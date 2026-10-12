# Handoff WP-002b: migrasi 0016, revisi 1 setelah review independen (DISIAPKAN dan DIUJI-ROLLBACK; BELUM DITERAPKAN)

- Pelaksana: PJ migrasi database (postgres-pro). Tanggal: 2026-10-12.
- Revisi 1 menjawab `docs/orchestration/reviews/WP-002b_0016_review.md` (butir 1-10, lihat bagian "Revisi 1" di bawah; bagian lain memuat keadaan terbaru). Migrasi bukan lagi "aditif": ada `drop policy work_orders_tech`, penggantian beberapa policy, dan perubahan perilaku fungsi (header 0016 sudah dikoreksi).
- Status: **TIDAK ada commit ke database.** Seluruh uji dijalankan di dalam satu transaksi yang SELALU di-ROLLBACK (`tools/try-migration.mjs`). Penerapan menunggu persetujuan eksplisit user (decisions.md, baris "Migrasi 0016").
- Berkas ditulis: `supabase/migrations/0016_celah_api_db_dan_perbaikan_keamanan.sql` (baru), `tools/try-migration.mjs` (baru), `docs/04_database_schema.sql` (bagian "MIGRATION 0016" ditambahkan di akhir, isinya identik dengan berkas migrasi, terverifikasi byte per byte; komentar header daftar migrasi diperbarui), `docs/05_rls_and_security.md` (D29-D34 di bagian 0; baris matriks bagian 3.1/3.2/3.3; katalog bagian 4; bagian 5.2), berkas ini. Berkas 0000-0015, `tests/**`, `src/**`, `docs/01-03` tidak disentuh. Isi `.env.local` tidak dicetak (hanya host pooler).
- Nama berkas selaras dengan `tools/split-migrations.mjs`: judul penanda `celah API-DB dan perbaikan keamanan` menghasilkan nama berkas yang sama bila dokumen 04 dipecah ulang.

## Isi migrasi dan keputusan desain
| ID | Isi | Keputusan dan alasan |
|---|---|---|
| G-13 | `wo_declare_no_parts(p_wo_id, p_value, p_expected_version, p_op_id)` | Cek: `my_active_wo_ids()` (bukan pemegang: `WO005`), harus penugasan LEAD (helper: `WO002`; keputusan: pernyataan tingkat-WO yang menentukan penutupan, sama dengan `wo_transition`/`extra_cost_request`), `can_edit_wo()` (`WO001`), `p_op_id` yang sudah `APPLIED` milik pemanggil di `sync_operations` atau nilai sama = replay tanpa mengubah/menaikkan version (op lama tidak bisa membalik nilai), `WO004` bila versi basi. Tambahan yang tidak diminta: `true` ditolak `WO003 PARTS_ALREADY_RECORDED` bila sudah ada pemakaian aktif (data kontradiktif). Audit lewat `trg_audit` yang sudah ada (aktor teknisi terbukti di uji). Menulis menaikkan `work_orders.version` (tg_touch); hasil mengembalikan version baru. |
| G-04 | `wo_signatures.upload_status` (lama `UPLOADED`, baru `PENDING`); `app.wo_submit_deficiencies` menghitung hanya tanda tangan VALID + `UPLOADED` | Cara menjadi `UPLOADED`: (1) tanda tangan teknisi (`TECH_DEVICE`): klien menyisipkan lewat PostgREST (hak kolom tidak mencakup `upload_status`, jadi selalu `PENDING`), server memverifikasi objek lalu service_role menandai `UPLOADED` (05 bagian 6.3a, pola foto). (2) tanda tangan pelanggan: `wo_customer_sign` menyisipkan dan memanggil SIGNOFF dalam satu transaksi sehingga server tak sempat menandai; maka fungsi definer itu sendiri memeriksa `storage.objects` (bucket `wo-media`, path persis) dan menyisipkan dengan `UPLOADED`, atau `PENDING` (lalu guard menolak `WO003 SIGNATURE_MISSING`, transaksi batal). Perubahan perilaku `wo_customer_sign` yang tidak diminta (review no. 1): path wajib `{customer}/wo/{wo}/sig/{file}` (lebih panjang dari sub-prefix, tanpa `..`, belum terdaftar di `wo_attachments`; jika tidak `WO006`) dan objek storage harus berukuran > 0 dengan mimetype `image/png|jpeg|webp` (metadata Storage), kalau tidak tetap `PENDING`. Sub-prefix `sig/` yang sama diterapkan pada policy `wo_signatures_insert_tech`. Tanpa ini foto OTHER/FAILED_VISIT bisa lolos sebagai "tanda tangan" dan terbaca pelanggan. |
| G-05 | Tabel `wo_child_changes(wo_id pk, changed_at)` + trigger `trg_wo_child_changed` di 11 tabel anak; kolom `children_changed_at` di view `tech_work_orders` | **Saya menyimpang dari usulan kolom `work_orders.children_changed_at`**: (a) `tg_touch` menaikkan `version` dan `updated_at` pada SETIAP update baris `work_orders` (tidak bisa dihindari tanpa mengubah trigger global), yaitu persis WO004 palsu yang ingin dihindari; (b) `trg_audit` mencatat tiap perubahan; (c) `tg_wo_before_update` menolak (`IMM01`) update kolom itu pada WO final. Tabel pendamping tanpa kolom version/updated_at, tanpa audit, tanpa trigger sendiri (tidak ada rekursi). Trigger berupa constraint trigger DEFERRABLE INITIALLY DEFERRED (review no. 3): upsert dijalankan saat COMMIT sehingga kunci baris `wo_child_changes` singkat dan tidak membentuk urutan kunci dengan fungsi yang mengunci `work_orders` lebih dulu; dedupe per WO per transaksi lewat GUC lokal. Tabel anak: 8 yang diminta + `extra_cost_approvals`, `part_requests`, `service_reports` (dibaca teknisi). `changed_at` = `clock_timestamp()`. DELETE tidak ditangkap (anak memakai tombstone). Baris awal diisi `clock_timestamp()` saat migrasi (review no. 8); pull memakai `coalesce(children_changed_at, updated_at)`. RLS: staf (sama dengan `work_orders_staff`) dan teknisi (WO aktifnya). Catatan: pull berbasis timestamp tetap perlu tumpang-tindih kursor kecil (transaksi yang commit terlambat). |
| G-06 | `sync_op_record(p_op_id, p_status, p_result, p_clock_skew default null)`; kolom `sync_operations.resolved_at/by/note`; `sync_rescued_resolve(p_op_id, p_note)` | Tidak ada tabel `rescued` terpisah: draf RESCUED adalah baris `sync_operations` berstatus `RESCUED`, jadi kolom `resolved_*` ditaruh di sana (tanpa tabel baru). Hanya baris milik `auth.uid()` (lain/tak ada: `WO005`); transisi `RECEIVED` ke `APPLIED/REJECTED/RESCUED`, `REJECTED` ke `RESCUED`; status sama = replay; lainnya `WO001`; status tak dikenal atau `RECEIVED` = `WO006`. Parameter keempat opsional ditambahkan agar `clock_skew` (disebut 03 baris 594) bisa dicatat. `sync_rescued_resolve`: ADM, DSP, SPV, OWN (sama dengan yang boleh membaca), catatan wajib, hanya status `RESCUED`. `service_role` tidak diperluas. KOREKSI klaim sebelumnya: kemampuan klien menandai operasinya sendiri `APPLIED/REJECTED/RESCUED` adalah BARU (sebelumnya hanya INSERT), bukan keadaan lama; `p_result` dibatasi 64 KB. |
| G-08 | View `tech_work_orders` (security_barrier, filter `my_active_wo_ids()`, 61 kolom: semua kolom `work_orders` kecuali `estimate_total`, `estimate_version`, `billing_type`, `billing_status`, `billing_override_reason`, `warranty_exception_reason`); `drop policy work_orders_tech` | Daftar kolom eksplisit agar kolom baru tidak bocor otomatis. Kolom lain (mis. `policy_snapshot`, `created_by`) sengaja dipertahankan agar tidak mengurangi apa yang dulu terbaca teknisi; hanya harga/penagihan dicabut. Tabel tetap punya GRANT SELECT untuk `authenticated`, tetapi tanpa policy teknisi hasilnya 0 baris. |
| G-12 | `wo_closure_check(p_wo_id)` | Mengembalikan array jsonb dari `app.wo_submit_deficiencies`. Pemanggil: teknisi pemegang dan ADM/DSP/SPV/OWN; lain `WO005`. Mode `CLOSE` bila WO `UNDER_REVIEW` (pratinjau T-19 untuk SPV), selain itu `SUBMIT` dengan antrean klien = 0, jadi `SYNC_PENDING/SYNC_STATE_UNKNOWN` tidak dihasilkan server (klien menggabungkan antrean lokalnya). `sla_acknowledge`, `wo_reschedule` tidak dibuat. |
| S1 | `wo_cost_summary` | Pemanggil staf (ADM, DSP, SPV, FIN, OWN) tetap hasil penuh; pemanggil yang hanya teknisi: `{needs_approval}`. `p_wo_id` NULL, `auth.uid()` NULL, atau WO tidak ada = `WO005` seragam (sebelumnya staf dengan id acak mendapat JSON berisi null). |
| N1 | `customer_users_select` | Baris sendiri hanya bila `customer_users.is_active` dan `profiles.is_active`. Tabel milik-pengguna lain TIDAK diubah (alasan di D33 05): 05 bagian 3 menandainya R* (diri) tanpa syarat aktif dan harness menganggapnya wajar. |
| S2 | `payments_customer` | Filter `i.status in ('ISSUED','PAID')` ditambahkan. |
| S4 | `app.can_read_object` | Teknisi hanya bucket `wo-media` (tidak lagi `reports`); cabang `req` pelanggan hanya `wo-media`; bucket lain ditolak. Staf dan FINANCE tidak berubah. |
| GRANT | 4 RPC baru | `revoke all ... from public, anon, authenticated` lalu `grant execute ... to authenticated`. Fungsi `app.tg_wo_child_changed` dicabut dari semua (jika tidak, `authenticated` mendapat EXECUTE lewat default PUBLIC di schema `app` dan uji "daftar helper app persis" gagal). Tabel/view baru: `revoke all` dari anon dan authenticated, lalu `grant select` ke authenticated. |

Ditunda (tidak dikerjakan): G-02, G-03, G-07, G-09, G-10, G-11, S3, S5, S6, S7, S8, S9, `sla_acknowledge`, `wo_reschedule`.

## Dampak G-08 (hasil grep seluruh migrasi 0000-0015)
- Tidak terpengaruh (definer milik postgres, bypass RLS): `wo_transition`, `apply_wo_transition`, semua RPC `public.*` (SECURITY DEFINER), semua helper `app.*` (`my_active_wo_ids`, `tech_*_ids`, `can_edit_wo`, `wo_storage_prefix`, `can_read_object`), trigger definer, view `customer_*`, `v_tech_asset_service_history`, `v_wh_part_requests`. Bukti: `wo_transition ACCEPT` penuh oleh teknisi sukses (ASSIGNED ke ACCEPTED), WAREHOUSE tetap membaca `v_wh_part_requests` (2 baris), pelanggan tetap membaca `customer_work_orders` (6 baris).
- Terpengaruh: (1) `v_today_work_orders` (`security_invoker`) kini 0 baris bagi teknisi (terbukti 0); view itu memang untuk monitor operasional, teknisi memakai `tech_work_orders`. (2) Semua klien/API teknisi yang membaca `work_orders` langsung (mis. `/sync/pull`, doc 03 baris 535, `api_db_mapping`) harus pindah ke `tech_work_orders`. (3) Embedding PostgREST ke `work_orders` dari tabel anak oleh teknisi tidak lagi mengembalikan baris.
- Peran lain: ADM, DSP, SPV, FIN, OWN tetap melihat 12 dari 12 WO (terbukti); GDG 0 baris (sama seperti sebelumnya); pelanggan 0 baris di tabel mentah.
- Residu G-08: `extra_cost_request` tidak lagi mengembalikan `total` (revisi 1). Teknisi masih bisa MENGIRIM `unit_price` untuk item `OTHER` (itu input, bukan bocor).

## Risiko kompatibilitas
- G-08: perubahan kontrak API (lihat di atas). Aman untuk fungsi definer. Satu-satunya cara teknisi mendapat harga kini adalah RPC definer yang mengembalikan angka (tersisa: `extra_cost_request`).
- G-05: `changed_at` memakai waktu tulis; transaksi panjang yang commit belakangan bisa terlewat oleh kursor `> last_seen`. Pull harus memakai tumpang-tindih (mis. kursor dikurangi beberapa detik) atau mengambil ulang WO yang `version`-nya berbeda.
- G-04: setelah migrasi, tanda tangan yang disisipkan teknisi (`TECH_DEVICE`) tetap `PENDING` sampai server menandai `UPLOADED`. **Rute `/uploads/complete` (Next.js, service_role) harus ditambah agar menandai `wo_signatures.upload_status`, bila tidak, penutupan WO oleh teknisi dengan tanda tangan perangkat akan selalu `SIGNATURE_MISSING`.** Baris lama otomatis `UPLOADED`.
- `wo_customer_sign`: path wajib berprefix WO (`WO006` bila tidak) dan objek wajib sudah diunggah sebelum RPC dipanggil (urutan klien: unggah dulu, baru panggil RPC).
- `wo_declare_no_parts` menaikkan `version` WO; klien offline yang mengantre operasi dengan `expected_version` lama akan mendapat `WO004` (perilaku optimistic lock biasa; outbox harus memperbarui version dari respons).
- S4: teknisi tidak lagi bisa membuat signed URL untuk laporan PDF (bucket `reports`).
- Kemampuan BARU (bukan pre-existing): pemilik baris dapat menandai operasinya `APPLIED` lewat `sync_op_record` dan dengan itu melepas guard `SYNC_UNAPPLIED` untuk WO-nya (kepercayaan pada klien).
- `wo_declare_no_parts` kini LEAD saja (helper `WO002`); klien yang memakai akun helper akan ditolak.

## Revisi 1: ringkasan per butir review
1. `wo_customer_sign` dan `wo_signatures_insert_tech`: sub-prefix `sig/`, panjang path, tolak path terdaftar di `wo_attachments`, ukuran/mimetype Storage (lihat G-04).
2. N2 ditutup: `sync_operations_insert_own` kini `user_id = auth.uid()` + peran TECHNICIAN aktif + (`wo_id` NULL atau di `my_active_wo_ids()`). Dampak: (a) pelanggan tidak lagi dapat menyisipkan `sync_operations` (matriks 05 baris `sync_operations`: PLG kini hanya baca baris sendiri; PLG memang tidak punya jalur sinkron). (b) Draf RESCUED: operasi untuk WO yang sudah dilepas/ditugaskan ulang tidak lagi lolos policy bila `wo_id` diisi; rute `/sync/push` WAJIB menyisipkan op seperti itu dengan `wo_id` NULL (WO tetap ada di `payload`) lalu mencatat `RESCUED` lewat `sync_op_record`, supaya DEC-06 (tidak ada data dibuang diam-diam) tetap berlaku. (c) Baris lama tidak berubah. (d) `tests/isolation` hanya menyisipkan `sync_operations` lewat superuser (fixtures.ts ~baris 410), jadi tidak terpengaruh; `catalog.ts` hanya membaca.
3. Trigger sinyal menjadi constraint trigger deferred (+ dedupe GUC). Uji: 11 trigger bertanda DEFERRABLE INITIALLY DEFERRED; sebelum `SET CONSTRAINTS ALL IMMEDIATE` belum ada tulis ke `wo_child_changes`; sesudahnya `changed_at` maju, `version`/`updated_at` WO tidak berubah. **Uji konkurensi dua transaksi paralel TIDAK dapat dilakukan dalam kerangka rollback**: objek baru hanya ada di transaksi yang belum commit dan tidak terlihat sesi kedua. Jadi tidak ada bukti empiris bebas-deadlock; yang ada hanya argumen desain (kunci diambil saat commit, satu upsert per WO per transaksi). Disarankan uji dua sesi pada database uji setelah penerapan.
4. `extra_cost_request` dibuat ulang tanpa kunci `total` pada nilai kembalian (satu-satunya perubahan; notifikasi pelanggan dan tabel tetap memuat total). Terbukti: kunci kembalian `status, version, approval_id, content_hash, approval_version`. Residu G-08 tertutup.
5. `wo_cost_summary`: `p_wo_id` NULL dan WO tak ada = `WO005` (terbukti).
6. `wo_declare_no_parts`: LEAD saja dan `p_op_id` dipakai (lihat G-13; terbukti op APPLIED = replay, nilai tidak dibalik).
7. Klaim `sync_op_record` dikoreksi (G-06 dan D32); `p_result` maks 64 KB (diperiksa di kode; batas tidak diuji dengan payload besar).
8. Backfill `clock_timestamp()`.
9. `set local lock_timeout = '5s'` di awal 0016 (DDL memegang kunci sampai commit; terapkan di jam sepi).
10. Header 0016 dikoreksi.

## Pengujian
Perintah: `node tools/try-migration.mjs` (membaca `DATABASE_URL` dari `.env.local`). Hasil terakhir (database Supabase nyata, host `aws-0-ap-southeast-2.pooler.supabase.com`): **145 pemeriksaan OK, 0 GAGAL, exit code 0** (revisi 1; sebelum revisi 128); ROLLBACK dijalankan. Migrasi dijalankan dua kali berturut-turut dalam transaksi (idempoten) tanpa galat.

Sebelum vs sesudah (keluaran nyata):
```
INFO  G-08 lama: teknisi SELECT work_orders -> {"n":5,"has_est":true}
INFO  S1 lama: kunci wo_cost_summary untuk teknisi -> estimate_total,needs_approval,projected_total,tolerance
INFO  S4 lama: teknisi can_read_object(reports, laporan WO-nya) -> true
INFO  N1 lama: akun nonaktif membaca customer_users -> 1 baris
OK     teknisi SELECT work_orders langsung = 0 baris (sebelumnya >0) -> sebelum={"n":5,"has_est":true} sesudah={"n":0}
OK     teknisi hanya menerima {needs_approval} -> {"needs_approval":false}
OK     teknisi TIDAK lagi membaca bucket reports (sebelumnya true)
OK     akun nonaktif: customer_users 0 baris (sebelumnya 1) -> 0
OK     app.tables_without_rls() kosong -> []
OK     semua fungsi SECURITY DEFINER di public/app ber-search_path="" -> []
OK     tidak ada fungsi public/app yang bisa dieksekusi anon/PUBLIC -> []
OK     schema app: authenticated hanya mendapat daftar helper lama (persis) -> []
OK     work_orders.version dan updated_at TIDAK berubah -> v1->v1
OK     tidak ada audit_logs baru untuk work_orders (tidak berisik) -> 1->1
OK     pelanggan tidak dapat menyisipkan sync_operations (42501) -> 42501
OK     teknisi yang tidak memegang WO tidak dapat menyisipkan op untuk WO itu (42501) -> 42501
OK     teknisi menyisipkan op dengan wo_id NULL (jalur draf WO yang sudah dilepas)
OK       semuanya constraint trigger DEFERRABLE INITIALLY DEFERRED (kunci saat commit) -> 11
OK     extra_cost_request: nilai kembalian teknisi tanpa kunci 'total' -> ["status","version","approval_id","content_hash","approval_version"]
== BUKTI SETELAH ROLLBACK (sambungan baru) ==
OK     fungsi RPC baru tidak ada -> 0
OK     kolom baru tidak ada -> 0
OK     view tech_work_orders dan tabel wo_child_changes tidak ada -> 0
OK     fungsi app.tg_wo_child_changed tidak ada
OK     policy work_orders_tech masih ada (belum dicabut)
OK     app.wo_submit_deficiencies masih versi lama (tanpa upload_status tanda tangan)
OK     supabase_migrations tidak mencatat 0016 -> 0
RINGKASAN: SEMUA PEMERIKSAAN LULUS (migrasi sempat dijalankan lalu di-ROLLBACK)
```

Yang diuji (semua di transaksi rollback, data fixture WP-007 yang sudah ada di DB):
- Struktur: 4 RPC baru ada, SECURITY DEFINER, `search_path=""`, anon/PUBLIC tidak bisa execute, authenticated bisa; kolom baru; tabel dan view baru; 11 trigger; policy S2/N1; `tables_without_rls()` kosong; tidak ada fungsi public/app executable oleh anon/PUBLIC; daftar helper `app` untuk authenticated tidak berubah; anon tanpa hak pada relasi public mana pun.
- G-08/S1: teknisi 0 baris di `work_orders`, 5 baris di `tech_work_orders` tanpa kolom harga, teknisi lain tidak melihat; ADM/DSP/SPV/FIN/OWN tetap 12/12, GDG 0; pelanggan tetap lancar; `wo_transition` ACCEPT penuh sukses; `wo_cost_summary` teknisi vs ADM.
- G-13: WO005 untuk teknisi lain, pelanggan, ADM; WO001 pada status tak dapat diisi; WO003 saat sudah ada pemakaian; jalur sukses (pemakaian di-tombstone sementara dalam transaksi): tulis, version naik, audit beraktor teknisi, replay, WO004 versi basi, `PARTS_NOT_DECLARED` hilang dari `wo_closure_check`.
- G-12: hasil sama dengan fungsi guard; ADM/DSP/SPV/OWN berhasil; teknisi lain, pelanggan, FIN, GDG, id acak = WO005.
- G-04: baris baru `PENDING`, `SIGNATURE_MISSING` muncul lalu hilang setelah `UPLOADED`; klien tidak bisa mengisi/mengubah `upload_status` (42501); `wo_customer_sign`: path liar dan `..` = WO006, objek belum ada = WO003 memuat `SIGNATURE_MISSING`, objek ada (baris `storage.objects` sementara) = `SIGNATURE_MISSING` hilang.
- G-05: perubahan anak memajukan `changed_at`, `work_orders.version`/`updated_at` tidak berubah, tidak ada baris audit baru, RLS sinyal (teknisi 5 baris, pelanggan 0), authenticated tidak bisa menulis.
- G-06: seluruh jalur status, replay, penolakan, penyelesaian draf, tidak ada UPDATE langsung.
- S4, N1, S2 (teks policy), sanity keamanan.

**TIDAK diuji / batasan jujur:**
- `wo_customer_sign` sukses sampai CLOSED/UNDER_REVIEW tidak teruji: WO fixture tidak memenuhi syarat lain (check-in, temuan, biaya PENDING), jadi yang terbukti hanya "`SIGNATURE_MISSING` tidak muncul bila objek ada". Verifikasi `storage.objects` memakai baris metadata yang disisipkan, bukan unggahan nyata.
- Penandaan `UPLOADED` oleh service_role (jalur tanda tangan teknisi) tidak diuji dengan peran `service_role` nyata (disimulasikan UPDATE sebagai postgres).
- Konkurensi/deadlock dan beban trigger sinyal: TIDAK diuji (tidak mungkin dalam kerangka rollback, lihat Revisi 1 no. 3). Pull nyata dengan kursor tidak diuji.
- Hak `service_role` pada tabel baru (default privilege Supabase) tidak diperiksa.
- Uji PostgREST/HTTP nyata tidak dijalankan; peran ditiru dengan `set local role authenticated` + klaim JWT (sama dengan `asRole` di harness). Penolakan lewat API (kode HTTP 401/403/404) belum dibuktikan.
- N1 hanya untuk `customer_users`; tabel milik-pengguna lain tidak diubah (keputusan, bukan lupa).
- Jalur `sync_op_record` dari `/sync/push` nyata belum ada; yang diuji hanya RPC-nya.

## Daftar uji `tests/isolation/**` yang perlu diubah SETELAH migrasi diterapkan (tidak saya ubah)
1. `isolation.test.ts` (sekitar baris 984-1020): uji "[celah diketahui G-08] KONTROL" (teknisi membaca `estimate_total`) akan gagal; `it.fails` G-08 dan S1 akan GAGAL karena perilaku benar kini tercapai. Ganti jadi `it` biasa terhadap `tech_work_orders` (tanpa `estimate_*`/`billing_*`) dan `wo_cost_summary` (kunci tepat `needs_approval`), hapus uji "KONTROL" S1.
2. `isolation.test.ts` (sekitar baris 876-904, 915-935 dan uji `it.each` teknisi lain yang memakai `work_orders` sebagai teknisi): `fetchAll(T1, "work_orders", "id")`, `rest(T1/T2, work_orders?...)`, serta cek "teknisi baru" pada `work_orders` kini 0 baris; pindahkan ke `tech_work_orders` (`id`) dan tambahkan tegas bahwa `work_orders` bagi teknisi = 0 baris.
3. `isolation.test.ts` (sekitar baris 1257-1266): uji `[temuan N1]` akan lulus (hapus penanda sengaja-merah). Uji penonaktifan (baris 1245) boleh dibuat mencakup `customer_users`.
4. `storage-struktur.test.ts` baris 157: `expect((await list(F.ids.tek1, F.custA)).length).toBe(7)` menjadi 6 (objek di bucket `reports` tak lagi terbaca teknisi); tambahkan kasus negatif teknisi + bucket `reports`.
5. `catalog.ts`: `RPC_ALLOWED` tambah `wo_declare_no_parts`, `wo_closure_check`, `sync_op_record` (roles `["TECHNICIAN"]` beserta alasan); `sync_rescued_resolve` tidak boleh untuk pelanggan/teknisi (tidak perlu entri); `wo_cost_summary` alasan "hanya needs_approval" diperbarui. `ALLOWED_TABLES`/allow-list kolom view: tambah `wo_child_changes` (pemilik: teknisi WO aktif, staf) dan `tech_work_orders` (allow-list kolom, tanpa harga); sesuaikan `MUST_BE_FORBIDDEN` bagi pelanggan bila mencantumkan relasi baru.
6. `fixtures.ts` baris 324: sisipan `wo_signatures` akan berstatus `PENDING`; tambahkan `upload_status = 'UPLOADED'` agar WO fixture yang menguji guard penutupan tetap memenuhi syarat tanda tangan. Path fixture tanda tangan tidak lagi memenuhi sub-prefix `sig/` untuk jalur policy tulis (fixture memakai superuser sehingga tidak terpengaruh), tetapi `wo_customer_sign` di uji (isolation.test.ts ~761-775) memakai path sendiri: periksa bahwa hanya mencapai `WO001`.
7. Uji RPC parametrik (`storage-struktur.test.ts` ~baris 368-393): 4 RPC baru otomatis ikut; pemeriksaan `WO002/WO005/42501` untuk pelanggan/teknisi lulus (terbukti di uji-rollback untuk argumen dummy), kecuali `RPC_ALLOWED` belum diperbarui (butir 5).
8. Tambah uji baru: `wo_declare_no_parts` (LEAD vs helper), `wo_closure_check`, `sync_op_record`, `sync_rescued_resolve`, S4 (teknisi/reports), S2, N2 (pelanggan/teknisi lain ditolak, `wo_id` NULL diizinkan), `extra_cost_request` tanpa `total`, `wo_cost_summary(NULL)`, sub-prefix `sig/`, dan `wo_child_changes` (tidak menaikkan `version`).
9. Uji isolasi yang memakai `RPC_ALLOWED`: `wo_declare_no_parts` kini `WO002` bagi helper dan `WO005` bagi bukan pemegang; keduanya dalam daftar kode tolak yang diterima uji RPC parametrik.

## Langkah sebelum penerapan (butuh persetujuan user)
1. Setujui 0016 (dan keputusan: tabel vs kolom G-05, `PARTS_ALREADY_RECORDED`, LEAD saja pada `wo_declare_no_parts`, aturan path `sig/`, pembatasan insert `sync_operations`).
2. Terapkan dengan `node tools/apply-migrations.mjs` (satu transaksi; mencatat versi `0016` di `supabase_migrations.schema_migrations`).
3. Jalankan ulang `npm run test:isolation` setelah memperbarui uji sesuai daftar di atas; perbarui rute `/uploads/complete` (tanda tangan), `/sync/push` (op untuk WO terlepas: `wo_id` NULL lalu `RESCUED`) dan `/sync/pull` (pakai `tech_work_orders`, `wo_child_changes`, kursor tumpang-tindih, `coalesce(children_changed_at, updated_at)`).
4. Uji konkurensi dua sesi (tulis anak WO yang sama + `wo_transition`) pada database uji setelah penerapan.
