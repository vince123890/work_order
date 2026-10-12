// Uji migrasi 0017 (perbaikan deadlock N3). TIDAK PERNAH meng-commit apa pun ke schema public (atau schema aplikasi lain).
//  Fase A: transaksi pada database nyata (0016 sudah terpasang) -> jalankan 0017 -> pemeriksaan -> SELALU ROLLBACK.
//  Fase B: uji konkurensi NYATA di schema sementara n3_scratch (dibuat, dipakai, di-DROP CASCADE, lalu dibuktikan hilang):
//          kontrol negatif = desain 0016 (upsert on conflict), kandidat = desain 0017 (insert murni), plus stres pemadatan.
//  Fase C: bukti sesudah rollback / drop dengan sambungan baru.
// Pakai:  node tools/try-migration-0017.mjs [--rounds=40]
// DATABASE_URL dibaca dari .env.local (tidak dicetak; hanya host).
import { readFileSync, readdirSync, existsSync } from "node:fs";
import pg from "pg";

function loadEnv(path) {
  if (!existsSync(path)) return {};
  const out = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return out;
}
const env = { ...loadEnv(".env.local"), ...process.env };
const url = env.DATABASE_URL;
if (!url) {
  console.error("DATABASE_URL belum diisi di .env.local");
  process.exit(2);
}
const ROUNDS = Number(
  (process.argv.find((a) => a.startsWith("--rounds=")) ?? "--rounds=40").split("=")[1],
);
const files = readdirSync("supabase/migrations").filter((f) => /^0017_.*\.sql$/.test(f));
if (files.length !== 1) {
  console.error(`Harus ada tepat satu berkas 0017_*.sql, ditemukan ${files.length}`);
  process.exit(2);
}
const sql = readFileSync(`supabase/migrations/${files[0]}`, "utf8");
if (/^[ \t]*(begin|commit|rollback)[ \t]*;/im.test(sql) || /start\s+transaction/i.test(sql)) {
  console.error("Migrasi memuat perintah transaksi; ditolak demi keamanan uji-rollback.");
  process.exit(2);
}

const mk = () => new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
let failed = 0;
const log = (s) => console.log(s);
const check = (name, cond, detail = "") => {
  if (!cond) failed++;
  log(`${cond ? "OK    " : "GAGAL "} ${name}${detail ? ` -> ${detail}` : ""}`);
};
const info = (name, detail = "") => log(`INFO  ${name}${detail ? ` -> ${detail}` : ""}`);
const js = (x) => JSON.stringify(x);

log(`Terhubung ke ${new URL(url).host} | berkas: ${files[0]} | rounds per skenario: ${ROUNDS}`);

// =====================================================================================================================
// FASE A: uji dalam transaksi yang SELALU di-ROLLBACK
// =====================================================================================================================
log("\n== FASE A: migrasi 0017 di atas 0016 (transaksi, SELALU ROLLBACK) ==");
const viewCols = `select string_agg(column_name || ':' || data_type, ',' order by ordinal_position) s, count(*)::int n
                    from information_schema.columns where table_schema='public' and table_name='tech_work_orders'`;
const rowsDigest = `select count(*)::int n, coalesce(md5(string_agg(wo_id::text || '@' || changed_at::text, ',' order by wo_id, changed_at)), '') h
                      from public.wo_child_changes`;
let baseline = null;
const c = mk();
await c.connect();
const q = (t, p = []) => c.query(t, p);
const one = async (t, p = []) => (await q(t, p)).rows[0];
let migrationRan = false;
try {
  await q("begin");
  await q("set local lock_timeout = '15s'");
  await q("set local statement_timeout = '120s'");

  const pre =
    await one(`select to_regclass('public.wo_child_changes') t, to_regprocedure('app.tg_wo_child_changed()') f,
      (select count(*)::int from pg_constraint where conrelid = to_regclass('public.wo_child_changes') and contype = 'p') pk,
      (select pg_get_functiondef('app.tg_wo_child_changed()'::regprocedure) ilike '%on conflict%') upsert`);
  if (!pre.t || !pre.f)
    throw new Error("Prasyarat: migrasi 0016 belum terpasang pada database ini");
  check(
    "prasyarat: 0016 terpasang (PK wo_id ada, trigger memakai on conflict)",
    pre.pk === 1 && pre.upsert === true,
    js(pre),
  );
  const vb = await one(viewCols);
  const dg0 = await one(rowsDigest);
  baseline = { dg0, vb };
  info("keadaan awal", `baris sinyal=${dg0.n}, kolom view=${vb.n}`);

  await q(sql);
  migrationRan = true;
  check("migrasi 0017 berjalan tanpa galat", true);

  // --- struktur
  const uq = await one(
    `select count(*)::int n from pg_index where indrelid = 'public.wo_child_changes'::regclass and (indisunique or indisprimary)`,
  );
  check(
    "tidak ada PK/indeks unik pada wo_child_changes (penyebab deadlock hilang)",
    uq.n === 0,
    `${uq.n}`,
  );
  const nn = await one(
    `select attnotnull from pg_attribute where attrelid = 'public.wo_child_changes'::regclass and attname = 'wo_id'`,
  );
  check("wo_id tetap NOT NULL", nn.attnotnull === true);
  const ix = await one(
    `select count(*)::int n from pg_indexes where schemaname='public' and tablename='wo_child_changes' and indexname in ('ix_wo_child_changes_wo_at','ix_wo_child_changes_at')`,
  );
  check("indeks (wo_id, changed_at desc) dan indeks kursor 0016 ada", ix.n === 2, `${ix.n}`);
  const fsrc = await one(`select pg_get_functiondef('app.tg_wo_child_changed()'::regprocedure) d`);
  check("fungsi trigger tidak lagi memuat 'on conflict'", !/on conflict/i.test(fsrc.d));
  const trg = await one(
    `select count(*)::int n from pg_trigger where tgname = 'trg_wo_child_changed' and tgdeferrable and tginitdeferred and not tgisinternal`,
  );
  check("11 constraint trigger deferred tetap terpasang", trg.n === 11, `${trg.n}`);

  // --- view
  const va = await one(viewCols);
  check(
    "view tech_work_orders: daftar kolom, urutan, dan tipe IDENTIK dengan sebelum 0017",
    va.s === vb.s,
    `${vb.n} -> ${va.n} kolom`,
  );
  check(
    "view memuat children_changed_at (timestamptz)",
    /,children_changed_at:timestamp with time zone$/.test(va.s),
  );
  const vo = await one(
    `select reloptions from pg_class where oid = 'public.tech_work_orders'::regclass`,
  );
  check(
    "view security_barrier=true",
    (vo.reloptions ?? []).includes("security_barrier=true"),
    js(vo.reloptions),
  );
  const vp = await one(
    `select has_table_privilege('anon','public.tech_work_orders','SELECT') a, has_table_privilege('authenticated','public.tech_work_orders','SELECT') b`,
  );
  check("hak view: anon tidak, authenticated SELECT", vp.a === false && vp.b === true, js(vp));
  const vdef = await one(`select pg_get_viewdef('public.tech_work_orders'::regclass) d`);
  check("view membaca max(changed_at) per WO", /max\(/i.test(vdef.d));

  // --- RLS / GRANT tabel sinyal
  const rls = await one(
    `select relrowsecurity r from pg_class where oid = 'public.wo_child_changes'::regclass`,
  );
  check("RLS wo_child_changes tetap aktif", rls.r === true);
  const pol = await one(
    `select count(*)::int n from pg_policies where schemaname='public' and tablename='wo_child_changes' and cmd='SELECT'`,
  );
  check("2 policy SELECT sinyal tetap ada", pol.n === 2, `${pol.n}`);
  const tp =
    await one(`select has_table_privilege('anon','public.wo_child_changes','SELECT') a1, has_table_privilege('authenticated','public.wo_child_changes','SELECT') a2,
      has_table_privilege('authenticated','public.wo_child_changes','INSERT') i1, has_table_privilege('authenticated','public.wo_child_changes','UPDATE') u1,
      has_table_privilege('authenticated','public.wo_child_changes','DELETE') d1, has_table_privilege('anon','public.wo_child_changes','INSERT') i2`);
  check(
    "hak tabel: authenticated hanya SELECT; anon tidak ada",
    tp.a1 === false && tp.a2 === true && !tp.i1 && !tp.u1 && !tp.d1 && !tp.i2,
    js(tp),
  );
  const nors = (await q("select * from app.tables_without_rls()")).rows;
  check("app.tables_without_rls() kosong", nors.length === 0, js(nors));

  // --- fungsi
  for (const fn of [
    "app.tg_wo_child_changed()",
    "app.compact_wo_child_changes(interval, integer)",
  ]) {
    const r = await one(
      `select p.prosecdef, p.proconfig, has_function_privilege('anon', p.oid, 'EXECUTE') ax,
              has_function_privilege('authenticated', p.oid, 'EXECUTE') bx,
              not exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) no_public
         from pg_proc p where p.oid = $1::regprocedure`,
      [fn],
    );
    check(
      `${fn}: SECURITY DEFINER, search_path="" terkunci`,
      r.prosecdef && (r.proconfig ?? []).includes('search_path=""'),
      js(r.proconfig),
    );
    check(
      `${fn}: tidak dapat dieksekusi anon/authenticated/PUBLIC`,
      !r.ax && !r.bx && r.no_public,
      js({ ax: r.ax, bx: r.bx, no_public: r.no_public }),
    );
  }
  const sdNoPath = (
    await q(`select p.oid::regprocedure::text s from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname in ('public','app') and p.prosecdef and not ('search_path=""' = any (coalesce(p.proconfig, '{}')))`)
  ).rows;
  check(
    'semua fungsi SECURITY DEFINER di public/app ber-search_path=""',
    sdNoPath.length === 0,
    js(sdNoPath),
  );

  // --- backfill
  const dg1 = await one(rowsDigest);
  check(
    "backfill utuh: jumlah dan isi baris sinyal hasil 0016 identik (hash)",
    dg1.n === dg0.n && dg1.h === dg0.h,
    `${dg0.n} -> ${dg1.n}`,
  );

  // --- pg_cron
  const cronOn =
    (await one(`select count(*)::int n from pg_extension where extname='pg_cron'`)).n === 1;
  if (cronOn) {
    const j = await one(
      `select count(*)::int n, max(schedule) sch, max(command) cmd from cron.job where jobname = 'vasta_compact_wo_child_changes'`,
    );
    check(
      "pg_cron: job vasta_compact_wo_child_changes terjadwal",
      j.n === 1 && /compact_wo_child_changes/.test(j.cmd),
      js(j),
    );
  } else info("pg_cron tidak aktif pada database ini (job tidak diuji)");

  // --- idempoten
  await q("savepoint sp_idem");
  let idemOk = true,
    idemErr = "";
  try {
    await q(sql);
  } catch (e) {
    idemOk = false;
    idemErr = `${e.code} ${e.message}`;
  }
  await q(idemOk ? "release savepoint sp_idem" : "rollback to savepoint sp_idem");
  check("idempoten: menjalankan 0017 kedua kali tanpa galat", idemOk, idemErr);
  const dg2 = await one(rowsDigest);
  check(
    "idempoten: isi sinyal tidak berubah sesudah run kedua",
    dg2.h === dg0.h && dg2.n === dg0.n,
  );

  // --- perilaku: perubahan anak -> +1 baris (dedupe per transaksi), version/updated_at WO tidak naik, view membaca max
  const w = await one(`select wo.id::text id, wo.version, wo.updated_at::text ua, i.id::text item
                         from public.work_orders wo join public.wo_checklist_items i on i.wo_id = wo.id
                        where wo.status in ('IN_PROGRESS','ON_HOLD_PARTS','ACCEPTED','EN_ROUTE') order by wo.created_at limit 1`);
  if (w) {
    const cnt = async () =>
      await one(
        "select count(*)::int n, max(changed_at)::text mx from public.wo_child_changes where wo_id = $1",
        [w.id],
      );
    const b = await cnt();
    await q("update public.wo_checklist_items set value = value where id = $1", [w.item]);
    await q("set constraints all immediate");
    await q("set constraints all deferred");
    const a1 = await cnt();
    check(
      "perubahan anak menambah TEPAT 1 baris sinyal (insert murni)",
      a1.n === b.n + 1,
      `${b.n} -> ${a1.n}`,
    );
    await q("update public.wo_checklist_items set value = value where id = $1", [w.item]);
    await q("set constraints all immediate");
    await q("set constraints all deferred");
    const a2 = await cnt();
    check(
      "dedupe per WO per transaksi (GUC): perubahan kedua di transaksi sama tidak menambah baris",
      a2.n === a1.n,
      `${a1.n} -> ${a2.n}`,
    );
    const w2 = await one(
      "select version, updated_at::text ua from public.work_orders where id = $1",
      [w.id],
    );
    check(
      "work_orders.version dan updated_at TIDAK naik",
      w2.version === w.version && w2.ua === w.ua,
    );
    check("changed_at maju", new Date(a1.mx) > new Date(b.mx), `${b.mx} -> ${a1.mx}`);

    // pemadatan: 3 baris lama sintetis + baris lama hasil 0016 harus hilang, yang terbaru tetap
    await q(
      `insert into public.wo_child_changes (wo_id, changed_at) select $1, now() - (g || ' hours')::interval from generate_series(2, 4) g`,
      [w.id],
    );
    const preC = await one(
      "select count(*)::int n, count(distinct wo_id)::int d, max(changed_at)::text mx from public.wo_child_changes",
    );
    const mxWo = (await cnt()).mx;
    // baris segar (1 menit) yang bukan terbaru: ditahan oleh masa tenggang bawaan 10 menit
    await q(
      "insert into public.wo_child_changes (wo_id, changed_at) values ($1, clock_timestamp() - interval '1 minute')",
      [w.id],
    );
    const grace = await one("select app.compact_wo_child_changes() n");
    const keptFresh = (await cnt()).n;
    check(
      "masa tenggang: baris < 10 menit yang bukan terbaru tidak dihapus oleh pemadatan bawaan",
      keptFresh >= 2,
      `sisa ${keptFresh} baris untuk WO uji, dihapus ${grace.n}`,
    );
    const del = await one("select app.compact_wo_child_changes(interval '0') n");
    const postC = await one(
      "select count(*)::int n, count(distinct wo_id)::int d from public.wo_child_changes",
    );
    const wo2 = await cnt();
    check(
      "pemadatan: tepat satu baris per WO tersisa",
      postC.n === postC.d,
      `${preC.n} -> ${postC.n} baris, ${postC.d} WO`,
    );
    check(
      "pemadatan: jumlah WO yang punya sinyal tidak berkurang",
      postC.d === preC.d,
      `${preC.d} -> ${postC.d}`,
    );
    check(
      "pemadatan: baris terbaru WO uji tetap (max(changed_at) sama)",
      wo2.n === 1 && wo2.mx === mxWo,
      `${mxWo} vs ${wo2.mx}`,
    );
    info("baris yang dihapus pemadatan", `${del.n}`);
    const hb = await one(
      "select status::text s, rows_affected from public.job_runs where job_name = 'compact_wo_child_changes' order by id desc limit 1",
    );
    check("heartbeat job_runs OK", hb?.s === "OK" && hb.rows_affected === del.n, js(hb));
    const again = await one("select app.compact_wo_child_changes(interval '0') n");
    check("pemadatan idempoten (run kedua menghapus 0)", again.n === 0, `${again.n}`);
  } else info("uji perilaku trigger dilewati: tidak ada WO/butir checklist yang cocok");
} catch (e) {
  failed++;
  log(`GAGAL galat tak terduga fase A: ${e.code ?? ""} ${e.message}`);
} finally {
  try {
    await c.query("rollback");
    log("ROLLBACK dijalankan (fase A tidak meng-commit apa pun).");
  } catch (e) {
    failed++;
    log(`PERINGATAN: rollback gagal: ${e.message}`);
  }
  await c.end().catch(() => {});
}

// =====================================================================================================================
// FASE B: konkurensi nyata di schema sementara n3_scratch
// =====================================================================================================================
log("\n== FASE B: konkurensi nyata di schema sementara n3_scratch (bukan public) ==");
const migFn = /create or replace function app\.compact_wo_child_changes[\s\S]*?end \$\$;/.exec(
  sql,
)?.[0];
const trgFn = /create or replace function app\.tg_wo_child_changed[\s\S]*?end \$\$;/.exec(sql)?.[0];
if (!migFn || !trgFn) throw new Error("fungsi 0017 tidak ditemukan di berkas migrasi");
// Fungsi 0017 DIPAKAI APA ADANYA dari berkas migrasi; hanya nama schema/tabel yang dipetakan ke n3_scratch (dan sleep opsional
// untuk memperlebar jendela balapan, sama untuk kedua desain).
const sleepStmt = `perform pg_sleep(coalesce(nullif(current_setting('n3.delay', true), ''), '0')::float8);`;
const fn17 = trgFn
  .replace("app.tg_wo_child_changed", "n3_scratch.fn17")
  .replace("public.wo_child_changes", "n3_scratch.sig17")
  .replace("return null;\nend $$;", () => `${sleepStmt}\n  return null;\nend $$;`);
const fnCompact = migFn
  .replace("app.compact_wo_child_changes", "n3_scratch.compact")
  .replace(/public\.wo_child_changes/g, "n3_scratch.sig17")
  .replace(/public\.job_runs/g, "n3_scratch.job_runs");
if (!/n3_scratch\.sig17/.test(fn17) || !/pg_sleep/.test(fn17) || /public\./.test(fn17 + fnCompact))
  throw new Error("pemetaan fungsi ke schema sementara gagal");
// Desain 0016 (kontrol negatif), tepat seperti di 0016 (insert ... on conflict do update).
const fn16 = `create or replace function n3_scratch.fn16() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_key text := 'app.wcc_' || replace(new.wo_id::text, '-', '_');
begin
  if coalesce(current_setting(v_key, true), '') = '1' then return null; end if;
  perform set_config(v_key, '1', true);
  insert into n3_scratch.sig16 as c (wo_id, changed_at) values (new.wo_id, clock_timestamp())
  on conflict (wo_id) do update set changed_at = excluded.changed_at;
  ${sleepStmt}
  return null;
end $$;`;

const admin = mk();
await admin.connect();
let scratchCreated = false;
const results = [];
try {
  await admin.query("drop schema if exists n3_scratch cascade");
  await admin.query(`
    create schema n3_scratch;
    create table n3_scratch.sig16 (wo_id uuid primary key, changed_at timestamptz not null default clock_timestamp());
    create table n3_scratch.sig17 (wo_id uuid not null, changed_at timestamptz not null default clock_timestamp());
    create index on n3_scratch.sig17 (wo_id, changed_at desc);
    create table n3_scratch.ch16 (id bigserial primary key, wo_id uuid not null);
    create table n3_scratch.ch17 (id bigserial primary key, wo_id uuid not null);
    create table n3_scratch.job_runs (id bigint generated always as identity primary key, job_name text not null,
      started_at timestamptz not null default now(), finished_at timestamptz, status text not null default 'RUNNING',
      rows_affected int, error text);
  `);
  scratchCreated = true;
  await admin.query(fn16);
  await admin.query(fn17);
  await admin.query(fnCompact);
  await admin.query(`
    create constraint trigger trg16 after insert on n3_scratch.ch16 deferrable initially deferred for each row execute function n3_scratch.fn16();
    create constraint trigger trg17 after insert on n3_scratch.ch17 deferrable initially deferred for each row execute function n3_scratch.fn17();
  `);
  await admin.query("update n3_scratch.job_runs set status = status"); // pastikan tabel dapat dipakai
  info(
    "schema n3_scratch dibuat",
    "fn17 dan compact diambil dari berkas migrasi (hanya nama tabel dipetakan)",
  );

  const ids = () => [crypto.randomUUID(), crypto.randomUUID()];
  async function round(design, delay) {
    const [A, B] = ids();
    const sig = `n3_scratch.sig${design}`;
    const ch = `n3_scratch.ch${design}`;
    await admin.query(`insert into ${sig} (wo_id) values ($1), ($2)`, [A, B]); // sinyal sudah ada (seperti hasil backfill)
    const c1 = mk(),
      c2 = mk();
    await Promise.all([c1.connect(), c2.connect()]);
    const out = [];
    try {
      for (const k of [c1, c2]) {
        await k.query("begin");
        await k.query(`set n3.delay = '${delay}'`);
        await k.query("set lock_timeout = '20s'");
      }
      await c1.query(`insert into ${ch} (wo_id) values ($1)`, [A]);
      await c2.query(`insert into ${ch} (wo_id) values ($1)`, [B]);
      await c1.query(`insert into ${ch} (wo_id) values ($1)`, [B]);
      await c2.query(`insert into ${ch} (wo_id) values ($1)`, [A]); // urutan TERBALIK
      const commit = (k) =>
        k.query("commit").then(
          () => ({ ok: true }),
          (e) => ({ ok: false, code: e.code, msg: e.message.slice(0, 120) }),
        );
      out.push(...(await Promise.all([commit(c1), commit(c2)])));
      for (const k of [c1, c2]) await k.query("rollback").catch(() => {});
    } finally {
      await c1.end().catch(() => {});
      await c2.end().catch(() => {});
    }
    const committed = out.filter((o) => o.ok).length;
    const cnt = (await admin.query(`select count(*)::int n from ${sig} where wo_id = $1`, [A]))
      .rows[0].n;
    return { out, committed, cntA: cnt };
  }
  async function scenario(label, design, delay) {
    let dead = 0,
      other = 0,
      bothOk = 0,
      lost = 0,
      sample = "";
    for (let i = 0; i < ROUNDS; i++) {
      const r = await round(design, delay);
      const d = r.out.filter((o) => !o.ok && o.code === "40P01").length;
      const o = r.out.filter((x) => !x.ok && x.code !== "40P01");
      if (d) dead++;
      if (o.length) {
        other++;
        sample = js(o[0]);
      }
      if (r.committed === 2) bothOk++;
      // tidak ada sinyal hilang: baris awal (1) + satu baris per transaksi yang COMMIT dan menyentuh A (desain 0017);
      // desain 0016 hanya satu baris per WO (upsert), jadi diperiksa hanya bahwa baris ada.
      if (design === "17" ? r.cntA !== 1 + r.committed : r.cntA !== 1) lost++;
    }
    results.push({ label, design, delay, rounds: ROUNDS, dead, other, bothOk, lost });
    info(
      label,
      `${ROUNDS} putaran: putaran dengan deadlock 40P01=${dead}, galat lain=${other}${sample ? " " + sample : ""}, kedua commit sukses=${bothOk}, sinyal tidak sesuai=${lost}`,
    );
    return { dead, other, lost };
  }

  const k16a = await scenario("KONTROL 0016 (upsert on conflict), tanpa sleep ", "16", "0");
  const k16b = await scenario("KONTROL 0016 (upsert on conflict), jendela +50ms", "16", "0.05");
  const n17a = await scenario("DESAIN 0017 (insert murni), tanpa sleep         ", "17", "0");
  const n17b = await scenario("DESAIN 0017 (insert murni), jendela +50ms        ", "17", "0.05");
  check(
    "kontrol negatif: desain 0016 TERBUKTI deadlock (uji sahih)",
    k16a.dead + k16b.dead > 0,
    `${k16a.dead} + ${k16b.dead} putaran`,
  );
  check(
    "desain 0017: 0 deadlock tanpa sleep",
    n17a.dead === 0 && n17a.other === 0,
    `${n17a.dead} deadlock, ${n17a.other} galat lain`,
  );
  check(
    "desain 0017: 0 deadlock dengan jendela diperlebar",
    n17b.dead === 0 && n17b.other === 0,
    `${n17b.dead} deadlock, ${n17b.other} galat lain`,
  );
  check(
    "desain 0017: tidak ada sinyal hilang (baris = 1 awal + 1 per transaksi yang commit)",
    n17a.lost === 0 && n17b.lost === 0,
  );
  if (k16a.dead + k16b.dead === 0)
    info("PERINGATAN: kontrol 0016 tidak deadlock pada putaran ini; uji tidak membuktikan apa pun");

  // --- stres pemadatan: penulis bolak-balik + pemadat berjalan terus (min_age 0 = paling agresif)
  const W = 2,
    N = Math.max(20, ROUNDS);
  const wos = Array.from({ length: 4 }, () => crypto.randomUUID());
  await admin.query(
    "insert into n3_scratch.sig17 (wo_id, changed_at) select unnest($1::uuid[]), now() - interval '1 day'",
    [wos],
  );
  const lastBefore = new Map(wos.map((x) => [x, 0]));
  let stop = false,
    compErr = 0,
    compRuns = 0,
    compDeleted = 0;
  const comp = (async () => {
    const k = mk();
    await k.connect();
    try {
      while (!stop) {
        try {
          const r = await k.query("select n3_scratch.compact(interval '0', 50) n");
          compDeleted += r.rows[0].n;
          compRuns++;
        } catch (e) {
          compErr++;
        }
      }
    } finally {
      await k.end();
    }
  })();
  const comp2 = (async () => {
    // pemadat kedua bersamaan: harus melewati lewat advisory lock, tidak menunggu/deadlock
    const k = mk();
    await k.connect();
    try {
      while (!stop) {
        try {
          await k.query("select n3_scratch.compact(interval '0', 50)");
          compRuns++;
        } catch {
          compErr++;
        }
      }
    } finally {
      await k.end();
    }
  })();
  async function writer(order) {
    const k = mk();
    await k.connect();
    let errs = 0,
      dl = 0;
    try {
      for (let i = 0; i < N; i++) {
        const mine = order === 0 ? wos : [...wos].reverse();
        await k.query("begin");
        try {
          const before = (await k.query("select clock_timestamp() t")).rows[0].t;
          for (const x of mine)
            await k.query("insert into n3_scratch.ch17 (wo_id) values ($1)", [x]);
          await k.query("commit");
          for (const x of mine) if (before > (lastBefore.get(x) || 0)) lastBefore.set(x, before);
        } catch (e) {
          errs++;
          if (e.code === "40P01") dl++;
          await k.query("rollback").catch(() => {});
        }
      }
    } finally {
      await k.end();
    }
    return { errs, dl };
  }
  const ws = await Promise.all(Array.from({ length: W }, (_, i) => writer(i % 2)));
  stop = true;
  await Promise.all([comp, comp2]);
  const werr = ws.reduce((a, x) => a + x.errs, 0),
    wdl = ws.reduce((a, x) => a + x.dl, 0);
  const jr = (
    await admin.query(
      "select count(*) filter (where status = 'ERROR')::int e, count(*) filter (where status = 'OK')::int ok from n3_scratch.job_runs",
    )
  ).rows[0];
  const mx = (
    await admin.query(
      "select wo_id::text, max(changed_at) m from n3_scratch.sig17 where wo_id = any($1::uuid[]) group by wo_id",
      [wos],
    )
  ).rows;
  const behind = mx.filter((r) => new Date(r.m) < new Date(lastBefore.get(r.wo_id))).length;
  info(
    "stres pemadatan",
    `${W} penulis x ${N} transaksi (urutan WO berlawanan) + 2 pemadat; pemadatan=${compRuns} kali, baris dihapus=${compDeleted}`,
  );
  check(
    "stres: 0 galat/deadlock di penulis",
    werr === 0 && wdl === 0,
    `galat=${werr}, deadlock=${wdl}`,
  );
  check(
    "stres: pemadat tanpa galat (job_runs ERROR=0) dan tidak ada galat klien",
    jr.e === 0 && compErr === 0,
    `ERROR=${jr.e}, OK=${jr.ok}, galat klien=${compErr}`,
  );
  check(
    "stres: pemadatan tidak mengurangi max(changed_at) per WO di bawah waktu commit terakhir yang tercatat",
    behind === 0 && mx.length === wos.length,
    `${behind} WO tertinggal`,
  );
} catch (e) {
  failed++;
  log(`GAGAL galat tak terduga fase B: ${e.code ?? ""} ${e.message}`);
} finally {
  try {
    await admin.query("drop schema if exists n3_scratch cascade");
    const gone = (
      await admin.query("select count(*)::int n from pg_namespace where nspname = 'n3_scratch'")
    ).rows[0].n;
    check("DROP SCHEMA n3_scratch CASCADE: schema tidak ada lagi", gone === 0, `${gone}`);
  } catch (e) {
    failed++;
    log(`PERINGATAN: drop schema gagal: ${e.message}`);
  }
  await admin.end().catch(() => {});
}

// =====================================================================================================================
// FASE C: bukti sesudah rollback (sambungan baru)
// =====================================================================================================================
log("\n== FASE C: bukti sesudah rollback/drop (sambungan baru) ==");
{
  const v = mk();
  await v.connect();
  const o = async (t, p = []) => (await v.query(t, p)).rows[0];
  check(
    "fungsi app.compact_wo_child_changes tidak ada",
    (await o("select count(*)::int n from pg_proc where proname = 'compact_wo_child_changes'"))
      .n === 0,
  );
  check(
    "indeks ix_wo_child_changes_wo_at tidak ada",
    (
      await o(
        "select count(*)::int n from pg_indexes where indexname = 'ix_wo_child_changes_wo_at'",
      )
    ).n === 0,
  );
  check(
    "PK wo_id dari 0016 masih ada",
    (
      await o(
        "select count(*)::int n from pg_constraint where conrelid = 'public.wo_child_changes'::regclass and contype = 'p'",
      )
    ).n === 1,
  );
  check(
    "trigger masih versi 0016 (on conflict)",
    /on conflict/i.test(
      (await o("select pg_get_functiondef('app.tg_wo_child_changed()'::regprocedure) d")).d,
    ),
  );
  check(
    "view tech_work_orders masih versi 0016 (tanpa max())",
    !/max\(/i.test((await o("select pg_get_viewdef('public.tech_work_orders'::regclass) d")).d),
  );
  const vb2 = await o(viewCols);
  check("kolom view sama dengan sebelum uji", baseline && vb2.s === baseline.vb.s);
  const dgx = await o(rowsDigest);
  check(
    "isi wo_child_changes sama dengan sebelum uji (hash)",
    baseline && dgx.h === baseline.dg0.h && dgx.n === baseline.dg0.n,
    `${dgx.n} baris`,
  );
  check(
    "tidak ada baris job_runs 'compact_wo_child_changes'",
    (
      await o(
        "select count(*)::int n from public.job_runs where job_name = 'compact_wo_child_changes'",
      )
    ).n === 0,
  );
  const cronOn =
    (await o("select count(*)::int n from pg_extension where extname='pg_cron'")).n === 1;
  if (cronOn)
    check(
      "job cron vasta_compact_wo_child_changes tidak ada",
      (
        await o(
          "select count(*)::int n from cron.job where jobname = 'vasta_compact_wo_child_changes'",
        )
      ).n === 0,
    );
  check(
    "schema n3_scratch tidak ada",
    (await o("select count(*)::int n from pg_namespace where nspname = 'n3_scratch'")).n === 0,
  );
  await v.end();
}

log(
  `\nRINGKASAN: ${failed === 0 ? "SEMUA PEMERIKSAAN LULUS" : failed + " PEMERIKSAAN GAGAL"} (migrasi ${migrationRan ? "sempat dijalankan lalu di-ROLLBACK" : "tidak sempat berjalan"})`,
);
process.exit(failed === 0 ? 0 : 1);
