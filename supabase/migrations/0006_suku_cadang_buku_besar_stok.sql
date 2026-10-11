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
