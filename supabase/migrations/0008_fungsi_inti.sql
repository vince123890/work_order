-- ===== MIGRATION 0008: fungsi inti (helper, nomor, audit, SLA, hash, guard) =======
-- Semua fungsi SECURITY DEFINER memakai search_path '' dan nama terkualifikasi (anti-hijack).

-- ---- settings -----------------------------------------------------------------
create or replace function app.setting(p_key text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select value from public.app_settings where key = p_key
$$;

create or replace function app.setting_int(p_key text) returns int
language sql stable security definer set search_path = '' as $$
  select case when jsonb_typeof(value) = 'number' then (value #>> '{}')::numeric::int end
  from public.app_settings where key = p_key
$$;

create or replace function app.setting_text(p_key text) returns text
language sql stable security definer set search_path = '' as $$
  select case when jsonb_typeof(value) = 'string' then value #>> '{}' end
  from public.app_settings where key = p_key
$$;

create or replace function app.setting_bool(p_key text, p_default boolean default false) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select case when jsonb_typeof(value) = 'boolean' then (value #>> '{}')::boolean end
                   from public.app_settings where key = p_key), p_default)
$$;

-- ---- nomor dokumen (BR-001) ------------------------------------------------------
-- Counter per (prefix, tahun) dengan row lock lewat ON CONFLICT DO UPDATE: unik, berurutan, tidak dipakai ulang.
create or replace function app.next_doc_number(p_prefix text, p_pad int default 6) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_year int := extract(year from (now() at time zone coalesce(app.setting_text('default_timezone'), 'Asia/Jakarta')))::int;
  v_val bigint;
begin
  insert into public.document_counters as dc (prefix, year, last_value)
  values (p_prefix, v_year, 1)
  on conflict (prefix, year) do update set last_value = dc.last_value + 1
  returning last_value into v_val;
  return p_prefix || '-' || v_year::text || '-' || lpad(v_val::text, p_pad, '0');
end $$;

-- ---- identitas / peran (dipakai RLS; selalu dipanggil sebagai (select app.fn()) di policy) ----
create or replace function app.my_roles() returns public.app_role[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(ur.role), '{}'::public.app_role[])
  from public.user_roles ur
  join public.profiles p on p.user_id = ur.user_id
  where ur.user_id = auth.uid() and p.is_active
$$;

create or replace function app.has_any_role(p_roles public.app_role[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select app.my_roles() && p_roles
$$;

create or replace function app.my_customer_ids() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(cu.customer_id), '{}'::uuid[])
  from public.customer_users cu
  join public.profiles p on p.user_id = cu.user_id
  join public.customers c on c.id = cu.customer_id
  where cu.user_id = auth.uid() and cu.is_active and p.is_active and c.is_active
$$;

create or replace function app.my_technician_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select t.id from public.technicians t
  join public.profiles p on p.user_id = t.user_id
  where t.user_id = auth.uid() and t.is_active and p.is_active
$$;

-- WO yang boleh DILIHAT teknisi: penugasan aktif/selesai/dibatalkan miliknya (AP-2; CANCELLED tetap terlihat agar pull sinkron tahu
-- pembatalan). REJECTED/RELEASED/REASSIGNED hilang dari cache (CONFLICT_REASSIGNED).
create or replace function app.my_active_wo_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select a.wo_id from public.wo_assignments a
  where a.technician_id = app.my_technician_id() and a.status in ('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED')
$$;

-- WO yang boleh DIUBAH datanya oleh teknisi (isian lapangan).
create or replace function app.my_editable_wo_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select a.wo_id from public.wo_assignments a
  join public.work_orders w on w.id = a.wo_id
  where a.technician_id = app.my_technician_id() and a.status = 'ACCEPTED'
    and w.status in ('IN_PROGRESS','ON_HOLD_PARTS','AWAITING_CUSTOMER_APPROVAL')
$$;

create or replace function app.tech_customer_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select distinct w.customer_id from public.work_orders w where w.id in (select app.my_active_wo_ids())
$$;
create or replace function app.tech_site_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select distinct w.site_id from public.work_orders w where w.site_id is not null and w.id in (select app.my_active_wo_ids())
$$;
create or replace function app.tech_asset_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select distinct w.asset_id from public.work_orders w where w.id in (select app.my_active_wo_ids())
$$;

create or replace function app.customer_owns_wo(p_wo_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.work_orders w
                 where w.id = p_wo_id and w.customer_id = any (app.my_customer_ids()))
$$;

-- Konteks sistem: service_role (JWT) atau sesi DB postgres tanpa user (pg_cron, migrasi).
create or replace function app.is_system() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
      or (auth.uid() is null and session_user in ('postgres', 'supabase_admin'))
$$;

create or replace function app.resolve_actor_roles(p_wo_id uuid) returns public.app_role[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(r), '{}'::public.app_role[])
  from unnest(app.my_roles()) r
  where r <> 'CUSTOMER' or app.customer_owns_wo(p_wo_id)
$$;

-- Pemetaan status internal -> status pelanggan (4.2). Fungsi murni di database, bukan di klien.
create or replace function app.customer_status(p_status public.wo_status) returns text
language sql immutable as $$
  select case p_status
    when 'NEW' then 'RECEIVED'
    when 'ASSIGNED' then 'RECEIVED'                       -- DEC-02: belum "Dijadwalkan" sebelum teknisi menerima
    when 'ACCEPTED' then 'SCHEDULED'
    when 'EN_ROUTE' then 'EN_ROUTE'
    when 'IN_PROGRESS' then 'IN_PROGRESS'
    when 'ON_HOLD_PARTS' then 'IN_PROGRESS'
    when 'UNDER_REVIEW' then 'IN_PROGRESS'
    when 'RETURNED' then 'IN_PROGRESS'                    -- tidak ada kemunduran terlihat
    when 'AWAITING_CUSTOMER_APPROVAL' then 'AWAITING_CUSTOMER'
    when 'AWAITING_SIGNOFF' then 'AWAITING_CUSTOMER'
    when 'CLOSED' then 'COMPLETED'
    when 'CANCELLED' then 'CANCELLED'
  end
$$;

-- ---- rate limit (BR-072) -----------------------------------------------------------
-- Jendela tetap. Mengembalikan TRUE bila masih dalam batas. IP-level dilakukan di edge/Next.js.
create or replace function app.rate_limit_hit(p_key text, p_max int, p_window_seconds int) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_ws timestamptz; v_count int;
begin
  if p_max is null or p_window_seconds is null or p_window_seconds <= 0 then return true; end if;
  v_ws := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into public.rate_limits as rl (key, window_start, count) values (p_key, v_ws, 1)
  on conflict (key, window_start) do update set count = rl.count + 1
  returning count into v_count;
  return v_count <= p_max;
end $$;

-- ---- trigger utilitas ---------------------------------------------------------------
create or replace function app.tg_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.version := old.version + 1;
  return new;
end $$;

create or replace function app.tg_forbid_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'IMM01: % bersifat append-only (% ditolak)', tg_table_name, tg_op
    using errcode = 'IMM01';
end $$;

-- Audit generik (BR-070, NFR-A2/A4). TG_ARGV[0] = daftar kolom diabaikan (csv) agar tidak berisik.
create or replace function app.tg_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_old jsonb; v_new jsonb; v_entity text;
  v_ignore text[] := coalesce(string_to_array(tg_argv[0], ','), '{}'::text[]) || array['updated_at','version'];
  v_headers jsonb; v_roles text;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new) - v_ignore;
    v_entity := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'key', to_jsonb(new) ->> 'user_id');
  elsif tg_op = 'UPDATE' then
    select jsonb_object_agg(n.key, n.value), jsonb_object_agg(o.key, o.value)
      into v_new, v_old
    from jsonb_each(to_jsonb(new) - v_ignore) n
    join jsonb_each(to_jsonb(old) - v_ignore) o on o.key = n.key
    where n.value is distinct from o.value;
    if v_new is null then return null; end if;           -- tidak ada perubahan bermakna
    v_entity := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'key', to_jsonb(new) ->> 'user_id');
  else
    v_old := to_jsonb(old) - v_ignore;
    v_entity := coalesce(to_jsonb(old) ->> 'id', to_jsonb(old) ->> 'key', to_jsonb(old) ->> 'user_id');
  end if;

  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;
  v_roles := coalesce(nullif(current_setting('app.actor_role', true), ''),
                      nullif(array_to_string(app.my_roles(), ','), ''),
                      case when app.is_system() then 'SYSTEM' end);

  insert into public.audit_logs (actor_id, actor_roles, entity_type, entity_id, action, old_values, new_values, request_id, ip)
  values (auth.uid(), v_roles, tg_table_name, v_entity, tg_op, v_old, v_new,
          v_headers ->> 'x-request-id',
          coalesce(split_part(v_headers ->> 'x-forwarded-for', ',', 1), v_headers ->> 'x-real-ip'));
  return null;
end $$;

-- ---- notifikasi -----------------------------------------------------------------------
create or replace function app.enqueue_notification(p_user_id uuid, p_event text, p_wo_id uuid,
                                                    p_payload jsonb, p_dedupe text) returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_channels text[];
  v_ch text; v_n int := 0;
begin
  select coalesce(array(select jsonb_array_elements_text(value)), '{}')
    into v_channels
    from public.app_settings
   where key = 'notification.default_channels' and jsonb_typeof(value) = 'array';
  if v_channels is null or cardinality(v_channels) = 0 then v_channels := array['IN_APP','EMAIL']; end if;

  foreach v_ch in array v_channels loop
    continue when exists (
      select 1 from public.notification_prefs np
      where np.user_id = p_user_id and np.channel = v_ch::public.notification_channel
        and np.event_group in ('*', split_part(p_event, '.', 1)) and not np.enabled);
    insert into public.notifications (user_id, event, channel, wo_id, payload, dedupe_key)
    values (p_user_id, p_event, v_ch::public.notification_channel, p_wo_id, coalesce(p_payload, '{}'::jsonb),
            case when p_dedupe is null then null else p_dedupe || ':' || v_ch end)
    on conflict do nothing;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function app.notify_role(p_role public.app_role, p_event text, p_wo_id uuid,
                                           p_payload jsonb, p_dedupe_prefix text) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select ur.user_id from public.user_roles ur join public.profiles p on p.user_id = ur.user_id
            where ur.role = p_role and p.is_active loop
    v_n := v_n + app.enqueue_notification(r.user_id, p_event, p_wo_id, p_payload,
              case when p_dedupe_prefix is null then null else p_dedupe_prefix || ':' || r.user_id::text end);
  end loop;
  return v_n;
end $$;

create or replace function app.notify_customer(p_customer_id uuid, p_event text, p_wo_id uuid,
                                               p_payload jsonb, p_dedupe_prefix text) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select cu.user_id from public.customer_users cu join public.profiles p on p.user_id = cu.user_id
            where cu.customer_id = p_customer_id and cu.is_active and p.is_active loop
    v_n := v_n + app.enqueue_notification(r.user_id, p_event, p_wo_id, p_payload,
              case when p_dedupe_prefix is null then null else p_dedupe_prefix || ':' || r.user_id::text end);
  end loop;
  return v_n;
end $$;

create or replace function app.notify_wo_technicians(p_wo_id uuid, p_event text, p_payload jsonb, p_dedupe_prefix text) returns int
language plpgsql security definer set search_path = '' as $$
declare r record; v_n int := 0;
begin
  for r in select t.user_id from public.wo_assignments a join public.technicians t on t.id = a.technician_id
            where a.wo_id = p_wo_id and a.status in ('ASSIGNED','ACCEPTED') loop
    v_n := v_n + app.enqueue_notification(r.user_id, p_event, p_wo_id, p_payload,
              case when p_dedupe_prefix is null then null else p_dedupe_prefix || ':' || r.user_id::text end);
  end loop;
  return v_n;
end $$;

-- ---- kalender kerja & SLA (BR-011/012) -----------------------------------------------------
-- Jendela jam kerja terbuka pada [p_from, p_to), sudah dipotong ke rentang & melewati hari libur.
create or replace function app.sla_open_windows(p_calendar_id uuid, p_from timestamptz, p_to timestamptz)
returns table (w_start timestamptz, w_end timestamptz)
language sql stable security definer set search_path = '' as $$
  with cal as (
    select id, timezone, is_24x7 from public.business_calendars where id = p_calendar_id
  )
  select p_from, p_to from cal where cal.is_24x7 and p_to > p_from
  union all
  select x.ws, x.we from (
    select greatest((d.d::date + h.open_time) at time zone cal.timezone, p_from) as ws,
           least((d.d::date + h.close_time) at time zone cal.timezone, p_to)     as we
    from cal
    cross join lateral generate_series(((p_from at time zone cal.timezone)::date - 1)::timestamp,
                                       ((p_to   at time zone cal.timezone)::date + 1)::timestamp,
                                       interval '1 day') as d(d)
    join public.calendar_hours h on h.calendar_id = cal.id and h.weekday = extract(isodow from d.d)::int
    where not cal.is_24x7
      and not exists (select 1 from public.calendar_holidays ho
                      where ho.calendar_id = cal.id and ho.holiday_date = d.d::date)
  ) x
  where x.we > x.ws
  order by 1
$$;

-- Tambah menit kerja ke waktu mulai. Kalender NULL / 24x7 = menit dinding. NULL bila kalender tak punya jam kerja.
create or replace function app.sla_add_business_minutes(p_start timestamptz, p_minutes numeric, p_calendar_id uuid)
returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare
  v_is247 boolean; v_found boolean := false;
  v_rem numeric := p_minutes; v_t timestamptz := p_start; v_to timestamptz;
  v_i int := 0; r record; v_avail numeric;
begin
  if p_start is null or p_minutes is null then return null; end if;
  if p_minutes < 0 then raise exception 'WO006: menit negatif tidak didukung' using errcode = 'WO006'; end if;
  if p_calendar_id is not null then
    select is_24x7, true into v_is247, v_found from public.business_calendars where id = p_calendar_id;
  end if;
  if not v_found or v_is247 then
    return p_start + make_interval(secs => (p_minutes * 60)::double precision);
  end if;
  loop
    v_to := v_t + interval '62 days';
    for r in select * from app.sla_open_windows(p_calendar_id, v_t, v_to) loop
      v_avail := extract(epoch from (r.w_end - r.w_start)) / 60;
      if v_rem <= v_avail then
        return r.w_start + make_interval(secs => (v_rem * 60)::double precision);
      end if;
      v_rem := v_rem - v_avail;
    end loop;
    v_t := v_to; v_i := v_i + 1;
    if v_i >= 24 then
      raise warning 'sla_add_business_minutes: kalender % tidak punya jam kerja dalam ~4 tahun', p_calendar_id;
      return null;
    end if;
  end loop;
end $$;

-- Menit kerja antara dua waktu (>= 0).
create or replace function app.sla_business_minutes_between(p_from timestamptz, p_to timestamptz, p_calendar_id uuid)
returns numeric
language plpgsql stable security definer set search_path = '' as $$
declare v_is247 boolean; v_found boolean := false; v_sum numeric;
begin
  if p_from is null or p_to is null then return null; end if;
  if p_to <= p_from then return 0; end if;
  if p_calendar_id is not null then
    select is_24x7, true into v_is247, v_found from public.business_calendars where id = p_calendar_id;
  end if;
  if not v_found or v_is247 then return extract(epoch from (p_to - p_from)) / 60; end if;
  select coalesce(sum(extract(epoch from (w_end - w_start)) / 60), 0) into v_sum
    from app.sla_open_windows(p_calendar_id, p_from, p_to);
  return v_sum;
end $$;

-- ---- hash isi laporan (BR-043) ----------------------------------------------------------------
-- Hanya data "bermakna" (definisi [P], OQ-18): temuan, tindakan, rekomendasi, suku cadang, jasa, biaya tambahan disetujui.
create or replace function app.wo_content_hash(p_wo_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select encode(sha256(convert_to(jsonb_build_object(
    'findings', (select jsonb_build_object('d', diagnosis, 'a', action_taken, 'r', recommendation)
                 from public.wo_findings where wo_id = p_wo_id),
    'parts', (select coalesce(jsonb_agg(jsonb_build_array(item_id, qty) order by item_id, qty), '[]'::jsonb)
              from public.wo_part_usages where wo_id = p_wo_id and deleted_at is null),
    'labor', (select coalesce(jsonb_agg(jsonb_build_array(description, qty) order by description, qty), '[]'::jsonb)
              from public.wo_labor_lines where wo_id = p_wo_id and deleted_at is null),
    'extra', (select coalesce(jsonb_agg(jsonb_build_array(version_no, total) order by version_no), '[]'::jsonb)
              from public.extra_cost_approvals where wo_id = p_wo_id and status = 'APPROVED')
  )::text, 'UTF8')), 'hex')
$$;

-- ---- syarat penutupan (BR-040): kembalikan SEMUA kekurangan sekaligus -------------------------------
-- p_mode: 'SUBMIT' (T-16/T-18), 'SIGNOFF_REQUEST' (T-17: tanpa syarat tanda tangan), 'CLOSE' (T-19, BR-042)
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

  -- 4. tanda tangan / persetujuan / pengecualian
  if p_mode in ('SUBMIT', 'CLOSE') then
    v_hash := app.wo_content_hash(p_wo_id);
    v_ok := exists (select 1 from public.wo_signatures s
                     where s.wo_id = p_wo_id and s.signer_type = 'CUSTOMER' and s.status = 'VALID' and s.content_hash = v_hash);
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

-- ---- billing_type (BR-060) --------------------------------------------------------------------------
create or replace function app.determine_billing(p_customer_id uuid, p_asset_id uuid, p_service_type_id uuid, p_at timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text := coalesce(app.setting_text('default_timezone'), 'Asia/Jakarta');
  v_date date := (p_at at time zone v_tz)::date;
  v_contract uuid; v_ca uuid; a public.assets;
begin
  select c.id, ca.id into v_contract, v_ca
  from public.contracts c
  join public.contract_assets ca on ca.contract_id = c.id
  where c.customer_id = p_customer_id and c.status = 'ACTIVE'
    and v_date between c.start_date and c.end_date
    and ca.asset_id = p_asset_id and ca.service_type_id = p_service_type_id and ca.is_active
    and (ca.active_from is null or ca.active_from <= v_date)
    and (ca.active_to is null or ca.active_to >= v_date)
  order by c.start_date desc
  limit 1;
  if v_contract is not null then
    return jsonb_build_object('billing_type', 'COVERED_CONTRACT', 'contract_id', v_contract, 'contract_asset_id', v_ca);
  end if;

  select * into a from public.assets where id = p_asset_id;
  if a.warranty_start is not null and a.warranty_end is not null and v_date between a.warranty_start and a.warranty_end then
    return jsonb_build_object('billing_type', 'WARRANTY');   -- pengecualian garansi dinilai SPV (BR-063)
  end if;
  return jsonb_build_object('billing_type', 'BILLABLE');
end $$;

-- ---- SLA: hitung ulang tenggat & status dari kebijakan (BR-010/015/016) ---------------------------------
-- Dipanggil saat WO dibuat dan saat prioritas berubah. TODO: jeda yang sudah berlalu tidak dihitung ulang saat prioritas berubah.
create or replace function app.sla_recalculate(p_wo_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  w public.work_orders; c public.contracts; pol public.sla_policies; ca public.contract_assets;
  v_set uuid; v_cal uuid; v_tz text; v_grace int; v_resp timestamptz; v_reso timestamptz;
begin
  select * into w from public.work_orders where id = p_wo_id;
  if w.contract_id is not null then select * into c from public.contracts where id = w.contract_id; end if;
  v_set := coalesce(c.sla_policy_set_id, (select id from public.sla_policy_sets where is_default and is_active limit 1));
  v_cal := coalesce(c.calendar_id, (select id from public.business_calendars where is_default limit 1));
  v_tz  := coalesce((select timezone from public.business_calendars where id = v_cal),
                    app.setting_text('default_timezone'), 'Asia/Jakarta');
  if v_set is not null then
    select * into pol from public.sla_policies where policy_set_id = v_set and priority_code = w.priority_code;
  end if;

  if pol.id is null then
    update public.work_orders set sla_policy_set_id = v_set, sla_calendar_id = v_cal, policy_snapshot = null,
           response_due_at = null, resolution_due_at = null,
           response_sla_state = case when response_met_at is null then 'NOT_TRACKED' else response_sla_state end,
           resolution_sla_state = case when resolution_met_at is null then 'NOT_TRACKED' else resolution_sla_state end,
           next_sla_check_at = null
     where id = p_wo_id;
    return;
  end if;

  if w.type = 'PREVENTIVE' then
    select * into ca from public.contract_assets where id = w.contract_asset_id;
    v_grace := coalesce(ca.grace_days, app.setting_int('pm.grace_days'), 0);
    v_resp := null;
    v_reso := ((w.pm_due_date + v_grace + 1)::timestamp at time zone v_tz);   -- akhir hari jatuh tempo + toleransi (BR-016)
  else
    v_resp := app.sla_add_business_minutes(w.sla_clock_start_at, pol.response_minutes, v_cal);
    v_reso := app.sla_add_business_minutes(w.sla_clock_start_at, pol.resolution_minutes, v_cal);
  end if;

  update public.work_orders set
    sla_policy_set_id = v_set, sla_calendar_id = v_cal,
    policy_snapshot = to_jsonb(pol) || jsonb_build_object('timezone', v_tz, 'applied_at', now()),
    response_due_at = v_resp, resolution_due_at = v_reso,
    response_sla_state = case when response_met_at is not null then response_sla_state
                              when v_resp is null then 'NOT_TRACKED' else 'RUNNING' end,
    resolution_sla_state = case when resolution_met_at is not null then resolution_sla_state
                                when v_reso is null then 'NOT_TRACKED'
                                when sla_paused_at is not null then 'PAUSED' else 'RUNNING' end,
    next_sla_check_at = now()
  where id = p_wo_id;
end $$;

-- ---- checklist & syarat foto: salin template ke WO (snapshot) ------------------------------------------------
create or replace function app.instantiate_checklist(p_wo_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders; v_tpl uuid; v_ver int;
begin
  select * into w from public.work_orders where id = p_wo_id;
  select coalesce(st.default_checklist_template_id, ac.default_checklist_template_id)
    into v_tpl
    from public.service_types st
    left join public.assets a on a.id = w.asset_id
    left join public.asset_categories ac on ac.id = a.category_id
   where st.id = w.service_type_id;
  if v_tpl is null then return; end if;
  select version_no into v_ver from public.checklist_templates where id = v_tpl;

  update public.work_orders set checklist_template_id = v_tpl, checklist_template_version = v_ver where id = p_wo_id;
  insert into public.wo_checklist_items (wo_id, template_item_id, seq, label_snapshot, input_type, choices, required, photo_required)
  select p_wo_id, i.id, i.seq, i.label, i.input_type, i.choices, i.required, i.photo_required
    from public.checklist_template_items i where i.template_id = v_tpl
  on conflict (wo_id, seq) do nothing;
  insert into public.wo_photo_requirements (wo_id, kind, min_count)
  select p_wo_id, kind, min_count from public.photo_requirements where template_id = v_tpl
  on conflict (wo_id, kind) do nothing;
end $$;

-- ---- pembuatan WO (dipakai validasi permintaan, generator PM, rework) -------------------------------------------
-- Mengembalikan NULL bila bentrok unique PM (sudah ada WO untuk periode itu): idempotensi dijamin constraint DB.
create or replace function app.create_work_order(
  p_type public.wo_type, p_customer_id uuid, p_site_id uuid, p_asset_id uuid, p_service_type_id uuid,
  p_request_id uuid, p_contract_asset_id uuid, p_pm_period date, p_parent_wo_id uuid,
  p_priority_code text, p_estimate_total numeric, p_actor uuid,
  p_requested_at timestamptz default now(), p_billing public.billing_type default null,
  p_clock_start timestamptz default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_bill jsonb; v_billing public.billing_type; v_contract uuid; v_ca uuid; v_id uuid;
  v_prev text := coalesce(current_setting('app.tx_active', true), 'off');
begin
  if p_priority_code is null then
    raise exception 'WO006: priority wajib' using errcode = 'WO006';
  end if;
  if p_billing is not null then
    v_billing := p_billing;
    v_contract := (select contract_id from public.contract_assets ca join public.contracts c on c.id = ca.contract_id
                    where ca.id = p_contract_asset_id);
  else
    v_bill := app.determine_billing(p_customer_id, p_asset_id, p_service_type_id, p_requested_at);
    v_billing := (v_bill ->> 'billing_type')::public.billing_type;
    v_contract := nullif(v_bill ->> 'contract_id', '')::uuid;
    v_ca := nullif(v_bill ->> 'contract_asset_id', '')::uuid;
  end if;
  if p_type = 'PREVENTIVE' then
    v_contract := (select ca.contract_id from public.contract_assets ca where ca.id = p_contract_asset_id);
    v_ca := p_contract_asset_id;
  else
    v_ca := null;          -- contract_asset_id hanya untuk WO preventif (unik per periode)
  end if;

  perform set_config('app.tx_active', 'on', true);       -- izinkan INSERT status awal tanpa guard
  insert into public.work_orders as w (
    wo_number, type, customer_id, site_id, asset_id, service_type_id, request_id, contract_id, contract_asset_id,
    pm_period_key, pm_due_date, parent_wo_id, priority_code, status, billing_type, billing_status, estimate_total,
    requested_at, sla_clock_start_at, created_by)
  values (
    app.next_doc_number('WO'), p_type, p_customer_id, p_site_id, p_asset_id, p_service_type_id, p_request_id, v_contract, v_ca,
    p_pm_period, p_pm_period, p_parent_wo_id, p_priority_code, 'NEW', v_billing, 'NOT_BILLABLE', p_estimate_total,
    p_requested_at, coalesce(p_clock_start, now()), p_actor)
  on conflict (contract_asset_id, pm_period_key) where type = 'PREVENTIVE' do nothing
  returning w.id into v_id;
  if v_id is null then
    perform set_config('app.tx_active', v_prev, true);
    return null;
  end if;

  perform app.instantiate_checklist(v_id);
  perform app.sla_recalculate(v_id);
  perform set_config('app.tx_active', v_prev, true);
  return v_id;
end $$;
