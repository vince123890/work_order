// Uji isolasi data (WP-007, 05 bagian 7.2) terhadap Supabase NYATA lewat API dengan JWT pengguna seed.
// Jalankan: npm run test:isolation   (membuat data uji bertanda [UJI ISOLASI]; lihat fixtures.ts)
// Prinsip: setiap perbandingan lintas pelanggan didahului KONTROL POSITIF (data memang ada dan terbaca oleh
// pemiliknya) agar asersi "0 baris" tidak vakum; kode galat dicek spesifik, bukan sekadar status >= 400.
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type pg from "pg";
import {
  ALLOWED_TABLES,
  CUSTOMER_VIEW_COLUMNS,
  KNOWN_EMPTY_FORBIDDEN,
  MUST_BE_FORBIDDEN,
  PRICE_COLUMNS,
  TECH_VIEW_COLUMNS,
  WO_PRICE_BILLING_COLUMNS,
} from "./catalog";
import { ensureFixture, resetTransient, type Fixture, type Kit } from "./fixtures";
import {
  api,
  asRole,
  deniedWith,
  errShape,
  fetchAll,
  listPublicRelations,
  login,
  newDb,
  pmap,
  rest,
  rowsOf,
  rowsStrict,
  rpc,
  trySql,
  withDb,
  type Res,
} from "./helpers";

let F: Fixture;
let kA: Kit;
let kB: Kit;
let A: string; // JWT pelanggan A
let B: string; // JWT pelanggan B
let T1: string; // teknisi 1 (ditugaskan ke WO A)
let T2: string; // teknisi 2 (ditugaskan ke WO B)
let ADM: string;
let DISP: string;
let OWN: string;
let SPV: string;
let db: pg.Client;

function expectCode(r: Res, codes: string[], label = "") {
  const d = deniedWith(r, codes);
  expect(d.ok, `${label} ${d.info}`).toBe(true);
}

beforeAll(async () => {
  F = await ensureFixture();
  kA = F.kitA;
  kB = F.kitB;
  [A, B, T1, T2, ADM, DISP, OWN, SPV] = await Promise.all([
    login("plg-a"),
    login("plg-b"),
    login("tek1"),
    login("tek2"),
    login("admin"),
    login("dispatcher"),
    login("owner"),
    login("spv"),
  ]);
  db = newDb();
  await db.connect();
}, 300_000);

afterAll(async () => {
  await db?.end();
});

// ------------------------------------------------------------------------------------------------
describe("fixture", () => {
  it("dua WO berbeda milik dua pelanggan berbeda", () => {
    expect(F.woA).not.toBe(F.woB);
    expect(F.custA).not.toBe(F.custB);
    expect(kA.cust).not.toBe(kB.cust);
  });

  it("kedua pelanggan punya data kaya di tabel-tabel utama (dasar kontrol positif)", async () => {
    const q = `
      select 'wo_closed' k, count(*)::int n from public.work_orders where customer_id = $1 and status = 'CLOSED'
      union all select 'wo_attachments_uploaded_after', count(*)::int from public.wo_attachments x join public.work_orders w on w.id = x.wo_id
        where w.customer_id = $1 and w.status = 'CLOSED' and x.kind = 'AFTER' and x.upload_status = 'UPLOADED'
      union all select 'signature_valid', count(*)::int from public.wo_signatures g join public.work_orders w on w.id = g.wo_id
        where w.customer_id = $1 and g.status = 'VALID'
      union all select 'report_ready', count(*)::int from public.service_reports where customer_id = $1 and status = 'READY'
      union all select 'approval_pending', count(*)::int from public.extra_cost_approvals a join public.work_orders w on w.id = a.wo_id
        where w.customer_id = $1 and a.status = 'PENDING'
      union all select 'approval_items', count(*)::int from public.extra_cost_approval_items i join public.extra_cost_approvals a on a.id = i.approval_id
        join public.work_orders w on w.id = a.wo_id where w.customer_id = $1
      union all select 'labor_priced', count(*)::int from public.wo_labor_lines l join public.work_orders w on w.id = l.wo_id
        where w.customer_id = $1 and l.unit_price_snapshot > 0
      union all select 'usage_priced', count(*)::int from public.wo_part_usages u join public.work_orders w on w.id = u.wo_id
        where w.customer_id = $1 and u.unit_price_snapshot > 0
      union all select 'rating', count(*)::int from public.ratings where customer_id = $1
      union all select 'complaint', count(*)::int from public.complaints where customer_id = $1
      union all select 'invoice_issued', count(*)::int from public.invoices where customer_id = $1 and status = 'ISSUED'
      union all select 'invoice_draft', count(*)::int from public.invoices where customer_id = $1 and status = 'DRAFT'
      union all select 'payments', count(*)::int from public.payments p join public.invoices i on i.id = p.invoice_id where i.customer_id = $1
      union all select 'notifications', count(*)::int from public.notifications n join public.customer_users cu on cu.user_id = n.user_id where cu.customer_id = $1
      union all select 'contract', count(*)::int from public.contracts where customer_id = $1
      union all select 'request_attachments', count(*)::int from public.request_attachments where customer_id = $1`;
    for (const cust of [F.custA, F.custB]) {
      const r = await db.query(q, [cust]);
      for (const row of r.rows) expect(row.n, `${row.k} untuk ${cust}`).toBeGreaterThan(0);
    }
    const g = await db.query(
      "select (select count(*)::int from public.stock_movements) sm, (select count(*)::int from public.access_logs) al",
    );
    expect(g.rows[0].sm).toBeGreaterThan(0);
    expect(g.rows[0].al).toBeGreaterThan(0);
  });
});

// ------------------------------------------------------------------------------------------------
describe("Tabel: pelanggan hanya melihat barisnya sendiri (T6, T20)", () => {
  type Sweep = Map<string, Awaited<ReturnType<typeof fetchAll>>>;

  async function sweep(token: string, names: string[]): Promise<Sweep> {
    const res = await pmap(names, (n) => fetchAll(token, n), 6);
    return new Map(names.map((n, i) => [n, res[i] as Awaited<ReturnType<typeof fetchAll>>]));
  }

  function audit(s: Sweep, cust: string | null, userId: string, expectData: boolean): string[] {
    const problems: string[] = [];
    const idsOf = (rel: string, col: string) =>
      new Set((s.get(rel)?.rows ?? []).map((r) => String(r[col])));
    const woIds = idsOf("customer_work_orders", "wo_id");
    for (const [name, r] of s) {
      if (r.status >= 500) problems.push(`${name}: HTTP ${r.status}`);
      if (r.truncated) problems.push(`${name}: terpotong paginasi`);
      const allowed = ALLOWED_TABLES[name];
      if (!allowed) {
        if (r.rows.length > 0)
          problems.push(`${name}: BOCOR ${r.rows.length} baris ke tabel terlarang`);
        continue;
      }
      if (r.status !== 200) problems.push(`${name}: tabel diizinkan tapi HTTP ${r.status}`);
      if (expectData && allowed.expectRows && r.rows.length === 0)
        problems.push(`${name}: kontrol positif gagal (0 baris)`);
      const o = allowed.own;
      for (const row of r.rows) {
        if (o.kind === "cust" && row[o.col] !== cust)
          problems.push(`${name}.${o.col}=${String(row[o.col])}`);
        if (o.kind === "user" && row[o.col] !== userId)
          problems.push(`${name}.${o.col}=${String(row[o.col])}`);
        if (o.kind === "via" && !idsOf(o.from, o.fromCol).has(String(row[o.col])))
          problems.push(
            `${name}.${o.col}=${String(row[o.col])} bukan dari ${o.from} milik sendiri`,
          );
        if (o.kind === "wo" && !woIds.has(String(row[o.col])))
          problems.push(`${name}.${o.col}=${String(row[o.col])} bukan WO milik sendiri`);
      }
    }
    return [...new Set(problems)];
  }

  it("daftar relasi diturunkan dari pg_class; ALLOWED_TABLES dan MUST_BE_FORBIDDEN konsisten (T20)", async () => {
    const rels = (await listPublicRelations()).map((r) => r.name);
    expect(rels.length).toBeGreaterThan(80);
    for (const n of Object.keys(ALLOWED_TABLES)) expect(rels, `ALLOWED ${n}`).toContain(n);
    const forbidden = rels.filter((n) => !(n in ALLOWED_TABLES));
    for (const n of MUST_BE_FORBIDDEN) expect(forbidden, `terlarang ${n}`).toContain(n);
    expect(forbidden.length).toBeGreaterThan(50);
  });

  it.each([
    ["A", () => A, () => F.custA, () => F.ids.userA],
    ["B", () => B, () => F.custB, () => F.ids.userB],
  ])(
    "pelanggan %s: tiap relasi diizinkan hanya memuat barisnya sendiri, sisanya 0 baris",
    async (_n, tok, cust, user) => {
      const rels = (await listPublicRelations()).map((r) => r.name);
      const s = await sweep(tok(), rels);
      expect(audit(s, cust(), user(), true)).toEqual([]);
    },
    300_000,
  );

  it("pengguna ber-customer_id ganda (A dan B): melihat keduanya saja, tidak melihat pelanggan lain (ANY)", async () => {
    const tok = await login(F.emails.multi);
    const other = await db.query(
      "select count(*)::int n from public.assets where customer_id not in ($1, $2)",
      [F.custA, F.custB],
    );
    expect(other.rows[0].n, "kontrol: ada aset pelanggan ketiga di DB").toBeGreaterThan(0);
    const cust = (await fetchAll(tok, "customers", "id")).rows.map((r) => r.id).sort();
    expect(cust).toEqual([F.custA, F.custB].sort());
    const wos = (await fetchAll(tok, "customer_work_orders", "wo_id,customer_id")).rows;
    const ids = wos.map((r) => r.wo_id);
    expect(ids).toEqual(expect.arrayContaining([kA.woClosed, kB.woClosed]));
    for (const r of wos) expect([F.custA, F.custB]).toContain(r.customer_id);
    const assets = (await fetchAll(tok, "assets", "id,customer_id")).rows;
    expect(assets.length).toBeGreaterThan(0);
    for (const r of assets) expect([F.custA, F.custB]).toContain(r.customer_id);
    // identitas ganda terbukti pada sesi DB
    const r = await asRole(db, F.ids.multi, "select app.my_customer_ids() as ids");
    expect((r.rows[0]?.ids as string[]).sort()).toEqual([F.custA, F.custB].sort());
  });

  it("tabel terlarang punya data pembukti di DB (kosong hanya bila tercatat di KNOWN_EMPTY_FORBIDDEN)", async () => {
    const rels = (await listPublicRelations()).filter((r) => r.kind !== "v").map((r) => r.name);
    const forbidden = rels.filter((n) => !(n in ALLOWED_TABLES));
    const sql = forbidden
      .map((n) => `select '${n}' as t, (select count(*) from public."${n}")::int as n`)
      .join(" union all ");
    const counts = (await db.query(sql)).rows.map((r) => [String(r.t), Number(r.n)] as const);
    const empty = counts.filter(([, n]) => n === 0).map(([n]) => n);
    const unexplained = empty.filter((n) => !(n in KNOWN_EMPTY_FORBIDDEN));
    expect(unexplained, "tabel terlarang tanpa data: asersi 0 baris vakum").toEqual([]);
  });

  it("pengguna tanpa pemetaan pelanggan: 0 baris di semua data pelanggan (T16)", async () => {
    const tok = await login(F.emails.tanpaPelanggan);
    const rels = (await listPublicRelations()).map((r) => r.name);
    const s = await sweep(tok, rels);
    // kontrol: token berfungsi (profil sendiri terbaca)
    expect(s.get("profiles")?.rows.map((r) => r.user_id)).toEqual([F.ids.tanpaPelanggan]);
    const leaks: string[] = [];
    for (const [name, r] of s) {
      if (r.status >= 500) leaks.push(`${name}: HTTP ${r.status}`);
      const own = ALLOWED_TABLES[name]?.own;
      // relasi berpemilik pengguna (profil, peran, notifikasi sendiri) boleh memuat baris sendiri saja
      if (own?.kind === "user") {
        for (const row of r.rows)
          if (row[own.col] !== F.ids.tanpaPelanggan) leaks.push(`${name}: baris orang lain`);
        continue;
      }
      if (own?.kind === "katalog") continue;
      if (r.rows.length > 0) leaks.push(`${name}: ${r.rows.length} baris`);
    }
    expect(leaks).toEqual([]);
  }, 300_000);
});

// ------------------------------------------------------------------------------------------------
describe("Tebakan ID (kontrol positif: pemilik membaca, pihak lain 0 baris)", () => {
  const byId = async (tok: string, rel: string, col: string, id: string) =>
    rowsOf(await rest(tok, `${rel}?select=${col}&${col}=eq.${id}`));

  it.each([
    ["assets", "id", (k: Kit) => k.asset],
    ["service_requests", "id", (k: Kit) => k.reqClosed],
    ["customer_work_orders", "wo_id", (k: Kit) => k.woClosed],
    ["request_attachments", "id", (k: Kit) => k.reqAttach.id],
    ["customer_wo_photos", "attachment_id", (k: Kit) => k.attAfter.id],
    ["invoices", "id", (k: Kit) => k.invIssued],
    ["payments", "id", (k: Kit) => k.payIssued],
    ["contracts", "id", (k: Kit) => k.contractId],
    ["ratings", "wo_id", (k: Kit) => k.woClosed],
    ["complaints", "wo_id", (k: Kit) => k.woClosed],
    ["customer_extra_cost_approvals", "approval_id", (k: Kit) => k.approvalId],
    ["customer_service_reports", "wo_id", (k: Kit) => k.woClosed],
  ])(
    "%s: A membaca miliknya, 0 baris untuk ID milik B (dan sebaliknya)",
    async (rel, col, pick) => {
      expect(await byId(A, rel, col, pick(kA)), `kontrol A ${rel}`).toHaveLength(1);
      expect(await byId(B, rel, col, pick(kB)), `kontrol B ${rel}`).toHaveLength(1);
      expect(await byId(A, rel, col, pick(kB)), `A -> B ${rel}`).toHaveLength(0);
      expect(await byId(B, rel, col, pick(kA)), `B -> A ${rel}`).toHaveLength(0);
    },
  );

  it.each([
    "work_orders",
    "wo_attachments",
    "wo_signatures",
    "service_reports",
    "extra_cost_approvals",
  ])(
    "%s: A tidak membaca tabel mentah, bahkan dengan ID WO miliknya sendiri maupun milik B",
    async (rel) => {
      for (const wo of [kA.woClosed, kB.woClosed, kA.woAwait]) {
        const col = rel === "work_orders" ? "id" : "wo_id";
        const r = await rest(A, `${rel}?select=*&${col}=eq.${wo}`);
        expect(r.status, JSON.stringify(r.body)).toBeLessThan(500);
        expect(rowsOf(r)).toHaveLength(0);
      }
    },
  );

  it("A tidak bisa mengubah aset B (0 baris terpengaruh) dan aset B tidak berubah; kontrol: ADMIN_CS bisa menulis", async () => {
    const before = rowsOf(await rest(ADM, `assets?select=brand&id=eq.${F.assetB}`));
    expect(before).toHaveLength(1);
    // kontrol positif: jalur tulis bekerja untuk ADMIN_CS (nilai sama, tanpa perubahan)
    const ctl = await rest(ADM, `assets?id=eq.${F.assetB}`, {
      method: "PATCH",
      prefer: "return=representation",
      body: { brand: before[0]?.brand ?? null },
    });
    expect(ctl.status).toBe(200);
    expect(rowsOf(ctl)).toHaveLength(1);
    const a = await rest(A, `assets?id=eq.${F.assetB}`, {
      method: "PATCH",
      prefer: "return=representation",
      body: { brand: "DIRETAS" },
    });
    expect(a.status, JSON.stringify(a.body)).toBeLessThan(500);
    expect(rowsOf(a)).toHaveLength(0);
    const after = rowsOf(await rest(ADM, `assets?select=brand&id=eq.${F.assetB}`));
    expect(after).toHaveLength(1);
    expect(after[0]?.brand).toBe(before[0]?.brand);
    expect(after[0]?.brand).not.toBe("DIRETAS");
  });

  it("pelanggan tidak punya hak tulis aset sendiri (hanya ADMIN_CS menurut 05 bagian 3.1)", async () => {
    const r = await rest(A, `assets?id=eq.${F.assetA}`, {
      method: "PATCH",
      prefer: "return=representation",
      body: { brand: "DIRETAS" },
    });
    expect(r.status).toBeLessThan(500);
    expect(rowsOf(r)).toHaveLength(0);
    const brand = rowsOf(await rest(ADM, `assets?select=brand&id=eq.${F.assetA}`))[0]?.brand;
    expect(brand).not.toBe("DIRETAS");
  });

  it("kontrol positif tulis: A mengubah permintaan SUBMITTED miliknya (dikembalikan); B tidak bisa mengubah milik A dan sebaliknya", async () => {
    const orig = rowsOf(
      await rest(A, `service_requests?select=description&id=eq.${kA.reqSubmitted}`),
    );
    expect(orig).toHaveLength(1);
    const desc = String(orig[0]?.description);
    try {
      const ok = await rest(A, `service_requests?id=eq.${kA.reqSubmitted}`, {
        method: "PATCH",
        prefer: "return=representation",
        body: { description: "[UJI ISOLASI] diubah pemilik" },
      });
      expect(ok.status).toBe(200);
      expect(rowsOf(ok)).toHaveLength(1);
      const cross = await rest(B, `service_requests?id=eq.${kA.reqSubmitted}`, {
        method: "PATCH",
        prefer: "return=representation",
        body: { description: "DIRETAS" },
      });
      expect(cross.status).toBeLessThan(500);
      expect(rowsOf(cross)).toHaveLength(0);
      const now = rowsOf(
        await rest(ADM, `service_requests?select=description&id=eq.${kA.reqSubmitted}`),
      );
      expect(now[0]?.description).toBe("[UJI ISOLASI] diubah pemilik");
    } finally {
      await rest(A, `service_requests?id=eq.${kA.reqSubmitted}`, {
        method: "PATCH",
        prefer: "return=minimal",
        body: { description: desc },
      });
    }
    const restored = rowsOf(
      await rest(A, `service_requests?select=description&id=eq.${kA.reqSubmitted}`),
    );
    expect(restored[0]?.description).toBe(desc);
  });
});

// ------------------------------------------------------------------------------------------------
describe("Tulis lintas pelanggan (T9, T16): kode galat spesifik, didahului kontrol payload sah", () => {
  const validBody = () => ({
    customer_id: F.custA,
    site_id: F.siteA,
    asset_id: F.assetA,
    problem_type_id: F.ptAC,
    description: "[UJI ISOLASI] AC tidak dingin",
    client_request_id: "11111111-1111-4111-8111-aaaaaaaaaaa1",
  });
  const fresh = () => ({
    description: "[UJI ISOLASI] seharusnya ditolak",
    client_request_id: crypto.randomUUID(),
  });
  const post = (tok: string, body: unknown, qs = "") =>
    rest(tok, `service_requests${qs}`, { method: "POST", prefer: "return=minimal", body });

  it("kontrol: payload sah A diterima 201 (idempoten lewat ignore-duplicates)", async () => {
    const r = await post(A, validBody(), "?on_conflict=customer_id,client_request_id");
    // ignore-duplicates: tidak membuat baris baru bila client_request_id sama
    const r2 = await rest(A, "service_requests?on_conflict=customer_id,client_request_id", {
      method: "POST",
      prefer: "return=minimal,resolution=ignore-duplicates",
      body: validBody(),
    });
    expect([201, 409]).toContain(r.status); // tanpa ignore-duplicates, kedua kali bisa 409 (23505) = sah tapi duplikat
    expect(r2.status, JSON.stringify(r2.body)).toBe(201);
  });

  const cases: [string, () => Record<string, unknown>, string[]][] = [
    [
      "customer_id B + aset B -> RLS",
      () => ({
        ...fresh(),
        customer_id: F.custB,
        asset_id: F.assetB,
        site_id: F.siteB,
        problem_type_id: F.ptAC,
      }),
      ["42501"],
    ],
    [
      "aset B dengan customer_id A -> FK komposit",
      () => ({
        ...fresh(),
        customer_id: F.custA,
        asset_id: F.assetB,
        site_id: F.siteA,
        problem_type_id: F.ptAC,
      }),
      ["23503"],
    ],
    [
      "site B dengan aset A -> FK komposit",
      () => ({
        ...fresh(),
        customer_id: F.custA,
        asset_id: F.assetA,
        site_id: F.siteB,
        problem_type_id: F.ptAC,
      }),
      ["23503"],
    ],
    [
      "channel=PHONE -> RLS",
      () => ({
        ...fresh(),
        customer_id: F.custA,
        asset_id: F.assetA,
        site_id: F.siteA,
        problem_type_id: F.ptAC,
        channel: "PHONE",
      }),
      ["42501"],
    ],
    [
      "status=CONVERTED -> hak kolom",
      () => ({
        ...fresh(),
        customer_id: F.custA,
        asset_id: F.assetA,
        site_id: F.siteA,
        problem_type_id: F.ptAC,
        status: "CONVERTED",
      }),
      ["42501"],
    ],
    [
      "created_by -> hak kolom",
      () => ({
        ...fresh(),
        customer_id: F.custA,
        asset_id: F.assetA,
        site_id: F.siteA,
        problem_type_id: F.ptAC,
        created_by: F.ids.admin,
      }),
      ["42501"],
    ],
    [
      "duplicate_of -> hak kolom",
      () => ({
        ...fresh(),
        customer_id: F.custA,
        asset_id: F.assetA,
        site_id: F.siteA,
        problem_type_id: F.ptAC,
        duplicate_of: F.reqA,
      }),
      ["42501"],
    ],
    [
      "decision_by -> hak kolom",
      () => ({
        ...fresh(),
        customer_id: F.custA,
        asset_id: F.assetA,
        site_id: F.siteA,
        problem_type_id: F.ptAC,
        decision_by: F.ids.admin,
      }),
      ["42501"],
    ],
  ];
  it.each(cases)("%s", async (_n, body, codes) => {
    const r = await post(A, body());
    expectCode(r, codes);
  });

  it("lampiran permintaan: kontrol sah, lalu varian lintas pelanggan ditolak spesifik", async () => {
    const path = kA.reqAttach.path;
    const ctl = await rest(A, "request_attachments?on_conflict=storage_path", {
      method: "POST",
      prefer: "return=minimal,resolution=ignore-duplicates",
      body: {
        request_id: kA.reqClosed,
        customer_id: F.custA,
        storage_path: path,
        mime: "image/jpeg",
        bytes: 4,
      },
    });
    expect(ctl.status, JSON.stringify(ctl.body)).toBe(201);
    const mk = (over: Record<string, unknown>) =>
      rest(A, "request_attachments", {
        method: "POST",
        prefer: "return=minimal",
        body: {
          request_id: kA.reqClosed,
          customer_id: F.custA,
          storage_path: `${F.custA}/req/${kA.reqClosed}/uji-lintas-${crypto.randomUUID()}.jpg`,
          mime: "image/jpeg",
          bytes: 4,
          ...over,
        },
      });
    expectCode(
      await mk({
        customer_id: F.custB,
        request_id: kB.reqClosed,
        storage_path: `${F.custB}/req/${kB.reqClosed}/x.jpg`,
      }),
      ["42501"],
      "customer B",
    );
    expectCode(
      await mk({ request_id: kB.reqClosed }),
      ["23503", "42501"],
      "permintaan B dengan customer A",
    );
    expectCode(
      await mk({ storage_path: `${F.custB}/req/${kB.reqClosed}/x.jpg` }),
      ["42501"],
      "path milik B",
    );
  });

  it("rating/komplain WO milik B ditolak WO005 (kontrol: WO sendiri melewati pemeriksaan kepemilikan dan berhenti di 23505 karena sudah dinilai)", async () => {
    const own = await rest(A, "ratings", {
      method: "POST",
      prefer: "return=minimal",
      body: { wo_id: kA.woClosed, score: 4 },
    });
    expect(own.code, JSON.stringify(own.body)).toBe("23505");
    expectCode(
      await rest(A, "ratings", {
        method: "POST",
        prefer: "return=minimal",
        body: { wo_id: kB.woClosed, score: 1 },
      }),
      ["WO005"],
      "rating B",
    );
    expectCode(
      await rest(A, "complaints", {
        method: "POST",
        prefer: "return=minimal",
        body: { wo_id: kB.woClosed, description: "x" },
      }),
      ["WO005"],
      "komplain B",
    );
  });

  it("update status permintaan oleh pelanggan: transisi tak sah WO001, kolom identitas 42501, permintaan final 0 baris", async () => {
    const st = await rest(A, `service_requests?id=eq.${kA.reqSubmitted}`, {
      method: "PATCH",
      prefer: "return=representation",
      body: { status: "CONVERTED" },
    });
    expectCode(st, ["WO001"], "SUBMITTED -> CONVERTED");
    expectCode(
      await rest(A, `service_requests?id=eq.${kA.reqSubmitted}`, {
        method: "PATCH",
        prefer: "return=representation",
        body: { customer_id: F.custB },
      }),
      ["42501"],
      "pindah pelanggan",
    );
    const fin = await rest(A, `service_requests?id=eq.${kA.reqClosed}`, {
      method: "PATCH",
      prefer: "return=representation",
      body: { description: "DIRETAS" },
    });
    expect(fin.status).toBe(200);
    expect(rowsOf(fin)).toHaveLength(0);
    const cross = await rest(A, `service_requests?id=eq.${kB.reqSubmitted}`, {
      method: "PATCH",
      prefer: "return=representation",
      body: { status: "CANCELLED_BY_CUSTOMER" },
    });
    expect(cross.status).toBe(200);
    expect(rowsOf(cross)).toHaveLength(0);
    const chk = rowsOf(
      await rest(
        ADM,
        `service_requests?select=status&id=in.(${kA.reqSubmitted},${kB.reqSubmitted})`,
      ),
    );
    expect(chk).toHaveLength(2);
    for (const r of chk) expect(r.status).toBe("SUBMITTED");
  });
});

// ------------------------------------------------------------------------------------------------
describe("View customer_* (T4, T14)", () => {
  const idCol: Record<string, string> = {
    customer_requests: "request_id",
    customer_work_orders: "wo_id",
    customer_wo_timeline: "wo_id",
    customer_wo_photos: "attachment_id",
    customer_service_reports: "report_id",
    customer_extra_cost_approvals: "approval_id",
  };

  it("himpunan view customer_* persis sama dengan katalog (view baru wajib diuji)", async () => {
    const r = await db.query(
      "select table_name from information_schema.views where table_schema = 'public' and table_name like 'customer\\_%' order by 1",
    );
    expect(r.rows.map((x) => x.table_name)).toEqual(Object.keys(CUSTOMER_VIEW_COLUMNS).sort());
  });

  it.each(Object.entries({ ...CUSTOMER_VIEW_COLUMNS, ...TECH_VIEW_COLUMNS }))(
    "allow-list kolom persis untuk view %s (information_schema)",
    async (view, cols) => {
      const r = await db.query(
        "select column_name from information_schema.columns where table_schema = 'public' and table_name = $1 order by ordinal_position",
        [view],
      );
      expect(r.rows.map((x) => x.column_name).sort()).toEqual([...cols].sort());
    },
  );

  it.each(Object.keys(CUSTOMER_VIEW_COLUMNS))(
    "%s: A dan B masing-masing melihat baris (kontrol) dan tidak saling melihat",
    async (view) => {
      const ra = rowsStrict(await rest(A, `${view}?select=*`), view);
      const rb = rowsStrict(await rest(B, `${view}?select=*`), view);
      expect(ra.length, `kontrol A ${view}`).toBeGreaterThan(0);
      expect(rb.length, `kontrol B ${view}`).toBeGreaterThan(0);
      const col = idCol[view] as string;
      const key = (r: Record<string, unknown>) => `${String(r[col])}|${String(r.at ?? "")}`;
      const sa = new Set(ra.map(key));
      for (const row of rb)
        expect(sa.has(key(row)), `${view}: baris B terlihat oleh A`).toBe(false);
      for (const row of ra) if ("customer_id" in row) expect(row.customer_id).toBe(F.custA);
      for (const row of rb) if ("customer_id" in row) expect(row.customer_id).toBe(F.custB);
      const allowed = CUSTOMER_VIEW_COLUMNS[view] as string[];
      for (const row of [...ra, ...rb])
        for (const c of Object.keys(row)) expect(allowed, `kolom ${c} di ${view}`).toContain(c);
    },
  );

  it("customer_wo_photos: hanya AFTER/UPLOADED pada WO CLOSED (bukan OTHER, PENDING, atau WO belum CLOSED)", async () => {
    const ra = rowsStrict(await rest(A, "customer_wo_photos?select=attachment_id,kind"), "photos");
    const ids = ra.map((r) => r.attachment_id);
    expect(ids).toContain(kA.attAfter.id);
    for (const hidden of [
      kA.attOther.id,
      kA.attFailed.id,
      kA.attPending.id,
      kA.attNotClosed.id,
      kB.attAfter.id,
    ])
      expect(ids).not.toContain(hidden);
    for (const r of ra) expect(["BEFORE", "AFTER", "FINDING"]).toContain(r.kind);
  });

  it("customer_service_reports: hanya laporan READY (revisi GENERATING tersembunyi)", async () => {
    const db2 = await db.query(
      "select count(*)::int n from public.service_reports where wo_id = $1",
      [kA.woClosed],
    );
    expect(db2.rows[0].n).toBe(2); // kontrol: ada 2 revisi di DB
    const ra = rowsStrict(
      await rest(A, `customer_service_reports?select=revision,wo_id&wo_id=eq.${kA.woClosed}`),
      "laporan",
    );
    expect(ra.map((r) => r.revision)).toEqual([1]);
  });

  it("customer_extra_cost_approvals: A melihat persetujuan miliknya beserta item; tidak melihat milik B", async () => {
    const ra = rowsStrict(await rest(A, "customer_extra_cost_approvals?select=*"), "approvals");
    const mine = ra.find((r) => r.approval_id === kA.approvalId);
    expect(mine, "persetujuan A terlihat").toBeDefined();
    expect(mine?.status).toBe("PENDING");
    expect(Array.isArray(mine?.items) && (mine?.items as unknown[]).length).toBe(1);
    expect(ra.map((r) => r.approval_id)).not.toContain(kB.approvalId);
    const rb = rowsStrict(
      await rest(B, "customer_extra_cost_approvals?select=approval_id"),
      "approvals B",
    );
    expect(rb.map((r) => r.approval_id)).toContain(kB.approvalId);
    expect(rb.map((r) => r.approval_id)).not.toContain(kA.approvalId);
  });

  it("customer_work_orders: status dipetakan, tidak ada WO B; pending_approval_id menunjuk persetujuan A", async () => {
    const ra = rowsStrict(await rest(A, "customer_work_orders?select=*"), "wo A");
    const ids = ra.map((r) => r.wo_id);
    for (const w of [kA.woNew, kA.woReview, kA.woAwait, kA.woClosed, F.woA])
      expect(ids).toContain(w);
    for (const w of [kB.woNew, kB.woClosed, F.woB]) expect(ids).not.toContain(w);
    const aw = ra.find((r) => r.wo_id === kA.woAwait);
    expect(aw?.pending_approval_id).toBe(kA.approvalId);
    expect(aw?.awaiting_customer_action).toBe(true);
    expect(ra.find((r) => r.wo_id === kA.woClosed)?.rated).toBe(true);
  });
});

// ------------------------------------------------------------------------------------------------
describe("RPC: 404 seragam dan penjagaan peran (T4, T5, T10)", () => {
  const RANDOM = "00000000-0000-4000-8000-000000000000";

  it("wo_transition CANCEL_BY_CUSTOMER pada WO B (status NEW) identik dengan id acak -> WO005", async () => {
    const mk = (id: string) =>
      rpc(A, "wo_transition", {
        p_wo_id: id,
        p_action: "CANCEL_BY_CUSTOMER",
        p_expected_version: 1,
        p_reason: "uji",
      });
    const other = await mk(kB.woNew);
    const none = await mk(RANDOM);
    expectCode(other, ["WO005"]);
    expect(errShape(other)).toEqual(errShape(none));
    // kontrol: aksi yang sama pada WO sendiri TIDAK berakhir WO005 (kepemilikan lolos; berhenti di status/versi)
    const own = await rpc(A, "wo_transition", {
      p_wo_id: kA.woReview,
      p_action: "CANCEL_BY_CUSTOMER",
      p_expected_version: -1,
      p_reason: "uji",
    });
    expect(own.code, JSON.stringify(own.body)).not.toBe("WO005");
    expect(own.code).toBeDefined();
  });

  it("aksi staf (ASSIGN) pada WO B oleh A -> WO005 (tidak membocorkan keberadaan)", async () => {
    const r = await rpc(A, "wo_transition", {
      p_wo_id: kB.woNew,
      p_action: "ASSIGN",
      p_expected_version: 1,
    });
    const none = await rpc(A, "wo_transition", {
      p_wo_id: RANDOM,
      p_action: "ASSIGN",
      p_expected_version: 1,
    });
    expectCode(r, ["WO005"]);
    expect(errShape(r)).toEqual(errShape(none));
  });

  it("wo_request_cancel pada WO B identik dengan id acak (WO005); kontrol: WO sendiri lolos kepemilikan (WO001)", async () => {
    const other = await rpc(A, "wo_request_cancel", { p_wo_id: kB.woNew, p_note: "uji" });
    const none = await rpc(A, "wo_request_cancel", { p_wo_id: RANDOM, p_note: "uji" });
    expectCode(other, ["WO005"]);
    expect(errShape(other)).toEqual(errShape(none));
    const own = await rpc(A, "wo_request_cancel", { p_wo_id: kA.woNew, p_note: "uji" });
    expectCode(own, ["WO001"], "WO sendiri (status NEW tidak bisa diajukan batal)");
  });

  it("wo_customer_sign pada WO B identik dengan id acak (WO005); kontrol: WO sendiri lolos kepemilikan (WO001)", async () => {
    const args = (id: string) => ({
      p_wo_id: id,
      p_signer_name: "x",
      p_storage_path: `${F.custB}/wo/${id}/sig.png`,
      p_expected_version: 1,
    });
    const other = await rpc(A, "wo_customer_sign", args(kB.woAwait));
    const none = await rpc(A, "wo_customer_sign", args(RANDOM));
    expectCode(other, ["WO005"]);
    expect(errShape(other)).toEqual(errShape(none));
    const own = await rpc(A, "wo_customer_sign", {
      ...args(kA.woAwait),
      p_storage_path: `${F.custA}/wo/${kA.woAwait}/sig.png`,
    });
    expectCode(own, ["WO001"], "WO sendiri belum AWAITING_SIGNOFF");
  });

  it("wo_cost_summary: WO B dan id acak identik (code, status, message, details, hint) = WO005; kontrol: staf berhasil", async () => {
    const other = await rpc(A, "wo_cost_summary", { p_wo_id: F.woB });
    const none = await rpc(A, "wo_cost_summary", { p_wo_id: RANDOM });
    expectCode(other, ["WO005"]);
    expect(errShape(other)).toEqual(errShape(none));
    expect(errShape(other).message).toBe("WO005: WO tidak ditemukan");
    // pelanggan juga ditolak untuk WO sendiri (ringkasan biaya internal bukan untuk pelanggan)
    expectCode(await rpc(A, "wo_cost_summary", { p_wo_id: kA.woClosed }), ["WO005"], "WO sendiri");
    // kontrol positif: ADMIN_CS sukses atas WO yang sama
    const ok = await rpc(ADM, "wo_cost_summary", { p_wo_id: F.woB });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(Object.keys(ok.body as object)).toContain("projected_total");
  });

  it("extra_cost_decide: persetujuan B identik dengan id acak (WO005); kontrol: persetujuan sendiri lolos kepemilikan (WO004 hash salah, tanpa mutasi)", async () => {
    const mk = (id: string) =>
      rpc(A, "extra_cost_decide", {
        p_approval_id: id,
        p_decision: "APPROVE",
        p_content_hash: "hash-salah",
      });
    const other = await mk(kB.approvalId);
    const none = await mk(RANDOM);
    expectCode(other, ["WO005"]);
    expect(errShape(other)).toEqual(errShape(none));
    const own = await mk(kA.approvalId);
    expectCode(own, ["WO004"], "persetujuan sendiri");
    expect(own.body).toMatchObject({ details: expect.stringContaining("APPROVAL_VERSION_STALE") });
    const st = await db.query("select status from public.extra_cost_approvals where id = any($1)", [
      [kA.approvalId, kB.approvalId],
    ]);
    for (const r of st.rows) expect(r.status).toBe("PENDING");
  });

  it("aksi staf pada WO sendiri oleh pelanggan -> tepat WO002 (WO disiapkan pada status tempat aksi sah bagi staf)", async () => {
    // pra-syarat: WO memang pada status yang sah untuk aksi itu menurut wo_transitions
    const tr = rowsStrict(
      await rest(
        ADM,
        "wo_transitions?select=action,from_status,allowed_roles&action=in.(ASSIGN,APPROVE_CLOSE)",
      ),
      "wo_transitions",
    );
    expect(tr.find((t) => t.action === "ASSIGN" && t.from_status === "NEW")).toBeDefined();
    expect(
      tr.find((t) => t.action === "APPROVE_CLOSE" && t.from_status === "UNDER_REVIEW"),
    ).toBeDefined();
    const st = await db.query("select id, status from public.work_orders where id = any($1)", [
      [kA.woNew, kA.woReview],
    ]);
    expect(new Map(st.rows.map((r) => [r.id, r.status]))).toEqual(
      new Map([
        [kA.woNew, "NEW"],
        [kA.woReview, "UNDER_REVIEW"],
      ]),
    );
    const assign = await rpc(A, "wo_transition", {
      p_wo_id: kA.woNew,
      p_action: "ASSIGN",
      p_expected_version: 1,
    });
    expectCode(assign, ["WO002"], "ASSIGN");
    const close = await rpc(A, "wo_transition", {
      p_wo_id: kA.woReview,
      p_action: "APPROVE_CLOSE",
      p_expected_version: 1,
    });
    expectCode(close, ["WO002"], "APPROVE_CLOSE");
    const after = await db.query(
      "select status from public.work_orders where id = any($1) order by status",
      [[kA.woNew, kA.woReview]],
    );
    expect(after.rows.map((r) => r.status).sort()).toEqual(["NEW", "UNDER_REVIEW"]);
  });

  it("pelanggan tidak bisa memanggil request_decide (hanya ADMIN_CS) -> WO002", async () => {
    const r = await rpc(A, "request_decide", {
      p_request_id: kA.reqSubmitted,
      p_decision: "REJECT",
      p_reason: "x",
      p_expected_version: -1,
    });
    expectCode(r, ["WO002"]);
    const st = await db.query("select status from public.service_requests where id = $1", [
      kA.reqSubmitted,
    ]);
    expect(st.rows[0].status).toBe("SUBMITTED");
  });
});

// ------------------------------------------------------------------------------------------------
describe("Teknisi (T11, REASSIGN)", () => {
  const ACTIVE = "('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED')";

  it("tiap teknisi melihat TEPAT WO dari penugasan aktifnya (himpunan sama dengan DB), tidak lebih", async () => {
    for (const [tok, techId] of [
      [T1, F.tech1],
      [T2, F.tech2],
    ] as const) {
      const expected = await db.query(
        `select distinct wo_id from public.wo_assignments where technician_id = $1 and status in ${ACTIVE}`,
        [techId],
      );
      const got = await fetchAll(tok, "tech_work_orders", "id");
      expect(got.status).toBe(200);
      expect(expected.rows.length, "kontrol: teknisi punya penugasan").toBeGreaterThan(2);
      expect(got.rows.map((r) => r.id).sort()).toEqual(expected.rows.map((r) => r.wo_id).sort());
    }
    // kontrol silang eksplisit
    const w1 = (await fetchAll(T1, "tech_work_orders", "id")).rows.map((r) => r.id);
    const w2 = (await fetchAll(T2, "tech_work_orders", "id")).rows.map((r) => r.id);
    expect(w1).toContain(F.woA);
    expect(w1).not.toContain(F.woB);
    expect(w2).toContain(F.woB);
    expect(w2).not.toContain(F.woA);
    // sejak 0016 tabel mentah work_orders tertutup bagi teknisi (0 baris), padahal DB berisi WO miliknya
    for (const tok of [T1, T2]) {
      const raw = await fetchAll(tok, "work_orders", "id");
      expect(raw.status).toBeLessThan(500);
      expect(raw.rows).toHaveLength(0);
    }
  });

  it("teknisi 2 tidak bisa membaca WO teknisi 1 lewat tebakan ID (kontrol: teknisi 1 bisa)", async () => {
    for (const wo of [F.woA, kA.woClosed, kA.woAwait]) {
      expect(
        rowsOf(await rest(T1, `tech_work_orders?select=id&id=eq.${wo}`)),
        `T1 ${wo}`,
      ).toHaveLength(1);
      expect(
        rowsOf(await rest(T2, `tech_work_orders?select=id&id=eq.${wo}`)),
        `T2 ${wo}`,
      ).toHaveLength(0);
    }
  });

  it.each([
    ["A", () => kA.woReassign, () => T1, () => T2, () => F.tech1],
    ["B", () => kB.woReassign, () => T2, () => T1, () => F.tech2],
  ])(
    "setelah REASSIGN (pelanggan %s) teknisi lama tidak lagi membaca WO; teknisi baru membaca",
    async (_n, wo, oldTok, newTok, oldTech) => {
      const asg = await db.query(
        "select status, technician_id from public.wo_assignments where wo_id = $1",
        [wo()],
      );
      expect(
        asg.rows.some((r) => r.status === "REASSIGNED" && r.technician_id === oldTech()),
        "REASSIGNED tercatat",
      ).toBe(true);
      for (const rel of [
        "tech_work_orders",
        "wo_assignments",
        "wo_status_history",
        "wo_checklist_items",
      ]) {
        const col = rel === "tech_work_orders" ? "id" : "wo_id";
        const rOld = await rest(oldTok(), `${rel}?select=*&${col}=eq.${wo()}`);
        expect(rowsOf(rOld), `${rel} oleh teknisi lama`).toHaveLength(0);
      }
      expect(
        rowsOf(await rest(newTok(), `tech_work_orders?select=id&id=eq.${wo()}`)),
        "teknisi baru",
      ).toHaveLength(1);
      expect(
        rowsOf(await rest(newTok(), `wo_assignments?select=id&wo_id=eq.${wo()}`)).length,
      ).toBeGreaterThan(0);
    },
  );

  it.each([
    "items",
    "wo_part_usages",
    "wo_labor_lines",
    "extra_cost_approvals",
    "extra_cost_approval_items",
  ])("teknisi tidak melihat baris di %s (kontrol: DB memang berisi baris)", async (table) => {
    const n = await db.query(`select count(*)::int n from public."${table}"`);
    expect(n.rows[0].n, `kontrol ${table}`).toBeGreaterThan(0);
    const r = await rest(T1, `${table}?select=*&limit=5`);
    expect(r.status).toBeLessThan(500);
    expect(rowsOf(r)).toHaveLength(0);
  });

  it.each([
    "tech_work_orders",
    "tech_wo_part_usages",
    "tech_wo_labor_lines",
    "tech_extra_cost_approvals",
    "v_items_catalog",
    "v_tech_asset_service_history",
  ])("view %s: teknisi melihat baris nyata tanpa satu pun kolom harga", async (view) => {
    const rows = rowsStrict(await rest(T1, `${view}?select=*`), view);
    expect(rows.length, `kontrol ${view}`).toBeGreaterThan(0);
    const allowed = TECH_VIEW_COLUMNS[view] as string[];
    for (const row of rows)
      for (const c of Object.keys(row)) {
        expect(allowed, `kolom ${c} di ${view}`).toContain(c);
        expect(PRICE_COLUMNS, `kolom harga ${c} di ${view}`).not.toContain(c);
      }
  });

  it("pelanggan tidak melihat view tech_* maupun v_items_catalog", async () => {
    for (const view of Object.keys(TECH_VIEW_COLUMNS)) {
      const r = await rest(A, `${view}?select=*`);
      expect(r.status).toBeLessThan(500);
      expect(rowsOf(r), view).toHaveLength(0);
    }
  });
});

// ------------------------------------------------------------------------------------------------
describe("Perbaikan 0016: G-08, S1, S2 (celah lama kini ditutup; uji biasa, bukan it.fails)", () => {
  // ---- G-08
  it("[G-08] teknisi 0 baris di tabel mentah work_orders, padahal DB berisi WO miliknya (kontrol)", async () => {
    const ctl = await db.query(
      "select count(*)::int n from public.wo_assignments where technician_id = $1 and wo_id = $2",
      [F.tech1, kA.woAwait],
    );
    expect(ctl.rows[0].n, "kontrol: T1 memegang woAwait").toBeGreaterThan(0);
    const r = await rest(T1, `work_orders?select=*&id=eq.${kA.woAwait}`);
    expect(r.status).toBeLessThan(500);
    expect(rowsOf(r)).toHaveLength(0);
    // staf tetap membaca (kontrol bahwa baris itu ada dan jalur baca bekerja)
    const adm = rowsStrict(
      await rest(ADM, `work_orders?select=id,estimate_total&id=eq.${kA.woAwait}`),
      "ADM",
    );
    expect(adm).toHaveLength(1);
    expect(adm[0]?.estimate_total).toBe(1500000);
  });

  it("[G-08] teknisi membaca WO-nya lewat tech_work_orders tanpa kolom estimate_*, billing_*, warranty_exception_reason", async () => {
    const rows = rowsStrict(
      await rest(T1, `tech_work_orders?select=*&id=eq.${kA.woAwait}`),
      "G-08",
    );
    expect(rows).toHaveLength(1); // kontrol positif: pemegang melihat WO-nya
    const cols = Object.keys(rows[0] as object);
    for (const c of WO_PRICE_BILLING_COLUMNS) expect(cols, `kolom ${c}`).not.toContain(c);
    expect(cols).toEqual(
      expect.arrayContaining(["id", "status", "version", "children_changed_at"]),
    );
    // permintaan eksplisit kolom harga ditolak (bukan sekadar disembunyikan oleh select=*)
    const explicit = await rest(T1, `tech_work_orders?select=estimate_total&id=eq.${kA.woAwait}`);
    expect(explicit.status).toBeGreaterThanOrEqual(400);
    expect(explicit.status).toBeLessThan(500);
    // teknisi lain (bukan pemegang) tidak melihat WO itu
    expect(rowsOf(await rest(T2, `tech_work_orders?select=id&id=eq.${kA.woAwait}`))).toHaveLength(
      0,
    );
  });

  // ---- S1
  it("[S1] wo_cost_summary: teknisi pemegang hanya menerima {needs_approval}; staf menerima hasil penuh", async () => {
    const t = await rpc<Record<string, unknown>>(T1, "wo_cost_summary", { p_wo_id: kA.woAwait });
    expect(t.status, JSON.stringify(t.body)).toBe(200);
    expect(Object.keys(t.body).sort()).toEqual(["needs_approval"]);
    expect(typeof t.body.needs_approval).toBe("boolean");
    const s = await rpc<Record<string, unknown>>(ADM, "wo_cost_summary", { p_wo_id: kA.woAwait });
    expect(s.status).toBe(200);
    expect(Object.keys(s.body).sort()).toEqual(
      ["estimate_total", "needs_approval", "projected_total", "tolerance"].sort(),
    );
    expect(s.body.estimate_total).toBe(1500000);
    expect(s.body.projected_total).toBe(650000);
    // teknisi bukan pemegang: WO005 seragam
    expectCode(
      await rpc(T2, "wo_cost_summary", { p_wo_id: kA.woAwait }),
      ["WO005"],
      "bukan pemegang",
    );
  });

  it("[S1] wo_cost_summary(NULL) memberi WO005 seragam (identik dengan id acak) bagi pelanggan, teknisi, dan staf", async () => {
    for (const [nama, tok] of [
      ["pelanggan", A],
      ["teknisi", T1],
      ["staf", ADM],
    ] as const) {
      const nul = await rpc(tok, "wo_cost_summary", { p_wo_id: null });
      const rnd = await rpc(tok, "wo_cost_summary", { p_wo_id: crypto.randomUUID() });
      expectCode(nul, ["WO005"], nama);
      expect(errShape(nul), nama).toEqual(errShape(rnd));
    }
  });

  // ---- residu G-08: extra_cost_request tidak mengembalikan total
  it("[G-08] extra_cost_request: nilai kembalian teknisi tanpa kunci 'total' (data dipulihkan setelahnya)", async () => {
    const before = await db.query("select version, status from public.work_orders where id = $1", [
      kA.woProgress,
    ]);
    expect(before.rows[0].status, "pra-syarat: woProgress IN_PROGRESS").toBe("IN_PROGRESS");
    try {
      const r = await rpc<Record<string, unknown>>(T1, "extra_cost_request", {
        p_wo_id: kA.woProgress,
        p_reason: "[UJI ISOLASI] biaya tambahan uji",
        p_items: [
          { kind: "OTHER", description: "[UJI ISOLASI] komponen", qty: 1, unit_price: 12345 },
        ],
        p_expected_version: before.rows[0].version,
      });
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      const keys = Object.keys(r.body);
      expect(keys).not.toContain("total");
      expect(keys).toEqual(
        expect.arrayContaining(["approval_id", "content_hash", "approval_version"]),
      );
      // kontrol: total memang tersimpan di DB, tetapi view teknisi tidak memuatnya
      const row = await db.query("select total from public.extra_cost_approvals where id = $1", [
        r.body.approval_id,
      ]);
      expect(Number(row.rows[0].total)).toBe(12345);
      const tv = rowsStrict(
        await rest(
          T1,
          `tech_extra_cost_approvals?select=*&approval_id=eq.${String(r.body.approval_id)}`,
        ),
        "tech view",
      );
      expect(tv).toHaveLength(1);
      expect(Object.keys(tv[0] as object)).not.toContain("total");
    } finally {
      await withDb((d) => resetTransient(d, [kA]));
    }
  });

  // ---- S2 (regresi): filter status eksplisit
  it("[S2 regresi] KONTROL: pembayaran invoice DRAFT ada di DB dan invoice DRAFT tidak terlihat pelanggan", async () => {
    const p = await db.query(
      "select p.id, i.status from public.payments p join public.invoices i on i.id = p.invoice_id where p.id = any($1)",
      [[kA.payDraft, kA.payIssued]],
    );
    expect(new Map(p.rows.map((r) => [r.id, r.status]))).toEqual(
      new Map([
        [kA.payDraft, "DRAFT"],
        [kA.payIssued, "ISSUED"],
      ]),
    );
    const inv = rowsStrict(await rest(A, "invoices?select=id,status"), "invoices");
    expect(inv.map((r) => r.id)).toContain(kA.invIssued);
    expect(inv.map((r) => r.id)).not.toContain(kA.invDraft);
  });

  it("[S2 regresi] pelanggan tidak melihat pembayaran/baris invoice dari invoice DRAFT; policy payments_customer memfilter status secara eksplisit", async () => {
    const pays = rowsStrict(await rest(A, "payments?select=id,invoice_id"), "payments");
    expect(pays.map((r) => r.id)).toContain(kA.payIssued); // kontrol positif
    expect(pays.map((r) => r.id)).not.toContain(kA.payDraft);
    expect(pays.map((r) => r.invoice_id)).not.toContain(kA.invDraft);
    const lines = rowsStrict(await rest(A, "invoice_lines?select=invoice_id"), "invoice_lines");
    expect(lines.length).toBeGreaterThan(0);
    expect(lines.map((r) => r.invoice_id)).not.toContain(kA.invDraft);
    // regresi teks policy: filter status ada di payments_customer itu sendiri (bukan hanya lewat RLS invoices)
    const pol = await db.query(
      "select qual from pg_policies where schemaname = 'public' and tablename = 'payments' and policyname = 'payments_customer'",
    );
    expect(pol.rows).toHaveLength(1);
    expect(String(pol.rows[0].qual)).toMatch(/ISSUED/);
    expect(String(pol.rows[0].qual)).toMatch(/PAID/);
  });
});

// ------------------------------------------------------------------------------------------------
describe("Staf dan peran (T8, T12)", () => {
  const rolesOf = async (uid: string) =>
    (
      await db.query("select role::text from public.user_roles where user_id = $1 order by 1", [
        uid,
      ])
    ).rows.map((r) => r.role as string);

  it("Gudang tidak membaca work_orders (kontrol: ADMIN_CS membaca)", async () => {
    const adm = rowsOf(await rest(ADM, "work_orders?select=id&limit=1"));
    expect(adm).toHaveLength(1);
    const r = await rest(await login("gudang"), "work_orders?select=id");
    expect(r.status).toBeLessThan(500);
    expect(rowsOf(r)).toHaveLength(0);
  });

  it("Finance tidak bisa menulis work_orders (42501); kontrol: Finance bisa membaca", async () => {
    const fin = await login("finance");
    expect(rowsOf(await rest(fin, `work_orders?select=id&id=eq.${F.woA}`))).toHaveLength(1);
    const r = await rest(fin, `work_orders?id=eq.${F.woA}`, {
      method: "PATCH",
      prefer: "return=representation",
      body: { priority_code: "LOW" },
    });
    expectCode(r, ["42501"]);
  });

  it("ADMIN_CS memberi OWNER lewat RPC -> WO002 dan peran target tidak berubah", async () => {
    expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER"]);
    const r = await rpc(ADM, "admin_set_user_roles", {
      p_user_id: F.ids.targetPeran,
      p_roles: ["DISPATCHER", "OWNER"],
    });
    expectCode(r, ["WO002"]);
    expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER"]);
    const r2 = await rpc(ADM, "admin_set_user_roles", {
      p_user_id: F.ids.targetPeran,
      p_roles: ["DISPATCHER", "ADMIN_CS"],
    });
    expectCode(r2, ["WO002"], "ADMIN_CS memberi ADMIN_CS");
    expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER"]);
  });

  it("kontrol: OWNER berhasil memberi OWNER lalu dikembalikan; ADMIN_CS berhasil mengubah peran non-istimewa lalu dikembalikan", async () => {
    try {
      const own = await rpc(OWN, "admin_set_user_roles", {
        p_user_id: F.ids.targetPeran,
        p_roles: ["DISPATCHER", "OWNER"],
      });
      expect(own.status, JSON.stringify(own.body)).toBeLessThan(300);
      expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER", "OWNER"]);
    } finally {
      await rpc(OWN, "admin_set_user_roles", {
        p_user_id: F.ids.targetPeran,
        p_roles: ["DISPATCHER"],
      });
    }
    expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER"]);
    try {
      const adm = await rpc(ADM, "admin_set_user_roles", {
        p_user_id: F.ids.targetPeran,
        p_roles: ["DISPATCHER", "FINANCE"],
      });
      expect(adm.status, JSON.stringify(adm.body)).toBeLessThan(300);
      expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER", "FINANCE"]);
    } finally {
      await rpc(OWN, "admin_set_user_roles", {
        p_user_id: F.ids.targetPeran,
        p_roles: ["DISPATCHER"],
      });
    }
    expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER"]);
  });

  it("pelanggan, teknisi, dispatcher, supervisor memanggil admin_set_user_roles -> WO002", async () => {
    for (const tok of [A, T1, DISP, SPV]) {
      const r = await rpc(tok, "admin_set_user_roles", {
        p_user_id: F.ids.targetPeran,
        p_roles: ["DISPATCHER"],
      });
      expectCode(r, ["WO002"]);
    }
    expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER"]);
  });

  it("INSERT/DELETE langsung ke user_roles oleh ADMIN_CS ditolak (42501) dan peran tidak berubah", async () => {
    const ins = await rest(ADM, "user_roles", {
      method: "POST",
      prefer: "return=minimal",
      body: { user_id: F.ids.targetPeran, role: "OWNER" },
    });
    expectCode(ins, ["42501"], "insert");
    const del = await rest(ADM, `user_roles?user_id=eq.${F.ids.targetPeran}`, {
      method: "DELETE",
      prefer: "return=representation",
    });
    expectCode(del, ["42501"], "delete");
    expect(await rolesOf(F.ids.targetPeran)).toEqual(["DISPATCHER"]);
  });

  it("tak seorang pun (termasuk staf) mengubah status WO langsung: 42501 lewat API, status tidak berubah (T12)", async () => {
    const before = rowsOf(await rest(ADM, `work_orders?select=status&id=eq.${F.woA}`));
    expect(before).toHaveLength(1);
    for (const k of ["admin", "dispatcher", "owner", "spv"]) {
      const r = await rest(await login(k), `work_orders?id=eq.${F.woA}`, {
        method: "PATCH",
        prefer: "return=representation",
        body: { status: "CLOSED" },
      });
      expectCode(r, ["42501"], k);
    }
    const after = rowsOf(await rest(ADM, `work_orders?select=status&id=eq.${F.woA}`));
    expect(after).toHaveLength(1);
    expect(after[0]?.status).toBe(before[0]?.status);
    expect(after[0]?.status).not.toBe("CLOSED");
  });

  it("pemicu WO001 lewat koneksi DB langsung: authenticated ditolak hak (42501); superuser memicu WO001; WO final IMM01 (T12)", async () => {
    // sebagai peran authenticated (meniru PostgREST): tidak ada hak UPDATE pada work_orders
    const viaRole = await asRole(
      db,
      F.ids.admin,
      "update public.work_orders set status = 'CLOSED' where id = $1",
      [F.woA],
    );
    expect(viaRole.ok).toBe(false);
    expect(viaRole.code).toBe("42501");
    // kontrol: peran authenticated yang sama BISA membaca baris itu (sesi dan identitas benar)
    const read = await asRole(db, F.ids.admin, "select id from public.work_orders where id = $1", [
      F.woA,
    ]);
    expect(read.ok).toBe(true);
    expect(read.rows).toHaveLength(1);
    // pemicu itu sendiri (jalur superuser, melewati privilege): WO001
    const trig = await trySql(db, "update public.work_orders set status = 'CLOSED' where id = $1", [
      F.woA,
    ]);
    expect(trig.code).toBe("WO001");
    // WO final immutable (BR-044): ubah kolom inti WO CLOSED -> IMM01
    const fin = await trySql(
      db,
      "update public.work_orders set priority_code = 'LOW' where id = $1",
      [kA.woClosed],
    );
    expect(fin.code).toBe("IMM01");
    // anak WO final menolak sisipan baru -> IMM01
    const child = await trySql(
      db,
      `insert into public.wo_labor_lines (wo_id, description, qty, billable) values ($1, 'x', 1, true)`,
      [kA.woClosed],
    );
    expect(child.code).toBe("IMM01");
    const stat = await db.query("select status from public.work_orders where id = $1", [F.woA]);
    expect(stat.rows).toHaveLength(1);
    expect(stat.rows[0].status).not.toBe("CLOSED");
  });
});

// ------------------------------------------------------------------------------------------------
describe("Penonaktifan akun (T16)", () => {
  const setActive = async (v: boolean) => {
    const r = await rpc(ADM, "admin_set_user_active", { p_user_id: F.ids.nonaktif, p_active: v });
    expect(r.status, JSON.stringify(r.body)).toBeLessThan(300);
    const st = await db.query("select is_active from public.profiles where user_id = $1", [
      F.ids.nonaktif,
    ]);
    expect(st.rows[0].is_active).toBe(v);
  };

  it("pengguna is_active=false: token lama langsung kehilangan akses data pelanggan; saat aktif terlihat (kontrol)", async () => {
    const tok = await login(F.emails.nonaktif);
    await setActive(true);
    const ctlRows = rowsStrict(
      await rest(tok, "customer_work_orders?select=wo_id"),
      "kontrol aktif",
    );
    expect(ctlRows.length, "kontrol: akun aktif melihat WO pelanggan A").toBeGreaterThan(0);
    expect(rowsStrict(await rest(tok, "assets?select=id"), "aset").length).toBeGreaterThan(0);

    await setActive(false);
    const rels = (await listPublicRelations()).map((r) => r.name);
    const res = await pmap(rels, (n) => fetchAll(tok, n), 6);
    const leaks: string[] = [];
    rels.forEach((n, i) => {
      const r = res[i] as Awaited<ReturnType<typeof fetchAll>>;
      if (r.status >= 500) leaks.push(`${n}: HTTP ${r.status}`);
      const own = ALLOWED_TABLES[n]?.own;
      if (own?.kind === "user" || own?.kind === "katalog") return; // baris milik diri sendiri / katalog umum
      if (r.rows.length > 0) leaks.push(`${n}: ${r.rows.length} baris`);
    });
    expect(leaks).toEqual([]);
    expectCode(
      await rpc(tok, "wo_request_cancel", { p_wo_id: kA.woClosed, p_note: "uji" }),
      ["WO005"],
      "RPC oleh akun nonaktif",
    );
    // akun dibiarkan nonaktif (akun uji khusus, tercatat di handoff)
  }, 300_000);

  // N1 (ditutup 0016): customer_users_select kini mensyaratkan customer_users.is_active dan profiles.is_active.
  it("[N1] pengguna nonaktif tidak membaca baris customer_users miliknya sendiri", async () => {
    const tok = await login(F.emails.nonaktif);
    await setActive(false);
    const r = await rest(tok, "customer_users?select=customer_id,user_id");
    expect(r.status).toBe(200);
    expect(rowsOf(r)).toHaveLength(0);
  });
});

// ------------------------------------------------------------------------------------------------
describe("anon (T7, T19)", () => {
  it("anon: setiap relasi public ditolak 42501 (HTTP 401/403), tanpa pengecualian", async () => {
    const rels = await listPublicRelations();
    expect(rels.length).toBeGreaterThan(80);
    const res = await pmap(rels, (r) => rest(null, `${r.name}?select=*&limit=1`), 6);
    const bad: string[] = [];
    res.forEach((r, i) => {
      if (!([401, 403].includes(r.status) && r.code === "42501"))
        bad.push(`${rels[i]?.name}: HTTP ${r.status} kode=${String(r.code)}`);
    });
    expect(bad).toEqual([]);
  }, 300_000);

  it("schema app tidak terekspos: objek yang BENAR-BENAR ada di app (my_roles) -> PGRST106; kontrol public sukses", async () => {
    // kontrol bahwa objek itu ada di DB, dan jalur public yang setara berhasil
    const exists = await db.query(
      "select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'my_roles'",
    );
    expect(exists.rows).toHaveLength(1);
    const ctl = await rest(A, "service_types?select=id&limit=1", {
      headers: { "Accept-Profile": "public" },
    });
    expect(ctl.status).toBe(200);
    expect(rowsOf(ctl).length).toBe(1);
    const ctlRpc = await rpc(
      ADM,
      "wo_cost_summary",
      { p_wo_id: F.woB },
      { "Content-Profile": "public" },
    );
    expect(ctlRpc.status).toBe(200);
    for (const tok of [null, A, ADM]) {
      const r = await api(tok, "/rest/v1/rpc/my_roles", {
        method: "POST",
        body: {},
        headers: { "Accept-Profile": "app", "Content-Profile": "app" },
      });
      expect(r.status).toBe(406);
      expect(r.code).toBe("PGRST106");
    }
    // tabel di schema app/Accept-Profile app juga tidak terbuka
    const t = await api(A, "/rest/v1/document_counters?select=*", {
      headers: { "Accept-Profile": "app" },
    });
    expect(t.code).toBe("PGRST106");
  });
});
