// Seed data fiktif Lapis 1 (WP-008): data master + akun uji per peran.
// Idempoten. Kata sandi akun diacak setiap pembuatan dan ditulis ke supabase/seed/.accounts.local.md
// (berkas ini di .gitignore). Pakai:  node tools/seed.mjs
//   node tools/seed.mjs --clean   -> hapus data bertanda seed (DEMO-*, @demo.vasta.test)
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import pg from "pg";

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
if (!env.DATABASE_URL) {
  console.error("DATABASE_URL belum diisi di .env.local");
  process.exit(2);
}
const client = new pg.Client({
  connectionString: env.DATABASE_URL,
  ssl: { rejectUnauthorized: false },
});
await client.connect();

const DOMAIN = "demo.vasta.test";

if (process.argv.includes("--clean")) {
  // Hanya data bertanda seed. Konfigurasi (keahlian, template, jenis layanan) dibiarkan.
  await client.query("begin");
  await client.query("delete from public.assets where asset_code like 'DEMO-%'");
  await client.query(
    "delete from public.customer_sites where customer_id in (select id from public.customers where code like 'DEMO-%')",
  );
  await client.query(
    "delete from public.customer_users where customer_id in (select id from public.customers where code like 'DEMO-%')",
  );
  await client.query("delete from public.customers where code like 'DEMO-%'");
  await client.query("delete from public.technicians where employee_code like 'DEMO-%'");
  // user_consents append-only (IMM01): akun yang sudah punya persetujuan tidak bisa dihapus.
  const del = await client.query(
    `delete from auth.users where email like '%@${DOMAIN}'
       and id not in (select user_id from public.user_consents)`,
  );
  await client.query("commit");
  console.log(`Data seed dihapus (${del.rowCount} akun dihapus).`);
  const kept = await client.query(`select email from auth.users where email like '%@${DOMAIN}'`);
  if (kept.rows.length) {
    console.log(
      `Akun berikut dipertahankan karena punya catatan persetujuan yang tidak bisa dihapus: ${kept.rows.map((r) => r.email).join(", ")}`,
    );
  }
  await client.end();
  process.exit(0);
}

// 1) data master
await client.query(readFileSync("supabase/seed/001_master_demo.sql", "utf8"));
console.log("OK data master");

// 2) akun uji
const accounts = [
  { key: "owner", name: "Owner Demo", role: "OWNER" },
  { key: "admin", name: "Admin CS Demo", role: "ADMIN_CS" },
  { key: "dispatcher", name: "Dispatcher Demo", role: "DISPATCHER" },
  { key: "spv", name: "Supervisor Demo", role: "SUPERVISOR" },
  { key: "gudang", name: "Petugas Gudang Demo", role: "WAREHOUSE" },
  { key: "finance", name: "Finance Demo", role: "FINANCE" },
  {
    key: "tek1",
    name: "Teknisi Satu Demo",
    role: "TECHNICIAN",
    code: "DEMO-T1",
    skills: ["AC", "CCTV"],
  },
  {
    key: "tek2",
    name: "Teknisi Dua Demo",
    role: "TECHNICIAN",
    code: "DEMO-T2",
    skills: ["GENSET", "AC"],
  },
  { key: "plg-a", name: "Rina Contoh", role: "CUSTOMER", customer: "DEMO-PLG-A", cRole: "ADMIN" },
  { key: "plg-b", name: "Dedi Contoh", role: "CUSTOMER", customer: "DEMO-PLG-B", cRole: "ADMIN" },
  { key: "plg-c", name: "Budi Santoso", role: "CUSTOMER", customer: "DEMO-PLG-C", cRole: "ADMIN" },
];

// Pertahankan kata sandi akun yang sudah ada dari jalankan sebelumnya.
const previous = {};
if (existsSync("supabase/seed/.accounts.local.md")) {
  for (const line of readFileSync("supabase/seed/.accounts.local.md", "utf8").split(/\r?\n/)) {
    const m = /^\| \w+ \| (\S+) \| (\S+) \|$/.exec(line);
    if (m) previous[m[1]] = m[2];
  }
}
const resetPasswords = process.argv.includes("--reset-passwords");
const lines = [];
for (const a of accounts) {
  const email = `${a.key}@${DOMAIN}`;
  const existing = await client.query("select id from auth.users where email = $1", [email]);
  let userId;
  let password = null;
  if (existing.rows.length) {
    userId = existing.rows[0].id;
    if (resetPasswords) {
      password = randomBytes(12).toString("base64url");
      await client.query(
        "update auth.users set encrypted_password = extensions.crypt($1, extensions.gen_salt('bf')), updated_at = now() where id = $2",
        [password, userId],
      );
    }
  } else {
    password = randomBytes(12).toString("base64url");
    const r = await client.query(
      `insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
         raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
         confirmation_token, recovery_token, email_change_token_new, email_change)
       values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', $1,
         extensions.crypt($2, extensions.gen_salt('bf')), now(),
         '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', $3::text), now(), now(),
         '', '', '', '')
       returning id`,
      [email, password, a.name],
    );
    userId = r.rows[0].id;
    await client.query(
      `insert into auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
       values (gen_random_uuid(), $1::uuid, jsonb_build_object('sub', $1::uuid::text, 'email', $2::text, 'email_verified', true),
         'email', $1::uuid::text, now(), now(), now())`,
      [userId, email],
    );
  }
  await client.query(
    "insert into public.user_roles (user_id, role) values ($1, $2) on conflict (user_id, role) do nothing",
    [userId, a.role],
  );
  if (a.role === "TECHNICIAN") {
    await client.query(
      "insert into public.technicians (user_id, employee_code, home_area) values ($1, $2, 'Jabodetabek (fiktif)') on conflict (user_id) do nothing",
      [userId, a.code],
    );
    for (const s of a.skills) {
      await client.query(
        `insert into public.technician_skills (technician_id, skill_id, level)
         select t.id, k.id, 2 from public.technicians t, public.skills k
         where t.user_id = $1 and k.code = $2 on conflict do nothing`,
        [userId, s],
      );
    }
  }
  if (a.role === "CUSTOMER") {
    await client.query(
      `insert into public.customer_users (customer_id, user_id, customer_role)
       select c.id, $1, $3::public.customer_role from public.customers c where c.code = $2
       on conflict (customer_id, user_id) do nothing`,
      [userId, a.customer, a.cRole],
    );
    await client.query(
      `insert into public.user_consents (user_id, policy_version)
       select $1::uuid, 'demo-0' where not exists (select 1 from public.user_consents where user_id = $1::uuid)`,
      [userId],
    );
  }
  lines.push(
    `| ${a.role} | ${email} | ${password ?? previous[email] ?? "(tidak diketahui, jalankan --clean lalu seed ulang)"} |`,
  );
  console.log(`${password ? "dibuat " : "ada    "} ${email} (${a.role})`);
}

writeFileSync(
  "supabase/seed/.accounts.local.md",
  [
    "# Akun uji (FIKTIF) - berkas lokal, tidak masuk git",
    "",
    "Kata sandi acak dibuat saat seed. Jangan dipakai di tempat lain.",
    "",
    "| Peran | Email | Kata sandi |",
    "|---|---|---|",
    ...lines,
    "",
  ].join("\n"),
);
console.log("Akun ditulis ke supabase/seed/.accounts.local.md");
await client.end();
