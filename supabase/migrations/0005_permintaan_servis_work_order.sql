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
