-- ===== MIGRATION 0012: indeks (termasuk yang mendukung policy RLS) ====================
-- Indeks FK + akses kueri + predikat RLS. Catatan performa ada di 05_rls_and_security.md.
create index ix_customer_users_user on public.customer_users (user_id) where is_active;        -- app.my_customer_ids()
create index ix_user_roles_role on public.user_roles (role, user_id);                             -- notify_role()
create index ix_customer_sites_customer on public.customer_sites (customer_id);
create index ix_assets_customer on public.assets (customer_id);
create index ix_assets_site on public.assets (site_id);
create index ix_assets_category on public.assets (category_id);
create index ix_contracts_customer on public.contracts (customer_id);
create index ix_contracts_active on public.contracts (status, start_date, end_date);
create index ix_contract_assets_asset on public.contract_assets (asset_id) where is_active;
create index ix_pm_periods_wo on public.pm_periods (wo_id);
create index ix_pm_periods_status on public.pm_periods (status, period_key);
create index ix_problem_types_st on public.problem_types (service_type_id);
create index ix_technician_skills_skill on public.technician_skills (skill_id);

create index ix_sr_customer on public.service_requests (customer_id, created_at desc);
create index ix_sr_queue on public.service_requests (created_at) where status in ('SUBMITTED','NEEDS_INFO');   -- antrean validasi admin
create index ix_sr_dup on public.service_requests (customer_id, asset_id, problem_type_id, created_at desc);
create index ix_sr_asset on public.service_requests (asset_id);
create index ix_req_att_request on public.request_attachments (request_id);
create index ix_req_att_customer on public.request_attachments (customer_id);

create index ix_wo_customer_status on public.work_orders (customer_id, status);                  -- RLS pelanggan + daftar
create index ix_wo_customer_created on public.work_orders (customer_id, created_at desc);
create index ix_wo_active_sched on public.work_orders (scheduled_start) where status not in ('CLOSED','CANCELLED');   -- monitor hari ini
create index ix_wo_status on public.work_orders (status, priority_code);
create index ix_wo_asset_closed on public.work_orders (asset_id, closed_at desc);                -- riwayat aset
create index ix_wo_sla_next on public.work_orders (next_sla_check_at)
  where next_sla_check_at is not null and status not in ('CLOSED','CANCELLED');                   -- job SLA (BR-014)
create index ix_wo_signoff_exp on public.work_orders (signoff_expires_at) where status = 'AWAITING_SIGNOFF';
create index ix_wo_contract on public.work_orders (contract_id);
create index ix_wo_parent on public.work_orders (parent_wo_id) where parent_wo_id is not null;
create index ix_wo_service_type on public.work_orders (service_type_id);

create index ix_wsh_wo on public.wo_status_history (wo_id, at);
create unique index uq_wsh_op on public.wo_status_history (wo_id, op_id) where op_id is not null;   -- idempotensi transisi
create unique index uq_wo_assign_active_lead on public.wo_assignments (wo_id) where role = 'LEAD' and status in ('ASSIGNED','ACCEPTED');
create index ix_wo_assign_tech on public.wo_assignments (technician_id, status) include (wo_id);  -- RLS teknisi: my_active_wo_ids()
create index ix_wo_assign_wo on public.wo_assignments (wo_id);
create index ix_wo_visits_wo on public.wo_visits (wo_id);
create unique index uq_wo_visits_open on public.wo_visits (wo_id, technician_id) where check_out_at is null and check_in_at is not null;
create unique index uq_wo_checklist_op on public.wo_checklist_items (wo_id, op_id) where op_id is not null;
create index ix_wo_att_wo on public.wo_attachments (wo_id, kind) where deleted_at is null;
create unique index uq_wo_att_op on public.wo_attachments (op_id) where op_id is not null;
create index ix_wo_att_approval on public.wo_attachments (extra_approval_id) where extra_approval_id is not null;
create index ix_wo_sig_wo on public.wo_signatures (wo_id, status);
create index ix_wo_labor_wo on public.wo_labor_lines (wo_id) where deleted_at is null;
create unique index uq_wo_labor_op on public.wo_labor_lines (op_id) where op_id is not null;
create index ix_wo_usage_wo on public.wo_part_usages (wo_id) where deleted_at is null;
create index ix_wo_usage_item on public.wo_part_usages (item_id);
create unique index uq_wo_usage_op on public.wo_part_usages (op_id) where op_id is not null;
create index ix_extra_wo on public.extra_cost_approvals (wo_id, status);
create unique index uq_extra_pending on public.extra_cost_approvals (wo_id) where status = 'PENDING';   -- satu PENDING per WO
create index ix_extra_expiry on public.extra_cost_approvals (expires_at) where status = 'PENDING';
create index ix_extra_items_approval on public.extra_cost_approval_items (approval_id);
create index ix_sla_pauses_open on public.sla_pauses (wo_id) where resumed_at is null;
create index ix_reports_customer on public.service_reports (customer_id);
create index ix_ratings_customer on public.ratings (customer_id);
create index ix_complaints_wo on public.complaints (wo_id);
create index ix_complaints_customer on public.complaints (customer_id);

create index ix_sm_item on public.stock_movements (item_id, created_at);
create index ix_sm_wo on public.stock_movements (wo_id, type) where wo_id is not null;
create index ix_sm_from on public.stock_movements (from_location_id) where from_location_id is not null;
create index ix_sm_to on public.stock_movements (to_location_id) where to_location_id is not null;
create index ix_sm_ref on public.stock_movements (ref_type, ref_id);
create index ix_pr_wo on public.part_requests (wo_id, status);
create index ix_prl_item on public.part_request_lines (item_id);
create index ix_returns_wo on public.part_returns (wo_id);
create index ix_variance_open on public.parts_variances (status) where status = 'OPEN';

create index ix_invoices_customer on public.invoices (customer_id);
create index ix_invoice_lines_wo on public.invoice_lines (wo_id);
create index ix_payments_invoice on public.payments (invoice_id);

create index ix_notif_user on public.notifications (user_id, created_at desc) where read_at is null;
create index ix_notif_queue on public.notifications (scheduled_at) where status = 'PENDING';     -- worker pengirim
create unique index uq_notif_dedupe on public.notifications (dedupe_key, channel) where dedupe_key is not null;
create index ix_audit_entity on public.audit_logs (entity_type, entity_id, at desc);
create index ix_audit_actor on public.audit_logs (actor_id, at desc);
create index ix_audit_at_brin on public.audit_logs using brin (at);
create index ix_access_customer on public.access_logs (customer_id, at desc);
create index ix_access_actor on public.access_logs (actor_id, at desc);
create index ix_sync_wo on public.sync_operations (wo_id, status);
create index ix_sync_pending on public.sync_operations (received_at) where status = 'RECEIVED';
create index ix_sync_device on public.sync_operations (user_id, device_id, seq);
create index ix_job_runs on public.job_runs (job_name, started_at desc);
create index ix_invites_customer on public.customer_invitations (customer_id);

-- Pencarian teks (FR-039/L3): hanya bila pg_trgm tersedia.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_trgm') then
    execute 'create index ix_customers_name_trgm on public.customers using gin (name extensions.gin_trgm_ops)';
    execute 'create index ix_assets_code_trgm on public.assets using gin (asset_code extensions.gin_trgm_ops)';
    execute 'create index ix_assets_serial_trgm on public.assets using gin (serial_no extensions.gin_trgm_ops)';
    execute 'create index ix_wo_number_trgm on public.work_orders using gin (wo_number extensions.gin_trgm_ops)';
  end if;
end $$;
