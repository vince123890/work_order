-- ===== MIGRATION 0010: fungsi bisnis ===============================================
-- ---- 0010a: helper SLA / penugasan / pembatalan / laporan --------------------------------

-- Tandai respons/penyelesaian terpenuhi (BR-013).
create or replace function app.sla_mark_met(p_wo_id uuid, p_kind text, p_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_kind = 'RESPONSE' then
    update public.work_orders w set response_met_at = p_at,
           response_sla_state = case when w.response_due_at is not null and p_at > w.response_due_at
                                     then 'MET_LATE'::public.sla_state else 'MET'::public.sla_state end
     where w.id = p_wo_id and w.response_met_at is null;
  else
    update public.work_orders w set resolution_met_at = p_at, sla_paused_at = null,
           resolution_sla_state = case when w.resolution_due_at is not null and p_at > w.resolution_due_at
                                       then 'MET_LATE'::public.sla_state else 'MET'::public.sla_state end
     where w.id = p_wo_id and w.resolution_met_at is null;
    update public.sla_pauses set resumed_at = p_at where wo_id = p_wo_id and resumed_at is null;
  end if;
end $$;

-- Jeda timer penyelesaian (BR-012). Tidak berlaku untuk WO preventif (jendela tanggal, BR-016).
create or replace function app.sla_pause(p_wo_id uuid, p_reason text, p_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders; v_rem numeric;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if w.type = 'PREVENTIVE' or w.sla_paused_at is not null or w.resolution_due_at is null or w.resolution_met_at is not null then
    return;
  end if;
  v_rem := app.sla_business_minutes_between(p_at, w.resolution_due_at, w.sla_calendar_id);
  insert into public.sla_pauses (wo_id, reason, paused_at, remaining_minutes) values (p_wo_id, p_reason, p_at, v_rem);
  update public.work_orders set sla_paused_at = p_at, resolution_sla_state = 'PAUSED' where id = p_wo_id;
end $$;

create or replace function app.sla_resume(p_wo_id uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders; pz public.sla_pauses;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if w.sla_paused_at is null then return; end if;
  select * into pz from public.sla_pauses where wo_id = p_wo_id and resumed_at is null order by paused_at desc limit 1;
  update public.sla_pauses set resumed_at = p_at where id = pz.id;
  update public.work_orders set sla_paused_at = null, resolution_sla_state = 'RUNNING',
         resolution_due_at = app.sla_add_business_minutes(p_at, pz.remaining_minutes, w.sla_calendar_id),
         next_sla_check_at = p_at
   where id = p_wo_id;
end $$;

-- Peringatan lunak penugasan (FR-043): keahlian & bentrok jadwal. Mengembalikan array jsonb.
create or replace function app.assignment_warnings(p_tech uuid, p_service_type uuid, p_start timestamptz,
                                                   p_end timestamptz, p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_warn jsonb := '[]'::jsonb; v_skill uuid;
begin
  select skill_id into v_skill from public.service_types where id = p_service_type;
  if v_skill is not null and not exists (select 1 from public.technician_skills ts
                                          where ts.technician_id = p_tech and ts.skill_id = v_skill) then
    v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'SKILL_MISMATCH'));
  end if;
  if p_start is not null and exists (
       select 1 from public.wo_assignments a join public.work_orders o on o.id = a.wo_id
        where a.technician_id = p_tech and a.role = 'LEAD' and a.status in ('ASSIGNED','ACCEPTED')
          and o.id <> p_wo and o.scheduled_start is not null
          and tstzrange(o.scheduled_start, coalesce(o.scheduled_end, o.scheduled_start + interval '1 minute'))
              && tstzrange(p_start, coalesce(p_end, p_start + interval '1 minute'))) then
    v_warn := v_warn || jsonb_build_array(jsonb_build_object('code', 'SCHEDULE_OVERLAP'));
  end if;
  return v_warn;
end $$;

-- Snapshot isi laporan servis (tanpa HPP/biaya internal/catatan internal) (FR-140/141).
create or replace function app.build_report_snapshot(p_wo_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'wo', jsonb_build_object('wo_number', w.wo_number, 'type', w.type, 'priority', w.priority_code,
            'requested_at', w.requested_at, 'scheduled_start', w.scheduled_start, 'scheduled_end', w.scheduled_end,
            'started_at', w.started_at, 'submitted_at', w.submitted_at, 'closed_at', w.closed_at, 'outcome', w.outcome),
    'customer', jsonb_build_object('name', c.name),
    'site', (select jsonb_build_object('name', s.name, 'address', s.address) from public.customer_sites s where s.id = w.site_id),
    'asset', jsonb_build_object('asset_code', a.asset_code, 'serial_no', a.serial_no, 'brand', a.brand, 'model', a.model),
    'technician', (select p.full_name from public.wo_assignments x
                     join public.technicians t on t.id = x.technician_id
                     join public.profiles p on p.user_id = t.user_id
                    where x.wo_id = w.id and x.role = 'LEAD' and x.status in ('ACCEPTED','COMPLETED')
                    order by x.assigned_at desc limit 1),
    'findings', (select jsonb_build_object('diagnosis', f.diagnosis, 'action_taken', f.action_taken,
                         'recommendation', f.recommendation) from public.wo_findings f where f.wo_id = w.id),
    'checklist', (select coalesce(jsonb_agg(jsonb_build_object('seq', i.seq, 'label', i.label_snapshot, 'value', i.value,
                         'is_na', i.is_na, 'na_reason', i.na_reason) order by i.seq), '[]'::jsonb)
                    from public.wo_checklist_items i where i.wo_id = w.id),
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'path', x.storage_path, 'taken_at', x.taken_at)
                         order by x.taken_at), '[]'::jsonb)
                 from public.wo_attachments x
                where x.wo_id = w.id and x.deleted_at is null and x.upload_status = 'UPLOADED'
                  and x.kind in ('BEFORE','AFTER','FINDING')),
    'parts', (select coalesce(jsonb_agg(jsonb_build_object('sku', it.sku, 'name', it.name, 'qty', u.qty, 'uom', it.uom,
                         'billable', u.billable)), '[]'::jsonb)
                from public.wo_part_usages u join public.items it on it.id = u.item_id
               where u.wo_id = w.id and u.deleted_at is null),
    'labor', (select coalesce(jsonb_agg(jsonb_build_object('description', l.description, 'qty', l.qty,
                         'billable', l.billable)), '[]'::jsonb)
                from public.wo_labor_lines l where l.wo_id = w.id and l.deleted_at is null),
    'signatures', (select coalesce(jsonb_agg(jsonb_build_object('signer_name', g.signer_name, 'signed_at', g.signed_at,
                         'path', g.storage_path, 'via', g.signed_via)), '[]'::jsonb)
                     from public.wo_signatures g where g.wo_id = w.id and g.status = 'VALID'),
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('check_in_at', v.check_in_at, 'check_out_at', v.check_out_at)
                         order by v.check_in_at), '[]'::jsonb)
                 from public.wo_visits v where v.wo_id = w.id),
    'closure_exception', jsonb_build_object('flag', w.closure_exception, 'code', w.closure_exception_code,
                         'note', w.closure_exception_note)
  )
  from public.work_orders w
  join public.customers c on c.id = w.customer_id
  join public.assets a on a.id = w.asset_id
  where w.id = p_wo_id
$$;

-- Efek pembatalan (T-22/T-23): tutup penugasan, persetujuan, permintaan suku cadang; PM periode dicatat.
create or replace function app.wo_cancel_effects(p_wo_id uuid, p_code text, p_reason text, p_by uuid, p_now timestamptz)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform app.notify_wo_technicians(p_wo_id, 'wo.cancelled', jsonb_build_object('reason', p_reason), 'cancel-tech:' || p_wo_id::text);
  update public.wo_assignments set status = 'CANCELLED', ended_at = p_now
   where wo_id = p_wo_id and status in ('ASSIGNED','ACCEPTED');
  update public.wo_visits set check_out_at = p_now, auto_checked_out = true,
         result = coalesce(result, 'FAILED_OTHER'), note = coalesce(note, 'WO dibatalkan')
   where wo_id = p_wo_id and check_in_at is not null and check_out_at is null;
  update public.extra_cost_approvals set status = 'SUPERSEDED' where wo_id = p_wo_id and status = 'PENDING';
  update public.part_requests set status = 'CANCELLED' where wo_id = p_wo_id and status in ('REQUESTED','APPROVED','PARTIALLY_ISSUED');
  update public.sla_pauses set resumed_at = p_now where wo_id = p_wo_id and resumed_at is null;
  update public.work_orders set cancelled_at = p_now, cancel_reason_code = p_code, cancel_reason = p_reason,
         sla_paused_at = null
   where id = p_wo_id;
  update public.pm_periods set status = case when p_code = 'CONTRACT_CHANGED' then 'SKIPPED' else 'MISSED' end::public.pm_period_status,
         missed_at = case when p_code = 'CONTRACT_CHANGED' then missed_at else p_now end,
         skip_reason = case when p_code = 'CONTRACT_CHANGED' then p_reason else skip_reason end
   where wo_id = p_wo_id and status = 'GENERATED';
  perform app.refresh_parts_variances(p_wo_id, false);          -- BR-037: barang diserahkan jadi selisih sampai kembali
end $$;

-- ---- 0010b: inti transisi status WO (T-02..T-27) ---------------------------------------------
-- Satu-satunya jalan mengubah work_orders.status. Memvalidasi: versi, peran, guard per transisi;
-- menulis riwayat (trigger), audit (trigger), notifikasi, SLA. Idempoten terhadap p_op_id.
create or replace function app.apply_wo_transition(
  p_wo_id uuid, p_action text, p_actor_id uuid, p_actor_roles public.app_role[], p_is_system boolean,
  p_expected_version int, p_op_id uuid, p_reason text, p_reason_code text, p_payload jsonb default '{}'::jsonb,
  p_now timestamptz default now()
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  w public.work_orders; t public.wo_transitions;
  v_pl jsonb := coalesce(p_payload, '{}'::jsonb);
  v_eff public.app_role[]; v_tech uuid; v_lead public.wo_assignments; v_ok boolean;
  v_def jsonb; v_warn jsonb := '[]'::jsonb; v_new_tech uuid; v_n int; v_th int;
  v_ap public.extra_cost_approvals; v_tol int; v_sched date; v_today date; v_visit uuid;
  v_exc text; v_outcome public.wo_outcome; v_rev int; v_snap jsonb; v_has_billable boolean;
  v_ev text; v_tz text := coalesce(app.setting_text('default_timezone'), 'Asia/Jakarta');
  v_force boolean := false; v_to public.wo_status; v_expect public.approval_status;
  v_prev text := coalesce(current_setting('app.tx_active', true), 'off');
begin
  select * into w from public.work_orders where id = p_wo_id for update;
  if not found then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;

  -- (d) replay idempoten
  if p_op_id is not null and exists (select 1 from public.wo_status_history h where h.wo_id = p_wo_id and h.op_id = p_op_id) then
    return jsonb_build_object('status', w.status, 'version', w.version, 'replayed', true);
  end if;

  select * into t from public.wo_transitions where action = p_action and from_status = w.status;
  if not found then
    raise exception 'WO001: aksi % tidak diizinkan dari status %', p_action, w.status using errcode = 'WO001',
      detail = jsonb_build_object('action', p_action, 'from_status', w.status)::text;
  end if;
  v_to := t.to_status;

  -- peran
  if p_is_system then
    if not t.allow_system then
      raise exception 'WO002: aksi % tidak boleh dilakukan sistem', p_action using errcode = 'WO002';
    end if;
  else
    select coalesce(array_agg(r), '{}'::public.app_role[]) into v_eff
      from unnest(p_actor_roles) r where r = any (t.allowed_roles);
    if cardinality(v_eff) = 0 then
      raise exception 'WO002: peran tidak berhak untuk aksi %', p_action using errcode = 'WO002';
    end if;
    if v_eff = array['TECHNICIAN']::public.app_role[] then          -- teknisi hanya untuk WO yang ditugaskan
      v_tech := app.my_technician_id();
      if v_tech is null or not exists (select 1 from public.wo_assignments a
            where a.wo_id = p_wo_id and a.technician_id = v_tech and a.role = 'LEAD' and a.status in ('ASSIGNED','ACCEPTED')) then
        raise exception 'WO002: bukan teknisi yang ditugaskan' using errcode = 'WO002';
      end if;
    end if;
  end if;

  if not p_is_system and p_expected_version is null then
    raise exception 'WO004: expected_version wajib' using errcode = 'WO004';
  end if;
  if p_expected_version is not null and w.version <> p_expected_version then
    raise exception 'WO004: konflik versi (klien %, server %)', p_expected_version, w.version using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;

  if t.requires_reason and coalesce(btrim(p_reason), '') = '' then
    raise exception 'WO003: alasan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;

  perform set_config('app.tx_active', 'on', true);
  perform set_config('app.tx_action', p_action, true);
  perform set_config('app.tx_reason', coalesce(p_reason, ''), true);
  perform set_config('app.tx_reason_code', coalesce(p_reason_code, ''), true);
  perform set_config('app.tx_customer_note', coalesce(v_pl ->> 'customer_note', ''), true);
  perform set_config('app.tx_op_id', coalesce(p_op_id::text, ''), true);
  perform set_config('app.actor_role', case when p_is_system then 'SYSTEM' else array_to_string(v_eff, ',') end, true);

  select * into v_lead from public.wo_assignments a
   where a.wo_id = p_wo_id and a.role = 'LEAD' and a.status in ('ASSIGNED','ACCEPTED') limit 1;

  case p_action
  -- T-02 / T-05: penugasan & tugas ulang
  when 'ASSIGN', 'REASSIGN' then
    v_new_tech := nullif(v_pl ->> 'technician_id', '')::uuid;
    if v_new_tech is null or not exists (select 1 from public.technicians x where x.id = v_new_tech and x.is_active) then
      raise exception 'WO003: teknisi tidak valid' using errcode = 'WO003', detail = '{"code":"TECHNICIAN_INVALID"}';
    end if;
    if nullif(v_pl ->> 'scheduled_start', '') is null then
      raise exception 'WO003: jadwal final wajib' using errcode = 'WO003', detail = '{"code":"SCHEDULE_REQUIRED"}';
    end if;
    v_warn := app.assignment_warnings(v_new_tech, w.service_type_id, (v_pl ->> 'scheduled_start')::timestamptz,
                                      nullif(v_pl ->> 'scheduled_end', '')::timestamptz, p_wo_id);
    if jsonb_array_length(v_warn) > 0 and coalesce(btrim(v_pl ->> 'override_reason'), '') = '' then
      raise exception 'WO003: peringatan lunak penugasan butuh override_reason' using errcode = 'WO003',
        detail = jsonb_build_object('code', 'SOFT_GUARD', 'warnings', v_warn)::text;
    end if;
    if p_action = 'REASSIGN' then
      perform app.notify_wo_technicians(p_wo_id, 'wo.reassigned_away', jsonb_build_object('wo_number', w.wo_number), 'reassign-old:' || coalesce(p_op_id::text, gen_random_uuid()::text));
      update public.wo_assignments set status = 'REASSIGNED', ended_at = p_now, reason = p_reason, reason_code = p_reason_code
       where wo_id = p_wo_id and role = 'LEAD' and status in ('ASSIGNED','ACCEPTED');
      v_force := true;
    end if;
    update public.work_orders set scheduled_start = (v_pl ->> 'scheduled_start')::timestamptz,
           scheduled_end = nullif(v_pl ->> 'scheduled_end', '')::timestamptz where id = p_wo_id;
    insert into public.wo_assignments (wo_id, technician_id, role, status, assigned_by, override_reason)
    values (p_wo_id, v_new_tech, 'LEAD', 'ASSIGNED', p_actor_id, nullif(v_pl ->> 'override_reason', ''));
    perform app.enqueue_notification((select user_id from public.technicians where id = v_new_tech), 'wo.assigned', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'scheduled_start', v_pl ->> 'scheduled_start'),
              'assign:' || p_wo_id::text || ':' || coalesce(p_op_id::text, gen_random_uuid()::text));
    if p_action = 'REASSIGN' and w.status = 'ACCEPTED' then
      perform app.notify_customer(w.customer_id, 'wo.rescheduled', p_wo_id,
                jsonb_build_object('wo_number', w.wo_number), 'resched:' || p_wo_id::text || ':' || coalesce(p_op_id::text, gen_random_uuid()::text));
    end if;

  -- T-03
  when 'ACCEPT' then
    update public.wo_assignments set status = 'ACCEPTED', responded_at = p_now where id = v_lead.id;
    if w.policy_snapshot ->> 'response_met_event' = 'ACCEPT' then perform app.sla_mark_met(p_wo_id, 'RESPONSE', p_now); end if;
    perform app.notify_customer(w.customer_id, 'wo.scheduled', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'scheduled_start', w.scheduled_start, 'scheduled_end', w.scheduled_end),
              'accepted:' || p_wo_id::text || ':' || v_lead.id::text);

  -- T-04
  when 'REJECT' then
    update public.wo_assignments set status = 'REJECTED', responded_at = p_now, ended_at = p_now,
           reason = p_reason, reason_code = p_reason_code where id = v_lead.id;
    update public.work_orders set rejection_count = rejection_count + 1 where id = p_wo_id returning rejection_count into v_n;
    perform app.notify_role('DISPATCHER', 'wo.assignment_rejected', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'reason', p_reason), 'rej:' || p_wo_id::text || ':' || v_n::text);
    v_th := app.setting_int('reject.escalation_threshold');
    if v_th is not null and v_n >= v_th then
      perform app.notify_role('SUPERVISOR', 'wo.rejection_escalation', p_wo_id,
                jsonb_build_object('wo_number', w.wo_number, 'rejection_count', v_n), 'rejesc:' || p_wo_id::text || ':' || v_n::text);
    end if;

  -- T-06
  when 'RELEASE' then
    if exists (select 1 from public.wo_visits where wo_id = p_wo_id and check_in_at is not null) then
      raise exception 'WO003: sudah check-in, gunakan serah-terima' using errcode = 'WO003', detail = '{"code":"ALREADY_CHECKED_IN"}';
    end if;
    update public.wo_assignments set status = 'RELEASED', ended_at = p_now, reason = p_reason, reason_code = p_reason_code
     where id = v_lead.id;
    perform app.notify_role('DISPATCHER', 'wo.released', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'reason', p_reason),
              'rel:' || p_wo_id::text || ':' || v_lead.id::text);

  -- T-07
  when 'DEPART' then
    v_tol := app.setting_int('en_route.tolerance_days');
    if v_tol is not null then
      v_sched := (w.scheduled_start at time zone v_tz)::date;
      v_today := (p_now at time zone v_tz)::date;
      if v_sched is null or abs(v_sched - v_today) > v_tol then
        raise exception 'WO003: bukan hari jadwal' using errcode = 'WO003', detail = '{"code":"NOT_SCHEDULED_TODAY"}';
      end if;
    end if;
    if w.policy_snapshot ->> 'response_met_event' = 'DEPART' then perform app.sla_mark_met(p_wo_id, 'RESPONSE', p_now); end if;
    perform app.notify_customer(w.customer_id, 'wo.en_route', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
              'enroute:' || p_wo_id::text || ':' || w.version::text);

  -- T-08
  when 'CHECK_IN' then
    if (nullif(v_pl ->> 'lat', '') is null or nullif(v_pl ->> 'lng', '') is null)
       and coalesce(btrim(v_pl ->> 'no_gps_reason'), '') = '' then
      raise exception 'WO003: lokasi GPS atau alasan tanpa lokasi wajib' using errcode = 'WO003',
        detail = '{"code":"GPS_OR_REASON_REQUIRED"}';
    end if;
    insert into public.wo_visits (wo_id, technician_id, check_in_at, check_in_lat, check_in_lng, check_in_accuracy_m, check_in_no_gps_reason)
    values (p_wo_id, v_lead.technician_id, coalesce(nullif(v_pl ->> 'client_ts', '')::timestamptz, p_now),
            nullif(v_pl ->> 'lat', '')::numeric, nullif(v_pl ->> 'lng', '')::numeric,
            nullif(v_pl ->> 'accuracy_m', '')::numeric, nullif(btrim(v_pl ->> 'no_gps_reason'), ''));
    update public.work_orders set started_at = coalesce(started_at, p_now) where id = p_wo_id;
    if w.policy_snapshot ->> 'response_met_event' = 'CHECK_IN' then perform app.sla_mark_met(p_wo_id, 'RESPONSE', p_now); end if;

  -- T-09 / T-10
  when 'HOLD_PARTS' then
    if not exists (select 1 from public.part_requests where wo_id = p_wo_id and status in ('REQUESTED','APPROVED','PARTIALLY_ISSUED')) then
      raise exception 'WO003: tidak ada permintaan suku cadang terbuka' using errcode = 'WO003', detail = '{"code":"NO_OPEN_PART_REQUEST"}';
    end if;
    if coalesce((w.policy_snapshot ->> 'pause_on_hold_parts')::boolean, false) then
      perform app.sla_pause(p_wo_id, 'ON_HOLD_PARTS', p_now);
    end if;
    perform app.notify_role('DISPATCHER', 'wo.on_hold_parts', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'hold:' || p_wo_id::text || ':' || w.version::text);
    perform app.notify_role('WAREHOUSE', 'wo.on_hold_parts', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'holdw:' || p_wo_id::text || ':' || w.version::text);
  when 'RESUME_PARTS' then
    if not (p_is_system or 'DISPATCHER' = any (v_eff))
       and exists (select 1 from public.part_requests where wo_id = p_wo_id and status in ('REQUESTED','APPROVED','PARTIALLY_ISSUED')) then
      raise exception 'WO003: permintaan suku cadang masih terbuka' using errcode = 'WO003', detail = '{"code":"PART_REQUEST_OPEN"}';
    end if;
    perform app.sla_resume(p_wo_id, p_now);

  -- T-11..T-15: biaya tambahan
  when 'REQUEST_EXTRA_COST' then
    select * into v_ap from public.extra_cost_approvals where wo_id = p_wo_id and status = 'PENDING';
    if v_ap.id is null or not exists (select 1 from public.extra_cost_approval_items where approval_id = v_ap.id) then
      raise exception 'WO003: pengajuan biaya tambahan PENDING (dengan item) wajib' using errcode = 'WO003', detail = '{"code":"EXTRA_COST_REQUEST_MISSING"}';
    end if;
    perform app.sla_pause(p_wo_id, 'AWAITING_CUSTOMER_APPROVAL', p_now);
    perform app.notify_customer(w.customer_id, 'wo.approval_needed', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'approval_id', v_ap.id, 'total', v_ap.total), 'approval:' || v_ap.id::text);
  when 'APPROVE_EXTRA_COST', 'REJECT_EXTRA_COST', 'EXPIRE_EXTRA_COST' then
    select * into v_ap from public.extra_cost_approvals where id = nullif(v_pl ->> 'approval_id', '')::uuid and wo_id = p_wo_id;
    v_expect := (case p_action when 'APPROVE_EXTRA_COST' then 'APPROVED'
                               when 'REJECT_EXTRA_COST' then 'REJECTED' else 'EXPIRED' end)::public.approval_status;
    if v_ap.id is null or v_ap.status <> v_expect then
      raise exception 'WO003: keputusan persetujuan belum tercatat (gunakan extra_cost_decide)' using errcode = 'WO003',
        detail = '{"code":"APPROVAL_DECISION_MISSING"}';
    end if;
    perform app.sla_resume(p_wo_id, p_now);
    perform app.notify_wo_technicians(p_wo_id, 'wo.approval_' || lower(substr(p_action, 1, position('_EXTRA' in p_action) - 1)),
              jsonb_build_object('wo_number', w.wo_number, 'approval_id', v_ap.id), 'apprres:' || v_ap.id::text);
    if p_action = 'EXPIRE_EXTRA_COST' then
      perform app.notify_role('DISPATCHER', 'wo.approval_expired', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'appexp:' || v_ap.id::text);
      perform app.notify_role('ADMIN_CS', 'wo.approval_expired', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'appexpa:' || v_ap.id::text);
    end if;
  when 'CLOSE_AFTER_REJECTION' then
    select * into v_ap from public.extra_cost_approvals where wo_id = p_wo_id order by version_no desc limit 1;
    if v_ap.id is null or v_ap.status not in ('REJECTED','EXPIRED') or coalesce(v_ap.continue_original_scope, true) then
      raise exception 'WO003: tidak ada penolakan yang menghalangi lingkup awal' using errcode = 'WO003', detail = '{"code":"NO_BLOCKING_REJECTION"}';
    end if;
    v_outcome := coalesce(nullif(v_pl ->> 'outcome', '')::public.wo_outcome, 'UNRESOLVED');
    if v_outcome = 'RESOLVED' then
      raise exception 'WO003: outcome harus PARTIAL/UNRESOLVED' using errcode = 'WO003', detail = '{"code":"OUTCOME_INVALID"}';
    end if;
    v_def := app.wo_submit_deficiencies(p_wo_id, 'SUBMIT', nullif(v_pl ->> 'client_pending_ops', '')::int);
    if jsonb_array_length(v_def) > 0 then
      raise exception 'WO003: syarat penutupan belum lengkap' using errcode = 'WO003', detail = v_def::text;
    end if;
    perform app.sla_resume(p_wo_id, p_now);
    update public.wo_visits set check_out_at = p_now, result = 'COMPLETED', auto_checked_out = true
     where wo_id = p_wo_id and check_in_at is not null and check_out_at is null;
    update public.work_orders set outcome = v_outcome, submitted_at = p_now where id = p_wo_id;
    if w.policy_snapshot ->> 'resolution_met_event' = 'SUBMIT' then perform app.sla_mark_met(p_wo_id, 'RESOLUTION', p_now); end if;
    perform app.notify_role('SUPERVISOR', 'wo.review_needed', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'outcome', v_outcome),
              'review:' || p_wo_id::text || ':' || w.version::text);

  -- T-16 / T-17 / T-18: penutupan oleh teknisi
  when 'SUBMIT_REVIEW', 'REQUEST_SIGNOFF' then
    -- BR-043: tanda tangan yang hash-nya tidak sama dengan isi sekarang menjadi SUPERSEDED
    update public.wo_signatures set status = 'SUPERSEDED'
     where wo_id = p_wo_id and status = 'VALID' and content_hash <> app.wo_content_hash(p_wo_id);
    v_exc := nullif(btrim(v_pl ->> 'closure_exception_code'), '');
    if v_exc is not null and p_action = 'SUBMIT_REVIEW' then                       -- BR-041
      if not exists (select 1 from public.reason_codes where category = 'CLOSURE_EXCEPTION' and code = v_exc and is_active) then
        raise exception 'WO006: kode pengecualian tidak dikenal' using errcode = 'WO006';
      end if;
      if coalesce(btrim(v_pl ->> 'closure_exception_note'), '') = '' then
        raise exception 'WO003: catatan pengecualian wajib' using errcode = 'WO003', detail = '{"code":"EXCEPTION_NOTE_REQUIRED"}';
      end if;
      update public.work_orders set closure_exception = true, closure_exception_code = v_exc,
             closure_exception_note = v_pl ->> 'closure_exception_note' where id = p_wo_id;
    end if;
    v_def := app.wo_submit_deficiencies(p_wo_id, case p_action when 'SUBMIT_REVIEW' then 'SUBMIT' else 'SIGNOFF_REQUEST' end,
                                        nullif(v_pl ->> 'client_pending_ops', '')::int);
    if jsonb_array_length(v_def) > 0 then
      raise exception 'WO003: syarat penutupan belum lengkap' using errcode = 'WO003', detail = v_def::text;
    end if;
    update public.wo_visits set check_out_at = p_now, check_out_lat = nullif(v_pl ->> 'lat', '')::numeric,
           check_out_lng = nullif(v_pl ->> 'lng', '')::numeric, result = 'COMPLETED'
     where wo_id = p_wo_id and check_in_at is not null and check_out_at is null;
    update public.work_orders set outcome = coalesce(nullif(v_pl ->> 'outcome', '')::public.wo_outcome, outcome, 'RESOLVED') where id = p_wo_id;
    if p_action = 'SUBMIT_REVIEW' then
      update public.work_orders set submitted_at = p_now where id = p_wo_id;
      if w.policy_snapshot ->> 'resolution_met_event' = 'SUBMIT' then perform app.sla_mark_met(p_wo_id, 'RESOLUTION', p_now); end if;
      perform app.notify_role('SUPERVISOR', 'wo.review_needed', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
                'review:' || p_wo_id::text || ':' || w.version::text);
    else
      update public.work_orders set signoff_expires_at = case when app.setting_int('signoff.expiry_hours') is null then null
                 else p_now + make_interval(hours => app.setting_int('signoff.expiry_hours')) end where id = p_wo_id;
      if w.policy_snapshot ->> 'resolution_met_event' = 'SUBMIT' then
        perform app.sla_mark_met(p_wo_id, 'RESOLUTION', p_now);
      else
        perform app.sla_pause(p_wo_id, 'AWAITING_SIGNOFF', p_now);
      end if;
      perform app.notify_customer(w.customer_id, 'wo.signoff_needed', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
                'signoff:' || p_wo_id::text || ':' || w.version::text);
    end if;
  when 'SIGNOFF', 'EXPIRE_SIGNOFF' then
    if p_action = 'EXPIRE_SIGNOFF' then
      update public.work_orders set closure_exception = true, closure_exception_code = 'NO_RESPONSE',
             closure_exception_note = 'pelanggan tidak menjawab hingga batas waktu' where id = p_wo_id;
    end if;
    update public.wo_signatures set status = 'SUPERSEDED'
     where wo_id = p_wo_id and status = 'VALID' and content_hash <> app.wo_content_hash(p_wo_id);
    v_def := app.wo_submit_deficiencies(p_wo_id, 'SUBMIT', 0);
    if jsonb_array_length(v_def) > 0 then
      raise exception 'WO003: syarat penutupan belum lengkap' using errcode = 'WO003', detail = v_def::text;
    end if;
    perform app.sla_resume(p_wo_id, p_now);
    update public.work_orders set submitted_at = coalesce(submitted_at, p_now), signoff_expires_at = null where id = p_wo_id;
    perform app.notify_role('SUPERVISOR', 'wo.review_needed', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
              'review:' || p_wo_id::text || ':' || w.version::text);

  -- T-19: supervisor menyetujui => CLOSED
  when 'APPROVE_CLOSE' then
    if w.closure_exception then
      if not coalesce((v_pl ->> 'approve_exception')::boolean, false) then
        raise exception 'WO003: pengecualian penutupan harus disetujui eksplisit' using errcode = 'WO003',
          detail = '{"code":"CLOSURE_EXCEPTION_NOT_APPROVED"}';
      end if;
      update public.work_orders set closure_exception_approved_by = p_actor_id, closure_exception_approved_at = p_now where id = p_wo_id;
    end if;
    v_def := app.wo_submit_deficiencies(p_wo_id, 'CLOSE', null);                  -- BR-042
    if jsonb_array_length(v_def) > 0 then
      raise exception 'WO003: validasi ulang penutupan gagal' using errcode = 'WO003', detail = v_def::text;
    end if;
    select exists (select 1 from public.wo_labor_lines l where l.wo_id = p_wo_id and l.deleted_at is null and l.billable)
        or exists (select 1 from public.wo_part_usages u where u.wo_id = p_wo_id and u.deleted_at is null and u.billable)
      into v_has_billable;
    update public.work_orders set closed_at = p_now, next_sla_check_at = null,
           billing_status = case when w.billing_type = 'BILLABLE' or v_has_billable then 'PENDING' else 'NOT_BILLABLE' end::public.billing_status
     where id = p_wo_id;
    if w.policy_snapshot ->> 'resolution_met_event' = 'CLOSE' or w.resolution_met_at is null then
      perform app.sla_mark_met(p_wo_id, 'RESOLUTION', p_now);
    end if;
    update public.wo_assignments set status = 'COMPLETED', ended_at = p_now where wo_id = p_wo_id and status in ('ASSIGNED','ACCEPTED');
    update public.pm_periods set status = case when status = 'GENERATED' then 'COMPLETED' else status end::public.pm_period_status,
           completed_at = p_now where wo_id = p_wo_id;
    -- laporan: snapshot terkunci, PDF dirender asinkron oleh aplikasi (NFR-P6)
    v_snap := app.build_report_snapshot(p_wo_id);
    select coalesce(max(revision), 0) + 1 into v_rev from public.service_reports where wo_id = p_wo_id;
    insert into public.service_reports (wo_id, customer_id, revision, status, snapshot, snapshot_hash, generated_by)
    values (p_wo_id, w.customer_id, v_rev, 'GENERATING', v_snap, encode(sha256(convert_to(v_snap::text, 'UTF8')), 'hex'), p_actor_id);
    perform app.refresh_parts_variances(p_wo_id, false);                          -- BR-032(a)
    perform app.notify_customer(w.customer_id, 'wo.closed', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
              'closed:' || p_wo_id::text);

  -- T-20 / T-21
  when 'RETURN' then
    update public.work_orders set returned_count = returned_count + 1 where id = p_wo_id returning returned_count into v_n;
    perform app.notify_wo_technicians(p_wo_id, 'wo.returned', jsonb_build_object('wo_number', w.wo_number, 'note', p_reason),
              'ret:' || p_wo_id::text || ':' || v_n::text);
    v_th := app.setting_int('return.escalation_threshold');
    if v_th is not null and v_n >= v_th then
      perform app.notify_role('OWNER', 'wo.return_escalation', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'returned_count', v_n),
                'retesc:' || p_wo_id::text || ':' || v_n::text);
    end if;
  when 'RESUME_AFTER_RETURN' then
    null;   -- tanda tangan lama di-SUPERSEDE saat pengajuan ulang jika hash berubah (BR-043)

  -- T-22 / T-23: pembatalan
  when 'CANCEL', 'CANCEL_BY_CUSTOMER', 'CANCEL_ACTIVE' then
    if p_action = 'CANCEL_ACTIVE' then
      update public.work_orders set outcome = coalesce(nullif(v_pl ->> 'outcome', '')::public.wo_outcome, 'PARTIAL') where id = p_wo_id;
    end if;
    perform app.wo_cancel_effects(p_wo_id, p_reason_code, p_reason, p_actor_id, p_now);
    perform app.notify_customer(w.customer_id, 'wo.cancelled', p_wo_id,
              jsonb_build_object('wo_number', w.wo_number, 'reason', p_reason), 'cancelled:' || p_wo_id::text);
    if p_action <> 'CANCEL' then
      perform app.notify_role('DISPATCHER', 'wo.cancelled', p_wo_id, jsonb_build_object('wo_number', w.wo_number), 'cancelled-d:' || p_wo_id::text);
    end if;

  -- T-27: kunjungan gagal
  when 'VISIT_FAILED' then
    if not exists (select 1 from public.wo_attachments where wo_id = p_wo_id and kind = 'FAILED_VISIT' and deleted_at is null) then
      raise exception 'WO003: foto bukti kunjungan gagal wajib' using errcode = 'WO003', detail = '{"code":"FAILED_VISIT_EVIDENCE_MISSING"}';
    end if;
    update public.wo_visits set check_out_at = p_now, auto_checked_out = true,
           result = coalesce(nullif(v_pl ->> 'result', '')::public.visit_result, 'FAILED_ABSENT')
     where wo_id = p_wo_id and check_out_at is null;
    update public.wo_assignments set status = 'RELEASED', ended_at = p_now, reason = p_reason, reason_code = p_reason_code
     where id = v_lead.id;
    update public.work_orders set failed_visit_count = failed_visit_count + 1 where id = p_wo_id;
    perform app.notify_role('DISPATCHER', 'wo.visit_failed', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'reason', p_reason),
              'vf:' || p_wo_id::text || ':' || w.version::text);
  else
    raise exception 'WO001: aksi % belum diimplementasikan', p_action using errcode = 'WO001';
  end case;

  if v_force then perform set_config('app.history_force', 'on', true); end if;
  update public.work_orders set status = v_to,
         next_sla_check_at = case when v_to in ('CLOSED','CANCELLED') then null else p_now end,
         customer_note = coalesce(nullif(v_pl ->> 'customer_note', ''), customer_note)
   where id = p_wo_id
   returning * into w;

  perform set_config('app.tx_active', v_prev, true);
  perform set_config('app.history_force', 'off', true);
  return jsonb_build_object('status', w.status, 'version', w.version, 'replayed', false, 'warnings', v_warn);
end $$;

-- RPC publik transisi status (satu-satunya pintu untuk klien). Pelanggan/staf/teknisi memakai JWT mereka.
create or replace function public.wo_transition(
  p_wo_id uuid, p_action text, p_expected_version int, p_op_id uuid default null,
  p_reason text default null, p_reason_code text default null, p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_roles public.app_role[];
begin
  if auth.uid() is null then
    if app.is_system() then
      return app.apply_wo_transition(p_wo_id, p_action, null, '{}'::public.app_role[], true,
                                     p_expected_version, p_op_id, p_reason, p_reason_code, p_payload);
    end if;
    raise exception 'WO002: tidak terautentikasi' using errcode = 'WO002';
  end if;
  v_roles := app.resolve_actor_roles(p_wo_id);
  -- 404 seragam: tidak membedakan "tidak ada" dari "bukan milik Anda" (NFR-S10)
  if cardinality(v_roles) = 0
     or not (app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE}')
             or app.customer_owns_wo(p_wo_id)
             or p_wo_id in (select app.my_active_wo_ids())) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  return app.apply_wo_transition(p_wo_id, p_action, auth.uid(), v_roles, false,
                                 p_expected_version, p_op_id, p_reason, p_reason_code, p_payload);
end $$;


-- ---- 0010c: permintaan servis -> WO (T-01, T-24, SP-02) -----------------------------------------
create or replace function app.request_decide_core(
  p_request_id uuid, p_decision text, p_actor uuid, p_source public.decision_source,
  p_priority_code text, p_service_type_id uuid, p_estimate_total numeric, p_reason text, p_expected_version int
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.service_requests; v_st uuid; v_prio text; v_wo uuid; v_wo_no text; v_clock timestamptz;
  v_prev text := coalesce(current_setting('app.tx_active', true), 'off');
begin
  select * into r from public.service_requests where id = p_request_id for update;
  if not found then raise exception 'WO005: permintaan tidak ditemukan' using errcode = 'WO005'; end if;
  if p_expected_version is not null and r.version <> p_expected_version then
    raise exception 'WO004: konflik versi permintaan' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', r.version, 'current_status', r.status)::text;
  end if;
  if r.status <> 'SUBMITTED' then
    raise exception 'WO001: permintaan berstatus % tidak dapat diputuskan', r.status using errcode = 'WO001';
  end if;
  perform set_config('app.tx_active', 'on', true);
  perform set_config('app.actor_role', case when p_source = 'SYSTEM_RULE' then 'SYSTEM_RULE' else 'ADMIN_CS' end, true);

  if p_decision = 'APPROVE' then
    if r.asset_id is null then
      raise exception 'WO003: aset wajib sebelum permintaan disetujui' using errcode = 'WO003', detail = '{"code":"ASSET_REQUIRED"}';
    end if;
    v_st := coalesce(p_service_type_id, (select pt.service_type_id from public.problem_types pt where pt.id = r.problem_type_id));
    if v_st is null then
      raise exception 'WO003: jenis layanan wajib' using errcode = 'WO003', detail = '{"code":"SERVICE_TYPE_REQUIRED"}';
    end if;
    v_prio := coalesce(p_priority_code, (select default_priority_code from public.service_types where id = v_st));
    if v_prio is null then
      raise exception 'WO003: prioritas wajib' using errcode = 'WO003', detail = '{"code":"PRIORITY_REQUIRED"}';
    end if;
    -- SP-01: titik mulai jam SLA dapat dikonfigurasi (default WO_CREATED mengikuti T-01)
    v_clock := case when coalesce(app.setting_text('sla.clock_starts_at'), 'WO_CREATED') = 'REQUEST_RECEIVED'
                    then r.created_at else now() end;
    v_wo := app.create_work_order('CORRECTIVE', r.customer_id, r.site_id, r.asset_id, v_st, r.id, null, null, null,
                                  v_prio, p_estimate_total, p_actor, r.created_at, null, v_clock);
    select wo_number into v_wo_no from public.work_orders where id = v_wo;
    update public.service_requests set status = 'CONVERTED', decision_by = p_actor, decision_source = p_source,
           decided_at = now(), decision_reason = p_reason where id = p_request_id;
    perform app.notify_customer(r.customer_id, 'request.accepted', v_wo,
              jsonb_build_object('request_no', r.request_no, 'wo_number', v_wo_no), 'req-acc:' || p_request_id::text);
    perform set_config('app.tx_active', v_prev, true);
    return jsonb_build_object('decision', 'APPROVE', 'wo_id', v_wo, 'wo_number', v_wo_no);
  elsif p_decision = 'NEEDS_INFO' then
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'WO003: catatan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
    end if;
    update public.service_requests set status = 'NEEDS_INFO', needs_info_note = p_reason, decision_by = p_actor,
           decision_source = p_source, decided_at = now() where id = p_request_id;
    perform app.notify_customer(r.customer_id, 'request.needs_info', null,
              jsonb_build_object('request_no', r.request_no, 'note', p_reason), 'req-info:' || p_request_id::text || ':' || r.version::text);
  elsif p_decision = 'REJECT' then
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'WO003: alasan penolakan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
    end if;
    update public.service_requests set status = 'REJECTED', decision_reason = p_reason, decision_by = p_actor,
           decision_source = p_source, decided_at = now() where id = p_request_id;
    perform app.notify_customer(r.customer_id, 'request.rejected', null,
              jsonb_build_object('request_no', r.request_no, 'reason', p_reason), 'req-rej:' || p_request_id::text);
  else
    raise exception 'WO006: decision harus APPROVE|NEEDS_INFO|REJECT' using errcode = 'WO006';
  end if;
  perform set_config('app.tx_active', v_prev, true);
  return jsonb_build_object('decision', p_decision);
end $$;

create or replace function public.request_decide(
  p_request_id uuid, p_decision text, p_priority_code text default null, p_service_type_id uuid default null,
  p_estimate_total numeric default null, p_reason text default null, p_expected_version int default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_any_role('{ADMIN_CS}') then
    raise exception 'WO002: hanya Admin/CS' using errcode = 'WO002';
  end if;
  return app.request_decide_core(p_request_id, p_decision, auth.uid(), 'USER', p_priority_code, p_service_type_id,
                                 p_estimate_total, p_reason, p_expected_version);
end $$;

-- Auto-approve (SP-02): hanya bila kontrak aktif mencakup aset+jenis layanan, tidak ada duplikat, prioritas default tersedia.
create or replace function app.try_auto_approve(p_request_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.service_requests; v_st uuid; v_bill jsonb;
begin
  select * into r from public.service_requests where id = p_request_id;
  if r.status <> 'SUBMITTED' or r.duplicate_of is not null or r.asset_id is null or r.problem_type_id is null then return; end if;
  select service_type_id into v_st from public.problem_types where id = r.problem_type_id;
  if v_st is null or (select default_priority_code from public.service_types where id = v_st) is null then return; end if;
  v_bill := app.determine_billing(r.customer_id, r.asset_id, v_st, r.created_at);
  if v_bill ->> 'billing_type' <> 'COVERED_CONTRACT' then return; end if;
  begin
    perform app.request_decide_core(p_request_id, 'APPROVE', null, 'SYSTEM_RULE', null, v_st, null, 'aturan auto-approve kontrak', null);
  exception when others then
    raise warning 'auto-approve gagal untuk %: %', p_request_id, sqlerrm;     -- permintaan tetap SUBMITTED untuk antrean admin
  end;
end $$;

-- ---- 0010d: biaya tambahan (BR-050..055) -----------------------------------------------------------------
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
  return v_res || jsonb_build_object('approval_id', v_id, 'approval_version', v_ver, 'content_hash', v_hash, 'total', v_total);
end $$;

create or replace function public.extra_cost_decide(
  p_approval_id uuid, p_decision text, p_content_hash text, p_continue_original_scope boolean default true,
  p_channel public.decision_channel default 'PWA', p_evidence_note text default null,
  p_op_id uuid default null, p_meta jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a public.extra_cost_approvals; w public.work_orders; v_roles public.app_role[]; v_behalf boolean; v_res jsonb; v_wo uuid;
begin
  select wo_id into v_wo from public.extra_cost_approvals where id = p_approval_id;
  select * into w from public.work_orders where id = v_wo for update;          -- kunci WO dulu, lalu persetujuan
  select * into a from public.extra_cost_approvals where id = p_approval_id for update;
  v_roles := case when w.id is null then '{}'::public.app_role[] else app.resolve_actor_roles(w.id) end;
  if a.id is null or ('CUSTOMER' <> all (v_roles) and 'ADMIN_CS' <> all (v_roles)) then
    raise exception 'WO005: persetujuan tidak ditemukan' using errcode = 'WO005';
  end if;
  v_behalf := 'CUSTOMER' <> all (v_roles);                                        -- ADM atas nama pelanggan
  if v_behalf and (coalesce(btrim(p_evidence_note), '') = '' or p_channel = 'PWA') then
    raise exception 'WO003: keputusan atas nama pelanggan butuh bukti dan kanal non-PWA' using errcode = 'WO003',
      detail = '{"code":"ON_BEHALF_EVIDENCE_REQUIRED"}';
  end if;
  if a.status <> 'PENDING' or w.status <> 'AWAITING_CUSTOMER_APPROVAL' then
    raise exception 'WO004: persetujuan sudah tidak berlaku (status %)', a.status using errcode = 'WO004',
      detail = jsonb_build_object('code', 'APPROVAL_STALE', 'approval_status', a.status)::text;
  end if;
  if a.content_hash <> coalesce(p_content_hash, '') then                          -- hanya sah untuk versi yang ditampilkan
    raise exception 'WO004: versi persetujuan berubah' using errcode = 'WO004', detail = '{"code":"APPROVAL_VERSION_STALE"}';
  end if;
  if a.expires_at is not null and a.expires_at < now() then
    raise exception 'WO004: persetujuan kedaluwarsa' using errcode = 'WO004', detail = '{"code":"APPROVAL_EXPIRED"}';
  end if;
  if p_decision not in ('APPROVE','REJECT') then
    raise exception 'WO006: decision harus APPROVE|REJECT' using errcode = 'WO006';
  end if;

  update public.extra_cost_approvals set
         status = case p_decision when 'APPROVE' then 'APPROVED' else 'REJECTED' end::public.approval_status,
         decided_by = auth.uid(), decided_at = now(), decision_channel = p_channel, on_behalf = v_behalf,
         evidence_note = p_evidence_note, continue_original_scope = case p_decision when 'REJECT' then p_continue_original_scope end,
         decision_meta = coalesce(p_meta, '{}'::jsonb) || jsonb_build_object('content_hash', a.content_hash, 'total', a.total)
   where id = p_approval_id;

  if p_decision = 'APPROVE' then
    v_res := app.apply_wo_transition(w.id, 'APPROVE_EXTRA_COST', auth.uid(), v_roles, false, w.version, p_op_id, null, null,
                                     jsonb_build_object('approval_id', a.id));
  elsif p_continue_original_scope then
    v_res := app.apply_wo_transition(w.id, 'REJECT_EXTRA_COST', auth.uid(), v_roles, false, w.version, p_op_id, null, null,
                                     jsonb_build_object('approval_id', a.id));
  else                                                                              -- T-14: tetap menunggu teknisi menutup tidak tuntas
    perform app.notify_wo_technicians(w.id, 'wo.approval_reject_close_needed',
              jsonb_build_object('wo_number', w.wo_number, 'approval_id', a.id), 'apprc:' || a.id::text);
    perform app.sla_resume(w.id, now());
    v_res := jsonb_build_object('status', w.status, 'version', w.version + 1);
  end if;
  return v_res;
end $$;

-- Tanda tangan pelanggan lewat PWA (jalur AWAITING_SIGNOFF, SP-07) -> T-18.
create or replace function public.wo_customer_sign(
  p_wo_id uuid, p_signer_name text, p_storage_path text, p_expected_version int,
  p_op_id uuid default null, p_device_meta jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not app.customer_owns_wo(p_wo_id) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  if (select status from public.work_orders where id = p_wo_id) <> 'AWAITING_SIGNOFF' then
    raise exception 'WO001: WO tidak sedang menunggu tanda tangan' using errcode = 'WO001';
  end if;
  insert into public.wo_signatures (wo_id, signer_type, signer_name, signer_user_id, storage_path, content_hash, signed_via, device_meta, op_id)
  values (p_wo_id, 'CUSTOMER', p_signer_name, auth.uid(), p_storage_path, '', 'CUSTOMER_PWA', p_device_meta, p_op_id);
  return app.apply_wo_transition(p_wo_id, 'SIGNOFF', auth.uid(), app.resolve_actor_roles(p_wo_id), false,
                                 p_expected_version, p_op_id, null, null, '{}'::jsonb);
end $$;

-- ---- 0010e: RPC kecil WO (T-25/T-26, prioritas, billing, helper, batal oleh pelanggan) ----------------------------------
create or replace function public.wo_request_help(p_wo_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not exists (select 1 from public.wo_assignments a where a.wo_id = p_wo_id and a.technician_id = app.my_technician_id()
                  and a.status in ('ASSIGNED','ACCEPTED')) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  update public.work_orders set help_requested_at = now(), help_requested_by = auth.uid(), help_note = p_note
   where id = p_wo_id and status not in ('CLOSED','CANCELLED') returning * into w;
  if w.id is null then raise exception 'WO001: WO sudah final' using errcode = 'WO001'; end if;
  perform app.notify_role('DISPATCHER', 'wo.help_requested', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'note', p_note),
            'help:' || p_wo_id::text || ':' || w.version::text);
end $$;

create or replace function public.wo_add_helper(p_wo_id uuid, p_technician_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_uid uuid; w public.work_orders;
begin
  if not app.has_any_role('{DISPATCHER}') then raise exception 'WO002: hanya Dispatcher' using errcode = 'WO002'; end if;
  select * into w from public.work_orders where id = p_wo_id;
  if w.id is null or w.status in ('CLOSED','CANCELLED','NEW') then
    raise exception 'WO001: helper hanya untuk WO yang sedang ditangani' using errcode = 'WO001';
  end if;
  select user_id into v_uid from public.technicians where id = p_technician_id and is_active;
  if v_uid is null then raise exception 'WO006: teknisi tidak valid' using errcode = 'WO006'; end if;
  insert into public.wo_assignments (wo_id, technician_id, role, status, assigned_by, responded_at)
  values (p_wo_id, p_technician_id, 'HELPER', 'ACCEPTED', auth.uid(), now()) returning id into v_id;
  perform app.enqueue_notification(v_uid, 'wo.helper_assigned', p_wo_id, jsonb_build_object('wo_number', w.wo_number),
            'helper:' || v_id::text);
  return v_id;
end $$;

-- Pelanggan mengajukan pembatalan (DEC-04): keputusan ada di ADM/DSP. Dari NEW pelanggan membatalkan langsung via wo_transition(CANCEL_BY_CUSTOMER).
create or replace function public.wo_request_cancel(p_wo_id uuid, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not app.customer_owns_wo(p_wo_id) then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  update public.work_orders set cancel_requested_at = now(), cancel_requested_by = auth.uid(), cancel_request_note = p_note
   where id = p_wo_id and status in ('ASSIGNED','ACCEPTED','EN_ROUTE') returning * into w;
  if w.id is null then raise exception 'WO001: pengajuan batal tidak tersedia pada status ini' using errcode = 'WO001'; end if;
  perform app.notify_role('ADMIN_CS', 'wo.cancel_requested', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'note', p_note), 'cxl:' || p_wo_id::text);
  perform app.notify_role('DISPATCHER', 'wo.cancel_requested', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'note', p_note), 'cxld:' || p_wo_id::text);
end $$;

create or replace function public.wo_change_priority(p_wo_id uuid, p_priority_code text, p_reason text, p_expected_version int)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'WO003: alasan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;
  select * into w from public.work_orders where id = p_wo_id for update;
  if w.id is null then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  if w.status in ('CLOSED','CANCELLED') then raise exception 'WO001: WO final' using errcode = 'WO001'; end if;
  if w.version <> p_expected_version then
    raise exception 'WO004: konflik versi' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;
  update public.work_orders set priority_code = p_priority_code where id = p_wo_id;   -- diaudit oleh trigger (nilai lama/baru)
  perform app.sla_recalculate(p_wo_id);                                             -- BR-015: dihitung dari sla_clock_start_at
  insert into public.wo_status_history (wo_id, from_status, to_status, action, actor_id, actor_roles, reason)
  values (p_wo_id, w.status, w.status, 'CHANGE_PRIORITY', auth.uid(), array_to_string(app.my_roles(), ','), p_reason);
  select * into w from public.work_orders where id = p_wo_id;
  return jsonb_build_object('status', w.status, 'version', w.version);
end $$;

create or replace function public.wo_override_billing(p_wo_id uuid, p_billing_type public.billing_type, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not app.has_any_role('{SUPERVISOR}') then raise exception 'WO002: hanya Supervisor' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'WO003: alasan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;
  select * into w from public.work_orders where id = p_wo_id for update;
  if w.id is null then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  if w.billing_status in ('INVOICED','PAID') then
    raise exception 'WO001: sudah ditagih; gunakan nota koreksi (di luar cakupan)' using errcode = 'WO001';   -- BR-062
  end if;
  update public.work_orders set billing_type = p_billing_type, billing_override_reason = p_reason where id = p_wo_id;
end $$;

create or replace function public.wo_create_rework(p_parent_wo_id uuid, p_reason text, p_priority_code text default null,
                                                   p_complaint_id uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare p public.work_orders; v_days int; v_id uuid;
begin
  if not app.has_any_role('{ADMIN_CS,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  select * into p from public.work_orders where id = p_parent_wo_id;
  if p.id is null then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  if p.status <> 'CLOSED' then raise exception 'WO001: WO induk harus CLOSED' using errcode = 'WO001'; end if;
  v_days := app.setting_int('rework.claim_window_days');
  if v_days is not null and p.closed_at < now() - make_interval(days => v_days) then
    raise exception 'WO001: di luar jendela klaim' using errcode = 'WO001';
  end if;
  -- T-25: WO induk TIDAK dibuka kembali; BR-066: garansi pekerjaan
  v_id := app.create_work_order('REWORK', p.customer_id, p.site_id, p.asset_id, p.service_type_id, null, null, null, p.id,
                                coalesce(p_priority_code, p.priority_code), null, auth.uid(), now(), 'WARRANTY_WORK');
  update public.work_orders set customer_note = p_reason where id = v_id;
  if p_complaint_id is not null then
    update public.complaints set rework_wo_id = v_id, status = 'IN_REVIEW', handled_by = auth.uid()
     where id = p_complaint_id and wo_id = p_parent_wo_id;
  end if;
  return v_id;
end $$;

create or replace function public.wo_cost_summary(p_wo_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare w public.work_orders; v_proj numeric; v_tol numeric := coalesce(app.setting_int('extra_cost.tolerance_amount'), 0);
begin
  if not (app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')
          or p_wo_id in (select app.my_active_wo_ids())) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  select * into w from public.work_orders where id = p_wo_id;
  select coalesce(sum(qty * coalesce(unit_price_snapshot, 0)), 0) into v_proj from (
    select qty, unit_price_snapshot from public.wo_labor_lines where wo_id = p_wo_id and deleted_at is null and billable
    union all
    select qty, unit_price_snapshot from public.wo_part_usages where wo_id = p_wo_id and deleted_at is null and billable) x;
  return jsonb_build_object('estimate_total', w.estimate_total, 'projected_total', v_proj, 'tolerance', v_tol,
           'needs_approval', w.estimate_total is not null and v_proj > w.estimate_total + v_tol);        -- BR-050
end $$;

-- ---- 0010f: pemeliharaan berkala (BR-020..028) ------------------------------------------------------------------------
create or replace function app.generate_preventive_work_orders(p_today date default null) returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record; v_today date; v_step int; v_horizon date; v_first date; v_due date; v_nmax int; v_n int;
  v_grace int; v_pid uuid; v_wo uuid; v_prio text; v_created int := 0;
begin
  for r in
    select ca.id, ca.asset_id, ca.service_type_id, ca.frequency, ca.anchor_date, ca.lead_days, ca.grace_days,
           ca.active_from, ca.active_to, ca.created_at, c.customer_id, c.start_date, c.end_date, a.site_id,
           st.default_priority_code,
           coalesce((select bc.timezone from public.business_calendars bc
                      where bc.id = coalesce(c.calendar_id, (select id from public.business_calendars where is_default limit 1))),
                    app.setting_text('default_timezone'), 'Asia/Jakarta') as tz
      from public.contract_assets ca
      join public.contracts c on c.id = ca.contract_id and c.status = 'ACTIVE'
      join public.assets a on a.id = ca.asset_id and a.is_active
      join public.service_types st on st.id = ca.service_type_id
     where ca.is_active
  loop
    v_today := coalesce(p_today, (now() at time zone r.tz)::date);                       -- BR-028
    v_step := case r.frequency when 'MONTHLY' then 1 when 'QUARTERLY' then 3 else 12 end;
    v_horizon := least(v_today + r.lead_days, r.end_date, coalesce(r.active_to, r.end_date));
    -- periode sebelum aset dimasukkan ke jadwal tidak dibuat mundur (hindari banjir MISSED historis)
    v_first := greatest(r.anchor_date, r.start_date, coalesce(r.active_from, r.start_date), (r.created_at at time zone r.tz)::date);
    continue when v_horizon < r.anchor_date;
    v_nmax := ((extract(year from age(v_horizon, r.anchor_date)) * 12 + extract(month from age(v_horizon, r.anchor_date)))::int / v_step) + 1;
    v_grace := coalesce(r.grace_days, app.setting_int('pm.grace_days'), 0);
    for v_n in 0 .. v_nmax loop
      v_due := (r.anchor_date + make_interval(months => v_n * v_step))::date;           -- selalu dari anchor (BR-021)
      continue when v_due > v_horizon or v_due < v_first;
      v_pid := null;
      insert into public.pm_periods (contract_asset_id, period_key, status) values (r.id, v_due, 'GENERATED')
      on conflict (contract_asset_id, period_key) do nothing returning id into v_pid;
      continue when v_pid is null;                                                       -- sudah diproses: idempoten
      if v_due + v_grace < v_today then                                                  -- BR-025: catch-up lampau => MISSED tanpa WO
        update public.pm_periods set status = 'MISSED', missed_at = now() where id = v_pid;
        continue;
      end if;
      v_prio := coalesce(r.default_priority_code, app.setting_text('pm.default_priority_code'),
                         (select code from public.priorities where is_active order by sort_rank limit 1));
      v_wo := app.create_work_order('PREVENTIVE', r.customer_id, r.site_id, r.asset_id, r.service_type_id, null, r.id, v_due,
                                    null, v_prio, null, null, now(), 'COVERED_CONTRACT');
      if v_wo is null then                                                               -- WO periode ini sudah ada (jaring pengaman unique)
        select id into v_wo from public.work_orders where contract_asset_id = r.id and pm_period_key = v_due and type = 'PREVENTIVE';
      else
        v_created := v_created + 1;
        perform app.notify_role('DISPATCHER', 'pm.generated', v_wo, jsonb_build_object('asset_id', r.asset_id, 'due_date', v_due),
                  'pmgen:' || v_wo::text);
      end if;
      update public.pm_periods set wo_id = v_wo where id = v_pid;
    end loop;
  end loop;
  return v_created;
end $$;

-- Tandai periode PM terlewat + eskalasi idempoten (BR-024)
create or replace function app.mark_missed_pm_periods(p_today date default null) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_today date; v_n int := 0; v_set uuid; v_ins int; k record; v_grace int;
begin
  for r in
    select p.id, p.status, p.period_key, p.wo_id, p.contract_asset_id, ca.grace_days, c.sla_policy_set_id,
           coalesce((select bc.timezone from public.business_calendars bc where bc.id = c.calendar_id),
                    app.setting_text('default_timezone'), 'Asia/Jakarta') as tz
      from public.pm_periods p
      join public.contract_assets ca on ca.id = p.contract_asset_id
      join public.contracts c on c.id = ca.contract_id
      left join public.work_orders w on w.id = p.wo_id
     where (p.status = 'GENERATED' and (w.id is null or w.status <> 'CLOSED'))
        or (p.status = 'MISSED' and not exists (select 1 from public.sla_events e where e.pm_period_id = p.id and e.kind = 'PM_MISSED'))
  loop
    v_today := coalesce(p_today, (now() at time zone r.tz)::date);
    v_grace := coalesce(r.grace_days, app.setting_int('pm.grace_days'), 0);
    continue when r.status = 'GENERATED' and r.period_key + v_grace >= v_today;
    if r.status = 'GENERATED' then
      update public.pm_periods set status = 'MISSED', missed_at = now() where id = r.id;
    end if;
    v_set := coalesce(r.sla_policy_set_id, (select id from public.sla_policy_sets where is_default and is_active limit 1));
    -- minimal satu baris event agar idempoten walau aturan eskalasi belum dikonfigurasi
    insert into public.sla_events (wo_id, pm_period_id, kind, level, target) values (r.wo_id, r.id, 'PM_MISSED', 1, '*') on conflict do nothing;
    get diagnostics v_ins = row_count;
    if v_ins > 0 then
      v_n := v_n + 1;
      for k in select * from public.escalation_rules er
                where er.policy_set_id = v_set and er.trigger_kind = 'PM_MISSED' and er.is_active order by er.level loop
        insert into public.sla_events (wo_id, pm_period_id, kind, level, target) values (r.wo_id, r.id, 'PM_MISSED', k.level, k.notify_role::text) on conflict do nothing;
        perform app.notify_role(k.notify_role, 'sla.pm_missed', r.wo_id,
                  jsonb_build_object('pm_period_id', r.id, 'due_date', r.period_key, 'level', k.level),
                  'pmmiss:' || r.id::text || ':' || k.level::text);
      end loop;
    end if;
  end loop;
  return v_n;
end $$;

-- ADM memutuskan periode MISSED: buat WO sekarang atau lewati dengan alasan (BR-024/025)
create or replace function public.pm_period_resolve(p_period_id uuid, p_action text, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare p public.pm_periods; ca public.contract_assets; c public.contracts; a public.assets; v_wo uuid; v_prio text;
begin
  if not app.has_any_role('{ADMIN_CS}') then raise exception 'WO002: hanya Admin/CS' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'WO003: alasan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;
  select * into p from public.pm_periods where id = p_period_id for update;
  if p.id is null or p.status <> 'MISSED' then raise exception 'WO001: periode bukan MISSED' using errcode = 'WO001'; end if;
  if p_action = 'SKIP' then
    update public.pm_periods set status = 'SKIPPED', skip_reason = p_reason where id = p_period_id;
    return null;
  elsif p_action = 'CREATE_NOW' then
    select * into ca from public.contract_assets where id = p.contract_asset_id;
    select * into c from public.contracts where id = ca.contract_id;
    select * into a from public.assets where id = ca.asset_id;
    if p.wo_id is not null and (select status from public.work_orders where id = p.wo_id) <> 'CANCELLED' then
      raise exception 'WO001: WO periode ini masih aktif' using errcode = 'WO001';
    end if;
    -- WO lama (dibatalkan) menempati unique periode; WO pengganti memakai periode kunci geser ditandai pada pm_period_key = hari ini
    v_prio := coalesce((select default_priority_code from public.service_types where id = ca.service_type_id),
                       app.setting_text('pm.default_priority_code'),
                       (select code from public.priorities where is_active order by sort_rank limit 1));
    v_wo := app.create_work_order('PREVENTIVE', c.customer_id, a.site_id, a.id, ca.service_type_id, null, ca.id,
                                  case when p.wo_id is null then p.period_key else current_date end, null, v_prio, null, auth.uid(),
                                  now(), 'COVERED_CONTRACT');
    if v_wo is null then raise exception 'WO001: WO periode sudah ada' using errcode = 'WO001'; end if;
    update public.pm_periods set wo_id = v_wo, status = 'GENERATED', skip_reason = p_reason where id = p_period_id;
    return v_wo;
  end if;
  raise exception 'WO006: action harus SKIP|CREATE_NOW' using errcode = 'WO006';
end $$;


-- ---- 0010g: suku cadang: permintaan, serah-terima, retur, selisih (BR-030..038) ------------------------------
create or replace function public.part_request_create(p_wo_id uuid, p_lines jsonb, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; w public.work_orders;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if w.id is null
     or not (app.has_any_role('{DISPATCHER}') or exists (select 1 from public.wo_assignments a
               where a.wo_id = p_wo_id and a.technician_id = app.my_technician_id() and a.status in ('ASSIGNED','ACCEPTED'))) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  if w.status in ('CLOSED','CANCELLED') then raise exception 'WO001: WO final' using errcode = 'WO001'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'WO006: minimal satu baris' using errcode = 'WO006';
  end if;
  insert into public.part_requests (request_no, wo_id, requested_by, note)
  values (app.next_doc_number('PR'), p_wo_id, auth.uid(), p_note) returning id into v_id;
  insert into public.part_request_lines (request_id, item_id, qty_requested)
  select v_id, x.item_id, x.qty from jsonb_to_recordset(p_lines) as x(item_id uuid, qty numeric);
  perform app.notify_role('WAREHOUSE', 'parts.requested', p_wo_id, jsonb_build_object('wo_number', w.wo_number, 'request_id', v_id), 'pr:' || v_id::text);
  return v_id;
end $$;

create or replace function public.part_request_decide(p_request_id uuid, p_decision text, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_any_role('{WAREHOUSE}') then raise exception 'WO002: hanya Gudang' using errcode = 'WO002'; end if;
  update public.part_requests set status = case p_decision when 'APPROVE' then 'APPROVED' when 'REJECT' then 'REJECTED' end::public.part_request_status,
         decided_by = auth.uid(), decided_at = now(), note = coalesce(p_note, note)
   where id = p_request_id and status = 'REQUESTED';
  if not found then raise exception 'WO001: permintaan tidak dapat diputuskan' using errcode = 'WO001'; end if;
end $$;

-- Serah-terima Gudang -> teknisi: stok gudang berkurang, stok teknisi bertambah; ditolak bila stok kurang (STK01).
create or replace function public.part_issue(p_line_id uuid, p_qty numeric, p_from_location_id uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare l public.part_request_lines; pr public.part_requests; v_tech uuid; v_to uuid; v_from uuid; v_mid uuid; v_open int;
begin
  if not app.has_any_role('{WAREHOUSE}') then raise exception 'WO002: hanya Gudang' using errcode = 'WO002'; end if;
  select * into l from public.part_request_lines where id = p_line_id for update;
  select * into pr from public.part_requests where id = l.request_id for update;
  if l.id is null or pr.status not in ('REQUESTED','APPROVED','PARTIALLY_ISSUED') then
    raise exception 'WO001: baris tidak dapat diserahkan' using errcode = 'WO001';
  end if;
  if p_qty is null or p_qty <= 0 or l.qty_issued + p_qty > l.qty_requested then
    raise exception 'WO006: jumlah melebihi sisa permintaan' using errcode = 'WO006';
  end if;
  select a.technician_id into v_tech from public.wo_assignments a
   where a.wo_id = pr.wo_id and a.role = 'LEAD' and a.status in ('ASSIGNED','ACCEPTED') limit 1;
  select id into v_to from public.stock_locations where technician_id = v_tech and type = 'TECHNICIAN' and is_active;
  v_from := coalesce(p_from_location_id, (select id from public.stock_locations where is_default_warehouse and is_active));
  if v_to is null or v_from is null then
    raise exception 'WO006: lokasi stok asal/tujuan tidak ditemukan' using errcode = 'WO006';
  end if;
  insert into public.stock_movements (item_id, from_location_id, to_location_id, qty, type, wo_id, ref_type, ref_id, actor_id)
  values (l.item_id, v_from, v_to, p_qty, 'ISSUE_TO_TECH', pr.wo_id, 'PART_REQUEST_LINE', l.id, auth.uid())
  returning id into v_mid;
  update public.part_request_lines set qty_issued = qty_issued + p_qty where id = l.id;
  select count(*) into v_open from public.part_request_lines where request_id = pr.id and qty_issued < qty_requested;
  update public.part_requests set status = case when v_open = 0 then 'ISSUED' else 'PARTIALLY_ISSUED' end::public.part_request_status,
         decided_by = coalesce(decided_by, auth.uid()), decided_at = coalesce(decided_at, now())
   where id = pr.id;
  perform app.notify_wo_technicians(pr.wo_id, 'parts.issued', jsonb_build_object('request_id', pr.id, 'line_id', l.id, 'qty', p_qty),
            'issue:' || v_mid::text);
  return v_mid;
end $$;

-- Teknisi mengajukan retur (PENDING); Gudang yang mengonfirmasi mutasi (BR-034).
create or replace function public.part_return_create(p_wo_id uuid, p_lines jsonb, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_tech uuid := app.my_technician_id(); v_id uuid;
begin
  if v_tech is null or not exists (select 1 from public.wo_assignments a where a.wo_id = p_wo_id and a.technician_id = v_tech) then
    raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005';
  end if;
  insert into public.part_returns (wo_id, technician_id, note) values (p_wo_id, v_tech, p_note) returning id into v_id;
  insert into public.part_return_lines (return_id, item_id, qty)
  select v_id, x.item_id, x.qty from jsonb_to_recordset(p_lines) as x(item_id uuid, qty numeric);
  perform app.notify_role('WAREHOUSE', 'parts.return_pending', p_wo_id, jsonb_build_object('return_id', v_id), 'ret:' || v_id::text);
  return v_id;
end $$;

create or replace function public.part_return_confirm(p_return_id uuid, p_lines jsonb default null,
                                                      p_to_location_id uuid default null, p_reject boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.part_returns; l record; v_from uuid; v_to uuid; v_qty numeric; v_final boolean;
begin
  if not app.has_any_role('{WAREHOUSE}') then raise exception 'WO002: hanya Gudang' using errcode = 'WO002'; end if;
  select * into r from public.part_returns where id = p_return_id for update;
  if r.id is null or r.status <> 'PENDING' then raise exception 'WO001: retur tidak dapat dikonfirmasi' using errcode = 'WO001'; end if;
  if p_reject then
    update public.part_returns set status = 'REJECTED', confirmed_by = auth.uid(), confirmed_at = now() where id = r.id;
    return;
  end if;
  select id into v_from from public.stock_locations where technician_id = r.technician_id and type = 'TECHNICIAN' and is_active;
  v_to := coalesce(p_to_location_id, (select id from public.stock_locations where is_default_warehouse and is_active));
  if v_from is null or v_to is null then raise exception 'WO006: lokasi stok tidak ditemukan' using errcode = 'WO006'; end if;
  for l in select rl.* from public.part_return_lines rl where rl.return_id = r.id loop
    v_qty := coalesce((select (x.confirmed_qty) from jsonb_to_recordset(p_lines) as x(item_id uuid, confirmed_qty numeric)
                        where x.item_id = l.item_id), l.qty);
    update public.part_return_lines set confirmed_qty = v_qty where id = l.id;
    if v_qty > 0 then
      insert into public.stock_movements (item_id, from_location_id, to_location_id, qty, type, wo_id, ref_type, ref_id, actor_id)
      values (l.item_id, v_from, v_to, v_qty, 'RETURN_FROM_TECH', r.wo_id, 'PART_RETURN', r.id, auth.uid());
    end if;
  end loop;
  update public.part_returns set status = 'CONFIRMED', confirmed_by = auth.uid(), confirmed_at = now() where id = r.id;
  select status in ('CLOSED','CANCELLED') into v_final from public.work_orders where id = r.wo_id;
  perform app.refresh_parts_variances(r.wo_id, false);           -- retur terlambat dapat menutup selisih OPEN otomatis
  if v_final then perform app.refresh_parts_variances(r.wo_id, true); end if;
end $$;

create or replace function public.stock_receive(p_item_id uuid, p_location_id uuid, p_qty numeric, p_note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not app.has_any_role('{WAREHOUSE}') then raise exception 'WO002: hanya Gudang' using errcode = 'WO002'; end if;
  insert into public.stock_movements (item_id, to_location_id, qty, type, actor_id, note)
  values (p_item_id, p_location_id, p_qty, 'RECEIPT', auth.uid(), p_note) returning id into v_id;
  return v_id;
end $$;

-- Penyesuaian / opname (FR-127). delta > 0 menambah, < 0 mengurangi. Di atas ambang butuh Supervisor.
create or replace function public.stock_adjust(p_item_id uuid, p_location_id uuid, p_delta numeric, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_th int := app.setting_int('stock.adjustment_supervisor_threshold');
begin
  if not app.has_any_role('{WAREHOUSE,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_reason), '') = '' or p_delta is null or p_delta = 0 then
    raise exception 'WO006: alasan dan delta (non-nol) wajib' using errcode = 'WO006';
  end if;
  if v_th is not null and abs(p_delta) > v_th and not app.has_any_role('{SUPERVISOR}') then
    raise exception 'WO002: penyesuaian di atas ambang butuh Supervisor' using errcode = 'WO002';
  end if;
  insert into public.stock_movements (item_id, from_location_id, to_location_id, qty, type, actor_id, note)
  values (p_item_id, case when p_delta < 0 then p_location_id end, case when p_delta > 0 then p_location_id end,
          abs(p_delta), 'ADJUSTMENT', auth.uid(), p_reason) returning id into v_id;
  return v_id;
end $$;

-- Hitung selisih per (WO, item, teknisi): issued - used - returned (BR-031). Barang BULK tidak dilacak per WO.
create or replace function app.refresh_parts_variances(p_wo_id uuid, p_final boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.parts_variances as pv (wo_id, item_id, technician_id, issued, used, returned, is_final, status)
  select p_wo_id, k.item_id, k.technician_id, k.issued, k.used, k.returned, p_final,
         case when p_final and abs(k.issued - k.used - k.returned) > coalesce(i.variance_tolerance, 0) then 'OPEN'::public.variance_status end
    from (
      select coalesce(a.item_id, b.item_id, c.item_id) as item_id, coalesce(a.technician_id, b.technician_id, c.technician_id) as technician_id,
             coalesce(a.qty, 0) as issued, coalesce(b.qty, 0) as used, coalesce(c.qty, 0) as returned
        from (select m.item_id, sl.technician_id, sum(m.qty) as qty from public.stock_movements m
                join public.stock_locations sl on sl.id = m.to_location_id
               where m.wo_id = p_wo_id and m.type = 'ISSUE_TO_TECH' group by 1, 2) a
        full join (select u.item_id, u.technician_id, sum(u.qty) as qty from public.wo_part_usages u
                    join public.items it on it.id = u.item_id and it.tracking_mode = 'PER_WO'
                   where u.wo_id = p_wo_id and u.deleted_at is null group by 1, 2) b
               on b.item_id = a.item_id and b.technician_id = a.technician_id
        full join (select m.item_id, sl.technician_id, sum(m.qty) as qty from public.stock_movements m
                    join public.stock_locations sl on sl.id = m.from_location_id
                   where m.wo_id = p_wo_id and m.type = 'RETURN_FROM_TECH' group by 1, 2) c
               on c.item_id = coalesce(a.item_id, b.item_id) and c.technician_id = coalesce(a.technician_id, b.technician_id)
    ) k
    join public.items i on i.id = k.item_id
  on conflict (wo_id, item_id, technician_id) do update set
     issued = excluded.issued, used = excluded.used, returned = excluded.returned,
     is_final = pv.is_final or excluded.is_final,
     status = case
       when pv.status in ('EXPLAINED','RETURNED_LATE','WRITTEN_OFF','CHARGED_TO_CUSTOMER') then pv.status
       when excluded.is_final and abs(excluded.issued - excluded.used - excluded.returned)
            > coalesce((select variance_tolerance from public.items where id = excluded.item_id), 0) then 'OPEN'::public.variance_status
       when pv.status = 'OPEN' and excluded.issued - excluded.used - excluded.returned = 0 then 'RETURNED_LATE'::public.variance_status
       else pv.status end;
end $$;

-- Finalisasi setelah batas waktu retur (BR-032b). Batas NULL = final saat WO selesai/batal.
create or replace function app.finalize_parts_variances(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0; v_h int := coalesce(app.setting_int('parts.return_deadline_hours'), 0); v_open_before int; v_open_after int;
begin
  for r in
    select distinct w.id from public.parts_variances pv join public.work_orders w on w.id = pv.wo_id
     where not pv.is_final and w.status in ('CLOSED','CANCELLED')
       and coalesce(w.closed_at, w.cancelled_at) + make_interval(hours => v_h) <= p_now
  loop
    select count(*) into v_open_before from public.parts_variances where wo_id = r.id and status = 'OPEN';
    perform app.refresh_parts_variances(r.id, true);
    select count(*) into v_open_after from public.parts_variances where wo_id = r.id and status = 'OPEN';
    if v_open_after > v_open_before then
      perform app.notify_role('WAREHOUSE', 'parts.variance_open', r.id, jsonb_build_object('wo_id', r.id), 'pv-w:' || r.id::text);
      perform app.notify_role('SUPERVISOR', 'parts.variance_open', r.id, jsonb_build_object('wo_id', r.id), 'pv-s:' || r.id::text);
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.parts_variance_resolve(p_variance_id uuid, p_status public.variance_status, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.parts_variances; v_loc uuid;
begin
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'WO003: catatan wajib' using errcode = 'WO003', detail = '{"code":"REASON_REQUIRED"}';
  end if;
  if p_status in ('WRITTEN_OFF','CHARGED_TO_CUSTOMER') then
    if not app.has_any_role('{SUPERVISOR}') then raise exception 'WO002: butuh Supervisor' using errcode = 'WO002'; end if;
  elsif p_status in ('EXPLAINED','RETURNED_LATE') then
    if not app.has_any_role('{WAREHOUSE,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  else
    raise exception 'WO006: status tujuan tidak valid' using errcode = 'WO006';
  end if;
  select * into v from public.parts_variances where id = p_variance_id for update;
  if v.id is null or v.status is distinct from 'OPEN' then
    raise exception 'WO001: selisih tidak berstatus OPEN' using errcode = 'WO001';
  end if;
  if p_status = 'WRITTEN_OFF' and v.variance > 0 then            -- BR-033: koreksi lewat mutasi, bukan edit mutasi lama
    select id into v_loc from public.stock_locations where technician_id = v.technician_id and type = 'TECHNICIAN';
    insert into public.stock_movements (item_id, from_location_id, qty, type, wo_id, ref_type, ref_id, actor_id, note)
    values (v.item_id, v_loc, v.variance, 'ADJUSTMENT', v.wo_id, 'VARIANCE_WRITE_OFF', v.id, auth.uid(), p_note);
  end if;
  -- TODO: CHARGED_TO_CUSTOMER wajib melewati persetujuan biaya (BR-033/BR-050) - belum otomatis.
  update public.parts_variances set status = p_status, resolution_note = p_note, resolved_by = auth.uid(), resolved_at = now()
   where id = p_variance_id;
end $$;

-- ---- 0010h: job SLA, kedaluwarsa, retensi, heartbeat -----------------------------------------------------------------
create or replace function app.sla_fire_rules(p_wo_id uuid, p_wo_number text, p_set uuid, p_kind public.sla_event_kind,
                                              p_base timestamptz, p_now timestamptz, p_due timestamptz) returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare k record; v_fire timestamptz; v_next timestamptz; v_ins int;
begin
  for k in select * from public.escalation_rules er
            where er.policy_set_id = p_set and er.trigger_kind = p_kind and er.is_active order by er.level loop
    v_fire := p_base + make_interval(mins => k.after_minutes);
    if p_now >= v_fire then
      insert into public.sla_events (wo_id, kind, level, target) values (p_wo_id, p_kind, k.level, k.notify_role::text)
      on conflict do nothing;
      get diagnostics v_ins = row_count;
      if v_ins > 0 then                                              -- notifikasi hanya bila baris benar-benar baru (BR-014)
        perform app.notify_role(k.notify_role, 'sla.' || lower(p_kind::text), p_wo_id,
                  jsonb_build_object('wo_number', p_wo_number, 'level', k.level, 'due_at', p_due),
                  'sla:' || p_wo_id::text || ':' || p_kind::text || ':' || k.level::text || ':' || k.notify_role::text);
      end if;
    else
      v_next := least(v_next, v_fire);
    end if;
  end loop;
  return v_next;
end $$;

create or replace function app.run_sla_checks(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = '' as $$
declare
  w record; pol jsonb; v_warn numeric; v_total numeric; v_rem numeric; v_next timestamptz;
  v_rs public.sla_state; v_os public.sla_state; v_n int := 0; v_wthr numeric;
begin
  for w in select * from public.work_orders
            where status not in ('CLOSED','CANCELLED') and next_sla_check_at is not null and next_sla_check_at <= p_now
            order by next_sla_check_at for update skip locked
  loop
    v_next := null; v_rs := w.response_sla_state; v_os := w.resolution_sla_state; pol := w.policy_snapshot;
    if pol is null or w.sla_policy_set_id is null then
      update public.work_orders set next_sla_check_at = null where id = w.id;
      continue;
    end if;

    -- respons (BR-013)
    if w.response_met_at is null and w.response_due_at is not null then
      v_total := (pol ->> 'response_minutes')::numeric;
      v_warn := (pol ->> 'warning_pct')::numeric;
      v_wthr := case when v_warn is null or v_total is null then null else v_total * v_warn / 100 end;
      v_rem := app.sla_business_minutes_between(p_now, w.response_due_at, w.sla_calendar_id);
      v_rs := case when p_now > w.response_due_at then 'BREACHED'
                   when v_wthr is not null and v_rem <= v_wthr then 'WARNING' else 'RUNNING' end;
      if v_rs in ('WARNING','BREACHED') then
        v_next := least(v_next, app.sla_fire_rules(w.id, w.wo_number, w.sla_policy_set_id, 'RESPONSE_WARNING',
                   coalesce((select min(e.at) from public.sla_events e where e.wo_id = w.id and e.kind = 'RESPONSE_WARNING'), p_now),
                   p_now, w.response_due_at));
      end if;
      if v_rs = 'BREACHED' then
        v_next := least(v_next, app.sla_fire_rules(w.id, w.wo_number, w.sla_policy_set_id, 'RESPONSE_BREACH',
                   w.response_due_at, p_now, w.response_due_at));
      else
        v_next := least(v_next, w.response_due_at);
        if v_rs = 'RUNNING' and v_wthr is not null then
          v_next := least(v_next, app.sla_add_business_minutes(p_now, greatest(v_rem - v_wthr, 0), w.sla_calendar_id));
        end if;
      end if;
    end if;

    -- penyelesaian (BR-012: dijeda => tidak dievaluasi)
    if w.resolution_met_at is null and w.resolution_due_at is not null then
      if w.sla_paused_at is not null then
        v_os := 'PAUSED';
      else
        v_total := (pol ->> 'resolution_minutes')::numeric;
        v_warn := (pol ->> 'warning_pct')::numeric;
        v_wthr := case when w.type = 'PREVENTIVE' or v_warn is null or v_total is null then null else v_total * v_warn / 100 end;
        v_rem := app.sla_business_minutes_between(p_now, w.resolution_due_at, w.sla_calendar_id);
        v_os := case when p_now > w.resolution_due_at then 'BREACHED'
                     when v_wthr is not null and v_rem <= v_wthr then 'WARNING' else 'RUNNING' end;
        if v_os in ('WARNING','BREACHED') then
          v_next := least(v_next, app.sla_fire_rules(w.id, w.wo_number, w.sla_policy_set_id, 'RESOLUTION_WARNING',
                     coalesce((select min(e.at) from public.sla_events e where e.wo_id = w.id and e.kind = 'RESOLUTION_WARNING'), p_now),
                     p_now, w.resolution_due_at));
        end if;
        if v_os = 'BREACHED' then
          v_next := least(v_next, app.sla_fire_rules(w.id, w.wo_number, w.sla_policy_set_id, 'RESOLUTION_BREACH',
                     w.resolution_due_at, p_now, w.resolution_due_at));
        else
          v_next := least(v_next, w.resolution_due_at);
          if v_os = 'RUNNING' and v_wthr is not null then
            v_next := least(v_next, app.sla_add_business_minutes(p_now, greatest(v_rem - v_wthr, 0), w.sla_calendar_id));
          end if;
        end if;
      end if;
    end if;

    update public.work_orders set response_sla_state = v_rs, resolution_sla_state = v_os, next_sla_check_at = v_next
     where id = w.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- T-15 dan T-18 versi SYS: kedaluwarsa persetujuan biaya & tanda tangan
create or replace function app.expire_pending_customer_actions(p_now timestamptz default now()) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select a.id as approval_id, a.wo_id from public.extra_cost_approvals a
             join public.work_orders w on w.id = a.wo_id
            where a.status = 'PENDING' and a.expires_at is not null and a.expires_at <= p_now
              and w.status = 'AWAITING_CUSTOMER_APPROVAL'
            for update of a skip locked
  loop
    update public.extra_cost_approvals set status = 'EXPIRED', decided_at = p_now, continue_original_scope = true
     where id = r.approval_id;
    perform app.apply_wo_transition(r.wo_id, 'EXPIRE_EXTRA_COST', null, '{}'::public.app_role[], true, null, null,
              'persetujuan kedaluwarsa', 'EXPIRED', jsonb_build_object('approval_id', r.approval_id), p_now);
    v_n := v_n + 1;
  end loop;
  for r in select w.id from public.work_orders w
            where w.status = 'AWAITING_SIGNOFF' and w.signoff_expires_at is not null and w.signoff_expires_at <= p_now
            for update skip locked
  loop
    perform app.apply_wo_transition(r.id, 'EXPIRE_SIGNOFF', null, '{}'::public.app_role[], true, null, null,
              'tanda tangan kedaluwarsa', 'NO_RESPONSE', '{}'::jsonb, p_now);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Retensi teknis (NFR-S6). Nilai [P] dari app_settings; NULL = tidak dihapus.
-- audit_logs/access_logs append-only: retensi lewat partisi/arsip (TODO), bukan DELETE.
create or replace function app.purge_expired_data() returns int
language plpgsql security definer set search_path = '' as $$
declare v_n int := 0; v_d int; v_c int;
begin
  delete from public.rate_limits where window_start < now() - interval '2 days';          -- data teknis, bukan retensi bisnis
  get diagnostics v_c = row_count; v_n := v_n + v_c;
  v_d := app.setting_int('retention.notifications_days');
  if v_d is not null then
    delete from public.notifications where status in ('SENT','READ') and created_at < now() - make_interval(days => v_d);
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  v_d := app.setting_int('retention.sync_operations_days');
  if v_d is not null then
    delete from public.sync_operations where status = 'APPLIED' and received_at < now() - make_interval(days => v_d);
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  v_d := app.setting_int('retention.job_runs_days');
  if v_d is not null then
    delete from public.job_runs where started_at < now() - make_interval(days => v_d);
    get diagnostics v_c = row_count; v_n := v_n + v_c;
  end if;
  -- TODO (NFR-D5): anonimisasi data pribadi pelanggan setelah masa retensi [P] (customers.anonymized_at).
  return v_n;
end $$;

-- Pembungkus job dengan heartbeat (RK-15). Dipanggil pg_cron.
create or replace function app.run_job(p_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_n int;
begin
  insert into public.job_runs (job_name) values (p_name) returning id into v_id;
  begin
    v_n := case p_name
      when 'sla_check' then app.run_sla_checks()
      when 'pm_generate' then app.generate_preventive_work_orders()
      when 'pm_missed' then app.mark_missed_pm_periods()
      when 'expire_customer_actions' then app.expire_pending_customer_actions()
      when 'parts_variance_finalize' then app.finalize_parts_variances()
      when 'retention_purge' then app.purge_expired_data()
      else null end;
    if v_n is null and p_name not in ('sla_check','pm_generate','pm_missed','expire_customer_actions','parts_variance_finalize','retention_purge') then
      raise exception 'job tidak dikenal: %', p_name;
    end if;
    update public.job_runs set status = 'OK', finished_at = now(), rows_affected = v_n where id = v_id;
  exception when others then
    update public.job_runs set status = 'ERROR', finished_at = now(), error = sqlerrm where id = v_id;
  end;
end $$;

-- ---- 0010i: akses data (log), registrasi pelanggan ------------------------------------------------------------------------
create or replace function public.log_data_access(p_customer_id uuid, p_resource_type text, p_resource_id text,
                                                  p_action text default 'READ') returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_any_role('{ADMIN_CS,DISPATCHER,TECHNICIAN,SUPERVISOR,WAREHOUSE,FINANCE,OWNER}') then
    raise exception 'WO002: hanya staf' using errcode = 'WO002';
  end if;
  insert into public.access_logs (actor_id, customer_id, resource_type, resource_id, action)
  values (auth.uid(), p_customer_id, p_resource_type, p_resource_id, p_action);
end $$;

-- Registrasi mandiri pelanggan perorangan (D1/Q1). Diaktifkan bila app_settings registration.mode IN ('SELF','BOTH').
create or replace function public.register_individual_customer(p_full_name text, p_phone text, p_policy_version text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_mode text := app.setting_text('registration.mode'); v_cid uuid; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'WO002: tidak terautentikasi' using errcode = 'WO002'; end if;
  if v_mode is null or v_mode not in ('SELF','BOTH') then
    raise exception 'WO002: registrasi mandiri tidak diaktifkan' using errcode = 'WO002';
  end if;
  if coalesce(btrim(p_policy_version), '') = '' then
    raise exception 'WO006: persetujuan kebijakan privasi wajib (NFR-D2)' using errcode = 'WO006';
  end if;
  if exists (select 1 from public.user_roles where user_id = v_uid) then
    raise exception 'WO001: akun sudah memiliki peran' using errcode = 'WO001';
  end if;
  update public.profiles set full_name = coalesce(nullif(btrim(p_full_name), ''), full_name), phone = p_phone where user_id = v_uid;
  insert into public.customers (code, name, type, contact_name, contact_phone, contact_email)
  values (app.next_doc_number('CUS'), coalesce(nullif(btrim(p_full_name), ''), 'Pelanggan'), 'INDIVIDUAL', p_full_name, p_phone,
          auth.jwt() ->> 'email') returning id into v_cid;
  insert into public.customer_users (customer_id, user_id, customer_role) values (v_cid, v_uid, 'ADMIN');
  insert into public.user_roles (user_id, role) values (v_uid, 'CUSTOMER');
  insert into public.user_consents (user_id, policy_version) values (v_uid, p_policy_version);
  return v_cid;
end $$;

-- Terima undangan admin (token sekali pakai; hanya hash disimpan). Email undangan harus sama dengan email akun.
create or replace function public.accept_customer_invitation(p_token text, p_policy_version text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare i public.customer_invitations; v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'WO002: tidak terautentikasi' using errcode = 'WO002'; end if;
  if coalesce(btrim(p_policy_version), '') = '' then
    raise exception 'WO006: persetujuan kebijakan privasi wajib (NFR-D2)' using errcode = 'WO006';
  end if;
  select * into i from public.customer_invitations
   where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') for update;
  if i.id is null or i.accepted_at is not null or i.expires_at < now()
     or lower(i.email) <> lower(coalesce(auth.jwt() ->> 'email', '')) then
    raise exception 'WO005: undangan tidak valid' using errcode = 'WO005';       -- pesan seragam
  end if;
  if exists (select 1 from public.user_roles where user_id = v_uid and role <> 'CUSTOMER') then
    raise exception 'WO001: akun staf tidak dapat menerima undangan pelanggan' using errcode = 'WO001';
  end if;
  insert into public.customer_users (customer_id, user_id, customer_role, invited_by)
  values (i.customer_id, v_uid, i.customer_role, i.created_by) on conflict (customer_id, user_id) do update set is_active = true;
  insert into public.user_roles (user_id, role) values (v_uid, 'CUSTOMER') on conflict do nothing;
  insert into public.user_consents (user_id, policy_version) values (v_uid, p_policy_version);
  update public.customer_invitations set accepted_at = now(), accepted_by = v_uid where id = i.id;
  return i.customer_id;
end $$;
