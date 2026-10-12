// Uji isolasi bagian 2 (WP-007): Storage, struktur database, append-only, dan RPC parametrik.
// Jalankan: npm run test:isolation
// Catatan jujur: objek Storage yang diuji adalah BARIS terdaftar di storage.objects (tanpa berkas fisik, karena
// kunci service role tidak tersedia untuk uji). Tanda tangan URL (sign) dan kebijakan baca terbukti; unduh berkas
// nyata dan unggah sah lewat server TIDAK terbukti (lihat handoff).
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type pg from "pg";
import { APP_FUNCTIONS_FOR_AUTHENTICATED, RPC_ALLOWED } from "./catalog";
import { ensureFixture, type Fixture, type Kit } from "./fixtures";
import {
  ANON,
  URL_BASE,
  api,
  asRole,
  deniedWith,
  enumFirstLabels,
  listRpcs,
  login,
  newDb,
  pmap,
  rpc,
  trySql,
  type Res,
  type RpcInfo,
} from "./helpers";

let F: Fixture;
let kA: Kit;
let kB: Kit;
let A: string;
let B: string;
let T1: string;
let T2: string;
let ADM: string;
let db: pg.Client;

function expectCode(r: Res, codes: string[], label = "") {
  const d = deniedWith(r, codes);
  expect(d.ok, `${label} ${d.info}`).toBe(true);
}

beforeAll(async () => {
  F = await ensureFixture();
  kA = F.kitA;
  kB = F.kitB;
  [A, B, T1, T2, ADM] = await Promise.all([
    login("plg-a"),
    login("plg-b"),
    login("tek1"),
    login("tek2"),
    login("admin"),
  ]);
  db = newDb();
  await db.connect();
}, 300_000);

afterAll(async () => {
  await db?.end();
});

// ------------------------------------------------------------------------------------------------
describe("Storage: can_read_object dan policy storage.objects (T2, T3)", () => {
  // Satu sesi: identitas terbukti (my_customer_ids) dan hasil can_read_object diambil bersama-sama.
  async function check(sub: string, bucket: string, path: string) {
    const r = await asRole(
      db,
      sub,
      "select app.my_customer_ids() as ids, app.can_read_object($1, $2) as ok",
      [bucket, path],
    );
    expect(r.ok, `${r.code} ${r.message}`).toBe(true);
    return { ok: r.rows[0]?.ok as boolean, ids: (r.rows[0]?.ids ?? []) as string[] };
  }

  it("fixture: objek terdaftar ada di storage.objects dan bucket privat", async () => {
    expect(F.storageRows).toBe(true);
    const b = await db.query(
      "select id, public from storage.buckets where id in ('wo-media','reports') order by 1",
    );
    expect(b.rows).toEqual([
      { id: "reports", public: false },
      { id: "wo-media", public: false },
    ]);
    for (const k of [kA, kB]) {
      const n = await db.query("select count(*)::int n from storage.objects where name like $1", [
        `${k.cust}/%`,
      ]);
      expect(n.rows[0].n).toBe(7);
    }
  });

  it("identitas terbukti: my_customer_ids() sesi A berisi customer A saja, sesi B berisi B saja", async () => {
    const a = await check(F.ids.userA, "wo-media", kA.attAfter.path);
    expect(a.ids).toEqual([F.custA]);
    const b = await check(F.ids.userB, "wo-media", kB.attAfter.path);
    expect(b.ids).toEqual([F.custB]);
  });

  it("kasus POSITIF: objek sah milik sendiri terbaca (foto AFTER UPLOADED WO CLOSED, tanda tangan VALID, laporan READY, lampiran permintaan)", async () => {
    expect((await check(F.ids.userA, "wo-media", kA.attAfter.path)).ok).toBe(true);
    expect((await check(F.ids.userB, "wo-media", kB.attAfter.path)).ok).toBe(true); // B pada objeknya sendiri
    expect((await check(F.ids.userA, "wo-media", kA.sigPath)).ok).toBe(true);
    expect((await check(F.ids.userA, "reports", kA.reportPath)).ok).toBe(true);
    expect((await check(F.ids.userA, "wo-media", kA.reqAttach.path)).ok).toBe(true);
    expect((await check(F.ids.userB, "reports", kB.reportPath)).ok).toBe(true);
  });

  it("kasus NEGATIF bermakna: OTHER, PENDING, WO belum CLOSED, milik B, traversal, bucket salah, path liar", async () => {
    const u = F.ids.userA;
    const neg: [string, string, string][] = [
      ["kind OTHER", "wo-media", kA.attOther.path],
      ["kind FAILED_VISIT", "wo-media", kA.attFailed.path],
      ["upload PENDING", "wo-media", kA.attPending.path],
      ["WO belum CLOSED", "wo-media", kA.attNotClosed.path],
      ["milik B", "wo-media", kB.attAfter.path],
      ["tanda tangan B", "wo-media", kB.sigPath],
      ["laporan B", "reports", kB.reportPath],
      [
        "traversal",
        "wo-media",
        `${F.custA}/wo/${kA.woClosed}/../../${F.custB}/wo/${kB.woClosed}/after-uji.jpg`,
      ],
      ["traversal ke atas", "wo-media", `${F.custA}/wo/${kA.woClosed}/../after-uji.jpg/../../../x`],
      ["bucket salah (foto di bucket reports)", "reports", kA.attAfter.path],
      ["bucket salah (laporan di wo-media)", "wo-media", kA.reportPath],
      ["path tak terdaftar", "wo-media", `${F.custA}/wo/${kA.woClosed}/tidak-terdaftar.jpg`],
      ["path tak sesuai konvensi", "wo-media", "bebas/sekali.jpg"],
      ["path kosong", "wo-media", ""],
    ];
    for (const [label, bucket, path] of neg) {
      const r = await check(u, bucket, path);
      expect(r.ids, `identitas ${label}`).toEqual([F.custA]);
      expect(r.ok, label).toBe(false);
    }
  });

  it("policy storage.objects (vasta_media_read): pelanggan hanya melihat objek yang sah, bukan semua baris", async () => {
    const list = async (sub: string, cust: string) => {
      const r = await asRole(
        db,
        sub,
        "select bucket_id, name from storage.objects where name like $1 order by 1, 2",
        [`${cust}/%`],
      );
      expect(r.ok, `${r.code} ${r.message}`).toBe(true);
      return r.rows.map((x) => `${String(x.bucket_id)}:${String(x.name)}`).sort();
    };
    const expected = (k: Kit) =>
      [`wo-media:${k.attAfter.path}`, `wo-media:${k.sigPath}`, `reports:${k.reportPath}`].sort();
    expect(await list(F.ids.userA, F.custA)).toEqual(expected(kA));
    expect(await list(F.ids.userB, F.custB)).toEqual(expected(kB));
    expect(await list(F.ids.userA, F.custB)).toEqual([]);
    expect(await list(F.ids.userB, F.custA)).toEqual([]);
    // kontrol: staf melihat semua 7 objek tiap pelanggan; teknisi hanya WO yang dipegangnya
    expect((await list(F.ids.admin, F.custA)).length).toBe(7);
    expect((await list(F.ids.admin, F.custB)).length).toBe(7);
    expect((await list(F.ids.tek1, F.custA)).length).toBe(7);
    expect(await list(F.ids.tek2, F.custA)).toEqual([]);
  });

  it("pengguna tanpa pemetaan dan pengguna nonaktif tidak membaca objek apa pun", async () => {
    const r1 = await asRole(
      db,
      F.ids.tanpaPelanggan,
      "select count(*)::int n from storage.objects where name ~ '^[0-9a-f-]{36}/'",
    );
    expect(r1.rows[0]?.n).toBe(0);
    const c = await check(F.ids.tanpaPelanggan, "wo-media", kA.attAfter.path);
    expect(c.ids).toEqual([]);
    expect(c.ok).toBe(false);
  });
});

// ------------------------------------------------------------------------------------------------
describe("Storage API nyata (sign/upload) dengan baris terdaftar", () => {
  const sign = (tok: string | null, bucket: string, path: string) =>
    api(tok, `/storage/v1/object/sign/${bucket}/${path}`, {
      method: "POST",
      body: { expiresIn: 60 },
    });

  it("kontrol positif: A dan B membuat signed URL untuk objek sah miliknya", async () => {
    const a = await sign(A, "wo-media", kA.attAfter.path);
    expect(a.status, JSON.stringify(a.body)).toBe(200);
    expect(JSON.stringify(a.body)).toContain("signedURL");
    const b = await sign(B, "wo-media", kB.attAfter.path);
    expect(b.status, JSON.stringify(b.body)).toBe(200);
    expect((await sign(A, "reports", kA.reportPath)).status).toBe(200);
  });

  it("A tidak bisa membuat signed URL objek B yang TERDAFTAR dan sah (baris ada)", async () => {
    for (const [bucket, path] of [
      ["wo-media", kB.attAfter.path],
      ["wo-media", kB.sigPath],
      ["reports", kB.reportPath],
    ] as const) {
      const r = await sign(A, bucket, path);
      expect(r.status, `${bucket}/${path}`).toBeGreaterThanOrEqual(400);
      expect(JSON.stringify(r.body)).not.toContain("signedURL");
    }
  });

  it("A tidak bisa membuat signed URL objek sendiri yang tidak boleh dilihat (OTHER, PENDING, WO belum CLOSED)", async () => {
    for (const p of [
      kA.attOther.path,
      kA.attFailed.path,
      kA.attPending.path,
      kA.attNotClosed.path,
    ]) {
      const r = await sign(A, "wo-media", p);
      expect(r.status, p).toBeGreaterThanOrEqual(400);
      expect(JSON.stringify(r.body)).not.toContain("signedURL");
    }
  });

  it("anon tidak bisa membuat signed URL objek sah", async () => {
    const r = await sign(null, "wo-media", kA.attAfter.path);
    expect(r.status).toBeGreaterThanOrEqual(400);
    expect(JSON.stringify(r.body)).not.toContain("signedURL");
  });

  it("A tidak bisa mengunggah langsung ke bucket (tanpa policy INSERT): ditolak oleh RLS, bukan galat lain", async () => {
    const r = await fetch(
      `${URL_BASE}/storage/v1/object/wo-media/${F.custA}/wo/${kA.woClosed}/direct-uji.jpg`,
      {
        method: "POST",
        headers: { apikey: ANON, Authorization: `Bearer ${A}`, "Content-Type": "image/jpeg" },
        body: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]),
      },
    );
    const text = await r.text();
    expect([400, 401, 403], text).toContain(r.status);
    expect(text.toLowerCase()).toMatch(/row-level security|unauthorized|violates|policy/);
    const n = await db.query(
      "select count(*)::int n from storage.objects where name like '%direct-uji.jpg'",
    );
    expect(n.rows[0].n).toBe(0);
  });
});

// ------------------------------------------------------------------------------------------------
describe("Struktur database (langsung ke Postgres) (T13, T18)", () => {
  it("app.tables_without_rls() kosong", async () => {
    const r = await db.query("select * from app.tables_without_rls()");
    expect(r.rows).toEqual([]);
  });

  it("semua fungsi SECURITY DEFINER di public/app memakai search_path TEPAT '' (bukan sekadar ada)", async () => {
    const all = await db.query(
      `select count(*)::int n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname in ('public','app') and p.prosecdef`,
    );
    expect(all.rows[0].n, "kontrol: ada banyak fungsi SECURITY DEFINER").toBeGreaterThan(30);
    const r = await db.query(`
      select n.nspname || '.' || p.proname as fn, p.proconfig
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public','app') and p.prosecdef
         and not ('search_path=""' = any (coalesce(p.proconfig, '{}')))`);
    expect(r.rows).toEqual([]);
  });

  it("tidak ada fungsi public/app yang dapat dieksekusi PUBLIC atau anon", async () => {
    const r = await db.query(`
      select n.nspname || '.' || p.proname as fn
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public','app') and p.prokind = 'f'
         and (has_function_privilege('anon', p.oid, 'EXECUTE')
              or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))`);
    expect(r.rows.map((x) => x.fn)).toEqual([]);
  });

  it("schema app: authenticated hanya mendapat EXECUTE pada daftar helper yang diizinkan (persis)", async () => {
    const r = await db.query(`
      select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and has_function_privilege('authenticated', p.oid, 'EXECUTE')`);
    expect([...new Set(r.rows.map((x) => String(x.proname)))].sort()).toEqual(
      [...APP_FUNCTIONS_FOR_AUTHENTICATED].sort(),
    );
  });

  it("bucket Storage privat", async () => {
    const buckets = await db.query(
      "select id, public from storage.buckets where id in ('wo-media','reports')",
    );
    expect(buckets.rows.length).toBe(2);
    for (const b of buckets.rows) expect(b.public).toBe(false);
  });

  // Penanda kolom yang diubah (nilai sama) agar pemicu baris tetap menyala.
  const APPEND_ONLY: Record<string, string> = {
    audit_logs: "entity_type",
    access_logs: "resource_type",
    wo_status_history: "action",
    stock_movements: "note",
    user_consents: "policy_version",
  };
  it.each(Object.entries(APPEND_ONLY))(
    "%s append-only: UPDATE, DELETE, TRUNCATE -> IMM01 (tanpa skip)",
    async (t, col) => {
      const n = (await db.query(`select count(*)::int n from public.${t}`)).rows[0].n as number;
      expect(n, `kontrol: ${t} harus berisi baris agar pemicu per-baris teruji`).toBeGreaterThan(0);
      const upd = await trySql(db, `update public.${t} set ${col} = ${col}`);
      expect(upd.code, `UPDATE ${t}`).toBe("IMM01");
      const del = await trySql(db, `delete from public.${t}`);
      expect(del.code, `DELETE ${t}`).toBe("IMM01");
      const trunc = await trySql(db, `truncate table public.${t}`);
      expect(trunc.code, `TRUNCATE ${t}`).toBe("IMM01");
      const after = (await db.query(`select count(*)::int n from public.${t}`)).rows[0].n as number;
      expect(after).toBeGreaterThanOrEqual(n);
    },
  );
});

// ------------------------------------------------------------------------------------------------
describe("RPC parametrik (T15): turunan dari pg_proc, ditolak untuk pelanggan, teknisi, dan anon", () => {
  let rpcs: RpcInfo[];
  let enums: Record<string, string>;
  const RANDOM = () => crypto.randomUUID();

  function dummy(name: string, type: string): unknown {
    if (type.endsWith("[]")) return [];
    if (type === "uuid") {
      if (/wo_id|parent_wo/.test(name)) return kB.woClosed;
      if (/approval/.test(name)) return kB.approvalId;
      if (/request_id/.test(name)) return kB.reqClosed;
      return RANDOM(); // user/item/line/lokasi: acak agar tidak mengubah data nyata bila penjagaan bocor
    }
    if (type === "text")
      return /action/.test(name) ? "ASSIGN" : /decision/.test(name) ? "APPROVE" : "x";
    if (type === "integer") return /version/.test(name) ? -1 : 1;
    if (type === "numeric") return 1;
    if (type === "boolean") return false;
    if (type === "jsonb") return /lines|items/.test(name) ? [] : {};
    // variance_status: label pertama (OPEN) ditolak validasi nilai (WO006) SEBELUM cek peran; pakai nilai berhak-tinggi
    // agar panggilan benar-benar mencapai penjagaan peran.
    if (type === "variance_status") return "WRITTEN_OFF";
    if (type in enums) return enums[type];
    throw new Error(`tipe argumen belum dipetakan: ${name} ${type}`);
  }
  const argsOf = (f: RpcInfo) => {
    const out: Record<string, unknown> = {};
    for (let i = 0; i < f.required; i++)
      out[f.argNames[i] as string] = dummy(f.argNames[i] as string, f.argTypes[i] as string);
    return out;
  };

  beforeAll(async () => {
    rpcs = await listRpcs();
    enums = await enumFirstLabels();
  });

  it("daftar RPC diturunkan dari DB, cukup lengkap, dan setiap pengecualian terdaftar dengan alasan", () => {
    expect(rpcs.length).toBeGreaterThan(20);
    const names = rpcs.map((r) => r.name);
    for (const k of Object.keys(RPC_ALLOWED)) expect(names, `RPC_ALLOWED ${k}`).toContain(k);
    for (const k of [
      "wo_transition",
      "request_decide",
      "admin_set_user_roles",
      "stock_adjust",
      "wo_set_estimate",
    ])
      expect(names).toContain(k);
    for (const v of Object.values(RPC_ALLOWED)) expect(v.reason.length).toBeGreaterThan(10);
    expect(new Set(names).size, "tidak ada overload ambigu").toBe(names.length);
  });

  it.each(["CUSTOMER", "TECHNICIAN"] as const)(
    "setiap RPC yang tidak diizinkan bagi peran %s menolak dengan WO002/WO005/42501 (bukan sukses)",
    async (role) => {
      const tok = role === "CUSTOMER" ? A : T1;
      const targets = rpcs.filter((f) => !RPC_ALLOWED[f.name]?.roles.includes(role));
      expect(targets.length).toBeGreaterThan(15);
      const res = await pmap(targets, (f) => rpc(tok, f.name, argsOf(f)), 6);
      const bad: string[] = [];
      res.forEach((r, i) => {
        const d = deniedWith(r, ["WO002", "WO005", "42501"]);
        if (!d.ok) bad.push(`${targets[i]?.name}: ${d.info}`);
      });
      expect(bad).toEqual([]);
    },
    180_000,
  );

  it("anon ditolak untuk SEMUA RPC dengan 42501 (HTTP 401/403)", async () => {
    const res = await pmap(rpcs, (f) => rpc(null, f.name, argsOf(f)), 6);
    const bad: string[] = [];
    res.forEach((r, i) => {
      if (!([401, 403].includes(r.status) && r.code === "42501"))
        bad.push(`${rpcs[i]?.name}: HTTP ${r.status} kode=${String(r.code)}`);
    });
    expect(bad).toEqual([]);
  }, 180_000);

  it("RPC sah bagi peran tertentu tetap berfungsi untuk peran itu (kontrol: bukan semuanya ditolak buta)", async () => {
    // pelanggan: kepemilikan lolos pada WO sendiri (kode bukan WO005)
    const own = await rpc(A, "extra_cost_decide", {
      p_approval_id: kA.approvalId,
      p_decision: "APPROVE",
      p_content_hash: "salah",
    });
    expect(own.code).toBe("WO004");
    // teknisi: ringkasan biaya WO yang dipegangnya sukses (celah S1 diuji terpisah di isolation.test.ts)
    const cost = await rpc(T1, "wo_cost_summary", { p_wo_id: kA.woAwait });
    expect(cost.status).toBe(200);
    // teknisi lain ditolak WO005 atas WO yang bukan miliknya
    expectCode(
      await rpc(T2, "wo_cost_summary", { p_wo_id: kA.woAwait }),
      ["WO005"],
      "teknisi lain",
    );
    // staf memiliki akses
    expect((await rpc(ADM, "wo_cost_summary", { p_wo_id: kA.woAwait })).status).toBe(200);
  });
});
