// Mencocokkan setiap operasi di docs/openapi.yaml dengan objek di database Supabase nyata
// (fungsi public, tabel/view, aksi wo_transition) dan menulis docs/orchestration/api_db_mapping.md.
// Pakai: node tools/api-db-mapping.mjs
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import pg from "pg";
import YAML from "yaml";

function loadEnv(path) {
  if (!existsSync(path)) return {};
  const out = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

const env = { ...loadEnv(".env.local"), ...process.env };
const client = new pg.Client({
  connectionString: env.DATABASE_URL,
  ssl: { rejectUnauthorized: false },
});
await client.connect();
const rows = async (sql) => (await client.query(sql)).rows;

const funcs = new Set(
  (
    await rows(
      "select p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'",
    )
  ).map((r) => r.proname),
);
const rels = new Set(
  (
    await rows(
      "select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v')",
    )
  ).map((r) => r.relname),
);
const actions = new Set(
  (await rows("select distinct action from wo_transitions")).map((r) => r.action),
);
await client.end();

const spec = YAML.parse(readFileSync("docs/openapi.yaml", "utf8"));
const out = [];
const summary = { total: 0, ok: 0, gap: 0, na: 0 };

for (const [path, item] of Object.entries(spec.paths)) {
  for (const [method, op] of Object.entries(item)) {
    if (!["get", "post", "put", "patch", "delete"].includes(method)) continue;
    const db = String(op["x-db"] ?? "");
    const checks = [];
    let status = "OK";

    const rpcs = [...db.matchAll(/\brpc\s+([a-z_]+)\s*\(/g)].map((m) => m[1]);
    for (const r of rpcs) {
      const ok = funcs.has(r);
      checks.push(`rpc ${r}: ${ok ? "ada" : "TIDAK ADA"}`);
      if (!ok) status = "GAP";
    }
    const acts = [...db.matchAll(/wo_transition\('([A-Z_]+)'/g)].map((m) => m[1]);
    for (const a of acts) {
      const ok = actions.has(a);
      checks.push(`aksi ${a}: ${ok ? "ada" : "TIDAK ADA"}`);
      if (!ok) status = "GAP";
    }
    if (/\bwo_transition\(/.test(db) && !funcs.has("wo_transition")) {
      checks.push("rpc wo_transition: TIDAK ADA");
      status = "GAP";
    }
    const tables = [...db.matchAll(/\b(?:select|insert)\s+([a-z_]+)/g)].map((m) => m[1]);
    for (const t of tables) {
      if (["view", "baris"].includes(t)) continue;
      const ok = rels.has(t);
      checks.push(`tabel/view ${t}: ${ok ? "ada" : "TIDAK ADA"}`);
      if (!ok) status = "GAP";
    }
    if (/G-\d+|TODO|belum ada/i.test(db)) status = "GAP";
    if (!checks.length && status === "OK") status = "N/A";

    summary.total++;
    summary[status === "OK" ? "ok" : status === "GAP" ? "gap" : "na"]++;
    out.push({
      method: method.toUpperCase(),
      path,
      layer: op["x-layer"],
      roles: (op["x-roles"] ?? []).join(", "),
      db: db.replace(/\|/g, "/").replace(/\s+/g, " ").slice(0, 160),
      checks: checks.join("; "),
      codes: (op["x-error-codes"] ?? []).join(", "),
      status,
    });
  }
}

const md = [];
md.push("# Pemetaan Endpoint ke Database (WP-003)");
md.push("");
md.push(
  `Dibangkitkan otomatis oleh \`tools/api-db-mapping.mjs\` pada ${new Date().toISOString().slice(0, 10)} terhadap proyek Supabase nyata. Jangan diedit tangan; jalankan ulang skrip.`,
);
md.push("");
md.push(
  "Cara baca: kolom **DB** disalin dari `x-db` di `docs/openapi.yaml`. **Pemeriksaan** membandingkan nama fungsi `public`, tabel/view `public`, dan aksi `wo_transition` dengan database. `N/A` = bukan objek DB (Supabase Auth, Storage, Route Handler murni). `GAP` = objek tidak ada atau ditandai G-nn/TODO di openapi.",
);
md.push("");
md.push(
  `Ringkasan: ${summary.total} operasi, ${summary.ok} OK, ${summary.gap} GAP, ${summary.na} N/A.`,
);
md.push("");
md.push("| Status | Metode | Path | Lapis | Peran | DB | Pemeriksaan | Kode galat |");
md.push("|---|---|---|---|---|---|---|---|");
for (const o of out) {
  md.push(
    `| ${o.status} | ${o.method} | \`${o.path}\` | ${o.layer} | ${o.roles} | ${o.db} | ${o.checks || "-"} | ${o.codes || "-"} |`,
  );
}
writeFileSync("docs/orchestration/api_db_mapping.md", md.join("\n") + "\n");
console.log(summary);
for (const o of out.filter((x) => x.status === "GAP"))
  console.log("GAP", o.method, o.path, "|", o.checks || o.db);
