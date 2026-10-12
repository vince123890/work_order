-- ===== MIGRATION 0017: sinyal perubahan anak WO tanpa deadlock (N3) ===================
-- Memperbaiki temuan N3 (WP-007, uji D2): constraint trigger deferred app.tg_wo_child_changed (0016) melakukan UPSERT
-- (insert ... on conflict (wo_id) do update) ke baris tunggal per WO saat COMMIT. Dua transaksi yang menyentuh WO A dan B
-- dalam urutan terbalik lalu commit bersamaan saling menunggu baris/indeks unik wo_id => deadlock 40P01 dan korban kehilangan
-- SELURUH transaksi bisnis.
-- Desain: wo_child_changes menjadi APPEND-ONLY tanpa constraint unik pada wo_id. Trigger hanya INSERT murni (tanpa ON CONFLICT),
-- jadi tidak ada penantian antar transaksi (insert ke btree non-unik tidak menunggu transaksi lain), untuk WO sama MAUPUN beda.
-- Satu WO boleh punya beberapa baris sinyal (duplikat sementara); "WO berubah setelah T" = max(changed_at) per WO, disajikan
-- view tech_work_orders.children_changed_at (kontrak kolom tidak berubah). Pemadatan terjadwal menyisakan baris terbaru per WO.
-- Idempoten dan tanpa kehilangan data: baris hasil 0016 (satu per WO) tetap ada sebagai baris terbaru. work_orders tidak disentuh
-- (version/updated_at tidak naik). Pemadatan hanya DELETE baris lama, tidak pernah menyentuh baris terbaru yang dibaca pull.
-- Klien: baca children_changed_at dari view, atau bila membaca tabel langsung WAJIB group by wo_id / max(changed_at).

-- Pengaman penerapan (review 0017): gagal cepat daripada menunggu tanpa batas dan memblok commit bisnis di belakang kunci DDL.
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1. Lepas PK (wo_id) dari 0016; wo_id tetap not null. Indeks pembacaan max per WO; indeks kursor 0016 (changed_at, wo_id) dipertahankan.
alter table public.wo_child_changes drop constraint if exists wo_child_changes_pkey;
alter table public.wo_child_changes alter column wo_id set not null;
create index if not exists ix_wo_child_changes_wo_at on public.wo_child_changes (wo_id, changed_at desc);
alter table public.wo_child_changes set (autovacuum_vacuum_scale_factor = 0.05);   -- tabel insert/delete berat
-- RLS dan GRANT dari 0016 tidak berubah (select untuk authenticated, tulis hanya lewat trigger definer); dinyatakan ulang agar eksplisit.
alter table public.wo_child_changes enable row level security;
revoke all on public.wo_child_changes from anon, authenticated;
grant select on public.wo_child_changes to authenticated;

-- 2. Trigger: insert murni. Dedupe per WO per transaksi lewat GUC lokal dipertahankan (paling banyak satu baris per WO per transaksi).
-- Tidak ada exception handler SENGAJA: insert murni ke tabel tanpa kunci bersama tidak punya mode gagal selain kerusakan fatal
-- (disk penuh, tabel hilang); menelan galat itu berarti kehilangan sinyal diam-diam, yang lebih buruk daripada membatalkan transaksi.
create or replace function app.tg_wo_child_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_key text := 'app.wcc_' || replace(new.wo_id::text, '-', '_');
begin
  if coalesce(current_setting(v_key, true), '') = '1' then return null; end if;
  perform set_config(v_key, '1', true);
  insert into public.wo_child_changes (wo_id, changed_at) values (new.wo_id, clock_timestamp());
  return null;
end $$;
revoke execute on function app.tg_wo_child_changed() from public, anon, authenticated;

-- 3. Pemadatan: hapus baris yang BUKAN terbaru per WO dan lebih tua dari p_min_age, paling banyak p_batch baris per panggilan.
-- Trigger tidak pernah mengunci baris lama, jadi DELETE ini tidak membuat urutan kunci dengan transaksi bisnis. Antar pemadat
-- dijaga satu pelaksana (advisory lock transaksi, try): panggilan kedua yang bersamaan langsung selesai (0 baris) tanpa menunggu.
-- Heartbeat ke job_runs seperti app.run_job; galat pemadatan dicatat ERROR (pemadatan bukan transaksi bisnis dan tidak menelan sinyal).
create or replace function app.compact_wo_child_changes(p_min_age interval default interval '10 minutes', p_batch int default 20000)
returns int language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_n int := 0;
begin
  insert into public.job_runs (job_name) values ('compact_wo_child_changes') returning id into v_id;
  begin
    if pg_try_advisory_xact_lock(hashtextextended('vasta.compact_wo_child_changes', 0)) then
      with ranked as (
        select ctid as rid, changed_at,
               row_number() over (partition by wo_id order by changed_at desc, ctid desc) as rn
          from public.wo_child_changes
      ), old as (
        select rid from ranked where rn > 1 and changed_at < clock_timestamp() - p_min_age limit p_batch
      )
      delete from public.wo_child_changes d where d.ctid in (select rid from old);
      get diagnostics v_n = row_count;
    end if;
    update public.job_runs set status = 'OK', finished_at = now(), rows_affected = v_n where id = v_id;
  exception when others then
    update public.job_runs set status = 'ERROR', finished_at = now(), error = sqlerrm where id = v_id;
  end;
  return v_n;
end $$;
revoke execute on function app.compact_wo_child_changes(interval, int) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('vasta_compact_wo_child_changes', '*/10 * * * *', $j$select app.compact_wo_child_changes()$j$);
  else
    raise notice 'pg_cron tidak aktif: jadwalkan select app.compact_wo_child_changes() tiap ~10 menit lewat scheduler eksternal.';
  end if;
end $$;

-- 4. View tech_work_orders: kolom identik dengan 0016; children_changed_at = max(changed_at) per WO (NULL bila belum ada baris).
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
       (select max(c.changed_at) from public.wo_child_changes c where c.wo_id = w.id) as children_changed_at   -- G-05 (0017)
from public.work_orders w
where w.id in (select app.my_active_wo_ids());
revoke all on public.tech_work_orders from anon, authenticated;
grant select on public.tech_work_orders to authenticated;
