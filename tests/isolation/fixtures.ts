// Data uji isolasi (WP-007). Idempoten; semua baris bertanda '[UJI ISOLASI]' (atau awalan 'UJI-ISO' pada kode unik).
//
// Dua lapis:
//  (1) WO dasar A dan B dibuat lewat API nyata (JWT pengguna): permintaan -> request_decide -> ASSIGN.
//  (2) "Kit" kaya data per pelanggan dibuat lewat SQL superuser (DATABASE_URL) karena banyak status/tabel
//      tidak bisa dicapai lewat RPC tanpa alur lapangan penuh. Jalan pintas yang dipakai (dicatat di handoff):
//        - WO disisipkan langsung dengan status tujuan (tidak ada pemicu INSERT yang melarangnya);
//        - app.tx_active='on' (lokal transaksi) hanya untuk menandai permintaan menjadi CONVERTED;
//        - app.revision_mode='on' (lokal transaksi) agar anak WO (foto, tanda tangan, jasa, pemakaian) bisa
//          disisipkan ke WO berstatus CLOSED. TIDAK memakai session_replication_role.
//      Skenario REASSIGN memakai RPC wo_transition nyata (ASSIGN lalu REASSIGN oleh dispatcher).
import { randomBytes } from "node:crypto";
import type pg from "pg";
import {
  api,
  login,
  newDb,
  rest,
  rowsOf,
  rpc,
  setRuntimePassword,
  withDb,
  DOMAIN,
} from "./helpers";

export type Kit = {
  cust: string;
  asset: string;
  site: string;
  techId: string;
  userId: string; // user pelanggan
  // WO per status
  woNew: string;
  woReview: string;
  woAwait: string;
  woClosed: string;
  woReassign: string;
  woProgress: string; // IN_PROGRESS, LEAD ACCEPTED (uji declare_no_parts, biaya tambahan, konkurensi)
  woSign: string; // AWAITING_SIGNOFF (uji path tanda tangan)
  woTagih: string; // CLOSED, billing PENDING, tanpa invoice_lines (v_finance_ready_to_bill)
  sigRegPath: string; // path sig/ yang terdaftar di wo_attachments pada woSign
  reqSubmitted: string;
  reqClosed: string;
  // objek pada WO CLOSED
  attAfter: { id: string; path: string };
  attOther: { id: string; path: string };
  attPending: { id: string; path: string };
  attNotClosed: { id: string; path: string }; // AFTER/UPLOADED tetapi WO belum CLOSED
  attFailed: { id: string; path: string }; // FAILED_VISIT/UPLOADED pada WO CLOSED
  sigPath: string;
  reportPath: string;
  reqAttach: { id: string; path: string };
  // persetujuan biaya tambahan (WO woAwait)
  approvalId: string;
  approvalHash: string;
  // penagihan
  invIssued: string;
  invDraft: string;
  payIssued: string;
  payDraft: string;
  contractId: string;
  laborId: string;
  usageId: string;
};

export type Fixture = {
  custA: string;
  custB: string;
  assetA: string;
  assetB: string;
  siteA: string;
  siteB: string;
  ptAC: string;
  stAC: string;
  woA: string;
  woB: string;
  reqA: string;
  reqB: string;
  tech1: string;
  tech2: string;
  kitA: Kit;
  kitB: Kit;
  ids: {
    admin: string;
    owner: string;
    userA: string;
    userB: string;
    tek1: string;
    tek2: string;
    nonaktif: string;
    tanpaPelanggan: string;
    multi: string;
    targetPeran: string;
  };
  emails: { nonaktif: string; tanpaPelanggan: string; targetPeran: string; multi: string };
  storageRows: boolean; // baris storage.objects tersisip (untuk uji signed URL)
  stockLocation: string;
};

const CRID_A = "11111111-1111-4111-8111-aaaaaaaaaaa1";
const CRID_B = "11111111-1111-4111-8111-bbbbbbbbbbb1";

async function ensureWo(
  custKey: string,
  assetCode: string,
  crid: string,
  techId: string,
  ptId: string,
  stId: string,
) {
  const cust = await login(custKey);
  const admin = await login("admin");
  const disp = await login("dispatcher");

  const asset = rowsOf(
    await rest(cust, `assets?select=id,site_id,customer_id&asset_code=eq.${assetCode}`),
  )[0];
  if (!asset) throw new Error(`aset ${assetCode} tidak terlihat oleh ${custKey}`);

  let req = rowsOf(
    await rest(admin, `service_requests?select=id,status,version&client_request_id=eq.${crid}`),
  )[0];
  if (!req) {
    const ins = await rest(cust, "service_requests", {
      method: "POST",
      prefer: "return=minimal",
      body: {
        customer_id: asset.customer_id,
        site_id: asset.site_id,
        asset_id: asset.id,
        problem_type_id: ptId,
        description: "[UJI ISOLASI] AC tidak dingin",
        client_request_id: crid,
      },
    });
    if (ins.status !== 201) throw new Error(`insert permintaan gagal: ${JSON.stringify(ins.body)}`);
    req = rowsOf(
      await rest(admin, `service_requests?select=id,status,version&client_request_id=eq.${crid}`),
    )[0];
  }
  if (!req) throw new Error("permintaan tidak ditemukan setelah insert");

  let wo = rowsOf(
    await rest(admin, `work_orders?select=id,status,version&request_id=eq.${req.id}`),
  )[0];
  if (!wo) {
    const dec = await rpc(admin, "request_decide", {
      p_request_id: req.id,
      p_decision: "APPROVE",
      p_priority_code: "NORMAL",
      p_service_type_id: stId,
      p_expected_version: req.version,
    });
    if (dec.status !== 200) throw new Error(`request_decide gagal: ${JSON.stringify(dec.body)}`);
    wo = rowsOf(
      await rest(admin, `work_orders?select=id,status,version&request_id=eq.${req.id}`),
    )[0];
  }
  if (!wo) throw new Error("WO tidak terbentuk");

  if (wo.status === "NEW") {
    const start = new Date(Date.now() + 86_400_000).toISOString();
    const end = new Date(Date.now() + 90_000_000).toISOString();
    const as = await rpc(disp, "wo_transition", {
      p_wo_id: wo.id,
      p_action: "ASSIGN",
      p_expected_version: wo.version,
      p_payload: { technician_id: techId, scheduled_start: start, scheduled_end: end },
    });
    if (as.status !== 200) throw new Error(`ASSIGN gagal: ${JSON.stringify(as.body)}`);
  }
  return { asset, reqId: String(req.id), woId: String(wo.id) };
}

// ---------------------------------------------------------------------------------------------
// Akun uji khusus (dibuat lewat SQL seperti tools/seed.mjs). Kata sandi diacak tiap proses uji dan
// hanya disimpan di memori. Akun ini PERLU dibersihkan manual bila proyek uji dihapus (lihat handoff).
// ---------------------------------------------------------------------------------------------
async function ensureTestUser(
  db: pg.Client,
  local: string,
  fullName: string,
  role: string,
  customerId: string | null,
): Promise<string> {
  const email = `${local}@${DOMAIN}`;
  const password = randomBytes(18).toString("base64url");
  const ex = await db.query("select id from auth.users where email = $1", [email]);
  let id: string;
  if (ex.rows[0]) {
    id = String(ex.rows[0].id);
    await db.query(
      "update auth.users set encrypted_password = extensions.crypt($1, extensions.gen_salt('bf')), updated_at = now() where id = $2",
      [password, id],
    );
  } else {
    const r = await db.query(
      `insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
         raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
         confirmation_token, recovery_token, email_change_token_new, email_change)
       values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', $1,
         extensions.crypt($2, extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', $3::text), now(), now(),
         '', '', '', '')
       returning id`,
      [email, password, fullName],
    );
    id = String(r.rows[0].id);
    await db.query(
      `insert into auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
       values (gen_random_uuid(), $1::uuid, jsonb_build_object('sub', $1::uuid::text, 'email', $2::text, 'email_verified', true),
         'email', $1::uuid::text, now(), now(), now())`,
      [id, email],
    );
  }
  const prof = await db.query("select 1 from public.profiles where user_id = $1", [id]);
  if (!prof.rows[0]) throw new Error(`profil untuk ${email} tidak terbentuk oleh pemicu auth`);
  // akun uji milik fixture ini: pulihkan ke peran tunggal yang dimaksud (menyembuhkan sisa uji yang terhenti)
  await db.query(
    "delete from public.user_roles where user_id = $1 and role <> $2::public.app_role",
    [id, role],
  );
  await db.query(
    "insert into public.user_roles (user_id, role) values ($1, $2::public.app_role) on conflict (user_id, role) do nothing",
    [id, role],
  );
  if (customerId) {
    await db.query(
      `insert into public.customer_users (customer_id, user_id, customer_role)
       values ($1, $2, 'MEMBER') on conflict (customer_id, user_id) do nothing`,
      [customerId, id],
    );
  }
  setRuntimePassword(email, password);
  return id;
}

// ---------------------------------------------------------------------------------------------
// Kit kaya data per pelanggan. Seluruhnya satu blok DO (satu round trip) karena latensi pooler tinggi.
// Nilai yang disisipkan ke teks SQL hanya UUID dari basis data ini dan huruf tetap (divalidasi oleh lit()).
// ---------------------------------------------------------------------------------------------
function lit(v: string): string {
  if (!/^[0-9a-zA-Z_.-]+$/.test(v)) throw new Error(`nilai literal tidak aman: ${v}`);
  return `'${v}'`;
}

type KitBase = {
  cust: string;
  asset: string;
  site: string;
  techId: string;
  userId: string;
  letter: string;
};
type KitCtx = {
  ptId: string;
  stId: string;
  adminId: string;
  itemId: string;
  serviceItemId: string;
};

function kitSql(b: KitBase, c: KitCtx): string {
  return `
do $kit$
declare
  v_cust uuid := ${lit(b.cust)}; v_asset uuid := ${lit(b.asset)}; v_site uuid := ${lit(b.site)};
  v_tech uuid := ${lit(b.techId)}; v_user uuid := ${lit(b.userId)}; v_admin uuid := ${lit(c.adminId)};
  v_pt uuid := ${lit(c.ptId)}; v_st uuid := ${lit(c.stId)}; v_item uuid := ${lit(c.itemId)};
  v_svc uuid := ${lit(c.serviceItemId)}; v_l text := ${lit(b.letter)};
  r record; v_sr uuid; v_wo uuid; v_key text; v_pr uuid; v_ap uuid; v_inv_i uuid; v_inv_d uuid; v_lab uuid;
  v_closed uuid; v_await uuid; v_req_closed uuid; v_prog uuid; v_sign uuid; v_hash text := 'uji-iso-hash-' || ${lit(b.letter)};
begin
  perform set_config('app.revision_mode', 'on', true);
  for r in select * from (values
      ('baru', 'NEW', null, null),
      ('tinjau', 'UNDER_REVIEW', 'ACCEPTED', null),
      ('tunggu-persetujuan', 'AWAITING_CUSTOMER_APPROVAL', 'ACCEPTED', null),
      ('selesai', 'CLOSED', 'COMPLETED', null),
      ('tugas-ulang', 'NEW', null, null),
      ('berjalan', 'IN_PROGRESS', 'ACCEPTED', null),
      ('tanda-tangan', 'AWAITING_SIGNOFF', 'ACCEPTED', null),
      ('selesai-tagih', 'CLOSED', 'COMPLETED', null),
      ('diajukan', null, null, null)) t(tag, status, assign, x) loop
    v_key := 'uji-iso:' || r.tag || ':' || v_cust::text;
    select id into v_sr from public.service_requests where customer_id = v_cust and client_request_id = md5(v_key)::uuid;
    if v_sr is null then
      insert into public.service_requests (customer_id, site_id, asset_id, problem_type_id, description, channel, created_by, client_request_id)
      values (v_cust, v_site, v_asset, v_pt, '[UJI ISOLASI] kasus ' || r.tag, 'PHONE', v_admin, md5(v_key)::uuid) returning id into v_sr;
    end if;
    if r.status is not null then
      select id into v_wo from public.work_orders where request_id = v_sr;
      if v_wo is null then
        insert into public.work_orders (wo_number, type, customer_id, site_id, asset_id, service_type_id, request_id, priority_code, status,
            billing_type, billing_status, estimate_total, requested_at, scheduled_start, scheduled_end, submitted_at, closed_at, outcome,
            customer_note, created_by)
        values (app.next_doc_number('WO'), 'CORRECTIVE', v_cust, v_site, v_asset, v_st, v_sr, 'NORMAL', r.status::public.wo_status,
            'BILLABLE', (case when r.status = 'CLOSED' then 'PENDING' else 'NOT_BILLABLE' end)::public.billing_status,
            1500000, now(),
            case when r.status = 'NEW' then null else now() + interval '1 day' end,
            case when r.status = 'NEW' then null else now() + interval '1 day 1 hour' end,
            case when r.status in ('UNDER_REVIEW', 'CLOSED') then now() end,
            case when r.status = 'CLOSED' then now() end,
            case when r.status = 'CLOSED' then 'RESOLVED'::public.wo_outcome end,
            '[UJI ISOLASI] ' || r.tag, v_admin) returning id into v_wo;
      end if;
      perform set_config('app.tx_active', 'on', true);
      update public.service_requests set status = 'CONVERTED' where id = v_sr and status = 'SUBMITTED';
      perform set_config('app.tx_active', 'off', true);
      if r.assign is not null then
        insert into public.wo_assignments (wo_id, technician_id, role, status, assigned_by, responded_at)
        select v_wo, v_tech, 'LEAD', r.assign::public.assignment_status, v_admin, now()
         where not exists (select 1 from public.wo_assignments where wo_id = v_wo and technician_id = v_tech);
      end if;
      if r.tag = 'selesai' then v_closed := v_wo; v_req_closed := v_sr; end if;
      if r.tag = 'tunggu-persetujuan' then v_await := v_wo; end if;
      if r.tag = 'berjalan' then v_prog := v_wo; end if;
      if r.tag = 'tanda-tangan' then v_sign := v_wo; end if;
    end if;
  end loop;

  -- foto pada WO CLOSED: AFTER/UPLOADED (sah), OTHER/UPLOADED (tak boleh dilihat pelanggan), BEFORE/PENDING
  insert into public.wo_attachments (wo_id, kind, storage_path, upload_status, mime, bytes, taken_at, taken_by)
  select v_closed, x.kind::public.attachment_kind, v_cust::text || '/wo/' || v_closed::text || '/' || x.f, x.st::public.upload_status,
         'image/jpeg', 4, now(), v_admin
    from (values ('AFTER', 'UPLOADED', 'after-uji.jpg'), ('OTHER', 'UPLOADED', 'other-uji.jpg'),
                 ('BEFORE', 'PENDING', 'before-pending-uji.jpg'),
                 ('FAILED_VISIT', 'UPLOADED', 'failed-visit-uji.jpg')) x(kind, st, f)
  on conflict (storage_path) do nothing;
  insert into public.wo_attachments (wo_id, kind, storage_path, upload_status, mime, bytes, taken_at, taken_by)
  values (v_await, 'AFTER', v_cust::text || '/wo/' || v_await::text || '/after-belum-selesai.jpg', 'UPLOADED', 'image/jpeg', 4, now(), v_admin)
  on conflict (storage_path) do nothing;
  insert into public.wo_signatures (wo_id, signer_type, signer_name, storage_path, content_hash, signed_via, upload_status)
  values (v_closed, 'CUSTOMER', '[UJI ISOLASI] penanda tangan', v_cust::text || '/wo/' || v_closed::text || '/sig-uji.png', '', 'TECH_DEVICE', 'UPLOADED')
  on conflict (storage_path) do nothing;
  insert into public.service_reports (wo_id, customer_id, revision, status, storage_path, snapshot, snapshot_hash, generated_at)
  values (v_closed, v_cust, 1, 'READY', v_cust::text || '/wo/' || v_closed::text || '/laporan-uji.pdf', '{"catatan":"[UJI ISOLASI]"}'::jsonb, 'uji-iso', now())
  on conflict (wo_id, revision) do nothing;
  insert into public.service_reports (wo_id, customer_id, revision, status, snapshot, snapshot_hash)
  values (v_closed, v_cust, 2, 'GENERATING', '{"catatan":"[UJI ISOLASI] revisi belum siap"}'::jsonb, 'uji-iso-2')
  on conflict (wo_id, revision) do nothing;
  insert into public.request_attachments (request_id, customer_id, storage_path, mime, bytes, upload_status, created_by)
  values (v_req_closed, v_cust, v_cust::text || '/req/' || v_req_closed::text || '/lampiran-uji.jpg', 'image/jpeg', 4, 'UPLOADED', v_user)
  on conflict (storage_path) do nothing;

  -- jasa dan suku cadang berharga (BILLABLE) pada WO CLOSED dan pada WO yang sedang berjalan
  insert into public.wo_labor_lines (wo_id, service_item_id, description, qty, unit_price_snapshot, unit_cost_snapshot, billable, created_by)
  select w, v_svc, d, q, 150000, 90000, true, v_admin
    from (values (v_closed, '[UJI ISOLASI] jasa servis', 2), (v_await, '[UJI ISOLASI] jasa berjalan', 1)) x(w, d, q)
   where not exists (select 1 from public.wo_labor_lines l where l.wo_id = x.w and l.description = x.d);
  insert into public.wo_part_usages (wo_id, item_id, technician_id, qty, unit_price_snapshot, unit_cost_snapshot, billable, created_by)
  select w, v_item, v_tech, 1, 500000, 300000, true, v_admin from (values (v_closed), (v_await)) x(w)
   where not exists (select 1 from public.wo_part_usages u where u.wo_id = x.w and u.item_id = v_item);

  -- temuan, kunjungan, checklist, SLA
  insert into public.wo_findings (wo_id, diagnosis, action_taken, recommendation, internal_note)
  values (v_closed, '[UJI ISOLASI] diagnosis', 'ganti kapasitor', 'servis berkala', '[UJI ISOLASI] catatan internal')
  on conflict (wo_id) do nothing;
  insert into public.wo_visits (wo_id, technician_id, check_in_at, check_out_at, result, note)
  select v_closed, v_tech, now() - interval '2 hour', now() - interval '1 hour', 'COMPLETED', '[UJI ISOLASI] kunjungan'
   where not exists (select 1 from public.wo_visits where wo_id = v_closed);
  insert into public.wo_checklist_items (wo_id, seq, label_snapshot, input_type, required)
  select x.w, 9001, '[UJI ISOLASI] butir checklist', 'BOOLEAN', false from (values (v_closed), (v_prog)) x(w)
  on conflict (wo_id, seq) do nothing;
  -- path sig/ yang sudah terdaftar sebagai foto (tidak boleh dipakai sebagai tanda tangan)
  insert into public.wo_attachments (wo_id, kind, storage_path, upload_status, mime, bytes, taken_at, taken_by)
  values (v_sign, 'OTHER', v_cust::text || '/wo/' || v_sign::text || '/sig/terdaftar-uji.png', 'UPLOADED', 'image/png', 4, now(), v_admin)
  on conflict (storage_path) do nothing;
  -- data pembukti untuk view operasional: SLA tercapai (v_kpi_sla_monthly)
  update public.work_orders set resolution_sla_state = 'MET' where id = v_closed and resolution_sla_state = 'NOT_TRACKED';
  insert into public.sla_events (wo_id, kind, level, target) values (v_closed, 'RESPONSE_WARNING', 1, 'ADMIN_CS') on conflict do nothing;
  insert into public.sla_pauses (wo_id, reason, paused_at)
  select v_closed, '[UJI ISOLASI] jeda', now() - interval '3 hour' where not exists (select 1 from public.sla_pauses where wo_id = v_closed);

  -- suku cadang: permintaan, retur, selisih
  select id into v_pr from public.part_requests where wo_id = v_closed and note = '[UJI ISOLASI]';
  if v_pr is null then
    insert into public.part_requests (request_no, wo_id, requested_by, note) values (app.next_doc_number('PR'), v_closed, v_admin, '[UJI ISOLASI]')
    returning id into v_pr;
    insert into public.part_request_lines (request_id, item_id, qty_requested) values (v_pr, v_item, 1);
  end if;
  insert into public.part_returns (wo_id, technician_id, note)
  select v_closed, v_tech, '[UJI ISOLASI]' where not exists (select 1 from public.part_returns where wo_id = v_closed and note = '[UJI ISOLASI]');
  insert into public.parts_variances (wo_id, item_id, technician_id, issued, used) values (v_closed, v_item, v_tech, 2, 1)
  on conflict (wo_id, item_id, technician_id) do nothing;
  update public.parts_variances set status = 'OPEN' where wo_id = v_closed and status is null;     -- v_open_part_variances

  -- persetujuan biaya tambahan PENDING + itemnya (WO menunggu persetujuan)
  insert into public.extra_cost_approvals (wo_id, version_no, status, total, reason, requested_by, expires_at, content_hash)
  values (v_await, 1, 'PENDING', 250000, '[UJI ISOLASI] biaya tambahan', v_admin, now() + interval '3650 days', v_hash)
  on conflict (wo_id, version_no) do nothing;
  select id into v_ap from public.extra_cost_approvals where wo_id = v_await and version_no = 1;
  insert into public.extra_cost_approval_items (approval_id, kind, description, qty, unit_price)
  select v_ap, 'PART', '[UJI ISOLASI] kapasitor', 1, 250000
   where not exists (select 1 from public.extra_cost_approval_items where approval_id = v_ap);

  -- penagihan: invoice ISSUED dan DRAFT, masing-masing dengan pembayaran
  insert into public.invoices (invoice_no, customer_id, status, subtotal, total, issued_at, created_by)
  values ('UJI-ISO-' || v_l || '-ISSUED', v_cust, 'ISSUED', 800000, 800000, now(), v_admin),
         ('UJI-ISO-' || v_l || '-DRAFT', v_cust, 'DRAFT', 800000, 800000, null, v_admin)
  on conflict (invoice_no) do nothing;
  select id into v_inv_i from public.invoices where invoice_no = 'UJI-ISO-' || v_l || '-ISSUED';
  select id into v_inv_d from public.invoices where invoice_no = 'UJI-ISO-' || v_l || '-DRAFT';
  select id into v_lab from public.wo_labor_lines where wo_id = v_closed and description = '[UJI ISOLASI] jasa servis';
  insert into public.invoice_lines (invoice_id, wo_id, source_type, source_id, description, qty, unit_price, amount)
  values (v_inv_i, v_closed, 'LABOR', v_lab, '[UJI ISOLASI] jasa servis', 2, 150000, 300000)
  on conflict (source_type, source_id) do nothing;
  insert into public.payments (invoice_id, amount, paid_at, method, reference, created_by)
  select x.i, 400000, now(), 'TRANSFER', x.ref, v_admin
    from (values (v_inv_i, 'UJI-ISO-' || v_l || '-PAY-ISSUED'), (v_inv_d, 'UJI-ISO-' || v_l || '-PAY-DRAFT')) x(i, ref)
   where not exists (select 1 from public.payments p where p.reference = x.ref);

  -- kontrak
  insert into public.contracts (customer_id, contract_no, start_date, end_date, status, note)
  values (v_cust, 'UJI-ISO-CTR-' || v_l, current_date - 30, current_date + 330, 'ACTIVE', '[UJI ISOLASI]')
  on conflict (contract_no) do nothing;

  -- notifikasi, rating, komplain, operasi sinkron
  insert into public.notifications (user_id, event, channel, wo_id, payload, dedupe_key)
  values (v_user, 'uji.isolasi', 'IN_APP', v_closed, '{"catatan":"[UJI ISOLASI]"}'::jsonb, 'uji-iso:notif:' || v_cust::text)
  on conflict (dedupe_key, channel) where dedupe_key is not null do nothing;
  insert into public.ratings (wo_id, customer_id, customer_user_id, score, comment)
  values (v_closed, v_cust, v_user, 5, '[UJI ISOLASI] bagus') on conflict (wo_id) do nothing;
  insert into public.complaints (wo_id, customer_id, customer_user_id, description)
  select v_closed, v_cust, v_user, '[UJI ISOLASI] komplain'
   where not exists (select 1 from public.complaints where wo_id = v_closed and description = '[UJI ISOLASI] komplain');
  insert into public.sync_operations (op_id, device_id, user_id, wo_id, type, payload)
  values (md5('uji-iso:sync:' || v_cust::text)::uuid, 'uji-iso', v_user, v_closed, 'UJI', '{}'::jsonb) on conflict (op_id) do nothing;
end
$kit$`;
}

async function readKit(db: pg.Client, b: KitBase): Promise<Kit> {
  const one = async (sql: string, params: unknown[]) => {
    const r = await db.query(sql, params);
    if (!r.rows[0]) throw new Error(`data fixture tidak ditemukan: ${sql.slice(0, 80)}`);
    return String(Object.values(r.rows[0])[0]);
  };
  const woOf = (tag: string) =>
    one(
      `select w.id from public.work_orders w join public.service_requests s on s.id = w.request_id
        where s.customer_id = $1 and s.client_request_id = md5($2)::uuid`,
      [b.cust, `uji-iso:${tag}:${b.cust}`],
    );
  const reqOf = (tag: string) =>
    one(
      `select id from public.service_requests where customer_id = $1 and client_request_id = md5($2)::uuid`,
      [b.cust, `uji-iso:${tag}:${b.cust}`],
    );
  const woClosed = await woOf("selesai");
  const woAwait = await woOf("tunggu-persetujuan");
  const att = async (f: string) => {
    const path = `${b.cust}/wo/${woClosed}/${f}`;
    return {
      id: await one("select id from public.wo_attachments where storage_path = $1", [path]),
      path,
    };
  };
  const attOn = async (wo: string, f: string) => {
    const path = `${b.cust}/wo/${wo}/${f}`;
    return {
      id: await one("select id from public.wo_attachments where storage_path = $1", [path]),
      path,
    };
  };
  const reqClosed = await reqOf("selesai");
  const reqAttachPath = `${b.cust}/req/${reqClosed}/lampiran-uji.jpg`;
  const ap = await db.query(
    "select id, content_hash from public.extra_cost_approvals where wo_id = $1 and version_no = 1",
    [woAwait],
  );
  const L = b.letter;
  return {
    cust: b.cust,
    asset: b.asset,
    site: b.site,
    techId: b.techId,
    userId: b.userId,
    woNew: await woOf("baru"),
    woReview: await woOf("tinjau"),
    woAwait,
    woClosed,
    woReassign: await woOf("tugas-ulang"),
    woProgress: await woOf("berjalan"),
    woSign: await woOf("tanda-tangan"),
    woTagih: await woOf("selesai-tagih"),
    sigRegPath: `${b.cust}/wo/${await woOf("tanda-tangan")}/sig/terdaftar-uji.png`,
    reqSubmitted: await reqOf("diajukan"),
    reqClosed,
    attAfter: await att("after-uji.jpg"),
    attOther: await att("other-uji.jpg"),
    attPending: await att("before-pending-uji.jpg"),
    attNotClosed: await attOn(woAwait, "after-belum-selesai.jpg"),
    attFailed: await att("failed-visit-uji.jpg"),
    sigPath: `${b.cust}/wo/${woClosed}/sig-uji.png`,
    reportPath: `${b.cust}/wo/${woClosed}/laporan-uji.pdf`,
    reqAttach: {
      id: await one("select id from public.request_attachments where storage_path = $1", [
        reqAttachPath,
      ]),
      path: reqAttachPath,
    },
    approvalId: String(ap.rows[0].id),
    approvalHash: String(ap.rows[0].content_hash),
    invIssued: await one("select id from public.invoices where invoice_no = $1", [
      `UJI-ISO-${L}-ISSUED`,
    ]),
    invDraft: await one("select id from public.invoices where invoice_no = $1", [
      `UJI-ISO-${L}-DRAFT`,
    ]),
    payIssued: await one("select id from public.payments where reference = $1", [
      `UJI-ISO-${L}-PAY-ISSUED`,
    ]),
    payDraft: await one("select id from public.payments where reference = $1", [
      `UJI-ISO-${L}-PAY-DRAFT`,
    ]),
    contractId: await one("select id from public.contracts where contract_no = $1", [
      `UJI-ISO-CTR-${L}`,
    ]),
    laborId: await one(
      "select id from public.wo_labor_lines where wo_id = $1 and description = '[UJI ISOLASI] jasa servis'",
      [woClosed],
    ),
    usageId: await one("select id from public.wo_part_usages where wo_id = $1 limit 1", [woClosed]),
  };
}

async function ensureKit(base: KitBase, ctx: KitCtx): Promise<Kit> {
  const db = newDb();
  await db.connect();
  try {
    await db.query(kitSql(base, ctx));
    return await readKit(db, base);
  } finally {
    await db.end();
  }
}

/** Tugas ulang lewat RPC nyata: ASSIGN ke teknisi lama lalu REASSIGN ke teknisi baru (oleh dispatcher). */
async function ensureReassign(woId: string, oldTech: string, newTech: string) {
  const disp = await login("dispatcher");
  const admin = await login("admin");
  const cur = rowsOf(await rest(admin, `wo_assignments?select=id,status&wo_id=eq.${woId}`));
  const wo = rowsOf(await rest(admin, `work_orders?select=status,version&id=eq.${woId}`))[0];
  if (!wo) throw new Error("WO tugas-ulang tidak terbaca");
  const base = {
    scheduled_start: new Date(Date.now() + 86_400_000).toISOString(),
    scheduled_end: new Date(Date.now() + 90_000_000).toISOString(),
    override_reason: "[UJI ISOLASI] penugasan uji",
  };
  if (cur.length === 0) {
    const a = await rpc(disp, "wo_transition", {
      p_wo_id: woId,
      p_action: "ASSIGN",
      p_expected_version: wo.version,
      p_payload: { technician_id: oldTech, ...base },
    });
    if (a.status !== 200) throw new Error(`ASSIGN (tugas-ulang) gagal: ${JSON.stringify(a.body)}`);
  }
  if (
    !rowsOf(await rest(admin, `wo_assignments?select=id&wo_id=eq.${woId}&status=eq.REASSIGNED`))
      .length
  ) {
    const wo2 = rowsOf(await rest(admin, `work_orders?select=version&id=eq.${woId}`))[0];
    const r = await rpc(disp, "wo_transition", {
      p_wo_id: woId,
      p_action: "REASSIGN",
      p_expected_version: wo2?.version,
      p_reason: "[UJI ISOLASI] tugas ulang",
      p_payload: { technician_id: newTech, ...base },
    });
    if (r.status !== 200) throw new Error(`REASSIGN gagal: ${JSON.stringify(r.body)}`);
  }
}

async function ensureStorageRows(db: pg.Client, kits: Kit[]): Promise<boolean> {
  try {
    const rows: { bucket: string; name: string; mime: string }[] = [];
    for (const k of kits) {
      for (const path of [
        k.attAfter.path,
        k.attOther.path,
        k.attPending.path,
        k.attNotClosed.path,
        k.attFailed.path,
        k.sigPath,
      ]) {
        rows.push({ bucket: "wo-media", name: path, mime: "image/jpeg" });
      }
      rows.push({ bucket: "reports", name: k.reportPath, mime: "application/pdf" });
    }
    await db.query(
      `insert into storage.objects (bucket_id, name, metadata)
       select x.bucket, x.name, jsonb_build_object('mimetype', x.mime, 'size', 4)
         from jsonb_to_recordset($1::jsonb) as x(bucket text, name text, mime text)
        where not exists (select 1 from storage.objects o where o.bucket_id = x.bucket and o.name = x.name)`,
      [JSON.stringify(rows)],
    );
    return true;
  } catch {
    return false;
  }
}

/**
 * Memulihkan keadaan sementara yang diubah uji (WO berjalan, persetujuan biaya tambahan hasil uji, no_parts_used,
 * operasi sinkron uji). Aman dijalankan berulang; juga menyembuhkan sisa uji yang terhenti di tengah.
 */
export async function resetTransient(db: pg.Client, kits: Kit[]): Promise<void> {
  for (const k of kits) {
    await db.query("begin");
    try {
      await db.query("select set_config('app.tx_active', 'on', true)");
      await db.query(
        `delete from public.extra_cost_approval_items where approval_id in
           (select id from public.extra_cost_approvals where wo_id = $1)`,
        [k.woProgress],
      );
      await db.query("delete from public.extra_cost_approvals where wo_id = $1", [k.woProgress]);
      await db.query(
        "delete from public.sla_pauses where wo_id = $1 and reason <> '[UJI ISOLASI] jeda'",
        [k.woProgress],
      );
      await db.query(
        `update public.work_orders set status = 'IN_PROGRESS', no_parts_used = false, sla_paused_at = null
          where id = $1 and (status <> 'IN_PROGRESS' or no_parts_used or sla_paused_at is not null)`,
        [k.woProgress],
      );
      await db.query("delete from public.sync_operations where device_id = 'uji-iso-transien'");
      await db.query("commit");
    } catch (e) {
      await db.query("rollback");
      throw e;
    }
  }
}

let memo: Promise<Fixture> | undefined;
export function ensureFixture(): Promise<Fixture> {
  memo ??= buildFixture();
  return memo;
}

async function buildFixture(): Promise<Fixture> {
  const admin = await login("admin");
  const pt = rowsOf(await rest(admin, "problem_types?select=id&code=eq.AC-NOT-COLD"))[0];
  const st = rowsOf(await rest(admin, "service_types?select=id&code=eq.SVC-AC"))[0];
  const techs = rowsOf(
    await rest(admin, "technicians?select=id,employee_code&employee_code=in.(DEMO-T1,DEMO-T2)"),
  );
  const t1 = techs.find((t) => t.employee_code === "DEMO-T1");
  const t2 = techs.find((t) => t.employee_code === "DEMO-T2");
  if (!pt || !st || !t1 || !t2)
    throw new Error("seed belum lengkap (jalankan node tools/seed.mjs)");

  // WO dasar lewat API nyata (paralel A dan B)
  const [a, b] = await Promise.all([
    ensureWo("plg-a", "DEMO-A-AC-01", CRID_A, String(t1.id), String(pt.id), String(st.id)),
    ensureWo("plg-b", "DEMO-B-AC-01", CRID_B, String(t2.id), String(pt.id), String(st.id)),
  ]);
  const custA = String(a.asset.customer_id);
  const custB = String(b.asset.customer_id);

  const ids = await withDb(async (db) => {
    const r = await db.query("select email, id from auth.users where email = any($1)", [
      ["admin", "owner", "plg-a", "plg-b", "tek1", "tek2"].map((k) => `${k}@${DOMAIN}`),
    ]);
    const m = new Map(r.rows.map((x) => [String(x.email), String(x.id)]));
    const get = (k: string) => {
      const v = m.get(`${k}@${DOMAIN}`);
      if (!v) throw new Error(`akun ${k} tidak ada`);
      return v;
    };
    return {
      admin: get("admin"),
      owner: get("owner"),
      userA: get("plg-a"),
      userB: get("plg-b"),
      tek1: get("tek1"),
      tek2: get("tek2"),
    };
  });

  // akun uji khusus + master uji (paralel)
  const [nonaktif, tanpa, multi, target, master] = await Promise.all([
    withDb((db) => ensureTestUser(db, "nonaktif", "Akun Nonaktif Uji", "CUSTOMER", custA)),
    withDb((db) =>
      ensureTestUser(db, "tanpa-pelanggan", "Akun Tanpa Pelanggan Uji", "CUSTOMER", null),
    ),
    withDb(async (db) => {
      // pengguna ber-customer_id ganda: terpetakan ke A dan B (uji ANY)
      const id = await ensureTestUser(
        db,
        "multi-pelanggan",
        "Akun Dua Pelanggan Uji",
        "CUSTOMER",
        custA,
      );
      await db.query(
        "insert into public.customer_users (customer_id, user_id, customer_role) values ($1, $2, 'MEMBER') on conflict (customer_id, user_id) do nothing",
        [custB, id],
      );
      return id;
    }),
    withDb(async (db) => {
      const id = await ensureTestUser(db, "target-peran", "Target Peran Uji", "DISPATCHER", null);
      // pulihkan peran target ke keadaan awal (hanya DISPATCHER) bila uji sebelumnya terhenti di tengah
      await db.query("delete from public.user_roles where user_id = $1 and role <> 'DISPATCHER'", [
        id,
      ]);
      return id;
    }),
    withDb(async (db) => {
      // item (BULK agar tidak butuh stok teknisi), jasa, gudang uji, satu mutasi stok, satu access_log
      await db.query(`
        do $m$
        declare v_item uuid; v_loc uuid;
        begin
          insert into public.items (sku, name, unit_cost, unit_price, tracking_mode)
          values ('UJI-ISO-ITEM', '[UJI ISOLASI] kapasitor', 300000, 500000, 'BULK') on conflict (sku) do nothing;
          insert into public.service_items (code, name, unit_price, unit_cost)
          values ('UJI-ISO-SVC', '[UJI ISOLASI] jasa servis', 150000, 90000) on conflict (code) do nothing;
          insert into public.stock_locations (type, name)
          select 'WAREHOUSE', '[UJI ISOLASI] gudang uji'
           where not exists (select 1 from public.stock_locations where name = '[UJI ISOLASI] gudang uji');
          select id into v_item from public.items where sku = 'UJI-ISO-ITEM';
          select id into v_loc from public.stock_locations where name = '[UJI ISOLASI] gudang uji';
          insert into public.stock_movements (item_id, to_location_id, qty, type, note)
          select v_item, v_loc, 10, 'RECEIPT', '[UJI ISOLASI] penerimaan awal'
           where not exists (select 1 from public.stock_movements where note = '[UJI ISOLASI] penerimaan awal');
        end $m$`);
      await db.query(
        `insert into public.access_logs (actor_id, customer_id, resource_type, resource_id, action)
         select $1, $2, '[UJI ISOLASI]', 'uji', 'READ'
          where not exists (select 1 from public.access_logs where resource_type = '[UJI ISOLASI]')`,
        [ids.admin, custA],
      );
      const r = await db.query(
        `select (select id from public.items where sku = 'UJI-ISO-ITEM') as item,
                (select id from public.service_items where code = 'UJI-ISO-SVC') as svc,
                (select id from public.stock_locations where name = '[UJI ISOLASI] gudang uji') as loc`,
      );
      return {
        itemId: String(r.rows[0].item),
        serviceItemId: String(r.rows[0].svc),
        stockLoc: String(r.rows[0].loc),
      };
    }),
  ]);

  const ctx: KitCtx = {
    ptId: String(pt.id),
    stId: String(st.id),
    adminId: ids.admin,
    itemId: master.itemId,
    serviceItemId: master.serviceItemId,
  };
  const [kitA, kitB] = await Promise.all([
    ensureKit(
      {
        cust: custA,
        asset: String(a.asset.id),
        site: String(a.asset.site_id),
        techId: String(t1.id),
        userId: ids.userA,
        letter: "A",
      },
      ctx,
    ),
    ensureKit(
      {
        cust: custB,
        asset: String(b.asset.id),
        site: String(b.asset.site_id),
        techId: String(t2.id),
        userId: ids.userB,
        letter: "B",
      },
      ctx,
    ),
  ]);
  const storageRows = await withDb((db) => ensureStorageRows(db, [kitA, kitB]));
  await withDb(async (db) => {
    // teknisi 2 menjadi HELPER pada WO berjalan milik A (uji peran helper)
    await db.query(
      `insert into public.wo_assignments (wo_id, technician_id, role, status, assigned_by, responded_at)
       select $1, $2, 'HELPER', 'ACCEPTED', $3, now()
        where not exists (select 1 from public.wo_assignments where wo_id = $1 and technician_id = $2)`,
      [kitA.woProgress, String(t2.id), ids.admin],
    );
    await resetTransient(db, [kitA, kitB]);
  });
  await Promise.all([
    ensureReassign(kitA.woReassign, String(t1.id), String(t2.id)),
    ensureReassign(kitB.woReassign, String(t2.id), String(t1.id)),
  ]);

  return {
    custA,
    custB,
    assetA: String(a.asset.id),
    assetB: String(b.asset.id),
    siteA: String(a.asset.site_id),
    siteB: String(b.asset.site_id),
    ptAC: String(pt.id),
    stAC: String(st.id),
    woA: a.woId,
    woB: b.woId,
    reqA: a.reqId,
    reqB: b.reqId,
    tech1: String(t1.id),
    tech2: String(t2.id),
    kitA,
    kitB,
    ids: { ...ids, nonaktif, tanpaPelanggan: tanpa, multi, targetPeran: target },
    emails: {
      nonaktif: `nonaktif@${DOMAIN}`,
      tanpaPelanggan: `tanpa-pelanggan@${DOMAIN}`,
      multi: `multi-pelanggan@${DOMAIN}`,
      targetPeran: `target-peran@${DOMAIN}`,
    },
    storageRows,
    stockLocation: master.stockLoc,
  };
}

export { api };
