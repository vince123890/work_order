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
