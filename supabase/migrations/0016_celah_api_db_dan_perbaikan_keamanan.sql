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
