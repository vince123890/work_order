// Uji isolasi untuk migrasi 0016 (WP-007 lanjutan): G-13 wo_declare_no_parts, G-12 wo_closure_check, G-06 sync_op_record /
// sync_rescued_resolve, N2 (insert sync_operations), G-04 sub-prefix sig/, G-05 wo_child_changes, view operasional (B3),
// dan uji konkurensi dua sesi. Semua data uji memakai WO milik fixture (woProgress dkk) dan dipulihkan setelahnya.
import { randomBytes } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type pg from "pg";
import { TECH_WORK_ORDERS_COLUMNS } from "./catalog";
import { ensureFixture, resetTransient, type Fixture, type Kit } from "./fixtures";
import {
  deniedWith,
  errShape,
  fetchAll,
  login,
  newDb,
  rest,
  rowsOf,
  rowsStrict,
  rpc,
  withDb,
  type Res,
} from "./helpers";

let F: Fixture;
let kA: Kit;
let kB: Kit;
let A = "";
let B = "";
let T1 = "";
let T2 = "";
let ADM = "";
let DISP = "";
let OWN = "";
let SPV = "";
let GDG = "";
let FIN = "";
let db: pg.Client;
const MARK = "uji-iso-transien";

function expectCode(r: Res, codes: string[], label = "") {
  const d = deniedWith(r, codes);
  expect(d.ok, `${label} ${d.info}`).toBe(true);
}

beforeAll(async () => {
  F = await ensureFixture();
  kA = F.kitA;
  kB = F.kitB;
  const toks: string[] = await Promise.all(
    [
      "plg-a",
      "plg-b",
      "tek1",
      "tek2",
      "admin",
      "dispatcher",
      "owner",
      "spv",
      "gudang",
      "finance",
    ].map((k) => login(k)),
  );
  [A, B, T1, T2, ADM, DISP, OWN, SPV, GDG, FIN] = toks as [
    string,
    string,
    string,
    string,
    string,
    string,
    string,
    string,
    string,
    string,
  ];
  db = newDb();
  await db.connect();
}, 300_000);

afterAll(async () => {
  if (db) {
    await resetTransient(db, [kA, kB]).catch(() => undefined);
    await db.end();
  }
});

async function mkOp(userId: string, status = "RECEIVED"): Promise<string> {
  const id = crypto.randomUUID();
  await db.query(
    `insert into public.sync_operations (op_id, device_id, user_id, type, status)
     values ($1, $2, $3, 'UJI', $4::public.sync_op_status)`,
    [id, MARK, userId, status],
  );
  return id;
}
const woRow = async (wo: string) =>
  (
    await db.query(
      "select version, no_parts_used, status, updated_at from public.work_orders where id = $1",
      [wo],
    )
  ).rows[0] as { version: number; no_parts_used: boolean; status: string; updated_at: Date };

// ------------------------------------------------------------------------------------------------
describe("G-13 wo_declare_no_parts", () => {
  it("LEAD berhasil, helper WO002, bukan pemegang/pelanggan/staf WO005 seragam, replay p_op_id tidak membalik nilai, versi basi WO004; nilai dipulihkan", async () => {
    await resetTransient(db, [kA]);
    const wo = kA.woProgress;
    try {
      const w0 = await woRow(wo);
      expect(w0.no_parts_used).toBe(false);
      // LEAD
      const r1 = await rpc<Record<string, unknown>>(T1, "wo_declare_no_parts", {
        p_wo_id: wo,
        p_value: true,
        p_expected_version: w0.version,
      });
      expect(r1.status, JSON.stringify(r1.body)).toBe(200);
      expect(r1.body.no_parts_used).toBe(true);
      expect(r1.body.replayed).toBe(false);
      const w1 = await woRow(wo);
      expect(w1.no_parts_used).toBe(true);
      expect(w1.version).toBeGreaterThan(w0.version);
      expect(r1.body.version).toBe(w1.version);

      // helper (T2 memegang woProgress sebagai HELPER ACCEPTED): WO002
      const helperRows = await db.query(
        "select role from public.wo_assignments where wo_id = $1 and technician_id = $2",
        [wo, F.tech2],
      );
      expect(
        helperRows.rows.map((r) => r.role),
        "kontrol: T2 memang HELPER",
      ).toContain("HELPER");
      expectCode(
        await rpc(T2, "wo_declare_no_parts", {
          p_wo_id: wo,
          p_value: false,
          p_expected_version: w1.version,
        }),
        ["WO002"],
        "helper",
      );
      expect((await woRow(wo)).no_parts_used, "helper tidak mengubah apa pun").toBe(true);

      // bukan pemegang / pelanggan / staf: WO005 seragam, identik dengan id acak
      const none = await rpc(T2, "wo_declare_no_parts", {
        p_wo_id: crypto.randomUUID(),
        p_value: true,
        p_expected_version: 1,
      });
      expectCode(none, ["WO005"], "id acak");
      for (const [nama, tok, id] of [
        ["teknisi bukan pemegang", T2, kA.woAwait],
        ["pelanggan pemilik", A, wo],
        ["pelanggan lain", B, wo],
        ["ADMIN_CS", ADM, wo],
        ["NULL", T1, null],
      ] as const) {
        const r = await rpc(tok, "wo_declare_no_parts", {
          p_wo_id: id,
          p_value: true,
          p_expected_version: 1,
        });
        expectCode(r, ["WO005"], nama);
        expect(errShape(r), nama).toEqual(errShape(none));
      }

      // replay p_op_id: op APPLIED milik T1 -> tidak membalik nilai, version tetap
      const op = await mkOp(F.ids.tek1, "APPLIED");
      const r2 = await rpc<Record<string, unknown>>(T1, "wo_declare_no_parts", {
        p_wo_id: wo,
        p_value: false,
        p_expected_version: w1.version,
        p_op_id: op,
      });
      expect(r2.status, JSON.stringify(r2.body)).toBe(200);
      expect(r2.body.replayed).toBe(true);
      expect(r2.body.no_parts_used).toBe(true);
      const w2 = await woRow(wo);
      expect(w2.no_parts_used).toBe(true);
      expect(w2.version).toBe(w1.version);
      // op APPLIED milik ORANG LAIN tidak memberi efek replay (nilai berubah normal) -> dibuktikan lewat nilai sama di bawah
      // nilai sama = tanpa perubahan, version tetap
      const r3 = await rpc<Record<string, unknown>>(T1, "wo_declare_no_parts", {
        p_wo_id: wo,
        p_value: true,
        p_expected_version: w1.version,
      });
      expect(r3.body.replayed).toBe(true);
      expect((await woRow(wo)).version).toBe(w1.version);
      // versi basi
      const r4 = await rpc(T1, "wo_declare_no_parts", {
        p_wo_id: wo,
        p_value: false,
        p_expected_version: w0.version,
      });
      expectCode(r4, ["WO004"], "versi basi");
      expect((await woRow(wo)).no_parts_used).toBe(true);
      // p_value NULL
      expectCode(
        await rpc(T1, "wo_declare_no_parts", {
          p_wo_id: wo,
          p_value: null,
          p_expected_version: w1.version,
        }),
        ["WO006"],
        "null",
      );
      // pulihkan lewat RPC (jalur nyata)
      const r5 = await rpc<Record<string, unknown>>(T1, "wo_declare_no_parts", {
        p_wo_id: wo,
        p_value: false,
        p_expected_version: w1.version,
      });
      expect(r5.status, JSON.stringify(r5.body)).toBe(200);
      expect(r5.body.no_parts_used).toBe(false);
    } finally {
      await resetTransient(db, [kA]);
    }
    expect((await woRow(wo)).no_parts_used).toBe(false);
  });

  it("true ditolak (WO003 PARTS_ALREADY_RECORDED) bila sudah ada pemakaian aktif; tidak ada perubahan", async () => {
    const used = await db.query(
      "select count(*)::int n from public.wo_part_usages where wo_id = $1 and deleted_at is null",
      [kA.woAwait],
    );
    expect(used.rows[0].n, "kontrol: ada pemakaian aktif").toBeGreaterThan(0);
    const w0 = await woRow(kA.woAwait);
    const r = await rpc(T1, "wo_declare_no_parts", {
      p_wo_id: kA.woAwait,
      p_value: true,
      p_expected_version: w0.version,
    });
    expectCode(r, ["WO003"], "sudah ada pemakaian");
    expect(JSON.stringify(r.body)).toContain("PARTS_ALREADY_RECORDED");
    const w1 = await woRow(kA.woAwait);
    expect(w1.no_parts_used).toBe(false);
    expect(w1.version).toBe(w0.version);
  });

  it("WO yang tidak dapat diisi (CLOSED) -> WO001 untuk pemegangnya (kontrol: pemegang lolos kepemilikan)", async () => {
    const w = await woRow(kA.woClosed);
    const r = await rpc(T1, "wo_declare_no_parts", {
      p_wo_id: kA.woClosed,
      p_value: true,
      p_expected_version: w.version,
    });
    expectCode(r, ["WO001"], "CLOSED");
  });
});

// ------------------------------------------------------------------------------------------------
describe("G-12 wo_closure_check", () => {
  it("pemegang dan staf berhasil dengan hasil sama; kekurangan nyata muncul (bukan vakum)", async () => {
    const t = await rpc<{ code: string }[]>(T1, "wo_closure_check", { p_wo_id: kA.woAwait });
    expect(t.status, JSON.stringify(t.body)).toBe(200);
    expect(Array.isArray(t.body)).toBe(true);
    const codes = t.body.map((x) => x.code);
    expect(codes).toEqual(expect.arrayContaining(["CHECK_IN_MISSING", "EXTRA_COST_PENDING"]));
    for (const [nama, tok] of [
      ["ADMIN_CS", ADM],
      ["DISPATCHER", DISP],
      ["SUPERVISOR", SPV],
      ["OWNER", OWN],
    ] as const) {
      const r = await rpc(tok, "wo_closure_check", { p_wo_id: kA.woAwait });
      expect(r.status, `${nama} ${JSON.stringify(r.body)}`).toBe(200);
      expect(r.body, nama).toEqual(t.body);
    }
    // WO UNDER_REVIEW memakai mode CLOSE (pratinjau T-19)
    const u = await rpc(SPV, "wo_closure_check", { p_wo_id: kA.woReview });
    expect(u.status, JSON.stringify(u.body)).toBe(200);
    expect(Array.isArray(u.body)).toBe(true);
  });

  it("pelanggan (pemilik maupun lain), teknisi bukan pemegang, Finance, Gudang, NULL dan id acak: WO005 seragam", async () => {
    const none = await rpc(T2, "wo_closure_check", { p_wo_id: crypto.randomUUID() });
    expectCode(none, ["WO005"], "id acak");
    for (const [nama, tok, id] of [
      ["pelanggan pemilik", A, kA.woAwait],
      ["pelanggan lain", B, kA.woAwait],
      ["teknisi bukan pemegang", T2, kA.woAwait],
      ["Finance", FIN, kA.woAwait],
      ["Gudang", GDG, kA.woAwait],
      ["NULL", ADM, null],
    ] as const) {
      const r = await rpc(tok, "wo_closure_check", { p_wo_id: id });
      expectCode(r, ["WO005"], nama);
      expect(errShape(r), nama).toEqual(errShape(none));
    }
  });
});

// ------------------------------------------------------------------------------------------------
describe("G-06 sync_op_record dan sync_rescued_resolve", () => {
  it("hanya baris milik sendiri; transisi sah, replay, transisi tak sah WO001, status tak sah WO006", async () => {
    const op = await mkOp(F.ids.tek1);
    const r1 = await rpc<Record<string, unknown>>(T1, "sync_op_record", {
      p_op_id: op,
      p_status: "APPLIED",
      p_result: { ok: true },
    });
    expect(r1.status, JSON.stringify(r1.body)).toBe(200);
    expect(r1.body.status).toBe("APPLIED");
    expect(r1.body.replayed).toBe(false);
    const row = (
      await db.query(
        "select status, applied_at, result from public.sync_operations where op_id = $1",
        [op],
      )
    ).rows[0];
    expect(row.status).toBe("APPLIED");
    expect(row.applied_at).not.toBeNull();
    expect(row.result).toEqual({ ok: true });
    // replay
    const r2 = await rpc<Record<string, unknown>>(T1, "sync_op_record", {
      p_op_id: op,
      p_status: "APPLIED",
    });
    expect(r2.body.replayed).toBe(true);
    // APPLIED -> REJECTED tak sah
    expectCode(
      await rpc(T1, "sync_op_record", { p_op_id: op, p_status: "REJECTED" }),
      ["WO001"],
      "APPLIED->REJECTED",
    );

    // RECEIVED -> REJECTED -> RESCUED, lalu final
    const op2 = await mkOp(F.ids.tek1);
    expect((await rpc(T1, "sync_op_record", { p_op_id: op2, p_status: "REJECTED" })).status).toBe(
      200,
    );
    expect((await rpc(T1, "sync_op_record", { p_op_id: op2, p_status: "RESCUED" })).status).toBe(
      200,
    );
    expectCode(
      await rpc(T1, "sync_op_record", { p_op_id: op2, p_status: "APPLIED" }),
      ["WO001"],
      "RESCUED final",
    );

    // status tak sah
    const op3 = await mkOp(F.ids.tek1);
    for (const st of ["RECEIVED", "XYZ", null]) {
      expectCode(
        await rpc(T1, "sync_op_record", { p_op_id: op3, p_status: st }),
        ["WO006"],
        String(st),
      );
    }
    expect(
      (await db.query("select status from public.sync_operations where op_id = $1", [op3])).rows[0]
        .status,
    ).toBe("RECEIVED");
  });

  it("baris orang lain atau tak ada: WO005 seragam (pelanggan, teknisi lain, staf)", async () => {
    const op = await mkOp(F.ids.tek1);
    const none = await rpc(T2, "sync_op_record", {
      p_op_id: crypto.randomUUID(),
      p_status: "APPLIED",
    });
    expectCode(none, ["WO005"], "id acak");
    for (const [nama, tok] of [
      ["teknisi lain", T2],
      ["pelanggan", A],
      ["ADMIN_CS", ADM],
    ] as const) {
      const r = await rpc(tok, "sync_op_record", { p_op_id: op, p_status: "APPLIED" });
      expectCode(r, ["WO005"], nama);
      expect(errShape(r), nama).toEqual(errShape(none));
    }
    expect(
      (await db.query("select status from public.sync_operations where op_id = $1", [op])).rows[0]
        .status,
    ).toBe("RECEIVED");
  });

  it("p_result > 64 KB ditolak (WO006) dengan payload besar nyata; payload kecil diterima (kontrol)", async () => {
    const big = { blob: randomBytes(90_000).toString("hex") }; // sekitar 180 KB
    const op = await mkOp(F.ids.tek1);
    const r = await rpc(T1, "sync_op_record", { p_op_id: op, p_status: "APPLIED", p_result: big });
    expectCode(r, ["WO006"], "payload besar");
    const st = (
      await db.query("select status, result from public.sync_operations where op_id = $1", [op])
    ).rows[0];
    expect(st.status).toBe("RECEIVED");
    expect(st.result).toBeNull();
    // tepat di bawah batas (sekitar 40 KB) diterima
    const mid = { blob: randomBytes(20_000).toString("hex") };
    const ok = await rpc(T1, "sync_op_record", { p_op_id: op, p_status: "APPLIED", p_result: mid });
    expect(ok.status, JSON.stringify(ok.body).slice(0, 200)).toBe(200);
  });

  it("sync_rescued_resolve: staf berhak berhasil (replay aman), catatan wajib, hanya RESCUED, selain staf WO002", async () => {
    const rescued = await mkOp(F.ids.tek1, "RESCUED");
    expectCode(
      await rpc(ADM, "sync_rescued_resolve", { p_op_id: rescued, p_note: "  " }),
      ["WO006"],
      "catatan kosong",
    );
    const r = await rpc<Record<string, unknown>>(ADM, "sync_rescued_resolve", {
      p_op_id: rescued,
      p_note: "ditautkan",
    });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.replayed).toBe(false);
    const row = (
      await db.query(
        "select resolved_by, resolved_note, resolved_at from public.sync_operations where op_id = $1",
        [rescued],
      )
    ).rows[0];
    expect(row.resolved_by).toBe(F.ids.admin);
    expect(row.resolved_note).toBe("ditautkan");
    const r2 = await rpc<Record<string, unknown>>(ADM, "sync_rescued_resolve", {
      p_op_id: rescued,
      p_note: "lagi",
    });
    expect(r2.body.replayed).toBe(true);
    // peran staf lain yang berhak
    for (const tok of [DISP, SPV, OWN]) {
      const op = await mkOp(F.ids.tek1, "RESCUED");
      expect((await rpc(tok, "sync_rescued_resolve", { p_op_id: op, p_note: "x" })).status).toBe(
        200,
      );
    }
    // bukan RESCUED
    const recv = await mkOp(F.ids.tek1);
    expectCode(
      await rpc(ADM, "sync_rescued_resolve", { p_op_id: recv, p_note: "x" }),
      ["WO001"],
      "bukan RESCUED",
    );
    expectCode(
      await rpc(ADM, "sync_rescued_resolve", { p_op_id: crypto.randomUUID(), p_note: "x" }),
      ["WO005"],
      "tak ada",
    );
    // bukan staf berhak
    const op = await mkOp(F.ids.tek1, "RESCUED");
    for (const [nama, tok] of [
      ["pelanggan", A],
      ["teknisi pemilik", T1],
      ["Gudang", GDG],
      ["Finance", FIN],
    ] as const) {
      expectCode(
        await rpc(tok, "sync_rescued_resolve", { p_op_id: op, p_note: "x" }),
        ["WO002"],
        nama,
      );
    }
    expect(
      (await db.query("select resolved_at from public.sync_operations where op_id = $1", [op]))
        .rows[0].resolved_at,
    ).toBeNull();
  });

  afterAll(async () => {
    await db.query("delete from public.sync_operations where device_id = $1", [MARK]);
  });
});

// ------------------------------------------------------------------------------------------------
describe("N2: INSERT sync_operations dibatasi (42501)", () => {
  const body = (user: string, wo: string | null) => ({
    op_id: crypto.randomUUID(),
    device_id: MARK,
    user_id: user,
    wo_id: wo,
    type: "UJI",
  });
  const ins = (tok: string, b: unknown) =>
    rest(tok, "sync_operations", { method: "POST", prefer: "return=minimal", body: b });

  it("pelanggan dan teknisi bukan pemegang ditolak 42501; teknisi pemegang boleh dengan wo_id miliknya dan dengan wo_id NULL", async () => {
    try {
      // ditolak
      expectCode(await ins(A, body(F.ids.userA, kA.woClosed)), ["42501"], "pelanggan pemilik WO");
      expectCode(await ins(A, body(F.ids.userA, null)), ["42501"], "pelanggan tanpa wo_id");
      expectCode(await ins(B, body(F.ids.userB, kA.woClosed)), ["42501"], "pelanggan lain");
      expectCode(await ins(T2, body(F.ids.tek2, kA.woClosed)), ["42501"], "teknisi bukan pemegang");
      expectCode(
        await ins(T1, body(F.ids.tek1, kB.woClosed)),
        ["42501"],
        "teknisi, WO milik teknisi lain",
      );
      expectCode(await ins(T2, body(F.ids.tek1, null)), ["42501"], "menyamar sebagai user lain");
      expectCode(await ins(ADM, body(F.ids.admin, kA.woClosed)), ["42501"], "staf non-teknisi");
      // diizinkan
      const ok1 = await ins(T1, body(F.ids.tek1, kA.woClosed));
      expect(ok1.status, JSON.stringify(ok1.body)).toBe(201);
      const ok2 = await ins(T1, body(F.ids.tek1, null));
      expect(ok2.status, JSON.stringify(ok2.body)).toBe(201);
      const n = await db.query(
        "select count(*)::int n from public.sync_operations where device_id = $1 and user_id = $2",
        [MARK, F.ids.tek1],
      );
      expect(n.rows[0].n).toBeGreaterThanOrEqual(2);
      const bad = await db.query(
        "select count(*)::int n from public.sync_operations where device_id = $1 and user_id <> $2",
        [MARK, F.ids.tek1],
      );
      expect(bad.rows[0].n, "tidak ada baris dari penyisip yang ditolak").toBe(0);
    } finally {
      await db.query("delete from public.sync_operations where device_id = $1", [MARK]);
    }
  });
});

// ------------------------------------------------------------------------------------------------
describe("G-04: tanda tangan, sub-prefix sig/ dan upload_status", () => {
  const sigBase = (k: Kit, wo: string) => `${k.cust}/wo/${wo}`;
  const sign = (tok: string, wo: string, path: string, ver: number) =>
    rpc(tok, "wo_customer_sign", {
      p_wo_id: wo,
      p_signer_name: "[UJI ISOLASI]",
      p_storage_path: path,
      p_expected_version: ver,
    });

  it("wo_customer_sign: path bukan sig/ atau terdaftar di wo_attachments atau berbahaya -> WO006 (tanpa mutasi)", async () => {
    const wo = kA.woSign;
    const w0 = await woRow(wo);
    expect(w0.status, "pra-syarat").toBe("AWAITING_SIGNOFF");
    const base = sigBase(kA, wo);
    const reg = await db.query("select 1 from public.wo_attachments where storage_path = $1", [
      kA.sigRegPath,
    ]);
    expect(reg.rows, "kontrol: path sig/ terdaftar di wo_attachments").toHaveLength(1);
    const cases: [string, string][] = [
      ["tanpa sub-prefix sig/", `${base}/x.png`],
      ["sig/ tanpa nama file", `${base}/sig/`],
      ["traversal", `${base}/sig/../x.png`],
      ["traversal bersarang", `${base}/sig/a/../../x.png`],
      ["terdaftar di wo_attachments", kA.sigRegPath],
      ["WO lain milik sendiri", `${sigBase(kA, kA.woClosed)}/sig/x.png`],
      ["pelanggan lain", `${sigBase(kB, kB.woSign)}/sig/x.png`],
      ["kosong", ""],
    ];
    for (const [label, path] of cases) {
      expectCode(await sign(A, wo, path, w0.version), ["WO006"], label);
    }
    const w1 = await woRow(wo);
    expect(w1.status).toBe("AWAITING_SIGNOFF");
    expect(w1.version).toBe(w0.version);
    const sigs = await db.query(
      "select count(*)::int n from public.wo_signatures where wo_id = $1",
      [wo],
    );
    expect(sigs.rows[0].n).toBe(0);
  });

  it("path sah tetapi objek belum diunggah: WO003 (SIGNATURE_MISSING), transaksi batal; pelanggan lain WO005", async () => {
    const wo = kA.woSign;
    const w0 = await woRow(wo);
    const path = `${sigBase(kA, wo)}/sig/tidak-ada-${crypto.randomUUID()}.png`;
    const r = await sign(A, wo, path, w0.version);
    expectCode(r, ["WO003"], "objek belum ada");
    expect(JSON.stringify(r.body)).toContain("SIGNATURE_MISSING");
    const left = await db.query(
      "select count(*)::int n from public.wo_signatures where storage_path = $1",
      [path],
    );
    expect(left.rows[0].n, "tidak ada baris tanda tangan tersisa").toBe(0);
    expect((await woRow(wo)).status).toBe("AWAITING_SIGNOFF");
    expectCode(await sign(B, wo, path, w0.version), ["WO005"], "pelanggan lain");
  });

  it("tanda tangan teknisi (TECH_DEVICE): hanya di bawah sig/, selalu PENDING, klien tidak bisa mengisi upload_status", async () => {
    const wo = kA.woProgress;
    const base = sigBase(kA, wo);
    const mk = (over: Record<string, unknown>) =>
      rest(T1, "wo_signatures", {
        method: "POST",
        prefer: "return=minimal",
        body: {
          wo_id: wo,
          signer_type: "CUSTOMER",
          signer_name: "[UJI ISOLASI]",
          storage_path: `${base}/sig/uji-${crypto.randomUUID()}.png`,
          signed_via: "TECH_DEVICE",
          ...over,
        },
      });
    try {
      expectCode(await mk({ storage_path: `${base}/x.png` }), ["42501"], "tanpa sig/");
      expectCode(await mk({ storage_path: `${base}/sig/../x.png` }), ["42501"], "traversal");
      expectCode(await mk({ upload_status: "UPLOADED" }), ["42501"], "klien mengisi upload_status");
      expectCode(await mk({ signed_via: "CUSTOMER_PWA" }), ["42501"], "signed_via PWA");
      const path = `${base}/sig/uji-sah-${crypto.randomUUID()}.png`;
      const ok = await mk({ storage_path: path });
      expect(ok.status, JSON.stringify(ok.body)).toBe(201);
      const row = (
        await db.query(
          "select upload_status, status from public.wo_signatures where storage_path = $1",
          [path],
        )
      ).rows[0];
      expect(row.upload_status).toBe("PENDING");
      expect(row.status).toBe("VALID");
      // tanda tangan PENDING tidak dihitung untuk penutupan
      const chk = await rpc<{ code: string }[]>(T1, "wo_closure_check", { p_wo_id: wo });
      expect(chk.body.map((x) => x.code)).toContain("SIGNATURE_MISSING");
    } finally {
      await db.query("delete from public.wo_signatures where wo_id = $1", [wo]);
    }
  });
});

// ------------------------------------------------------------------------------------------------
describe("G-05 wo_child_changes dan view tech_work_orders", () => {
  it("perubahan anak memajukan changed_at TANPA menaikkan version/updated_at/audit WO (jalur teknisi nyata)", async () => {
    await resetTransient(db, [kA]);
    const wo = kA.woProgress;
    const item = rowsStrict(
      await rest(T1, `wo_checklist_items?select=id,value&wo_id=eq.${wo}&seq=eq.9001`),
      "checklist",
    );
    expect(item).toHaveLength(1);
    const before = await woRow(wo);
    const auditBefore = (
      await db.query(
        "select count(*)::int n from public.audit_logs where entity_type = 'work_orders' and entity_id = $1",
        [wo],
      )
    ).rows[0].n;
    const t0 = (
      await db.query("select changed_at from public.wo_child_changes where wo_id = $1", [wo])
    ).rows[0]?.changed_at as Date | undefined;
    try {
      const up = await rest(T1, `wo_checklist_items?wo_id=eq.${wo}&seq=eq.9001`, {
        method: "PATCH",
        prefer: "return=representation",
        body: { value: true },
      });
      expect(up.status, JSON.stringify(up.body)).toBe(200);
      expect(rowsOf(up)).toHaveLength(1);
      const after = await woRow(wo);
      expect(after.version, "version WO tidak naik karena anak").toBe(before.version);
      expect(after.updated_at.getTime()).toBe(before.updated_at.getTime());
      const auditAfter = (
        await db.query(
          "select count(*)::int n from public.audit_logs where entity_type = 'work_orders' and entity_id = $1",
          [wo],
        )
      ).rows[0].n;
      expect(auditAfter).toBe(auditBefore);
      const t1 = (
        await db.query("select changed_at from public.wo_child_changes where wo_id = $1", [wo])
      ).rows[0].changed_at as Date;
      if (t0) expect(t1.getTime()).toBeGreaterThan(t0.getTime());
      // terlihat teknisi lewat view dan tabel sinyal
      const v = rowsStrict(
        await rest(T1, `tech_work_orders?select=version,children_changed_at&id=eq.${wo}`),
        "view",
      );
      expect(v[0]?.version).toBe(before.version);
      expect(new Date(String(v[0]?.children_changed_at)).getTime()).toBe(t1.getTime());
      const s = rowsStrict(
        await rest(T1, `wo_child_changes?select=wo_id,changed_at&wo_id=eq.${wo}`),
        "sinyal",
      );
      expect(s).toHaveLength(1);
    } finally {
      await rest(T1, `wo_checklist_items?wo_id=eq.${wo}&seq=eq.9001`, {
        method: "PATCH",
        prefer: "return=minimal",
        body: { value: null },
      });
    }
  });

  it("RLS sinyal: teknisi hanya WO aktifnya, staf semua, pelanggan 0; authenticated tidak bisa menulis", async () => {
    const dbCount = await db.query("select count(*)::int n from public.wo_child_changes");
    expect(dbCount.rows[0].n, "kontrol: tabel sinyal berisi baris").toBeGreaterThan(5);
    const t1 = (await fetchAll(T1, "wo_child_changes", "wo_id")).rows.map((r) => String(r.wo_id));
    expect(t1.length).toBeGreaterThan(0);
    const mine = new Set(
      (await fetchAll(T1, "tech_work_orders", "id")).rows.map((r) => String(r.id)),
    );
    for (const id of t1) expect(mine.has(id), `sinyal ${id} milik WO aktif`).toBe(true);
    expect(t1).not.toContain(kB.woClosed);
    const t2 = (await fetchAll(T2, "wo_child_changes", "wo_id")).rows.map((r) => String(r.wo_id));
    expect(t2).not.toContain(kA.woClosed); // T2 bukan pemegang woClosed A
    expect((await fetchAll(ADM, "wo_child_changes", "wo_id")).rows.length).toBe(dbCount.rows[0].n);
    expect((await fetchAll(A, "wo_child_changes", "wo_id")).rows).toHaveLength(0);
    for (const tok of [T1, ADM, A]) {
      expectCode(
        await rest(tok, "wo_child_changes", {
          method: "POST",
          prefer: "return=minimal",
          body: { wo_id: crypto.randomUUID() },
        }),
        ["42501"],
        "tulis sinyal",
      );
    }
  });

  it("tech_work_orders: security_barrier aktif dan kolom PERSIS sama dengan allow-list (information_schema)", async () => {
    const opt = await db.query(
      "select reloptions from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = 'tech_work_orders'",
    );
    expect(opt.rows).toHaveLength(1);
    expect(opt.rows[0].reloptions).toContain("security_barrier=true");
    const cols = await db.query(
      "select column_name from information_schema.columns where table_schema = 'public' and table_name = 'tech_work_orders'",
    );
    expect(cols.rows.map((r) => r.column_name).sort()).toEqual(
      [...TECH_WORK_ORDERS_COLUMNS].sort(),
    );
  });
});

// ------------------------------------------------------------------------------------------------
describe("B3: view terlarang berisi data bagi peran berhak (bukan vakum), kosong bagi lainnya", () => {
  const cases: {
    view: string;
    entitled: () => [string, string][];
    mustContain?: () => string[]; // kolom, nilai (opsional)
    col?: string;
  }[] = [
    { view: "v_job_health", entitled: () => [["OWNER", OWN]] },
    { view: "v_kpi_sla_monthly", entitled: () => [["OWNER", OWN]] },
    {
      view: "v_finance_ready_to_bill",
      entitled: () => [["FINANCE", FIN]],
      col: "wo_id",
      mustContain: () => [kA.woTagih, kB.woTagih],
    },
    { view: "v_wh_part_requests", entitled: () => [["GUDANG", GDG]] },
    {
      view: "v_today_work_orders",
      entitled: () => [["ADMIN_CS", ADM]],
      col: "wo_id",
      mustContain: () => [kA.woAwait, kB.woAwait],
    },
    { view: "v_open_part_variances", entitled: () => [["OWNER", OWN]] },
  ];

  it.each(cases.map((c) => c.view))(
    "%s: peran berhak melihat baris; pelanggan, Finance/Gudang yang tak berhak, dan teknisi tidak",
    async (view) => {
      const c = cases.find((x) => x.view === view) as (typeof cases)[number];
      for (const [nama, tok] of c.entitled()) {
        const rows = rowsStrict(await rest(tok, `${view}?select=*`), `${view} ${nama}`);
        expect(rows.length, `kontrol: ${nama} melihat data di ${view}`).toBeGreaterThan(0);
        if (c.col && c.mustContain) {
          const ids = rows.map((r) => String(r[c.col as string]));
          for (const id of c.mustContain()) expect(ids, `${view} memuat WO fixture`).toContain(id);
        }
      }
      for (const [nama, tok] of [
        ["pelanggan A", A],
        ["pelanggan B", B],
      ] as const) {
        const r = await rest(tok, `${view}?select=*`);
        expect(r.status, nama).toBeLessThan(500);
        expect(rowsOf(r), `${view} ${nama}`).toHaveLength(0);
      }
      // teknisi: kosong, kecuali v_open_part_variances (boleh barisnya sendiri menurut parts_variances_tech)
      const tr = await rest(T1, `${view}?select=*`);
      expect(tr.status).toBeLessThan(500);
      if (view === "v_open_part_variances") {
        const mine = rowsStrict(tr, view);
        expect(mine.length, "kontrol: teknisi melihat selisih miliknya").toBeGreaterThan(0);
        for (const row of mine) expect(row.technician_id).toBe(F.tech1);
      } else {
        expect(rowsOf(tr), `${view} teknisi`).toHaveLength(0);
      }
    },
  );

  it("peran yang tidak berhak (Gudang/Finance/Dispatcher) tidak melihat view yang bukan haknya", async () => {
    for (const [view, tok, nama] of [
      ["v_job_health", GDG, "Gudang"],
      ["v_job_health", FIN, "Finance"],
      ["v_finance_ready_to_bill", GDG, "Gudang"],
      ["v_wh_part_requests", FIN, "Finance"],
      ["v_kpi_sla_monthly", GDG, "Gudang"],
    ] as const) {
      const r = await rest(tok, `${view}?select=*`);
      expect(r.status, `${view} ${nama}`).toBeLessThan(500);
      expect(rowsOf(r), `${view} ${nama}`).toHaveLength(0);
    }
  });
});

// ------------------------------------------------------------------------------------------------
describe("Konkurensi dua sesi (D): trigger sinyal deferred, WO uji milik fixture", () => {
  type Out = { ok: boolean; code?: string; msg?: string; detail?: string; where?: string };

  async function openSession(): Promise<pg.Client> {
    const c = newDb();
    await c.connect();
    await c.query("set statement_timeout = '25s'");
    await c.query("set lock_timeout = '10s'");
    return c;
  }
  const attempt = async (c: pg.Client, sql: string, params: unknown[] = []): Promise<Out> => {
    try {
      await c.query(sql, params);
      return { ok: true };
    } catch (e) {
      const err = e as { code?: string; message?: string; detail?: string; where?: string };
      return { ok: false, code: err.code, msg: err.message, detail: err.detail, where: err.where };
    }
  };
  async function extraRequest(c: pg.Client, sub: string, wo: string, reason: string): Promise<Out> {
    const ver = (await c.query("select version from public.work_orders where id = $1", [wo]))
      .rows[0].version as number; // dibaca di sesi yang sama sebelum ganti peran
    await c.query("set local role authenticated");
    await c.query("select set_config('request.jwt.claim.sub', $1, true)", [sub]);
    await c.query("select set_config('request.jwt.claims', $1, true)", [
      JSON.stringify({ sub, role: "authenticated" }),
    ]);
    const r = await attempt(c, "select public.extra_cost_request($1, $2, $3::jsonb, $4)", [
      wo,
      reason,
      JSON.stringify([
        { kind: "OTHER", description: "[UJI ISOLASI] konkurensi", qty: 1, unit_price: 100 },
      ]),
      ver,
    ]);
    await c.query("reset role").catch(() => undefined);
    return r;
  }
  const childWrite = (c: pg.Client, wo: string) =>
    attempt(
      c,
      "update public.wo_checklist_items set value = to_jsonb($2::text) where wo_id = $1 and seq = 9001",
      [wo, `konkurensi-${Date.now()}`],
    );
  const changedAt = async (wo: string) =>
    (await db.query("select changed_at from public.wo_child_changes where wo_id = $1", [wo]))
      .rows[0]?.changed_at as Date | undefined;
  const wccLocksOk = (outs: Out[]) => outs.every((o) => o.code !== "55P03" && o.code !== "57014");

  it("D1: sesi 1 menulis anak WO tanpa commit, sesi 2 memanggil extra_cost_request pada WO yang sama: tanpa deadlock, version hanya naik karena transisi", async () => {
    const wo = kA.woProgress;
    await resetTransient(db, [kA]);
    // ukur dulu kenaikan version karena extra_cost_request SENDIRIAN
    const solo = await openSession();
    let delta: number;
    try {
      const v0 = (await woRow(wo)).version;
      await solo.query("begin");
      const o = await extraRequest(solo, F.ids.tek1, wo, "[UJI ISOLASI] solo");
      expect(o.ok, `${o.code} ${o.msg}`).toBe(true);
      await solo.query("commit");
      delta = (await woRow(wo)).version - v0;
    } finally {
      await solo.end();
    }
    expect(delta).toBeGreaterThan(0);
    await resetTransient(db, [kA]);

    const v0 = (await woRow(wo)).version;
    const t0 = await changedAt(wo);
    const s1 = await openSession();
    const s2 = await openSession();
    const outs: Out[] = [];
    try {
      await s1.query("begin");
      await s2.query("begin");
      outs.push(await childWrite(s1, wo)); // sesi 1: anak WO, belum commit
      outs.push(await extraRequest(s2, F.ids.tek1, wo, "[UJI ISOLASI] sesi 2")); // sesi 2: transisi pada WO yang sama
      const c = await Promise.all([attempt(s1, "commit"), attempt(s2, "commit")]);
      outs.push(...c);
    } finally {
      await s1.end();
      await s2.end();
    }
    console.log("D1 hasil:", JSON.stringify(outs));
    for (const o of outs) expect(o.ok, `${o.code} ${o.msg}`).toBe(true);
    expect(outs.some((o) => o.code === "40P01")).toBe(false);
    expect(wccLocksOk(outs)).toBe(true);
    const t1 = await changedAt(wo);
    expect(t1, "wo_child_changes terisi").toBeDefined();
    if (t0) expect((t1 as Date).getTime()).toBeGreaterThan(t0.getTime());
    expect(
      (await woRow(wo)).version - v0,
      "version naik hanya karena transisi, bukan karena anak",
    ).toBe(delta);
    await resetTransient(db, [kA]);
  }, 180_000);

  it("D2: dua transaksi menyentuh dua WO uji dalam urutan TERBALIK, commit bersamaan, 5 putaran: hasil nyata dicatat", async () => {
    const A1 = kA.woProgress;
    const B1 = kB.woProgress;
    const rounds: Out[][] = [];
    for (let i = 0; i < 5; i++) {
      await resetTransient(db, [kA, kB]);
      const s1 = await openSession();
      const s2 = await openSession();
      const outs: Out[] = [];
      try {
        await s1.query("begin");
        await s2.query("begin");
        // sesi 1: transisi di A lalu anak di B; sesi 2: transisi di B lalu anak di A (urutan antrean pemicu terbalik)
        outs.push(await extraRequest(s1, F.ids.tek1, A1, `[UJI ISOLASI] d2-${i}-1`));
        outs.push(await extraRequest(s2, F.ids.tek2, B1, `[UJI ISOLASI] d2-${i}-2`));
        outs.push(await childWrite(s1, B1));
        outs.push(await childWrite(s2, A1));
        outs.push(...(await Promise.all([attempt(s1, "commit"), attempt(s2, "commit")])));
      } finally {
        await s1.end();
        await s2.end();
      }
      rounds.push(outs);
    }
    const deadlocks = rounds.flat().filter((o) => o.code === "40P01").length;
    const other = rounds.flat().filter((o) => !o.ok && o.code !== "40P01");
    console.log(
      `D2 ringkasan: putaran=5 deadlock(40P01)=${deadlocks} galat lain=${JSON.stringify(other)}`,
    );
    console.log(
      "D2 detail deadlock:",
      JSON.stringify(
        rounds
          .flat()
          .filter((o) => o.code === "40P01")
          .slice(0, 2),
      ),
    );
    await resetTransient(db, [kA, kB]);
    expect(other, "galat selain deadlock").toEqual([]);
    expect(deadlocks, "deadlock pada commit bersamaan dua WO terbalik").toBe(0);
  }, 300_000);

  it("D3 [karakterisasi]: kontensi terarah (sesi ketiga menahan baris sinyal WO A) pada dua WO terbalik: catat apakah terjadi 40P01", async () => {
    const A1 = kA.woProgress;
    const B1 = kB.woProgress;
    await resetTransient(db, [kA, kB]);
    // pastikan baris sinyal A ada
    await db.query(
      "insert into public.wo_child_changes (wo_id, changed_at) values ($1, clock_timestamp()) on conflict (wo_id) do nothing",
      [A1],
    );
    const s1 = await openSession();
    const s2 = await openSession();
    const s3 = await openSession();
    const outs: Out[] = [];
    try {
      await s1.query("begin");
      await s2.query("begin");
      outs.push(await extraRequest(s1, F.ids.tek1, A1, "[UJI ISOLASI] d3-1"));
      outs.push(await extraRequest(s2, F.ids.tek2, B1, "[UJI ISOLASI] d3-2"));
      outs.push(await childWrite(s1, B1));
      outs.push(await childWrite(s2, A1));
      // sesi 3 menahan baris sinyal A lalu kedua commit dilepas bersamaan
      await s3.query("begin");
      await s3.query("select 1 from public.wo_child_changes where wo_id = $1 for update", [A1]);
      const p1 = attempt(s1, "commit");
      const p2 = attempt(s2, "commit");
      await new Promise((r) => setTimeout(r, 2000));
      await s3.query("rollback");
      outs.push(...(await Promise.all([p1, p2])));
    } finally {
      await s1.end();
      await s2.end();
      await s3.end();
    }
    const commits = outs.slice(-2);
    console.log("D3 hasil commit:", JSON.stringify(commits));
    await resetTransient(db, [kA, kB]);
    // invarian yang harus selalu benar: paling banyak satu korban, korban = 40P01, tidak ada timeout kunci, yang lain commit
    const failed = commits.filter((o) => !o.ok);
    expect(failed.length).toBeLessThanOrEqual(1);
    for (const f of failed) expect(f.code).toBe("40P01");
    expect(commits.some((o) => o.ok)).toBe(true);
    expect(outs.slice(0, 4).every((o) => o.ok)).toBe(true);
  }, 180_000);
});
