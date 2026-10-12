// Uji-coba migrasi 0016 pada database nyata di dalam SATU transaksi yang SELALU di-ROLLBACK (tidak pernah commit).
// Alur: BEGIN -> probe "sebelum" -> jalankan supabase/migrations/0016_*.sql -> pemeriksaan sanity + uji perilaku -> ROLLBACK
//       -> sambungan baru membuktikan database tidak berubah.
// Pakai:  node tools/try-migration.mjs
// DATABASE_URL dibaca dari .env.local (tidak dicetak; hanya host). Skrip ini tidak menulis ke supabase_migrations.
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
const files = readdirSync("supabase/migrations").filter((f) => /^0016_.*\.sql$/.test(f));
if (files.length !== 1) {
  console.error(`Harus ada tepat satu berkas 0016_*.sql, ditemukan ${files.length}`);
  process.exit(2);
}
const migrationFile = files[0];
const sql = readFileSync(`supabase/migrations/${migrationFile}`, "utf8");
if (/^\s*(begin|commit|rollback|end)\s*;/im.test(sql) || /start\s+transaction/i.test(sql)) {
  console.error(
    "Migrasi memuat perintah transaksi (begin/commit/rollback); ditolak demi keamanan uji-rollback.",
  );
  process.exit(2);
}

const mkClient = () => new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
const c = mkClient();
await c.connect();
console.log(
  `Terhubung ke ${new URL(url).host} | berkas: ${migrationFile} | MODE: transaksi, SELALU ROLLBACK`,
);

let failed = 0;
const log = (s) => console.log(s);
const check = (name, cond, detail = "") => {
  if (!cond) failed++;
  log(`${cond ? "OK    " : "GAGAL "} ${name}${detail ? ` -> ${detail}` : ""}`);
};
const info = (name, detail = "") => log(`INFO  ${name}${detail ? ` -> ${detail}` : ""}`);
const skip = (name, why) => log(`LEWAT ${name} (${why})`);
const js = (x) => JSON.stringify(x);

const q = (text, params = []) => c.query(text, params);
let spN = 0;
// Jalankan sebagai peran authenticated dengan sub JWT tertentu (meniru PostgREST), di dalam savepoint.
// keep=false: efek dibuang (rollback to savepoint); keep=true: efek dipertahankan sampai ROLLBACK akhir.
async function asUser(sub, text, params = [], { keep = false } = {}) {
  const sp = `sp_${++spN}`;
  await q(`savepoint ${sp}`);
  try {
    await q("set local role authenticated");
    await q(
      "select set_config('request.jwt.claim.sub', $1, true), set_config('request.jwt.claims', $2, true)",
      [sub, js({ sub, role: "authenticated" })],
    );
    const r = await q(text, params);
    await q("reset role");
    await q(
      "select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '', true)",
    );
    if (!keep) await q(`rollback to savepoint ${sp}`);
    await q(`release savepoint ${sp}`);
    return { ok: true, rows: r.rows };
  } catch (e) {
    await q(`rollback to savepoint ${sp}`);
    await q(`release savepoint ${sp}`);
    return { ok: false, code: e.code, message: e.message, detail: e.detail, rows: [] };
  }
}
// Sebagai sesi postgres (melewati RLS) dalam savepoint.
async function tryAdmin(text, params = [], { keep = false } = {}) {
  const sp = `sp_${++spN}`;
  await q(`savepoint ${sp}`);
  try {
    const r = await q(text, params);
    if (!keep) await q(`rollback to savepoint ${sp}`);
    await q(`release savepoint ${sp}`);
    return { ok: true, rows: r.rows };
  } catch (e) {
    await q(`rollback to savepoint ${sp}`);
    await q(`release savepoint ${sp}`);
    return { ok: false, code: e.code, message: e.message, detail: e.detail, rows: [] };
  }
}
const one = async (text, params = []) => (await q(text, params)).rows[0];

const NEW_PUBLIC_RPCS = [
  ["wo_declare_no_parts", "uuid, boolean, integer, uuid"],
  ["wo_closure_check", "uuid"],
  ["sync_op_record", "uuid, text, jsonb, boolean"],
  ["sync_rescued_resolve", "uuid, text"],
];

let migrationRan = false;
try {
  await q("begin");
  await q("set local lock_timeout = '15s'");
  await q("set local statement_timeout = '120s'");

  // ---------------------------------------------------------------- penemuan data uji (sebelum migrasi)
  const tech1 = await one(`
    select t.user_id::text uid, t.id::text tid, a.wo_id::text wo, w.version, w.status::text status, w.customer_id::text cust,
           w.estimate_total::text est
      from public.wo_assignments a
      join public.technicians t on t.id = a.technician_id and t.is_active
      join public.profiles p on p.user_id = t.user_id and p.is_active
      join public.work_orders w on w.id = a.wo_id
     where a.status = 'ACCEPTED' and a.role = 'LEAD' and w.status in ('IN_PROGRESS','ON_HOLD_PARTS','AWAITING_CUSTOMER_APPROVAL')
     order by (w.estimate_total is null), w.created_at limit 1`);
  const tech2 = tech1
    ? await one(
        `select t.user_id::text uid from public.technicians t join public.profiles p on p.user_id = t.user_id and p.is_active
          where t.is_active and t.user_id <> $1
            and not exists (select 1 from public.wo_assignments a where a.wo_id = $2 and a.technician_id = t.id
                             and a.status in ('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED'))
          limit 1`,
        [tech1.uid, tech1.wo],
      )
    : null;
  const custUser = tech1
    ? await one(
        `select cu.user_id::text uid from public.customer_users cu join public.profiles p on p.user_id = cu.user_id and p.is_active
          where cu.customer_id = $1 and cu.is_active limit 1`,
        [tech1.cust],
      )
    : null;
  const roleUser = async (role) =>
    (
      await one(
        `select ur.user_id::text uid from public.user_roles ur join public.profiles p on p.user_id = ur.user_id and p.is_active
          where ur.role = $1::public.app_role order by ur.user_id limit 1`,
        [role],
      )
    )?.uid;
  const staff = {};
  for (const r of ["ADMIN_CS", "DISPATCHER", "SUPERVISOR", "FINANCE", "OWNER", "WAREHOUSE"])
    staff[r] = await roleUser(r);
  const nonaktif = (
    await one("select id::text uid from auth.users where email = 'nonaktif@demo.vasta.test'")
  )?.uid;
  const woCount = (await one("select count(*)::int n from public.work_orders")).n;
  info(
    "data uji",
    `WO di DB=${woCount}; tech1=${tech1 ? "ada" : "TIDAK ada"}; tech2=${tech2 ? "ada" : "TIDAK ada"}; pelanggan WO=${custUser ? "ada" : "TIDAK ada"}; nonaktif=${nonaktif ? "ada" : "TIDAK ada"}`,
  );

  // objek Storage nyata untuk uji S4
  const repObj = await one(`
    with r as materialized (select name from storage.objects where bucket_id = 'reports'
                              and name ~ '^[0-9a-f-]{36}/wo/[0-9a-f-]{36}/')
    select t.user_id::text uid, r.name from r
      join public.wo_assignments a on a.wo_id = split_part(r.name, '/', 3)::uuid and a.status in ('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED')
      join public.technicians t on t.id = a.technician_id and t.is_active limit 1`);
  const mediaObj = await one(`
    with r as materialized (select name from storage.objects where bucket_id = 'wo-media'
                              and name ~ '^[0-9a-f-]{36}/wo/[0-9a-f-]{36}/')
    select t.user_id::text uid, r.name from r
      join public.wo_assignments a on a.wo_id = split_part(r.name, '/', 3)::uuid and a.status in ('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED')
      join public.technicians t on t.id = a.technician_id and t.is_active limit 1`);

  // ---------------------------------------------------------------- PROBE SEBELUM migrasi (membuktikan celah ada)
  log("\n== PROBE SEBELUM migrasi (perilaku lama) ==");
  let pre = {};
  if (tech1) {
    const a = await asUser(
      tech1.uid,
      "select count(*)::int n, bool_or(estimate_total is not null) has_est from public.work_orders",
    );
    pre.techRows = a.rows[0];
    info("G-08 lama: teknisi SELECT work_orders", js(a.rows[0]));
    const s = await asUser(tech1.uid, "select public.wo_cost_summary($1) r", [tech1.wo]);
    pre.costKeys = s.ok ? Object.keys(s.rows[0].r).sort() : [`galat ${s.code}`];
    info("S1 lama: kunci wo_cost_summary untuk teknisi", pre.costKeys.join(","));
  }
  if (repObj) {
    const a = await asUser(repObj.uid, "select app.can_read_object('reports', $1) ok", [
      repObj.name,
    ]);
    pre.techReports = a.rows[0]?.ok;
    info("S4 lama: teknisi can_read_object(reports, laporan WO-nya)", String(pre.techReports));
  }
  if (nonaktif) {
    await q("update public.profiles set is_active = false where user_id = $1", [nonaktif]);
    const a = await asUser(nonaktif, "select count(*)::int n from public.customer_users");
    pre.nonaktifCU = a.rows[0]?.n;
    info("N1 lama: akun nonaktif membaca customer_users", `${pre.nonaktifCU} baris`);
  }
  const sigColPre = (
    await one(
      "select count(*)::int n from information_schema.columns where table_schema='public' and table_name='wo_signatures' and column_name='upload_status'",
    )
  ).n;
  check("prasyarat: kolom wo_signatures.upload_status belum ada", sigColPre === 0);

  // ---------------------------------------------------------------- jalankan migrasi
  log("\n== MENJALANKAN MIGRASI (dalam transaksi) ==");
  await q("savepoint sp_migrasi");
  try {
    await q(sql);
    migrationRan = true;
    check("migrasi 0016 berjalan tanpa galat", true);
  } catch (e) {
    check(
      "migrasi 0016 berjalan tanpa galat",
      false,
      `${e.code} ${e.message}${e.where ? " | " + e.where.split("\n")[0] : ""}`,
    );
    throw e;
  }
  // idempoten: jalankan sekali lagi di atasnya
  try {
    await q(sql);
    check("migrasi 0016 idempoten (dijalankan dua kali tanpa galat)", true);
  } catch (e) {
    check(
      "migrasi 0016 idempoten (dijalankan dua kali tanpa galat)",
      false,
      `${e.code} ${e.message}`,
    );
    throw e;
  }

  // ---------------------------------------------------------------- SANITY struktur
  log("\n== SANITY struktur ==");
  for (const [fn, args] of NEW_PUBLIC_RPCS) {
    const r = await one(
      `select p.oid::regprocedure::text sig, p.prosecdef, p.proconfig,
              has_function_privilege('anon', p.oid, 'EXECUTE') anon_x,
              has_function_privilege('authenticated', p.oid, 'EXECUTE') auth_x,
              exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0) public_x
         from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = $1`,
      [fn],
    );
    check(`RPC public.${fn}(${args}) ada`, !!r);
    if (r) {
      check(
        `  ${fn}: SECURITY DEFINER dan search_path=""`,
        r.prosecdef && (r.proconfig ?? []).includes('search_path=""'),
      );
      check(
        `  ${fn}: anon TIDAK bisa execute, PUBLIC tidak, authenticated bisa`,
        !r.anon_x && !r.public_x && r.auth_x,
      );
    }
  }
  const col = async (t, cname) =>
    await one(
      "select data_type, column_default, is_nullable from information_schema.columns where table_schema='public' and table_name=$1 and column_name=$2",
      [t, cname],
    );
  const sigCol = await col("wo_signatures", "upload_status");
  check(
    "kolom wo_signatures.upload_status (default PENDING, not null)",
    !!sigCol && String(sigCol.column_default).includes("PENDING") && sigCol.is_nullable === "NO",
    js(sigCol),
  );
  const sigDist = (
    await q("select upload_status::text s, count(*)::int n from public.wo_signatures group by 1")
  ).rows;
  check(
    "baris wo_signatures lama berstatus UPLOADED semua",
    sigDist.every((x) => x.s === "UPLOADED"),
    js(sigDist),
  );
  for (const cn of ["resolved_at", "resolved_by", "resolved_note"])
    check(`kolom sync_operations.${cn}`, !!(await col("sync_operations", cn)));
  check(
    "tabel wo_child_changes + RLS aktif",
    (
      await one(
        "select relrowsecurity r from pg_class where oid = 'public.wo_child_changes'::regclass",
      )
    ).r === true,
  );
  const trgN = (
    await one(
      "select count(*)::int n from pg_trigger where tgname = 'trg_wo_child_changed' and not tgisinternal",
    )
  ).n;
  check("trigger trg_wo_child_changed terpasang di 11 tabel anak", trgN === 11, `${trgN}`);
  const trgD = (
    await one(
      "select count(*)::int n from pg_trigger where tgname = 'trg_wo_child_changed' and tgconstraint <> 0 and tgdeferrable and tginitdeferred",
    )
  ).n;
  check(
    "  semuanya constraint trigger DEFERRABLE INITIALLY DEFERRED (kunci saat commit)",
    trgD === 11,
    `${trgD}`,
  );
  const vcols = (
    await q(
      "select column_name from information_schema.columns where table_schema='public' and table_name='tech_work_orders'",
    )
  ).rows.map((x) => x.column_name);
  check(
    "view tech_work_orders ada & tanpa kolom harga/penagihan",
    vcols.length > 40 && !vcols.some((n) => /^(estimate_|billing_|warranty_exception)/.test(n)),
    `${vcols.length} kolom`,
  );
  check("view tech_work_orders memuat children_changed_at", vcols.includes("children_changed_at"));
  const opts =
    (await one("select reloptions from pg_class where oid = 'public.tech_work_orders'::regclass"))
      .reloptions ?? [];
  check("view tech_work_orders security_barrier", opts.includes("security_barrier=true"), js(opts));
  const acl =
    await one(`select has_table_privilege('anon','public.tech_work_orders','SELECT') a1, has_table_privilege('authenticated','public.tech_work_orders','SELECT') a2,
                                has_table_privilege('anon','public.wo_child_changes','SELECT') b1, has_table_privilege('authenticated','public.wo_child_changes','SELECT') b2,
                                has_table_privilege('authenticated','public.wo_child_changes','INSERT') b3`);
  check(
    "hak tabel: anon tanpa akses; authenticated hanya SELECT pada view/tabel baru",
    !acl.a1 && acl.a2 && !acl.b1 && acl.b2 && !acl.b3,
    js(acl),
  );
  const pol = (name, tbl) =>
    one(
      "select qual from pg_policies where schemaname='public' and tablename=$2 and policyname=$1",
      [name, tbl],
    );
  check("policy work_orders_tech sudah dicabut", !(await pol("work_orders_tech", "work_orders")));
  check("policy work_orders_staff masih ada", !!(await pol("work_orders_staff", "work_orders")));
  const pay = await pol("payments_customer", "payments");
  check(
    "S2: payments_customer memuat filter status ISSUED/PAID",
    /ISSUED/.test(pay?.qual ?? "") && /PAID/.test(pay?.qual ?? ""),
  );
  const cus = await pol("customer_users_select", "customer_users");
  check(
    "N1: customer_users_select memeriksa is_active dan profiles",
    /is_active/.test(cus?.qual ?? "") && /profiles/.test(cus?.qual ?? ""),
  );

  log("\n== SANITY keamanan global ==");
  const nors = (await q("select * from app.tables_without_rls()")).rows;
  check("app.tables_without_rls() kosong", nors.length === 0, js(nors));
  const badSp = (
    await q(`select n.nspname || '.' || p.proname fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public','app') and p.prosecdef and not ('search_path=""' = any (coalesce(p.proconfig, '{}')))`)
  ).rows;
  check(
    'semua fungsi SECURITY DEFINER di public/app ber-search_path=""',
    badSp.length === 0,
    js(badSp),
  );
  const anonFn = (
    await q(`select n.nspname || '.' || p.proname fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public','app') and p.prokind = 'f'
         and (has_function_privilege('anon', p.oid, 'EXECUTE')
              or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0))`)
  ).rows;
  check(
    "tidak ada fungsi public/app yang bisa dieksekusi anon/PUBLIC",
    anonFn.length === 0,
    js(anonFn),
  );
  const expectedApp = [
    "can_edit_wo",
    "can_read_object",
    "customer_owns_wo",
    "customer_status",
    "has_any_role",
    "my_active_wo_ids",
    "my_customer_ids",
    "my_editable_wo_ids",
    "my_location_ids",
    "my_roles",
    "my_technician_id",
    "tech_asset_ids",
    "tech_customer_ids",
    "tech_request_ids",
    "tech_site_ids",
    "wo_storage_prefix",
  ];
  const appAuth = [
    ...new Set(
      (
        await q(
          `select p.proname from pg_proc p where p.pronamespace = 'app'::regnamespace and has_function_privilege('authenticated', p.oid, 'EXECUTE')`,
        )
      ).rows.map((x) => x.proname),
    ),
  ].sort();
  check(
    "schema app: authenticated hanya mendapat daftar helper lama (persis)",
    js(appAuth) === js([...expectedApp].sort()),
    js(appAuth.filter((x) => !expectedApp.includes(x))),
  );
  const pubAuth = (
    await q(`select p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prorettype <> 'trigger'::regtype
        and has_function_privilege('authenticated', p.oid, 'EXECUTE')`)
  ).rows.map((x) => x.proname);
  info(
    "RPC public yang bisa dieksekusi authenticated (jumlah)",
    `${pubAuth.length}; baru: ${NEW_PUBLIC_RPCS.map((x) => x[0])
      .filter((n) => pubAuth.includes(n))
      .join(",")}`,
  );
  const anonRel = (
    await q(`select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','v','p')
        and (has_table_privilege('anon', c.oid, 'SELECT') or has_table_privilege('anon', c.oid, 'INSERT'))`)
  ).rows;
  check("anon tanpa hak pada relasi public mana pun", anonRel.length === 0, js(anonRel));

  // ---------------------------------------------------------------- perilaku
  log("\n== PERILAKU: G-08 (teknisi tidak melihat harga) ==");
  if (tech1) {
    const a = await asUser(tech1.uid, "select count(*)::int n from public.work_orders");
    check(
      "teknisi SELECT work_orders langsung = 0 baris (sebelumnya >0)",
      a.ok && a.rows[0].n === 0,
      `sebelum=${js(pre.techRows)} sesudah=${js(a.rows[0])}`,
    );
    const b = await asUser(tech1.uid, "select * from public.tech_work_orders");
    const keys = b.rows[0] ? Object.keys(b.rows[0]) : [];
    check(
      "teknisi membaca WO aktifnya lewat tech_work_orders (>=1 baris)",
      b.ok && b.rows.length >= 1,
      `${b.rows.length} baris`,
    );
    check(
      "  tech_work_orders tidak memuat estimate_*/billing_* pada baris nyata",
      keys.length > 0 && !keys.some((k) => /^(estimate_|billing_|warranty_exception)/.test(k)),
    );
    const nAct = (
      await one(
        "select count(*)::int n from public.wo_assignments a join public.technicians t on t.id = a.technician_id where t.user_id = $1 and a.status in ('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED')",
        [tech1.uid],
      )
    ).n;
    check(
      "  jumlah baris view = jumlah WO aktif teknisi (distinct)",
      b.rows.length <= nAct && b.rows.some((r) => r.id === tech1.wo),
      `view=${b.rows.length} penugasan=${nAct}`,
    );
    const t0 = await asUser(tech1.uid, "select * from public.tech_work_orders where id = $1", [
      tech1.wo,
    ]);
    check(
      "  version & status WO tetap terbaca (untuk optimistic lock)",
      t0.rows[0]?.version === tech1.version && t0.rows[0]?.status === tech1.status,
    );
    if (tech2) {
      const o = await asUser(
        tech2.uid,
        "select count(*)::int n from public.tech_work_orders where id = $1",
        [tech1.wo],
      );
      check("  teknisi lain tidak melihat WO ini di tech_work_orders", o.ok && o.rows[0].n === 0);
    }
    const tv = await asUser(tech1.uid, "select count(*)::int n from public.v_today_work_orders");
    info(
      "v_today_work_orders (security_invoker) untuk teknisi",
      `${tv.rows[0]?.n} baris (dampak G-08, diharapkan 0)`,
    );
    const col2 = await asUser(
      tech1.uid,
      "select estimate_total from public.tech_work_orders limit 1",
    );
    check(
      "  SELECT estimate_total dari tech_work_orders ditolak (kolom tidak ada, 42703)",
      !col2.ok && col2.code === "42703",
      col2.code,
    );
  } else skip("G-08 teknisi", "tidak ada teknisi dengan WO ACCEPTED/editable");

  log("\n  -- peran lain tetap membaca work_orders --");
  for (const r of ["ADMIN_CS", "DISPATCHER", "SUPERVISOR", "FINANCE", "OWNER"]) {
    if (!staff[r]) {
      skip(`staf ${r}`, "tidak ada akun");
      continue;
    }
    const a = await asUser(staff[r], "select count(*)::int n from public.work_orders");
    check(
      `${r} membaca work_orders (${woCount} baris di DB)`,
      a.ok && a.rows[0].n === woCount,
      `${a.rows[0]?.n}`,
    );
  }
  if (staff.WAREHOUSE) {
    const a = await asUser(staff.WAREHOUSE, "select count(*)::int n from public.work_orders");
    check("WAREHOUSE tetap 0 baris di work_orders (kontrol)", a.ok && a.rows[0].n === 0);
    const v = await asUser(
      staff.WAREHOUSE,
      "select count(*)::int n from public.v_wh_part_requests",
    );
    info("WAREHOUSE v_wh_part_requests (definer view)", `${v.rows[0]?.n} baris`);
  }
  if (custUser) {
    const a = await asUser(custUser.uid, "select count(*)::int n from public.customer_work_orders");
    check(
      "pelanggan tetap membaca customer_work_orders (>0)",
      a.ok && a.rows[0].n > 0,
      `${a.rows[0]?.n}`,
    );
    const r = await asUser(custUser.uid, "select count(*)::int n from public.work_orders");
    check("pelanggan tetap 0 baris di work_orders", a.ok && r.rows[0].n === 0);
  }
  if (tech1) {
    // fungsi definer yang dipakai teknisi tetap bisa membaca work_orders
    const w = await asUser(
      tech1.uid,
      "select public.wo_transition($1, 'ACCEPT', $2, null, null, null, '{}'::jsonb) r",
      [tech1.wo, tech1.version],
    );
    check(
      "wo_transition oleh teknisi tetap mencapai logika (ACCEPT pada WO berjalan -> WO001, bukan 42501/WO005)",
      !w.ok && w.code === "WO001",
      `${w.code} ${w.message ?? ""}`,
    );
    const asg =
      await one(`select t.user_id::text uid, a.wo_id::text wo, w.version from public.wo_assignments a
        join public.technicians t on t.id = a.technician_id and t.is_active join public.work_orders w on w.id = a.wo_id
       where a.status = 'ASSIGNED' and a.role = 'LEAD' and w.status = 'ASSIGNED' limit 1`);
    if (asg) {
      const ok = await asUser(
        asg.uid,
        "select public.wo_transition($1, 'ACCEPT', $2, null, null, null, '{}'::jsonb) r",
        [asg.wo, asg.version],
      );
      check(
        "wo_transition ACCEPT penuh oleh teknisi sukses (ASSIGNED -> ACCEPTED)",
        ok.ok && ok.rows[0].r.status === "ACCEPTED",
        ok.ok ? js(ok.rows[0].r) : `${ok.code} ${ok.message}`,
      );
    } else skip("wo_transition ACCEPT penuh", "tidak ada WO ASSIGNED di fixture");
  }

  log("\n== PERILAKU: S1 wo_cost_summary ==");
  if (tech1) {
    const a = await asUser(tech1.uid, "select public.wo_cost_summary($1) r", [tech1.wo]);
    check(
      "teknisi hanya menerima {needs_approval}",
      a.ok && js(Object.keys(a.rows[0].r)) === js(["needs_approval"]),
      a.ok ? js(a.rows[0].r) : a.code,
    );
    const s = await asUser(staff.ADMIN_CS, "select public.wo_cost_summary($1) r", [tech1.wo]);
    check(
      "ADMIN_CS tetap menerima hasil penuh",
      s.ok &&
        ["estimate_total", "projected_total", "tolerance", "needs_approval"].every(
          (k) => k in s.rows[0].r,
        ),
      s.ok ? js(s.rows[0].r) : s.code,
    );
    if (tech2) {
      const o = await asUser(tech2.uid, "select public.wo_cost_summary($1) r", [tech1.wo]);
      check("teknisi lain: WO005", !o.ok && o.code === "WO005");
    }
    const nul = await asUser(tech1.uid, "select public.wo_cost_summary(null) r");
    check("p_wo_id NULL oleh teknisi: WO005", !nul.ok && nul.code === "WO005", nul.code);
    const rnd2 = await asUser(staff.ADMIN_CS, "select public.wo_cost_summary(gen_random_uuid()) r");
    check(
      "id acak oleh staf: WO005 (bukan JSON berisi null)",
      !rnd2.ok && rnd2.code === "WO005",
      rnd2.code,
    );
    const ecr = await asUser(
      tech1.uid,
      "select public.extra_cost_request($1, 'uji rollback', $2::jsonb, $3, null) r",
      [
        tech1.wo,
        js([{ kind: "OTHER", description: "uji", qty: 1, unit_price: 1000 }]),
        tech1.version,
      ],
    );
    if (ecr.ok)
      check(
        "extra_cost_request: nilai kembalian teknisi tanpa kunci 'total'",
        !("total" in ecr.rows[0].r) && "approval_id" in ecr.rows[0].r,
        js(Object.keys(ecr.rows[0].r)),
      );
    else
      info("extra_cost_request tidak dapat dijalankan pada WO uji", `${ecr.code} ${ecr.message}`);
  }

  log("\n== PERILAKU: G-13 wo_declare_no_parts ==");
  if (tech1) {
    const usages = (
      await one(
        "select count(*)::int n from public.wo_part_usages where wo_id = $1 and deleted_at is null",
        [tech1.wo],
      )
    ).n;
    const call = (uid, val, ver, keep = false) =>
      asUser(uid, "select public.wo_declare_no_parts($1, $2, $3, null) r", [tech1.wo, val, ver], {
        keep,
      });
    if (tech2) {
      const o = await call(tech2.uid, true, tech1.version);
      check(
        "teknisi lain (bukan pemegang) ditolak WO005",
        !o.ok && o.code === "WO005",
        `${o.code}`,
      );
    }
    if (custUser) {
      const o = await call(custUser.uid, true, tech1.version);
      check("pelanggan ditolak WO005", !o.ok && o.code === "WO005", `${o.code}`);
    }
    const adm = await call(staff.ADMIN_CS, true, tech1.version);
    check(
      "ADMIN_CS (bukan teknisi pemegang) ditolak WO005",
      !adm.ok && adm.code === "WO005",
      `${adm.code}`,
    );
    const auditN = async () =>
      (
        await one(
          "select count(*)::int n from public.audit_logs where entity_type = 'work_orders' and entity_id = $1 and action = 'UPDATE' and new_values ? 'no_parts_used'",
          [tech1.wo],
        )
      ).n;
    const successFlow = async () => {
      const a0 = await auditN();
      const r1 = await call(tech1.uid, true, tech1.version, true);
      check(
        "teknisi pemegang: deklarasi true sukses, version naik",
        r1.ok &&
          r1.rows[0].r.no_parts_used === true &&
          r1.rows[0].r.version === tech1.version + 1 &&
          r1.rows[0].r.replayed === false,
        r1.ok ? js(r1.rows[0].r) : `${r1.code} ${r1.message}`,
      );
      const st = await one("select no_parts_used, version from public.work_orders where id = $1", [
        tech1.wo,
      ]);
      check(
        "  work_orders.no_parts_used=true tertulis",
        st.no_parts_used === true && st.version === tech1.version + 1,
      );
      check(
        "  audit tercatat (audit_logs UPDATE work_orders memuat no_parts_used)",
        (await auditN()) === a0 + 1,
      );
      const au = await one(
        "select actor_id::text a, actor_roles r from public.audit_logs where entity_type='work_orders' and entity_id=$1 and new_values ? 'no_parts_used' order by id desc limit 1",
        [tech1.wo],
      );
      check(
        "  audit mencatat aktor teknisi",
        au?.a === tech1.uid,
        `${au?.a === tech1.uid ? "aktor=teknisi" : js(au)} peran=${au?.r}`,
      );
      const r2 = await call(tech1.uid, true, tech1.version, true);
      check(
        "  ulang nilai sama = replay tanpa perubahan",
        r2.ok && r2.rows[0].r.replayed === true && r2.rows[0].r.version === tech1.version + 1,
        r2.ok ? js(r2.rows[0].r) : r2.code,
      );
      const r3 = await call(tech1.uid, false, tech1.version);
      check("  versi basi (nilai berubah) -> WO004", !r3.ok && r3.code === "WO004", r3.code);
      const dsc = await asUser(tech1.uid, "select public.wo_closure_check($1) r", [tech1.wo]);
      check(
        "  setelah deklarasi, PARTS_NOT_DECLARED hilang dari wo_closure_check",
        dsc.ok && !js(dsc.rows[0].r).includes("PARTS_NOT_DECLARED"),
        dsc.ok ? "" : dsc.code,
      );
      const opx = (
        await one(
          "insert into public.sync_operations (op_id, device_id, user_id, wo_id, type, status) values (gen_random_uuid(), 'uji', $1, $2, 'UJI', 'APPLIED') returning op_id::text id",
          [tech1.uid, tech1.wo],
        )
      ).id;
      const rop = await asUser(
        tech1.uid,
        "select public.wo_declare_no_parts($1, false, $2, $3) r",
        [tech1.wo, tech1.version + 1, opx],
        { keep: true },
      );
      const still = (
        await one("select no_parts_used from public.work_orders where id = $1", [tech1.wo])
      ).no_parts_used;
      check(
        "  op_id yang sudah APPLIED = replay, nilai TIDAK dibalik",
        rop.ok && rop.rows[0].r.replayed === true && still === true,
        rop.ok ? js(rop.rows[0].r) : rop.code,
      );
      const r4 = await call(tech1.uid, false, tech1.version + 1, true);
      check(
        "  tarik kembali (false) dengan versi benar sukses",
        r4.ok && r4.rows[0].r.no_parts_used === false,
        r4.ok ? "" : r4.code,
      );
    };
    if (usages === 0) {
      await successFlow();
    } else {
      const r1 = await call(tech1.uid, true, tech1.version);
      check(
        `WO sudah punya ${usages} pemakaian: deklarasi true ditolak WO003 PARTS_ALREADY_RECORDED`,
        !r1.ok && r1.code === "WO003" && (r1.detail ?? "").includes("PARTS_ALREADY_RECORDED"),
        `${r1.code}`,
      );
      const r2 = await call(tech1.uid, false, tech1.version);
      check(
        "  deklarasi false (sama dengan nilai sekarang) = replay",
        r2.ok && r2.rows[0].r.replayed === true,
        r2.ok ? "" : r2.code,
      );
      await q("savepoint sp_np");
      const tb = await tryAdmin(
        "update public.wo_part_usages set deleted_at = now() where wo_id = $1 and deleted_at is null",
        [tech1.wo],
        { keep: true },
      );
      if (tb.ok) {
        info(
          "jalur sukses: pemakaian WO di-tombstone dalam transaksi (dibatalkan lagi oleh rollback)",
        );
        await successFlow();
      } else skip("jalur sukses wo_declare_no_parts", `tombstone pemakaian gagal: ${tb.code}`);
      await q("rollback to savepoint sp_np");
      await q("release savepoint sp_np");
    }
    const nonEdit =
      await one(`select t.user_id::text uid, a.wo_id::text wo from public.wo_assignments a
        join public.technicians t on t.id = a.technician_id and t.is_active join public.work_orders w on w.id = a.wo_id
       where a.status in ('ASSIGNED','ACCEPTED','COMPLETED','CANCELLED') and w.status not in ('IN_PROGRESS','ON_HOLD_PARTS','AWAITING_CUSTOMER_APPROVAL') limit 1`);
    if (nonEdit) {
      const o = await asUser(nonEdit.uid, "select public.wo_declare_no_parts($1, true, 1, null)", [
        nonEdit.wo,
      ]);
      check(
        "WO aktif tetapi tidak dapat diisi (status lain) -> WO001",
        !o.ok && o.code === "WO001",
        `${o.code}`,
      );
    } else skip("WO001 pada status tak dapat diisi", "tidak ada contoh");
  } else skip("G-13", "tidak ada teknisi uji");

  log("\n== PERILAKU: G-12 wo_closure_check ==");
  if (tech1) {
    const a = await asUser(tech1.uid, "select public.wo_closure_check($1) r", [tech1.wo]);
    check(
      "teknisi pemegang menerima array kekurangan",
      a.ok && Array.isArray(a.rows[0].r),
      a.ok ? js(a.rows[0].r) : `${a.code} ${a.message}`,
    );
    const direct = await one(
      "select app.wo_submit_deficiencies($1, case when (select status from public.work_orders where id = $1) = 'UNDER_REVIEW' then 'CLOSE' else 'SUBMIT' end, 0) r",
      [tech1.wo],
    );
    check("  isi sama dengan app.wo_submit_deficiencies", a.ok && js(a.rows[0].r) === js(direct.r));
    for (const r of ["ADMIN_CS", "DISPATCHER", "SUPERVISOR", "OWNER"]) {
      const s = await asUser(staff[r], "select public.wo_closure_check($1) r", [tech1.wo]);
      check(`  ${r} berhasil`, s.ok && Array.isArray(s.rows[0].r), s.ok ? "" : s.code);
    }
    for (const [lbl, uid] of [
      ["teknisi lain", tech2?.uid],
      ["pelanggan", custUser?.uid],
      ["FINANCE", staff.FINANCE],
      ["WAREHOUSE", staff.WAREHOUSE],
    ]) {
      if (!uid) {
        skip(`wo_closure_check ${lbl}`, "tidak ada akun");
        continue;
      }
      const o = await asUser(uid, "select public.wo_closure_check($1) r", [tech1.wo]);
      check(`  ${lbl} ditolak WO005`, !o.ok && o.code === "WO005", o.code);
    }
    const rnd = await asUser(staff.ADMIN_CS, "select public.wo_closure_check(gen_random_uuid())");
    check("  id acak oleh staf: WO005 (seragam)", !rnd.ok && rnd.code === "WO005");
  }

  log("\n== PERILAKU: G-04 upload_status tanda tangan ==");
  if (tech1) {
    const hasExc = (
      await one("select closure_exception ce from public.work_orders where id = $1", [tech1.wo])
    ).ce;
    const def = async () =>
      (await one("select app.wo_submit_deficiencies($1, 'SUBMIT', 0) r", [tech1.wo])).r.map(
        (x) => x.code,
      );
    await q("savepoint sp_sig");
    await q("update public.wo_signatures set upload_status = 'PENDING' where wo_id = $1", [
      tech1.wo,
    ]);
    const path = `${tech1.cust}/wo/${tech1.wo}/sig-uji-rollback.png`;
    const ins = await q(
      "insert into public.wo_signatures (wo_id, signer_type, signer_name, storage_path, content_hash, signed_via) values ($1, 'CUSTOMER', 'Uji Rollback', $2, '', 'TECH_DEVICE') returning upload_status::text s, status::text st",
      [tech1.wo, path],
    );
    check(
      "baris baru default PENDING (trigger tidak menimpa)",
      ins.rows[0].s === "PENDING" && ins.rows[0].st === "VALID",
      js(ins.rows[0]),
    );
    if (hasExc) skip("SIGNATURE_MISSING saat PENDING", "WO ber-closure_exception");
    else {
      const d1 = await def();
      check(
        "tanda tangan VALID tetapi PENDING -> SIGNATURE_MISSING",
        d1.includes("SIGNATURE_MISSING"),
        js(d1),
      );
      await q(
        "update public.wo_signatures set upload_status = 'UPLOADED' where storage_path = $1",
        [path],
      );
      const d2 = await def();
      check(
        "setelah ditandai UPLOADED (oleh server) -> SIGNATURE_MISSING hilang",
        !d2.includes("SIGNATURE_MISSING"),
        js(d2),
      );
    }
    const gr = await asUser(
      tech1.uid,
      "insert into public.wo_signatures (wo_id, signer_type, signer_name, storage_path, signed_via, upload_status) values ($1,'CUSTOMER','x',$2,'TECH_DEVICE','UPLOADED')",
      [tech1.wo, `${tech1.cust}/wo/${tech1.wo}/sig-uji-2.png`],
    );
    check(
      "klien (authenticated) tidak boleh mengisi upload_status (42501)",
      !gr.ok && gr.code === "42501",
      gr.code,
    );
    const gr2 = await asUser(
      tech1.uid,
      "update public.wo_signatures set upload_status = 'UPLOADED' where wo_id = $1",
      [tech1.wo],
    );
    check(
      "klien tidak boleh UPDATE wo_signatures (42501)",
      !gr2.ok && gr2.code === "42501",
      gr2.code,
    );
    const tpol = (path) =>
      asUser(
        tech1.uid,
        "insert into public.wo_signatures (wo_id, signer_type, signer_name, storage_path, signed_via) values ($1,'CUSTOMER','Uji',$2,'TECH_DEVICE')",
        [tech1.wo, path],
      );
    const tOk = await tpol(`${tech1.cust}/wo/${tech1.wo}/sig/tek-uji.png`);
    check(
      "tanda tangan teknisi di sub-prefix sig/ diizinkan policy (baris PENDING)",
      tOk.ok,
      `${tOk.code} ${tOk.message ?? ""}`,
    );
    const tBad = await tpol(`${tech1.cust}/wo/${tech1.wo}/foto-biasa.png`);
    check(
      "tanda tangan teknisi di luar sub-prefix sig/ ditolak policy (42501)",
      !tBad.ok && tBad.code === "42501",
      tBad.code,
    );
    await q("rollback to savepoint sp_sig");
    await q("release savepoint sp_sig");

    // wo_customer_sign: jalur pelanggan (butuh WO AWAITING_SIGNOFF; dipaksa dalam transaksi)
    if (custUser) {
      await q("savepoint sp_cs");
      await q("select set_config('app.tx_active', 'on', true)");
      await q("update public.work_orders set status = 'AWAITING_SIGNOFF' where id = $1", [
        tech1.wo,
      ]);
      await q("select set_config('app.tx_active', 'off', true)");
      const v = (await one("select version from public.work_orders where id = $1", [tech1.wo]))
        .version;
      const sign = (p) =>
        asUser(
          custUser.uid,
          "select public.wo_customer_sign($1, 'Uji Pelanggan', $2, $3, null, '{}'::jsonb) r",
          [tech1.wo, p, v],
        );
      const pfx = `${tech1.cust}/wo/${tech1.wo}/`;
      const bad = await sign("bebas/sekali.png");
      check(
        "wo_customer_sign: path di luar prefix WO -> WO006",
        !bad.ok && bad.code === "WO006",
        bad.code,
      );
      const noSub = await sign(`${pfx}foto-biasa.png`);
      check(
        "wo_customer_sign: path di prefix WO tetapi bukan sub-prefix sig/ -> WO006",
        !noSub.ok && noSub.code === "WO006",
        noSub.code,
      );
      const onlyPfx = await sign(`${pfx}sig/`);
      check(
        "wo_customer_sign: path = sub-prefix saja (tanpa nama file) -> WO006",
        !onlyPfx.ok && onlyPfx.code === "WO006",
        onlyPfx.code,
      );
      const trav = await sign(`${pfx}sig/../x.png`);
      check(
        "wo_customer_sign: path dengan '..' -> WO006",
        !trav.ok && trav.code === "WO006",
        trav.code,
      );
      const regPath = `${pfx}sig/foto-terdaftar.png`;
      await q(
        "insert into public.wo_attachments (wo_id, kind, storage_path, upload_status) values ($1, 'OTHER', $2, 'UPLOADED')",
        [tech1.wo, regPath],
      );
      const reg = await sign(regPath);
      check(
        "wo_customer_sign: path yang sudah terdaftar di wo_attachments -> WO006",
        !reg.ok && reg.code === "WO006",
        reg.code,
      );
      const p1 = `${pfx}sig/tanpa-objek.png`;
      const noObj = await sign(p1);
      check(
        "wo_customer_sign: objek belum diunggah -> ditolak WO003 memuat SIGNATURE_MISSING",
        !noObj.ok && noObj.code === "WO003" && (noObj.detail ?? "").includes("SIGNATURE_MISSING"),
        `${noObj.code} ${noObj.detail ?? noObj.message}`,
      );
      const p3 = `${pfx}sig/objek-tanpa-metadata.png`;
      await q("insert into storage.objects (bucket_id, name) values ('wo-media', $1)", [p3]);
      const noMeta = await sign(p3);
      check(
        "wo_customer_sign: objek ada tetapi tanpa ukuran/mimetype -> tetap SIGNATURE_MISSING",
        !noMeta.ok && (noMeta.detail ?? "").includes("SIGNATURE_MISSING"),
        `${noMeta.code}`,
      );
      const p4 = `${pfx}sig/objek-pdf.png`;
      await q(
        "insert into storage.objects (bucket_id, name, metadata) values ('wo-media', $1, $2::jsonb)",
        [p4, js({ size: 100, mimetype: "application/pdf" })],
      );
      const pdf = await sign(p4);
      check(
        "wo_customer_sign: mimetype bukan gambar -> tetap SIGNATURE_MISSING",
        !pdf.ok && (pdf.detail ?? "").includes("SIGNATURE_MISSING"),
        `${pdf.code}`,
      );
      const p2 = `${pfx}sig/dengan-objek.png`;
      await q(
        "insert into storage.objects (bucket_id, name, metadata) values ('wo-media', $1, $2::jsonb)",
        [p2, js({ size: 2048, mimetype: "image/png" })],
      );
      const withObj = await sign(p2);
      const missing = (withObj.detail ?? "").includes("SIGNATURE_MISSING");
      check(
        "wo_customer_sign: objek sah (ukuran>0, image/png) -> SIGNATURE_MISSING tidak muncul (sukses atau kekurangan lain saja)",
        !missing,
        withObj.ok
          ? `sukses ${js(withObj.rows[0].r)}`
          : `${withObj.code} ${(withObj.detail ?? "").slice(0, 220)}`,
      );
      await q("rollback to savepoint sp_cs");
      await q("release savepoint sp_cs");
    } else skip("wo_customer_sign", "tidak ada pengguna pelanggan untuk WO ini");
  }

  log("\n== PERILAKU: G-05 sinyal perubahan anak WO ==");
  if (tech1) {
    const before = await one(
      "select w.version, w.updated_at::text ua, (select changed_at::text from public.wo_child_changes where wo_id = w.id) ch from public.work_orders w where w.id = $1",
      [tech1.wo],
    );
    const aud0 = (
      await one(
        "select count(*)::int n from public.audit_logs where entity_type = 'work_orders' and entity_id = $1",
        [tech1.wo],
      )
    ).n;
    await q("savepoint sp_g5");
    await q("update public.wo_assignments set reason = reason where wo_id = $1", [tech1.wo]);
    await q(
      "insert into public.wo_findings (wo_id, diagnosis) values ($1, 'uji rollback') on conflict (wo_id) do update set diagnosis = excluded.diagnosis",
      [tech1.wo],
    );
    const pend = (
      await one(
        "select count(*)::int n from public.wo_child_changes where wo_id = $1 and changed_at > $2::timestamptz",
        [tech1.wo, before.ch],
      )
    ).n;
    check(
      "sinyal DITUNDA sampai commit (belum ada tulis ke wo_child_changes sebelum SET CONSTRAINTS IMMEDIATE)",
      pend === 0,
      `${pend}`,
    );
    await q("set constraints all immediate");
    await q("set constraints all deferred");
    const after = await one(
      "select w.version, w.updated_at::text ua, (select changed_at::text from public.wo_child_changes where wo_id = w.id) ch from public.work_orders w where w.id = $1",
      [tech1.wo],
    );
    check(
      "perubahan anak memajukan wo_child_changes.changed_at",
      !!after.ch && after.ch !== before.ch,
      `${before.ch} -> ${after.ch}`,
    );
    check(
      "work_orders.version dan updated_at TIDAK berubah",
      after.version === before.version && after.ua === before.ua,
      `v${before.version}->v${after.version}`,
    );
    const aud1 = (
      await one(
        "select count(*)::int n from public.audit_logs where entity_type = 'work_orders' and entity_id = $1",
        [tech1.wo],
      )
    ).n;
    check(
      "tidak ada audit_logs baru untuk work_orders (tidak berisik)",
      aud1 === aud0,
      `${aud0}->${aud1}`,
    );
    const tv = await asUser(
      tech1.uid,
      "select children_changed_at::text c from public.tech_work_orders where id = $1",
      [tech1.wo],
      { keep: false },
    );
    info("children_changed_at terbaca teknisi lewat view (di luar savepoint ini)", js(tv.rows[0]));
    await q("rollback to savepoint sp_g5");
    await q("release savepoint sp_g5");
    const sig = await asUser(tech1.uid, "select count(*)::int n from public.wo_child_changes");
    check(
      "teknisi membaca wo_child_changes hanya WO aktifnya",
      sig.ok && sig.rows[0].n >= 1,
      `${sig.rows[0]?.n} baris`,
    );
    if (custUser) {
      const c1 = await asUser(custUser.uid, "select count(*)::int n from public.wo_child_changes");
      check("pelanggan 0 baris di wo_child_changes", c1.ok && c1.rows[0].n === 0);
    }
    const wr = await asUser(
      tech1.uid,
      "insert into public.wo_child_changes (wo_id) values (gen_random_uuid())",
    );
    check(
      "authenticated tidak bisa menulis wo_child_changes (42501)",
      !wr.ok && wr.code === "42501",
      wr.code,
    );
    // transisi WO final tidak terblokir oleh pemicu sinyal (IMM01 hanya dari guard lama)
    const fin = await one(
      "select id::text id from public.work_orders where status = 'CLOSED' limit 1",
    );
    if (fin) {
      const r = await tryAdmin(
        "update public.wo_assignments set reason = reason where wo_id = $1",
        [fin.id],
      );
      check(
        "update anak pada WO final tidak menimbulkan galat baru dari pemicu sinyal",
        r.ok || r.code === "IMM01",
        r.ok ? "ok" : `${r.code}`,
      );
    }
  }

  log("\n== PERILAKU: G-06 sync_op_record / sync_rescued_resolve ==");
  if (tech1 && tech2) {
    const mk = async () =>
      (
        await one(
          "insert into public.sync_operations (op_id, device_id, user_id, wo_id, type, payload) values (gen_random_uuid(), 'uji-rollback', $1, $2, 'UJI', '{}'::jsonb) returning op_id::text id",
          [tech1.uid, tech1.wo],
        )
      ).id;
    const rec = (uid, id, st, res = null, keep = true) =>
      asUser(uid, "select public.sync_op_record($1, $2, $3::jsonb) r", [id, st, res], { keep });
    const op1 = await mk();
    const o = await rec(tech2.uid, op1, "APPLIED");
    check(
      "teknisi lain tidak bisa mencatat op milik orang: WO005",
      !o.ok && o.code === "WO005",
      o.code,
    );
    const bad = await rec(tech1.uid, op1, "BOGUS", null, false);
    check("status tak dikenal -> WO006", !bad.ok && bad.code === "WO006", bad.code);
    const rcv = await rec(tech1.uid, op1, "RECEIVED", null, false);
    check(
      "status RECEIVED tidak boleh dicatat -> WO006",
      !rcv.ok && rcv.code === "WO006",
      rcv.code,
    );
    const ap = await rec(tech1.uid, op1, "APPLIED", js({ ok: 1 }));
    check(
      "RECEIVED -> APPLIED sukses (applied_at terisi, result tersimpan)",
      ap.ok && ap.rows[0].r.status === "APPLIED",
      ap.ok ? "" : `${ap.code} ${ap.message}`,
    );
    const row = await one(
      "select status::text s, applied_at is not null aa, result from public.sync_operations where op_id = $1",
      [op1],
    );
    check(
      "  baris benar-benar berubah",
      row.s === "APPLIED" && row.aa === true && row.result?.ok === 1,
      js(row),
    );
    const ap2 = await rec(tech1.uid, op1, "APPLIED");
    check("  APPLIED lagi = replay", ap2.ok && ap2.rows[0].r.replayed === true);
    const back = await rec(tech1.uid, op1, "REJECTED", null, false);
    check("  APPLIED -> REJECTED ditolak WO001", !back.ok && back.code === "WO001", back.code);
    const op2 = await mk();
    const rs = await rec(tech1.uid, op2, "RESCUED", js({ code: "CONFLICT_CANCELLED" }));
    check(
      "RECEIVED -> RESCUED sukses",
      rs.ok && rs.rows[0].r.status === "RESCUED",
      rs.ok ? "" : rs.code,
    );
    const rt = await asUser(tech1.uid, "select public.sync_rescued_resolve($1, 'catatan')", [op2]);
    check("teknisi tidak boleh menyelesaikan draf: WO002", !rt.ok && rt.code === "WO002", rt.code);
    const nonResc = await asUser(
      staff.SUPERVISOR,
      "select public.sync_rescued_resolve($1, 'catatan')",
      [op1],
    );
    check(
      "menyelesaikan op yang bukan RESCUED -> WO001",
      !nonResc.ok && nonResc.code === "WO001",
      nonResc.code,
    );
    const noNote = await asUser(staff.SUPERVISOR, "select public.sync_rescued_resolve($1, '  ')", [
      op2,
    ]);
    check("catatan kosong -> WO006", !noNote.ok && noNote.code === "WO006", noNote.code);
    const rv = await asUser(
      staff.SUPERVISOR,
      "select public.sync_rescued_resolve($1, 'sudah ditautkan ke WO baru') r",
      [op2],
      { keep: true },
    );
    check(
      "SUPERVISOR menyelesaikan draf RESCUED",
      rv.ok && rv.rows[0].r.replayed === false,
      rv.ok ? "" : `${rv.code} ${rv.message}`,
    );
    const rr = await one(
      "select resolved_at is not null ra, resolved_by::text rb, resolved_note from public.sync_operations where op_id = $1",
      [op2],
    );
    check(
      "  resolved_at/by/note terisi",
      rr.ra && rr.rb === staff.SUPERVISOR && rr.resolved_note.length > 5,
      js(rr),
    );
    const upd = await asUser(
      tech1.uid,
      "update public.sync_operations set status = 'APPLIED' where op_id = $1",
      [op2],
    );
    check(
      "klien tetap tidak punya hak UPDATE langsung sync_operations (42501)",
      !upd.ok && upd.code === "42501",
      upd.code,
    );
    if (custUser) {
      const cu = await asUser(
        custUser.uid,
        "select public.sync_op_record(gen_random_uuid(), 'APPLIED')",
      );
      check(
        "pelanggan memanggil sync_op_record dengan op acak: WO005",
        !cu.ok && cu.code === "WO005",
        cu.code,
      );
    }
  } else skip("G-06", "butuh dua teknisi");

  log("\n== PERILAKU: S4 can_read_object ==");
  if (repObj) {
    const a = await asUser(repObj.uid, "select app.can_read_object('reports', $1) ok", [
      repObj.name,
    ]);
    check(
      "teknisi TIDAK lagi membaca bucket reports (sebelumnya " + pre.techReports + ")",
      a.ok && a.rows[0].ok === false,
    );
    const st = await asUser(staff.ADMIN_CS, "select app.can_read_object('reports', $1) ok", [
      repObj.name,
    ]);
    check("  ADMIN_CS tetap membaca reports", st.ok && st.rows[0].ok === true);
    if (staff.FINANCE) {
      const fi = await asUser(staff.FINANCE, "select app.can_read_object('reports', $1) ok", [
        repObj.name,
      ]);
      check("  FINANCE tetap membaca reports", fi.ok && fi.rows[0].ok === true);
    }
  } else skip("S4 reports", "tidak ada objek reports untuk WO teknisi");
  if (mediaObj) {
    const a = await asUser(mediaObj.uid, "select app.can_read_object('wo-media', $1) ok", [
      mediaObj.name,
    ]);
    check(
      "teknisi tetap membaca wo-media untuk WO aktifnya (kompatibel dengan uji lama)",
      a.ok && a.rows[0].ok === true,
    );
    const b = await asUser(mediaObj.uid, "select app.can_read_object('reports', $1) ok", [
      mediaObj.name,
    ]);
    check(
      "  objek wo-media tidak terbaca bila diminta lewat bucket reports",
      b.ok && b.rows[0].ok === false,
    );
  } else skip("S4 wo-media", "tidak ada objek");
  const reqObj = await one(
    "select a.storage_path p, a.customer_id::text cust from public.request_attachments a limit 1",
  );
  if (reqObj) {
    const cu = await one(
      "select cu.user_id::text uid from public.customer_users cu join public.profiles p on p.user_id = cu.user_id and p.is_active where cu.customer_id = $1 and cu.is_active limit 1",
      [reqObj.cust],
    );
    if (cu) {
      const a = await asUser(cu.uid, "select app.can_read_object('wo-media', $1) ok", [reqObj.p]);
      const b = await asUser(cu.uid, "select app.can_read_object('reports', $1) ok", [reqObj.p]);
      check(
        "pelanggan: lampiran permintaan terbaca di wo-media, tidak di bucket lain",
        a.ok && b.ok && a.rows[0].ok === true && b.rows[0].ok === false,
        `wo-media=${a.rows[0]?.ok} reports=${b.rows[0]?.ok}`,
      );
    }
  }

  log("\n== PERILAKU: N1 customer_users untuk akun nonaktif ==");
  if (nonaktif) {
    await q("update public.profiles set is_active = false where user_id = $1", [nonaktif]);
    const a = await asUser(nonaktif, "select count(*)::int n from public.customer_users");
    check(
      "akun nonaktif: customer_users 0 baris (sebelumnya " + pre.nonaktifCU + ")",
      a.ok && a.rows[0].n === 0,
      `${a.rows[0]?.n}`,
    );
    await q("update public.profiles set is_active = true where user_id = $1", [nonaktif]);
    const b = await asUser(nonaktif, "select count(*)::int n from public.customer_users");
    check(
      "  kontrol: setelah diaktifkan, baris sendiri terbaca (>=1)",
      b.ok && b.rows[0].n >= 1,
      `${b.rows[0]?.n}`,
    );
    await q("update public.customer_users set is_active = false where user_id = $1", [nonaktif]);
    const d = await asUser(nonaktif, "select count(*)::int n from public.customer_users");
    check(
      "  customer_users.is_active=false juga menyembunyikan baris sendiri",
      d.ok && d.rows[0].n === 0,
      `${d.rows[0]?.n}`,
    );
    await q("update public.customer_users set is_active = true where user_id = $1", [nonaktif]);
    await q("update public.profiles set is_active = false where user_id = $1", [nonaktif]);
    const own = await asUser(
      nonaktif,
      "select (select count(*) from public.profiles where user_id = $1)::int p, (select count(*) from public.user_roles where user_id = $1)::int r",
      [nonaktif],
    );
    info(
      "tabel milik-pengguna lain TIDAK diubah (akun nonaktif)",
      `profiles=${own.rows[0]?.p} user_roles=${own.rows[0]?.r}`,
    );
  } else skip("N1", "akun nonaktif@demo.vasta.test tidak ada");
  if (custUser) {
    const a = await asUser(custUser.uid, "select count(*)::int n from public.customer_users");
    check(
      "pelanggan aktif tetap membaca customer_users perusahaannya (>=1)",
      a.ok && a.rows[0].n >= 1,
      `${a.rows[0]?.n}`,
    );
  }

  log("\n== PERILAKU: N2 policy sync_operations_insert_own ==");
  if (custUser && tech1 && tech2) {
    const ins = (uid, wo) =>
      asUser(
        uid,
        "insert into public.sync_operations (op_id, device_id, user_id, wo_id, type) values (gen_random_uuid(), 'x', $1, $2, 'X')",
        [uid, wo],
      );
    const c1 = await ins(custUser.uid, tech1.wo);
    check(
      "pelanggan tidak dapat menyisipkan sync_operations (42501)",
      !c1.ok && c1.code === "42501",
      c1.code,
    );
    const t2 = await ins(tech2.uid, tech1.wo);
    check(
      "teknisi yang tidak memegang WO tidak dapat menyisipkan op untuk WO itu (42501)",
      !t2.ok && t2.code === "42501",
      t2.code,
    );
    const t1 = await ins(tech1.uid, tech1.wo);
    check(
      "teknisi pemegang menyisipkan op untuk WO aktifnya (kontrol positif)",
      t1.ok,
      `${t1.code} ${t1.message ?? ""}`,
    );
    const tn = await ins(tech1.uid, null);
    check(
      "teknisi menyisipkan op dengan wo_id NULL (jalur draf WO yang sudah dilepas)",
      tn.ok,
      `${tn.code} ${tn.message ?? ""}`,
    );
  } else skip("N2", "butuh pelanggan dan dua teknisi");
} catch (e) {
  failed++;
  log(`GAGAL galat tak terduga: ${e.code ?? ""} ${e.message}`);
} finally {
  try {
    await c.query("rollback");
    log("\nROLLBACK dijalankan (tidak ada perubahan yang di-commit).");
  } catch (e) {
    log(`PERINGATAN: rollback gagal: ${e.message}`);
    failed++;
  }
  await c.end().catch(() => {});
}

// ---------------------------------------------------------------- bukti database tidak berubah (sambungan baru)
{
  log("\n== BUKTI SETELAH ROLLBACK (sambungan baru) ==");
  const v = mkClient();
  await v.connect();
  const one2 = async (t, p = []) => (await v.query(t, p)).rows[0];
  const fnN = (
    await one2("select count(*)::int n from pg_proc where proname = any($1)", [
      NEW_PUBLIC_RPCS.map((x) => x[0]),
    ])
  ).n;
  check("fungsi RPC baru tidak ada", fnN === 0, `${fnN}`);
  const colN = (
    await one2(
      "select count(*)::int n from information_schema.columns where table_schema='public' and ((table_name='wo_signatures' and column_name='upload_status') or (table_name='sync_operations' and column_name in ('resolved_at','resolved_by','resolved_note')))",
    )
  ).n;
  check("kolom baru tidak ada", colN === 0, `${colN}`);
  const relN = (
    await one2(
      "select count(*)::int n from pg_class where relnamespace='public'::regnamespace and relname in ('tech_work_orders','wo_child_changes')",
    )
  ).n;
  check("view tech_work_orders dan tabel wo_child_changes tidak ada", relN === 0, `${relN}`);
  const appFn = (
    await one2("select count(*)::int n from pg_proc where proname = 'tg_wo_child_changed'")
  ).n;
  check("fungsi app.tg_wo_child_changed tidak ada", appFn === 0);
  const pol = (
    await one2(
      "select count(*)::int n from pg_policies where schemaname='public' and tablename='work_orders' and policyname='work_orders_tech'",
    )
  ).n;
  check("policy work_orders_tech masih ada (belum dicabut)", pol === 1);
  const defn = (
    await one2(
      "select pg_get_functiondef('app.wo_submit_deficiencies(uuid,text,integer)'::regprocedure) d",
    )
  ).d;
  check(
    "app.wo_submit_deficiencies masih versi lama (tanpa upload_status tanda tangan)",
    !/s\.upload_status/.test(defn),
  );
  const mig = await one2("select to_regclass('supabase_migrations.schema_migrations') t");
  if (mig.t) {
    const m = (
      await one2(
        "select count(*)::int n from supabase_migrations.schema_migrations where version = '0016'",
      )
    ).n;
    check("supabase_migrations tidak mencatat 0016", m === 0, `${m}`);
  }
  await v.end();
}

console.log(
  `\nRINGKASAN: ${failed === 0 ? "SEMUA PEMERIKSAAN LULUS" : failed + " PEMERIKSAAN GAGAL"} (migrasi ${migrationRan ? "sempat dijalankan lalu di-ROLLBACK" : "tidak sempat berjalan"})`,
);
process.exit(failed === 0 ? 0 : 1);
