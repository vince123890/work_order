// Memecah docs/04_database_schema.sql menjadi supabase/migrations/NNNN_nama.sql
// berdasarkan penanda "-- ===== MIGRATION nnnn: judul". Isi SQL tidak diubah.
import { readFileSync, writeFileSync, mkdirSync, readdirSync, unlinkSync } from "node:fs";

const src = readFileSync("docs/04_database_schema.sql", "utf8").replace(/\r\n/g, "\n");
const lines = src.split("\n");
const marker = /^-- ===== MIGRATION (\d{4}): (.+?) =*$/;

const starts = [];
lines.forEach((l, i) => {
  const m = marker.exec(l);
  if (m) starts.push({ i, num: m[1], title: m[2] });
});

mkdirSync("supabase/migrations", { recursive: true });
for (const f of readdirSync("supabase/migrations"))
  if (f.endsWith(".sql")) unlinkSync(`supabase/migrations/${f}`);

const header = lines.slice(0, starts[0].i).join("\n");
starts.forEach((s, k) => {
  const end = k + 1 < starts.length ? starts[k + 1].i : lines.length;
  const slug = s.title
    .toLowerCase()
    .replace(/\(.*?\)/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "")
    .slice(0, 40);
  let body = lines.slice(s.i, end).join("\n").replace(/\s+$/, "") + "\n";
  if (k === 0) body = header + "\n" + body;
  writeFileSync(`supabase/migrations/${s.num}_${slug}.sql`, body);
  console.log(s.num, slug, end - s.i, "baris");
});
