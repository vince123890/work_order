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
