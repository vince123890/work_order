// Pemeriksaan keadaan database Supabase setelah migrasi (baca-saja). Pakai: node tools/verify-db.mjs
import pg from "pg";
import { readFileSync } from "node:fs";
const env = Object.fromEntries(
  readFileSync(".env.local", "utf8")
    .split(/\r?\n/)
    .map((l) => /^([A-Z0-9_]+)=(.*)$/.exec(l))
    .filter(Boolean)
    .map((m) => [m[1], m[2]]),
);
const c = new pg.Client({ connectionString: env.DATABASE_URL, ssl: { rejectUnauthorized: false } });
await c.connect();
const q = async (label, sql) => {
  try {
    const r = await c.query(sql);
    console.log("##", label);
    console.table(r.rows);
  } catch (e) {
    console.log("##", label, "ERROR:", e.message);
  }
};
await q("versi", "select version()");
await q(
  "ekstensi",
  "select extname, extversion from pg_extension where extname in ('pg_cron','pg_trgm','pgcrypto','uuid-ossp') order by 1",
);
await q(
  "tabel public tanpa RLS",
  "select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p') and not c.relrowsecurity",
);
await q(
  "jumlah tabel/view/fungsi public",
  "select (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p')) tabel, (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='v') view, (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public') fungsi_public, (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app') fungsi_app",
);
await q("cron jobs", "select jobname, schedule, active from cron.job");
await q(
  "tzdata Asia/Jakarta",
  "select now() at time zone 'Asia/Jakarta' as jakarta, (select count(*) from pg_timezone_names where name='Asia/Jakarta') ada",
);
await q("storage buckets", "select id, public, file_size_limit from storage.buckets");
await q("app.tables_without_rls", "select * from app.tables_without_rls()");
await q(
  "schema app terekspos ke anon?",
  "select has_schema_privilege('anon','app','usage') anon_app, has_schema_privilege('authenticated','app','usage') auth_app",
);
await q(
  "migrasi tercatat",
  "select version,name from supabase_migrations.schema_migrations order by 1",
);
await c.end();
