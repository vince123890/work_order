// Pembantu uji isolasi (WP-007). Memanggil Supabase NYATA dengan JWT pengguna seed.
// Butuh .env.local (URL, anon key, DATABASE_URL) dan supabase/seed/.accounts.local.md.
// Berkas rahasia hanya DIBACA di sini; isinya tidak pernah dicetak atau ditulis ulang.
import { readFileSync, existsSync } from "node:fs";
import pg from "pg";

function loadEnv(path: string): Record<string, string> {
  if (!existsSync(path)) return {};
  const out: Record<string, string> = {};
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m && m[1] && m[2] !== undefined) out[m[1]] = m[2];
  }
  return out;
}

export const env = { ...loadEnv(".env.local"), ...process.env } as Record<string, string>;
export const URL_BASE = env.NEXT_PUBLIC_SUPABASE_URL ?? "";
export const ANON = env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";
export const DATABASE_URL = env.DATABASE_URL ?? "";
export const DOMAIN = "demo.vasta.test";

const passwords: Record<string, string> = {};
if (existsSync("supabase/seed/.accounts.local.md")) {
  for (const line of readFileSync("supabase/seed/.accounts.local.md", "utf8").split(/\r?\n/)) {
    const m = /^\| \w+ \| (\S+) \| (\S+) \|$/.exec(line);
    if (m && m[1] && m[2]) passwords[m[1]] = m[2];
  }
}

/** Kata sandi akun uji khusus (dibuat fixture) hanya hidup di memori selama satu proses uji. */
export function setRuntimePassword(email: string, password: string): void {
  passwords[email] = password;
  tokenCache.delete(email);
}

export type Res<T = unknown> = { status: number; body: T; code?: string };

const tokenCache = new Map<string, string>();
export async function login(key: string): Promise<string> {
  const email = key.includes("@") ? key : `${key}@${DOMAIN}`;
  const cached = tokenCache.get(email);
  if (cached) return cached;
  const r = await fetch(`${URL_BASE}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: passwords[email] }),
  });
  const j = (await r.json()) as { access_token?: string };
  if (!j.access_token) throw new Error(`login gagal untuk ${email} (HTTP ${r.status})`);
  tokenCache.set(email, j.access_token);
  return j.access_token;
}

export async function api<T = unknown>(
  token: string | null,
  path: string,
  init: {
    method?: string;
    body?: unknown;
    prefer?: string;
    headers?: Record<string, string>;
  } = {},
): Promise<Res<T>> {
  const headers: Record<string, string> = {
    apikey: ANON,
    Authorization: `Bearer ${token ?? ANON}`,
    "Content-Type": "application/json",
    ...(init.headers ?? {}),
  };
  if (init.prefer) headers.Prefer = init.prefer;
  const r = await fetch(`${URL_BASE}${path}`, {
    method: init.method ?? "GET",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  const text = await r.text();
  let body: unknown = text;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    /* biarkan teks */
  }
  const code =
    body && typeof body === "object" && "code" in (body as object)
      ? String((body as { code: unknown }).code)
      : undefined;
  return { status: r.status, body: body as T, code };
}

type RestInit = {
  method?: string;
  body?: unknown;
  prefer?: string;
  headers?: Record<string, string>;
};
export const rest = <T = unknown>(token: string | null, path: string, init: RestInit = {}) =>
  api<T>(token, `/rest/v1/${path}`, init);

export const rpc = <T = unknown>(
  token: string | null,
  fn: string,
  args: unknown,
  headers?: Record<string, string>,
) => api<T>(token, `/rest/v1/rpc/${fn}`, { method: "POST", body: args, headers });

export function rowsOf(res: Res): Record<string, unknown>[] {
  return Array.isArray(res.body) ? (res.body as Record<string, unknown>[]) : [];
}

/** Seperti rowsOf tetapi GAGAL bila respons bukan 2xx berisi larik (tidak menelan galat). */
export function rowsStrict(res: Res, label = ""): Record<string, unknown>[] {
  if (res.status < 200 || res.status >= 300 || !Array.isArray(res.body)) {
    throw new Error(`${label} respons tak terduga: HTTP ${res.status} ${JSON.stringify(res.body)}`);
  }
  return res.body as Record<string, unknown>[];
}

/** Bentuk galat yang dibandingkan untuk uji "404 seragam". */
export function errShape(r: Res): {
  status: number;
  code?: string;
  message?: unknown;
  details?: unknown;
  hint?: unknown;
} {
  const b = (r.body && typeof r.body === "object" ? r.body : {}) as Record<string, unknown>;
  return { status: r.status, code: r.code, message: b.message, details: b.details, hint: b.hint };
}

/** Respons dianggap ditolak dengan SALAH SATU kode galat yang disebut (bukan sekadar status >= 400). */
export function deniedWith(r: Res, codes: string[]): { ok: boolean; info: string } {
  const ok = r.status >= 400 && r.status < 500 && r.code !== undefined && codes.includes(r.code);
  return {
    ok,
    info: `HTTP ${r.status} kode=${String(r.code)} (diharapkan ${codes.join("/")}) ${JSON.stringify(r.body).slice(0, 300)}`,
  };
}

/** Ambil semua baris sebuah relasi dengan paginasi; mengembalikan status agar galat tak tertelan. */
export async function fetchAll(
  token: string | null,
  relation: string,
  select = "*",
  pageSize = 1000,
  maxPages = 20,
): Promise<{ status: number; code?: string; rows: Record<string, unknown>[]; truncated: boolean }> {
  const rows: Record<string, unknown>[] = [];
  for (let page = 0; page < maxPages; page++) {
    const r = await rest(
      token,
      `${relation}?select=${select}&limit=${pageSize}&offset=${page * pageSize}`,
    );
    if (r.status < 200 || r.status >= 300 || !Array.isArray(r.body)) {
      return { status: r.status, code: r.code, rows, truncated: false };
    }
    rows.push(...(r.body as Record<string, unknown>[]));
    if ((r.body as unknown[]).length < pageSize) return { status: 200, rows, truncated: false };
  }
  return { status: 200, rows, truncated: true };
}

// ---------- koneksi Postgres langsung (peran postgres, melewati RLS) ----------

export function newDb(): pg.Client {
  return new pg.Client({ connectionString: DATABASE_URL, ssl: { rejectUnauthorized: false } });
}

export async function withDb<T>(fn: (db: pg.Client) => Promise<T>): Promise<T> {
  const db = newDb();
  await db.connect();
  try {
    return await fn(db);
  } finally {
    await db.end();
  }
}

export async function listPublicRelations(): Promise<{ name: string; kind: string }[]> {
  return withDb(async (db) => {
    const r = await db.query(
      `select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind in ('r','p','v') order by 1`,
    );
    return r.rows.map((x) => ({ name: String(x.relname), kind: String(x.relkind) }));
  });
}

export async function userIdOf(db: pg.Client, key: string): Promise<string> {
  const email = key.includes("@") ? key : `${key}@${DOMAIN}`;
  const r = await db.query("select id from auth.users where email = $1", [email]);
  if (!r.rows[0]) throw new Error(`akun ${email} tidak ada`);
  return String(r.rows[0].id);
}

export type SqlOutcome = {
  ok: boolean;
  code?: string;
  message?: string;
  rows: Record<string, unknown>[];
};

/**
 * Jalankan SQL sebagai peran `authenticated` dengan sub JWT tertentu (meniru PostgREST), dalam transaksi
 * yang SELALU di-rollback. `claimSub` null = peran `anon`.
 */
export async function asRole(
  db: pg.Client,
  claimSub: string | null,
  sql: string,
  params: unknown[] = [],
): Promise<SqlOutcome> {
  await db.query("begin");
  try {
    await db.query(`set local role ${claimSub === null ? "anon" : "authenticated"}`);
    if (claimSub !== null) {
      await db.query("select set_config('request.jwt.claim.sub', $1, true)", [claimSub]);
      await db.query("select set_config('request.jwt.claims', $1, true)", [
        JSON.stringify({ sub: claimSub, role: "authenticated" }),
      ]);
    }
    const r = await db.query(sql, params);
    return { ok: true, rows: r.rows as Record<string, unknown>[] };
  } catch (e) {
    const err = e as { code?: string; message?: string };
    return { ok: false, code: err.code, message: err.message, rows: [] };
  } finally {
    await db.query("rollback");
  }
}

/** Jalankan SQL sebagai superuser dalam transaksi yang di-rollback dan kembalikan kode galat (bila ada). */
export async function trySql(
  db: pg.Client,
  sql: string,
  params: unknown[] = [],
): Promise<SqlOutcome> {
  await db.query("begin");
  try {
    const r = await db.query(sql, params);
    return { ok: true, rows: r.rows as Record<string, unknown>[] };
  } catch (e) {
    const err = e as { code?: string; message?: string };
    return { ok: false, code: err.code, message: err.message, rows: [] };
  } finally {
    await db.query("rollback");
  }
}

/** Peta paralel dengan batas konkurensi (urutan hasil terjaga). */
export async function pmap<T, R>(
  items: T[],
  fn: (x: T, i: number) => Promise<R>,
  concurrency = 6,
): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const worker = async () => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await fn(items[i] as T, i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
  return out;
}

export type RpcInfo = {
  name: string;
  argNames: string[];
  argTypes: string[]; // hasil format_type, mis. 'uuid', 'app_role[]', 'billing_type'
  required: number; // jumlah argumen tanpa default
};

/** Semua fungsi schema public yang boleh dieksekusi `authenticated` (kecuali fungsi pemicu). */
export async function listRpcs(): Promise<RpcInfo[]> {
  return withDb(async (db) => {
    const r = await db.query(`
      select p.proname, p.proargnames, p.pronargs, p.pronargdefaults,
             (select coalesce(array_agg(format_type(u.t, null) order by u.o), '{}')
                from unnest(p.proargtypes::oid[]) with ordinality as u(t, o)) as argtypes
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
         and has_function_privilege('authenticated', p.oid, 'EXECUTE')
       order by p.proname`);
    return r.rows.map((x) => ({
      name: String(x.proname),
      argNames: (x.proargnames ?? []) as string[],
      argTypes: x.argtypes as string[],
      required: Number(x.pronargs) - Number(x.pronargdefaults),
    }));
  });
}

/** Label pertama tiap tipe enum di schema public (untuk argumen dummy yang sah secara tipe). */
export async function enumFirstLabels(): Promise<Record<string, string>> {
  return withDb(async (db) => {
    const r = await db.query(`
      select t.typname, (array_agg(e.enumlabel order by e.enumsortorder))[1] as first
        from pg_type t join pg_enum e on e.enumtypid = t.oid
        join pg_namespace n on n.oid = t.typnamespace where n.nspname = 'public' group by t.typname`);
    return Object.fromEntries(r.rows.map((x) => [String(x.typname), String(x.first)]));
  });
}
