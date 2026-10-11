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
