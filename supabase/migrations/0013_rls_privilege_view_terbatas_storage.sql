-- ===== MIGRATION 0013: RLS, privilege, view terbatas, Storage ==========================
-- Strategi lengkap + matriks: 05_rls_and_security.md. Prinsip: default tolak.
--  * Semua tabel public: RLS aktif. Tabel tanpa policy = tertutup untuk anon/authenticated.
--  * Penulisan sensitif hanya lewat RPC SECURITY DEFINER (peran dicek di dalam fungsi).
--  * Fungsi SECURITY DEFINER dimiliki postgres (bypass RLS) = jalur kode tepercaya. Jangan pakai FORCE RLS.

-- ---- helper tambahan untuk policy ----------------------------------------------------------------
create or replace function app.tech_request_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select w.request_id from public.work_orders w
   where w.request_id is not null and w.id in (select app.my_active_wo_ids())
$$;

create or replace function app.my_location_ids() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select sl.id from public.stock_locations sl where sl.technician_id = app.my_technician_id()
$$;

create or replace function app.wo_storage_prefix(p_wo_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select w.customer_id::text || '/wo/' || w.id::text || '/' from public.work_orders w where w.id = p_wo_id
$$;

create or replace function app.can_edit_wo(p_wo_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_wo_id in (select app.my_editable_wo_ids())
$$;

-- Akses objek Storage (path: {customer_id}/{req|wo}/{owner_id}/{file}). Dipakai policy storage.objects.
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

  if app.has_any_role('{TECHNICIAN}') then
    if v_scope = 'wo' and v_owner in (select app.my_active_wo_ids()) then return true; end if;
    if v_scope = 'req' and v_owner in (select app.tech_request_ids()) then return true; end if;
  end if;

  if v_cust = any ((select app.my_customer_ids())::uuid[]) then                  -- pelanggan: hanya objek yang terdaftar & boleh dilihat
    if p_bucket = 'reports' then
      return exists (select 1 from public.service_reports r join public.work_orders w on w.id = r.wo_id
                      where r.storage_path = p_name and r.customer_id = v_cust and r.status = 'READY' and w.status = 'CLOSED');
    end if;
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

-- ---- RPC administrasi pengguna & estimasi -------------------------------------------------------------
create or replace function public.admin_set_user_roles(p_user_id uuid, p_roles public.app_role[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v_old public.app_role[]; v_changed public.app_role[]; r public.app_role;
begin
  if not app.has_any_role('{ADMIN_CS,OWNER}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  select coalesce(array_agg(role), '{}') into v_old from public.user_roles where user_id = p_user_id;
  -- selisih simetris
  select coalesce(array_agg(x), '{}') into v_changed from (
    select unnest(v_old) except select unnest(coalesce(p_roles, '{}'))
    union select unnest(coalesce(p_roles, '{}')) except select unnest(v_old)) q(x);
  -- hardening eskalasi hak: hanya OWNER boleh mengubah OWNER/ADMIN_CS
  if ('OWNER' = any (v_changed) or 'ADMIN_CS' = any (v_changed)) and not app.has_any_role('{OWNER}') then
    raise exception 'WO002: hanya Owner yang boleh mengubah peran OWNER/ADMIN_CS' using errcode = 'WO002';
  end if;
  delete from public.user_roles where user_id = p_user_id and not (role = any (coalesce(p_roles, '{}')));
  foreach r in array coalesce(p_roles, '{}') loop
    insert into public.user_roles (user_id, role, granted_by) values (p_user_id, r, auth.uid()) on conflict do nothing;
  end loop;
end $$;

create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_any_role('{ADMIN_CS,OWNER}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  update public.profiles set is_active = p_active, deactivated_at = case when p_active then null else now() end where user_id = p_user_id;
  -- FR-007: pencabutan sesi aktif (auth.admin.signOut) dilakukan API server setelah RPC ini; RLS sudah menolak seketika.
end $$;

create or replace function public.wo_set_estimate(p_wo_id uuid, p_estimate numeric, p_expected_version int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w public.work_orders;
begin
  if not app.has_any_role('{ADMIN_CS,SUPERVISOR}') then raise exception 'WO002: tidak berhak' using errcode = 'WO002'; end if;
  select * into w from public.work_orders where id = p_wo_id for update;
  if w.id is null then raise exception 'WO005: WO tidak ditemukan' using errcode = 'WO005'; end if;
  if w.status in ('CLOSED','CANCELLED') then raise exception 'WO001: WO final' using errcode = 'WO001'; end if;
  if w.version <> p_expected_version then
    raise exception 'WO004: konflik versi' using errcode = 'WO004',
      detail = jsonb_build_object('current_version', w.version, 'current_status', w.status)::text;
  end if;
  update public.work_orders set estimate_total = p_estimate, estimate_version = estimate_version + 1 where id = p_wo_id
    returning * into w;
  return jsonb_build_object('status', w.status, 'version', w.version, 'estimate_version', w.estimate_version);
end $$;

-- ---- view terbatas untuk teknisi & gudang (tanpa harga/margin, AP-2) --------------------------------------
create or replace view public.tech_wo_part_usages with (security_barrier = true) as
select u.id, u.wo_id, u.item_id, u.qty, u.is_extra, u.extra_approval_id, u.emergency, u.unsourced, u.op_id, u.deleted_at, u.created_at
from public.wo_part_usages u where u.wo_id in (select app.my_active_wo_ids());

create or replace view public.tech_wo_labor_lines with (security_barrier = true) as
select l.id, l.wo_id, l.service_item_id, l.description, l.qty, l.is_extra, l.extra_approval_id, l.emergency, l.op_id, l.deleted_at, l.created_at
from public.wo_labor_lines l where l.wo_id in (select app.my_active_wo_ids());

create or replace view public.tech_extra_cost_approvals with (security_barrier = true) as
select a.id as approval_id, a.wo_id, a.version_no, a.status, a.reason, a.requested_at, a.expires_at, a.decided_at, a.continue_original_scope
from public.extra_cost_approvals a where a.wo_id in (select app.my_active_wo_ids());

create or replace view public.v_items_catalog with (security_barrier = true) as
select i.id, i.sku, i.name, i.uom, i.is_serialized, i.tracking_mode, i.is_active
from public.items i
where app.has_any_role('{ADMIN_CS,DISPATCHER,TECHNICIAN,SUPERVISOR,WAREHOUSE,FINANCE,OWNER}');

create or replace view public.v_wh_part_requests with (security_barrier = true) as
select pr.id as request_id, pr.request_no, pr.status, pr.created_at, w.id as wo_id, w.wo_number, w.status as wo_status,
       a.asset_code, p.full_name as technician_name,
       (select coalesce(jsonb_agg(jsonb_build_object('line_id', l.id, 'item_id', l.item_id, 'qty_requested', l.qty_requested,
               'qty_issued', l.qty_issued)), '[]'::jsonb) from public.part_request_lines l where l.request_id = pr.id) as lines
from public.part_requests pr
join public.work_orders w on w.id = pr.wo_id
join public.assets a on a.id = w.asset_id
left join public.wo_assignments x on x.wo_id = w.id and x.role = 'LEAD' and x.status in ('ASSIGNED','ACCEPTED','COMPLETED')
left join public.technicians t on t.id = x.technician_id
left join public.profiles p on p.user_id = t.user_id
where app.has_any_role('{WAREHOUSE,SUPERVISOR,OWNER,DISPATCHER}');

-- ---- RLS aktif di SEMUA tabel public ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' loop
    execute format('alter table public.%I enable row level security', r.relname);
  end loop;
end $$;

-- Pemeriksaan CI (NFR-S3): harus mengembalikan 0 baris.
create or replace function app.tables_without_rls() returns table (table_name text)
language sql stable as $$
  select c.relname::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r','p') and not c.relrowsecurity
$$;

-- ---- privilege dasar ----------------------------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

revoke all on schema app from public, anon, authenticated;
revoke execute on all functions in schema app from public, anon, authenticated;
grant usage on schema app to authenticated;
grant execute on function
  app.my_roles(), app.has_any_role(public.app_role[]), app.my_customer_ids(), app.my_technician_id(),
  app.my_active_wo_ids(), app.my_editable_wo_ids(), app.tech_customer_ids(), app.tech_site_ids(), app.tech_asset_ids(),
  app.tech_request_ids(), app.my_location_ids(), app.customer_owns_wo(uuid), app.wo_storage_prefix(uuid),
  app.can_edit_wo(uuid), app.can_read_object(text, text), app.customer_status(public.wo_status)
to authenticated;

grant select on all tables in schema public to authenticated;
revoke select on public.rate_limits, public.document_counters from authenticated;

-- Penulisan langsung (tetap dibatasi RLS + trigger). Kolom sensitif sengaja TIDAK diberi hak tulis.
grant insert, update on public.customers, public.customer_sites, public.assets, public.asset_categories, public.service_types,
  public.problem_types, public.service_items, public.checklist_templates, public.checklist_template_items,
  public.photo_requirements, public.skills, public.technicians, public.technician_skills, public.contracts,
  public.contract_assets, public.items, public.stock_locations, public.business_calendars, public.calendar_hours,
  public.calendar_holidays, public.sla_policy_sets, public.sla_policies, public.escalation_rules, public.app_settings,
  public.customer_invitations, public.import_jobs, public.invoices, public.invoice_lines, public.payments, public.priorities,
  public.reason_codes to authenticated;
grant delete on public.calendar_hours, public.calendar_holidays, public.technician_skills, public.photo_requirements,
  public.checklist_template_items, public.escalation_rules, public.invoice_lines to authenticated;

grant insert (id, customer_id, site_id, asset_id, problem_type_id, description, preferred_start, preferred_end, channel, client_request_id)
  on public.service_requests to authenticated;
grant update (description, preferred_start, preferred_end, problem_type_id, site_id, asset_id, status)
  on public.service_requests to authenticated;
grant insert (id, request_id, customer_id, storage_path, mime, bytes, checksum) on public.request_attachments to authenticated;
grant update (value, is_na, na_reason, client_captured_at, op_id) on public.wo_checklist_items to authenticated;
grant insert (wo_id, diagnosis, action_taken, recommendation, internal_note),
      update (diagnosis, action_taken, recommendation, internal_note) on public.wo_findings to authenticated;
grant insert (id, wo_id, kind, storage_path, mime, bytes, checksum, taken_at, op_id, extra_approval_id),
      update (deleted_at) on public.wo_attachments to authenticated;
grant insert (id, wo_id, signer_type, signer_name, storage_path, signed_via, device_meta, op_id) on public.wo_signatures to authenticated;
grant insert (id, wo_id, service_item_id, description, qty, is_extra, extra_approval_id, emergency, emergency_reason, op_id),
      update (deleted_at) on public.wo_labor_lines to authenticated;
grant insert (id, wo_id, item_id, qty, is_extra, extra_approval_id, emergency, emergency_reason, source_location_id, op_id),
      update (deleted_at) on public.wo_part_usages to authenticated;
grant insert (wo_id, score, comment) on public.ratings to authenticated;
grant insert (wo_id, description) on public.complaints to authenticated;
grant update (status, resolution_note, handled_by) on public.complaints to authenticated;
grant update (full_name, phone) on public.profiles to authenticated;
grant update (read_at, status) on public.notifications to authenticated;
grant insert, update, delete on public.notification_prefs to authenticated;
grant insert (op_id, device_id, user_id, wo_id, type, seq, schema_version, payload, client_captured_at) on public.sync_operations to authenticated;

grant execute on function
  public.wo_transition(uuid, text, int, uuid, text, text, jsonb), public.request_decide(uuid, text, text, uuid, numeric, text, int),
  public.extra_cost_request(uuid, text, jsonb, int, uuid), public.extra_cost_decide(uuid, text, text, boolean, public.decision_channel, text, uuid, jsonb),
  public.wo_customer_sign(uuid, text, text, int, uuid, jsonb), public.wo_request_help(uuid, text), public.wo_add_helper(uuid, uuid),
  public.wo_request_cancel(uuid, text), public.wo_change_priority(uuid, text, text, int),
  public.wo_override_billing(uuid, public.billing_type, text), public.wo_create_rework(uuid, text, text, uuid),
  public.wo_cost_summary(uuid), public.wo_set_estimate(uuid, numeric, int), public.pm_period_resolve(uuid, text, text),
  public.part_request_create(uuid, jsonb, text), public.part_request_decide(uuid, text, text), public.part_issue(uuid, numeric, uuid),
  public.part_return_create(uuid, jsonb, text), public.part_return_confirm(uuid, jsonb, uuid, boolean),
  public.stock_receive(uuid, uuid, numeric, text), public.stock_adjust(uuid, uuid, numeric, text),
  public.parts_variance_resolve(uuid, public.variance_status, text), public.log_data_access(uuid, text, text, text),
  public.register_individual_customer(text, text, text), public.accept_customer_invitation(text, text),
  public.admin_set_user_roles(uuid, public.app_role[]), public.admin_set_user_active(uuid, boolean)
to authenticated;

-- ---- POLICY: pembacaan khusus staf per peran (pola seragam) --------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
    ('priorities',          '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE,TECHNICIAN}'),
    ('reason_codes',        '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE,TECHNICIAN}'),
    ('wo_transitions',      '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,TECHNICIAN}'),
    ('skills',              '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,TECHNICIAN}'),
    ('technicians',         '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('technician_skills',   '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('asset_categories',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,TECHNICIAN}'),
    ('checklist_templates', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,TECHNICIAN}'),
    ('checklist_template_items', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,TECHNICIAN}'),
    ('photo_requirements',  '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,TECHNICIAN}'),
    ('service_items',       '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('business_calendars',  '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('calendar_hours',      '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('calendar_holidays',   '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('sla_policy_sets',     '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('sla_policies',        '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('escalation_rules',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('app_settings',        '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE}'),
    ('pm_periods_staff',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('wo_status_history_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('wo_visits_staff',     '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_checklist_items_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_photo_requirements_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_findings_staff',   '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_attachments_staff','{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('wo_signatures_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('wo_labor_lines_staff','{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('wo_part_usages_staff','{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE}'),
    ('extra_cost_approvals_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('extra_cost_approval_items_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('sla_events_staff',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('sla_pauses_staff',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('service_reports_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE}'),
    ('items',               '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,FINANCE,WAREHOUSE}'),
    ('stock_locations_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE,FINANCE}'),
    ('stock_balances_staff', '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE,FINANCE}'),
    ('stock_movements_staff', '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE,FINANCE}'),
    ('part_requests_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE}'),
    ('part_request_lines_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE}'),
    ('part_returns_staff',  '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE}'),
    ('part_return_lines_staff', '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE}'),
    ('parts_variances_staff', '{DISPATCHER,SUPERVISOR,OWNER,WAREHOUSE,FINANCE}'),
    ('complaints_staff',    '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('ratings_staff',       '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('invoices_staff',      '{ADMIN_CS,SUPERVISOR,OWNER,FINANCE}'),
    ('invoice_lines_staff', '{ADMIN_CS,SUPERVISOR,OWNER,FINANCE}'),
    ('payments_staff',      '{ADMIN_CS,SUPERVISOR,OWNER,FINANCE}'),
    ('customer_invitations_staff', '{ADMIN_CS,OWNER}'),
    ('import_jobs_staff',   '{ADMIN_CS,OWNER,WAREHOUSE}'),
    ('job_runs_staff',      '{ADMIN_CS,OWNER}'),
    ('sync_operations_staff', '{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'),
    ('access_logs_staff',   '{OWNER}')
  ) v(pol, roles) loop
    -- nama tabel = pol tanpa akhiran _staff
    execute format('create policy %I on public.%I for select to authenticated using ((select app.has_any_role(%L::public.app_role[])))',
                   r.pol || case when r.pol like '%\_staff' then '' else '_select_staff' end,
                   regexp_replace(r.pol, '_staff$', ''), r.roles);
  end loop;
end $$;

-- ---- POLICY: tulis konfigurasi/master (staf) ------------------------------------------------------------------------------
do $$
declare r record; t text;
begin
  -- ADMIN_CS menulis master data
  foreach t in array array['customers','customer_sites','assets','asset_categories','service_types','problem_types','service_items',
      'checklist_templates','checklist_template_items','photo_requirements','skills','technicians','technician_skills','contracts',
      'contract_assets','customer_invitations','import_jobs'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app.has_any_role(%L::public.app_role[])))', t || '_insert_admin', t, '{ADMIN_CS}');
    execute format('create policy %I on public.%I for update to authenticated using ((select app.has_any_role(%L::public.app_role[]))) with check ((select app.has_any_role(%L::public.app_role[])))', t || '_update_admin', t, '{ADMIN_CS}', '{ADMIN_CS}');
  end loop;
  foreach t in array array['technician_skills','photo_requirements','checklist_template_items'] loop
    execute format('create policy %I on public.%I for delete to authenticated using ((select app.has_any_role(%L::public.app_role[])))', t || '_delete_admin', t, '{ADMIN_CS}');
  end loop;
  -- OWNER menulis konfigurasi SLA/kalender/setting (OQ-12: ubah ke {ADMIN_CS,OWNER} bila bisnis memutuskan)
  foreach t in array array['business_calendars','calendar_hours','calendar_holidays','sla_policy_sets','sla_policies','escalation_rules',
      'app_settings','priorities','reason_codes'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app.has_any_role(%L::public.app_role[])))', t || '_insert_owner', t, '{OWNER}');
    execute format('create policy %I on public.%I for update to authenticated using ((select app.has_any_role(%L::public.app_role[]))) with check ((select app.has_any_role(%L::public.app_role[])))', t || '_update_owner', t, '{OWNER}', '{OWNER}');
  end loop;
  foreach t in array array['calendar_hours','calendar_holidays','escalation_rules'] loop
    execute format('create policy %I on public.%I for delete to authenticated using ((select app.has_any_role(%L::public.app_role[])))', t || '_delete_owner', t, '{OWNER}');
  end loop;
  -- WAREHOUSE menulis master barang & lokasi stok
  foreach t in array array['items','stock_locations'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app.has_any_role(%L::public.app_role[])))', t || '_insert_wh', t, '{WAREHOUSE}');
    execute format('create policy %I on public.%I for update to authenticated using ((select app.has_any_role(%L::public.app_role[]))) with check ((select app.has_any_role(%L::public.app_role[])))', t || '_update_wh', t, '{WAREHOUSE}', '{WAREHOUSE}');
  end loop;
  -- FINANCE menulis invoice (Lapis 3, TODO: pindahkan ke RPC penerbitan)
  foreach t in array array['invoices','invoice_lines','payments'] loop
    execute format('create policy %I on public.%I for insert to authenticated with check ((select app.has_any_role(%L::public.app_role[])))', t || '_insert_fin', t, '{FINANCE}');
  end loop;
  foreach t in array array['invoices','invoice_lines'] loop
    execute format('create policy %I on public.%I for update to authenticated using ((select app.has_any_role(%L::public.app_role[]))) with check ((select app.has_any_role(%L::public.app_role[])))', t || '_update_fin', t, '{FINANCE}', '{FINANCE}');
  end loop;
  create policy invoice_lines_delete_fin on public.invoice_lines for delete to authenticated using ((select app.has_any_role('{FINANCE}')));
end $$;

-- ---- POLICY: identitas ---------------------------------------------------------------------------------------------------
create policy profiles_select on public.profiles for select to authenticated
  using (user_id = (select auth.uid()) or (select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}')));
create policy profiles_update_self on public.profiles for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy user_roles_select on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or (select app.has_any_role('{ADMIN_CS,OWNER}')));
create policy user_consents_select on public.user_consents for select to authenticated
  using (user_id = (select auth.uid()));

create policy technicians_select_self on public.technicians for select to authenticated using (user_id = (select auth.uid()));
create policy technician_skills_select_self on public.technician_skills for select to authenticated
  using (technician_id = (select app.my_technician_id()));

-- ---- POLICY: master data dibaca pelanggan / teknisi / staf ------------------------------------------------------------------
create policy customers_select on public.customers for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'))
         or id = any ((select app.my_customer_ids())::uuid[])
         or id in (select app.tech_customer_ids()));
create policy customer_users_select on public.customer_users for select to authenticated
  using (user_id = (select auth.uid()) or customer_id = any ((select app.my_customer_ids())::uuid[])
         or (select app.has_any_role('{ADMIN_CS,OWNER}')));
create policy customer_sites_select on public.customer_sites for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'))
         or customer_id = any ((select app.my_customer_ids())::uuid[])
         or id in (select app.tech_site_ids()));
create policy assets_select on public.assets for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'))
         or customer_id = any ((select app.my_customer_ids())::uuid[])
         or id in (select app.tech_asset_ids()));
create policy service_types_select on public.service_types for select to authenticated using (true);      -- katalog layanan (form pemesanan)
create policy problem_types_select on public.problem_types for select to authenticated using (true);
create policy contracts_select on public.contracts for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')) or customer_id = any ((select app.my_customer_ids())::uuid[]));
create policy contract_assets_select on public.contract_assets for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}'))
         or contract_id in (select c.id from public.contracts c where c.customer_id = any ((select app.my_customer_ids())::uuid[])));
create policy pm_periods_customer on public.pm_periods for select to authenticated
  using (contract_asset_id in (select ca.id from public.contract_assets ca join public.contracts c on c.id = ca.contract_id
                                where c.customer_id = any ((select app.my_customer_ids())::uuid[])));

-- ---- POLICY: permintaan servis ----------------------------------------------------------------------------------------------
create policy service_requests_select on public.service_requests for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')) or customer_id = any ((select app.my_customer_ids())::uuid[]));
create policy service_requests_insert on public.service_requests for insert to authenticated
  with check ((customer_id = any ((select app.my_customer_ids())::uuid[]) and channel = 'PWA')
              or (select app.has_any_role('{ADMIN_CS}')));
create policy service_requests_update on public.service_requests for update to authenticated
  using ((customer_id = any ((select app.my_customer_ids())::uuid[]) and status in ('SUBMITTED','NEEDS_INFO'))
         or (select app.has_any_role('{ADMIN_CS}')))
  with check (customer_id = any ((select app.my_customer_ids())::uuid[]) or (select app.has_any_role('{ADMIN_CS}')));
create policy request_attachments_select on public.request_attachments for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}'))
         or customer_id = any ((select app.my_customer_ids())::uuid[])
         or request_id in (select app.tech_request_ids()));
create policy request_attachments_insert on public.request_attachments for insert to authenticated
  with check ((customer_id = any ((select app.my_customer_ids())::uuid[]) or (select app.has_any_role('{ADMIN_CS}')))
              and storage_path like customer_id::text || '/req/' || request_id::text || '/%');

-- ---- POLICY: work order & anak (pelanggan TIDAK punya akses tabel mentah; lihat view customer_*) -----------------------------------
create policy work_orders_staff on public.work_orders for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,FINANCE,OWNER}')));
create policy work_orders_tech on public.work_orders for select to authenticated
  using (id in (select app.my_active_wo_ids()));
create policy wo_status_history_tech on public.wo_status_history for select to authenticated
  using (wo_id in (select app.my_active_wo_ids()));
create policy wo_assignments_select on public.wo_assignments for select to authenticated
  using ((select app.has_any_role('{ADMIN_CS,DISPATCHER,SUPERVISOR,OWNER}')) or wo_id in (select app.my_active_wo_ids()));
create policy wo_visits_tech on public.wo_visits for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_checklist_items_tech on public.wo_checklist_items for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_photo_requirements_tech on public.wo_photo_requirements for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_findings_tech on public.wo_findings for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_attachments_tech on public.wo_attachments for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy wo_signatures_tech on public.wo_signatures for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy service_reports_tech on public.service_reports for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
-- (wo_labor_lines, wo_part_usages, extra_cost_*: teknisi membaca lewat view tech_* tanpa harga)

-- tulis lapangan oleh teknisi: hanya WO yang ia tangani & statusnya mengizinkan
create policy wo_checklist_items_update_tech on public.wo_checklist_items for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
create policy wo_findings_insert_tech on public.wo_findings for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)));
create policy wo_findings_update_tech on public.wo_findings for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
create policy wo_attachments_insert_tech on public.wo_attachments for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)) and storage_path like app.wo_storage_prefix(wo_id) || '%');
create policy wo_attachments_update_tech on public.wo_attachments for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
create policy wo_signatures_insert_tech on public.wo_signatures for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)) and signed_via = 'TECH_DEVICE' and signer_type = 'CUSTOMER'
              and storage_path like app.wo_storage_prefix(wo_id) || '%');
create policy wo_labor_lines_insert_tech on public.wo_labor_lines for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)));
create policy wo_labor_lines_update_tech on public.wo_labor_lines for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
create policy wo_part_usages_insert_tech on public.wo_part_usages for insert to authenticated
  with check ((select app.can_edit_wo(wo_id)));
create policy wo_part_usages_update_tech on public.wo_part_usages for update to authenticated
  using ((select app.can_edit_wo(wo_id))) with check ((select app.can_edit_wo(wo_id)));
-- SPV: koreksi pemakaian dengan alasan (matriks) lewat tombstone
create policy wo_part_usages_update_spv on public.wo_part_usages for update to authenticated
  using ((select app.has_any_role('{SUPERVISOR}'))) with check ((select app.has_any_role('{SUPERVISOR}')));

-- ---- POLICY: stok teknisi, retur, selisih (sisi teknisi) -----------------------------------------------------------------------------
create policy stock_locations_tech on public.stock_locations for select to authenticated using (id in (select app.my_location_ids()));
create policy stock_balances_tech on public.stock_balances for select to authenticated using (location_id in (select app.my_location_ids()));
create policy stock_movements_tech on public.stock_movements for select to authenticated
  using (from_location_id in (select app.my_location_ids()) or to_location_id in (select app.my_location_ids()));
create policy part_requests_tech on public.part_requests for select to authenticated using (wo_id in (select app.my_active_wo_ids()));
create policy part_request_lines_tech on public.part_request_lines for select to authenticated
  using (request_id in (select pr.id from public.part_requests pr where pr.wo_id in (select app.my_active_wo_ids())));
create policy part_returns_tech on public.part_returns for select to authenticated using (technician_id = (select app.my_technician_id()));
create policy part_return_lines_tech on public.part_return_lines for select to authenticated
  using (return_id in (select r.id from public.part_returns r where r.technician_id = (select app.my_technician_id())));
create policy parts_variances_tech on public.parts_variances for select to authenticated using (technician_id = (select app.my_technician_id()));

-- ---- POLICY: umpan balik pelanggan, penagihan pelanggan ------------------------------------------------------------------------------
create policy ratings_customer on public.ratings for select to authenticated using (customer_id = any ((select app.my_customer_ids())::uuid[]));
create policy ratings_insert_customer on public.ratings for insert to authenticated
  with check (customer_id = any ((select app.my_customer_ids())::uuid[]));       -- customer_id diisi trigger dari WO (BEFORE INSERT), lalu dicek di sini
create policy complaints_customer on public.complaints for select to authenticated using (customer_id = any ((select app.my_customer_ids())::uuid[]));
create policy complaints_insert_customer on public.complaints for insert to authenticated
  with check (customer_id = any ((select app.my_customer_ids())::uuid[]));       -- customer_id diisi trigger tg_feedback_before_insert
create policy complaints_update_staff on public.complaints for update to authenticated
  using ((select app.has_any_role('{ADMIN_CS,SUPERVISOR}'))) with check ((select app.has_any_role('{ADMIN_CS,SUPERVISOR}')));
create policy invoices_customer on public.invoices for select to authenticated
  using (customer_id = any ((select app.my_customer_ids())::uuid[]) and status in ('ISSUED','PAID'));
create policy invoice_lines_customer on public.invoice_lines for select to authenticated
  using (invoice_id in (select i.id from public.invoices i where i.customer_id = any ((select app.my_customer_ids())::uuid[]) and i.status in ('ISSUED','PAID')));
create policy payments_customer on public.payments for select to authenticated
  using (invoice_id in (select i.id from public.invoices i where i.customer_id = any ((select app.my_customer_ids())::uuid[])));

-- ---- POLICY: lintas sektor ------------------------------------------------------------------------------------------------------------
create policy notifications_own on public.notifications for select to authenticated using (user_id = (select auth.uid()));
create policy notifications_update_own on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy notification_prefs_own on public.notification_prefs for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy sync_operations_own on public.sync_operations for select to authenticated using (user_id = (select auth.uid()));
create policy sync_operations_insert_own on public.sync_operations for insert to authenticated with check (user_id = (select auth.uid()));
create policy audit_logs_owner on public.audit_logs for select to authenticated using ((select app.has_any_role('{OWNER}')));
create policy audit_logs_supervisor on public.audit_logs for select to authenticated
  using ((select app.has_any_role('{SUPERVISOR}'))
         and entity_type in ('work_orders','wo_assignments','extra_cost_approvals','wo_signatures','service_requests','parts_variances'));

-- ---- Storage: bucket privat + policy baca; TIDAK ada policy tulis (unggah lewat signed upload URL dari server) ----------------------------
do $$
begin
  if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('wo-media', 'wo-media', false, null, array['image/jpeg','image/png','image/webp'])    -- file_size_limit: isi dari keputusan [P] (NFR-S7)
    on conflict (id) do update set public = false;
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('reports', 'reports', false, null, array['application/pdf'])
    on conflict (id) do update set public = false;
    execute $p$create policy vasta_media_read on storage.objects for select to authenticated
               using (bucket_id in ('wo-media','reports') and (select app.can_read_object(bucket_id, name)))$p$;
  else
    raise notice 'schema storage tidak ada: bucket & policy Storage dilewati (lingkungan non-Supabase).';
  end if;
end $$;
