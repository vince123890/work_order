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
