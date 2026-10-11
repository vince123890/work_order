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
