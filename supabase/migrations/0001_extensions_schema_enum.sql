-- ===== MIGRATION 0001: extensions, schema, enum ===============================
-- Supabase: extension di-schema "extensions" (jangan di public: 0013 mencabut EXECUTE fungsi public dari PUBLIC).
create schema if not exists extensions;
do $ext$
begin
  begin
    create extension if not exists pg_trgm with schema extensions;   -- pencarian teks (Lapis 3 + indeks nama)
  exception when others then
    raise notice 'pg_trgm tidak tersedia; indeks trigram akan dilewati (lihat 0012).';
  end;
  begin
    create extension if not exists pg_cron;       -- penjadwalan (0014). Supabase: aktifkan juga lewat dashboard.
  exception when others then
    raise notice 'pg_cron tidak tersedia; jadwal 0014 akan dilewati.';
  end;
end
$ext$;

create schema if not exists app;
comment on schema app is 'Fungsi internal VASTA. Tidak diekspos lewat PostgREST. Jangan masukkan ke exposed schemas.';

-- Peran (8 peran sesuai 02 bagian 1; CUSTOMER disimpan di user_roles juga).
create type public.app_role as enum
  ('CUSTOMER','ADMIN_CS','DISPATCHER','TECHNICIAN','SUPERVISOR','WAREHOUSE','FINANCE','OWNER');
create type public.customer_role as enum ('ADMIN','MEMBER');
create type public.customer_type as enum ('CORPORATE','INDIVIDUAL');

create type public.request_status as enum
  ('SUBMITTED','NEEDS_INFO','REJECTED','CONVERTED','CANCELLED_BY_CUSTOMER');
create type public.request_channel as enum ('PWA','PHONE','CHAT','OTHER');
create type public.decision_source as enum ('USER','SYSTEM_RULE');

create type public.wo_type as enum ('CORRECTIVE','PREVENTIVE','REWORK');
create type public.wo_status as enum
  ('NEW','ASSIGNED','ACCEPTED','EN_ROUTE','IN_PROGRESS','ON_HOLD_PARTS',
   'AWAITING_CUSTOMER_APPROVAL','AWAITING_SIGNOFF','UNDER_REVIEW','RETURNED','CLOSED','CANCELLED');
create type public.wo_outcome as enum ('RESOLVED','PARTIAL','UNRESOLVED');
create type public.billing_type as enum ('BILLABLE','WARRANTY','COVERED_CONTRACT','WARRANTY_WORK');
create type public.billing_status as enum ('NOT_BILLABLE','PENDING','INVOICED','PAID');

create type public.assignment_role as enum ('LEAD','HELPER');
create type public.assignment_status as enum
  ('ASSIGNED','ACCEPTED','REJECTED','REASSIGNED','RELEASED','COMPLETED','CANCELLED');
create type public.visit_result as enum ('COMPLETED','FAILED_ABSENT','FAILED_OTHER','HANDOVER');

create type public.attachment_kind as enum ('BEFORE','AFTER','FINDING','OTHER','FAILED_VISIT');
create type public.upload_status as enum ('PENDING','UPLOADED','FAILED');
create type public.signature_status as enum ('VALID','SUPERSEDED');
create type public.signed_via as enum ('TECH_DEVICE','CUSTOMER_PWA');
create type public.signer_type as enum ('CUSTOMER','TECHNICIAN');

create type public.approval_status as enum ('PENDING','APPROVED','REJECTED','EXPIRED','SUPERSEDED');
create type public.decision_channel as enum ('PWA','PHONE','CHAT','OTHER');
create type public.extra_item_kind as enum ('LABOR','PART','OTHER');

create type public.contract_status as enum ('DRAFT','ACTIVE','EXPIRED','TERMINATED');
create type public.pm_frequency as enum ('MONTHLY','QUARTERLY','YEARLY');
create type public.pm_period_status as enum ('GENERATED','COMPLETED','MISSED','SKIPPED');

create type public.sla_state as enum
  ('NOT_TRACKED','RUNNING','WARNING','BREACHED','MET','MET_LATE','PAUSED');
create type public.sla_event_kind as enum
  ('RESPONSE_WARNING','RESPONSE_BREACH','RESOLUTION_WARNING','RESOLUTION_BREACH','PM_MISSED');
create type public.sla_response_event as enum ('ACCEPT','DEPART','CHECK_IN');
create type public.sla_resolution_event as enum ('SUBMIT','CLOSE');

create type public.stock_location_type as enum ('WAREHOUSE','TECHNICIAN','VEHICLE');
create type public.stock_movement_type as enum
  ('RECEIPT','ISSUE_TO_TECH','RETURN_FROM_TECH','CONSUME_ON_WO','ADJUSTMENT','TRANSFER');
create type public.item_tracking_mode as enum ('PER_WO','BULK');
create type public.part_request_status as enum
  ('REQUESTED','APPROVED','PARTIALLY_ISSUED','ISSUED','REJECTED','CANCELLED');
create type public.return_status as enum ('PENDING','CONFIRMED','REJECTED');
create type public.variance_status as enum
  ('OPEN','EXPLAINED','RETURNED_LATE','WRITTEN_OFF','CHARGED_TO_CUSTOMER');

create type public.invoice_type as enum ('WO','CONTRACT_PERIODIC');
create type public.invoice_status as enum ('DRAFT','ISSUED','PAID','VOID');

create type public.notification_channel as enum ('IN_APP','EMAIL','WHATSAPP','PUSH');
create type public.notification_status as enum ('PENDING','SENT','FAILED','READ');
create type public.sync_op_status as enum ('RECEIVED','APPLIED','REJECTED','RESCUED');
create type public.report_status as enum ('GENERATING','READY','FAILED');
create type public.job_status as enum ('RUNNING','OK','ERROR');
create type public.import_status as enum ('UPLOADED','VALIDATED','COMMITTED','FAILED');
