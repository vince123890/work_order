# Review WP-007 v2 (security-auditor, read-only)

Putusan: **LULUS DENGAN CATATAN**. Disimpan oleh orchestrator dari laporan agen. Reviewer tidak menjalankan uji; orchestrator menjalankan sendiri `npm run test:isolation` pada 2026-10-12: **129 uji, 128 lulus, 1 gagal (N1, sengaja merah), 0 dilewati, 368 detik**. Dua dari 128 yang lulus adalah `it.fails` (celah G-08 dan S1 yang diketahui).

## Status v1 -> v2
- T1-T20: 13 tertutup (T2-T8, T10, T13, T14, T17-T20), 7 tertutup sebagian (T1, T6, T9, T11, T12, T15, T16). Tidak ada yang terbuka penuh.
- Peta 05 bagian 7.2: 15 dari 18 baris tercakup; 3 sebagian (Storage nyata: unduh/unggah sah tidak terbukti; penonaktifan: merah sengaja; `update work_orders.status`: lewat API muncul 42501, kode `WO001` hanya terbukti dari sesi superuser).
- S2: **terbantahkan sebagai kebocoran** (subquery policy dievaluasi dengan RLS pemanggil; bukti: uji menunjukkan pembayaran invoice DRAFT ada di DB tetapi tidak terlihat pelanggan). Turun ke minor / pertahanan berlapis. Catatan orchestrator: verifikasi v1 hanya membaca teks policy.
- N1: valid, rendah. `customer_users_select` (`0013:351-353`) tidak memeriksa `profiles.is_active` (maupun `cu.is_active`), sementara `app.my_customer_ids()` dan `app.my_roles()` memeriksanya. Pola `user_id = auth.uid()` yang sama ada di `profiles, user_roles, notifications, user_consents, sync_operations` dan belum dinilai untuk akun nonaktif (B9).

## Sisa celah harness (yang harus ditutup)
1. **B1** RPC parametrik memakai WO milik pihak lain sebagai argumen, jadi `WO005` muncul dari cek kepemilikan walau penjagaan peran (`WO002`) hilang. Perbaiki: dummy WO milik pemanggil, tuntut `WO002`, jangan menerima `WO005` untuk RPC non-WO, tambah kontrol peran sah.
2. **B2** `it.fails` lulus pada lemparan apa pun (token kedaluwarsa, 5xx, jaringan); `expect([200,400,403]).toContain(status)` salah arah. Pisahkan pra-syarat dari bagian yang diharapkan gagal.
3. **B3** Tidak ada pembuktian bahwa view terlarang (`v_job_health`, `v_kpi_sla_monthly`, `v_finance_ready_to_bill`, `v_wh_part_requests`, `v_today_work_orders`, `v_open_part_variances`) berisi data, sehingga "0 baris" bisa vakum.
4. T12/05 baris 235: sesuaikan 05 ("42501 lewat API, WO001 lewat pemicu") atau uji jalur yang memicu `WO001`.
5. N1: perbaikan policy (migrasi) dan penilaian tabel milik-pengguna untuk akun nonaktif (B9); sesuaikan 05 bila notifikasi diizinkan.
6. S2: tambah filter status eksplisit di `payments_customer` (minor) + uji regresi.
7. Handoff harus mengungkap: `app.revision_mode='on'` berlaku untuk seluruh sisipan fixture; permintaan fixture disisipkan dengan `channel='PHONE'` dan `created_by=admin` lewat superuser; pemicu `WO001`/`IMM01` dibuktikan dari sesi `postgres`, bukan `authenticated`; 05 baris 233 dilunakkan menjadi "boleh baris sendiri" tanpa mengubah 05.
8. Tindak lanjut S3-S9 (terutama S4, S6) dan G-08/S1 ke WP berikutnya; perketat B4/B5 bila memungkinkan.

Kesimpulan reviewer: harness boleh dipakai sebagai gerbang isolasi data PELANGGAN, belum sebagai bukti penjagaan peran RPC.
