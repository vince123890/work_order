// Uji asap (smoke) akun seed: login lewat Supabase Auth, lalu baca data lewat PostgREST sebagai tiap pengguna.
// BUKAN pengganti uji isolasi WP-007. Pakai: node tools/verify-seed.mjs
import { readFileSync, existsSync } from "node:fs";

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
const URL = env.NEXT_PUBLIC_SUPABASE_URL;
const KEY = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

const accounts = {};
for (const line of readFileSync("supabase/seed/.accounts.local.md", "utf8").split("\n")) {
  const m = /^\| (\w+) \| (\S+) \| (\S+) \|$/.exec(line);
  if (m && m[1] !== "Peran") accounts[m[2]] = { role: m[1], password: m[3] };
}

async function login(email, password) {
  const r = await fetch(`${URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const j = await r.json();
  return r.ok ? j.access_token : null;
}
async function get(token, path) {
  const r = await fetch(`${URL}/rest/v1/${path}`, {
    headers: { apikey: KEY, Authorization: `Bearer ${token}` },
  });
  const body = await r.json().catch(() => null);
  return { status: r.status, rows: Array.isArray(body) ? body : null, body };
}

const tokens = {};
let fails = 0;
for (const [email, a] of Object.entries(accounts)) {
  const t = await login(email, a.password);
  tokens[email] = t;
  console.log(`${t ? "login OK  " : "login GAGAL"} ${email} (${a.role})`);
  if (!t) fails++;
}

const t = (k) => tokens[`${k}@demo.vasta.test`];
console.log("\nBaca aset sebagai tiap pengguna (jumlah baris yang terlihat):");
for (const k of ["plg-a", "plg-b", "plg-c", "tek1", "admin", "owner"]) {
  if (!t(k)) continue;
  const r = await get(t(k), "assets?select=asset_code");
  console.log(
    `  ${k}: HTTP ${r.status}, ${r.rows ? r.rows.length : "-"} aset ${r.rows ? "" : JSON.stringify(r.body).slice(0, 120)}`,
  );
}

console.log("\nSmoke isolasi pelanggan:");
const a = await get(t("plg-a"), "assets?select=asset_code");
const b = await get(t("plg-b"), "assets?select=asset_code");
const leakA = (a.rows ?? []).filter((x) => !x.asset_code.startsWith("DEMO-A-")).length;
const leakB = (b.rows ?? []).filter((x) => !x.asset_code.startsWith("DEMO-B-")).length;
console.log(`  plg-a melihat aset non-A: ${leakA} (harus 0)`);
console.log(`  plg-b melihat aset non-B: ${leakB} (harus 0)`);
const cust = await get(t("plg-a"), "customers?select=code");
console.log(
  `  plg-a membaca customers: ${cust.rows ? cust.rows.map((x) => x.code).join(",") : "ditolak/" + cust.status}`,
);
const wo = await get(t("plg-a"), "work_orders?select=id&limit=1");
console.log(
  `  plg-a membaca work_orders langsung: HTTP ${wo.status}, ${wo.rows ? wo.rows.length + " baris" : "ditolak"} (belum ada WO, jadi 0 baris belum membuktikan kebijakan; diuji di WP-007)`,
);
const roles = await get(t("plg-a"), "user_roles?select=user_id,role");
console.log(
  `  plg-a membaca user_roles: ${roles.rows ? roles.rows.length + " baris" : "HTTP " + roles.status}`,
);
if (leakA || leakB) fails++;
process.exit(fails ? 1 : 0);
