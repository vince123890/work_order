-- ===== MIGRATION 0011: view =========================================================
-- View pelanggan: SECURITY DEFINER (default) + security_barrier. Pelanggan TIDAK punya akses ke tabel mentah
-- work_orders/wo_*; semua pembacaan lewat view ini yang menyaring customer_id = ANY(app.my_customer_ids())
-- dan hanya mengekspos kolom aman + status yang sudah dipetakan (AP-3, 4.2).

create or replace view public.customer_requests with (security_barrier = true) as
select sr.id as request_id, sr.request_no, sr.customer_id, sr.site_id, sr.asset_id, sr.problem_type_id, sr.description,
       sr.preferred_start, sr.preferred_end, sr.channel, sr.created_at as requested_at, sr.client_request_id,
       sr.version as request_version, (sr.duplicate_of is not null) as possible_duplicate,
       w.id as wo_id, w.wo_number,
       case when w.id is not null then app.customer_status(w.status)
            when sr.status = 'REJECTED' then 'UNPROCESSABLE'
            when sr.status = 'CANCELLED_BY_CUSTOMER' then 'CANCELLED'
            else 'RECEIVED' end as display_status,
       (sr.status = 'NEEDS_INFO') as needs_info,
       coalesce(w.customer_note, case sr.status when 'NEEDS_INFO' then sr.needs_info_note
                                                when 'REJECTED' then sr.decision_reason end) as status_note
from public.service_requests sr
left join public.work_orders w on w.request_id = sr.id
where sr.customer_id = any ((select app.my_customer_ids())::uuid[]);

create or replace view public.customer_work_orders with (security_barrier = true) as
select w.id as wo_id, w.wo_number, w.type as wo_type, w.customer_id, w.site_id, w.asset_id, w.request_id,
       app.customer_status(w.status) as display_status,
       case when w.status = 'CANCELLED' then coalesce(w.cancel_reason, w.customer_note) else w.customer_note end as status_note,
       (w.status in ('AWAITING_CUSTOMER_APPROVAL','AWAITING_SIGNOFF')) as awaiting_customer_action,
       w.status = 'AWAITING_SIGNOFF' as awaiting_signoff,
       (select a.id from public.extra_cost_approvals a where a.wo_id = w.id and a.status = 'PENDING') as pending_approval_id,
       -- jadwal & nama teknisi baru tampil setelah teknisi menerima (DEC-02)
       case when w.status not in ('NEW','ASSIGNED','CANCELLED') then w.scheduled_start end as scheduled_start,
       case when w.status not in ('NEW','ASSIGNED','CANCELLED') then w.scheduled_end end as scheduled_end,
       case when w.status not in ('NEW','ASSIGNED','CANCELLED') then
         (select p.full_name from public.wo_assignments x join public.technicians t on t.id = x.technician_id
            join public.profiles p on p.user_id = t.user_id
           where x.wo_id = w.id and x.role = 'LEAD' and x.status in ('ACCEPTED','COMPLETED') limit 1) end as technician_name,
       w.requested_at, w.closed_at, w.cancel_requested_at, w.version as wo_version,
       (w.status = 'CLOSED' and exists (select 1 from public.ratings r where r.wo_id = w.id)) as rated
from public.work_orders w
where w.customer_id = any ((select app.my_customer_ids())::uuid[]);

create or replace view public.customer_wo_timeline with (security_barrier = true) as
select h.wo_id, h.at, app.customer_status(h.to_status) as display_status, h.customer_note
from public.wo_status_history h
join public.work_orders w on w.id = h.wo_id
where w.customer_id = any ((select app.my_customer_ids())::uuid[])
  and (h.from_status is null or app.customer_status(h.from_status) is distinct from app.customer_status(h.to_status));

create or replace view public.customer_extra_cost_approvals with (security_barrier = true) as
select a.id as approval_id, a.wo_id, a.version_no, a.status, a.total, a.reason, a.requested_at, a.expires_at, a.content_hash,
       (select coalesce(jsonb_agg(jsonb_build_object('kind', i.kind, 'description', i.description, 'qty', i.qty,
                'unit_price', i.unit_price, 'subtotal', i.subtotal) order by i.description), '[]'::jsonb)
          from public.extra_cost_approval_items i where i.approval_id = a.id) as items
from public.extra_cost_approvals a
join public.work_orders w on w.id = a.wo_id
where w.customer_id = any ((select app.my_customer_ids())::uuid[]) and a.status <> 'SUPERSEDED';

-- Foto laporan: hanya foto BEFORE/AFTER/FINDING yang sudah UPLOADED dari WO CLOSED (FR-056, matriks "foto laporan").
create or replace view public.customer_wo_photos with (security_barrier = true) as
select x.id as attachment_id, x.wo_id, x.kind, x.storage_path, x.taken_at
from public.wo_attachments x
join public.work_orders w on w.id = x.wo_id
where w.customer_id = any ((select app.my_customer_ids())::uuid[]) and w.status = 'CLOSED'
  and x.deleted_at is null and x.upload_status = 'UPLOADED' and x.kind in ('BEFORE','AFTER','FINDING');

create or replace view public.customer_service_reports with (security_barrier = true) as
select r.id as report_id, r.wo_id, r.revision, r.storage_path, r.generated_at, r.sent_at
from public.service_reports r
join public.work_orders w on w.id = r.wo_id
where r.customer_id = any ((select app.my_customer_ids())::uuid[]) and w.status = 'CLOSED' and r.status = 'READY';

-- Riwayat servis aset untuk teknisi (AP-2): hanya aset dari WO aktifnya, tanpa harga/catatan internal.
create or replace view public.v_tech_asset_service_history with (security_barrier = true) as
select w.asset_id, w.id as wo_id, w.wo_number, w.type as wo_type, w.closed_at, f.diagnosis, f.action_taken
from public.work_orders w
left join public.wo_findings f on f.wo_id = w.id
where w.status = 'CLOSED' and w.asset_id in (select app.tech_asset_ids());

-- View operasional (RLS pemanggil berlaku: security_invoker).
create or replace view public.v_today_work_orders with (security_invoker = true) as
select w.id as wo_id, w.wo_number, w.type, w.status, w.priority_code, w.customer_id, w.asset_id, w.scheduled_start, w.scheduled_end,
       w.response_sla_state, w.resolution_sla_state, w.response_due_at, w.resolution_due_at,
       (select a.technician_id from public.wo_assignments a where a.wo_id = w.id and a.role = 'LEAD'
          and a.status in ('ASSIGNED','ACCEPTED') limit 1) as lead_technician_id
from public.work_orders w
where w.status not in ('CLOSED','CANCELLED');

create or replace view public.v_open_part_variances with (security_invoker = true) as
select pv.* from public.parts_variances pv where pv.status = 'OPEN';

create or replace view public.v_job_health with (security_invoker = true) as
select distinct on (job_name) job_name, started_at, finished_at, status, rows_affected, error
from public.job_runs order by job_name, started_at desc;

-- Antrean Finance (L3 ringkas): WO CLOSED yang siap ditagih dan belum punya baris invoice (SP-05b).
create or replace view public.v_finance_ready_to_bill with (security_invoker = true) as
select w.id as wo_id, w.wo_number, w.customer_id, w.billing_type, w.closed_at
from public.work_orders w
where w.status = 'CLOSED' and w.billing_status = 'PENDING'
  and not exists (select 1 from public.invoice_lines il where il.wo_id = w.id);

-- M2: % WO selesai dalam SLA per bulan (contoh KPI; dashboard lain = TODO Lapis 3).
create or replace view public.v_kpi_sla_monthly with (security_invoker = true) as
select date_trunc('month', w.closed_at) as month, count(*) as closed_total,
       count(*) filter (where w.resolution_sla_state = 'MET') as within_sla,
       count(*) filter (where w.resolution_sla_state = 'MET_LATE') as late
from public.work_orders w
where w.status = 'CLOSED' and w.resolution_sla_state in ('MET','MET_LATE')
group by 1;
-- TODO Lapis 3: v_kpi_technician_productivity, v_kpi_asset_recurrence, v_kpi_contract_profit (butuh sumber biaya, R18/Q19),
--               v_kpi_request_to_assignment (M1), v_kpi_close_to_invoice (M3), v_kpi_pm_ontime (M4), v_kpi_parts_variance (M6).
