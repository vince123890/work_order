# Review kedua migrasi 0016 revisi 1 (security-auditor, read-only)

Putusan: **LAYAK DITERAPKAN**, dengan syarat non-SQL. Tidak ada perbaikan SQL yang wajib; tidak ada temuan blocker/major baru. Reviewer tidak menjalankan perintah. Orchestrator menjalankan sendiri `tools/try-migration.mjs` (hanya rollback): 145 OK, 0 gagal; bagian 0016 di `docs/04` identik dengan berkas migrasi.

## Review pertama (butir 1-10)
8 TERTUTUP, 2 TERTUTUP SEBAGIAN (butir 3: konkurensi belum diuji; butir 6: replay `p_op_id` longgar). Tidak ada yang terbuka. `extra_cost_request` dan `wo_submit_deficiencies` dibandingkan baris demi baris dengan 0010/0008: hanya berbeda pada baris yang dimaksud.

## Temuan baru (semua minor/obs)
| No | Ringkas |
|---|---|
| 4.1 | `wo_attachments_insert_tech` tidak menolak path `sig/` (pemeriksaan satu arah). Opsional. |
| 4.2 | Constraint trigger deferred: deadlock multi-WO di fase commit dimungkinkan; bila upsert gagal, seluruh transaksi bisnis batal (tanpa exception handler). Klien/rute wajib retry pada 40P01; uji dua sesi setelah penerapan. |
| 4.3 | Batch INSERT `sync_operations`: satu `wo_id` tidak aktif (WO baru di-REASSIGN) menggagalkan seluruh statement. Rute harus menyisipkan per operasi dan memakai `wo_id` NULL lalu `sync_op_record(RESCUED)`. |
| 4.4 | Replay `wo_declare_no_parts` tidak terikat ke WO/tipe operasi (hanya merugikan diri sendiri). |
| 4.5 | `sync_operations` tak terbatas ukuran/jumlah; retensi hanya menghapus APPLIED. Beri batas ukuran payload dan perluas retensi. |
| 4.6-4.8 | `pg_column_size` bukan ukuran logis; GUC per WO per sesi pooled; tanda tangan teknisi tidak diperiksa size/mimetype di SQL (tanggung jawab `/uploads/complete`). |

## Syarat non-SQL sebelum klien memakai 0016
1. `/uploads/complete` menandai `wo_signatures.upload_status='UPLOADED'` setelah verifikasi ukuran/mimetype.
2. `/sync/push` menyisipkan per operasi; `wo_id` NULL untuk WO terlepas lalu `sync_op_record(RESCUED)`.
3. `/sync/pull` pindah ke `tech_work_orders` + `wo_child_changes`; kursor tumpang-tindih; `coalesce(children_changed_at, updated_at)`.
4. `/uploads` hanya mengeluarkan signed URL `sig/` untuk tanda tangan.
5. Perbarui `tests/isolation` (G-08, S1, N1, `storage-struktur` 7 -> 6, `RPC_ALLOWED`, `fixtures.ts`).
6. Uji konkurensi dua sesi setelah penerapan.
7. Terapkan di jam sepi dengan `node tools/apply-migrations.mjs`.
8. Klien teknisi mengikuti kontrak baru (tanpa `total`; baca lewat `tech_work_orders`; `wo_declare_no_parts` hanya LEAD).
