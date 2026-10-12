# Celah API vs Database yang Butuh Keputusan (hasil WP-003)

Tanggal: 2026-10-12. Sumber: `docs/03_api_design.md` bagian 10.2 (G-01..G-13), dicocokkan ke database Supabase nyata oleh `tools/api-db-mapping.mjs` dan pemeriksaan langsung. Tabel lengkap per endpoint: `api_db_mapping.md`.

## Temuan penting tentang rencana
1. `01_team_and_task_plan.md` menulis WP-003 harus menyelaraskan nama `rpc_*`/view/kode galat antara 03 dan 04/05 dan "90 operasi". Itu sudah usang: 03 versi 0.2 sudah mengikuti 04/05, dan jumlah operasi di `openapi.yaml` adalah **59** (28 Lapis 1, 25 Lapis 2, 6 Lapis 3).
2. Hasil pencocokan ke database nyata: **44 OK, 8 N/A (Auth/Storage/Route Handler murni), 7 GAP**. Semua 7 GAP sudah tercatat di 03 (G-05, G-06, G-10). Tidak ada nama RPC, tabel, atau aksi `wo_transition` di openapi yang tidak ada di database di luar celah itu.
3. **Keputusan K-04 bertabrakan dengan database** (lihat G-01 di bawah).

## Celah yang memblokir Lapis 1 (dikonfirmasi ada di database nyata)

| ID | Kenyataan di DB (diperiksa) | Dampak | Usulan |
|---|---|---|---|
| **G-01** | T-19 `APPROVE_CLOSE` hanya `SUPERVISOR`; tidak ada setelan penutupan otomatis. **Bertentangan dengan K-04** ("teknisi tutup final di L1") | Demo L1 tidak bisa menutup WO tanpa akun SPV | (a) demo L1 memakai akun SPV yang menyetujui (tanpa ubah DB, K-04 diubah); atau (b) migrasi tambahan: setelan `requires_supervisor_review` dan `allow_system` untuk `APPROVE_CLOSE` |
| **G-13** | `work_orders.no_parts_used` ada, tapi tidak ada jalur tulis untuk teknisi | BR-040 butir 6: WO tanpa suku cadang tidak bisa ditutup (`PARTS_NOT_DECLARED`) | RPC `wo_declare_no_parts` |
| **G-04** | `wo_signatures` tanpa kolom `upload_status` (tidak ada) | Penutupan tidak memeriksa gambar tanda tangan sudah terunggah | Tambah kolom dan cek di guard penutupan |
| **G-06** | `sync_operations`: klien tanpa hak ubah status/hasil; tidak ada `sync_op_record`; tidak ada kolom `resolved_*` | `/sync/push` butuh `service_role` di luar daftar 05 bagian 6.3; draf `RESCUED` tidak bisa diselesaikan | Tambah RPC dan kolom; atau perluas daftar `service_role` (butuh persetujuan keamanan) |
| **G-05** | Tidak ada `sync_changes`, `change_seq`, tombstone | `/sync/pull` berbasis `updated_at`; perubahan anak WO bisa tidak terlihat | Trigger yang menaikkan `work_orders.updated_at` dari anak, atau umpan perubahan |
| **G-12** | Tidak ada `wo_closure_check`, `sla_acknowledge`, `wo_reschedule` | Pratinjau kekurangan penutupan (L1-T10) tidak bisa dari server | Tambah RPC (closure_check untuk L1; dua lainnya L2) |
| **G-08** | Tidak ada view `tech_work_orders`; teknisi bisa `SELECT` seluruh kolom `work_orders` (termasuk `estimate_total`, `billing_*`) | Melanggar aturan "teknisi tidak melihat harga" | View `tech_work_orders` tanpa kolom harga, cabut SELECT tabel untuk TECHNICIAN |

Celah lain Lapis 1 yang bukan migrasi: **G-02** (batas laju per IP tidak mungkin lewat PostgREST; terima batas per pelanggan atau pindahkan pemesanan ke satu Route Handler) dan **G-03** (tidak ada `idempotency_keys`; RPC tanpa `p_op_id` tidak idempoten di luar sinkron).

## Celah Lapis 2/3 (tidak memblokir L1)
G-07 (`run_job` ada di schema `app`, tidak terekspos), G-09 (penyesuaian stok dua langkah), G-10 (RPC invoice, pembayaran, ekspor, impor, anonimisasi, dashboard), G-11 (`push_subscriptions`, notifikasi `report.ready`/`invoice.issued`, retry notifikasi).

## Pertanyaan keputusan untuk Anda
1. **G-01**: pilih (a) SPV menyetujui penutupan di demo L1 (K-04 diubah), atau (b) tambah setelan penutupan otomatis lewat migrasi 0016?
2. Setujui satu **migrasi tambahan 0016** (aditif, tanpa menghapus apa pun) yang menutup G-04, G-05, G-06, G-08, G-12 (hanya `wo_closure_check`), G-13? Ini mengubah skema 04 yang sudah ada di Supabase, sehingga butuh persetujuan (CP-04) dan harus ditulis ulang juga di `docs/04_database_schema.sql`/05.
3. **G-02**: terima batas laju per pelanggan saja?
4. **G-06**: apakah `service_role` boleh dipakai oleh `/sync/push` untuk mencatat status operasi (menambah daftar tertutup 05 bagian 6.3), atau lebih baik RPC `sync_op_record`? Saran: RPC, supaya `service_role` tidak melebar.

## Temuan keamanan baru dari review WP-007 (menambah isi migrasi 0016)
Sumber: `docs/orchestration/reviews/WP-007_review_v1.md` dan uji nyata WP-007. S1 terbukti oleh uji di Supabase nyata; S2 dicabut (lihat baris S2); N1 baru dari PJ WP-007.

| ID | Temuan | Lokasi | Usulan perbaikan |
|---|---|---|---|
| ~~S2~~ | **DICABUT sebagai bug eksploitabel (menunggu konfirmasi review v2).** Dugaan awal: pelanggan melihat pembayaran invoice DRAFT. Uji di Supabase nyata (WP-007) menunjukkan tidak terjadi: subquery policy `payments_customer` membaca `invoices` dengan RLS pemanggil, sehingga filter `ISSUED/PAID` ikut berlaku. Verifikasi awal orchestrator hanya membaca teks policy, bukan menjalankannya. Tetap disarankan menambah filter status eksplisit sebagai pertahanan berlapis | `0013:461-462` | Opsional: tambah `and i.status in ('ISSUED','PAID')` |
| **S1** | `wo_cost_summary` dapat dipanggil teknisi pada WO aktifnya dan mengembalikan `estimate_total` dan `projected_total` (bocor harga ke teknisi; belum tercatat di G-08) | `0010:902-916` | Batasi hasil untuk teknisi ke `needs_approval` saja |
| S4 | `can_read_object`: cabang `req` tidak memeriksa nama bucket; teknisi bisa membaca bucket `reports` untuk WO aktifnya | `0013:44-56` | Periksa bucket per cabang |
| S6 | ADMIN_CS bebas memberi peran SUPERVISOR/FINANCE/WAREHOUSE/TECHNICIAN (termasuk ke dirinya sendiri) | `0013:67-85` | Keputusan: sesuai D22 atau dibatasi? |
| S9 | Pelanggan membaca `customers.auto_approve` (kontrol internal) | `0003:69` | View terbatas atau cabut kolom |

| N1 | Akun nonaktif (`is_active=false`) masih membaca baris `customer_users` miliknya sendiri; policy `customer_users_select` memakai `user_id = auth.uid()` tanpa memeriksa `profiles.is_active` (risiko rendah: relasi data pelanggan lain kosong untuk akun nonaktif). Ditemukan uji nyata WP-007 | `0013` policy `customer_users_select` | Tambah pemeriksaan `is_active` |

Status: belum diperbaiki. Perbaikan butuh persetujuan migrasi `0016` (lihat pertanyaan 2 di atas).
