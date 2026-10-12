# Review migrasi 0016 (security-auditor, read-only)

Putusan: **LAYAK SETELAH PERBAIKAN**. Tidak ada blocker absolut di SQL; 4 temuan major sebaiknya masuk 0016 sebelum diterapkan. Disimpan oleh orchestrator dari laporan agen. Reviewer tidak menjalankan uji. Orchestrator menjalankan sendiri `tools/try-migration.mjs` (rollback): semua pemeriksaan lulus dan database tetap tanpa 0016.

| No | Tingkat | Lokasi | Ringkas |
|---|---|---|---|
| 1 | major | 0016:122-134 `wo_customer_sign` | Objek APA PUN di prefix WO (foto OTHER/FAILED_VISIT, foto teknisi) lolos sebagai "tanda tangan" dan setelah CLOSED terbaca pelanggan lewat cabang tanda tangan `can_read_object`. Wajibkan sub-prefix `.../sig/`, panjang path > prefix, tolak path yang sudah terdaftar di `wo_attachments`, cek ukuran/mimetype. Berlaku juga untuk `wo_signatures_insert_tech` (0013:420-422). |
| 2 | major | 0013:471, 0013:212, 0008:453 (N2) | `sync_operations_insert_own` hanya `user_id = auth.uid()`; `wo_id` bebas. Pelanggan atau teknisi lama bisa menyisipkan baris RECEIVED untuk WO orang lain; guard menolak T-16/T-18/T-19 selama ada baris RECEIVED -> WO terblokir permanen, staf tidak punya jalur membersihkan. Masukkan ke 0016: policy `with check (user_id = (select auth.uid()) and has_any_role('{TECHNICIAN}') and (wo_id is null or wo_id in (select app.my_active_wo_ids())))`. Cocokkan dengan matriks 05:155 (pelanggan "W insert" sync_operations). |
| 3 | major | 0016:309-327 trigger sinyal | Trigger per baris di 11 tabel meng-upsert SATU baris per WO: kunci baris dipegang sampai commit, risiko deadlock dengan fungsi yang mengunci `work_orders` dulu lalu menulis anak (mis. `extra_cost_request` 0010:658), banyak versi baris/entri indeks per transaksi. Ganti ke constraint trigger `deferrable initially deferred` atau trigger statement-level terurut; tambah uji konkurensi. |
| 4 | major | 0010:712 `extra_cost_request` | Mengembalikan `total` ke teknisi LEAD (qty x harga master membocorkan harga). Masukkan `create or replace` tanpa `'total'`, atau terima risikonya secara eksplisit. |
| 5 | minor | 0016:204-206 `wo_cost_summary` | `p_wo_id` NULL pada non-staf tidak melempar WO005. Tambah `p_wo_id is null or auth.uid() is null or not (...)` dan `if not found then WO005`. |
| 6 | minor | 0016:143-175 `wo_declare_no_parts` | `p_op_id` tidak dipakai (replay op lama bisa membalik nilai); helper boleh mengubah. |
| 7 | minor | handoff baris 38 | Klaim "pemilik bisa menandai APPLIED = pra-ada" tidak didukung SQL: kemampuan itu BARU lewat `sync_op_record`. Koreksi D32; batasi ukuran `p_result`. |
| 8 | minor | 0016:330-331 backfill | `changed_at = work_orders.updated_at` bisa lebih lama dari perubahan anak terakhir; WO tanpa anak punya `children_changed_at` NULL. Backfill `clock_timestamp()` atau gunakan `greatest(...)`; pull memakai `coalesce(children_changed_at, updated_at)`. |
| 9 | minor | kunci DDL | Semua kunci ACCESS EXCLUSIVE dipegang sampai commit; tambah `set local lock_timeout = '5s'`; terapkan di jam sepi. |
| 10 | minor | header 0016:1-5 | Bukan "aditif": ada `drop policy work_orders_tech` dan perubahan perilaku fungsi. Koreksi komentar. |
| 11 | obs | `tech_work_orders` | 60 kolom + `children_changed_at`; 6 kolom harga/penagihan benar dikeluarkan; `security_barrier` dan filter `my_active_wo_ids` ada. `contract_id`/`type=REWORK`/`parent_wo_id` memungkinkan inferensi jenis penagihan (risiko kecil). |
| 12-13 | positif | `can_read_object`, N1, S2 | Pemeriksaan bucket per cabang benar; N1 dan filter S2 benar, tanpa rekursi. |

## Regresi G-08 (tidak ditemukan yang rusak diam-diam di SQL)
Tidak ada policy atau fungsi invoker yang membaca `work_orders` dengan RLS teknisi. `v_today_work_orders` jadi kosong bagi teknisi (sesuai desain: dipakai DSP/SPV). Tidak terverifikasi: Realtime `postgres_changes`, embedding PostgREST, dan klien teknisi.

## Syarat non-SQL sebelum klien memakai 0016
- `/uploads/complete` harus menandai `wo_signatures.upload_status='UPLOADED'` (D31); tanpa itu tanda tangan perangkat teknisi selalu `SIGNATURE_MISSING`.
- `/sync/pull` pindah ke `tech_work_orders` + `wo_child_changes`, kursor tumpang-tindih, `coalesce(children_changed_at, updated_at)`.
- Perbarui `tests/isolation` (fixtures baris 324; `RPC_ALLOWED`; uji G-08/S1/N1; `storage-struktur.test.ts` 7 -> 6) setelah penerapan.
