-- =============================================================================
-- VASTA - Field Service & Work Order Management
-- 04_database_schema.sql  (PostgreSQL 15+ / Supabase)
-- Versi 0.1 (draf) | 2026-10-11
-- Sumber: 01_PRD.md, 02_business_analysis_technical_logic.md
-- Keputusan/deviasi dari 02: lihat bagian atas 05_rls_and_security.md
--
-- URUTAN MIGRASI (satu file ini = semua; potong pada penanda "MIGRATION nnnn"):
--   0000 local dev stubs         (hanya untuk Postgres non-Supabase; no-op di Supabase)
--   0001 extensions + enum + schema
--   0002 lookup + konfigurasi    (app_settings, priorities, reason_codes, wo_transitions)
--   0003 identitas + master data
--   0004 kontrak, kalender, SLA, jadwal berkala
--   0005 permintaan servis + work order + anak-anaknya
--   0006 suku cadang + buku besar stok
--   0007 penagihan (Lapis 3, ringkas) + tabel lintas sektor
--   0008 fungsi inti (helper, nomor dokumen, audit, SLA, kunci state)
--   0009 trigger
--   0010 fungsi bisnis (transisi WO, permintaan, PM, stok, variance, SLA job)
--   0011 view pelanggan + view operasional
--   0012 indeks
--   0013 RLS + privilege + Storage
--   0014 pg_cron
--   0015 seed struktural (tanpa angka bisnis)
--   0016 celah API-DB + perbaikan keamanan (G-04/05/06/08/12/13, S1/S2/S4, N1; aditif, menunggu persetujuan terap)
--
-- KONVENSI
--   * Tabel/kolom: snake_case Inggris. Nilai enum: UPPER_SNAKE.
--   * Semua tabel mutable punya id uuid, created_at, updated_at, version (kunci optimistik;
--     di-bump trigger app.tg_touch). Tabel append-only tidak punya updated_at/version.
--   * Tabel di schema public (terlihat PostgREST); fungsi internal di schema app (tidak diekspos).
--   * RPC publik (dipanggil klien/API) ada di public dan diberi GRANT EXECUTE eksplisit di 0013.
--   * Parameter bisnis ([P] di 02) ada di tabel konfigurasi (app_settings, sla_policies,
--     escalation_rules, business_calendars). Tidak ada angka bisnis yang di-hardcode.
--     Setting kosong (NULL) = fitur/batas nonaktif.
--
-- KATALOG ERROR (SQLSTATE kustom, untuk dipetakan api-designer)
--   WO001 transisi tidak diizinkan dari status saat ini
--   WO002 peran/aktor tidak berhak
--   WO003 guard gagal (DETAIL berisi jsonb daftar kekurangan)
--   WO004 konflik versi (optimistic lock) / op sudah kedaluwarsa
--   WO005 data tidak ditemukan / bukan milik aktor (dipetakan ke 404 seragam)
--   WO006 input tidak valid
--   STK01 stok tidak cukup
--   RL001 batas laju terlampaui
--   IMM01 data immutable (WO final / ledger append-only)
--
-- STATUS PENGUJIAN: dijalankan utuh pada PostgreSQL 16.2 lokal (tanpa pg_cron/pg_trgm/Storage/tzdata) beserta 171 pemeriksaan
-- fungsional & isolasi; BELUM diuji di proyek Supabase nyata. Rincian di bagian "Status verifikasi" 05_rls_and_security.md.
-- Skrip ini ditujukan untuk database KOSONG (migrasi satu kali; bukan idempoten).
-- =============================================================================

-- ===== MIGRATION 0000: local dev stubs (no-op di Supabase) ====================
do $stub$
begin
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    create schema auth;
    create table auth.users (
      id uuid primary key default gen_random_uuid(),
      email text,
      raw_user_meta_data jsonb,
      created_at timestamptz not null default now()
    );
    create function auth.uid() returns uuid language sql stable as
      $f$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
    create function auth.role() returns text language sql stable as
      $f$ select nullif(current_setting('request.jwt.claim.role', true), '') $f$;
    create function auth.jwt() returns jsonb language sql stable as
      $f$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $f$;
    grant usage on schema auth to public;                       -- Supabase memberi usage ke anon/authenticated/service_role
    grant execute on all functions in schema auth to public;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$stub$;

-- ===== MIGRATION 0001: extensions, schema, enum ===============================
-- Supabase: extension di-schema "extensions" (jangan di public: 0013 mencabut EXECUTE fungsi public dari PUBLIC).
create schema if not exists extensions;
do $ext$
begin
  begin
    create extension if not exists pg_trgm with schema extensions;   -- pencarian teks (Lapis 3 + indeks nama)
  exception when others then
    raise notice 'pg_trgm tidak tersedia; indeks trigram akan dilewati (lihat 0012).';
  end;
  begin
    create extension if not exists pg_cron;       -- penjadwalan (0014). Supabase: aktifkan juga lewat dashboard.
  exception when others then
    raise notice 'pg_cron tidak tersedia; jadwal 0014 akan dilewati.';
  end;
end
$ext$;

create schema if not exists app;
comment on schema app is 'Fungsi internal VASTA. Tidak diekspos lewat PostgREST. Jangan masukkan ke exposed schemas.';

-- Peran (8 peran sesuai 02 bagian 1; CUSTOMER disimpan di user_roles juga).
create type public.app_role as enum
  ('CUSTOMER','ADMIN_CS','DISPATCHER','TECHNICIAN','SUPERVISOR','WAREHOUSE','FINANCE','OWNER');
create type public.customer_role as enum ('ADMIN','MEMBER');
create type public.customer_type as enum ('CORPORATE','INDIVIDUAL');

create type public.request_status as enum
  ('SUBMITTED','NEEDS_INFO','REJECTED','CONVERTED','CANCELLED_BY_CUSTOMER');
create type public.request_channel as enum ('PWA','PHONE','CHAT','OTHER');
create type public.decision_source as enum ('USER','SYSTEM_RULE');

create type public.wo_type as enum ('CORRECTIVE','PREVENTIVE','REWORK');
create type public.wo_status as enum
  ('NEW','ASSIGNED','ACCEPTED','EN_ROUTE','IN_PROGRESS','ON_HOLD_PARTS',
   'AWAITING_CUSTOMER_APPROVAL','AWAITING_SIGNOFF','UNDER_REVIEW','RETURNED','CLOSED','CANCELLED');
create type public.wo_outcome as enum ('RESOLVED','PARTIAL','UNRESOLVED');
create type public.billing_type as enum ('BILLABLE','WARRANTY','COVERED_CONTRACT','WARRANTY_WORK');
create type public.billing_status as enum ('NOT_BILLABLE','PENDING','INVOICED','PAID');

create type public.assignment_role as enum ('LEAD','HELPER');
create type public.assignment_status as enum
  ('ASSIGNED','ACCEPTED','REJECTED','REASSIGNED','RELEASED','COMPLETED','CANCELLED');
create type public.visit_result as enum ('COMPLETED','FAILED_ABSENT','FAILED_OTHER','HANDOVER');

create type public.attachment_kind as enum ('BEFORE','AFTER','FINDING','OTHER','FAILED_VISIT');
create type public.upload_status as enum ('PENDING','UPLOADED','FAILED');
create type public.signature_status as enum ('VALID','SUPERSEDED');
create type public.signed_via as enum ('TECH_DEVICE','CUSTOMER_PWA');
create type public.signer_type as enum ('CUSTOMER','TECHNICIAN');

create type public.approval_status as enum ('PENDING','APPROVED','REJECTED','EXPIRED','SUPERSEDED');
create type public.decision_channel as enum ('PWA','PHONE','CHAT','OTHER');
create type public.extra_item_kind as enum ('LABOR','PART','OTHER');

create type public.contract_status as enum ('DRAFT','ACTIVE','EXPIRED','TERMINATED');
create type public.pm_frequency as enum ('MONTHLY','QUARTERLY','YEARLY');
create type public.pm_period_status as enum ('GENERATED','COMPLETED','MISSED','SKIPPED');

create type public.sla_state as enum
  ('NOT_TRACKED','RUNNING','WARNING','BREACHED','MET','MET_LATE','PAUSED');
create type public.sla_event_kind as enum
  ('RESPONSE_WARNING','RESPONSE_BREACH','RESOLUTION_WARNING','RESOLUTION_BREACH','PM_MISSED');
create type public.sla_response_event as enum ('ACCEPT','DEPART','CHECK_IN');
create type public.sla_resolution_event as enum ('SUBMIT','CLOSE');

create type public.stock_location_type as enum ('WAREHOUSE','TECHNICIAN','VEHICLE');
create type public.stock_movement_type as enum
  ('RECEIPT','ISSUE_TO_TECH','RETURN_FROM_TECH','CONSUME_ON_WO','ADJUSTMENT','TRANSFER');
create type public.item_tracking_mode as enum ('PER_WO','BULK');
create type public.part_request_status as enum
  ('REQUESTED','APPROVED','PARTIALLY_ISSUED','ISSUED','REJECTED','CANCELLED');
create type public.return_status as enum ('PENDING','CONFIRMED','REJECTED');
create type public.variance_status as enum
  ('OPEN','EXPLAINED','RETURNED_LATE','WRITTEN_OFF','CHARGED_TO_CUSTOMER');

create type public.invoice_type as enum ('WO','CONTRACT_PERIODIC');
create type public.invoice_status as enum ('DRAFT','ISSUED','PAID','VOID');

create type public.notification_channel as enum ('IN_APP','EMAIL','WHATSAPP','PUSH');
create type public.notification_status as enum ('PENDING','SENT','FAILED','READ');
create type public.sync_op_status as enum ('RECEIVED','APPLIED','REJECTED','RESCUED');
create type public.report_status as enum ('GENERATING','READY','FAILED');
create type public.job_status as enum ('RUNNING','OK','ERROR');
create type public.import_status as enum ('UPLOADED','VALIDATED','COMMITTED','FAILED');


-- ===== MIGRATION 0002: lookup + konfigurasi ====================================
create table public.app_settings (
  key         text primary key,
  value       jsonb,                      -- NULL = belum diputuskan / nonaktif
  description text,
  updated_by  uuid,
  updated_at  timestamptz not null default now()
);
comment on table public.app_settings is
  'Parameter [P] dari 02. NULL berarti belum diputuskan bisnis; fungsi memperlakukan NULL sebagai nonaktif.';

create table public.priorities (
  code        text primary key,
  name        text not null,
  sort_rank   smallint not null unique,   -- kecil = lebih rendah; hanya untuk urutan tampilan
  is_active   boolean not null default true
);

create table public.reason_codes (
  category    text not null,              -- CANCEL, REJECT_ASSIGNMENT, RELEASE, REASSIGN, CLOSURE_EXCEPTION, FAILED_VISIT, REQUEST_REJECT, HELP
  code        text not null,
  label       text not null,
  is_active   boolean not null default true,
  primary key (category, code)
);

create table public.document_counters (
  prefix      text not null,
  year        int  not null,
  last_value  bigint not null default 0,
  primary key (prefix, year)
);

-- Tabel transisi WO (T-02..T-27). Guard rinci ada di app.apply_wo_transition.
create table public.wo_transitions (
  code            text primary key,       -- 'T-03'
  action          text not null,          -- nama aksi untuk RPC wo_transition
  from_status     public.wo_status not null,
  to_status       public.wo_status not null,
  allowed_roles   public.app_role[] not null default '{}',
  allow_system    boolean not null default false,
  requires_reason boolean not null default false,
  description     text,
  unique (action, from_status)
);

-- ===== MIGRATION 0003: identitas + master data =================================
create table public.profiles (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  full_name      text not null,
  phone          text,
  is_active      boolean not null default true,
  deactivated_at timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  version        int not null default 1
);

create table public.user_roles (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(user_id) on delete cascade,
  role        public.app_role not null,
  granted_by  uuid,
  created_at  timestamptz not null default now(),
  unique (user_id, role)
);
comment on table public.user_roles is 'Penulisan hanya lewat service role/RPC admin (lihat 05). CUSTOMER eksklusif terhadap peran staf.';

create table public.user_consents (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.profiles(user_id) on delete cascade,
  policy_version text not null,
  accepted_at    timestamptz not null default now(),
  ip             text,
  user_agent     text
);

create table public.skills (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version    int not null default 1
);

create table public.technicians (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null unique references public.profiles(user_id),
  employee_code text not null unique,
  home_area     text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);

create table public.technician_skills (
  technician_id uuid not null references public.technicians(id) on delete cascade,
  skill_id      uuid not null references public.skills(id),
  level         smallint,
  primary key (technician_id, skill_id)
);

create table public.customers (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  name         text not null,
  type         public.customer_type not null,
  contact_name  text,
  contact_phone text,
  contact_email text,
  address      text,
  auto_approve boolean not null default false,   -- SP-02: auto-validasi permintaan (default mati)
  is_active    boolean not null default true,
  anonymized_at timestamptz,                     -- NFR-D5 (TODO prosedur anonimisasi)
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  version      int not null default 1
);

create table public.customer_users (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references public.customers(id),
  user_id       uuid not null references public.profiles(user_id),
  customer_role public.customer_role not null default 'MEMBER',
  is_active     boolean not null default true,
  invited_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  unique (customer_id, user_id)
);

create table public.customer_invitations (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references public.customers(id),
  email         text not null,
  customer_role public.customer_role not null default 'MEMBER',
  token_hash    text not null unique,            -- simpan hash, bukan token
  expires_at    timestamptz not null,
  accepted_at   timestamptz,
  accepted_by   uuid references public.profiles(user_id),
  created_by    uuid,
  created_at    timestamptz not null default now()
);

create table public.customer_sites (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  name        text not null,
  address     text,
  lat         numeric(9,6),
  lng         numeric(9,6),
  pic_name    text,
  pic_phone   text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  version     int not null default 1,
  unique (id, customer_id)                       -- target FK komposit (isolasi konsisten)
);

-- Template checklist (dibuat sebelum service_types/asset_categories yang mereferensikannya)
create table public.checklist_templates (
  id         uuid primary key default gen_random_uuid(),
  code       text not null,
  version_no int  not null default 1,
  name       text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version    int not null default 1,
  unique (code, version_no)
);

create table public.checklist_template_items (
  id             uuid primary key default gen_random_uuid(),
  template_id    uuid not null references public.checklist_templates(id) on delete cascade,
  seq            int  not null,
  label          text not null,
  input_type     text not null default 'BOOLEAN' check (input_type in ('BOOLEAN','TEXT','NUMBER','CHOICE')),
  choices        jsonb,
  required       boolean not null default false,
  photo_required boolean not null default false,
  unique (template_id, seq)
);

create table public.photo_requirements (
  id          uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.checklist_templates(id) on delete cascade,
  kind        public.attachment_kind not null,
  min_count   int not null check (min_count > 0),
  unique (template_id, kind)
);

create table public.asset_categories (
  id        uuid primary key default gen_random_uuid(),
  code      text not null unique,
  name      text not null,
  default_checklist_template_id uuid references public.checklist_templates(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version    int not null default 1
);

create table public.service_types (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  skill_id    uuid references public.skills(id),
  default_checklist_template_id uuid references public.checklist_templates(id),
  default_priority_code text references public.priorities(code),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  version     int not null default 1
);

create table public.problem_types (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique,
  name            text not null,
  service_type_id uuid references public.service_types(id),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  version         int not null default 1
);

create table public.service_items (            -- master jasa/tarif tenaga kerja (nilai diisi bisnis)
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  uom        text not null default 'EA',
  unit_price numeric(14,2),
  unit_cost  numeric(14,2),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version    int not null default 1
);

create table public.assets (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  site_id     uuid,
  category_id uuid references public.asset_categories(id),
  asset_code  text not null unique,
  qr_token    text not null unique default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  serial_no   text,
  brand       text,
  model       text,
  install_date date,
  warranty_start date,
  warranty_end   date,
  warranty_covers_labor boolean not null default true,   -- [A] cakupan garansi (BR-061), ubah per aset
  warranty_covers_parts boolean not null default true,   -- [A]
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  version     int not null default 1,
  unique (id, customer_id),
  foreign key (site_id, customer_id) references public.customer_sites(id, customer_id),
  check (warranty_end is null or warranty_start is null or warranty_end >= warranty_start)
);

-- ===== MIGRATION 0004: kalender, SLA, kontrak, jadwal berkala ===================
create table public.business_calendars (
  id        uuid primary key default gen_random_uuid(),
  name      text not null,
  timezone  text not null default 'Asia/Jakarta',   -- default dari 02 BR-011; disimpan per kalender
  is_24x7   boolean not null default false,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version    int not null default 1
);
create unique index uq_business_calendars_default on public.business_calendars (is_default) where is_default;

create table public.calendar_hours (
  id          uuid primary key default gen_random_uuid(),
  calendar_id uuid not null references public.business_calendars(id) on delete cascade,
  weekday     smallint not null check (weekday between 1 and 7),   -- ISO: 1=Senin .. 7=Minggu
  open_time   time not null,
  close_time  time not null,
  check (open_time < close_time)
);

create table public.calendar_holidays (
  id           uuid primary key default gen_random_uuid(),
  calendar_id  uuid not null references public.business_calendars(id) on delete cascade,
  holiday_date date not null,
  name         text,
  unique (calendar_id, holiday_date)
);

create table public.sla_policy_sets (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  is_default boolean not null default false,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version    int not null default 1
);
create unique index uq_sla_policy_sets_default on public.sla_policy_sets (is_default) where is_default;

create table public.sla_policies (
  id                  uuid primary key default gen_random_uuid(),
  policy_set_id       uuid not null references public.sla_policy_sets(id) on delete cascade,
  priority_code       text not null references public.priorities(code),
  response_minutes    int check (response_minutes > 0),       -- menit kerja; NULL = tidak dilacak
  resolution_minutes  int check (resolution_minutes > 0),
  warning_pct         numeric(5,2) check (warning_pct > 0 and warning_pct <= 100),  -- % durasi tersisa saat warning; NULL = tanpa warning
  response_met_event  public.sla_response_event not null default 'CHECK_IN',   -- BR-013 (opsi, pilih bisnis)
  resolution_met_event public.sla_resolution_event not null default 'SUBMIT',  -- OQ-11
  pause_on_hold_parts boolean not null default false,                          -- BR-012 opsional
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  version             int not null default 1,
  unique (policy_set_id, priority_code)
);

create table public.escalation_rules (
  id            uuid primary key default gen_random_uuid(),
  policy_set_id uuid not null references public.sla_policy_sets(id) on delete cascade,
  trigger_kind  public.sla_event_kind not null,
  level         smallint not null check (level > 0),
  notify_role   public.app_role not null,
  after_minutes int not null default 0 check (after_minutes >= 0),  -- menit jam-dinding sejak pemicu
  is_active     boolean not null default true,
  unique (policy_set_id, trigger_kind, level, notify_role)
);

create table public.contracts (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references public.customers(id),
  contract_no  text not null unique,
  start_date   date not null,
  end_date     date not null,
  status       public.contract_status not null default 'DRAFT',
  sla_policy_set_id uuid references public.sla_policy_sets(id),
  calendar_id  uuid references public.business_calendars(id),
  covers_labor  boolean not null default false,
  covers_parts  boolean not null default false,
  covers_travel boolean not null default false,
  contract_value numeric(14,2),
  note         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  version      int not null default 1,
  unique (id, customer_id),
  check (end_date >= start_date)
);

create table public.contract_assets (
  id              uuid primary key default gen_random_uuid(),
  contract_id     uuid not null references public.contracts(id),
  asset_id        uuid not null references public.assets(id),
  service_type_id uuid not null references public.service_types(id),
  frequency       public.pm_frequency not null,
  anchor_date     date not null,
  lead_days       int not null check (lead_days >= 0),    -- tanpa default: wajib diputuskan bisnis
  grace_days      int check (grace_days >= 0),            -- NULL -> app_settings pm.grace_days
  active_from     date,
  active_to       date,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  version         int not null default 1,
  unique (contract_id, asset_id, service_type_id)
);

-- Periode PM: baris unik per (contract_asset, tanggal jatuh tempo). Menjadi jangkar idempotensi
-- generator dan tempat mencatat periode MISSED tanpa WO (BR-024/025).
create table public.pm_periods (
  id                uuid primary key default gen_random_uuid(),
  contract_asset_id uuid not null references public.contract_assets(id),
  period_key        date not null,                         -- = tanggal jatuh tempo (BR-020)
  status            public.pm_period_status not null default 'GENERATED',
  wo_id             uuid,                                  -- FK ditambah setelah work_orders ada
  missed_at         timestamptz,
  completed_at      timestamptz,
  skip_reason       text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  version           int not null default 1,
  unique (contract_asset_id, period_key)
);


-- ===== MIGRATION 0005: permintaan servis + work order ===========================
create table public.service_requests (
  id              uuid primary key default gen_random_uuid(),
  request_no      text not null unique,                   -- diisi trigger (REQ-YYYY-nnnnnn)
  customer_id     uuid not null references public.customers(id),
  site_id         uuid,
  asset_id        uuid,
  problem_type_id uuid references public.problem_types(id),
  description     text,
  preferred_start timestamptz,                            -- hanya preferensi (FR-027)
  preferred_end   timestamptz,
  channel         public.request_channel not null default 'PWA',
  created_by      uuid not null,                          -- auth.users.id pembuat (pelanggan atau admin)
  client_request_id uuid,                                 -- idempotensi klien (BR-073)
  status          public.request_status not null default 'SUBMITTED',
  duplicate_of    uuid references public.service_requests(id),   -- peringatan duplikat (BR-071)
  decision_by     uuid,
  decision_source public.decision_source,
  decided_at      timestamptz,
  decision_reason text,                                   -- alasan tolak (tampil ke pelanggan)
  needs_info_note text,                                   -- catatan "butuh info" (tampil ke pelanggan)
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  version         int not null default 1,
  unique (customer_id, client_request_id),
  unique (id, customer_id),
  foreign key (asset_id, customer_id) references public.assets(id, customer_id),
  foreign key (site_id, customer_id) references public.customer_sites(id, customer_id)
);

create table public.request_attachments (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null,
  customer_id   uuid not null,
  storage_path  text not null unique,
  mime          text not null,
  bytes         int  not null check (bytes > 0),
  checksum      text,
  upload_status public.upload_status not null default 'PENDING',
  created_by    uuid,
  created_at    timestamptz not null default now(),
  foreign key (request_id, customer_id) references public.service_requests(id, customer_id)
);

create table public.work_orders (
  id              uuid primary key default gen_random_uuid(),
  wo_number       text not null unique,                    -- WO-YYYY-nnnnnn (BR-001)
  type            public.wo_type not null,
  customer_id     uuid not null references public.customers(id),   -- denormalisasi untuk RLS cepat
  site_id         uuid,
  asset_id        uuid not null,
  service_type_id uuid not null references public.service_types(id),
  request_id      uuid,
  contract_id     uuid,                                    -- kontrak yang mencakup (COVERED_CONTRACT / PM); dasar SLA + profit kontrak
  contract_asset_id uuid references public.contract_assets(id),
  pm_period_key   date,
  parent_wo_id    uuid references public.work_orders(id),
  priority_code   text not null references public.priorities(code),
  status          public.wo_status not null default 'NEW',
  -- penagihan (DEC-03: terpisah dari status WO)
  billing_type    public.billing_type not null,
  billing_status  public.billing_status not null default 'NOT_BILLABLE',
  billing_override_reason text,
  warranty_exception_reason text,
  estimate_total  numeric(14,2),                           -- boleh NULL (SP-08)
  estimate_version int not null default 1,
  -- jadwal
  scheduled_start timestamptz,
  scheduled_end   timestamptz,
  requested_at    timestamptz not null default now(),      -- dasar billing_type (BR-060)
  -- SLA (snapshot BR-010)
  sla_clock_start_at timestamptz not null default now(),
  sla_policy_set_id uuid references public.sla_policy_sets(id),
  sla_calendar_id   uuid references public.business_calendars(id),
  policy_snapshot   jsonb,
  response_due_at   timestamptz,
  resolution_due_at timestamptz,
  response_met_at   timestamptz,
  resolution_met_at timestamptz,
  response_sla_state   public.sla_state not null default 'NOT_TRACKED',
  resolution_sla_state public.sla_state not null default 'NOT_TRACKED',
  sla_paused_at     timestamptz,                           -- non-NULL = timer penyelesaian sedang dijeda
  next_sla_check_at timestamptz,
  pm_due_date       date,                                  -- BR-016: jendela jatuh tempo PM
  -- siklus kerja
  started_at      timestamptz,
  submitted_at    timestamptz,
  closed_at       timestamptz,
  cancelled_at    timestamptz,
  cancel_reason_code text,
  cancel_reason   text,
  cancel_requested_at timestamptz,                         -- pelanggan mengajukan batal (DEC-04)
  cancel_requested_by uuid,
  cancel_request_note text,
  signoff_expires_at timestamptz,                          -- kedaluwarsa AWAITING_SIGNOFF (T-17/T-18)
  closure_exception boolean not null default false,        -- BR-041
  closure_exception_code text,
  closure_exception_note text,
  closure_exception_approved_by uuid,
  closure_exception_approved_at timestamptz,
  outcome         public.wo_outcome,
  no_parts_used   boolean not null default false,          -- pernyataan eksplisit BR-040(6)
  checklist_template_id uuid references public.checklist_templates(id),
  checklist_template_version int,
  returned_count  int not null default 0,
  rejection_count int not null default 0,
  failed_visit_count int not null default 0,
  help_requested_at timestamptz,                           -- T-26
  help_requested_by uuid,
  help_note       text,
  customer_note   text,                                    -- keterangan satu baris untuk pelanggan (SP-09)
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  version         int not null default 1,
  unique (id, customer_id),
  foreign key (asset_id, customer_id) references public.assets(id, customer_id),
  foreign key (site_id, customer_id) references public.customer_sites(id, customer_id),
  foreign key (request_id, customer_id) references public.service_requests(id, customer_id),
  foreign key (contract_id, customer_id) references public.contracts(id, customer_id),
  check (type <> 'PREVENTIVE' or (contract_asset_id is not null and pm_period_key is not null)),
  check (type <> 'REWORK' or parent_wo_id is not null),
  check (type <> 'CORRECTIVE' or request_id is not null),
  check (scheduled_end is null or scheduled_start is null or scheduled_end >= scheduled_start)
);

-- Constraint kunci idempotensi (BR-022): satu WO per (contract_asset, periode); satu WO per permintaan.
create unique index uq_wo_preventive_period on public.work_orders (contract_asset_id, pm_period_key) where type = 'PREVENTIVE';
create unique index uq_wo_request on public.work_orders (request_id) where request_id is not null;

alter table public.pm_periods
  add constraint fk_pm_periods_wo foreign key (wo_id) references public.work_orders(id);

create table public.wo_status_history (
  id            bigint generated always as identity primary key,
  wo_id         uuid not null references public.work_orders(id),
  from_status   public.wo_status,
  to_status     public.wo_status not null,
  action        text,
  actor_id      uuid,
  actor_roles   text,
  reason_code   text,
  reason        text,
  customer_note text,
  op_id         uuid,
  at            timestamptz not null default now()
);

create table public.wo_assignments (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  technician_id uuid not null references public.technicians(id),
  role          public.assignment_role not null default 'LEAD',
  status        public.assignment_status not null default 'ASSIGNED',
  reason_code   text,
  reason        text,
  override_reason text,                                    -- override peringatan lunak keahlian/bentrok
  assigned_by   uuid,
  assigned_at   timestamptz not null default now(),
  responded_at  timestamptz,
  ended_at      timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);

create table public.wo_visits (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  technician_id uuid not null references public.technicians(id),
  check_in_at   timestamptz,
  check_in_lat  numeric(9,6),
  check_in_lng  numeric(9,6),
  check_in_accuracy_m numeric(8,2),
  check_in_no_gps_reason text,                             -- FR-053: tanpa lokasi + alasan
  check_out_at  timestamptz,
  check_out_lat numeric(9,6),
  check_out_lng numeric(9,6),
  result        public.visit_result,
  note          text,
  auto_checked_out boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);

create table public.wo_checklist_items (
  id               uuid primary key default gen_random_uuid(),
  wo_id            uuid not null references public.work_orders(id),
  template_item_id uuid references public.checklist_template_items(id),
  seq              int not null,
  label_snapshot   text not null,
  input_type       text not null default 'BOOLEAN',
  choices          jsonb,
  required         boolean not null default false,
  photo_required   boolean not null default false,
  value            jsonb,
  is_na            boolean not null default false,
  na_reason        text,
  filled_by        uuid,
  filled_at        timestamptz,
  client_captured_at timestamptz,
  op_id            uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  version          int not null default 1,
  unique (wo_id, seq),
  check (not is_na or coalesce(btrim(na_reason), '') <> '')
);

create table public.wo_photo_requirements (    -- snapshot dari photo_requirements saat WO dibuat
  id        uuid primary key default gen_random_uuid(),
  wo_id     uuid not null references public.work_orders(id) on delete cascade,
  kind      public.attachment_kind not null,
  min_count int not null check (min_count > 0),
  unique (wo_id, kind)
);

create table public.wo_findings (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null unique references public.work_orders(id),
  diagnosis     text,
  action_taken  text,
  recommendation text,
  internal_note text,                                      -- tidak pernah ke pelanggan (AP-3)
  updated_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);

create table public.extra_cost_approvals (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  version_no    int not null,                              -- versi dokumen persetujuan (BR-051)
  status        public.approval_status not null default 'PENDING',
  total         numeric(14,2) not null default 0,
  reason        text not null,
  requested_by  uuid not null,
  requested_at  timestamptz not null default now(),
  expires_at    timestamptz,
  decided_by    uuid,
  decided_at    timestamptz,
  decision_channel public.decision_channel,
  on_behalf     boolean not null default false,            -- ADM atas nama pelanggan (butuh bukti)
  evidence_note text,
  continue_original_scope boolean,                         -- T-13 vs T-14
  content_hash  text not null,
  decision_meta jsonb,                                     -- ip, device, user agent
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  unique (wo_id, version_no),
  check (not on_behalf or coalesce(btrim(evidence_note), '') <> '')
);

create table public.extra_cost_approval_items (
  id          uuid primary key default gen_random_uuid(),
  approval_id uuid not null references public.extra_cost_approvals(id) on delete cascade,
  kind        public.extra_item_kind not null,
  ref_id      uuid,                                        -- service_items.id atau items.id
  description text not null,
  qty         numeric(12,3) not null check (qty > 0),
  unit_price  numeric(14,2) not null check (unit_price >= 0),
  subtotal    numeric(14,2) generated always as (round(qty * unit_price, 2)) stored
);

create table public.wo_attachments (
  id            uuid primary key default gen_random_uuid(),   -- klien boleh menyuplai id (idempotensi ADD_PHOTO)
  wo_id         uuid not null references public.work_orders(id),
  kind          public.attachment_kind not null,
  storage_path  text not null unique,
  upload_status public.upload_status not null default 'PENDING',
  mime          text,
  bytes         int check (bytes is null or bytes > 0),
  checksum      text,
  taken_at      timestamptz,
  taken_by      uuid,
  op_id         uuid,
  extra_approval_id uuid references public.extra_cost_approvals(id),
  deleted_at    timestamptz,                                -- tombstone (6.3)
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);

create table public.wo_signatures (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  signer_type   public.signer_type not null default 'CUSTOMER',
  signer_name   text not null,
  signer_user_id uuid,
  storage_path  text not null unique,
  content_hash  text not null,                              -- diisi server (app.wo_content_hash)
  status        public.signature_status not null default 'VALID',
  signed_at     timestamptz not null default now(),
  signed_via    public.signed_via not null,
  device_meta   jsonb,
  op_id         uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);

create table public.wo_labor_lines (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  service_item_id uuid references public.service_items(id),
  description   text not null,
  qty           numeric(12,3) not null check (qty > 0),
  unit_price_snapshot numeric(14,2),                        -- BR-067
  unit_cost_snapshot  numeric(14,2),
  billable      boolean not null,                           -- diisi trigger bila NULL (BR-061)
  is_extra      boolean not null default false,
  extra_approval_id uuid references public.extra_cost_approvals(id),
  emergency     boolean not null default false,             -- BR-052
  emergency_reason text,
  emergency_approved_by uuid,
  op_id         uuid,
  deleted_at    timestamptz,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  check (not emergency or coalesce(btrim(emergency_reason), '') <> '')
);

create table public.sla_events (
  id           uuid primary key default gen_random_uuid(),
  wo_id        uuid references public.work_orders(id),
  pm_period_id uuid references public.pm_periods(id),
  kind         public.sla_event_kind not null,
  level        smallint not null default 1,
  target       text not null default '*',                  -- peran penerima eskalasi ('*' = penanda dasar tanpa penerima)
  at           timestamptz not null default now(),
  acknowledged_by uuid,
  acknowledged_at timestamptz,
  check (wo_id is not null or pm_period_id is not null)
);
-- idempotensi eskalasi (BR-014): satu baris per (target, jenis, level, penerima)
create unique index uq_sla_events_wo on public.sla_events (wo_id, kind, level, target) where wo_id is not null;
create unique index uq_sla_events_period on public.sla_events (pm_period_id, kind, level, target) where pm_period_id is not null;

create table public.sla_pauses (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  reason        text not null,
  paused_at     timestamptz not null,
  resumed_at    timestamptz,
  remaining_minutes numeric(12,2)                           -- sisa menit kerja saat jeda (BR-012)
);

create table public.service_reports (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  customer_id   uuid not null references public.customers(id),
  revision      int not null default 1,
  status        public.report_status not null default 'GENERATING',
  storage_path  text unique,
  snapshot      jsonb not null,                              -- tanpa HPP (FR-140)
  snapshot_hash text not null,
  generated_at  timestamptz,
  generated_by  uuid,
  sent_at       timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  unique (wo_id, revision)
);

create table public.ratings (
  id               uuid primary key default gen_random_uuid(),
  wo_id            uuid not null unique references public.work_orders(id),   -- BR-074: satu per WO
  customer_id      uuid not null references public.customers(id),
  customer_user_id uuid not null,
  score            smallint not null check (score between 1 and 5),
  comment          text,
  created_at       timestamptz not null default now()
);

create table public.complaints (
  id               uuid primary key default gen_random_uuid(),
  wo_id            uuid not null references public.work_orders(id),
  customer_id      uuid not null references public.customers(id),
  customer_user_id uuid not null,
  description      text not null,
  status           text not null default 'OPEN' check (status in ('OPEN','IN_REVIEW','RESOLVED','REJECTED')),
  rework_wo_id     uuid references public.work_orders(id),
  handled_by       uuid,
  resolution_note  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  version          int not null default 1
);

-- ===== MIGRATION 0006: suku cadang + buku besar stok =============================
create table public.items (
  id            uuid primary key default gen_random_uuid(),
  sku           text not null unique,
  name          text not null,
  uom           text not null default 'EA',
  unit_cost     numeric(14,2),
  unit_price    numeric(14,2),
  min_stock     numeric(12,3) check (min_stock is null or min_stock >= 0),
  variance_tolerance numeric(12,3) check (variance_tolerance is null or variance_tolerance >= 0),  -- OQ-20, NULL = 0
  is_serialized boolean not null default false,
  tracking_mode public.item_tracking_mode not null default 'PER_WO',   -- SP-04(e)
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);

create table public.stock_locations (
  id            uuid primary key default gen_random_uuid(),
  type          public.stock_location_type not null,
  name          text not null,
  technician_id uuid references public.technicians(id),
  is_default_warehouse boolean not null default false,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  check ((type = 'WAREHOUSE' and technician_id is null) or (type <> 'WAREHOUSE' and technician_id is not null))
);
create unique index uq_stock_locations_default_wh on public.stock_locations (is_default_warehouse) where is_default_warehouse;
create unique index uq_stock_locations_tech on public.stock_locations (technician_id) where type = 'TECHNICIAN';

create table public.stock_balances (
  item_id     uuid not null references public.items(id),
  location_id uuid not null references public.stock_locations(id),
  on_hand     numeric(14,3) not null default 0 check (on_hand >= 0),     -- BR-030
  reserved    numeric(14,3) not null default 0 check (reserved >= 0),    -- BR-038 (opsional, TODO logika reservasi)
  below_min_notified boolean not null default false,                     -- BR-036
  updated_at  timestamptz not null default now(),
  primary key (item_id, location_id)
);

create table public.stock_movements (          -- APPEND-ONLY (trigger IMM01)
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.items(id),
  from_location_id uuid references public.stock_locations(id),
  to_location_id   uuid references public.stock_locations(id),
  qty          numeric(14,3) not null check (qty > 0),
  type         public.stock_movement_type not null,
  wo_id        uuid references public.work_orders(id),
  ref_type     text,
  ref_id       uuid,
  actor_id     uuid,
  note         text,
  created_at   timestamptz not null default now(),
  check (
    (type = 'RECEIPT'          and from_location_id is null     and to_location_id is not null) or
    (type = 'ISSUE_TO_TECH'    and from_location_id is not null and to_location_id is not null and wo_id is not null) or
    (type = 'RETURN_FROM_TECH' and from_location_id is not null and to_location_id is not null and wo_id is not null) or
    (type = 'CONSUME_ON_WO'    and from_location_id is not null and to_location_id is null     and wo_id is not null) or
    (type = 'ADJUSTMENT'       and (from_location_id is null) <> (to_location_id is null)) or
    (type = 'TRANSFER'         and from_location_id is not null and to_location_id is not null and from_location_id <> to_location_id)
  )
);

create table public.part_requests (
  id           uuid primary key default gen_random_uuid(),
  request_no   text not null unique,                      -- PR-YYYY-nnnnnn
  wo_id        uuid not null references public.work_orders(id),
  requested_by uuid not null,
  status       public.part_request_status not null default 'REQUESTED',
  note         text,
  decided_by   uuid,
  decided_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  version      int not null default 1
);

create table public.part_request_lines (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references public.part_requests(id) on delete cascade,
  item_id       uuid not null references public.items(id),
  qty_requested numeric(12,3) not null check (qty_requested > 0),
  qty_issued    numeric(12,3) not null default 0 check (qty_issued >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  check (qty_issued <= qty_requested),
  unique (request_id, item_id)
);

create table public.part_returns (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  technician_id uuid not null references public.technicians(id),
  status        public.return_status not null default 'PENDING',
  note          text,
  confirmed_by  uuid,
  confirmed_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1
);

create table public.part_return_lines (
  id            uuid primary key default gen_random_uuid(),
  return_id     uuid not null references public.part_returns(id) on delete cascade,
  item_id       uuid not null references public.items(id),
  qty           numeric(12,3) not null check (qty > 0),
  confirmed_qty numeric(12,3) check (confirmed_qty >= 0),
  unique (return_id, item_id)
);

create table public.wo_part_usages (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  item_id       uuid not null references public.items(id),
  technician_id uuid not null references public.technicians(id),
  qty           numeric(12,3) not null check (qty > 0),
  unit_price_snapshot numeric(14,2),
  unit_cost_snapshot  numeric(14,2),
  billable      boolean not null,                           -- diisi trigger bila NULL (BR-061)
  is_extra      boolean not null default false,
  extra_approval_id uuid references public.extra_cost_approvals(id),
  emergency     boolean not null default false,
  emergency_reason text,
  emergency_approved_by uuid,
  source_location_id uuid references public.stock_locations(id),
  unsourced     boolean not null default false,             -- BR-035 (UNSOURCED_USAGE)
  op_id         uuid,
  deleted_at    timestamptz,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  check (not emergency or coalesce(btrim(emergency_reason), '') <> '')
);

create table public.parts_variances (
  id            uuid primary key default gen_random_uuid(),
  wo_id         uuid not null references public.work_orders(id),
  item_id       uuid not null references public.items(id),
  technician_id uuid not null references public.technicians(id),
  issued        numeric(14,3) not null default 0,
  used          numeric(14,3) not null default 0,
  returned      numeric(14,3) not null default 0,
  variance      numeric(14,3) generated always as (issued - used - returned) stored,   -- BR-031
  is_final      boolean not null default false,             -- BR-032 (awal indikatif, lalu final)
  status        public.variance_status,                     -- NULL = belum ditandai; OPEN setelah final & melewati toleransi
  resolution_note text,
  resolved_by   uuid,
  resolved_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  version       int not null default 1,
  unique (wo_id, item_id, technician_id)
);

-- ===== MIGRATION 0007: penagihan (Lapis 3, ringkas) + lintas sektor ==============
-- TODO Lapis 3: nomor invoice per kebijakan pajak (Q14), PPN, nota koreksi, ekspor CSV (Q13).
create table public.invoices (
  id           uuid primary key default gen_random_uuid(),
  invoice_no   text not null unique,
  customer_id  uuid not null references public.customers(id),
  contract_id  uuid references public.contracts(id),
  type         public.invoice_type not null default 'WO',
  period       daterange,
  status       public.invoice_status not null default 'DRAFT',
  subtotal     numeric(14,2) not null default 0,
  tax          numeric(14,2) not null default 0,          -- aturan PPN: di luar cakupan awal (AS-14)
  total        numeric(14,2) not null default 0,
  issued_at    timestamptz,
  due_date     date,
  exported_at  timestamptz,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  version      int not null default 1
);

create table public.invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.invoices(id) on delete cascade,
  wo_id        uuid references public.work_orders(id),
  source_type  text not null,                              -- 'LABOR' | 'PART' | 'CONTRACT_FEE'
  source_id    uuid not null,
  description  text not null,
  qty          numeric(12,3) not null,
  unit_price   numeric(14,2) not null,
  amount       numeric(14,2) not null,
  unique (source_type, source_id)                          -- cegah tagih ganda (SP-05c)
);

create table public.payments (
  id         uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id),
  amount     numeric(14,2) not null check (amount > 0),
  paid_at    timestamptz not null,
  method     text,
  reference  text,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table public.import_jobs (                          -- RK-09 / FR-014 (TODO logika impor)
  id           uuid primary key default gen_random_uuid(),
  type         text not null check (type in ('CUSTOMERS','ASSETS','STOCK')),
  file_path    text not null,
  status       public.import_status not null default 'UPLOADED',
  error_report jsonb,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  version      int not null default 1
);

create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(user_id),
  event        text not null,
  channel      public.notification_channel not null,
  wo_id        uuid,
  payload      jsonb not null default '{}'::jsonb,
  status       public.notification_status not null default 'PENDING',
  dedupe_key   text,
  attempts     int not null default 0,
  last_error   text,
  scheduled_at timestamptz not null default now(),
  sent_at      timestamptz,
  read_at      timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  version      int not null default 1
);

create table public.notification_prefs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(user_id) on delete cascade,
  channel     public.notification_channel not null,
  event_group text not null default '*',
  enabled     boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  version     int not null default 1,
  unique (user_id, channel, event_group)
);

create table public.audit_logs (                           -- APPEND-ONLY
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor_id    uuid,
  actor_roles text,
  entity_type text not null,
  entity_id   text,
  action      text not null,                              -- INSERT | UPDATE | DELETE
  old_values  jsonb,
  new_values  jsonb,
  request_id  text,
  ip          text
);

create table public.access_logs (                          -- APPEND-ONLY, FR-171
  id            bigint generated always as identity primary key,
  at            timestamptz not null default now(),
  actor_id      uuid not null,
  customer_id   uuid,
  resource_type text not null,
  resource_id   text,
  action        text not null default 'READ'
);

create table public.sync_operations (
  op_id        uuid primary key,
  device_id    text not null,
  user_id      uuid not null,
  wo_id        uuid,
  type         text not null,
  seq          bigint,
  schema_version int,
  status       public.sync_op_status not null default 'RECEIVED',
  payload      jsonb,
  result       jsonb,
  client_captured_at timestamptz,
  clock_skew   boolean not null default false,
  received_at  timestamptz not null default now(),
  applied_at   timestamptz
);

create table public.rate_limits (
  key          text not null,
  window_start timestamptz not null,
  count        int not null default 0,
  primary key (key, window_start)
);

create table public.job_runs (                             -- RK-15: heartbeat job terjadwal
  id            bigint generated always as identity primary key,
  job_name      text not null,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  status        public.job_status not null default 'RUNNING',
  rows_affected int,
  error         text
);


-- ===== MIGRATION 0008: fungsi inti (helper, nomor, audit, SLA, hash, guard) =======
-- Semua fungsi SECURITY DEFINER memakai search_path '' dan nama terkualifikasi (anti-hijack).

-- ---- settings -----------------------------------------------------------------
create or replace function app.setting(p_key text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select value from public.app_settings where key = p_key
$$;

create or replace function app.setting_int(p_key text) returns int
language sql stable security definer set search_path = '' as $$
  select case when jsonb_typeof(value) = 'number' then (value #>> '{}')::numeric::int end
  from public.app_settings where key = p_key
$$;

create or replace function app.setting_text(p_key text) returns text
language sql stable security definer set search_path = '' as $$
  select case when jsonb_typeof(value) = 'string' then value #>> '{}' end
  from public.app_settings where key = p_key
$$;

create or replace function app.setting_bool(p_key text, p_default boolean default false) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select case when jsonb_typeof(value) = 'boolean' then (value #>> '{}')::boolean end
                   from public.app_settings where key = p_key), p_default)
$$;

-- ---- nomor dokumen (BR-001) ------------------------------------------------------
-- Counter per (prefix, tahun) dengan row lock lewat ON CONFLICT DO UPDATE: unik, berurutan, tidak dipakai ulang.
create or replace function app.next_doc_number(p_prefix text, p_pad int default 6) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_year int := extract(year from (now() at time zone coalesce(app.setting_text('default_timezone'), 'Asia/Jakarta')))::int;
  v_val bigint;
begin
  insert into public.document_counters as dc (prefix, year, last_value)
  values (p_prefix, v_year, 1)
  on conflict (prefix, year) do update set last_value = dc.last_value + 1
  returning last_value into v_val;
  return p_prefix || '-' || v_year::text || '-' || lpad(v_val::text, p_pad, '0');
end $$;

-- ---- identitas / peran (dipakai RLS; selalu dipanggil sebagai (select app.fn()) di policy) ----
create or replace function app.my_roles() returns public.app_role[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(ur.role), '{}'::public.app_role[])
  from public.user_roles ur
  join public.profiles p on p.user_id = ur.user_id
  where ur.user_id = auth.uid() and p.is_active
$$;

create or replace function app.has_any_role(p_roles public.app_role[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.my_roles() && p_roles
$$;

create or replace function app.my_customer_ids() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(cu.customer_id), '{}'::uuid[])
  from public.customer_users cu
  join public.profiles p on p.user_id = cu.user_id
  join public.customers c on c.id = cu.customer_id
  where cu.user_id = auth.uid() and cu.is_active and p.is_active and c.is_active
$$;

create or replace function app.my_technician_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select t.id from public.technicians t
  join public.profiles p on p.user_id = t.user_id
  where t.user_id = auth.uid() and t.is_active and p.is_active
$$;

-- WO yang boleh DILIHAT teknisi: penugasan aktif/selesai/dibatalkan miliknya (AP-2; CANCELLED tetap terlihat agar pull sinkron tahu
-- pembatalan). REJECTED/RELEASED/REASSIGNED hilang dari cache (CONFLICT_REASSIGNED).
create or replace function app.my_active_wo_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select a.wo_id from public.wo_assignments a
  where a.technician_id = app.my_technician_id() and a.status in ('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED')
$$;

-- WO yang boleh DIUBAH datanya oleh teknisi (isian lapangan).
create or replace function app.my_editable_wo_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select a.wo_id from public.wo_assignments a
  join public.work_orders w on w.id = a.wo_id
  where a.technician_id = app.my_technician_id() and a.status = 'ACCEPTED'
    and w.status in ('IN_PROGRESS','ON_HOLD_PARTS','AWAITING_CUSTOMER_APPROVAL')
$$;

create or replace function app.tech_customer_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select distinct w.customer_id from public.work_orders w where w.id in (select app.my_active_wo_ids())
$$;
create or replace function app.tech_site_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select distinct w.site_id from public.work_orders w where w.site_id is not null and w.id in (select app.my_active_wo_ids())
$$;
create or replace function app.tech_asset_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select distinct w.asset_id from public.work_orders w where w.id in (select app.my_active_wo_ids())
$$;

create or replace function app.customer_owns_wo(p_wo_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.work_orders w
                 where w.id = p_wo_id and w.customer_id = any (app.my_customer_ids()))
$$;

-- Konteks sistem: service_role (JWT) atau sesi DB postgres tanpa user (pg_cron, migrasi).
create or replace function app.is_system() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
      or (auth.uid() is null and session_user in ('postgres', 'supabase_admin'))
$$;

create or replace function app.resolve_actor_roles(p_wo_id uuid) returns public.app_role[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(r), '{}'::public.app_role[])
  from unnest(app.my_roles()) r
  where r <> 'CUSTOMER' or app.customer_owns_wo(p_wo_id)
$$;

-- Pemetaan status internal -> status pelanggan (4.2). Fungsi murni di database, bukan di klien.
create or replace function app.customer_status(p_status public.wo_status) returns text
language sql immutable as $$
  select case p_status
    when 'NEW' then 'RECEIVED'
    when 'ASSIGNED' then 'RECEIVED'                       -- DEC-02: belum "Dijadwalkan" sebelum teknisi menerima
    when 'ACCEPTED' then 'SCHEDULED'
    when 'EN_ROUTE' then 'EN_ROUTE'
    when 'IN_PROGRESS' then 'IN_PROGRESS'
    when 'ON_HOLD_PARTS' then 'IN_PROGRESS'
    when 'UNDER_REVIEW' then 'IN_PROGRESS'
    when 'RETURNED' then 'IN_PROGRESS'                    -- tidak ada kemunduran terlihat
    when 'AWAITING_CUSTOMER_APPROVAL' then 'AWAITING_CUSTOMER'
    when 'AWAITING_SIGNOFF' then 'AWAITING_CUSTOMER'
    when 'CLOSED' then 'COMPLETED'
    when 'CANCELLED' then 'CANCELLED'
  end
$$;

-- ---- rate limit (BR-072) -----------------------------------------------------------
-- Jendela tetap. Mengembalikan TRUE bila masih dalam batas. IP-level dilakukan di edge/Next.js.
create or replace function app.rate_limit_hit(p_key text, p_max int, p_window_seconds int) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_ws timestamptz; v_count int;
begin
  if p_max is null or p_window_seconds is null or p_window_seconds <= 0 then return true; end if;
  v_ws := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into public.rate_limits as rl (key, window_start, count) values (p_key, v_ws, 1)
  on conflict (key, window_start) do update set count = rl.count + 1
  returning count into v_count;
  return v_count <= p_max;
end $$;

-- ---- trigger utilitas ---------------------------------------------------------------
create or replace function app.tg_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.version := old.version + 1;
  return new;
end $$;

create or replace function app.tg_forbid_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'IMM01: % bersifat append-only (% ditolak)', tg_table_name, tg_op
    using errcode = 'IMM01';
end $$;

-- Audit generik (BR-070, NFR-A2/A4). TG_ARGV[0] = daftar kolom diabaikan (csv) agar tidak berisik.
create or replace function app.tg_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_old jsonb; v_new jsonb; v_entity text;
  v_ignore text[] := coalesce(string_to_array(tg_argv[0], ','), '{}'::text[]) || array['updated_at','version'];
  v_headers jsonb; v_roles text;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new) - v_ignore;
    v_entity := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'key', to_jsonb(new) ->> 'user_id');
  elsif tg_op = 'UPDATE' then
    select jsonb_object_agg(n.key, n.value), jsonb_object_agg(o.key, o.value)
      into v_new, v_old
    from jsonb_each(to_jsonb(new) - v_ignore) n
    join jsonb_each(to_jsonb(old) - v_ignore) o on o.key = n.key
    where n.value is distinct from o.value;
    if v_new is null then return null; end if;           -- tidak ada perubahan bermakna
    v_entity := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'key', to_jsonb(new) ->> 'user_id');
  else
    v_old := to_jsonb(old) - v_ignore;
    v_entity := coalesce(to_jsonb(old) ->> 'id', to_jsonb(old) ->> 'key', to_jsonb(old) ->> 'user_id');
  end if;

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;
  v_roles := coalesce(nullif(current_setting('app.actor_role', true), ''),
                      nullif(array_to_string(app.my_roles(), ','), ''),
                      case when app.is_system() then 'SYSTEM' end);

  insert into public.audit_logs (actor_id, actor_roles, entity_type, entity_id, action, old_values, new_values, request_id, ip)
  values (auth.uid(), v_roles, tg_table_name, v_entity, tg_op, v_old, v_new,
          v_headers ->> 'x-request-id',
          coalesce(split_part(v_headers ->> 'x-forwarded-for', ',', 1), v_headers ->> 'x-real-ip'));
  return null;
end $$;

-- ---- notifikasi -----------------------------------------------------------------------
create or replace function app.enqueue_notification(p_user_id uuid, p_event text, p_wo_id uuid,
                                                    p_payload jsonb, p_dedupe text) returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_channels text[];
  v_ch text; v_n int := 0;
begin
  select coalesce(array(select jsonb_array_elements_text(value)), '{}')
    into v_channels
    from public.app_settings
   where key = 'notification.default_channels' and jsonb_typeof(value) = 'array';
  if v_channels is null or cardinality(v_channels) = 0 then v_channels := array['IN_APP','EMAIL']; end if;

  foreach v_ch in array v_channels loop
    continue when exists (
      select 1 from public.notification_prefs np
      where np.user_id = p_user_id and np.channel = v_ch::public.notification_channel
        and np.event_group in ('*', split_part(p_event, '.', 1)) and not np.enabled);
    insert into public.notifications (user_id, event, channel, wo_id, payload, dedupe_key)
    values (p_user_id, p_event, v_ch::public.notification_channel, p_wo_id, coalesce(p_payload, '{}'::jsonb),
            case when p_dedupe is null then null else p_dedupe || ':' || v_ch end)
    on conflict do nothing;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function app.notify_role(p_role public.app_role, p_event text, p_wo_id uuid,
                                           p_payload jsonb, p_dedupe_prefix text) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select ur.user_id from public.user_roles ur join public.profiles p on p.user_id = ur.user_id
            where ur.role = p_role and p.is_active loop
    v_n := v_n + app.enqueue_notification(r.user_id, p_event, p_wo_id, p_payload,
              case when p_dedupe_prefix is null then null else p_dedupe_prefix || ':' || r.user_id::text end);
  end loop;
  return v_n;
end $$;

create or replace function app.notify_customer(p_customer_id uuid, p_event text, p_wo_id uuid,
                                               p_payload jsonb, p_dedupe_prefix text) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select cu.user_id from public.customer_users cu join public.profiles p on p.user_id = cu.user_id
            where cu.customer_id = p_customer_id and cu.is_active and p.is_active loop
    v_n := v_n + app.enqueue_notification(r.user_id, p_event, p_wo_id, p_payload,
              case when p_dedupe_prefix is null then null else p_dedupe_prefix || ':' || r.user_id::text end);
  end loop;
  return v_n;
end $$;

create or replace function app.notify_wo_technicians(p_wo_id uuid, p_event text, p_payload jsonb, p_dedupe_prefix text) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select t.user_id from public.wo_assignments a join public.technicians t on t.id = a.technician_id
            where a.wo_id = p_wo_id and a.status in ('ASSIGNED','ACCEPTED') loop
    v_n := v_n + app.enqueue_notification(r.user_id, p_event, p_wo_id, p_payload,
              case when p_dedupe_prefix is null then null else p_dedupe_prefix || ':' || r.user_id::text end);
  end loop;
  return v_n;
end $$;

-- ---- kalender kerja & SLA (BR-011/012) -----------------------------------------------------
-- Jendela jam kerja terbuka pada [p_from, p_to), sudah dipotong ke rentang & melewati hari libur.
create or replace function app.sla_open_windows(p_calendar_id uuid, p_from timestamptz, p_to timestamptz)
returns table (w_start timestamptz, w_end timestamptz)
language sql stable security definer set search_path = '' as $$
  with cal as (
    select id, timezone, is_24x7 from public.business_calendars where id = p_calendar_id
  )
  select p_from, p_to from cal where cal.is_24x7 and p_to > p_from
  union all
  select x.ws, x.we from (
    select greatest((d.d::date + h.open_time) at time zone cal.timezone, p_from) as ws,
           least((d.d::date + h.close_time) at time zone cal.timezone, p_to)     as we
    from cal
    cross join lateral generate_series(((p_from at time zone cal.timezone)::date - 1)::timestamp,
                                       ((p_to   at time zone cal.timezone)::date + 1)::timestamp,
                                       interval '1 day') as d(d)
    join public.calendar_hours h on h.calendar_id = cal.id and h.weekday = extract(isodow from d.d)::int
    where not cal.is_24x7
      and not exists (select 1 from public.calendar_holidays ho
                      where ho.calendar_id = cal.id and ho.holiday_date = d.d::date)
  ) x
  where x.we > x.ws
  order by 1
$$;

-- Tambah menit kerja ke waktu mulai. Kalender NULL / 24x7 = menit dinding. NULL bila kalender tak punya jam kerja.
create or replace function app.sla_add_business_minutes(p_start timestamptz, p_minutes numeric, p_calendar_id uuid)
returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare
  v_is247 boolean; v_found boolean := false;
  v_rem numeric := p_minutes; v_t timestamptz := p_start; v_to timestamptz;
  v_i int := 0; r record; v_avail numeric;
begin
  if p_start is null or p_minutes is null then return null; end if;
  if p_minutes < 0 then raise exception 'WO006: menit negatif tidak didukung' using errcode = 'WO006'; end if;
  if p_calendar_id is not null then
    select is_24x7, true into v_is247, v_found from public.business_calendars where id = p_calendar_id;
  end if;
  if not v_found or v_is247 then
    return p_start + make_interval(secs => (p_minutes * 60)::double precision);
  end if;
  loop
    v_to := v_t + interval '62 days';
    for r in select * from app.sla_open_windows(p_calendar_id, v_t, v_to) loop
      v_avail := extract(epoch from (r.w_end - r.w_start)) / 60;
      if v_rem <= v_avail then
        return r.w_start + make_interval(secs => (v_rem * 60)::double precision);
      end if;
      v_rem := v_rem - v_avail;
    end loop;
    v_t := v_to; v_i := v_i + 1;
    if v_i >= 24 then
      raise warning 'sla_add_business_minutes: kalender % tidak punya jam kerja dalam ~4 tahun', p_calendar_id;
      return null;
    end if;
  end loop;
end $$;

-- Menit kerja antara dua waktu (>= 0).
create or replace function app.sla_business_minutes_between(p_from timestamptz, p_to timestamptz, p_calendar_id uuid)
returns numeric
language plpgsql stable security definer set search_path = '' as $$
declare v_is247 boolean; v_found boolean := false; v_sum numeric;
begin
  if p_from is null or p_to is null then return null; end if;
  if p_to <= p_from then return 0; end if;
  if p_calendar_id is not null then
    select is_24x7, true into v_is247, v_found from public.business_calendars where id = p_calendar_id;
  end if;
  if not v_found or v_is247 then return extract(epoch from (p_to - p_from)) / 60; end if;
  select coalesce(sum(extract(epoch from (w_end - w_start)) / 60), 0) into v_sum
    from app.sla_open_windows(p_calendar_id, p_from, p_to);
  return v_sum;
end $$;

-- ---- hash isi laporan (BR-043) ----------------------------------------------------------------
-- Hanya data "bermakna" (definisi [P], OQ-18): temuan, tindakan, rekomendasi, suku cadang, jasa, biaya tambahan disetujui.
create or replace function app.wo_content_hash(p_wo_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select encode(sha256(convert_to(jsonb_build_object(
    'findings', (select jsonb_build_object('d', diagnosis, 'a', action_taken, 'r', recommendation)
                 from public.wo_findings where wo_id = p_wo_id),
    'parts', (select coalesce(jsonb_agg(jsonb_build_array(item_id, qty) order by item_id, qty), '[]'::jsonb)
              from public.wo_part_usages where wo_id = p_wo_id and deleted_at is null),
    'labor', (select coalesce(jsonb_agg(jsonb_build_array(description, qty) order by description, qty), '[]'::jsonb)
              from public.wo_labor_lines where wo_id = p_wo_id and deleted_at is null),
    'extra', (select coalesce(jsonb_agg(jsonb_build_array(version_no, total) order by version_no), '[]'::jsonb)
              from public.extra_cost_approvals where wo_id = p_wo_id and status = 'APPROVED')
  )::text, 'UTF8')), 'hex')
$$;

-- ---- syarat penutupan (BR-040): kembalikan SEMUA kekurangan sekaligus -------------------------------
-- p_mode: 'SUBMIT' (T-16/T-18), 'SIGNOFF_REQUEST' (T-17: tanpa syarat tanda tangan), 'CLOSE' (T-19, BR-042)
create or replace function app.wo_submit_deficiencies(p_wo_id uuid, p_mode text default 'SUBMIT',
                                                      p_client_pending_ops int default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  w public.work_orders; d jsonb := '[]'::jsonb; v_cnt int; v_hash text; v_min int; r record; v_ok boolean;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if not found then
    return jsonb_build_array(jsonb_build_object('code', 'WO_NOT_FOUND'));
  end if;

  -- 1. checklist wajib
  select count(*) into v_cnt from public.wo_checklist_items
   where wo_id = p_wo_id and required and not is_na and value is null;
  if v_cnt > 0 then
    d := d || jsonb_build_array(jsonb_build_object('code', 'CHECKLIST_INCOMPLETE', 'missing', v_cnt,
          'items', (select jsonb_agg(label_snapshot order by seq) from public.wo_checklist_items
                     where wo_id = p_wo_id and required and not is_na and value is null)));
  end if;

  -- 2. foto wajib (hanya yang sudah UPLOADED)
  for r in select pr.kind, pr.min_count,
                  (select count(*) from public.wo_attachments a
                    where a.wo_id = p_wo_id and a.kind = pr.kind and a.upload_status = 'UPLOADED' and a.deleted_at is null) as have
             from public.wo_photo_requirements pr where pr.wo_id = p_wo_id loop
    if r.have < r.min_count then
      d := d || jsonb_build_array(jsonb_build_object('code', 'PHOTO_MISSING', 'kind', r.kind,
            'required', r.min_count, 'uploaded', r.have));
    end if;
  end loop;

  -- 3. check-in
  if not exists (select 1 from public.wo_visits where wo_id = p_wo_id and check_in_at is not null) then
    d := d || jsonb_build_array(jsonb_build_object('code', 'CHECK_IN_MISSING'));
  end if;

  -- 4. tanda tangan / persetujuan / pengecualian
  if p_mode in ('SUBMIT', 'CLOSE') then
    v_hash := app.wo_content_hash(p_wo_id);
    v_ok := exists (select 1 from public.wo_signatures s
                     where s.wo_id = p_wo_id and s.signer_type = 'CUSTOMER' and s.status = 'VALID' and s.content_hash = v_hash);
    if not v_ok then
      v_ok := w.closure_exception and coalesce(btrim(w.closure_exception_code), '') <> '';
      if v_ok and p_mode = 'CLOSE' and w.closure_exception_approved_by is null then
        d := d || jsonb_build_array(jsonb_build_object('code', 'CLOSURE_EXCEPTION_NOT_APPROVED'));
      end if;
    end if;
    if not v_ok then
      d := d || jsonb_build_array(jsonb_build_object('code', 'SIGNATURE_MISSING'));
    end if;
  end if;

  -- 5. tidak ada persetujuan biaya PENDING
  if exists (select 1 from public.extra_cost_approvals where wo_id = p_wo_id and status = 'PENDING') then
    d := d || jsonb_build_array(jsonb_build_object('code', 'EXTRA_COST_PENDING'));
  end if;

  -- 6. pemakaian suku cadang tercatat atau pernyataan "tidak ada"
  if not w.no_parts_used
     and not exists (select 1 from public.wo_part_usages where wo_id = p_wo_id and deleted_at is null) then
    d := d || jsonb_build_array(jsonb_build_object('code', 'PARTS_NOT_DECLARED'));
  end if;

  -- 7. temuan + tindakan
  v_min := coalesce(app.setting_int('closure.min_note_length'), 1);
  if not exists (select 1 from public.wo_findings f
                  where f.wo_id = p_wo_id
                    and char_length(btrim(coalesce(f.diagnosis, ''))) >= v_min
                    and char_length(btrim(coalesce(f.action_taken, ''))) >= v_min) then
    d := d || jsonb_build_array(jsonb_build_object('code', 'FINDINGS_INCOMPLETE', 'min_length', v_min));
  end if;

  -- 8. antrean sinkron
  if p_mode in ('SUBMIT', 'SIGNOFF_REQUEST') then
    if p_client_pending_ops is null then
      d := d || jsonb_build_array(jsonb_build_object('code', 'SYNC_STATE_UNKNOWN'));
    elsif p_client_pending_ops > 0 then
      d := d || jsonb_build_array(jsonb_build_object('code', 'SYNC_PENDING', 'client_pending_ops', p_client_pending_ops));
    end if;
  end if;
  if exists (select 1 from public.sync_operations where wo_id = p_wo_id and status = 'RECEIVED') then
    d := d || jsonb_build_array(jsonb_build_object('code', 'SYNC_UNAPPLIED'));
  end if;

  return d;
end $$;

-- ---- billing_type (BR-060) --------------------------------------------------------------------------
create or replace function app.determine_billing(p_customer_id uuid, p_asset_id uuid, p_service_type_id uuid, p_at timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text := coalesce(app.setting_text('default_timezone'), 'Asia/Jakarta');
  v_date date := (p_at at time zone v_tz)::date;
  v_contract uuid; v_ca uuid; a public.assets;
begin
  select c.id, ca.id into v_contract, v_ca
  from public.contracts c
  join public.contract_assets ca on ca.contract_id = c.id
  where c.customer_id = p_customer_id and c.status = 'ACTIVE'
    and v_date between c.start_date and c.end_date
    and ca.asset_id = p_asset_id and ca.service_type_id = p_service_type_id and ca.is_active
    and (ca.active_from is null or ca.active_from <= v_date)
    and (ca.active_to is null or ca.active_to >= v_date)
  order by c.start_date desc
  limit 1;
  if v_contract is not null then
    return jsonb_build_object('billing_type', 'COVERED_CONTRACT', 'contract_id', v_contract, 'contract_asset_id', v_ca);
  end if;

  select * into a from public.assets where id = p_asset_id;
  if a.warranty_start is not null and a.warranty_end is not null and v_date between a.warranty_start and a.warranty_end then
    return jsonb_build_object('billing_type', 'WARRANTY');   -- pengecualian garansi dinilai SPV (BR-063)
  end if;
  return jsonb_build_object('billing_type', 'BILLABLE');
end $$;

-- ---- SLA: hitung ulang tenggat & status dari kebijakan (BR-010/015/016) ---------------------------------
-- Dipanggil saat WO dibuat dan saat prioritas berubah. TODO: jeda yang sudah berlalu tidak dihitung ulang saat prioritas berubah.
create or replace function app.sla_recalculate(p_wo_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w public.work_orders; c public.contracts; pol public.sla_policies; ca public.contract_assets;
  v_set uuid; v_cal uuid; v_tz text; v_grace int; v_resp timestamptz; v_reso timestamptz;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if w.contract_id is not null then select * into c from public.contracts where id = w.contract_id; end if;
  v_set := coalesce(c.sla_policy_set_id, (select id from public.sla_policy_sets where is_default and is_active limit 1));
  v_cal := coalesce(c.calendar_id, (select id from public.business_calendars where is_default limit 1));
  v_tz  := coalesce((select timezone from public.business_calendars where id = v_cal),
                    app.setting_text('default_timezone'), 'Asia/Jakarta');
  if v_set is not null then
    select * into pol from public.sla_policies where policy_set_id = v_set and priority_code = w.priority_code;
  end if;

  if pol.id is null then
    update public.work_orders set sla_policy_set_id = v_set, sla_calendar_id = v_cal, policy_snapshot = null,
           response_due_at = null, resolution_due_at = null,
           response_sla_state = case when response_met_at is null then 'NOT_TRACKED' else response_sla_state end,
           resolution_sla_state = case when resolution_met_at is null then 'NOT_TRACKED' else resolution_sla_state end,
           next_sla_check_at = null
     where id = p_wo_id;
    return;
  end if;

  if w.type = 'PREVENTIVE' then
    select * into ca from public.contract_assets where id = w.contract_asset_id;
    v_grace := coalesce(ca.grace_days, app.setting_int('pm.grace_days'), 0);
    v_resp := null;
    v_reso := ((w.pm_due_date + v_grace + 1)::timestamp at time zone v_tz);   -- akhir hari jatuh tempo + toleransi (BR-016)
  else
    v_resp := app.sla_add_business_minutes(w.sla_clock_start_at, pol.response_minutes, v_cal);
    v_reso := app.sla_add_business_minutes(w.sla_clock_start_at, pol.resolution_minutes, v_cal);
  end if;

  update public.work_orders set
    sla_policy_set_id = v_set, sla_calendar_id = v_cal,
    policy_snapshot = to_jsonb(pol) || jsonb_build_object('timezone', v_tz, 'applied_at', now()),
    response_due_at = v_resp, resolution_due_at = v_reso,
    response_sla_state = case when response_met_at is not null then response_sla_state
                              when v_resp is null then 'NOT_TRACKED' else 'RUNNING' end,
    resolution_sla_state = case when resolution_met_at is not null then resolution_sla_state
                                when v_reso is null then 'NOT_TRACKED'
                                when sla_paused_at is not null then 'PAUSED' else 'RUNNING' end,
    next_sla_check_at = now()
  where id = p_wo_id;
end $$;

-- ---- checklist & syarat foto: salin template ke WO (snapshot) ------------------------------------------------
create or replace function app.instantiate_checklist(p_wo_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders; v_tpl uuid; v_ver int;
begin
  select * into w from public.work_orders where id = p_wo_id;
  select coalesce(st.default_checklist_template_id, ac.default_checklist_template_id)
    into v_tpl
    from public.service_types st
    left join public.assets a on a.id = w.asset_id
    left join public.asset_categories ac on ac.id = a.category_id
   where st.id = w.service_type_id;
  if v_tpl is null then return; end if;
  select version_no into v_ver from public.checklist_templates where id = v_tpl;

  update public.work_orders set checklist_template_id = v_tpl, checklist_template_version = v_ver where id = p_wo_id;
  insert into public.wo_checklist_items (wo_id, template_item_id, seq, label_snapshot, input_type, choices, required, photo_required)
  select p_wo_id, i.id, i.seq, i.label, i.input_type, i.choices, i.required, i.photo_required
    from public.checklist_template_items i where i.template_id = v_tpl
  on conflict (wo_id, seq) do nothing;
  insert into public.wo_photo_requirements (wo_id, kind, min_count)
  select p_wo_id, kind, min_count from public.photo_requirements where template_id = v_tpl
  on conflict (wo_id, kind) do nothing;
end $$;

-- ---- pembuatan WO (dipakai validasi permintaan, generator PM, rework) -------------------------------------------
-- Mengembalikan NULL bila bentrok unique PM (sudah ada WO untuk periode itu): idempotensi dijamin constraint DB.
create or replace function app.create_work_order(
  p_type public.wo_type, p_customer_id uuid, p_site_id uuid, p_asset_id uuid, p_service_type_id uuid,
  p_request_id uuid, p_contract_asset_id uuid, p_pm_period date, p_parent_wo_id uuid,
  p_priority_code text, p_estimate_total numeric, p_actor uuid,
  p_requested_at timestamptz default now(), p_billing public.billing_type default null,
  p_clock_start timestamptz default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_bill jsonb; v_billing public.billing_type; v_contract uuid; v_ca uuid; v_id uuid;
  v_prev text := coalesce(current_setting('app.tx_active', true), 'off');
begin
  if p_priority_code is null then
    raise exception 'WO006: priority wajib' using errcode = 'WO006';
  end if;
  if p_billing is not null then
    v_billing := p_billing;
    v_contract := (select contract_id from public.contract_assets ca join public.contracts c on c.id = ca.contract_id
                    where ca.id = p_contract_asset_id);
  else
    v_bill := app.determine_billing(p_customer_id, p_asset_id, p_service_type_id, p_requested_at);
    v_billing := (v_bill ->> 'billing_type')::public.billing_type;
    v_contract := nullif(v_bill ->> 'contract_id', '')::uuid;
    v_ca := nullif(v_bill ->> 'contract_asset_id', '')::uuid;
  end if;
  if p_type = 'PREVENTIVE' then
    v_contract := (select ca.contract_id from public.contract_assets ca where ca.id = p_contract_asset_id);
    v_ca := p_contract_asset_id;
  else
    v_ca := null;          -- contract_asset_id hanya untuk WO preventif (unik per periode)
  end if;

  perform set_config('app.tx_active', 'on', true);       -- izinkan INSERT status awal tanpa guard
  insert into public.work_orders as w (
    wo_number, type, customer_id, site_id, asset_id, service_type_id, request_id, contract_id, contract_asset_id,
    pm_period_key, pm_due_date, parent_wo_id, priority_code, status, billing_type, billing_status, estimate_total,
    requested_at, sla_clock_start_at, created_by)
  values (
    app.next_doc_number('WO'), p_type, p_customer_id, p_site_id, p_asset_id, p_service_type_id, p_request_id, v_contract, v_ca,
    p_pm_period, p_pm_period, p_parent_wo_id, p_priority_code, 'NEW', v_billing, 'NOT_BILLABLE', p_estimate_total,
    p_requested_at, coalesce(p_clock_start, now()), p_actor)
  on conflict (contract_asset_id, pm_period_key) where type = 'PREVENTIVE' do nothing
  returning w.id into v_id;
  if v_id is null then
    perform set_config('app.tx_active', v_prev, true);
    return null;
  end if;

  perform app.instantiate_checklist(v_id);
  perform app.sla_recalculate(v_id);
  perform set_config('app.tx_active', v_prev, true);
  return v_id;
end $$;


-- ===== MIGRATION 0009: trigger ===================================================
-- ---- guard WO: status hanya via wo_transition; WO final immutable (BR-044, FR-032) ---------
create or replace function app.tg_wo_before_update() returns trigger
language plpgsql as $$
declare
  v_allowed text[] := array['billing_status','billing_type','billing_override_reason',
                            'warranty_exception_reason','customer_note','updated_at','version'];
begin
  if new.status is distinct from old.status
     and coalesce(current_setting('app.tx_active', true), '') <> 'on' then
    raise exception 'WO001: status WO hanya boleh diubah lewat wo_transition()' using errcode = 'WO001';
  end if;
  if old.status in ('CLOSED','CANCELLED')
     and coalesce(current_setting('app.revision_mode', true), '') <> 'on'
     and (to_jsonb(new) - v_allowed) is distinct from (to_jsonb(old) - v_allowed) then
    raise exception 'IMM01: WO % sudah final; koreksi lewat mekanisme revisi', old.wo_number using errcode = 'IMM01';
  end if;
  return new;
end $$;
create trigger trg_wo_before_update before update on public.work_orders
  for each row execute function app.tg_wo_before_update();

-- ---- riwayat status: terisi otomatis oleh trigger (BR-002) -------------------------------------
create or replace function app.tg_wo_status_history() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.wo_status_history (wo_id, from_status, to_status, action, actor_id, actor_roles)
    values (new.id, null, new.status, 'CREATE', auth.uid(),
            coalesce(nullif(current_setting('app.actor_role', true), ''), case when app.is_system() then 'SYSTEM' end));
  elsif new.status is distinct from old.status or coalesce(current_setting('app.history_force', true), '') = 'on' then
    insert into public.wo_status_history (wo_id, from_status, to_status, action, actor_id, actor_roles,
                                          reason_code, reason, customer_note, op_id)
    values (new.id, old.status, new.status, nullif(current_setting('app.tx_action', true), ''), auth.uid(),
            coalesce(nullif(current_setting('app.actor_role', true), ''), case when app.is_system() then 'SYSTEM' end),
            nullif(current_setting('app.tx_reason_code', true), ''), nullif(current_setting('app.tx_reason', true), ''),
            nullif(current_setting('app.tx_customer_note', true), ''),
            nullif(current_setting('app.tx_op_id', true), '')::uuid);
  end if;
  return null;
end $$;
create trigger trg_wo_status_history after insert or update of status on public.work_orders
  for each row execute function app.tg_wo_status_history();

-- ---- tabel anak WO: tolak perubahan bila WO final (kecuali mode revisi) ---------------------------
create or replace function app.tg_wo_child_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_wo uuid; v_status public.wo_status;
begin
  v_wo := case when tg_op = 'DELETE' then old.wo_id else new.wo_id end;
  select status into v_status from public.work_orders where id = v_wo;
  if v_status in ('CLOSED','CANCELLED') and coalesce(current_setting('app.revision_mode', true), '') <> 'on' then
    raise exception 'IMM01: WO sudah final (%); data lapangan baru ditolak (CONFLICT_*)', v_status using errcode = 'IMM01';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
do $$
declare t text;
begin
  foreach t in array array['wo_checklist_items','wo_findings','wo_attachments','wo_signatures','wo_labor_lines','wo_part_usages'] loop
    execute format('create trigger trg_wo_child_guard before insert or update or delete on public.%I
                    for each row execute function app.tg_wo_child_guard()', t);
  end loop;
end $$;

-- ---- append-only ------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['audit_logs','access_logs','wo_status_history','stock_movements','user_consents'] loop
    execute format('create trigger trg_append_only before update or delete on public.%I
                    for each row execute function app.tg_forbid_mutation()', t);
    execute format('create trigger trg_no_truncate before truncate on public.%I
                    for each statement execute function app.tg_forbid_mutation()', t);
  end loop;
end $$;

-- ---- updated_at + version pada semua tabel mutable ----------------------------------------------------
do $$
declare r record;
begin
  for r in
    select c.table_name
      from information_schema.columns c
      join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
     where c.table_schema = 'public' and t.table_type = 'BASE TABLE' and c.column_name = 'version'
       and exists (select 1 from information_schema.columns c2
                    where c2.table_schema = 'public' and c2.table_name = c.table_name and c2.column_name = 'updated_at')
  loop
    execute format('create trigger trg_touch before update on public.%I for each row execute function app.tg_touch()', r.table_name);
  end loop;
end $$;

-- ---- audit log (BR-070) -----------------------------------------------------------------------------------
do $$
declare
  t text;
  tbls text[] := array['profiles','user_roles','technicians','customers','customer_users','customer_sites','assets',
    'service_types','items','service_items','contracts','contract_assets','pm_periods','sla_policy_sets','sla_policies',
    'escalation_rules','business_calendars','calendar_hours','calendar_holidays','app_settings',
    'service_requests','wo_assignments','wo_visits','wo_findings','wo_checklist_items','wo_attachments','wo_signatures',
    'wo_labor_lines','wo_part_usages','extra_cost_approvals','service_reports','part_requests','part_returns',
    'parts_variances','ratings','complaints','invoices','payments'];
begin
  foreach t in array tbls loop
    execute format('create trigger trg_audit after insert or update or delete on public.%I
                    for each row execute function app.tg_audit(%L)', t, '');
  end loop;
  -- work_orders: abaikan kolom SLA yang berubah oleh job tiap menit agar log tidak berisik
  create trigger trg_audit after insert or update or delete on public.work_orders
    for each row execute function app.tg_audit('next_sla_check_at,response_sla_state,resolution_sla_state');
end $$;

-- ---- profil otomatis untuk user baru Supabase Auth ---------------------------------------------------------------
create or replace function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- raw_user_meta_data dikendalikan user: HANYA untuk nama tampilan, tidak pernah untuk otorisasi.
  insert into public.profiles (user_id, full_name)
  values (new.id, coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
                           nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'User'))
  on conflict (user_id) do nothing;
  return new;
end $$;
create trigger trg_on_auth_user_created after insert on auth.users
  for each row execute function app.handle_new_user();

-- ---- peran: CUSTOMER eksklusif dari peran staf ---------------------------------------------------------------------
create or replace function app.tg_user_roles_exclusive() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (new.role = 'CUSTOMER' and exists (select 1 from public.user_roles where user_id = new.user_id and role <> 'CUSTOMER'))
     or (new.role <> 'CUSTOMER' and exists (select 1 from public.user_roles where user_id = new.user_id and role = 'CUSTOMER')) then
    raise exception 'WO006: peran CUSTOMER tidak boleh digabung dengan peran staf' using errcode = 'WO006';
  end if;
  return new;
end $$;
create trigger trg_user_roles_exclusive before insert on public.user_roles
  for each row execute function app.tg_user_roles_exclusive();

-- ---- kontrak: aset harus milik pelanggan kontrak; perubahan kontrak membatalkan WO PM mendatang (BR-026) ----------------------
create or replace function app.tg_contract_asset_check() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.contracts c join public.assets a on a.customer_id = c.customer_id
                  where c.id = new.contract_id and a.id = new.asset_id) then
    raise exception 'WO006: aset bukan milik pelanggan kontrak' using errcode = 'WO006';
  end if;
  return new;
end $$;
create trigger trg_contract_asset_check before insert or update of contract_id, asset_id on public.contract_assets
  for each row execute function app.tg_contract_asset_check();

create or replace function app.tg_contract_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record; v_cutoff date;
begin
  if (new.status in ('TERMINATED','EXPIRED') and old.status is distinct from new.status) or new.end_date < old.end_date then
    v_cutoff := case when new.status in ('TERMINATED','EXPIRED') then least(current_date, new.end_date) else new.end_date end;
    for r in select w.id, w.version, w.pm_period_key from public.work_orders w
              where w.contract_id = new.id and w.type = 'PREVENTIVE' and w.status = 'NEW' and w.pm_period_key > v_cutoff loop
      perform app.apply_wo_transition(r.id, 'CANCEL', null, '{}'::public.app_role[], true, null, null,
                                      'kontrak berubah', 'CONTRACT_CHANGED', '{}'::jsonb);
      update public.pm_periods set status = 'SKIPPED', skip_reason = 'kontrak berubah'
       where wo_id = r.id and status = 'GENERATED';
    end loop;
  end if;
  return null;
end $$;
create trigger trg_contract_changed after update of status, end_date on public.contracts
  for each row execute function app.tg_contract_changed();

-- ---- permintaan servis ---------------------------------------------------------------------------------------------------
create or replace function app.tg_sr_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_dup uuid; v_win int;
begin
  new.request_no := app.next_doc_number('REQ');
  new.created_by := coalesce(new.created_by, auth.uid());
  if new.created_by is null then
    raise exception 'WO006: created_by wajib' using errcode = 'WO006';
  end if;
  new.status := 'SUBMITTED';
  new.decision_by := null; new.decision_source := null; new.decided_at := null;
  new.decision_reason := null; new.needs_info_note := null;
  if new.site_id is null and new.asset_id is not null then
    select a.site_id into new.site_id from public.assets a where a.id = new.asset_id and a.customer_id = new.customer_id;
  end if;

  -- BR-072: batas laju per pelanggan (pemesanan lewat PWA). Retry idempoten tidak dihitung.
  if new.channel = 'PWA'
     and not (new.client_request_id is not null and exists (
              select 1 from public.service_requests s
               where s.customer_id = new.customer_id and s.client_request_id = new.client_request_id)) then
    if not app.rate_limit_hit('sr:' || new.customer_id::text,
                              app.setting_int('rate_limit.service_request.max'),
                              app.setting_int('rate_limit.service_request.window_seconds')) then
      raise exception 'RL001: batas pemesanan terlampaui' using errcode = 'RL001';
    end if;
  end if;

  -- BR-071: peringatan duplikat (bukan penolakan)
  v_win := app.setting_int('duplicate.window_minutes');
  if v_win is not null and new.asset_id is not null then
    select s.id into v_dup
      from public.service_requests s
      left join public.work_orders w on w.request_id = s.id
     where s.customer_id = new.customer_id and s.asset_id = new.asset_id
       and s.problem_type_id is not distinct from new.problem_type_id
       and s.created_at >= now() - make_interval(mins => v_win)
       and s.status in ('SUBMITTED','NEEDS_INFO','CONVERTED')
       and (s.status <> 'CONVERTED' or w.status not in ('CLOSED','CANCELLED'))
     order by s.created_at desc limit 1;
    new.duplicate_of := v_dup;
  end if;
  return new;
end $$;
create trigger trg_sr_before_insert before insert on public.service_requests
  for each row execute function app.tg_sr_before_insert();

create or replace function app.tg_sr_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform app.notify_customer(new.customer_id, 'request.received', null,
            jsonb_build_object('request_id', new.id, 'request_no', new.request_no), 'req-recv:' || new.id::text);
  perform app.notify_role('ADMIN_CS', 'request.new', null,
            jsonb_build_object('request_id', new.id, 'request_no', new.request_no, 'duplicate_of', new.duplicate_of),
            'req-new:' || new.id::text);
  if exists (select 1 from public.customers c where c.id = new.customer_id and c.auto_approve) then
    perform app.try_auto_approve(new.id);                -- SP-02 / FR-023
  end if;
  return null;
end $$;
create trigger trg_sr_after_insert after insert on public.service_requests
  for each row execute function app.tg_sr_after_insert();

create or replace function app.tg_sr_before_update() returns trigger
language plpgsql as $$
declare
  v_safe text[] := array['description','preferred_start','preferred_end','status','problem_type_id','site_id','asset_id','updated_at','version'];
begin
  if coalesce(current_setting('app.tx_active', true), '') = 'on' then return new; end if;   -- request_decide()
  if old.status in ('REJECTED','CONVERTED','CANCELLED_BY_CUSTOMER') then
    raise exception 'IMM01: permintaan % sudah final', old.request_no using errcode = 'IMM01';
  end if;
  if new.status is distinct from old.status
     and not ((old.status in ('SUBMITTED','NEEDS_INFO') and new.status = 'CANCELLED_BY_CUSTOMER')
              or (old.status = 'NEEDS_INFO' and new.status = 'SUBMITTED')) then
    raise exception 'WO001: perubahan status permintaan % -> % tidak diizinkan', old.status, new.status using errcode = 'WO001';
  end if;
  if (to_jsonb(new) - v_safe) is distinct from (to_jsonb(old) - v_safe) then
    raise exception 'WO002: kolom keputusan/identitas tidak boleh diubah langsung' using errcode = 'WO002';
  end if;
  return new;
end $$;
create trigger trg_sr_before_update before update on public.service_requests
  for each row execute function app.tg_sr_before_update();

create or replace function app.tg_sr_after_update() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status and coalesce(current_setting('app.tx_active', true), '') <> 'on' then
    perform app.notify_role('ADMIN_CS',
              case when new.status = 'CANCELLED_BY_CUSTOMER' then 'request.cancelled' else 'request.info_provided' end,
              null, jsonb_build_object('request_id', new.id, 'request_no', new.request_no),
              'req-upd:' || new.id::text || ':' || new.status::text);
  end if;
  return null;
end $$;
create trigger trg_sr_after_update after update of status on public.service_requests
  for each row execute function app.tg_sr_after_update();

-- ---- penilaian & komplain (BR-074, T-25) ---------------------------------------------------------------------------------------
create or replace function app.tg_feedback_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders; v_days int;
begin
  select * into w from public.work_orders where id = new.wo_id;
  if not found or (not app.is_system() and not (w.customer_id = any (app.my_customer_ids()))) then
    raise exception 'WO005: tidak ditemukan' using errcode = 'WO005';
  end if;
  if w.status <> 'CLOSED' then
    raise exception 'WO001: hanya WO berstatus CLOSED yang dapat dinilai/dikomplain' using errcode = 'WO001';
  end if;
  new.customer_id := w.customer_id;
  new.customer_user_id := coalesce(auth.uid(), new.customer_user_id);
  if tg_table_name = 'complaints' then
    v_days := app.setting_int('rework.claim_window_days');
    if v_days is not null and w.closed_at < now() - make_interval(days => v_days) then
      raise exception 'WO001: di luar jendela klaim' using errcode = 'WO001';
    end if;
  end if;
  return new;
end $$;
create trigger trg_ratings_before_insert before insert on public.ratings
  for each row execute function app.tg_feedback_before_insert();
create trigger trg_complaints_before_insert before insert on public.complaints
  for each row execute function app.tg_feedback_before_insert();

-- ---- tanda tangan: hash selalu dihitung server (BR-043, NFR-A5) -------------------------------------------------------------------
create or replace function app.tg_signature_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.content_hash := app.wo_content_hash(new.wo_id);
  new.status := 'VALID';
  new.signed_at := now();
  return new;
end $$;
create trigger trg_signature_before_insert before insert on public.wo_signatures
  for each row execute function app.tg_signature_before_insert();

-- ---- checklist / temuan: jejak pengisi ----------------------------------------------------------------------------------------------
create or replace function app.tg_checklist_before_update() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (new.value, new.is_na, new.na_reason) is distinct from (old.value, old.is_na, old.na_reason) then
    new.filled_by := coalesce(auth.uid(), new.filled_by);
    new.filled_at := now();
  end if;
  return new;
end $$;
create trigger trg_checklist_before_update before update on public.wo_checklist_items
  for each row execute function app.tg_checklist_before_update();

create or replace function app.tg_findings_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.updated_by := auth.uid();
  return new;
end $$;
create trigger trg_findings_before_write before insert or update on public.wo_findings
  for each row execute function app.tg_findings_before_write();

-- ---- baris jasa & suku cadang: snapshot harga, billable, larangan biaya tambahan tanpa persetujuan (BR-052/061/064/067) ---------------
create or replace function app.line_billable(p_wo_id uuid, p_kind text, p_is_extra boolean) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare w public.work_orders; c public.contracts; a public.assets;
begin
  if p_is_extra then return true; end if;
  select * into w from public.work_orders where id = p_wo_id;
  if w.billing_type = 'BILLABLE' then return true; end if;
  if w.billing_type = 'COVERED_CONTRACT' then
    select * into c from public.contracts where id = w.contract_id;
    return not (case when p_kind = 'LABOR' then coalesce(c.covers_labor, false) else coalesce(c.covers_parts, false) end);
  end if;
  if w.billing_type = 'WARRANTY' then
    select * into a from public.assets where id = w.asset_id;
    return not (case when p_kind = 'LABOR' then a.warranty_covers_labor else a.warranty_covers_parts end);
  end if;
  return false;                                              -- WARRANTY_WORK
end $$;

create or replace function app.assert_extra_approved(p_wo_id uuid, p_approval_id uuid, p_emergency boolean) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_emergency then return; end if;
  if p_approval_id is null or not exists (
       select 1 from public.extra_cost_approvals a
        where a.id = p_approval_id and a.wo_id = p_wo_id and a.status = 'APPROVED') then
    raise exception 'WO003: biaya tambahan hanya boleh dicatat dengan persetujuan APPROVED (BR-052)'
      using errcode = 'WO003', detail = '{"code":"EXTRA_COST_NOT_APPROVED"}';
  end if;
end $$;

create or replace function app.tg_labor_before() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_si public.service_items;
begin
  if tg_op = 'UPDATE' then
    if (new.wo_id, new.qty, new.description, new.is_extra, new.extra_approval_id)
       is distinct from (old.wo_id, old.qty, old.description, old.is_extra, old.extra_approval_id) then
      raise exception 'IMM01: ubah baris jasa lewat tombstone (deleted_at) + baris baru' using errcode = 'IMM01';
    end if;
    return new;
  end if;
  new.created_by := coalesce(new.created_by, auth.uid());
  if new.service_item_id is not null then
    select * into v_si from public.service_items where id = new.service_item_id;
    new.unit_price_snapshot := coalesce(new.unit_price_snapshot, v_si.unit_price);
    new.unit_cost_snapshot := coalesce(new.unit_cost_snapshot, v_si.unit_cost);
  end if;
  if new.billable is null then new.billable := app.line_billable(new.wo_id, 'LABOR', new.is_extra); end if;
  if new.is_extra then perform app.assert_extra_approved(new.wo_id, new.extra_approval_id, new.emergency); end if;
  return new;
end $$;
create trigger trg_labor_before before insert or update on public.wo_labor_lines
  for each row execute function app.tg_labor_before();

create or replace function app.tg_usage_before() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_item public.items; v_bal numeric;
begin
  if tg_op = 'UPDATE' then
    if (new.wo_id, new.item_id, new.qty, new.technician_id, new.source_location_id, new.is_extra)
       is distinct from (old.wo_id, old.item_id, old.qty, old.technician_id, old.source_location_id, old.is_extra) then
      raise exception 'IMM01: ubah pemakaian lewat tombstone (deleted_at) + baris baru' using errcode = 'IMM01';
    end if;
    return new;
  end if;
  select * into v_item from public.items where id = new.item_id;
  new.technician_id := coalesce(new.technician_id, app.my_technician_id());
  if new.technician_id is null then
    raise exception 'WO006: technician_id wajib' using errcode = 'WO006';
  end if;
  new.created_by := coalesce(new.created_by, auth.uid());
  new.unit_price_snapshot := coalesce(new.unit_price_snapshot, v_item.unit_price);
  new.unit_cost_snapshot := coalesce(new.unit_cost_snapshot, v_item.unit_cost);
  if new.billable is null then new.billable := app.line_billable(new.wo_id, 'PART', new.is_extra); end if;
  if new.is_extra then perform app.assert_extra_approved(new.wo_id, new.extra_approval_id, new.emergency); end if;

  if v_item.tracking_mode = 'PER_WO' then
    if new.source_location_id is null then
      select sl.id into new.source_location_id from public.stock_locations sl
       where sl.technician_id = new.technician_id and sl.type = 'TECHNICIAN' and sl.is_active;
    end if;
    select sb.on_hand into v_bal from public.stock_balances sb
     where sb.item_id = new.item_id and sb.location_id = new.source_location_id;
    if (new.source_location_id is null or coalesce(v_bal, 0) < new.qty) then
      if app.setting_bool('stock.allow_unsourced_usage', false) then      -- BR-035 / OQ-17
        new.unsourced := true; new.source_location_id := null;
      else
        raise exception 'STK01: stok teknisi tidak cukup / lokasi sumber tidak ada (item %)', v_item.sku using errcode = 'STK01';
      end if;
    end if;
  end if;
  return new;
end $$;
create trigger trg_usage_before before insert or update on public.wo_part_usages
  for each row execute function app.tg_usage_before();

create or replace function app.tg_usage_after() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_mode public.item_tracking_mode;
begin
  select tracking_mode into v_mode from public.items where id = new.item_id;
  if new.unsourced or v_mode = 'BULK' then return null; end if;
  if tg_op = 'INSERT' then
    insert into public.stock_movements (item_id, from_location_id, qty, type, wo_id, ref_type, ref_id, actor_id)
    values (new.item_id, new.source_location_id, new.qty, 'CONSUME_ON_WO', new.wo_id, 'WO_PART_USAGE', new.id, auth.uid());
  elsif old.deleted_at is null and new.deleted_at is not null then          -- tombstone => mutasi koreksi
    insert into public.stock_movements (item_id, to_location_id, qty, type, wo_id, ref_type, ref_id, actor_id, note)
    values (new.item_id, new.source_location_id, new.qty, 'ADJUSTMENT', new.wo_id, 'USAGE_REVERSAL', new.id, auth.uid(),
            'pembatalan pemakaian');
  end if;
  return null;
end $$;
create trigger trg_usage_after after insert or update of deleted_at on public.wo_part_usages
  for each row execute function app.tg_usage_after();

-- ---- saldo stok dari buku besar (BR-030, BR-036) -------------------------------------------------------------------------------------
create or replace function app.tg_stock_apply() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  r record; v_on numeric; v_min numeric; v_notified boolean; v_type public.stock_location_type; v_sku text;
begin
  for r in
    select loc, delta from (values (new.from_location_id, -new.qty), (new.to_location_id, new.qty)) v(loc, delta)
     where loc is not null order by loc                       -- urutan kunci konsisten (cegah deadlock)
  loop
    insert into public.stock_balances (item_id, location_id, on_hand) values (new.item_id, r.loc, 0)
    on conflict (item_id, location_id) do nothing;
    select on_hand into v_on from public.stock_balances
     where item_id = new.item_id and location_id = r.loc for update;
    if r.delta < 0 and v_on + r.delta < 0 then
      select sku into v_sku from public.items where id = new.item_id;
      raise exception 'STK01: stok tidak cukup untuk % (tersedia %, diminta %)', v_sku, v_on, -r.delta
        using errcode = 'STK01';
    end if;
    update public.stock_balances set on_hand = on_hand + r.delta, updated_at = now()
     where item_id = new.item_id and location_id = r.loc;

    -- peringatan stok minimum: satu kali per transisi turun melewati batas (BR-036)
    select sb.on_hand, sb.below_min_notified, i.min_stock, sl.type
      into v_on, v_notified, v_min, v_type
      from public.stock_balances sb
      join public.items i on i.id = sb.item_id
      join public.stock_locations sl on sl.id = sb.location_id
     where sb.item_id = new.item_id and sb.location_id = r.loc;
    if v_type = 'WAREHOUSE' and v_min is not null then
      if v_on <= v_min and not v_notified then
        update public.stock_balances set below_min_notified = true where item_id = new.item_id and location_id = r.loc;
        perform app.notify_role('WAREHOUSE', 'stock.below_min', null,
                  jsonb_build_object('item_id', new.item_id, 'location_id', r.loc, 'on_hand', v_on, 'min_stock', v_min),
                  'stockmin:' || new.item_id::text || ':' || r.loc::text || ':' || new.id::text);
      elsif v_on > v_min and v_notified then
        update public.stock_balances set below_min_notified = false where item_id = new.item_id and location_id = r.loc;
      end if;
    end if;
  end loop;
  return null;
end $$;
create trigger trg_stock_apply after insert on public.stock_movements
  for each row execute function app.tg_stock_apply();


-- ===== MIGRATION 0010: fungsi bisnis ===============================================
-- ---- 0010a: helper SLA / penugasan / pembatalan / laporan --------------------------------

-- Tandai respons/penyelesaian terpenuhi (BR-013).
create or replace function app.sla_mark_met(p_wo_id uuid, p_kind text, p_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_kind = 'RESPONSE' then
    update public.work_orders w set response_met_at = p_at,
           response_sla_state = case when w.response_due_at is not null and p_at > w.response_due_at
                                     then 'MET_LATE'::public.sla_state else 'MET'::public.sla_state end
     where w.id = p_wo_id and w.response_met_at is null;
  else
    update public.work_orders w set resolution_met_at = p_at, sla_paused_at = null,
           resolution_sla_state = case when w.resolution_due_at is not null and p_at > w.resolution_due_at
                                       then 'MET_LATE'::public.sla_state else 'MET'::public.sla_state end
     where w.id = p_wo_id and w.resolution_met_at is null;
    update public.sla_pauses set resumed_at = p_at where wo_id = p_wo_id and resumed_at is null;
  end if;
end $$;

-- Jeda timer penyelesaian (BR-012). Tidak berlaku untuk WO preventif (jendela tanggal, BR-016).
create or replace function app.sla_pause(p_wo_id uuid, p_reason text, p_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders; v_rem numeric;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if w.type = 'PREVENTIVE' or w.sla_paused_at is not null or w.resolution_due_at is null or w.resolution_met_at is not null then
    return;
  end if;
  v_rem := app.sla_business_minutes_between(p_at, w.resolution_due_at, w.sla_calendar_id);
  insert into public.sla_pauses (wo_id, reason, paused_at, remaining_minutes) values (p_wo_id, p_reason, p_at, v_rem);
  update public.work_orders set sla_paused_at = p_at, resolution_sla_state = 'PAUSED' where id = p_wo_id;
end $$;

create or replace function app.sla_resume(p_wo_id uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders; pz public.sla_pauses;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if w.sla_paused_at is null then return; end if;
  select * into pz from public.sla_pauses where wo_id = p_wo_id and resumed_at is null order by paused_at desc limit 1;
  update public.sla_pauses set resumed_at = p_at where id = pz.id;
  update public.work_orders set sla_paused_at = null, resolution_sla_state = 'RUNNING',
         resolution_due_at = app.sla_add_business_minutes(p_at, pz.remaining_minutes, w.sla_calendar_id),
         next_sla_check_at = p_at
   where id = p_wo_id;
end $$;

-- Peringatan lunak penugasan (FR-043): keahlian & bentrok jadwal. Mengembalikan array jsonb.
create or replace function app.assignment_warnings(p_tech uuid, p_service_type uuid, p_start timestamptz,
                                                   p_end timestamptz, p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_warn jsonb := '[]'::jsonb; v_skill uuid;
begin
  select skill_id into v_skill from public.service_types where id = p_service_type;
  if v_skill is not null and not exists (select 1 from public.technician_skills ts
                                          where ts.technician_id = p_tech and ts.skill_id = v_skill) then
    v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'SKILL_MISMATCH'));
  end if;
  if p_start is not null and exists (
       select 1 from public.wo_assignments a join public.work_orders o on o.id = a.wo_id
        where a.technician_id = p_tech and a.role = 'LEAD' and a.status in ('ASSIGNED','ACCEPTED')
          and o.id <> p_wo and o.scheduled_start is not null
          and tstzrange(o.scheduled_start, coalesce(o.scheduled_end, o.scheduled_start + interval '1 minute'))
              && tstzrange(p_start, coalesce(p_end, p_start + interval '1 minute'))) then
    v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'SCHEDULE_OVERLAP'));
  end if;
  return v_warn;
end $$;

-- Snapshot isi laporan servis (tanpa HPP/biaya internal/catatan internal) (FR-140/141).
create or replace function app.build_report_snapshot(p_wo_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'wo', jsonb_build_object('wo_number', w.wo_number, 'type', w.type, 'priority', w.priority_code,
            'requested_at', w.requested_at, 'scheduled_start', w.scheduled_start, 'scheduled_end', w.scheduled_end,
            'started_at', w.started_at, 'submitted_at', w.submitted_at, 'closed_at', w.closed_at, 'outcome', w.outcome),
    'customer', jsonb_build_object('name', c.name),
    'site', (select jsonb_build_object('name', s.name, 'address', s.address) from public.customer_sites s where s.id = w.site_id),
    'asset', jsonb_build_object('asset_code', a.asset_code, 'serial_no', a.serial_no, 'brand', a.brand, 'model', a.model),
    'technician', (select p.full_name from public.wo_assignments x
                     join public.technicians t on t.id = x.technician_id
                     join public.profiles p on p.user_id = t.user_id
                    where x.wo_id = w.id and x.role = 'LEAD' and x.status in ('ACCEPTED','COMPLETED')
                    order by x.assigned_at desc limit 1),
    'findings', (select jsonb_build_object('diagnosis', f.diagnosis, 'action_taken', f.action_taken,
                         'recommendation', f.recommendation) from public.wo_findings f where f.wo_id = w.id),
    'checklist', (select coalesce(jsonb_agg(jsonb_build_object('seq', i.seq, 'label', i.label_snapshot, 'value', i.value,
                         'is_na', i.is_na, 'na_reason', i.na_reason) order by i.seq), '[]'::jsonb)
                    from public.wo_checklist_items i where i.wo_id = w.id),
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'path', x.storage_path, 'taken_at', x.taken_at)
                         order by x.taken_at), '[]'::jsonb)
                 from public.wo_attachments x
                where x.wo_id = w.id and x.deleted_at is null and x.upload_status = 'UPLOADED'
                  and x.kind in ('BEFORE','AFTER','FINDING')),
    'parts', (select coalesce(jsonb_agg(jsonb_build_object('sku', it.sku, 'name', it.name, 'qty', u.qty, 'uom', it.uom,
                         'billable', u.billable)), '[]'::jsonb)
                from public.wo_part_usages u join public.items it on it.id = u.item_id
               where u.wo_id = w.id and u.deleted_at is null),
    'labor', (select coalesce(jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty,
                         'billable', l.billable)), '[]'::jsonb)
                from public.wo_labor_lines l where l.wo_id = w.id and l.deleted_at is null),
    'signatures', (select coalesce(jsonb_agg(jsonb_build_object('signer_name', g.signer_name, 'signed_at', g.signed_at,
                         'path', g.storage_path, 'via', g.signed_via)), '[]'::jsonb)
                     from public.wo_signatures g where g.wo_id = w.id and g.status = 'VALID'),
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('check_in_at', v.check_in_at, 'check_out_at', v.check_out_at)
                         order by v.check_in_at), '[]'::jsonb)
                 from public.wo_visits v where v.wo_id = w.id),
    'closure_exception', jsonb_build_object('flag', w.closure_exception, 'code', w.closure_exception_code,
                         'note', w.closure_exception_note)
  )
  from public.work_orders w
  join public.customers c on c.id = w.customer_id
  join public.assets a on a.id = w.asset_id
  where w.id = p_wo_id
$$;

-- Efek pembatalan (T-22/T-23): tutup penugasan, persetujuan, permintaan suku cadang; PM periode dicatat.
create or replace function app.wo_cancel_effects(p_wo_id uuid, p_code text, p_reason text, p_by uuid, p_now timestamptz)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.notify_wo_technicians(p_wo_id, 'wo.cancelled', jsonb_build_object('reason', p_reason), 'cancel-tech:' || p_wo_id::text);
  update public.wo_assignments set status = 'CANCELLED', ended_at = p_now
   where wo_id = p_wo_id and status in ('ASSIGNED','ACCEPTED');
  update public.wo_visits set check_out_at = p_now, auto_checked_out = true,
         result = coalesce(result, 'FAILED_OTHER'), note = coalesce(note, 'WO dibatalkan')
   where wo_id = p_wo_id and check_in_at is not null and check_out_at is null;
  update public.extra_cost_approvals set status = 'SUPERSEDED' where wo_id = p_wo_id and status = 'PENDING';
  update public.part_requests set status = 'CANCELLED' where wo_id = p_wo_id and status in ('REQUESTED','APPROVED','PARTIALLY_ISSUED');
  update public.sla_pauses set resumed_at = p_now where wo_id = p_wo_id and resumed_at is null;
  update public.work_orders set cancelled_at = p_now, cancel_reason_code = p_code, cancel_reason = p_reason,
         sla_paused_at = null
   where id = p_wo_id;
  update public.pm_periods set status = case when p_code = 'CONTRACT_CHANGED' then 'SKIPPED' else 'MISSED' end::public.pm_period_status,
         missed_at = case when p_code = 'CONTRACT_CHANGED' then missed_at else p_now end,
         skip_reason = case when p_code = 'CONTRACT_CHANGED' then p_reason else skip_reason end
   where wo_id = p_wo_id and status = 'GENERATED';
  perform app.refresh_parts_variances(p_wo_id, false);          -- BR-037: barang diserahkan jadi selisih sampai kembali
end $$;

-- ---- 0010b: inti transisi status WO (T-02..T-27) ---------------------------------------------
-- Satu-satunya jalan mengubah work_orders.status. Memvalidasi: versi, peran, guard per transisi;
-- menulis riwayat (trigger), audit (trigger), notifikasi, SLA. Idempoten terhadap p_op_id.
create or replace function app.apply_wo_transition(
  p_wo_id uuid, p_action text, p_actor_id uuid, p_actor_roles public.app_role[], p_is_system boolean,
  p_expected_version int, p_op_id uuid, p_reason text, p_reason_code text, p_payload jsonb default '{}'::jsonb,
  p_now timestamptz default now()
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  w public.work_orders; t public.wo_transitions;
  v_pl jsonb := coalesce(p_payload, '{}'::jsonb);
  v_eff public.app_role[]; v_tech uuid; v_lead public.wo_assignments; v_ok boolean;
  v_def jsonb; v_warn jsonb := '[]'::jsonb; v_new_tech uuid; v_n int; v_th int;
  v_ap public.extra_cost_approvals; v_tol int; v_sched date; v_today date; v_visit uuid;
  v_exc text; v_outcome public.wo_outcome; v_rev int; v_snap jsonb; v_has_billable boolean;
  v_ev text; v_tz text := coalesce(app.setting_text('default_timezone'), 'Asia/Jakarta');
  v_force boolean := false; v_to public.wo_status; v_expect public.approval_status;
  v_prev text := coalesce(current_setting('app.tx_active', true), 'off');
begin
  select * into w from public.work_orders where id = p_wo_id for update;
  if not found then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;

  -- (d) replay idempoten
  if p_op_id is not null and exists (select 1 from public.wo_status_history h where h.wo_id = p_wo_id and h.op_id = p_op_id) then
    return jsonb_build_object('status', w.status, 'version', w.version, 'replayed', true);
  end if;

  select * into t from public.wo_transitions where action = p_action and from_status = w.status;
  if not found then
    raise exception 'WO001: aksi % tidak diizinkan dari status %', p_action, w.status using errcode = 'WO001',
      detail = jsonb_build_object('action', p_action, 'from_status', w.status)::text;
  end if;
  v_to := t.to_status;

  -- peran
  if p_is_system then
    if not t.allow_system then
      raise exception 'WO002: aksi % tidak boleh dilakukan sistem', p_action using errcode = 'WO002';
    end if;
  else
    select coalesce(array_agg(r), '{}'::public.app_role[]) into v_eff
      from unnest(p_actor_roles) r where r = any (t.allowed_roles);
    if cardinality(v_eff) = 0 then
      raise exception 'WO002: peran tidak berhak untuk aksi %', p_action using errcode = 'WO002';
    end if;
    if v_eff = array['TECHNICIAN']::public.app_role[] then          -- teknisi hanya untuk WO yang ditugaskan
      v_tech := app.my_technician_id();
      if v_tech is null or not exists (select 1 from public.wo_assignments a
            where a.wo_id = p_wo_id and a.technician_id = v_tech and a.role = 'LEAD' and a.status in ('ASSIGNED','ACCEPTED')) then
        raise exception 'WO002: bukan teknisi yang ditugaskan' using errcode = 'WO002';
      end if;
    end if;
  end if;

  if not p_is_system and p_expected_version is null then
    raise exception 'WO004: expected_version wajib' using errcode = 'WO004';
  end if;
  if p_expected_version is not null and w.version <> p_expected_version then
    raise exception 'WO004: konflik versi (klien %, server %)', p_expected_version, w.version using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;

  if t.requires_reason and coalesce(btrim(p_reason), '') = '' then
    raise exception 'WO003: alasan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;

  perform set_config('app.tx_active', 'on', true);
  perform set_config('app.tx_action', p_action, true);
  perform set_config('app.tx_reason', coalesce(p_reason, ''), true);
  perform set_config('app.tx_reason_code', coalesce(p_reason_code, ''), true);
  perform set_config('app.tx_customer_note', coalesce(v_pl ->> 'customer_note', ''), true);
  perform set_config('app.tx_op_id', coalesce(p_op_id::text, ''), true);
  perform set_config('app.actor_role', case when p_is_system then 'SYSTEM' else array_to_string(v_eff, ',') end, true);

  select * into v_lead from public.wo_assignments a
   where a.wo_id = p_wo_id and a.role = 'LEAD' and a.status in ('ASSIGNED','ACCEPTED') limit 1;

  case p_action
  -- T-02 / T-05: penugasan & tugas ulang
  when 'ASSIGN', 'REASSIGN' then
    v_new_tech := nullif(v_pl ->> 'technician_id', '')::uuid;
    if v_new_tech is null or not exists (select 1 from public.technicians x where x.id = v_new_tech and x.is_active) then
      raise exception 'WO003: teknisi tidak valid' using errcode = 'WO003', detail = '{"code":"TECHNICIAN_INVALID"}';
    end if;
    if nullif(v_pl ->> 'scheduled_start', '') is null then
      raise exception 'WO003: jadwal final wajib' using errcode = 'WO003', detail = '{"code":"SCHEDULE_REQUIRED"}';
    end if;
    v_warn := app.assignment_warnings(v_new_tech, w.service_type_id, (v_pl ->> 'scheduled_start')::timestamptz,
                                      nullif(v_pl ->> 'scheduled_end', '')::timestamptz, p_wo_id);
    if jsonb_array_length(v_warn) > 0 and coalesce(btrim(v_pl ->> 'override_reason'), '') = '' then
      raise exception 'WO003: peringatan lunak penugasan butuh override_reason' using errcode = 'WO003',
        detail = jsonb_build_object('code', 'SOFT_GUARD', 'warnings', v_warn)::text;
    end if;
    if p_action = 'REASSIGN' then
      perform app.notify_wo_technicians(p_wo_id, 'wo.reassigned_away', jsonb_build_object('wo_number', w.wo_number), 'reassign-old:' || coalesce(p_op_id::text, gen_random_uuid()::text));
      update public.wo_assignments set status = 'REASSIGNED', ended_at = p_now, reason = p_reason, reason_code = p_reason_code
       where wo_id = p_wo_id and role = 'LEAD' and status in ('ASSIGNED','ACCEPTED');
      v_force := true;
    end if;
    update public.work_orders set scheduled_start = (v_pl ->> 'scheduled_start')::timestamptz,
           scheduled_end = nullif(v_pl ->> 'scheduled_end', '')::timestamptz where id = p_wo_id;
    insert into public.wo_assignments (wo_id, technician_id, role, status, assigned_by, override_reason)
    values (p_wo_id, v_new_tech, 'LEAD', 'ASSIGNED', p_actor_id, nullif(v_pl ->> 'override_reason', ''));
    perform app.enqueue_notification((select user_id from public.technicians where id = v_new_tech), 'wo.assigned', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'scheduled_start', v_pl ->> 'scheduled_start'),
              'assign:' || p_wo_id::text || ':' || coalesce(p_op_id::text, gen_random_uuid()::text));
    if p_action = 'REASSIGN' and w.status = 'ACCEPTED' then
      perform app.notify_customer(w.customer_id, 'wo.rescheduled', p_wo_id,
                jsonb_build_object('wo_number', w.wo_number), 'resched:' || p_wo_id::text || ':' || coalesce(p_op_id::text, gen_random_uuid()::text));
    end if;

  -- T-03
  when 'ACCEPT' then
    update public.wo_assignments set status = 'ACCEPTED', responded_at = p_now where id = v_lead.id;
    if w.policy_snapshot ->> 'response_met_event' = 'ACCEPT' then perform app.sla_mark_met(p_wo_id, 'RESPONSE', p_now); end if;
    perform app.notify_customer(w.customer_id, 'wo.scheduled', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'scheduled_start', w.scheduled_start, 'scheduled_end', w.scheduled_end),
              'accepted:' || p_wo_id::text || ':' || v_lead.id::text);

  -- T-04
  when 'REJECT' then
    update public.wo_assignments set status = 'REJECTED', responded_at = p_now, ended_at = p_now,
           reason = p_reason, reason_code = p_reason_code where id = v_lead.id;
    update public.work_orders set rejection_count = rejection_count + 1 where id = p_wo_id returning rejection_count into v_n;
    perform app.notify_role('DISPATCHER', 'wo.assignment_rejected', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'reason', p_reason), 'rej:' || p_wo_id::text || ':' || v_n::text);
    v_th := app.setting_int('reject.escalation_threshold');
    if v_th is not null and v_n >= v_th then
      perform app.notify_role('SUPERVISOR', 'wo.rejection_escalation', p_wo_id,
                jsonb_build_object('wo_number', w.wo_number, 'rejection_count', v_n), 'rejesc:' || p_wo_id::text || ':' || v_n::text);
    end if;

  -- T-06
  when 'RELEASE' then
    if exists (select 1 from public.wo_visits where wo_id = p_wo_id and check_in_at is not null) then
      raise exception 'WO003: sudah check-in, gunakan serah-terima' using errcode = 'WO003', detail = '{"code":"ALREADY_CHECKED_IN"}';
    end if;
    update public.wo_assignments set status = 'RELEASED', ended_at = p_now, reason = p_reason, reason_code = p_reason_code
     where id = v_lead.id;
    perform app.notify_role('DISPATCHER', 'wo.released', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'reason', p_reason),
              'rel:' || p_wo_id::text || ':' || v_lead.id::text);

  -- T-07
  when 'DEPART' then
    v_tol := app.setting_int('en_route.tolerance_days');
    if v_tol is not null then
      v_sched := (w.scheduled_start at time zone v_tz)::date;
      v_today := (p_now at time zone v_tz)::date;
      if v_sched is null or abs(v_sched - v_today) > v_tol then
        raise exception 'WO003: bukan hari jadwal' using errcode = 'WO003', detail = '{"code":"NOT_SCHEDULED_TODAY"}';
      end if;
    end if;
    if w.policy_snapshot ->> 'response_met_event' = 'DEPART' then perform app.sla_mark_met(p_wo_id, 'RESPONSE', p_now); end if;
    perform app.notify_customer(w.customer_id, 'wo.en_route', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
              'enroute:' || p_wo_id::text || ':' || w.version::text);

  -- T-08
  when 'CHECK_IN' then
    if (nullif(v_pl ->> 'lat', '') is null or nullif(v_pl ->> 'lng', '') is null)
       and coalesce(btrim(v_pl ->> 'no_gps_reason'), '') = '' then
      raise exception 'WO003: lokasi GPS atau alasan tanpa lokasi wajib' using errcode = 'WO003',
        detail = '{"code":"GPS_OR_REASON_REQUIRED"}';
    end if;
    insert into public.wo_visits (wo_id, technician_id, check_in_at, check_in_lat, check_in_lng, check_in_accuracy_m, check_in_no_gps_reason)
    values (p_wo_id, v_lead.technician_id, coalesce(nullif(v_pl ->> 'client_ts', '')::timestamptz, p_now),
            nullif(v_pl ->> 'lat', '')::numeric, nullif(v_pl ->> 'lng', '')::numeric,
            nullif(v_pl ->> 'accuracy_m', '')::numeric, nullif(btrim(v_pl ->> 'no_gps_reason'), ''));
    update public.work_orders set started_at = coalesce(started_at, p_now) where id = p_wo_id;
    if w.policy_snapshot ->> 'response_met_event' = 'CHECK_IN' then perform app.sla_mark_met(p_wo_id, 'RESPONSE', p_now); end if;

  -- T-09 / T-10
  when 'HOLD_PARTS' then
    if not exists (select 1 from public.part_requests where wo_id = p_wo_id and status in ('REQUESTED','APPROVED','PARTIALLY_ISSUED')) then
      raise exception 'WO003: tidak ada permintaan suku cadang terbuka' using errcode = 'WO003', detail = '{"code":"NO_OPEN_PART_REQUEST"}';
    end if;
    if coalesce((w.policy_snapshot ->> 'pause_on_hold_parts')::boolean, false) then
      perform app.sla_pause(p_wo_id, 'ON_HOLD_PARTS', p_now);
    end if;
    perform app.notify_role('DISPATCHER', 'wo.on_hold_parts', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'hold:' || p_wo_id::text || ':' || w.version::text);
    perform app.notify_role('WAREHOUSE', 'wo.on_hold_parts', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'holdw:' || p_wo_id::text || ':' || w.version::text);
  when 'RESUME_PARTS' then
    if not (p_is_system or 'DISPATCHER' = any (v_eff))
       and exists (select 1 from public.part_requests where wo_id = p_wo_id and status in ('REQUESTED','APPROVED','PARTIALLY_ISSUED')) then
      raise exception 'WO003: permintaan suku cadang masih terbuka' using errcode = 'WO003', detail = '{"code":"PART_REQUEST_OPEN"}';
    end if;
    perform app.sla_resume(p_wo_id, p_now);

  -- T-11..T-15: biaya tambahan
  when 'REQUEST_EXTRA_COST' then
    select * into v_ap from public.extra_cost_approvals where wo_id = p_wo_id and status = 'PENDING';
    if v_ap.id is null or not exists (select 1 from public.extra_cost_approval_items where approval_id = v_ap.id) then
      raise exception 'WO003: pengajuan biaya tambahan PENDING (dengan item) wajib' using errcode = 'WO003', detail = '{"code":"EXTRA_COST_REQUEST_MISSING"}';
    end if;
    perform app.sla_pause(p_wo_id, 'AWAITING_CUSTOMER_APPROVAL', p_now);
    perform app.notify_customer(w.customer_id, 'wo.approval_needed', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'approval_id', v_ap.id, 'total', v_ap.total), 'approval:' || v_ap.id::text);
  when 'APPROVE_EXTRA_COST', 'REJECT_EXTRA_COST', 'EXPIRE_EXTRA_COST' then
    select * into v_ap from public.extra_cost_approvals where id = nullif(v_pl ->> 'approval_id', '')::uuid and wo_id = p_wo_id;
    v_expect := (case p_action when 'APPROVE_EXTRA_COST' then 'APPROVED'
                               when 'REJECT_EXTRA_COST' then 'REJECTED' else 'EXPIRED' end)::public.approval_status;
    if v_ap.id is null or v_ap.status <> v_expect then
      raise exception 'WO003: keputusan persetujuan belum tercatat (gunakan extra_cost_decide)' using errcode = 'WO003',
        detail = '{"code":"APPROVAL_DECISION_MISSING"}';
    end if;
    perform app.sla_resume(p_wo_id, p_now);
    perform app.notify_wo_technicians(p_wo_id, 'wo.approval_' || lower(substr(p_action, 1, position('_EXTRA' in p_action) - 1)),
              jsonb_build_object('wo_number', w.wo_number, 'approval_id', v_ap.id), 'apprres:' || v_ap.id::text);
    if p_action = 'EXPIRE_EXTRA_COST' then
      perform app.notify_role('DISPATCHER', 'wo.approval_expired', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'appexp:' || v_ap.id::text);
      perform app.notify_role('ADMIN_CS', 'wo.approval_expired', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'appexpa:' || v_ap.id::text);
    end if;
  when 'CLOSE_AFTER_REJECTION' then
    select * into v_ap from public.extra_cost_approvals where wo_id = p_wo_id order by version_no desc limit 1;
    if v_ap.id is null or v_ap.status not in ('REJECTED','EXPIRED') or coalesce(v_ap.continue_original_scope, true) then
      raise exception 'WO003: tidak ada penolakan yang menghalangi lingkup awal' using errcode = 'WO003', detail = '{"code":"NO_BLOCKING_REJECTION"}';
    end if;
    v_outcome := coalesce(nullif(v_pl ->> 'outcome', '')::public.wo_outcome, 'UNRESOLVED');
    if v_outcome = 'RESOLVED' then
      raise exception 'WO003: outcome harus PARTIAL/UNRESOLVED' using errcode = 'WO003', detail = '{"code":"OUTCOME_INVALID"}';
    end if;
    v_def := app.wo_submit_deficiencies(p_wo_id, 'SUBMIT', nullif(v_pl ->> 'client_pending_ops', '')::int);
    if jsonb_array_length(v_def) > 0 then
      raise exception 'WO003: syarat penutupan belum lengkap' using errcode = 'WO003', detail = v_def::text;
    end if;
    perform app.sla_resume(p_wo_id, p_now);
    update public.wo_visits set check_out_at = p_now, result = 'COMPLETED', auto_checked_out = true
     where wo_id = p_wo_id and check_in_at is not null and check_out_at is null;
    update public.work_orders set outcome = v_outcome, submitted_at = p_now where id = p_wo_id;
    if w.policy_snapshot ->> 'resolution_met_event' = 'SUBMIT' then perform app.sla_mark_met(p_wo_id, 'RESOLUTION', p_now); end if;
    perform app.notify_role('SUPERVISOR', 'wo.review_needed', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'outcome', v_outcome),
              'review:' || p_wo_id::text || ':' || w.version::text);

  -- T-16 / T-17 / T-18: penutupan oleh teknisi
  when 'SUBMIT_REVIEW', 'REQUEST_SIGNOFF' then
    -- BR-043: tanda tangan yang hash-nya tidak sama dengan isi sekarang menjadi SUPERSEDED
    update public.wo_signatures set status = 'SUPERSEDED'
     where wo_id = p_wo_id and status = 'VALID' and content_hash <> app.wo_content_hash(p_wo_id);
    v_exc := nullif(btrim(v_pl ->> 'closure_exception_code'), '');
    if v_exc is not null and p_action = 'SUBMIT_REVIEW' then                       -- BR-041
      if not exists (select 1 from public.reason_codes where category = 'CLOSURE_EXCEPTION' and code = v_exc and is_active) then
        raise exception 'WO006: kode pengecualian tidak dikenal' using errcode = 'WO006';
      end if;
      if coalesce(btrim(v_pl ->> 'closure_exception_note'), '') = '' then
        raise exception 'WO003: catatan pengecualian wajib' using errcode = 'WO003', detail = '{"code":"EXCEPTION_NOTE_REQUIRED"}';
      end if;
      update public.work_orders set closure_exception = true, closure_exception_code = v_exc,
             closure_exception_note = v_pl ->> 'closure_exception_note' where id = p_wo_id;
    end if;
    v_def := app.wo_submit_deficiencies(p_wo_id, case p_action when 'SUBMIT_REVIEW' then 'SUBMIT' else 'SIGNOFF_REQUEST' end,
                                        nullif(v_pl ->> 'client_pending_ops', '')::int);
    if jsonb_array_length(v_def) > 0 then
      raise exception 'WO003: syarat penutupan belum lengkap' using errcode = 'WO003', detail = v_def::text;
    end if;
    update public.wo_visits set check_out_at = p_now, check_out_lat = nullif(v_pl ->> 'lat', '')::numeric,
           check_out_lng = nullif(v_pl ->> 'lng', '')::numeric, result = 'COMPLETED'
     where wo_id = p_wo_id and check_in_at is not null and check_out_at is null;
    update public.work_orders set outcome = coalesce(nullif(v_pl ->> 'outcome', '')::public.wo_outcome, outcome, 'RESOLVED') where id = p_wo_id;
    if p_action = 'SUBMIT_REVIEW' then
      update public.work_orders set submitted_at = p_now where id = p_wo_id;
      if w.policy_snapshot ->> 'resolution_met_event' = 'SUBMIT' then perform app.sla_mark_met(p_wo_id, 'RESOLUTION', p_now); end if;
      perform app.notify_role('SUPERVISOR', 'wo.review_needed', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
                'review:' || p_wo_id::text || ':' || w.version::text);
    else
      update public.work_orders set signoff_expires_at = case when app.setting_int('signoff.expiry_hours') is null then null
                 else p_now + make_interval(hours => app.setting_int('signoff.expiry_hours')) end where id = p_wo_id;
      if w.policy_snapshot ->> 'resolution_met_event' = 'SUBMIT' then
        perform app.sla_mark_met(p_wo_id, 'RESOLUTION', p_now);
      else
        perform app.sla_pause(p_wo_id, 'AWAITING_SIGNOFF', p_now);
      end if;
      perform app.notify_customer(w.customer_id, 'wo.signoff_needed', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
                'signoff:' || p_wo_id::text || ':' || w.version::text);
    end if;
  when 'SIGNOFF', 'EXPIRE_SIGNOFF' then
    if p_action = 'EXPIRE_SIGNOFF' then
      update public.work_orders set closure_exception = true, closure_exception_code = 'NO_RESPONSE',
             closure_exception_note = 'pelanggan tidak menjawab hingga batas waktu' where id = p_wo_id;
    end if;
    update public.wo_signatures set status = 'SUPERSEDED'
     where wo_id = p_wo_id and status = 'VALID' and content_hash <> app.wo_content_hash(p_wo_id);
    v_def := app.wo_submit_deficiencies(p_wo_id, 'SUBMIT', 0);
    if jsonb_array_length(v_def) > 0 then
      raise exception 'WO003: syarat penutupan belum lengkap' using errcode = 'WO003', detail = v_def::text;
    end if;
    perform app.sla_resume(p_wo_id, p_now);
    update public.work_orders set submitted_at = coalesce(submitted_at, p_now), signoff_expires_at = null where id = p_wo_id;
    perform app.notify_role('SUPERVISOR', 'wo.review_needed', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
              'review:' || p_wo_id::text || ':' || w.version::text);

  -- T-19: supervisor menyetujui => CLOSED
  when 'APPROVE_CLOSE' then
    if w.closure_exception then
      if not coalesce((v_pl ->> 'approve_exception')::boolean, false) then
        raise exception 'WO003: pengecualian penutupan harus disetujui eksplisit' using errcode = 'WO003',
          detail = '{"code":"CLOSURE_EXCEPTION_NOT_APPROVED"}';
      end if;
      update public.work_orders set closure_exception_approved_by = p_actor_id, closure_exception_approved_at = p_now where id = p_wo_id;
    end if;
    v_def := app.wo_submit_deficiencies(p_wo_id, 'CLOSE', null);                  -- BR-042
    if jsonb_array_length(v_def) > 0 then
      raise exception 'WO003: validasi ulang penutupan gagal' using errcode = 'WO003', detail = v_def::text;
    end if;
    select exists (select 1 from public.wo_labor_lines l where l.wo_id = p_wo_id and l.deleted_at is null and l.billable)
        or exists (select 1 from public.wo_part_usages u where u.wo_id = p_wo_id and u.deleted_at is null and u.billable)
      into v_has_billable;
    update public.work_orders set closed_at = p_now, next_sla_check_at = null,
           billing_status = case when w.billing_type = 'BILLABLE' or v_has_billable then 'PENDING' else 'NOT_BILLABLE' end::public.billing_status
     where id = p_wo_id;
    if w.policy_snapshot ->> 'resolution_met_event' = 'CLOSE' or w.resolution_met_at is null then
      perform app.sla_mark_met(p_wo_id, 'RESOLUTION', p_now);
    end if;
    update public.wo_assignments set status = 'COMPLETED', ended_at = p_now where wo_id = p_wo_id and status in ('ASSIGNED','ACCEPTED');
    update public.pm_periods set status = case when status = 'GENERATED' then 'COMPLETED' else status end::public.pm_period_status,
           completed_at = p_now where wo_id = p_wo_id;
    -- laporan: snapshot terkunci, PDF dirender asinkron oleh aplikasi (NFR-P6)
    v_snap := app.build_report_snapshot(p_wo_id);
    select coalesce(max(revision), 0) + 1 into v_rev from public.service_reports where wo_id = p_wo_id;
    insert into public.service_reports (wo_id, customer_id, revision, status, snapshot, snapshot_hash, generated_by)
    values (p_wo_id, w.customer_id, v_rev, 'GENERATING', v_snap, encode(sha256(convert_to(v_snap::text, 'UTF8')), 'hex'), p_actor_id);
    perform app.refresh_parts_variances(p_wo_id, false);                          -- BR-032(a)
    perform app.notify_customer(w.customer_id, 'wo.closed', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
              'closed:' || p_wo_id::text);

  -- T-20 / T-21
  when 'RETURN' then
    update public.work_orders set returned_count = returned_count + 1 where id = p_wo_id returning returned_count into v_n;
    perform app.notify_wo_technicians(p_wo_id, 'wo.returned', jsonb_build_object('wo_number', w.wo_number, 'note', p_reason),
              'ret:' || p_wo_id::text || ':' || v_n::text);
    v_th := app.setting_int('return.escalation_threshold');
    if v_th is not null and v_n >= v_th then
      perform app.notify_role('OWNER', 'wo.return_escalation', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'returned_count', v_n),
                'retesc:' || p_wo_id::text || ':' || v_n::text);
    end if;
  when 'RESUME_AFTER_RETURN' then
    null;   -- tanda tangan lama di-SUPERSEDE saat pengajuan ulang jika hash berubah (BR-043)

  -- T-22 / T-23: pembatalan
  when 'CANCEL', 'CANCEL_BY_CUSTOMER', 'CANCEL_ACTIVE' then
    if p_action = 'CANCEL_ACTIVE' then
      update public.work_orders set outcome = coalesce(nullif(v_pl ->> 'outcome', '')::public.wo_outcome, 'PARTIAL') where id = p_wo_id;
    end if;
    perform app.wo_cancel_effects(p_wo_id, p_reason_code, p_reason, p_actor_id, p_now);
    perform app.notify_customer(w.customer_id, 'wo.cancelled', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'reason', p_reason), 'cancelled:' || p_wo_id::text);
    if p_action <> 'CANCEL' then
      perform app.notify_role('DISPATCHER', 'wo.cancelled', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'cancelled-d:' || p_wo_id::text);
    end if;

  -- T-27: kunjungan gagal
  when 'VISIT_FAILED' then
    if not exists (select 1 from public.wo_attachments where wo_id = p_wo_id and kind = 'FAILED_VISIT' and deleted_at is null) then
      raise exception 'WO003: foto bukti kunjungan gagal wajib' using errcode = 'WO003', detail = '{"code":"FAILED_VISIT_EVIDENCE_MISSING"}';
    end if;
    update public.wo_visits set check_out_at = p_now, auto_checked_out = true,
           result = coalesce(nullif(v_pl ->> 'result', '')::public.visit_result, 'FAILED_ABSENT')
     where wo_id = p_wo_id and check_out_at is null;
    update public.wo_assignments set status = 'RELEASED', ended_at = p_now, reason = p_reason, reason_code = p_reason_code
     where id = v_lead.id;
    update public.work_orders set failed_visit_count = failed_visit_count + 1 where id = p_wo_id;
    perform app.notify_role('DISPATCHER', 'wo.visit_failed', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'reason', p_reason),
              'vf:' || p_wo_id::text || ':' || w.version::text);
  else
    raise exception 'WO001: aksi % belum diimplementasikan', p_action using errcode = 'WO001';
  end case;

  if v_force then perform set_config('app.history_force', 'on', true); end if;
  update public.work_orders set status = v_to,
         next_sla_check_at = case when v_to in ('CLOSED','CANCELLED') then null else p_now end,
         customer_note = coalesce(nullif(v_pl ->> 'customer_note', ''), customer_note)
   where id = p_wo_id
   returning * into w;

  perform set_config('app.tx_active', v_prev, true);
  perform set_config('app.history_force', 'off', true);
  return jsonb_build_object('status', w.status, 'version', w.version, 'replayed', false, 'warnings', v_warn);
end $$;

-- RPC publik transisi status (satu-satunya pintu untuk klien). Pelanggan/staf/teknisi memakai JWT mereka.
create or replace function public.wo_transition(
  p_wo_id uuid, p_action text, p_expected_version int, p_op_id uuid default null,
  p_reason text default null, p_reason_code text default null, p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_roles public.app_role[];
begin
  if auth.uid() is null then
    if app.is_system() then
      return app.apply_wo_transition(p_wo_id, p_action, null, '{}'::public.app_role[], true,
                                     p_expected_version, p_op_id, p_reason, p_reason_code, p_payload);
    end if;
    raise exception 'WO002: tidak terautentikasi' using errcode = 'WO002';
  end if;
  v_roles := app.resolve_actor_roles(p_wo_id);
  -- 404 seragam: tidak membedakan "tidak ada" dari "bukan milik Anda" (NFR-S10)
  if cardinality(v_roles) = 0
     or not (app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE}')
             or app.customer_owns_wo(p_wo_id)
             or p_wo_id in (select app.my_active_wo_ids())) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  return app.apply_wo_transition(p_wo_id, p_action, auth.uid(), v_roles, false,
                                 p_expected_version, p_op_id, p_reason, p_reason_code, p_payload);
end $$;


-- ---- 0010c: permintaan servis -> WO (T-01, T-24, SP-02) -----------------------------------------
create or replace function app.request_decide_core(
  p_request_id uuid, p_decision text, p_actor uuid, p_source public.decision_source,
  p_priority_code text, p_service_type_id uuid, p_estimate_total numeric, p_reason text, p_expected_version int
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.service_requests; v_st uuid; v_prio text; v_wo uuid; v_wo_no text; v_clock timestamptz;
  v_prev text := coalesce(current_setting('app.tx_active', true), 'off');
begin
  select * into r from public.service_requests where id = p_request_id for update;
  if not found then raise exception 'WO005: permintaan tidak ditemukan' using errcode = 'WO005'; end if;
  if p_expected_version is not null and r.version <> p_expected_version then
    raise exception 'WO004: konflik versi permintaan' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', r.version, 'current_status', r.status)::text;
  end if;
  if r.status <> 'SUBMITTED' then
    raise exception 'WO001: permintaan berstatus % tidak dapat diputuskan', r.status using errcode = 'WO001';
  end if;
  perform set_config('app.tx_active', 'on', true);
  perform set_config('app.actor_role', case when p_source = 'SYSTEM_RULE' then 'SYSTEM_RULE' else 'ADMIN_CS' end, true);

  if p_decision = 'APPROVE' then
    if r.asset_id is null then
      raise exception 'WO003: aset wajib sebelum permintaan disetujui' using errcode = 'WO003', detail = '{"code":"ASSET_REQUIRED"}';
    end if;
    v_st := coalesce(p_service_type_id, (select pt.service_type_id from public.problem_types pt where pt.id = r.problem_type_id));
    if v_st is null then
      raise exception 'WO003: jenis layanan wajib' using errcode = 'WO003', detail = '{"code":"SERVICE_TYPE_REQUIRED"}';
    end if;
    v_prio := coalesce(p_priority_code, (select default_priority_code from public.service_types where id = v_st));
    if v_prio is null then
      raise exception 'WO003: prioritas wajib' using errcode = 'WO003', detail = '{"code":"PRIORITY_REQUIRED"}';
    end if;
    -- SP-01: titik mulai jam SLA dapat dikonfigurasi (default WO_CREATED mengikuti T-01)
    v_clock := case when coalesce(app.setting_text('sla.clock_starts_at'), 'WO_CREATED') = 'REQUEST_RECEIVED'
                    then r.created_at else now() end;
    v_wo := app.create_work_order('CORRECTIVE', r.customer_id, r.site_id, r.asset_id, v_st, r.id, null, null, null,
                                  v_prio, p_estimate_total, p_actor, r.created_at, null, v_clock);
    select wo_number into v_wo_no from public.work_orders where id = v_wo;
    update public.service_requests set status = 'CONVERTED', decision_by = p_actor, decision_source = p_source,
           decided_at = now(), decision_reason = p_reason where id = p_request_id;
    perform app.notify_customer(r.customer_id, 'request.accepted', v_wo,
              jsonb_build_object('request_no', r.request_no, 'wo_number', v_wo_no), 'req-acc:' || p_request_id::text);
    perform set_config('app.tx_active', v_prev, true);
    return jsonb_build_object('decision', 'APPROVE', 'wo_id', v_wo, 'wo_number', v_wo_no);
  elsif p_decision = 'NEEDS_INFO' then
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'WO003: catatan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
    end if;
    update public.service_requests set status = 'NEEDS_INFO', needs_info_note = p_reason, decision_by = p_actor,
           decision_source = p_source, decided_at = now() where id = p_request_id;
    perform app.notify_customer(r.customer_id, 'request.needs_info', null,
              jsonb_build_object('request_no', r.request_no, 'note', p_reason), 'req-info:' || p_request_id::text || ':' || r.version::text);
  elsif p_decision = 'REJECT' then
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'WO003: alasan penolakan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
    end if;
    update public.service_requests set status = 'REJECTED', decision_reason = p_reason, decision_by = p_actor,
           decision_source = p_source, decided_at = now() where id = p_request_id;
    perform app.notify_customer(r.customer_id, 'request.rejected', null,
              jsonb_build_object('request_no', r.request_no, 'reason', p_reason), 'req-rej:' || p_request_id::text);
  else
    raise exception 'WO006: decision harus APPROVE|NEEDS_INFO|REJECT' using errcode = 'WO006';
  end if;
  perform set_config('app.tx_active', v_prev, true);
  return jsonb_build_object('decision', p_decision);
end $$;

create or replace function public.request_decide(
  p_request_id uuid, p_decision text, p_priority_code text default null, p_service_type_id uuid default null,
  p_estimate_total numeric default null, p_reason text default null, p_expected_version int default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_any_role('{ADMIN_CS}') then
    raise exception 'WO002: hanya Admin/CS' using errcode = 'WO002';
  end if;
  return app.request_decide_core(p_request_id, p_decision, auth.uid(), 'USER', p_priority_code, p_service_type_id,
                                 p_estimate_total, p_reason, p_expected_version);
end $$;

-- Auto-approve (SP-02): hanya bila kontrak aktif mencakup aset+jenis layanan, tidak ada duplikat, prioritas default tersedia.
create or replace function app.try_auto_approve(p_request_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.service_requests; v_st uuid; v_bill jsonb;
begin
  select * into r from public.service_requests where id = p_request_id;
  if r.status <> 'SUBMITTED' or r.duplicate_of is not null or r.asset_id is null or r.problem_type_id is null then return; end if;
  select service_type_id into v_st from public.problem_types where id = r.problem_type_id;
  if v_st is null or (select default_priority_code from public.service_types where id = v_st) is null then return; end if;
  v_bill := app.determine_billing(r.customer_id, r.asset_id, v_st, r.created_at);
  if v_bill ->> 'billing_type' <> 'COVERED_CONTRACT' then return; end if;
  begin
    perform app.request_decide_core(p_request_id, 'APPROVE', null, 'SYSTEM_RULE', null, v_st, null, 'aturan auto-approve kontrak', null);
  exception when others then
    raise warning 'auto-approve gagal untuk %: %', p_request_id, sqlerrm;     -- permintaan tetap SUBMITTED untuk antrean admin
  end;
end $$;

-- ---- 0010d: biaya tambahan (BR-050..055) -----------------------------------------------------------------
create or replace function public.extra_cost_request(
  p_wo_id uuid, p_reason text, p_items jsonb, p_expected_version int, p_op_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  w public.work_orders; v_ver int; v_total numeric; v_hash text; v_id uuid; v_exp timestamptz; v_hours int; v_res jsonb;
begin
  select * into w from public.work_orders where id = p_wo_id for update;
  if not found or not exists (select 1 from public.wo_assignments a
        where a.wo_id = p_wo_id and a.technician_id = app.my_technician_id() and a.role = 'LEAD' and a.status = 'ACCEPTED') then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  if w.status not in ('IN_PROGRESS','AWAITING_CUSTOMER_APPROVAL') then
    raise exception 'WO001: biaya tambahan hanya dari IN_PROGRESS' using errcode = 'WO001';
  end if;
  if p_expected_version is distinct from w.version then
    raise exception 'WO004: konflik versi' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;
  if coalesce(btrim(p_reason), '') = '' or p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'WO006: alasan dan minimal satu item wajib' using errcode = 'WO006';
  end if;

  -- Harga diambil dari master bila ada ref_id (teknisi tidak perlu/tidak boleh melihat harga, AP-2); item bebas (OTHER) memakai unit_price input.
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'ref_id', x.ref_id, 'description', x.description, 'qty', x.qty,
           'unit_price', case when x.kind = 'LABOR' and x.ref_id is not null then (select si.unit_price from public.service_items si where si.id = x.ref_id)
                              when x.kind = 'PART' and x.ref_id is not null then (select it.unit_price from public.items it where it.id = x.ref_id)
                              else x.unit_price end)), '[]'::jsonb)
    into p_items
    from jsonb_to_recordset(p_items) as x(kind text, ref_id uuid, description text, qty numeric, unit_price numeric);
  if exists (select 1 from jsonb_to_recordset(p_items) as x(kind text, qty numeric, unit_price numeric)
              where x.unit_price is null or x.qty is null or x.qty <= 0 or x.kind not in ('LABOR','PART','OTHER')) then
    raise exception 'WO006: item tidak valid atau harga master belum diisi' using errcode = 'WO006';
  end if;
  select coalesce(sum(round(x.qty * x.unit_price, 2)), 0) into v_total
    from jsonb_to_recordset(p_items) as x(kind text, ref_id uuid, description text, qty numeric, unit_price numeric);

  update public.extra_cost_approvals set status = 'SUPERSEDED' where wo_id = p_wo_id and status = 'PENDING';   -- versi baru (BR-051)
  select coalesce(max(version_no), 0) + 1 into v_ver from public.extra_cost_approvals where wo_id = p_wo_id;
  select encode(sha256(convert_to(jsonb_build_object('wo', p_wo_id, 'v', v_ver, 'reason', p_reason, 'total', v_total,
           'items', (select coalesce(jsonb_agg(jsonb_build_array(x.kind, x.description, x.qty, x.unit_price)
                                      order by x.kind, x.description, x.qty, x.unit_price), '[]'::jsonb)
                       from jsonb_to_recordset(p_items) as x(kind text, ref_id uuid, description text, qty numeric, unit_price numeric)))::text,
           'UTF8')), 'hex') into v_hash;
  v_hours := app.setting_int('approval.expiry_hours');
  v_exp := case when v_hours is null then null else now() + make_interval(hours => v_hours) end;

  insert into public.extra_cost_approvals (wo_id, version_no, status, total, reason, requested_by, expires_at, content_hash)
  values (p_wo_id, v_ver, 'PENDING', v_total, p_reason, auth.uid(), v_exp, v_hash) returning id into v_id;
  insert into public.extra_cost_approval_items (approval_id, kind, ref_id, description, qty, unit_price)
  select v_id, x.kind::public.extra_item_kind, x.ref_id, x.description, x.qty, x.unit_price
    from jsonb_to_recordset(p_items) as x(kind text, ref_id uuid, description text, qty numeric, unit_price numeric);

  if w.status = 'IN_PROGRESS' then
    v_res := app.apply_wo_transition(p_wo_id, 'REQUEST_EXTRA_COST', auth.uid(), app.resolve_actor_roles(p_wo_id), false,
                                     w.version, p_op_id, null, null, '{}'::jsonb);
  else
    perform app.notify_customer(w.customer_id, 'wo.approval_needed', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'approval_id', v_id, 'total', v_total), 'approval:' || v_id::text);
    v_res := jsonb_build_object('status', w.status, 'version', w.version);
  end if;
  return v_res || jsonb_build_object('approval_id', v_id, 'approval_version', v_ver, 'content_hash', v_hash, 'total', v_total);
end $$;

create or replace function public.extra_cost_decide(
  p_approval_id uuid, p_decision text, p_content_hash text, p_continue_original_scope boolean default true,
  p_channel public.decision_channel default 'PWA', p_evidence_note text default null,
  p_op_id uuid default null, p_meta jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a public.extra_cost_approvals; w public.work_orders; v_roles public.app_role[]; v_behalf boolean; v_res jsonb; v_wo uuid;
begin
  select wo_id into v_wo from public.extra_cost_approvals where id = p_approval_id;
  select * into w from public.work_orders where id = v_wo for update;          -- kunci WO dulu, lalu persetujuan
  select * into a from public.extra_cost_approvals where id = p_approval_id for update;
  v_roles := case when w.id is null then '{}'::public.app_role[] else app.resolve_actor_roles(w.id) end;
  if a.id is null or ('CUSTOMER' <> all (v_roles) and 'ADMIN_CS' <> all (v_roles)) then
    raise exception 'WO005: persetujuan tidak ditemukan' using errcode = 'WO005';
  end if;
  v_behalf := 'CUSTOMER' <> all (v_roles);                                        -- ADM atas nama pelanggan
  if v_behalf and (coalesce(btrim(p_evidence_note), '') = '' or p_channel = 'PWA') then
    raise exception 'WO003: keputusan atas nama pelanggan butuh bukti dan kanal non-PWA' using errcode = 'WO003',
      detail = '{"code":"ON_BEHALF_EVIDENCE_REQUIRED"}';
  end if;
  if a.status <> 'PENDING' or w.status <> 'AWAITING_CUSTOMER_APPROVAL' then
    raise exception 'WO004: persetujuan sudah tidak berlaku (status %)', a.status using errcode = 'WO004',
      detail = jsonb_build_object('code', 'APPROVAL_STALE', 'approval_status', a.status)::text;
  end if;
  if a.content_hash <> coalesce(p_content_hash, '') then                          -- hanya sah untuk versi yang ditampilkan
    raise exception 'WO004: versi persetujuan berubah' using errcode = 'WO004', detail = '{"code":"APPROVAL_VERSION_STALE"}';
  end if;
  if a.expires_at is not null and a.expires_at < now() then
    raise exception 'WO004: persetujuan kedaluwarsa' using errcode = 'WO004', detail = '{"code":"APPROVAL_EXPIRED"}';
  end if;
  if p_decision not in ('APPROVE','REJECT') then
    raise exception 'WO006: decision harus APPROVE|REJECT' using errcode = 'WO006';
  end if;

  update public.extra_cost_approvals set
         status = case p_decision when 'APPROVE' then 'APPROVED' else 'REJECTED' end::public.approval_status,
         decided_by = auth.uid(), decided_at = now(), decision_channel = p_channel, on_behalf = v_behalf,
         evidence_note = p_evidence_note, continue_original_scope = case p_decision when 'REJECT' then p_continue_original_scope end,
         decision_meta = coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('content_hash', a.content_hash, 'total', a.total)
   where id = p_approval_id;

  if p_decision = 'APPROVE' then
    v_res := app.apply_wo_transition(w.id, 'APPROVE_EXTRA_COST', auth.uid(), v_roles, false, w.version, p_op_id, null, null,
                                     jsonb_build_object('approval_id', a.id));
  elsif p_continue_original_scope then
    v_res := app.apply_wo_transition(w.id, 'REJECT_EXTRA_COST', auth.uid(), v_roles, false, w.version, p_op_id, null, null,
                                     jsonb_build_object('approval_id', a.id));
  else                                                                              -- T-14: tetap menunggu teknisi menutup tidak tuntas
    perform app.notify_wo_technicians(w.id, 'wo.approval_reject_close_needed',
              jsonb_build_object('wo_number', w.wo_number, 'approval_id', a.id), 'apprc:' || a.id::text);
    perform app.sla_resume(w.id, now());
    v_res := jsonb_build_object('status', w.status, 'version', w.version + 1);
  end if;
  return v_res;
end $$;

-- Tanda tangan pelanggan lewat PWA (jalur AWAITING_SIGNOFF, SP-07) -> T-18.
create or replace function public.wo_customer_sign(
  p_wo_id uuid, p_signer_name text, p_storage_path text, p_expected_version int,
  p_op_id uuid default null, p_device_meta jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not app.customer_owns_wo(p_wo_id) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  if (select status from public.work_orders where id = p_wo_id) <> 'AWAITING_SIGNOFF' then
    raise exception 'WO001: WO tidak sedang menunggu tanda tangan' using errcode = 'WO001';
  end if;
  insert into public.wo_signatures (wo_id, signer_type, signer_name, signer_user_id, storage_path, content_hash, signed_via, device_meta, op_id)
  values (p_wo_id, 'CUSTOMER', p_signer_name, auth.uid(), p_storage_path, '', 'CUSTOMER_PWA', p_device_meta, p_op_id);
  return app.apply_wo_transition(p_wo_id, 'SIGNOFF', auth.uid(), app.resolve_actor_roles(p_wo_id), false,
                                 p_expected_version, p_op_id, null, null, '{}'::jsonb);
end $$;

-- ---- 0010e: RPC kecil WO (T-25/T-26, prioritas, billing, helper, batal oleh pelanggan) ----------------------------------
create or replace function public.wo_request_help(p_wo_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not exists (select 1 from public.wo_assignments a where a.wo_id = p_wo_id and a.technician_id = app.my_technician_id()
                  and a.status in ('ASSIGNED','ACCEPTED')) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  update public.work_orders set help_requested_at = now(), help_requested_by = auth.uid(), help_note = p_note
   where id = p_wo_id and status not in ('CLOSED','CANCELLED') returning * into w;
  if w.id is null then raise exception 'WO001: WO sudah final' using errcode = 'WO001'; end if;
  perform app.notify_role('DISPATCHER', 'wo.help_requested', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'note', p_note),
            'help:' || p_wo_id::text || ':' || w.version::text);
end $$;

create or replace function public.wo_add_helper(p_wo_id uuid, p_technician_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_uid uuid; w public.work_orders;
begin
  if not app.has_any_role('{DISPATCHER}') then raise exception 'WO002: hanya Dispatcher' using errcode = 'WO002'; end if;
  select * into w from public.work_orders where id = p_wo_id;
  if w.id is null or w.status in ('CLOSED','CANCELLED','NEW') then
    raise exception 'WO001: helper hanya untuk WO yang sedang ditangani' using errcode = 'WO001';
  end if;
  select user_id into v_uid from public.technicians where id = p_technician_id and is_active;
  if v_uid is null then raise exception 'WO006: teknisi tidak valid' using errcode = 'WO006'; end if;
  insert into public.wo_assignments (wo_id, technician_id, role, status, assigned_by, responded_at)
  values (p_wo_id, p_technician_id, 'HELPER', 'ACCEPTED', auth.uid(), now()) returning id into v_id;
  perform app.enqueue_notification(v_uid, 'wo.helper_assigned', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
            'helper:' || v_id::text);
  return v_id;
end $$;

-- Pelanggan mengajukan pembatalan (DEC-04): keputusan ada di ADM/DSP. Dari NEW pelanggan membatalkan langsung via wo_transition(CANCEL_BY_CUSTOMER).
create or replace function public.wo_request_cancel(p_wo_id uuid, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not app.customer_owns_wo(p_wo_id) then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  update public.work_orders set cancel_requested_at = now(), cancel_requested_by = auth.uid(), cancel_request_note = p_note
   where id = p_wo_id and status in ('ASSIGNED','ACCEPTED','EN_ROUTE') returning * into w;
  if w.id is null then raise exception 'WO001: pengajuan batal tidak tersedia pada status ini' using errcode = 'WO001'; end if;
  perform app.notify_role('ADMIN_CS', 'wo.cancel_requested', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'note', p_note), 'cxl:' || p_wo_id::text);
  perform app.notify_role('DISPATCHER', 'wo.cancel_requested', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'note', p_note), 'cxld:' || p_wo_id::text);
end $$;

create or replace function public.wo_change_priority(p_wo_id uuid, p_priority_code text, p_reason text, p_expected_version int)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'WO003: alasan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;
  select * into w from public.work_orders where id = p_wo_id for update;
  if w.id is null then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  if w.status in ('CLOSED','CANCELLED') then raise exception 'WO001: WO final' using errcode = 'WO001'; end if;
  if w.version <> p_expected_version then
    raise exception 'WO004: konflik versi' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;
  update public.work_orders set priority_code = p_priority_code where id = p_wo_id;   -- diaudit oleh trigger (nilai lama/baru)
  perform app.sla_recalculate(p_wo_id);                                             -- BR-015: dihitung dari sla_clock_start_at
  insert into public.wo_status_history (wo_id, from_status, to_status, action, actor_id, actor_roles, reason)
  values (p_wo_id, w.status, w.status, 'CHANGE_PRIORITY', auth.uid(), array_to_string(app.my_roles(), ','), p_reason);
  select * into w from public.work_orders where id = p_wo_id;
  return jsonb_build_object('status', w.status, 'version', w.version);
end $$;

create or replace function public.wo_override_billing(p_wo_id uuid, p_billing_type public.billing_type, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not app.has_any_role('{SUPERVISOR}') then raise exception 'WO002: hanya Supervisor' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'WO003: alasan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;
  select * into w from public.work_orders where id = p_wo_id for update;
  if w.id is null then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  if w.billing_status in ('INVOICED','PAID') then
    raise exception 'WO001: sudah ditagih; gunakan nota koreksi (di luar cakupan)' using errcode = 'WO001';   -- BR-062
  end if;
  update public.work_orders set billing_type = p_billing_type, billing_override_reason = p_reason where id = p_wo_id;
end $$;

create or replace function public.wo_create_rework(p_parent_wo_id uuid, p_reason text, p_priority_code text default null,
                                                   p_complaint_id uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare p public.work_orders; v_days int; v_id uuid;
begin
  if not app.has_any_role('{ADMIN_CS,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  select * into p from public.work_orders where id = p_parent_wo_id;
  if p.id is null then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  if p.status <> 'CLOSED' then raise exception 'WO001: WO induk harus CLOSED' using errcode = 'WO001'; end if;
  v_days := app.setting_int('rework.claim_window_days');
  if v_days is not null and p.closed_at < now() - make_interval(days => v_days) then
    raise exception 'WO001: di luar jendela klaim' using errcode = 'WO001';
  end if;
  -- T-25: WO induk TIDAK dibuka kembali; BR-066: garansi pekerjaan
  v_id := app.create_work_order('REWORK', p.customer_id, p.site_id, p.asset_id, p.service_type_id, null, null, null, p.id,
                                coalesce(p_priority_code, p.priority_code), null, auth.uid(), now(), 'WARRANTY_WORK');
  update public.work_orders set customer_note = p_reason where id = v_id;
  if p_complaint_id is not null then
    update public.complaints set rework_wo_id = v_id, status = 'IN_REVIEW', handled_by = auth.uid()
     where id = p_complaint_id and wo_id = p_parent_wo_id;
  end if;
  return v_id;
end $$;

create or replace function public.wo_cost_summary(p_wo_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare w public.work_orders; v_proj numeric; v_tol numeric := coalesce(app.setting_int('extra_cost.tolerance_amount'), 0);
begin
  if not (app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')
          or p_wo_id in (select app.my_active_wo_ids())) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  select * into w from public.work_orders where id = p_wo_id;
  select coalesce(sum(qty * coalesce(unit_price_snapshot, 0)), 0) into v_proj from (
    select qty, unit_price_snapshot from public.wo_labor_lines where wo_id = p_wo_id and deleted_at is null and billable
    union all
    select qty, unit_price_snapshot from public.wo_part_usages where wo_id = p_wo_id and deleted_at is null and billable) x;
  return jsonb_build_object('estimate_total', w.estimate_total, 'projected_total', v_proj, 'tolerance', v_tol,
           'needs_approval', w.estimate_total is not null and v_proj > w.estimate_total + v_tol);        -- BR-050
end $$;

-- ---- 0010f: pemeliharaan berkala (BR-020..028) ------------------------------------------------------------------------
create or replace function app.generate_preventive_work_orders(p_today date default null) returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record; v_today date; v_step int; v_horizon date; v_first date; v_due date; v_nmax int; v_n int;
  v_grace int; v_pid uuid; v_wo uuid; v_prio text; v_created int := 0;
begin
  for r in
    select ca.id, ca.asset_id, ca.service_type_id, ca.frequency, ca.anchor_date, ca.lead_days, ca.grace_days,
           ca.active_from, ca.active_to, ca.created_at, c.customer_id, c.start_date, c.end_date, a.site_id,
           st.default_priority_code,
           coalesce((select bc.timezone from public.business_calendars bc
                      where bc.id = coalesce(c.calendar_id, (select id from public.business_calendars where is_default limit 1))),
                    app.setting_text('default_timezone'), 'Asia/Jakarta') as tz
      from public.contract_assets ca
      join public.contracts c on c.id = ca.contract_id and c.status = 'ACTIVE'
      join public.assets a on a.id = ca.asset_id and a.is_active
      join public.service_types st on st.id = ca.service_type_id
     where ca.is_active
  loop
    v_today := coalesce(p_today, (now() at time zone r.tz)::date);                       -- BR-028
    v_step := case r.frequency when 'MONTHLY' then 1 when 'QUARTERLY' then 3 else 12 end;
    v_horizon := least(v_today + r.lead_days, r.end_date, coalesce(r.active_to, r.end_date));
    -- periode sebelum aset dimasukkan ke jadwal tidak dibuat mundur (hindari banjir MISSED historis)
    v_first := greatest(r.anchor_date, r.start_date, coalesce(r.active_from, r.start_date), (r.created_at at time zone r.tz)::date);
    continue when v_horizon < r.anchor_date;
    v_nmax := ((extract(year from age(v_horizon, r.anchor_date)) * 12 + extract(month from age(v_horizon, r.anchor_date)))::int / v_step) + 1;
    v_grace := coalesce(r.grace_days, app.setting_int('pm.grace_days'), 0);
    for v_n in 0 .. v_nmax loop
      v_due := (r.anchor_date + make_interval(months => v_n * v_step))::date;           -- selalu dari anchor (BR-021)
      continue when v_due > v_horizon or v_due < v_first;
      v_pid := null;
      insert into public.pm_periods (contract_asset_id, period_key, status) values (r.id, v_due, 'GENERATED')
      on conflict (contract_asset_id, period_key) do nothing returning id into v_pid;
      continue when v_pid is null;                                                       -- sudah diproses: idempoten
      if v_due + v_grace < v_today then                                                  -- BR-025: catch-up lampau => MISSED tanpa WO
        update public.pm_periods set status = 'MISSED', missed_at = now() where id = v_pid;
        continue;
      end if;
      v_prio := coalesce(r.default_priority_code, app.setting_text('pm.default_priority_code'),
                         (select code from public.priorities where is_active order by sort_rank limit 1));
      v_wo := app.create_work_order('PREVENTIVE', r.customer_id, r.site_id, r.asset_id, r.service_type_id, null, r.id, v_due,
                                    null, v_prio, null, null, now(), 'COVERED_CONTRACT');
      if v_wo is null then                                                               -- WO periode ini sudah ada (jaring pengaman unique)
        select id into v_wo from public.work_orders where contract_asset_id = r.id and pm_period_key = v_due and type = 'PREVENTIVE';
      else
        v_created := v_created + 1;
        perform app.notify_role('DISPATCHER', 'pm.generated', v_wo, jsonb_build_object('asset_id', r.asset_id, 'due_date', v_due),
                  'pmgen:' || v_wo::text);
      end if;
      update public.pm_periods set wo_id = v_wo where id = v_pid;
    end loop;
  end loop;
  return v_created;
end $$;

-- Tandai periode PM terlewat + eskalasi idempoten (BR-024)
create or replace function app.mark_missed_pm_periods(p_today date default null) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_today date; v_n int := 0; v_set uuid; v_ins int; k record; v_grace int;
begin
  for r in
    select p.id, p.status, p.period_key, p.wo_id, p.contract_asset_id, ca.grace_days, c.sla_policy_set_id,
           coalesce((select bc.timezone from public.business_calendars bc where bc.id = c.calendar_id),
                    app.setting_text('default_timezone'), 'Asia/Jakarta') as tz
      from public.pm_periods p
      join public.contract_assets ca on ca.id = p.contract_asset_id
      join public.contracts c on c.id = ca.contract_id
      left join public.work_orders w on w.id = p.wo_id
     where (p.status = 'GENERATED' and (w.id is null or w.status <> 'CLOSED'))
        or (p.status = 'MISSED' and not exists (select 1 from public.sla_events e where e.pm_period_id = p.id and e.kind = 'PM_MISSED'))
  loop
    v_today := coalesce(p_today, (now() at time zone r.tz)::date);
    v_grace := coalesce(r.grace_days, app.setting_int('pm.grace_days'), 0);
    continue when r.status = 'GENERATED' and r.period_key + v_grace >= v_today;
    if r.status = 'GENERATED' then
      update public.pm_periods set status = 'MISSED', missed_at = now() where id = r.id;
    end if;
    v_set := coalesce(r.sla_policy_set_id, (select id from public.sla_policy_sets where is_default and is_active limit 1));
    -- minimal satu baris event agar idempoten walau aturan eskalasi belum dikonfigurasi
    insert into public.sla_events (wo_id, pm_period_id, kind, level, target) values (r.wo_id, r.id, 'PM_MISSED', 1, '*') on conflict do nothing;
    get diagnostics v_ins = row_count;
    if v_ins > 0 then
      v_n := v_n + 1;
      for k in select * from public.escalation_rules er
                where er.policy_set_id = v_set and er.trigger_kind = 'PM_MISSED' and er.is_active order by er.level loop
        insert into public.sla_events (wo_id, pm_period_id, kind, level, target) values (r.wo_id, r.id, 'PM_MISSED', k.level, k.notify_role::text) on conflict do nothing;
        perform app.notify_role(k.notify_role, 'sla.pm_missed', r.wo_id,
                  jsonb_build_object('pm_period_id', r.id, 'due_date', r.period_key, 'level', k.level),
                  'pmmiss:' || r.id::text || ':' || k.level::text);
      end loop;
    end if;
  end loop;
  return v_n;
end $$;

-- ADM memutuskan periode MISSED: buat WO sekarang atau lewati dengan alasan (BR-024/025)
create or replace function public.pm_period_resolve(p_period_id uuid, p_action text, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare p public.pm_periods; ca public.contract_assets; c public.contracts; a public.assets; v_wo uuid; v_prio text;
begin
  if not app.has_any_role('{ADMIN_CS}') then raise exception 'WO002: hanya Admin/CS' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'WO003: alasan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;
  select * into p from public.pm_periods where id = p_period_id for update;
  if p.id is null or p.status <> 'MISSED' then raise exception 'WO001: periode bukan MISSED' using errcode = 'WO001'; end if;
  if p_action = 'SKIP' then
    update public.pm_periods set status = 'SKIPPED', skip_reason = p_reason where id = p_period_id;
    return null;
  elsif p_action = 'CREATE_NOW' then
    select * into ca from public.contract_assets where id = p.contract_asset_id;
    select * into c from public.contracts where id = ca.contract_id;
    select * into a from public.assets where id = ca.asset_id;
    if p.wo_id is not null and (select status from public.work_orders where id = p.wo_id) <> 'CANCELLED' then
      raise exception 'WO001: WO periode ini masih aktif' using errcode = 'WO001';
    end if;
    -- WO lama (dibatalkan) menempati unique periode; WO pengganti memakai periode kunci geser ditandai pada pm_period_key = hari ini
    v_prio := coalesce((select default_priority_code from public.service_types where id = ca.service_type_id),
                       app.setting_text('pm.default_priority_code'),
                       (select code from public.priorities where is_active order by sort_rank limit 1));
    v_wo := app.create_work_order('PREVENTIVE', c.customer_id, a.site_id, a.id, ca.service_type_id, null, ca.id,
                                  case when p.wo_id is null then p.period_key else current_date end, null, v_prio, null, auth.uid(),
                                  now(), 'COVERED_CONTRACT');
    if v_wo is null then raise exception 'WO001: WO periode sudah ada' using errcode = 'WO001'; end if;
    update public.pm_periods set wo_id = v_wo, status = 'GENERATED', skip_reason = p_reason where id = p_period_id;
    return v_wo;
  end if;
  raise exception 'WO006: action harus SKIP|CREATE_NOW' using errcode = 'WO006';
end $$;


-- ---- 0010g: suku cadang: permintaan, serah-terima, retur, selisih (BR-030..038) ------------------------------
create or replace function public.part_request_create(p_wo_id uuid, p_lines jsonb, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; w public.work_orders;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if w.id is null
     or not (app.has_any_role('{DISPATCHER}') or exists (select 1 from public.wo_assignments a
               where a.wo_id = p_wo_id and a.technician_id = app.my_technician_id() and a.status in ('ASSIGNED','ACCEPTED'))) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  if w.status in ('CLOSED','CANCELLED') then raise exception 'WO001: WO final' using errcode = 'WO001'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'WO006: minimal satu baris' using errcode = 'WO006';
  end if;
  insert into public.part_requests (request_no, wo_id, requested_by, note)
  values (app.next_doc_number('PR'), p_wo_id, auth.uid(), p_note) returning id into v_id;
  insert into public.part_request_lines (request_id, item_id, qty_requested)
  select v_id, x.item_id, x.qty from jsonb_to_recordset(p_lines) as x(item_id uuid, qty numeric);
  perform app.notify_role('WAREHOUSE', 'parts.requested', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'request_id', v_id), 'pr:' || v_id::text);
  return v_id;
end $$;

create or replace function public.part_request_decide(p_request_id uuid, p_decision text, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_any_role('{WAREHOUSE}') then raise exception 'WO002: hanya Gudang' using errcode = 'WO002'; end if;
  update public.part_requests set status = case p_decision when 'APPROVE' then 'APPROVED' when 'REJECT' then 'REJECTED' end::public.part_request_status,
         decided_by = auth.uid(), decided_at = now(), note = coalesce(p_note, note)
   where id = p_request_id and status = 'REQUESTED';
  if not found then raise exception 'WO001: permintaan tidak dapat diputuskan' using errcode = 'WO001'; end if;
end $$;

-- Serah-terima Gudang -> teknisi: stok gudang berkurang, stok teknisi bertambah; ditolak bila stok kurang (STK01).
create or replace function public.part_issue(p_line_id uuid, p_qty numeric, p_from_location_id uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare l public.part_request_lines; pr public.part_requests; v_tech uuid; v_to uuid; v_from uuid; v_mid uuid; v_open int;
begin
  if not app.has_any_role('{WAREHOUSE}') then raise exception 'WO002: hanya Gudang' using errcode = 'WO002'; end if;
  select * into l from public.part_request_lines where id = p_line_id for update;
  select * into pr from public.part_requests where id = l.request_id for update;
  if l.id is null or pr.status not in ('REQUESTED','APPROVED','PARTIALLY_ISSUED') then
    raise exception 'WO001: baris tidak dapat diserahkan' using errcode = 'WO001';
  end if;
  if p_qty is null or p_qty <= 0 or l.qty_issued + p_qty > l.qty_requested then
    raise exception 'WO006: jumlah melebihi sisa permintaan' using errcode = 'WO006';
  end if;
  select a.technician_id into v_tech from public.wo_assignments a
   where a.wo_id = pr.wo_id and a.role = 'LEAD' and a.status in ('ASSIGNED','ACCEPTED') limit 1;
  select id into v_to from public.stock_locations where technician_id = v_tech and type = 'TECHNICIAN' and is_active;
  v_from := coalesce(p_from_location_id, (select id from public.stock_locations where is_default_warehouse and is_active));
  if v_to is null or v_from is null then
    raise exception 'WO006: lokasi stok asal/tujuan tidak ditemukan' using errcode = 'WO006';
  end if;
  insert into public.stock_movements (item_id, from_location_id, to_location_id, qty, type, wo_id, ref_type, ref_id, actor_id)
  values (l.item_id, v_from, v_to, p_qty, 'ISSUE_TO_TECH', pr.wo_id, 'PART_REQUEST_LINE', l.id, auth.uid())
  returning id into v_mid;
  update public.part_request_lines set qty_issued = qty_issued + p_qty where id = l.id;
  select count(*) into v_open from public.part_request_lines where request_id = pr.id and qty_issued < qty_requested;
  update public.part_requests set status = case when v_open = 0 then 'ISSUED' else 'PARTIALLY_ISSUED' end::public.part_request_status,
         decided_by = coalesce(decided_by, auth.uid()), decided_at = coalesce(decided_at, now())
   where id = pr.id;
  perform app.notify_wo_technicians(pr.wo_id, 'parts.issued', jsonb_build_object('request_id', pr.id, 'line_id', l.id, 'qty', p_qty),
            'issue:' || v_mid::text);
  return v_mid;
end $$;

-- Teknisi mengajukan retur (PENDING); Gudang yang mengonfirmasi mutasi (BR-034).
create or replace function public.part_return_create(p_wo_id uuid, p_lines jsonb, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_tech uuid := app.my_technician_id(); v_id uuid;
begin
  if v_tech is null or not exists (select 1 from public.wo_assignments a where a.wo_id = p_wo_id and a.technician_id = v_tech) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  insert into public.part_returns (wo_id, technician_id, note) values (p_wo_id, v_tech, p_note) returning id into v_id;
  insert into public.part_return_lines (return_id, item_id, qty)
  select v_id, x.item_id, x.qty from jsonb_to_recordset(p_lines) as x(item_id uuid, qty numeric);
  perform app.notify_role('WAREHOUSE', 'parts.return_pending', p_wo_id, jsonb_build_object('return_id', v_id), 'ret:' || v_id::text);
  return v_id;
end $$;

create or replace function public.part_return_confirm(p_return_id uuid, p_lines jsonb default null,
                                                      p_to_location_id uuid default null, p_reject boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.part_returns; l record; v_from uuid; v_to uuid; v_qty numeric; v_final boolean;
begin
  if not app.has_any_role('{WAREHOUSE}') then raise exception 'WO002: hanya Gudang' using errcode = 'WO002'; end if;
  select * into r from public.part_returns where id = p_return_id for update;
  if r.id is null or r.status <> 'PENDING' then raise exception 'WO001: retur tidak dapat dikonfirmasi' using errcode = 'WO001'; end if;
  if p_reject then
    update public.part_returns set status = 'REJECTED', confirmed_by = auth.uid(), confirmed_at = now() where id = r.id;
    return;
  end if;
  select id into v_from from public.stock_locations where technician_id = r.technician_id and type = 'TECHNICIAN' and is_active;
  v_to := coalesce(p_to_location_id, (select id from public.stock_locations where is_default_warehouse and is_active));
  if v_from is null or v_to is null then raise exception 'WO006: lokasi stok tidak ditemukan' using errcode = 'WO006'; end if;
  for l in select rl.* from public.part_return_lines rl where rl.return_id = r.id loop
    v_qty := coalesce((select (x.confirmed_qty) from jsonb_to_recordset(p_lines) as x(item_id uuid, confirmed_qty numeric)
                        where x.item_id = l.item_id), l.qty);
    update public.part_return_lines set confirmed_qty = v_qty where id = l.id;
    if v_qty > 0 then
      insert into public.stock_movements (item_id, from_location_id, to_location_id, qty, type, wo_id, ref_type, ref_id, actor_id)
      values (l.item_id, v_from, v_to, v_qty, 'RETURN_FROM_TECH', r.wo_id, 'PART_RETURN', r.id, auth.uid());
    end if;
  end loop;
  update public.part_returns set status = 'CONFIRMED', confirmed_by = auth.uid(), confirmed_at = now() where id = r.id;
  select status in ('CLOSED','CANCELLED') into v_final from public.work_orders where id = r.wo_id;
  perform app.refresh_parts_variances(r.wo_id, false);           -- retur terlambat dapat menutup selisih OPEN otomatis
  if v_final then perform app.refresh_parts_variances(r.wo_id, true); end if;
end $$;

create or replace function public.stock_receive(p_item_id uuid, p_location_id uuid, p_qty numeric, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not app.has_any_role('{WAREHOUSE}') then raise exception 'WO002: hanya Gudang' using errcode = 'WO002'; end if;
  insert into public.stock_movements (item_id, to_location_id, qty, type, actor_id, note)
  values (p_item_id, p_location_id, p_qty, 'RECEIPT', auth.uid(), p_note) returning id into v_id;
  return v_id;
end $$;

-- Penyesuaian / opname (FR-127). delta > 0 menambah, < 0 mengurangi. Di atas ambang butuh Supervisor.
create or replace function public.stock_adjust(p_item_id uuid, p_location_id uuid, p_delta numeric, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_th int := app.setting_int('stock.adjustment_supervisor_threshold');
begin
  if not app.has_any_role('{WAREHOUSE,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_reason), '') = '' or p_delta is null or p_delta = 0 then
    raise exception 'WO006: alasan dan delta (non-nol) wajib' using errcode = 'WO006';
  end if;
  if v_th is not null and abs(p_delta) > v_th and not app.has_any_role('{SUPERVISOR}') then
    raise exception 'WO002: penyesuaian di atas ambang butuh Supervisor' using errcode = 'WO002';
  end if;
  insert into public.stock_movements (item_id, from_location_id, to_location_id, qty, type, actor_id, note)
  values (p_item_id, case when p_delta < 0 then p_location_id end, case when p_delta > 0 then p_location_id end,
          abs(p_delta), 'ADJUSTMENT', auth.uid(), p_reason) returning id into v_id;
  return v_id;
end $$;

-- Hitung selisih per (WO, item, teknisi): issued - used - returned (BR-031). Barang BULK tidak dilacak per WO.
create or replace function app.refresh_parts_variances(p_wo_id uuid, p_final boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.parts_variances as pv (wo_id, item_id, technician_id, issued, used, returned, is_final, status)
  select p_wo_id, k.item_id, k.technician_id, k.issued, k.used, k.returned, p_final,
         case when p_final and abs(k.issued - k.used - k.returned) > coalesce(i.variance_tolerance, 0) then 'OPEN'::public.variance_status end
    from (
      select coalesce(a.item_id, b.item_id, c.item_id) as item_id, coalesce(a.technician_id, b.technician_id, c.technician_id) as technician_id,
             coalesce(a.qty, 0) as issued, coalesce(b.qty, 0) as used, coalesce(c.qty, 0) as returned
        from (select m.item_id, sl.technician_id, sum(m.qty) as qty from public.stock_movements m
                join public.stock_locations sl on sl.id = m.to_location_id
               where m.wo_id = p_wo_id and m.type = 'ISSUE_TO_TECH' group by 1, 2) a
        full join (select u.item_id, u.technician_id, sum(u.qty) as qty from public.wo_part_usages u
                    join public.items it on it.id = u.item_id and it.tracking_mode = 'PER_WO'
                   where u.wo_id = p_wo_id and u.deleted_at is null group by 1, 2) b
               on b.item_id = a.item_id and b.technician_id = a.technician_id
        full join (select m.item_id, sl.technician_id, sum(m.qty) as qty from public.stock_movements m
                    join public.stock_locations sl on sl.id = m.from_location_id
                   where m.wo_id = p_wo_id and m.type = 'RETURN_FROM_TECH' group by 1, 2) c
               on c.item_id = coalesce(a.item_id, b.item_id) and c.technician_id = coalesce(a.technician_id, b.technician_id)
    ) k
    join public.items i on i.id = k.item_id
  on conflict (wo_id, item_id, technician_id) do update set
     issued = excluded.issued, used = excluded.used, returned = excluded.returned,
     is_final = pv.is_final or excluded.is_final,
     status = case
       when pv.status in ('EXPLAINED','RETURNED_LATE','WRITTEN_OFF','CHARGED_TO_CUSTOMER') then pv.status
       when excluded.is_final and abs(excluded.issued - excluded.used - excluded.returned)
            > coalesce((select variance_tolerance from public.items where id = excluded.item_id), 0) then 'OPEN'::public.variance_status
       when pv.status = 'OPEN' and excluded.issued - excluded.used - excluded.returned = 0 then 'RETURNED_LATE'::public.variance_status
       else pv.status end;
end $$;

-- Finalisasi setelah batas waktu retur (BR-032b). Batas NULL = final saat WO selesai/batal.
create or replace function app.finalize_parts_variances(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0; v_h int := coalesce(app.setting_int('parts.return_deadline_hours'), 0); v_open_before int; v_open_after int;
begin
  for r in
    select distinct w.id from public.parts_variances pv join public.work_orders w on w.id = pv.wo_id
     where not pv.is_final and w.status in ('CLOSED','CANCELLED')
       and coalesce(w.closed_at, w.cancelled_at) + make_interval(hours => v_h) <= p_now
  loop
    select count(*) into v_open_before from public.parts_variances where wo_id = r.id and status = 'OPEN';
    perform app.refresh_parts_variances(r.id, true);
    select count(*) into v_open_after from public.parts_variances where wo_id = r.id and status = 'OPEN';
    if v_open_after > v_open_before then
      perform app.notify_role('WAREHOUSE', 'parts.variance_open', r.id, jsonb_build_object('wo_id', r.id), 'pv-w:' || r.id::text);
      perform app.notify_role('SUPERVISOR', 'parts.variance_open', r.id, jsonb_build_object('wo_id', r.id), 'pv-s:' || r.id::text);
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.parts_variance_resolve(p_variance_id uuid, p_status public.variance_status, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.parts_variances; v_loc uuid;
begin
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'WO003: catatan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;
  if p_status in ('WRITTEN_OFF','CHARGED_TO_CUSTOMER') then
    if not app.has_any_role('{SUPERVISOR}') then raise exception 'WO002: butuh Supervisor' using errcode = 'WO002'; end if;
  elsif p_status in ('EXPLAINED','RETURNED_LATE') then
    if not app.has_any_role('{WAREHOUSE,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  else
    raise exception 'WO006: status tujuan tidak valid' using errcode = 'WO006';
  end if;
  select * into v from public.parts_variances where id = p_variance_id for update;
  if v.id is null or v.status is distinct from 'OPEN' then
    raise exception 'WO001: selisih tidak berstatus OPEN' using errcode = 'WO001';
  end if;
  if p_status = 'WRITTEN_OFF' and v.variance > 0 then            -- BR-033: koreksi lewat mutasi, bukan edit mutasi lama
    select id into v_loc from public.stock_locations where technician_id = v.technician_id and type = 'TECHNICIAN';
    insert into public.stock_movements (item_id, from_location_id, qty, type, wo_id, ref_type, ref_id, actor_id, note)
    values (v.item_id, v_loc, v.variance, 'ADJUSTMENT', v.wo_id, 'VARIANCE_WRITE_OFF', v.id, auth.uid(), p_note);
  end if;
  -- TODO: CHARGED_TO_CUSTOMER wajib melewati persetujuan biaya (BR-033/BR-050) - belum otomatis.
  update public.parts_variances set status = p_status, resolution_note = p_note, resolved_by = auth.uid(), resolved_at = now()
   where id = p_variance_id;
end $$;

-- ---- 0010h: job SLA, kedaluwarsa, retensi, heartbeat -----------------------------------------------------------------
create or replace function app.sla_fire_rules(p_wo_id uuid, p_wo_number text, p_set uuid, p_kind public.sla_event_kind,
                                              p_base timestamptz, p_now timestamptz, p_due timestamptz) returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare k record; v_fire timestamptz; v_next timestamptz; v_ins int;
begin
  for k in select * from public.escalation_rules er
            where er.policy_set_id = p_set and er.trigger_kind = p_kind and er.is_active order by er.level loop
    v_fire := p_base + make_interval(mins => k.after_minutes);
    if p_now >= v_fire then
      insert into public.sla_events (wo_id, kind, level, target) values (p_wo_id, p_kind, k.level, k.notify_role::text)
      on conflict do nothing;
      get diagnostics v_ins = row_count;
      if v_ins > 0 then                                              -- notifikasi hanya bila baris benar-benar baru (BR-014)
        perform app.notify_role(k.notify_role, 'sla.' || lower(p_kind::text), p_wo_id,
                  jsonb_build_object('wo_number', p_wo_number, 'level', k.level, 'due_at', p_due),
                  'sla:' || p_wo_id::text || ':' || p_kind::text || ':' || k.level::text || ':' || k.notify_role::text);
      end if;
    else
      v_next := least(v_next, v_fire);
    end if;
  end loop;
  return v_next;
end $$;

create or replace function app.run_sla_checks(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = '' as $$
declare
  w record; pol jsonb; v_warn numeric; v_total numeric; v_rem numeric; v_next timestamptz;
  v_rs public.sla_state; v_os public.sla_state; v_n int := 0; v_wthr numeric;
begin
  for w in select * from public.work_orders
            where status not in ('CLOSED','CANCELLED') and next_sla_check_at is not null and next_sla_check_at <= p_now
            order by next_sla_check_at for update skip locked
  loop
    v_next := null; v_rs := w.response_sla_state; v_os := w.resolution_sla_state; pol := w.policy_snapshot;
    if pol is null or w.sla_policy_set_id is null then
      update public.work_orders set next_sla_check_at = null where id = w.id;
      continue;
    end if;

    -- respons (BR-013)
    if w.response_met_at is null and w.response_due_at is not null then
      v_total := (pol ->> 'response_minutes')::numeric;
      v_warn := (pol ->> 'warning_pct')::numeric;
      v_wthr := case when v_warn is null or v_total is null then null else v_total * v_warn / 100 end;
      v_rem := app.sla_business_minutes_between(p_now, w.response_due_at, w.sla_calendar_id);
      v_rs := case when p_now > w.response_due_at then 'BREACHED'
                   when v_wthr is not null and v_rem <= v_wthr then 'WARNING' else 'RUNNING' end;
      if v_rs in ('WARNING','BREACHED') then
        v_next := least(v_next, app.sla_fire_rules(w.id, w.wo_number, w.sla_policy_set_id, 'RESPONSE_WARNING',
                   coalesce((select min(e.at) from public.sla_events e where e.wo_id = w.id and e.kind = 'RESPONSE_WARNING'), p_now),
                   p_now, w.response_due_at));
      end if;
      if v_rs = 'BREACHED' then
        v_next := least(v_next, app.sla_fire_rules(w.id, w.wo_number, w.sla_policy_set_id, 'RESPONSE_BREACH',
                   w.response_due_at, p_now, w.response_due_at));
      else
        v_next := least(v_next, w.response_due_at);
        if v_rs = 'RUNNING' and v_wthr is not null then
          v_next := least(v_next, app.sla_add_business_minutes(p_now, greatest(v_rem - v_wthr, 0), w.sla_calendar_id));
        end if;
      end if;
    end if;

    -- penyelesaian (BR-012: dijeda => tidak dievaluasi)
    if w.resolution_met_at is null and w.resolution_due_at is not null then
      if w.sla_paused_at is not null then
        v_os := 'PAUSED';
      else
        v_total := (pol ->> 'resolution_minutes')::numeric;
        v_warn := (pol ->> 'warning_pct')::numeric;
        v_wthr := case when w.type = 'PREVENTIVE' or v_warn is null or v_total is null then null else v_total * v_warn / 100 end;
        v_rem := app.sla_business_minutes_between(p_now, w.resolution_due_at, w.sla_calendar_id);
        v_os := case when p_now > w.resolution_due_at then 'BREACHED'
                     when v_wthr is not null and v_rem <= v_wthr then 'WARNING' else 'RUNNING' end;
        if v_os in ('WARNING','BREACHED') then
          v_next := least(v_next, app.sla_fire_rules(w.id, w.wo_number, w.sla_policy_set_id, 'RESOLUTION_WARNING',
                     coalesce((select min(e.at) from public.sla_events e where e.wo_id = w.id and e.kind = 'RESOLUTION_WARNING'), p_now),
                     p_now, w.resolution_due_at));
        end if;
        if v_os = 'BREACHED' then
          v_next := least(v_next, app.sla_fire_rules(w.id, w.wo_number, w.sla_policy_set_id, 'RESOLUTION_BREACH',
                     w.resolution_due_at, p_now, w.resolution_due_at));
        else
          v_next := least(v_next, w.resolution_due_at);
          if v_os = 'RUNNING' and v_wthr is not null then
            v_next := least(v_next, app.sla_add_business_minutes(p_now, greatest(v_rem - v_wthr, 0), w.sla_calendar_id));
          end if;
        end if;
      end if;
    end if;

    update public.work_orders set response_sla_state = v_rs, resolution_sla_state = v_os, next_sla_check_at = v_next
     where id = w.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- T-15 dan T-18 versi SYS: kedaluwarsa persetujuan biaya & tanda tangan
create or replace function app.expire_pending_customer_actions(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select a.id as approval_id, a.wo_id from public.extra_cost_approvals a
             join public.work_orders w on w.id = a.wo_id
            where a.status = 'PENDING' and a.expires_at is not null and a.expires_at <= p_now
              and w.status = 'AWAITING_CUSTOMER_APPROVAL'
            for update of a skip locked
  loop
    update public.extra_cost_approvals set status = 'EXPIRED', decided_at = p_now, continue_original_scope = true
     where id = r.approval_id;
    perform app.apply_wo_transition(r.wo_id, 'EXPIRE_EXTRA_COST', null, '{}'::public.app_role[], true, null, null,
              'persetujuan kedaluwarsa', 'EXPIRED', jsonb_build_object('approval_id', r.approval_id), p_now);
    v_n := v_n + 1;
  end loop;
  for r in select w.id from public.work_orders w
            where w.status = 'AWAITING_SIGNOFF' and w.signoff_expires_at is not null and w.signoff_expires_at <= p_now
            for update skip locked
  loop
    perform app.apply_wo_transition(r.id, 'EXPIRE_SIGNOFF', null, '{}'::public.app_role[], true, null, null,
              'tanda tangan kedaluwarsa', 'NO_RESPONSE', '{}'::jsonb, p_now);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Retensi teknis (NFR-S6). Nilai [P] dari app_settings; NULL = tidak dihapus.
-- audit_logs/access_logs append-only: retensi lewat partisi/arsip (TODO), bukan DELETE.
create or replace function app.purge_expired_data() returns int
language plpgsql security definer set search_path = '' as $$
declare v_n int := 0; v_d int; v_c int;
begin
  delete from public.rate_limits where window_start < now() - interval '2 days';          -- data teknis, bukan retensi bisnis
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  v_d := app.setting_int('retention.notifications_days');
  if v_d is not null then
    delete from public.notifications where status in ('SENT','READ') and created_at < now() - make_interval(days => v_d);
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  v_d := app.setting_int('retention.sync_operations_days');
  if v_d is not null then
    delete from public.sync_operations where status = 'APPLIED' and received_at < now() - make_interval(days => v_d);
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  v_d := app.setting_int('retention.job_runs_days');
  if v_d is not null then
    delete from public.job_runs where started_at < now() - make_interval(days => v_d);
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  -- TODO (NFR-D5): anonimisasi data pribadi pelanggan setelah masa retensi [P] (customers.anonymized_at).
  return v_n;
end $$;

-- Pembungkus job dengan heartbeat (RK-15). Dipanggil pg_cron.
create or replace function app.run_job(p_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_n int;
begin
  insert into public.job_runs (job_name) values (p_name) returning id into v_id;
  begin
    v_n := case p_name
      when 'sla_check' then app.run_sla_checks()
      when 'pm_generate' then app.generate_preventive_work_orders()
      when 'pm_missed' then app.mark_missed_pm_periods()
      when 'expire_customer_actions' then app.expire_pending_customer_actions()
      when 'parts_variance_finalize' then app.finalize_parts_variances()
      when 'retention_purge' then app.purge_expired_data()
      else null end;
    if v_n is null and p_name not in ('sla_check','pm_generate','pm_missed','expire_customer_actions','parts_variance_finalize','retention_purge') then
      raise exception 'job tidak dikenal: %', p_name;
    end if;
    update public.job_runs set status = 'OK', finished_at = now(), rows_affected = v_n where id = v_id;
  exception when others then
    update public.job_runs set status = 'ERROR', finished_at = now(), error = sqlerrm where id = v_id;
  end;
end $$;

-- ---- 0010i: akses data (log), registrasi pelanggan ------------------------------------------------------------------------
create or replace function public.log_data_access(p_customer_id uuid, p_resource_type text, p_resource_id text,
                                                  p_action text default 'READ') returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_any_role('{ADMIN_CS,DISPATCHER,TECHNICIAN,SUPERVISOR,WAREHOUSE,FINANCE,OWNER}') then
    raise exception 'WO002: hanya staf' using errcode = 'WO002';
  end if;
  insert into public.access_logs (actor_id, customer_id, resource_type, resource_id, action)
  values (auth.uid(), p_customer_id, p_resource_type, p_resource_id, p_action);
end $$;

-- Registrasi mandiri pelanggan perorangan (D1/Q1). Diaktifkan bila app_settings registration.mode IN ('SELF','BOTH').
create or replace function public.register_individual_customer(p_full_name text, p_phone text, p_policy_version text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_mode text := app.setting_text('registration.mode'); v_cid uuid; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'WO002: tidak terautentikasi' using errcode = 'WO002'; end if;
  if v_mode is null or v_mode not in ('SELF','BOTH') then
    raise exception 'WO002: registrasi mandiri tidak diaktifkan' using errcode = 'WO002';
  end if;
  if coalesce(btrim(p_policy_version), '') = '' then
    raise exception 'WO006: persetujuan kebijakan privasi wajib (NFR-D2)' using errcode = 'WO006';
  end if;
  if exists (select 1 from public.user_roles where user_id = v_uid) then
    raise exception 'WO001: akun sudah memiliki peran' using errcode = 'WO001';
  end if;
  update public.profiles set full_name = coalesce(nullif(btrim(p_full_name), ''), full_name), phone = p_phone where user_id = v_uid;
  insert into public.customers (code, name, type, contact_name, contact_phone, contact_email)
  values (app.next_doc_number('CUS'), coalesce(nullif(btrim(p_full_name), ''), 'Pelanggan'), 'INDIVIDUAL', p_full_name, p_phone,
          auth.jwt() ->> 'email') returning id into v_cid;
  insert into public.customer_users (customer_id, user_id, customer_role) values (v_cid, v_uid, 'ADMIN');
  insert into public.user_roles (user_id, role) values (v_uid, 'CUSTOMER');
  insert into public.user_consents (user_id, policy_version) values (v_uid, p_policy_version);
  return v_cid;
end $$;

-- Terima undangan admin (token sekali pakai; hanya hash disimpan). Email undangan harus sama dengan email akun.
create or replace function public.accept_customer_invitation(p_token text, p_policy_version text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare i public.customer_invitations; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'WO002: tidak terautentikasi' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_policy_version), '') = '' then
    raise exception 'WO006: persetujuan kebijakan privasi wajib (NFR-D2)' using errcode = 'WO006';
  end if;
  select * into i from public.customer_invitations
   where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') for update;
  if i.id is null or i.accepted_at is not null or i.expires_at < now()
     or lower(i.email) <> lower(coalesce(auth.jwt() ->> 'email', '')) then
    raise exception 'WO005: undangan tidak valid' using errcode = 'WO005';       -- pesan seragam
  end if;
  if exists (select 1 from public.user_roles where user_id = v_uid and role <> 'CUSTOMER') then
    raise exception 'WO001: akun staf tidak dapat menerima undangan pelanggan' using errcode = 'WO001';
  end if;
  insert into public.customer_users (customer_id, user_id, customer_role, invited_by)
  values (i.customer_id, v_uid, i.customer_role, i.created_by) on conflict (customer_id, user_id) do update set is_active = true;
  insert into public.user_roles (user_id, role) values (v_uid, 'CUSTOMER') on conflict do nothing;
  insert into public.user_consents (user_id, policy_version) values (v_uid, p_policy_version);
  update public.customer_invitations set accepted_at = now(), accepted_by = v_uid where id = i.id;
  return i.customer_id;
end $$;


-- ===== MIGRATION 0011: view =========================================================
-- View pelanggan: SECURITY DEFINER (default) + security_barrier. Pelanggan TIDAK punya akses ke tabel mentah
-- work_orders/wo_*; semua pembacaan lewat view ini yang menyaring customer_id = ANY(app.my_customer_ids())
-- dan hanya mengekspos kolom aman + status yang sudah dipetakan (AP-3, 4.2).

create or replace view public.customer_requests with (security_barrier = true) as
select sr.id as request_id, sr.request_no, sr.customer_id, sr.site_id, sr.asset_id, sr.problem_type_id, sr.description,
       sr.preferred_start, sr.preferred_end, sr.channel, sr.created_at as requested_at, sr.client_request_id,
       sr.version as request_version, (sr.duplicate_of is not null) as possible_duplicate,
       w.id as wo_id, w.wo_number,
       case when w.id is not null then app.customer_status(w.status)
            when sr.status = 'REJECTED' then 'UNPROCESSABLE'
            when sr.status = 'CANCELLED_BY_CUSTOMER' then 'CANCELLED'
            else 'RECEIVED' end as display_status,
       (sr.status = 'NEEDS_INFO') as needs_info,
       coalesce(w.customer_note, case sr.status when 'NEEDS_INFO' then sr.needs_info_note
                                                when 'REJECTED' then sr.decision_reason end) as status_note
from public.service_requests sr
left join public.work_orders w on w.request_id = sr.id
where sr.customer_id = any ((select app.my_customer_ids())::uuid[]);

create or replace view public.customer_work_orders with (security_barrier = true) as
select w.id as wo_id, w.wo_number, w.type as wo_type, w.customer_id, w.site_id, w.asset_id, w.request_id,
       app.customer_status(w.status) as display_status,
       case when w.status = 'CANCELLED' then coalesce(w.cancel_reason, w.customer_note) else w.customer_note end as status_note,
       (w.status in ('AWAITING_CUSTOMER_APPROVAL','AWAITING_SIGNOFF')) as awaiting_customer_action,
       w.status = 'AWAITING_SIGNOFF' as awaiting_signoff,
       (select a.id from public.extra_cost_approvals a where a.wo_id = w.id and a.status = 'PENDING') as pending_approval_id,
       -- jadwal & nama teknisi baru tampil setelah teknisi menerima (DEC-02)
       case when w.status not in ('NEW','ASSIGNED','CANCELLED') then w.scheduled_start end as scheduled_start,
       case when w.status not in ('NEW','ASSIGNED','CANCELLED') then w.scheduled_end end as scheduled_end,
       case when w.status not in ('NEW','ASSIGNED','CANCELLED') then
         (select p.full_name from public.wo_assignments x join public.technicians t on t.id = x.technician_id
            join public.profiles p on p.user_id = t.user_id
           where x.wo_id = w.id and x.role = 'LEAD' and x.status in ('ACCEPTED','COMPLETED') limit 1) end as technician_name,
       w.requested_at, w.closed_at, w.cancel_requested_at, w.version as wo_version,
       (w.status = 'CLOSED' and exists (select 1 from public.ratings r where r.wo_id = w.id)) as rated
from public.work_orders w
where w.customer_id = any ((select app.my_customer_ids())::uuid[]);

create or replace view public.customer_wo_timeline with (security_barrier = true) as
select h.wo_id, h.at, app.customer_status(h.to_status) as display_status, h.customer_note
from public.wo_status_history h
join public.work_orders w on w.id = h.wo_id
where w.customer_id = any ((select app.my_customer_ids())::uuid[])
  and (h.from_status is null or app.customer_status(h.from_status) is distinct from app.customer_status(h.to_status));

create or replace view public.customer_extra_cost_approvals with (security_barrier = true) as
select a.id as approval_id, a.wo_id, a.version_no, a.status, a.total, a.reason, a.requested_at, a.expires_at, a.content_hash,
       (select coalesce(jsonb_agg(jsonb_build_object('kind', i.kind, 'description', i.description, 'qty', i.qty,
                'unit_price', i.unit_price, 'subtotal', i.subtotal) order by i.description), '[]'::jsonb)
          from public.extra_cost_approval_items i where i.approval_id = a.id) as items
from public.extra_cost_approvals a
join public.work_orders w on w.id = a.wo_id
where w.customer_id = any ((select app.my_customer_ids())::uuid[]) and a.status <> 'SUPERSEDED';

-- Foto laporan: hanya foto BEFORE/AFTER/FINDING yang sudah UPLOADED dari WO CLOSED (FR-056, matriks "foto laporan").
create or replace view public.customer_wo_photos with (security_barrier = true) as
select x.id as attachment_id, x.wo_id, x.kind, x.storage_path, x.taken_at
from public.wo_attachments x
join public.work_orders w on w.id = x.wo_id
where w.customer_id = any ((select app.my_customer_ids())::uuid[]) and w.status = 'CLOSED'
  and x.deleted_at is null and x.upload_status = 'UPLOADED' and x.kind in ('BEFORE','AFTER','FINDING');

create or replace view public.customer_service_reports with (security_barrier = true) as
select r.id as report_id, r.wo_id, r.revision, r.storage_path, r.generated_at, r.sent_at
from public.service_reports r
join public.work_orders w on w.id = r.wo_id
where r.customer_id = any ((select app.my_customer_ids())::uuid[]) and w.status = 'CLOSED' and r.status = 'READY';

-- Riwayat servis aset untuk teknisi (AP-2): hanya aset dari WO aktifnya, tanpa harga/catatan internal.
create or replace view public.v_tech_asset_service_history with (security_barrier = true) as
select w.asset_id, w.id as wo_id, w.wo_number, w.type as wo_type, w.closed_at, f.diagnosis, f.action_taken
from public.work_orders w
left join public.wo_findings f on f.wo_id = w.id
where w.status = 'CLOSED' and w.asset_id in (select app.tech_asset_ids());

-- View operasional (RLS pemanggil berlaku: security_invoker).
create or replace view public.v_today_work_orders with (security_invoker = true) as
select w.id as wo_id, w.wo_number, w.type, w.status, w.priority_code, w.customer_id, w.asset_id, w.scheduled_start, w.scheduled_end,
       w.response_sla_state, w.resolution_sla_state, w.response_due_at, w.resolution_due_at,
       (select a.technician_id from public.wo_assignments a where a.wo_id = w.id and a.role = 'LEAD'
          and a.status in ('ASSIGNED','ACCEPTED') limit 1) as lead_technician_id
from public.work_orders w
where w.status not in ('CLOSED','CANCELLED');

create or replace view public.v_open_part_variances with (security_invoker = true) as
select pv.* from public.parts_variances pv where pv.status = 'OPEN';

create or replace view public.v_job_health with (security_invoker = true) as
select distinct on (job_name) job_name, started_at, finished_at, status, rows_affected, error
from public.job_runs order by job_name, started_at desc;

-- Antrean Finance (L3 ringkas): WO CLOSED yang siap ditagih dan belum punya baris invoice (SP-05b).
create or replace view public.v_finance_ready_to_bill with (security_invoker = true) as
select w.id as wo_id, w.wo_number, w.customer_id, w.billing_type, w.closed_at
from public.work_orders w
where w.status = 'CLOSED' and w.billing_status = 'PENDING'
  and not exists (select 1 from public.invoice_lines il where il.wo_id = w.id);

-- M2: % WO selesai dalam SLA per bulan (contoh KPI; dashboard lain = TODO Lapis 3).
create or replace view public.v_kpi_sla_monthly with (security_invoker = true) as
select date_trunc('month', w.closed_at) as month, count(*) as closed_total,
       count(*) filter (where w.resolution_sla_state = 'MET') as within_sla,
       count(*) filter (where w.resolution_sla_state = 'MET_LATE') as late
from public.work_orders w
where w.status = 'CLOSED' and w.resolution_sla_state in ('MET','MET_LATE')
group by 1;
-- TODO Lapis 3: v_kpi_technician_productivity, v_kpi_asset_recurrence, v_kpi_contract_profit (butuh sumber biaya, R18/Q19),
--               v_kpi_request_to_assignment (M1), v_kpi_close_to_invoice (M3), v_kpi_pm_ontime (M4), v_kpi_parts_variance (M6).

-- ===== MIGRATION 0012: indeks (termasuk yang mendukung policy RLS) ====================
-- Indeks FK + akses kueri + predikat RLS. Catatan performa ada di 05_rls_and_security.md.
create index ix_customer_users_user on public.customer_users (user_id) where is_active;        -- app.my_customer_ids()
create index ix_user_roles_role on public.user_roles (role, user_id);                             -- notify_role()
create index ix_customer_sites_customer on public.customer_sites (customer_id);
create index ix_assets_customer on public.assets (customer_id);
create index ix_assets_site on public.assets (site_id);
create index ix_assets_category on public.assets (category_id);
create index ix_contracts_customer on public.contracts (customer_id);
create index ix_contracts_active on public.contracts (status, start_date, end_date);
create index ix_contract_assets_asset on public.contract_assets (asset_id) where is_active;
create index ix_pm_periods_wo on public.pm_periods (wo_id);
create index ix_pm_periods_status on public.pm_periods (status, period_key);
create index ix_problem_types_st on public.problem_types (service_type_id);
create index ix_technician_skills_skill on public.technician_skills (skill_id);

create index ix_sr_customer on public.service_requests (customer_id, created_at desc);
create index ix_sr_queue on public.service_requests (created_at) where status in ('SUBMITTED','NEEDS_INFO');   -- antrean validasi admin
create index ix_sr_dup on public.service_requests (customer_id, asset_id, problem_type_id, created_at desc);
create index ix_sr_asset on public.service_requests (asset_id);
create index ix_req_att_request on public.request_attachments (request_id);
create index ix_req_att_customer on public.request_attachments (customer_id);

create index ix_wo_customer_status on public.work_orders (customer_id, status);                  -- RLS pelanggan + daftar
create index ix_wo_customer_created on public.work_orders (customer_id, created_at desc);
create index ix_wo_active_sched on public.work_orders (scheduled_start) where status not in ('CLOSED','CANCELLED');   -- monitor hari ini
create index ix_wo_status on public.work_orders (status, priority_code);
create index ix_wo_asset_closed on public.work_orders (asset_id, closed_at desc);                -- riwayat aset
create index ix_wo_sla_next on public.work_orders (next_sla_check_at)
  where next_sla_check_at is not null and status not in ('CLOSED','CANCELLED');                   -- job SLA (BR-014)
create index ix_wo_signoff_exp on public.work_orders (signoff_expires_at) where status = 'AWAITING_SIGNOFF';
create index ix_wo_contract on public.work_orders (contract_id);
create index ix_wo_parent on public.work_orders (parent_wo_id) where parent_wo_id is not null;
create index ix_wo_service_type on public.work_orders (service_type_id);

create index ix_wsh_wo on public.wo_status_history (wo_id, at);
create unique index uq_wsh_op on public.wo_status_history (wo_id, op_id) where op_id is not null;   -- idempotensi transisi
create unique index uq_wo_assign_active_lead on public.wo_assignments (wo_id) where role = 'LEAD' and status in ('ASSIGNED','ACCEPTED');
create index ix_wo_assign_tech on public.wo_assignments (technician_id, status) include (wo_id);  -- RLS teknisi: my_active_wo_ids()
create index ix_wo_assign_wo on public.wo_assignments (wo_id);
create index ix_wo_visits_wo on public.wo_visits (wo_id);
create unique index uq_wo_visits_open on public.wo_visits (wo_id, technician_id) where check_out_at is null and check_in_at is not null;
create unique index uq_wo_checklist_op on public.wo_checklist_items (wo_id, op_id) where op_id is not null;
create index ix_wo_att_wo on public.wo_attachments (wo_id, kind) where deleted_at is null;
create unique index uq_wo_att_op on public.wo_attachments (op_id) where op_id is not null;
create index ix_wo_att_approval on public.wo_attachments (extra_approval_id) where extra_approval_id is not null;
create index ix_wo_sig_wo on public.wo_signatures (wo_id, status);
create index ix_wo_labor_wo on public.wo_labor_lines (wo_id) where deleted_at is null;
create unique index uq_wo_labor_op on public.wo_labor_lines (op_id) where op_id is not null;
create index ix_wo_usage_wo on public.wo_part_usages (wo_id) where deleted_at is null;
create index ix_wo_usage_item on public.wo_part_usages (item_id);
create unique index uq_wo_usage_op on public.wo_part_usages (op_id) where op_id is not null;
create index ix_extra_wo on public.extra_cost_approvals (wo_id, status);
create unique index uq_extra_pending on public.extra_cost_approvals (wo_id) where status = 'PENDING';   -- satu PENDING per WO
create index ix_extra_expiry on public.extra_cost_approvals (expires_at) where status = 'PENDING';
create index ix_extra_items_approval on public.extra_cost_approval_items (approval_id);
create index ix_sla_pauses_open on public.sla_pauses (wo_id) where resumed_at is null;
create index ix_reports_customer on public.service_reports (customer_id);
create index ix_ratings_customer on public.ratings (customer_id);
create index ix_complaints_wo on public.complaints (wo_id);
create index ix_complaints_customer on public.complaints (customer_id);

create index ix_sm_item on public.stock_movements (item_id, created_at);
create index ix_sm_wo on public.stock_movements (wo_id, type) where wo_id is not null;
create index ix_sm_from on public.stock_movements (from_location_id) where from_location_id is not null;
create index ix_sm_to on public.stock_movements (to_location_id) where to_location_id is not null;
create index ix_sm_ref on public.stock_movements (ref_type, ref_id);
create index ix_pr_wo on public.part_requests (wo_id, status);
create index ix_prl_item on public.part_request_lines (item_id);
create index ix_returns_wo on public.part_returns (wo_id);
create index ix_variance_open on public.parts_variances (status) where status = 'OPEN';

create index ix_invoices_customer on public.invoices (customer_id);
create index ix_invoice_lines_wo on public.invoice_lines (wo_id);
create index ix_payments_invoice on public.payments (invoice_id);

create index ix_notif_user on public.notifications (user_id, created_at desc) where read_at is null;
create index ix_notif_queue on public.notifications (scheduled_at) where status = 'PENDING';     -- worker pengirim
create unique index uq_notif_dedupe on public.notifications (dedupe_key, channel) where dedupe_key is not null;
create index ix_audit_entity on public.audit_logs (entity_type, entity_id, at desc);
create index ix_audit_actor on public.audit_logs (actor_id, at desc);
create index ix_audit_at_brin on public.audit_logs using brin (at);
create index ix_access_customer on public.access_logs (customer_id, at desc);
create index ix_access_actor on public.access_logs (actor_id, at desc);
create index ix_sync_wo on public.sync_operations (wo_id, status);
create index ix_sync_pending on public.sync_operations (received_at) where status = 'RECEIVED';
create index ix_sync_device on public.sync_operations (user_id, device_id, seq);
create index ix_job_runs on public.job_runs (job_name, started_at desc);
create index ix_invites_customer on public.customer_invitations (customer_id);

-- Pencarian teks (FR-039/L3): hanya bila pg_trgm tersedia.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_trgm') then
    execute 'create index ix_customers_name_trgm on public.customers using gin (name extensions.gin_trgm_ops)';
    execute 'create index ix_assets_code_trgm on public.assets using gin (asset_code extensions.gin_trgm_ops)';
    execute 'create index ix_assets_serial_trgm on public.assets using gin (serial_no extensions.gin_trgm_ops)';
    execute 'create index ix_wo_number_trgm on public.work_orders using gin (wo_number extensions.gin_trgm_ops)';
  end if;
end $$;


-- ===== MIGRATION 0013: RLS, privilege, view terbatas, Storage ==========================
-- Strategi lengkap + matriks: 05_rls_and_security.md. Prinsip: default tolak.
--  * Semua tabel public: RLS aktif. Tabel tanpa policy = tertutup untuk anon/authenticated.
--  * Penulisan sensitif hanya lewat RPC SECURITY DEFINER (peran dicek di dalam fungsi).
--  * Fungsi SECURITY DEFINER dimiliki postgres (bypass RLS) = jalur kode tepercaya. Jangan pakai FORCE RLS.

-- ---- helper tambahan untuk policy ----------------------------------------------------------------
create or replace function app.tech_request_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select w.request_id from public.work_orders w
   where w.request_id is not null and w.id in (select app.my_active_wo_ids())
$$;

create or replace function app.my_location_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select sl.id from public.stock_locations sl where sl.technician_id = app.my_technician_id()
$$;

create or replace function app.wo_storage_prefix(p_wo_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select w.customer_id::text || '/wo/' || w.id::text || '/' from public.work_orders w where w.id = p_wo_id
$$;

create or replace function app.can_edit_wo(p_wo_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_wo_id in (select app.my_editable_wo_ids())
$$;

-- Akses objek Storage (path: {customer_id}/{req|wo}/{owner_id}/{file}). Dipakai policy storage.objects.
create or replace function app.can_read_object(p_bucket text, p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_cust uuid; v_scope text; v_owner uuid;
begin
  if p_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(req|wo)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.+' then
    return false;                                              -- path tak sesuai konvensi => tolak
  end if;
  v_cust := split_part(p_name, '/', 1)::uuid;
  v_scope := split_part(p_name, '/', 2);
  v_owner := split_part(p_name, '/', 3)::uuid;

  if app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}') then return true; end if;     -- akses staf dicatat via log_data_access (API)
  if p_bucket = 'reports' and app.has_any_role('{FINANCE}') then return true; end if;

  if app.has_any_role('{TECHNICIAN}') then
    if v_scope = 'wo' and v_owner in (select app.my_active_wo_ids()) then return true; end if;
    if v_scope = 'req' and v_owner in (select app.tech_request_ids()) then return true; end if;
  end if;

  if v_cust = any ((select app.my_customer_ids())::uuid[]) then                  -- pelanggan: hanya objek yang terdaftar & boleh dilihat
    if p_bucket = 'reports' then
      return exists (select 1 from public.service_reports r join public.work_orders w on w.id = r.wo_id
                      where r.storage_path = p_name and r.customer_id = v_cust and r.status = 'READY' and w.status = 'CLOSED');
    end if;
    if v_scope = 'req' then
      return exists (select 1 from public.request_attachments a where a.storage_path = p_name and a.customer_id = v_cust);
    end if;
    return exists (select 1 from public.wo_attachments x join public.work_orders w on w.id = x.wo_id
                    where x.storage_path = p_name and w.customer_id = v_cust and w.status = 'CLOSED' and x.deleted_at is null
                      and x.upload_status = 'UPLOADED' and x.kind in ('BEFORE','AFTER','FINDING'))
        or exists (select 1 from public.wo_signatures g join public.work_orders w on w.id = g.wo_id
                    where g.storage_path = p_name and w.customer_id = v_cust and w.status = 'CLOSED' and g.status = 'VALID');
  end if;
  return false;
end $$;

-- ---- RPC administrasi pengguna & estimasi -------------------------------------------------------------
create or replace function public.admin_set_user_roles(p_user_id uuid, p_roles public.app_role[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v_old public.app_role[]; v_changed public.app_role[]; r public.app_role;
begin
  if not app.has_any_role('{ADMIN_CS,OWNER}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  select coalesce(array_agg(role), '{}') into v_old from public.user_roles where user_id = p_user_id;
  -- selisih simetris
  select coalesce(array_agg(x), '{}') into v_changed from (
    select unnest(v_old) except select unnest(coalesce(p_roles, '{}'))
    union select unnest(coalesce(p_roles, '{}')) except select unnest(v_old)) q(x);
  -- hardening eskalasi hak: hanya OWNER boleh mengubah OWNER/ADMIN_CS
  if ('OWNER' = any (v_changed) or 'ADMIN_CS' = any (v_changed)) and not app.has_any_role('{OWNER}') then
    raise exception 'WO002: hanya Owner yang boleh mengubah peran OWNER/ADMIN_CS' using errcode = 'WO002';
  end if;
  delete from public.user_roles where user_id = p_user_id and not (role = any (coalesce(p_roles, '{}')));
  foreach r in array coalesce(p_roles, '{}') loop
    insert into public.user_roles (user_id, role, granted_by) values (p_user_id, r, auth.uid()) on conflict do nothing;
  end loop;
end $$;

create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_any_role('{ADMIN_CS,OWNER}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  update public.profiles set is_active = p_active, deactivated_at = case when p_active then null else now() end where user_id = p_user_id;
  -- FR-007: pencabutan sesi aktif (auth.admin.signOut) dilakukan API server setelah RPC ini; RLS sudah menolak seketika.
end $$;

create or replace function public.wo_set_estimate(p_wo_id uuid, p_estimate numeric, p_expected_version int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not app.has_any_role('{ADMIN_CS,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  select * into w from public.work_orders where id = p_wo_id for update;
  if w.id is null then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  if w.status in ('CLOSED','CANCELLED') then raise exception 'WO001: WO final' using errcode = 'WO001'; end if;
  if w.version <> p_expected_version then
    raise exception 'WO004: konflik versi' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;
  update public.work_orders set estimate_total = p_estimate, estimate_version = estimate_version + 1 where id = p_wo_id
    returning * into w;
  return jsonb_build_object('status', w.status, 'version', w.version, 'estimate_version', w.estimate_version);
end $$;

-- ---- view terbatas untuk teknisi & gudang (tanpa harga/margin, AP-2) --------------------------------------
create or replace view public.tech_wo_part_usages with (security_barrier = true) as
select u.id, u.wo_id, u.item_id, u.qty, u.is_extra, u.extra_approval_id, u.emergency, u.unsourced, u.op_id, u.deleted_at, u.created_at
from public.wo_part_usages u where u.wo_id in (select app.my_active_wo_ids());

create or replace view public.tech_wo_labor_lines with (security_barrier = true) as
select l.id, l.wo_id, l.service_item_id, l.description, l.qty, l.is_extra, l.extra_approval_id, l.emergency, l.op_id, l.deleted_at, l.created_at
from public.wo_labor_lines l where l.wo_id in (select app.my_active_wo_ids());

create or replace view public.tech_extra_cost_approvals with (security_barrier = true) as
select a.id as approval_id, a.wo_id, a.version_no, a.status, a.reason, a.requested_at, a.expires_at, a.decided_at, a.continue_original_scope
from public.extra_cost_approvals a where a.wo_id in (select app.my_active_wo_ids());

create or replace view public.v_items_catalog with (security_barrier = true) as
select i.id, i.sku, i.name, i.uom, i.is_serialized, i.tracking_mode, i.is_active
from public.items i
where app.has_any_role('{ADMIN_CS,DISPATCHER,TECHNICIAN,SUPERVISOR,WAREHOUSE,FINANCE,OWNER}');

create or replace view public.v_wh_part_requests with (security_barrier = true) as
select pr.id as request_id, pr.request_no, pr.status, pr.created_at, w.id as wo_id, w.wo_number, w.status as wo_status,
       a.asset_code, p.full_name as technician_name,
       (select coalesce(jsonb_agg(jsonb_build_object('line_id', l.id, 'item_id', l.item_id, 'qty_requested', l.qty_requested,
               'qty_issued', l.qty_issued)), '[]'::jsonb) from public.part_request_lines l where l.request_id = pr.id) as lines
from public.part_requests pr
join public.work_orders w on w.id = pr.wo_id
join public.assets a on a.id = w.asset_id
left join public.wo_assignments x on x.wo_id = w.id and x.role = 'LEAD' and x.status in ('ASSIGNED','ACCEPTED','COMPLETED')
left join public.technicians t on t.id = x.technician_id
left join public.profiles p on p.user_id = t.user_id
where app.has_any_role('{WAREHOUSE,SUPERVISOR,OWNER,DISPATCHER}');

-- ---- RLS aktif di SEMUA tabel public ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' loop
    execute format('alter table public.%I enable row level security', r.relname);
  end loop;
end $$;

-- Pemeriksaan CI (NFR-S3): harus mengembalikan 0 baris.
create or replace function app.tables_without_rls() returns table (table_name text)
language sql stable as $$
  select c.relname::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r','p') and not c.relrowsecurity
$$;

-- ---- privilege dasar ----------------------------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

revoke all on schema app from public, anon, authenticated;
revoke execute on all functions in schema app from public, anon, authenticated;
grant usage on schema app to authenticated;
grant execute on function
  app.my_roles(), app.has_any_role(public.app_role[]), app.my_customer_ids(), app.my_technician_id(),
  app.my_active_wo_ids(), app.my_editable_wo_ids(), app.tech_customer_ids(), app.tech_site_ids(), app.tech_asset_ids(),
  app.tech_request_ids(), app.my_location_ids(), app.customer_owns_wo(uuid), app.wo_storage_prefix(uuid),
  app.can_edit_wo(uuid), app.can_read_object(text, text), app.customer_status(public.wo_status)
to authenticated;

grant select on all tables in schema public to authenticated;
revoke select on public.rate_limits, public.document_counters from authenticated;

-- Penulisan langsung (tetap dibatasi RLS + trigger). Kolom sensitif sengaja TIDAK diberi hak tulis.
grant insert, update on public.customers, public.customer_sites, public.assets, public.asset_categories, public.service_types,
  public.problem_types, public.service_items, public.checklist_templates, public.checklist_template_items,
  public.photo_requirements, public.skills, public.technicians, public.technician_skills, public.contracts,
  public.contract_assets, public.items, public.stock_locations, public.business_calendars, public.calendar_hours,
  public.calendar_holidays, public.sla_policy_sets, public.sla_policies, public.escalation_rules, public.app_settings,
  public.customer_invitations, public.import_jobs, public.invoices, public.invoice_lines, public.payments, public.priorities,
  public.reason_codes to authenticated;
grant delete on public.calendar_hours, public.calendar_holidays, public.technician_skills, public.photo_requirements,
  public.checklist_template_items, public.escalation_rules, public.invoice_lines to authenticated;

grant insert (id, customer_id, site_id, asset_id, problem_type_id, description, preferred_start, preferred_end, channel, client_request_id)
  on public.service_requests to authenticated;
grant update (description, preferred_start, preferred_end, problem_type_id, site_id, asset_id, status)
  on public.service_requests to authenticated;
grant insert (id, request_id, customer_id, storage_path, mime, bytes, checksum) on public.request_attachments to authenticated;
grant update (value, is_na, na_reason, client_captured_at, op_id) on public.wo_checklist_items to authenticated;
grant insert (wo_id, diagnosis, action_taken, recommendation, internal_note),
      update (diagnosis, action_taken, recommendation, internal_note) on public.wo_findings to authenticated;
grant insert (id, wo_id, kind, storage_path, mime, bytes, checksum, taken_at, op_id, extra_approval_id),
      update (deleted_at) on public.wo_attachments to authenticated;
grant insert (id, wo_id, signer_type, signer_name, storage_path, signed_via, device_meta, op_id) on public.wo_signatures to authenticated;
grant insert (id, wo_id, service_item_id, description, qty, is_extra, extra_approval_id, emergency, emergency_reason, op_id),
      update (deleted_at) on public.wo_labor_lines to authenticated;
grant insert (id, wo_id, item_id, qty, is_extra, extra_approval_id, emergency, emergency_reason, source_location_id, op_id),
      update (deleted_at) on public.wo_part_usages to authenticated;
grant insert (wo_id, score, comment) on public.ratings to authenticated;
grant insert (wo_id, description) on public.complaints to authenticated;
grant update (status, resolution_note, handled_by) on public.complaints to authenticated;
grant update (full_name, phone) on public.profiles to authenticated;
grant update (read_at, status) on public.notifications to authenticated;
grant insert, update, delete on public.notification_prefs to authenticated;
grant insert (op_id, device_id, user_id, wo_id, type, seq, schema_version, payload, client_captured_at) on public.sync_operations to authenticated;

grant execute on function
  public.wo_transition(uuid, text, int, uuid, text, text, jsonb), public.request_decide(uuid, text, text, uuid, numeric, text, int),
  public.extra_cost_request(uuid, text, jsonb, int, uuid), public.extra_cost_decide(uuid, text, text, boolean, public.decision_channel, text, uuid, jsonb),
  public.wo_customer_sign(uuid, text, text, int, uuid, jsonb), public.wo_request_help(uuid, text), public.wo_add_helper(uuid, uuid),
  public.wo_request_cancel(uuid, text), public.wo_change_priority(uuid, text, text, int),
  public.wo_override_billing(uuid, public.billing_type, text), public.wo_create_rework(uuid, text, text, uuid),
  public.wo_cost_summary(uuid), public.wo_set_estimate(uuid, numeric, int), public.pm_period_resolve(uuid, text, text),
  public.part_request_create(uuid, jsonb, text), public.part_request_decide(uuid, text, text), public.part_issue(uuid, numeric, uuid),
  public.part_return_create(uuid, jsonb, text), public.part_return_confirm(uuid, jsonb, uuid, boolean),
  public.stock_receive(uuid, uuid, numeric, text), public.stock_adjust(uuid, uuid, numeric, text),
  public.parts_variance_resolve(uuid, public.variance_status, text), public.log_data_access(uuid, text, text, text),
  public.register_individual_customer(text, text, text), public.accept_customer_invitation(text, text),
  public.admin_set_user_roles(uuid, public.app_role[]), public.admin_set_user_active(uuid, boolean)
to authenticated;

-- ---- POLICY: pembacaan khusus staf per peran (pola seragam) --------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('priorities',          '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE,TECHNICIAN}'),
    ('reason_codes',        '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE,TECHNICIAN}'),
    ('wo_transitions',      '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,TECHNICIAN}'),
    ('skills',              '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,TECHNICIAN}'),
    ('technicians',         '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('technician_skills',   '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('asset_categories',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,TECHNICIAN}'),
    ('checklist_templates', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,TECHNICIAN}'),
    ('checklist_template_items', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,TECHNICIAN}'),
    ('photo_requirements',  '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,TECHNICIAN}'),
    ('service_items',       '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('business_calendars',  '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('calendar_hours',      '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('calendar_holidays',   '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('sla_policy_sets',     '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('sla_policies',        '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('escalation_rules',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('app_settings',        '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE}'),
    ('pm_periods_staff',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('wo_status_history_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('wo_visits_staff',     '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_checklist_items_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_photo_requirements_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_findings_staff',   '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_attachments_staff','{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_signatures_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('wo_labor_lines_staff','{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('wo_part_usages_staff','{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE}'),
    ('extra_cost_approvals_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('extra_cost_approval_items_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('sla_events_staff',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('sla_pauses_staff',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('service_reports_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('items',               '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE}'),
    ('stock_locations_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE,FINANCE}'),
    ('stock_balances_staff', '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE,FINANCE}'),
    ('stock_movements_staff', '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE,FINANCE}'),
    ('part_requests_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE}'),
    ('part_request_lines_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE}'),
    ('part_returns_staff',  '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE}'),
    ('part_return_lines_staff', '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE}'),
    ('parts_variances_staff', '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE,FINANCE}'),
    ('complaints_staff',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('ratings_staff',       '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('invoices_staff',      '{ADMIN_CS,SUPERVISOR,OWNER,FINANCE}'),
    ('invoice_lines_staff', '{ADMIN_CS,SUPERVISOR,OWNER,FINANCE}'),
    ('payments_staff',      '{ADMIN_CS,SUPERVISOR,OWNER,FINANCE}'),
    ('customer_invitations_staff', '{ADMIN_CS,OWNER}'),
    ('import_jobs_staff',   '{ADMIN_CS,OWNER,WAREHOUSE}'),
    ('job_runs_staff',      '{ADMIN_CS,OWNER}'),
    ('sync_operations_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('access_logs_staff',   '{OWNER}')
  ) v(pol, roles) loop
    -- nama tabel = pol tanpa akhiran _staff
    execute format('create policy %I on public.%I for select to authenticated using ((select app.has_any_role(%L::public.app_role[])))',
                   r.pol || case when r.pol like '%\_staff' then '' else '_select_staff' end,
                   regexp_replace(r.pol, '_staff$', ''), r.roles);
  end loop;
end $$;

-- ---- POLICY: tulis konfigurasi/master (staf) ------------------------------------------------------------------------------
do $$
declare r record; t text;
begin
  -- ADMIN_CS menulis master data
  foreach t in array array['customers','customer_sites','assets','asset_categories','service_types','problem_types','service_items',
      'checklist_templates','checklist_template_items','photo_requirements','skills','technicians','technician_skills','contracts',
      'contract_assets','customer_invitations','import_jobs'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app.has_any_role(%L::public.app_role[])))', t || '_insert_admin', t, '{ADMIN_CS}');
    execute format('create policy %I on public.%I for update to authenticated using ((select app.has_any_role(%L::public.app_role[]))) with check ((select app.has_any_role(%L::public.app_role[])))', t || '_update_admin', t, '{ADMIN_CS}', '{ADMIN_CS}');
  end loop;
  foreach t in array array['technician_skills','photo_requirements','checklist_template_items'] loop
    execute format('create policy %I on public.%I for delete to authenticated using ((select app.has_any_role(%L::public.app_role[])))', t || '_delete_admin', t, '{ADMIN_CS}');
  end loop;
  -- OWNER menulis konfigurasi SLA/kalender/setting (OQ-12: ubah ke {ADMIN_CS,OWNER} bila bisnis memutuskan)
  foreach t in array array['business_calendars','calendar_hours','calendar_holidays','sla_policy_sets','sla_policies','escalation_rules',
      'app_settings','priorities','reason_codes'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app.has_any_role(%L::public.app_role[])))', t || '_insert_owner', t, '{OWNER}');
    execute format('create policy %I on public.%I for update to authenticated using ((select app.has_any_role(%L::public.app_role[]))) with check ((select app.has_any_role(%L::public.app_role[])))', t || '_update_owner', t, '{OWNER}', '{OWNER}');
  end loop;
  foreach t in array array['calendar_hours','calendar_holidays','escalation_rules'] loop
    execute format('create policy %I on public.%I for delete to authenticated using ((select app.has_any_role(%L::public.app_role[])))', t || '_delete_owner', t, '{OWNER}');
  end loop;
  -- WAREHOUSE menulis master barang & lokasi stok
  foreach t in array array['items','stock_locations'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app.has_any_role(%L::public.app_role[])))', t || '_insert_wh', t, '{WAREHOUSE}');
    execute format('create policy %I on public.%I for update to authenticated using ((select app.has_any_role(%L::public.app_role[]))) with check ((select app.has_any_role(%L::public.app_role[])))', t || '_update_wh', t, '{WAREHOUSE}', '{WAREHOUSE}');
  end loop;
  -- FINANCE menulis invoice (Lapis 3, TODO: pindahkan ke RPC penerbitan)
  foreach t in array array['invoices','invoice_lines','payments'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app.has_any_role(%L::public.app_role[])))', t || '_insert_fin', t, '{FINANCE}');
  end loop;
  foreach t in array array['invoices','invoice_lines'] loop
    execute format('create policy %I on public.%I for update to authenticated using ((select app.has_any_role(%L::public.app_role[]))) with check ((select app.has_any_role(%L::public.app_role[])))', t || '_update_fin', t, '{FINANCE}', '{FINANCE}');
  end loop;
  create policy invoice_lines_delete_fin on public.invoice_lines for delete to authenticated using ((select app.has_any_role('{FINANCE}')));
end $$;

-- ---- POLICY: identitas ---------------------------------------------------------------------------------------------------
create policy profiles_select on public.profiles for select to authenticated
  using (user_id = (select auth.uid()) or (select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}')));
create policy profiles_update_self on public.profiles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy user_roles_select on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or (select app.has_any_role('{ADMIN_CS,OWNER}')));
create policy user_consents_select on public.user_consents for select to authenticated
  using (user_id = (select auth.uid()));

create policy technicians_select_self on public.technicians for select to authenticated using (user_id = (select auth.uid()));
create policy technician_skills_select_self on public.technician_skills for select to authenticated
  using (technician_id = (select app.my_technician_id()));

-- ---- POLICY: master data dibaca pelanggan / teknisi / staf ------------------------------------------------------------------
create policy customers_select on public.customers for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'))
         or id = any ((select app.my_customer_ids())::uuid[])
         or id in (select app.tech_customer_ids()));
create policy customer_users_select on public.customer_users for select to authenticated
  using (user_id = (select auth.uid()) or customer_id = any ((select app.my_customer_ids())::uuid[])
         or (select app.has_any_role('{ADMIN_CS,OWNER}')));
create policy customer_sites_select on public.customer_sites for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'))
         or customer_id = any ((select app.my_customer_ids())::uuid[])
         or id in (select app.tech_site_ids()));
create policy assets_select on public.assets for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'))
         or customer_id = any ((select app.my_customer_ids())::uuid[])
         or id in (select app.tech_asset_ids()));
create policy service_types_select on public.service_types for select to authenticated using (true);      -- katalog layanan (form pemesanan)
create policy problem_types_select on public.problem_types for select to authenticated using (true);
create policy contracts_select on public.contracts for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')) or customer_id = any ((select app.my_customer_ids())::uuid[]));
create policy contract_assets_select on public.contract_assets for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'))
         or contract_id in (select c.id from public.contracts c where c.customer_id = any ((select app.my_customer_ids())::uuid[])));
create policy pm_periods_customer on public.pm_periods for select to authenticated
  using (contract_asset_id in (select ca.id from public.contract_assets ca join public.contracts c on c.id = ca.contract_id
                                where c.customer_id = any ((select app.my_customer_ids())::uuid[])));

-- ---- POLICY: permintaan servis ----------------------------------------------------------------------------------------------
create policy service_requests_select on public.service_requests for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')) or customer_id = any ((select app.my_customer_ids())::uuid[]));
create policy service_requests_insert on public.service_requests for insert to authenticated
  with check ((customer_id = any ((select app.my_customer_ids())::uuid[]) and channel = 'PWA')
              or (select app.has_any_role('{ADMIN_CS}')));
create policy service_requests_update on public.service_requests for update to authenticated
  using ((customer_id = any ((select app.my_customer_ids())::uuid[]) and status in ('SUBMITTED','NEEDS_INFO'))
         or (select app.has_any_role('{ADMIN_CS}')))
  with check (customer_id = any ((select app.my_customer_ids())::uuid[]) or (select app.has_any_role('{ADMIN_CS}')));
create policy request_attachments_select on public.request_attachments for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'))
         or customer_id = any ((select app.my_customer_ids())::uuid[])
         or request_id in (select app.tech_request_ids()));
create policy request_attachments_insert on public.request_attachments for insert to authenticated
  with check ((customer_id = any ((select app.my_customer_ids())::uuid[]) or (select app.has_any_role('{ADMIN_CS}')))
              and storage_path like customer_id::text || '/req/' || request_id::text || '/%');

-- ---- POLICY: work order & anak (pelanggan TIDAK punya akses tabel mentah; lihat view customer_*) -----------------------------------
create policy work_orders_staff on public.work_orders for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')));
create policy work_orders_tech on public.work_orders for select to authenticated
  using (id in (select app.my_active_wo_ids()));
create policy wo_status_history_tech on public.wo_status_history for select to authenticated
  using (wo_id in (select app.my_active_wo_ids()));
create policy wo_assignments_select on public.wo_assignments for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}')) or wo_id in (select app.my_active_wo_ids()));
create policy wo_visits_tech on public.wo_visits for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_checklist_items_tech on public.wo_checklist_items for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_photo_requirements_tech on public.wo_photo_requirements for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_findings_tech on public.wo_findings for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_attachments_tech on public.wo_attachments for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_signatures_tech on public.wo_signatures for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy service_reports_tech on public.service_reports for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
-- (wo_labor_lines, wo_part_usages, extra_cost_*: teknisi membaca lewat view tech_* tanpa harga)

-- tulis lapangan oleh teknisi: hanya WO yang ia tangani & statusnya mengizinkan
create policy wo_checklist_items_update_tech on public.wo_checklist_items for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
create policy wo_findings_insert_tech on public.wo_findings for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)));
create policy wo_findings_update_tech on public.wo_findings for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
create policy wo_attachments_insert_tech on public.wo_attachments for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)) and storage_path like app.wo_storage_prefix(wo_id) || '%');
create policy wo_attachments_update_tech on public.wo_attachments for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
create policy wo_signatures_insert_tech on public.wo_signatures for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)) and signed_via = 'TECH_DEVICE' and signer_type = 'CUSTOMER'
              and storage_path like app.wo_storage_prefix(wo_id) || '%');
create policy wo_labor_lines_insert_tech on public.wo_labor_lines for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)));
create policy wo_labor_lines_update_tech on public.wo_labor_lines for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
create policy wo_part_usages_insert_tech on public.wo_part_usages for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)));
create policy wo_part_usages_update_tech on public.wo_part_usages for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
-- SPV: koreksi pemakaian dengan alasan (matriks) lewat tombstone
create policy wo_part_usages_update_spv on public.wo_part_usages for update to authenticated
  using ((select app.has_any_role('{SUPERVISOR}'))) with check ((select app.has_any_role('{SUPERVISOR}')));

-- ---- POLICY: stok teknisi, retur, selisih (sisi teknisi) -----------------------------------------------------------------------------
create policy stock_locations_tech on public.stock_locations for select to authenticated using (id in (select app.my_location_ids()));
create policy stock_balances_tech on public.stock_balances for select to authenticated using (location_id in (select app.my_location_ids()));
create policy stock_movements_tech on public.stock_movements for select to authenticated
  using (from_location_id in (select app.my_location_ids()) or to_location_id in (select app.my_location_ids()));
create policy part_requests_tech on public.part_requests for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy part_request_lines_tech on public.part_request_lines for select to authenticated
  using (request_id in (select pr.id from public.part_requests pr where pr.wo_id in (select app.my_active_wo_ids())));
create policy part_returns_tech on public.part_returns for select to authenticated using (technician_id = (select app.my_technician_id()));
create policy part_return_lines_tech on public.part_return_lines for select to authenticated
  using (return_id in (select r.id from public.part_returns r where r.technician_id = (select app.my_technician_id())));
create policy parts_variances_tech on public.parts_variances for select to authenticated using (technician_id = (select app.my_technician_id()));

-- ---- POLICY: umpan balik pelanggan, penagihan pelanggan ------------------------------------------------------------------------------
create policy ratings_customer on public.ratings for select to authenticated using (customer_id = any ((select app.my_customer_ids())::uuid[]));
create policy ratings_insert_customer on public.ratings for insert to authenticated
  with check (customer_id = any ((select app.my_customer_ids())::uuid[]));       -- customer_id diisi trigger dari WO (BEFORE INSERT), lalu dicek di sini
create policy complaints_customer on public.complaints for select to authenticated using (customer_id = any ((select app.my_customer_ids())::uuid[]));
create policy complaints_insert_customer on public.complaints for insert to authenticated
  with check (customer_id = any ((select app.my_customer_ids())::uuid[]));       -- customer_id diisi trigger tg_feedback_before_insert
create policy complaints_update_staff on public.complaints for update to authenticated
  using ((select app.has_any_role('{ADMIN_CS,SUPERVISOR}'))) with check ((select app.has_any_role('{ADMIN_CS,SUPERVISOR}')));
create policy invoices_customer on public.invoices for select to authenticated
  using (customer_id = any ((select app.my_customer_ids())::uuid[]) and status in ('ISSUED','PAID'));
create policy invoice_lines_customer on public.invoice_lines for select to authenticated
  using (invoice_id in (select i.id from public.invoices i where i.customer_id = any ((select app.my_customer_ids())::uuid[]) and i.status in ('ISSUED','PAID')));
create policy payments_customer on public.payments for select to authenticated
  using (invoice_id in (select i.id from public.invoices i where i.customer_id = any ((select app.my_customer_ids())::uuid[])));

-- ---- POLICY: lintas sektor ------------------------------------------------------------------------------------------------------------
create policy notifications_own on public.notifications for select to authenticated using (user_id = (select auth.uid()));
create policy notifications_update_own on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy notification_prefs_own on public.notification_prefs for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy sync_operations_own on public.sync_operations for select to authenticated using (user_id = (select auth.uid()));
create policy sync_operations_insert_own on public.sync_operations for insert to authenticated with check (user_id = (select auth.uid()));
create policy audit_logs_owner on public.audit_logs for select to authenticated using ((select app.has_any_role('{OWNER}')));
create policy audit_logs_supervisor on public.audit_logs for select to authenticated
  using ((select app.has_any_role('{SUPERVISOR}'))
         and entity_type in ('work_orders','wo_assignments','extra_cost_approvals','wo_signatures','service_requests','parts_variances'));

-- ---- Storage: bucket privat + policy baca; TIDAK ada policy tulis (unggah lewat signed upload URL dari server) ----------------------------
do $$
begin
  if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('wo-media', 'wo-media', false, null, array['image/jpeg','image/png','image/webp'])    -- file_size_limit: isi dari keputusan [P] (NFR-S7)
    on conflict (id) do update set public = false;
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('reports', 'reports', false, null, array['application/pdf'])
    on conflict (id) do update set public = false;
    execute $p$create policy vasta_media_read on storage.objects for select to authenticated
               using (bucket_id in ('wo-media','reports') and (select app.can_read_object(bucket_id, name)))$p$;
  else
    raise notice 'schema storage tidak ada: bucket & policy Storage dilewati (lingkungan non-Supabase).';
  end if;
end $$;

-- ===== MIGRATION 0014: pg_cron ===========================================================
-- Jadwal dalam UTC. Frekuensi/jam adalah parameter operasional [P]; ubah dengan cron.alter_job().
-- Setiap job idempoten (aman bila dijalankan ulang/ganda) dan menulis heartbeat ke job_runs.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('vasta_sla_check',               '* * * * *',  $j$select app.run_job('sla_check')$j$);
    perform cron.schedule('vasta_expire_customer_actions', '*/5 * * * *', $j$select app.run_job('expire_customer_actions')$j$);
    perform cron.schedule('vasta_pm_generate',             '0 17 * * *', $j$select app.run_job('pm_generate')$j$);            -- 00:00 WIB
    perform cron.schedule('vasta_pm_missed',               '30 17 * * *', $j$select app.run_job('pm_missed')$j$);
    perform cron.schedule('vasta_parts_variance_finalize', '15 * * * *', $j$select app.run_job('parts_variance_finalize')$j$);
    perform cron.schedule('vasta_retention_purge',         '0 19 * * *', $j$select app.run_job('retention_purge')$j$);
  else
    raise notice 'pg_cron tidak aktif: jadwalkan app.run_job(<nama>) lewat scheduler eksternal (Edge Function/cron Next.js).';
  end if;
end $$;


-- ===== MIGRATION 0015: seed struktural (TANPA angka bisnis) ============================
-- Hanya lookup & konfigurasi kerangka. Nilai [P] diisi bisnis (lihat app_settings, sla_policies, escalation_rules).
insert into public.priorities (code, name, sort_rank) values
  ('LOW', 'Rendah', 10), ('NORMAL', 'Normal', 20), ('HIGH', 'Tinggi', 30), ('CRITICAL', 'Kritis', 40)
on conflict (code) do nothing;    -- contoh awal; ganti/tambah sesuai hasil wawancara (OQ-06)

insert into public.reason_codes (category, code, label) values
  ('CLOSURE_EXCEPTION', 'CUSTOMER_ABSENT',  'Pelanggan tidak ada di lokasi'),
  ('CLOSURE_EXCEPTION', 'CUSTOMER_REFUSED', 'Pelanggan menolak menandatangani'),
  ('CLOSURE_EXCEPTION', 'NO_RESPONSE',      'Pelanggan tidak menjawab hingga batas waktu (sistem)'),
  ('CLOSURE_EXCEPTION', 'OTHER',            'Lainnya (catatan wajib)'),
  ('CANCEL', 'CUSTOMER_REQUEST', 'Permintaan pelanggan'),
  ('CANCEL', 'DUPLICATE',        'Pesanan ganda'),
  ('CANCEL', 'CONTRACT_CHANGED', 'Kontrak berubah (sistem)'),
  ('CANCEL', 'OTHER',            'Lainnya'),
  ('REJECT_ASSIGNMENT', 'UNAVAILABLE',    'Tidak tersedia'),
  ('REJECT_ASSIGNMENT', 'SKILL_MISMATCH', 'Keahlian tidak sesuai'),
  ('REJECT_ASSIGNMENT', 'OTHER',          'Lainnya'),
  ('FAILED_VISIT', 'CUSTOMER_ABSENT', 'Pelanggan tidak ada'),
  ('FAILED_VISIT', 'ACCESS_DENIED',   'Akses ke lokasi ditolak'),
  ('FAILED_VISIT', 'OTHER',           'Lainnya'),
  ('REQUEST_REJECT', 'INVALID_ASSET', 'Aset tidak valid'),
  ('REQUEST_REJECT', 'OUT_OF_SCOPE',  'Di luar cakupan layanan'),
  ('REQUEST_REJECT', 'DUPLICATE',     'Pesanan ganda'),
  ('REQUEST_REJECT', 'OTHER',         'Lainnya')
on conflict do nothing;

-- Kunci setting. value NULL = belum diputuskan/nonaktif. Hanya tiga yang berisi nilai struktural (bukan angka bisnis).
insert into public.app_settings (key, value, description) values
  ('default_timezone',                    '"Asia/Jakarta"'::jsonb, 'Zona waktu default (BR-011); kalender dapat menimpa'),
  ('sla.clock_starts_at',                 '"WO_CREATED"'::jsonb,   'WO_CREATED | REQUEST_RECEIVED (SP-01, OQ-11)'),
  ('notification.default_channels',       '["IN_APP","EMAIL"]'::jsonb, 'Kanal default (AS-10); WHATSAPP/PUSH setelah keputusan'),
  ('stock.allow_unsourced_usage',         'false'::jsonb,          'BR-035/OQ-17: izinkan pemakaian tanpa stok teknisi (UNSOURCED_USAGE)'),
  ('registration.mode',                   null, 'SELF | INVITE | BOTH (Q1/D1). NULL = registrasi mandiri mati'),
  ('rate_limit.service_request.max',      null, 'BR-072: maks permintaan per jendela per pelanggan'),
  ('rate_limit.service_request.window_seconds', null, 'BR-072: panjang jendela (detik)'),
  ('duplicate.window_minutes',            null, 'BR-071: jendela deteksi pesanan ganda'),
  ('approval.expiry_hours',               null, 'BR-055: kedaluwarsa persetujuan biaya tambahan'),
  ('signoff.expiry_hours',                null, 'T-17/T-18: kedaluwarsa tanda tangan via PWA'),
  ('extra_cost.tolerance_amount',         null, 'BR-050: toleransi nominal (NULL = 0)'),
  ('closure.min_note_length',             null, 'BR-040(7): panjang minimal temuan/tindakan (NULL = 1)'),
  ('en_route.tolerance_days',             null, 'T-07: toleransi hari jadwal (NULL = tidak diperiksa)'),
  ('pm.grace_days',                       null, 'BR-024: toleransi PM (NULL = 0)'),
  ('pm.default_priority_code',            null, 'Prioritas WO PM bila jenis layanan tak punya default'),
  ('rework.claim_window_days',            null, 'T-25: jendela klaim komplain/rework (NULL = tanpa batas)'),
  ('reject.escalation_threshold',         null, 'T-04: eskalasi setelah N penolakan'),
  ('return.escalation_threshold',         null, 'T-20: eskalasi setelah N pengembalian'),
  ('parts.return_deadline_hours',         null, 'BR-032: batas waktu retur sebelum selisih final (NULL = final saat WO selesai)'),
  ('stock.adjustment_supervisor_threshold', null, 'FR-127: ambang penyesuaian stok yang butuh Supervisor'),
  ('retention.notifications_days',        null, 'NFR-S6 (OQ-21)'),
  ('retention.sync_operations_days',      null, 'NFR-S6 (OQ-21)'),
  ('retention.job_runs_days',             null, 'NFR-S6'),
  ('retention.photos_days',               null, 'NFR-S6/NFR-D5: ditegakkan oleh worker Storage (TODO)'),
  ('retention.personal_data_days',        null, 'NFR-D5: anonimisasi (TODO)')
on conflict (key) do nothing;

insert into public.wo_transitions (code, action, from_status, to_status, allowed_roles, allow_system, requires_reason, description) values
  ('T-02',  'ASSIGN',  'NEW', 'ASSIGNED', '{DISPATCHER}', false, false, 'Dispatcher menugaskan teknisi + jadwal final'),
  ('T-03',  'ACCEPT',  'ASSIGNED', 'ACCEPTED', '{TECHNICIAN}', false, false, 'Teknisi menerima'),
  ('T-04',  'REJECT',  'ASSIGNED', 'NEW', '{TECHNICIAN}', false, true, 'Teknisi menolak (alasan wajib)'),
  ('T-05a', 'REASSIGN','ASSIGNED', 'ASSIGNED', '{DISPATCHER}', false, true, 'Tugas ulang'),
  ('T-05b', 'REASSIGN','ACCEPTED', 'ASSIGNED', '{DISPATCHER}', false, true, 'Tugas ulang'),
  ('T-06',  'RELEASE', 'ACCEPTED', 'NEW', '{TECHNICIAN,DISPATCHER}', false, true, 'Lepas tugas sebelum check-in'),
  ('T-07',  'DEPART',  'ACCEPTED', 'EN_ROUTE', '{TECHNICIAN}', false, false, 'Berangkat'),
  ('T-08a', 'CHECK_IN','ACCEPTED', 'IN_PROGRESS', '{TECHNICIAN}', false, false, 'Check-in tanpa berangkat'),
  ('T-08b', 'CHECK_IN','EN_ROUTE', 'IN_PROGRESS', '{TECHNICIAN}', false, false, 'Check-in'),
  ('T-09',  'HOLD_PARTS','IN_PROGRESS', 'ON_HOLD_PARTS', '{TECHNICIAN}', false, false, 'Menunggu suku cadang'),
  ('T-10',  'RESUME_PARTS','ON_HOLD_PARTS', 'IN_PROGRESS', '{TECHNICIAN,DISPATCHER}', false, false, 'Suku cadang tiba/dibatalkan'),
  ('T-11',  'REQUEST_EXTRA_COST','IN_PROGRESS', 'AWAITING_CUSTOMER_APPROVAL', '{TECHNICIAN}', false, false, 'Ajukan biaya tambahan'),
  ('T-12',  'APPROVE_EXTRA_COST','AWAITING_CUSTOMER_APPROVAL', 'IN_PROGRESS', '{CUSTOMER,ADMIN_CS}', false, false, 'Pelanggan menyetujui'),
  ('T-13',  'REJECT_EXTRA_COST','AWAITING_CUSTOMER_APPROVAL', 'IN_PROGRESS', '{CUSTOMER,ADMIN_CS}', false, false, 'Menolak, lanjut lingkup awal'),
  ('T-14',  'CLOSE_AFTER_REJECTION','AWAITING_CUSTOMER_APPROVAL', 'UNDER_REVIEW', '{TECHNICIAN}', false, true, 'Tutup tidak tuntas setelah penolakan'),
  ('T-15',  'EXPIRE_EXTRA_COST','AWAITING_CUSTOMER_APPROVAL', 'IN_PROGRESS', '{}', true, false, 'Kedaluwarsa (sistem)'),
  ('T-16',  'SUBMIT_REVIEW','IN_PROGRESS', 'UNDER_REVIEW', '{TECHNICIAN}', false, false, 'Teknisi menutup (BR-040)'),
  ('T-17',  'REQUEST_SIGNOFF','IN_PROGRESS', 'AWAITING_SIGNOFF', '{TECHNICIAN}', false, false, 'Minta tanda tangan lewat PWA'),
  ('T-18',  'SIGNOFF', 'AWAITING_SIGNOFF', 'UNDER_REVIEW', '{CUSTOMER}', false, false, 'Pelanggan menandatangani'),
  ('T-18s', 'EXPIRE_SIGNOFF','AWAITING_SIGNOFF', 'UNDER_REVIEW', '{}', true, false, 'Kedaluwarsa jadi pengecualian (sistem)'),
  ('T-19',  'APPROVE_CLOSE','UNDER_REVIEW', 'CLOSED', '{SUPERVISOR}', false, false, 'Supervisor menyetujui'),
  ('T-20',  'RETURN',  'UNDER_REVIEW', 'RETURNED', '{SUPERVISOR}', false, true, 'Supervisor mengembalikan'),
  ('T-21',  'RESUME_AFTER_RETURN','RETURNED', 'IN_PROGRESS', '{TECHNICIAN}', false, false, 'Teknisi mengerjakan catatan'),
  ('T-22a', 'CANCEL',  'NEW', 'CANCELLED', '{ADMIN_CS,DISPATCHER}', true, true, 'Batal'),
  ('T-22b', 'CANCEL',  'ASSIGNED', 'CANCELLED', '{ADMIN_CS,DISPATCHER}', true, true, 'Batal'),
  ('T-22c', 'CANCEL',  'ACCEPTED', 'CANCELLED', '{ADMIN_CS,DISPATCHER}', true, true, 'Batal'),
  ('T-22d', 'CANCEL',  'EN_ROUTE', 'CANCELLED', '{ADMIN_CS,DISPATCHER}', true, true, 'Batal'),
  ('T-22e', 'CANCEL_BY_CUSTOMER','NEW', 'CANCELLED', '{CUSTOMER}', false, true, 'Pelanggan batal sebelum penugasan'),
  ('T-23a', 'CANCEL_ACTIVE','IN_PROGRESS', 'CANCELLED', '{SUPERVISOR}', false, true, 'Batal saat berjalan'),
  ('T-23b', 'CANCEL_ACTIVE','ON_HOLD_PARTS', 'CANCELLED', '{SUPERVISOR}', false, true, 'Batal saat berjalan'),
  ('T-23c', 'CANCEL_ACTIVE','AWAITING_CUSTOMER_APPROVAL', 'CANCELLED', '{SUPERVISOR}', false, true, 'Batal saat berjalan'),
  ('T-23d', 'CANCEL_ACTIVE','AWAITING_SIGNOFF', 'CANCELLED', '{SUPERVISOR}', false, true, 'Batal saat berjalan'),
  ('T-27a', 'VISIT_FAILED','EN_ROUTE', 'NEW', '{TECHNICIAN}', false, true, 'Kunjungan gagal'),
  ('T-27b', 'VISIT_FAILED','IN_PROGRESS', 'NEW', '{TECHNICIAN}', false, true, 'Kunjungan gagal')
on conflict (code) do nothing;

-- ===== MIGRATION 0016: celah API-DB dan perbaikan keamanan ===========================
-- Idempoten (create or replace / if not exists / drop ... if exists) dan tanpa menghapus data, TETAPI BUKAN sekadar
-- aditif: (a) drop policy work_orders_tech (teknisi tidak lagi SELECT work_orders), (b) policy diganti (customer_users_select,
-- payments_customer, wo_signatures_insert_tech, sync_operations_insert_own), (c) perilaku fungsi berubah (wo_customer_sign,
-- wo_cost_summary, extra_cost_request tanpa 'total', app.wo_submit_deficiencies, app.can_read_object).
-- Sumber: docs/orchestration/gaps_for_decision.md (G-04, G-05, G-06, G-08, G-12, G-13), temuan review WP-007 (S1, S2, S4, N1, N2)
-- dan review independen WP-002b_0016_review.md. Ditunda: G-02/G-03/G-07/G-09/G-10/G-11, S3/S5/S6/S7/S8/S9, sla_acknowledge,
-- wo_reschedule.
-- Tidak boleh berisi perintah transaksi (begin/commit): dijalankan di dalam satu transaksi oleh tools/apply-migrations.mjs.
-- DDL memegang kunci sampai commit: lock_timeout 5 detik agar gagal cepat bila ada transaksi panjang; terapkan di jam sepi.
set local lock_timeout = '5s';

-- ---- G-04: wo_signatures.upload_status --------------------------------------------------------------------
-- Baris lama dianggap UPLOADED (sudah terdaftar sebelum kolom ada). Baris baru default PENDING.
-- Hak INSERT kolom authenticated (0013) tidak mencakup kolom ini, jadi klien tidak dapat menandai UPLOADED.
-- Penanda UPLOADED hanya oleh: (a) service_role setelah server memverifikasi objek (05 bagian 6.3a), pola sama dengan foto;
-- (b) wo_customer_sign di bawah (fungsi definer yang memeriksa keberadaan objek di storage.objects).
alter table public.wo_signatures add column if not exists upload_status public.upload_status not null default 'UPLOADED';
alter table public.wo_signatures alter column upload_status set default 'PENDING';

-- G-04: guard penutupan hanya menghitung tanda tangan VALID yang gambarnya sudah UPLOADED (butir SIGNATURE_MISSING).
create or replace function app.wo_submit_deficiencies(p_wo_id uuid, p_mode text default 'SUBMIT',
                                                      p_client_pending_ops int default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  w public.work_orders; d jsonb := '[]'::jsonb; v_cnt int; v_hash text; v_min int; r record; v_ok boolean;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if not found then
    return jsonb_build_array(jsonb_build_object('code', 'WO_NOT_FOUND'));
  end if;

  -- 1. checklist wajib
  select count(*) into v_cnt from public.wo_checklist_items
   where wo_id = p_wo_id and required and not is_na and value is null;
  if v_cnt > 0 then
    d := d || jsonb_build_array(jsonb_build_object('code', 'CHECKLIST_INCOMPLETE', 'missing', v_cnt,
          'items', (select jsonb_agg(label_snapshot order by seq) from public.wo_checklist_items
                     where wo_id = p_wo_id and required and not is_na and value is null)));
  end if;

  -- 2. foto wajib (hanya yang sudah UPLOADED)
  for r in select pr.kind, pr.min_count,
                  (select count(*) from public.wo_attachments a
                    where a.wo_id = p_wo_id and a.kind = pr.kind and a.upload_status = 'UPLOADED' and a.deleted_at is null) as have
             from public.wo_photo_requirements pr where pr.wo_id = p_wo_id loop
    if r.have < r.min_count then
      d := d || jsonb_build_array(jsonb_build_object('code', 'PHOTO_MISSING', 'kind', r.kind,
            'required', r.min_count, 'uploaded', r.have));
    end if;
  end loop;

  -- 3. check-in
  if not exists (select 1 from public.wo_visits where wo_id = p_wo_id and check_in_at is not null) then
    d := d || jsonb_build_array(jsonb_build_object('code', 'CHECK_IN_MISSING'));
  end if;

  -- 4. tanda tangan / persetujuan / pengecualian (G-04: gambar tanda tangan harus UPLOADED)
  if p_mode in ('SUBMIT', 'CLOSE') then
    v_hash := app.wo_content_hash(p_wo_id);
    v_ok := exists (select 1 from public.wo_signatures s
                     where s.wo_id = p_wo_id and s.signer_type = 'CUSTOMER' and s.status = 'VALID' and s.content_hash = v_hash
                       and s.upload_status = 'UPLOADED');
    if not v_ok then
      v_ok := w.closure_exception and coalesce(btrim(w.closure_exception_code), '') <> '';
      if v_ok and p_mode = 'CLOSE' and w.closure_exception_approved_by is null then
        d := d || jsonb_build_array(jsonb_build_object('code', 'CLOSURE_EXCEPTION_NOT_APPROVED'));
      end if;
    end if;
    if not v_ok then
      d := d || jsonb_build_array(jsonb_build_object('code', 'SIGNATURE_MISSING'));
    end if;
  end if;

  -- 5. tidak ada persetujuan biaya PENDING
  if exists (select 1 from public.extra_cost_approvals where wo_id = p_wo_id and status = 'PENDING') then
    d := d || jsonb_build_array(jsonb_build_object('code', 'EXTRA_COST_PENDING'));
  end if;

  -- 6. pemakaian suku cadang tercatat atau pernyataan "tidak ada"
  if not w.no_parts_used
     and not exists (select 1 from public.wo_part_usages where wo_id = p_wo_id and deleted_at is null) then
    d := d || jsonb_build_array(jsonb_build_object('code', 'PARTS_NOT_DECLARED'));
  end if;

  -- 7. temuan + tindakan
  v_min := coalesce(app.setting_int('closure.min_note_length'), 1);
  if not exists (select 1 from public.wo_findings f
                  where f.wo_id = p_wo_id
                    and char_length(btrim(coalesce(f.diagnosis, ''))) >= v_min
                    and char_length(btrim(coalesce(f.action_taken, ''))) >= v_min) then
    d := d || jsonb_build_array(jsonb_build_object('code', 'FINDINGS_INCOMPLETE', 'min_length', v_min));
  end if;

  -- 8. antrean sinkron
  if p_mode in ('SUBMIT', 'SIGNOFF_REQUEST') then
    if p_client_pending_ops is null then
      d := d || jsonb_build_array(jsonb_build_object('code', 'SYNC_STATE_UNKNOWN'));
    elsif p_client_pending_ops > 0 then
      d := d || jsonb_build_array(jsonb_build_object('code', 'SYNC_PENDING', 'client_pending_ops', p_client_pending_ops));
    end if;
  end if;
  if exists (select 1 from public.sync_operations where wo_id = p_wo_id and status = 'RECEIVED') then
    d := d || jsonb_build_array(jsonb_build_object('code', 'SYNC_UNAPPLIED'));
  end if;

  return d;
end $$;

-- G-04: wo_customer_sign menyisipkan tanda tangan dan memanggil SIGNOFF dalam satu transaksi, sehingga server tidak sempat
-- menandai UPLOADED di antaranya. Karena itu fungsi definer ini sendiri memverifikasi objek di storage.objects. Syarat path
-- (review 0016 no. 1): berawalan {customer}/wo/{wo}/sig/ dengan nama file tidak kosong, tanpa segmen '..', belum terdaftar di
-- wo_attachments (foto OTHER/FAILED_VISIT tidak bisa dipakai sebagai "tanda tangan"). Syarat objek: bucket wo-media, path persis,
-- ukuran > 0 dan mimetype gambar (metadata storage). Gagal path = WO006; objek belum/tidak sah = baris PENDING sehingga guard
-- menolak (WO003 SIGNATURE_MISSING) dan seluruh transaksi dibatalkan.
create or replace function public.wo_customer_sign(
  p_wo_id uuid, p_signer_name text, p_storage_path text, p_expected_version int,
  p_op_id uuid default null, p_device_meta jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_up boolean := false; v_pfx text;
begin
  if not app.customer_owns_wo(p_wo_id) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  if (select status from public.work_orders where id = p_wo_id) <> 'AWAITING_SIGNOFF' then
    raise exception 'WO001: WO tidak sedang menunggu tanda tangan' using errcode = 'WO001';
  end if;
  v_pfx := app.wo_storage_prefix(p_wo_id) || 'sig/';
  if coalesce(btrim(p_storage_path), '') = ''
     or char_length(p_storage_path) <= char_length(v_pfx)
     or left(p_storage_path, char_length(v_pfx)) <> v_pfx
     or p_storage_path ~ '(^|/)\.\.(/|$)'
     or exists (select 1 from public.wo_attachments x where x.storage_path = p_storage_path) then
    raise exception 'WO006: path tanda tangan tidak sesuai konvensi' using errcode = 'WO006';
  end if;
  if to_regclass('storage.objects') is not null then
    execute 'select exists (select 1 from storage.objects where bucket_id = ''wo-media'' and name = $1
                              and coalesce(nullif(metadata ->> ''size'', ''''), ''0'')::numeric > 0
                              and metadata ->> ''mimetype'' in (''image/png'', ''image/jpeg'', ''image/webp''))'
      into v_up using p_storage_path;
  end if;
  insert into public.wo_signatures (wo_id, signer_type, signer_name, signer_user_id, storage_path, content_hash, signed_via,
                                    device_meta, op_id, upload_status)
  values (p_wo_id, 'CUSTOMER', p_signer_name, auth.uid(), p_storage_path, '', 'CUSTOMER_PWA', p_device_meta, p_op_id,
          case when v_up then 'UPLOADED'::public.upload_status else 'PENDING'::public.upload_status end);
  return app.apply_wo_transition(p_wo_id, 'SIGNOFF', auth.uid(), app.resolve_actor_roles(p_wo_id), false,
                                 p_expected_version, p_op_id, null, null, '{}'::jsonb);
end $$;

-- Sub-prefix yang sama untuk tanda tangan teknisi (menggantikan wo_signatures_insert_tech 0013): .../sig/{nama file}.
drop policy if exists wo_signatures_insert_tech on public.wo_signatures;
create policy wo_signatures_insert_tech on public.wo_signatures for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)) and signed_via = 'TECH_DEVICE' and signer_type = 'CUSTOMER'
              and storage_path like app.wo_storage_prefix(wo_id) || 'sig/_%'
              and storage_path !~ '(^|/)\.\.(/|$)'
              and not exists (select 1 from public.wo_attachments x where x.storage_path = wo_signatures.storage_path));

-- ---- G-13: jalur tulis work_orders.no_parts_used untuk teknisi -----------------------------------------------
-- Tidak membuka UPDATE tabel. Hanya teknisi LEAD yang memegang WO (pernyataan tingkat-WO yang menentukan penutupan, sama
-- dengan wo_transition/extra_cost_request; helper boleh mengisi data lapangan tetapi tidak menyatakan ini: WO002) dan WO sedang
-- dapat diisi (can_edit_wo). p_op_id: bila op itu sudah tercatat APPLIED milik pemanggil di sync_operations, panggilan dianggap
-- replay dan tidak mengubah apa pun (mencegah op lama membalik nilai yang kemudian diubah); selain itu pengaman replay adalah
-- kesamaan nilai + expected_version.
-- Audit: trigger trg_audit pada work_orders mencatat perubahan kolom (aktor = auth.uid()).
-- Mengubah nilai menaikkan work_orders.version (trigger tg_touch); klien memakai version dari hasil.
create or replace function public.wo_declare_no_parts(p_wo_id uuid, p_value boolean, p_expected_version int,
                                                      p_op_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if auth.uid() is null or p_wo_id is null or p_wo_id not in (select app.my_active_wo_ids()) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';          -- 404 seragam
  end if;
  select * into w from public.work_orders where id = p_wo_id for update;
  if not found then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  if not exists (select 1 from public.wo_assignments a
                  where a.wo_id = p_wo_id and a.technician_id = app.my_technician_id() and a.role = 'LEAD'
                    and a.status in ('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED')) then
    raise exception 'WO002: hanya teknisi LEAD yang dapat menyatakan' using errcode = 'WO002';
  end if;
  if p_op_id is not null and exists (select 1 from public.sync_operations s
                                      where s.op_id = p_op_id and s.user_id = auth.uid() and s.status = 'APPLIED') then
    return jsonb_build_object('status', w.status, 'version', w.version, 'no_parts_used', w.no_parts_used, 'replayed', true);
  end if;
  if p_value is null then
    raise exception 'WO006: p_value wajib' using errcode = 'WO006';
  end if;
  if not app.can_edit_wo(p_wo_id) then
    raise exception 'WO001: WO tidak dapat diisi pada status ini' using errcode = 'WO001',
      detail = jsonb_build_object('current_status', w.status)::text;
  end if;
  if w.no_parts_used = p_value then                                              -- replay / tanpa perubahan: tidak menaikkan version
    return jsonb_build_object('status', w.status, 'version', w.version, 'no_parts_used', w.no_parts_used, 'replayed', true);
  end if;
  if p_expected_version is distinct from w.version then
    raise exception 'WO004: konflik versi' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;
  if p_value and exists (select 1 from public.wo_part_usages where wo_id = p_wo_id and deleted_at is null) then
    raise exception 'WO003: sudah ada pemakaian suku cadang tercatat' using errcode = 'WO003',
      detail = '{"code":"PARTS_ALREADY_RECORDED"}';
  end if;
  update public.work_orders set no_parts_used = p_value where id = p_wo_id returning * into w;
  return jsonb_build_object('status', w.status, 'version', w.version, 'no_parts_used', w.no_parts_used, 'replayed', false);
end $$;

-- ---- G-12: pratinjau kekurangan penutupan (pembungkus app.wo_submit_deficiencies) ---------------------------------
-- Pemanggil: teknisi pemegang WO dan staf operasional (ADM, DSP, SPV, OWN). Lainnya: WO005 (404 seragam).
-- Mode: WO berstatus UNDER_REVIEW memakai 'CLOSE' (validasi ulang T-19, BR-042); selain itu 'SUBMIT' dengan antrean klien = 0
-- (server tidak tahu antrean klien; klien menggabungkan SYNC_PENDING sendiri). Mengembalikan array jsonb [{code,...}].
create or replace function public.wo_closure_check(p_wo_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_status public.wo_status;
begin
  if auth.uid() is null or p_wo_id is null
     or not (app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}') or p_wo_id in (select app.my_active_wo_ids())) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  select status into v_status from public.work_orders where id = p_wo_id;
  if not found then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  return app.wo_submit_deficiencies(p_wo_id, case when v_status = 'UNDER_REVIEW' then 'CLOSE' else 'SUBMIT' end, 0);
end $$;

-- ---- S1: wo_cost_summary tidak membocorkan angka ke teknisi ---------------------------------------------------------
-- Staf (ADM, DSP, SPV, FIN, OWN) tetap menerima hasil penuh; pemanggil yang hanya teknisi menerima {needs_approval} saja.
create or replace function public.wo_cost_summary(p_wo_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  w public.work_orders; v_proj numeric; v_tol numeric := coalesce(app.setting_int('extra_cost.tolerance_amount'), 0);
  v_staff boolean := app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'); v_needs boolean;
begin
  if auth.uid() is null or p_wo_id is null or not (v_staff or p_wo_id in (select app.my_active_wo_ids())) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  select * into w from public.work_orders where id = p_wo_id;
  if not found then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  select coalesce(sum(qty * coalesce(unit_price_snapshot, 0)), 0) into v_proj from (
    select qty, unit_price_snapshot from public.wo_labor_lines where wo_id = p_wo_id and deleted_at is null and billable
    union all
    select qty, unit_price_snapshot from public.wo_part_usages where wo_id = p_wo_id and deleted_at is null and billable) x;
  v_needs := w.estimate_total is not null and v_proj > w.estimate_total + v_tol;                -- BR-050
  if not v_staff then
    return jsonb_build_object('needs_approval', v_needs);                                      -- S1: tanpa angka rupiah
  end if;
  return jsonb_build_object('estimate_total', w.estimate_total, 'projected_total', v_proj, 'tolerance', v_tol,
           'needs_approval', v_needs);
end $$;

-- ---- G-08 (sisa): extra_cost_request tidak lagi mengembalikan 'total' (qty x harga master) kepada teknisi ---------------------
-- Satu-satunya perubahan terhadap 0010: kunci 'total' dihapus dari nilai kembalian. Total tetap tersimpan di
-- extra_cost_approvals dan dikirim ke pelanggan lewat notifikasi/customer_extra_cost_approvals.
create or replace function public.extra_cost_request(
  p_wo_id uuid, p_reason text, p_items jsonb, p_expected_version int, p_op_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  w public.work_orders; v_ver int; v_total numeric; v_hash text; v_id uuid; v_exp timestamptz; v_hours int; v_res jsonb;
begin
  select * into w from public.work_orders where id = p_wo_id for update;
  if not found or not exists (select 1 from public.wo_assignments a
        where a.wo_id = p_wo_id and a.technician_id = app.my_technician_id() and a.role = 'LEAD' and a.status = 'ACCEPTED') then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  if w.status not in ('IN_PROGRESS','AWAITING_CUSTOMER_APPROVAL') then
    raise exception 'WO001: biaya tambahan hanya dari IN_PROGRESS' using errcode = 'WO001';
  end if;
  if p_expected_version is distinct from w.version then
    raise exception 'WO004: konflik versi' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;
  if coalesce(btrim(p_reason), '') = '' or p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'WO006: alasan dan minimal satu item wajib' using errcode = 'WO006';
  end if;

  -- Harga diambil dari master bila ada ref_id (teknisi tidak perlu/tidak boleh melihat harga, AP-2); item bebas (OTHER) memakai unit_price input.
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'ref_id', x.ref_id, 'description', x.description, 'qty', x.qty,
           'unit_price', case when x.kind = 'LABOR' and x.ref_id is not null then (select si.unit_price from public.service_items si where si.id = x.ref_id)
                              when x.kind = 'PART' and x.ref_id is not null then (select it.unit_price from public.items it where it.id = x.ref_id)
                              else x.unit_price end)), '[]'::jsonb)
    into p_items
    from jsonb_to_recordset(p_items) as x(kind text, ref_id uuid, description text, qty numeric, unit_price numeric);
  if exists (select 1 from jsonb_to_recordset(p_items) as x(kind text, qty numeric, unit_price numeric)
              where x.unit_price is null or x.qty is null or x.qty <= 0 or x.kind not in ('LABOR','PART','OTHER')) then
    raise exception 'WO006: item tidak valid atau harga master belum diisi' using errcode = 'WO006';
  end if;
  select coalesce(sum(round(x.qty * x.unit_price, 2)), 0) into v_total
    from jsonb_to_recordset(p_items) as x(kind text, ref_id uuid, description text, qty numeric, unit_price numeric);

  update public.extra_cost_approvals set status = 'SUPERSEDED' where wo_id = p_wo_id and status = 'PENDING';   -- versi baru (BR-051)
  select coalesce(max(version_no), 0) + 1 into v_ver from public.extra_cost_approvals where wo_id = p_wo_id;
  select encode(sha256(convert_to(jsonb_build_object('wo', p_wo_id, 'v', v_ver, 'reason', p_reason, 'total', v_total,
           'items', (select coalesce(jsonb_agg(jsonb_build_array(x.kind, x.description, x.qty, x.unit_price)
                                      order by x.kind, x.description, x.qty, x.unit_price), '[]'::jsonb)
                       from jsonb_to_recordset(p_items) as x(kind text, ref_id uuid, description text, qty numeric, unit_price numeric)))::text,
           'UTF8')), 'hex') into v_hash;
  v_hours := app.setting_int('approval.expiry_hours');
  v_exp := case when v_hours is null then null else now() + make_interval(hours => v_hours) end;

  insert into public.extra_cost_approvals (wo_id, version_no, status, total, reason, requested_by, expires_at, content_hash)
  values (p_wo_id, v_ver, 'PENDING', v_total, p_reason, auth.uid(), v_exp, v_hash) returning id into v_id;
  insert into public.extra_cost_approval_items (approval_id, kind, ref_id, description, qty, unit_price)
  select v_id, x.kind::public.extra_item_kind, x.ref_id, x.description, x.qty, x.unit_price
    from jsonb_to_recordset(p_items) as x(kind text, ref_id uuid, description text, qty numeric, unit_price numeric);

  if w.status = 'IN_PROGRESS' then
    v_res := app.apply_wo_transition(p_wo_id, 'REQUEST_EXTRA_COST', auth.uid(), app.resolve_actor_roles(p_wo_id), false,
                                     w.version, p_op_id, null, null, '{}'::jsonb);
  else
    perform app.notify_customer(w.customer_id, 'wo.approval_needed', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'approval_id', v_id, 'total', v_total), 'approval:' || v_id::text);
    v_res := jsonb_build_object('status', w.status, 'version', w.version);
  end if;
  return v_res || jsonb_build_object('approval_id', v_id, 'approval_version', v_ver, 'content_hash', v_hash);
end $$;

-- ---- G-06: pencatatan status operasi sinkron tanpa memperluas service_role ------------------------------------------
-- Penyimpanan draf RESCUED = baris sync_operations berstatus RESCUED (tidak ada tabel terpisah; tidak dibuat tabel baru).
alter table public.sync_operations
  add column if not exists resolved_at timestamptz,
  add column if not exists resolved_by uuid,
  add column if not exists resolved_note text;

-- KEMAMPUAN BARU: sebelum 0016 klien tidak dapat mengubah status/hasil sama sekali (hanya INSERT). Kini pemilik baris dapat
-- menandai operasinya sendiri APPLIED/REJECTED/RESCUED (kepercayaan pada klien; efek samping: baris RECEIVED milik sendiri yang
-- ditandai APPLIED melepas guard SYNC_UNAPPLIED untuk WO-nya). result dibatasi 64 KB.
-- Hanya baris milik auth.uid(). Transisi valid: RECEIVED -> APPLIED | REJECTED | RESCUED; REJECTED -> RESCUED.
-- Status sama dipanggil ulang = tanpa perubahan (replay). APPLIED dan RESCUED final. Baris orang lain/tak ada: WO005.
create or replace function public.sync_op_record(p_op_id uuid, p_status text, p_result jsonb default null,
                                                 p_clock_skew boolean default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare o public.sync_operations; v_new public.sync_op_status;
begin
  if auth.uid() is null or not exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.is_active) then
    raise exception 'WO005: operasi tidak ditemukan' using errcode = 'WO005';
  end if;
  select * into o from public.sync_operations where op_id = p_op_id and user_id = auth.uid() for update;
  if not found then
    raise exception 'WO005: operasi tidak ditemukan' using errcode = 'WO005';
  end if;
  if p_status is null or p_status not in ('APPLIED', 'REJECTED', 'RESCUED') then
    raise exception 'WO006: status harus APPLIED|REJECTED|RESCUED' using errcode = 'WO006';
  end if;
  if p_result is not null and pg_column_size(p_result) > 65536 then
    raise exception 'WO006: result terlalu besar (maks 64 KB)' using errcode = 'WO006';
  end if;
  v_new := p_status::public.sync_op_status;
  if o.status = v_new then
    return jsonb_build_object('op_id', o.op_id, 'status', o.status, 'replayed', true);
  end if;
  if not (o.status = 'RECEIVED' or (o.status = 'REJECTED' and v_new = 'RESCUED')) then
    raise exception 'WO001: transisi status operasi % -> % tidak diizinkan', o.status, v_new using errcode = 'WO001',
      detail = jsonb_build_object('current_status', o.status)::text;
  end if;
  update public.sync_operations
     set status = v_new,
         result = coalesce(p_result, result),
         applied_at = case when v_new = 'APPLIED' then now() else applied_at end,
         clock_skew = coalesce(p_clock_skew, clock_skew)
   where op_id = p_op_id;
  return jsonb_build_object('op_id', p_op_id, 'status', v_new, 'replayed', false);
end $$;

-- Penyelesaian draf RESCUED (dismiss/tautkan) oleh staf yang boleh membacanya (sync_operations_staff): ADM, DSP, SPV, OWN.
create or replace function public.sync_rescued_resolve(p_op_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare o public.sync_operations;
begin
  if not app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}') then
    raise exception 'WO002: tidak berhak' using errcode = 'WO002';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'WO006: catatan penyelesaian wajib' using errcode = 'WO006';
  end if;
  select * into o from public.sync_operations where op_id = p_op_id for update;
  if not found then
    raise exception 'WO005: operasi tidak ditemukan' using errcode = 'WO005';
  end if;
  if o.status <> 'RESCUED' then
    raise exception 'WO001: hanya draf RESCUED yang dapat diselesaikan' using errcode = 'WO001',
      detail = jsonb_build_object('current_status', o.status)::text;
  end if;
  if o.resolved_at is not null then
    return jsonb_build_object('op_id', o.op_id, 'resolved_at', o.resolved_at, 'replayed', true);
  end if;
  update public.sync_operations set resolved_at = now(), resolved_by = auth.uid(), resolved_note = btrim(p_note)
   where op_id = p_op_id returning * into o;
  return jsonb_build_object('op_id', o.op_id, 'resolved_at', o.resolved_at, 'replayed', false);
end $$;

-- ---- G-05: sinyal perubahan anak WO untuk /sync/pull TANPA menaikkan work_orders.version ----------------------------
-- Kolom di work_orders ditolak karena (1) tg_touch menaikkan version/updated_at pada SETIAP update baris (WO004 palsu),
-- (2) trg_audit mencatat tiap perubahan, (3) tg_wo_before_update menolak (IMM01) update kolom itu pada WO final.
-- Tabel pendamping satu baris per WO tidak punya kolom version/updated_at dan tidak diaudit. changed_at memakai
-- clock_timestamp() (waktu penulisan). Pull: baca wo_child_changes dengan changed_at > kursor (RLS: teknisi hanya WO aktifnya),
-- atau kolom children_changed_at pada view tech_work_orders.
create table if not exists public.wo_child_changes (
  wo_id      uuid primary key,                          -- tanpa FK sengaja: tidak menambah kunci pada work_orders
  changed_at timestamptz not null default clock_timestamp()
);
create index if not exists ix_wo_child_changes_at on public.wo_child_changes (changed_at, wo_id);
alter table public.wo_child_changes enable row level security;
revoke all on public.wo_child_changes from anon, authenticated;
grant select on public.wo_child_changes to authenticated;
drop policy if exists wo_child_changes_staff on public.wo_child_changes;
create policy wo_child_changes_staff on public.wo_child_changes for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')));
drop policy if exists wo_child_changes_tech on public.wo_child_changes;
create policy wo_child_changes_tech on public.wo_child_changes for select to authenticated
  using (wo_id in (select app.my_active_wo_ids()));

-- Constraint trigger DEFERRABLE INITIALLY DEFERRED: upsert dijalankan saat COMMIT, jadi kunci baris wo_child_changes hanya
-- dipegang sangat singkat (bukan sepanjang transaksi) dan tidak membentuk urutan kunci dengan fungsi yang mengunci work_orders
-- lebih dulu. Dedupe per transaksi lewat GUC lokal agar satu WO hanya di-upsert sekali per transaksi.
create or replace function app.tg_wo_child_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_key text := 'app.wcc_' || replace(new.wo_id::text, '-', '_');
begin
  if coalesce(current_setting(v_key, true), '') = '1' then return null; end if;
  perform set_config(v_key, '1', true);
  insert into public.wo_child_changes as c (wo_id, changed_at) values (new.wo_id, clock_timestamp())
  on conflict (wo_id) do update set changed_at = excluded.changed_at;
  return null;
end $$;
revoke execute on function app.tg_wo_child_changed() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['wo_checklist_items','wo_findings','wo_attachments','wo_signatures','wo_labor_lines','wo_part_usages',
                           'wo_assignments','wo_visits','extra_cost_approvals','part_requests','service_reports'] loop
    execute format('drop trigger if exists trg_wo_child_changed on public.%I', t);
    execute format('create constraint trigger trg_wo_child_changed after insert or update on public.%I
                    deferrable initially deferred for each row execute function app.tg_wo_child_changed()', t);
  end loop;
end $$;

-- pengisian awal: semua WO yang ada diberi changed_at = waktu migrasi (clock_timestamp), bukan updated_at yang bisa lebih lama
-- dari perubahan anak terakhir; dengan begitu pull pertama setelah migrasi mengambil ulang semua WO aktif (aman, bukan hilang).
-- Pull tetap memakai coalesce(children_changed_at, updated_at) untuk WO yang belum punya baris.
insert into public.wo_child_changes (wo_id, changed_at) select id, clock_timestamp() from public.work_orders
on conflict (wo_id) do nothing;

-- ---- G-08: teknisi tidak membaca kolom harga work_orders ------------------------------------------------------------
-- View memuat SEMUA kolom work_orders kecuali kelompok harga/penagihan (estimate_total, estimate_version, billing_type,
-- billing_status, billing_override_reason, warranty_exception_reason); daftar kolom eksplisit agar kolom baru tidak bocor otomatis.
-- Dimiliki postgres (membaca tabel tanpa RLS); satu-satunya penjaga adalah filter my_active_wo_ids() + security_barrier.
create or replace view public.tech_work_orders with (security_barrier = true) as
select w.id, w.wo_number, w.type, w.customer_id, w.site_id, w.asset_id, w.service_type_id, w.request_id, w.contract_id,
       w.contract_asset_id, w.pm_period_key, w.parent_wo_id, w.priority_code, w.status,
       w.scheduled_start, w.scheduled_end, w.requested_at,
       w.sla_clock_start_at, w.sla_policy_set_id, w.sla_calendar_id, w.policy_snapshot, w.response_due_at, w.resolution_due_at,
       w.response_met_at, w.resolution_met_at, w.response_sla_state, w.resolution_sla_state, w.sla_paused_at, w.next_sla_check_at,
       w.pm_due_date, w.started_at, w.submitted_at, w.closed_at, w.cancelled_at, w.cancel_reason_code, w.cancel_reason,
       w.cancel_requested_at, w.cancel_requested_by, w.cancel_request_note, w.signoff_expires_at,
       w.closure_exception, w.closure_exception_code, w.closure_exception_note, w.closure_exception_approved_by,
       w.closure_exception_approved_at, w.outcome, w.no_parts_used, w.checklist_template_id, w.checklist_template_version,
       w.returned_count, w.rejection_count, w.failed_visit_count, w.help_requested_at, w.help_requested_by, w.help_note,
       w.customer_note, w.created_by, w.created_at, w.updated_at, w.version,
       c.changed_at as children_changed_at                                                  -- G-05
from public.work_orders w
left join public.wo_child_changes c on c.wo_id = w.id
where w.id in (select app.my_active_wo_ids());
revoke all on public.tech_work_orders from anon, authenticated;
grant select on public.tech_work_orders to authenticated;

-- Policy baca tabel langsung untuk TECHNICIAN dicabut. Staf lain (work_orders_staff) tidak berubah; pelanggan tetap lewat view customer_*.
-- Fungsi/trigger/view definer (wo_transition, apply_wo_transition, helper app.*, customer_*, v_tech_asset_service_history,
-- v_wh_part_requests) berjalan sebagai postgres dan tidak terpengaruh. v_today_work_orders (security_invoker) menjadi kosong bagi teknisi.
drop policy if exists work_orders_tech on public.work_orders;

-- ---- N1: akun nonaktif tidak membaca baris customer_users miliknya ---------------------------------------------------
-- Baris sendiri hanya bila customer_users.is_active dan profiles.is_active. Tabel milik-pengguna lain (profiles, user_roles,
-- user_consents, notifications, sync_operations) SENGAJA tidak diubah: 05 bagian 3 menandainya R* (diri) tanpa syarat aktif
-- (hak mengakses data sendiri, pesan "akun nonaktif" di UI), dan tidak ada data pelanggan lain di dalamnya.
drop policy if exists customer_users_select on public.customer_users;
create policy customer_users_select on public.customer_users for select to authenticated
  using ((user_id = (select auth.uid()) and is_active
          and exists (select 1 from public.profiles p where p.user_id = (select auth.uid()) and p.is_active))
         or customer_id = any ((select app.my_customer_ids())::uuid[])
         or (select app.has_any_role('{ADMIN_CS,OWNER}')));

-- ---- S2: filter status eksplisit pada pembayaran pelanggan (pertahanan berlapis) ---------------------------------------
drop policy if exists payments_customer on public.payments;
create policy payments_customer on public.payments for select to authenticated
  using (invoice_id in (select i.id from public.invoices i
                         where i.customer_id = any ((select app.my_customer_ids())::uuid[]) and i.status in ('ISSUED','PAID')));

-- ---- S4: can_read_object memeriksa bucket per cabang ------------------------------------------------------------------
-- Cabang 'req' hanya bucket wo-media; teknisi hanya bucket wo-media (tidak lagi membaca bucket reports). Staf dan FINANCE tetap.
create or replace function app.can_read_object(p_bucket text, p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_cust uuid; v_scope text; v_owner uuid;
begin
  if p_name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/(req|wo)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.+' then
    return false;                                              -- path tak sesuai konvensi => tolak
  end if;
  v_cust := split_part(p_name, '/', 1)::uuid;
  v_scope := split_part(p_name, '/', 2);
  v_owner := split_part(p_name, '/', 3)::uuid;

  if app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}') then return true; end if;     -- akses staf dicatat via log_data_access (API)
  if p_bucket = 'reports' and app.has_any_role('{FINANCE}') then return true; end if;

  if p_bucket = 'wo-media' and app.has_any_role('{TECHNICIAN}') then                           -- S4: teknisi hanya wo-media
    if v_scope = 'wo' and v_owner in (select app.my_active_wo_ids()) then return true; end if;
    if v_scope = 'req' and v_owner in (select app.tech_request_ids()) then return true; end if;
  end if;

  if v_cust = any ((select app.my_customer_ids())::uuid[]) then                  -- pelanggan: hanya objek yang terdaftar & boleh dilihat
    if p_bucket = 'reports' then
      return exists (select 1 from public.service_reports r join public.work_orders w on w.id = r.wo_id
                      where r.storage_path = p_name and r.customer_id = v_cust and r.status = 'READY' and w.status = 'CLOSED');
    end if;
    if p_bucket <> 'wo-media' then return false; end if;                         -- S4: bucket lain tidak dikenal
    if v_scope = 'req' then
      return exists (select 1 from public.request_attachments a where a.storage_path = p_name and a.customer_id = v_cust);
    end if;
    return exists (select 1 from public.wo_attachments x join public.work_orders w on w.id = x.wo_id
                    where x.storage_path = p_name and w.customer_id = v_cust and w.status = 'CLOSED' and x.deleted_at is null
                      and x.upload_status = 'UPLOADED' and x.kind in ('BEFORE','AFTER','FINDING'))
        or exists (select 1 from public.wo_signatures g join public.work_orders w on w.id = g.wo_id
                    where g.storage_path = p_name and w.customer_id = v_cust and w.status = 'CLOSED' and g.status = 'VALID');
  end if;
  return false;
end $$;

-- ---- N2: sisip sync_operations hanya oleh teknisi aktif dan hanya untuk WO aktifnya -----------------------------------------
-- Sebelumnya hanya user_id = auth.uid(): siapa pun (pelanggan, teknisi lama) dapat menyisipkan baris RECEIVED untuk WO orang lain
-- dan memblokir penutupannya (SYNC_UNAPPLIED). wo_id boleh NULL: operasi untuk WO yang sudah tidak dipegang (REASSIGNED/RELEASED)
-- disisipkan dengan wo_id NULL (WO tetap ada di payload) lalu dicatat RESCUED lewat sync_op_record, sehingga draf tidak hilang (DEC-06).
drop policy if exists sync_operations_insert_own on public.sync_operations;
create policy sync_operations_insert_own on public.sync_operations for insert to authenticated
  with check (user_id = (select auth.uid()) and (select app.has_any_role('{TECHNICIAN}'))
              and (wo_id is null or wo_id in (select app.my_active_wo_ids())));

-- ---- GRANT eksplisit RPC publik baru (cabut dari PUBLIC dan anon; hanya authenticated) --------------------------------
revoke all on function public.wo_declare_no_parts(uuid, boolean, int, uuid) from public, anon, authenticated;
revoke all on function public.wo_closure_check(uuid) from public, anon, authenticated;
revoke all on function public.sync_op_record(uuid, text, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.sync_rescued_resolve(uuid, text) from public, anon, authenticated;
grant execute on function
  public.wo_declare_no_parts(uuid, boolean, int, uuid), public.wo_closure_check(uuid),
  public.sync_op_record(uuid, text, jsonb, boolean), public.sync_rescued_resolve(uuid, text)
to authenticated;
