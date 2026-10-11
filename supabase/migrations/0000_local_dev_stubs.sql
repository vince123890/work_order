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
