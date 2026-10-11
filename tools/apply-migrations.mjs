// Menerapkan supabase/migrations/*.sql berurutan ke database di DATABASE_URL (dari .env.local).
// Pengaman: menolak berjalan jika schema public sudah berisi tabel dan migrasi belum tercatat.
// Pelacakan memakai tabel yang sama dengan Supabase CLI: supabase_migrations.schema_migrations.
// Pakai:  node tools/apply-migrations.mjs [--dry-run]
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
const dry = process.argv.includes("--dry-run");
const files = readdirSync("supabase/migrations")
  .filter((f) => f.endsWith(".sql"))
  .sort();

const client = new pg.Client({ connectionString: url, ssl: { rejectUnauthorized: false } });
await client.connect();
const host = new URL(url).host;
console.log(`Terhubung ke ${host} (${dry ? "DRY RUN" : "TERAPKAN"})`);

await client.query("create schema if not exists supabase_migrations");
await client.query(
  "create table if not exists supabase_migrations.schema_migrations (version text primary key, name text, statements text[])",
);
const done = new Set(
  (await client.query("select version from supabase_migrations.schema_migrations")).rows.map(
    (r) => r.version,
  ),
);

const tables = (
  await client.query(
    "select count(*)::int n from information_schema.tables where table_schema='public' and table_type='BASE TABLE'",
  )
).rows[0].n;
if (done.size === 0 && tables > 0) {
  console.error(`public sudah berisi ${tables} tabel dan belum ada migrasi tercatat. Dihentikan.`);
  process.exit(3);
}

for (const f of files) {
  const version = f.slice(0, 4);
  const name = f.slice(5, -4);
  if (done.has(version)) {
    console.log(`lewati ${f} (sudah tercatat)`);
    continue;
  }
  if (dry) {
    console.log(`akan menerapkan ${f}`);
    continue;
  }
  const sql = readFileSync(`supabase/migrations/${f}`, "utf8");
  try {
    await client.query("begin");
    await client.query(sql);
    await client.query(
      "insert into supabase_migrations.schema_migrations(version,name,statements) values ($1,$2,$3)",
      [version, name, [sql]],
    );
    await client.query("commit");
    console.log(`OK ${f}`);
  } catch (e) {
    await client.query("rollback");
    console.error(`GAGAL ${f}: ${e.message}${e.where ? "\n  di: " + e.where.split("\n")[0] : ""}`);
    process.exit(1);
  }
}
await client.end();
