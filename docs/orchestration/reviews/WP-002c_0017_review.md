# Review migrasi 0017 (security-auditor, read-only)

Putusan: **LAYAK SETELAH PERBAIKAN** (dua perbaikan kecil sudah dikerjakan orchestrator, lihat bawah). Reviewer tidak menjalankan perintah. Orchestrator menjalankan sendiri `tools/try-migration-0017.mjs --rounds=10` pada 2026-10-12.

## Hasil verifikasi orchestrator
| Pemeriksaan | Hasil nyata |
|---|---|
| Fase A (transaksi di database nyata di atas 0016, selalu rollback) | semua OK; 61 kolom view identik; backfill utuh (18 -> 18); idempoten; RLS/GRANT sesuai; fungsi definer ber-`search_path` terkunci |
| Kontrol desain 0016 (upsert) di schema sementara | deadlock 5 dari 10 (tanpa jeda), 10 dari 10 (jeda 50 ms) -> uji sahih |
| Desain 0017 (insert murni) | **0 dari 10** dan **0 dari 10**; kedua commit sukses 10/10; tidak ada sinyal hilang |
| Stres pemadatan (2 penulis terbalik + 2 pemadat) | 0 galat/deadlock; 285 pemadatan, 126 baris dihapus |
| Schema `n3_scratch` | dihapus dan terbukti tidak ada |
| Database nyata | 0017 TIDAK terpasang (fungsi pemadat 0, tidak tercatat) |
| Uji D2 pada kondisi 0016 terpasang (run tenang) | gagal: deadlock 4 dari 5 putaran -> N3 nyata |

Catatan: satu run awal orchestrator melewati batas waktu 560 detik dan meninggalkan `n3_scratch`; sudah dihapus dan diverifikasi.

## Temuan reviewer
| No | Tingkat | Ringkas | Status |
|---|---|---|---|
| 1 | major | Penerapan tanpa `lock_timeout`/`statement_timeout`; `drop constraint` mengambil ACCESS EXCLUSIVE | **DIPERBAIKI**: `set local lock_timeout='5s'; set local statement_timeout='60s';` ditambahkan di 0017 dan `docs/04` (identik, diff kosong) |
| 2 | major | Drop PK mengubah replica identity; masalah jika tabel ada di publication | **TERBUKTI TIDAK BERLAKU**: publication hanya `supabase_realtime` (bukan all-tables) dan tidak memuat `wo_child_changes` |
| 3 | major (non-SQL) | `tests/isolation/migrasi-0016.test.ts` rapuh setelah 0017: `rows[0]` tanpa urutan, `toHaveLength(1)`, D3 memakai `on conflict (wo_id)` (42P10), perbandingan count DB vs REST lintas waktu | Menunggu; dikerjakan bersamaan dengan penerapan |
| 4-6 | minor | Pemadat memindai seluruh tabel; job_runs menulis OK untuk panggilan yang kalah lock dan tumbuh ~144 baris/hari tanpa retensi; semua galat pemadat ditelan (alarm harus membaca job_runs ERROR) | Dicatat |
| 7 | minor | RLS/GRANT dinyatakan ulang, idempoten | OK |
| 8 | minor (kontrak pull) | `changed_at` diambil di fase commit sebelum commit terlihat; pull dengan kursor = waktu pull bisa melewatkan perubahan | Kontrak `/sync/pull` WAJIB tumpang-tindih kursor (mundur beberapa menit) |
| 9 | minor | Jangan jalankan ulang 0016 di database ber-0017 (backfill `on conflict (wo_id)` dan fungsi trigger lama) | Dicatat; terlindung `schema_migrations` |
| 10-11 | minor | `cron.schedule` bernama = upsert (pg_cron 1.6.4 terverifikasi); placeholder GUC per WO per sesi pooled | OK / dicatat |

Tafsiran PJ "trigger tanpa exception handler" dinilai wajar dan lebih aman (menelan galat = sinyal hilang diam-diam). Penyimpangan dari kriteria ini dinyatakan di D35 dan perlu diketahui user.

## Syarat sebelum/sesudah penerapan
1. Terapkan di jam sepi dengan `node tools/apply-migrations.mjs`; jangan jalankan ulang 0016 sesudahnya.
2. Perbarui `tests/isolation/migrasi-0016.test.ts` (butir 3) lalu jalankan seluruh suite: D1-D3 harus hijau di database nyata.
3. Kontrak `/sync/pull`: tumpang-tindih kursor, baca `children_changed_at` dari view; pantau `job_runs` status ERROR; atur `retention.job_runs_days`.
