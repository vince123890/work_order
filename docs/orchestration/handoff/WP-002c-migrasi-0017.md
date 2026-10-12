# Handoff WP-002c: migrasi 0017, perbaikan deadlock N3 (DISIAPKAN dan DIUJI; BELUM DITERAPKAN)

- Pelaksana: PJ migrasi database (postgres-pro). Tanggal: 2026-10-12.
- Status: **tidak ada perubahan yang di-commit ke schema public atau schema aplikasi lain.** Penerapan 0017 menunggu persetujuan eksplisit user. Satu-satunya yang di-commit adalah schema sementara `n3_scratch` (dibuat lalu di-DROP CASCADE oleh skrip uji; hilangnya dibuktikan dengan sambungan baru).
- Berkas: `supabase/migrations/0017_sinyal_perubahan_anak_wo_tanpa_deadlock.sql` (baru), `tools/try-migration-0017.mjs` (baru), `docs/04_database_schema.sql` (header daftar + bagian "MIGRATION 0017" di akhir, identik byte-demi-byte dengan berkas migrasi; diperiksa programatis), `docs/05_rls_and_security.md` (baris D30 dan tabel akses `wo_child_changes` diubah, D35 baru). Tidak menyentuh tests/**, src/**, 0000-0016.

## Masalah N3
Trigger deferred `app.tg_wo_child_changed` (0016) meng-upsert satu baris per WO (`on conflict (wo_id) do update`) saat COMMIT. Dua transaksi yang menyentuh WO A dan B dalam urutan terbalik saling menunggu baris/indeks unik `wo_id` lalu deadlock 40P01; korban kehilangan seluruh transaksi bisnis.

## Desain 0017 dan alasan
- `wo_child_changes` menjadi **append-only**: PK `wo_id` dilepas (`wo_id` tetap NOT NULL), trigger hanya `INSERT` murni. Insert ke btree non-unik tidak menunggu transaksi lain, jadi tidak ada siklus tunggu, untuk WO sama maupun beda (kriteria 1). Dedupe per WO per transaksi lewat GUC dipertahankan.
- Indeks baru `(wo_id, changed_at desc)`; indeks kursor 0016 `(changed_at, wo_id)` dipertahankan.
- View `tech_work_orders`: `children_changed_at = (select max(changed_at) ...)` per WO; 61 kolom, urutan dan tipe identik (terbukti), security_barrier dan hak tidak berubah (kriteria 2). `work_orders.version/updated_at` tidak naik (terbukti, kriteria 3).
- Pertumbuhan: `app.compact_wo_child_changes(p_min_age default '10 minutes', p_batch default 20000)` menghapus baris yang bukan terbaru per WO dan lebih tua dari p_min_age. Trigger tidak pernah mengunci baris lama, jadi DELETE tidak membentuk urutan kunci dengan transaksi bisnis; antar pemadat dijaga advisory lock (try, panggilan kedua langsung keluar). SECURITY DEFINER, `search_path=''`, EXECUTE dicabut dari public/anon/authenticated. Dijadwalkan pg_cron `vasta_compact_wo_child_changes` tiap 10 menit (bila pg_cron aktif; bila tidak, NOTICE) dan menulis heartbeat ke `job_runs` (galat pemadatan dicatat ERROR). Autovacuum tabel diperketat (scale factor 0.05).
- Backfill: tidak perlu; 18 baris hasil 0016 tetap ada sebagai baris terbaru (hash isi identik sebelum/sesudah). Idempoten (dijalankan dua kali tanpa galat dan tanpa mengubah isi). RLS dan GRANT tabel tidak berubah (dinyatakan ulang).
- Kriteria 4 (interpretasi): trigger TANPA exception handler. Insert murni tanpa kunci bersama tidak punya mode gagal selain kerusakan fatal (disk penuh); menelan galat itu berarti sinyal hilang diam-diam, jadi dipilih membatalkan transaksi. Ini menyimpang dari kalimat "kegagalan sinyal tidak boleh membatalkan transaksi bisnis" untuk kasus fatal tersebut; deadlock/penantian, penyebab nyata N3, sudah mustahil dari trigger ini.
- Trade-off: baris duplikat sementara per WO (maks sekitar 10 menit penulisan + satu baris terbaru); pembacaan langsung tabel harus `max()`/`group by wo_id`; pull bisa mengambil lebih sering dari perlu, tidak pernah kurang. Alternatif ditolak: kunci advisory/urutan deterministik (masih ada kunci bersama), exception handler (menelan sinyal), kolom di `work_orders` (menaikkan version, diaudit, IMM01).

## Apa yang diuji (hasil nyata `node tools/try-migration-0017.mjs --rounds=40`, semua lulus, 0 GAGAL)
Fase A (database nyata, satu transaksi, SELALU ROLLBACK, 0016 terpasang): 0017 berjalan; tidak ada PK/unik; indeks ada; view kolom identik + `children_changed_at` + security_barrier + hak; RLS aktif, 2 policy, hak tabel (authenticated hanya SELECT); `app.tables_without_rls()` kosong; kedua fungsi SECURITY DEFINER dengan `search_path=""` dan tanpa EXECUTE anon/authenticated/PUBLIC; semua definer di public/app ber-search_path terkunci; 11 constraint trigger tetap; backfill utuh (hash); job pg_cron terdaftar; idempoten; perubahan anak pada WO nyata menambah tepat 1 baris, dedupe per transaksi, version/updated_at WO tidak naik; pemadatan (masa tenggang, satu baris per WO, max tetap, heartbeat, idempoten).
Fase B (schema sementara `n3_scratch`, dua koneksi pg, WO terbalik, commit bersamaan, 40 putaran per skenario; fungsi trigger 0017 dan pemadat diambil dari berkas migrasi, hanya nama tabel dipetakan):
| Skenario | Putaran deadlock 40P01 | Galat lain |
|---|---|---|
| KONTROL 0016 (upsert), tanpa sleep | 19 dari 40 | 0 |
| KONTROL 0016, jendela +50 ms | 40 dari 40 | 0 |
| 0017 (insert murni), tanpa sleep | **0 dari 40** | 0 |
| 0017, jendela +50 ms | **0 dari 40** | 0 |
Pada 0017 setiap transaksi yang commit meninggalkan tepat satu baris sinyal per WO (tidak ada sinyal hilang). Stres pemadatan: 2 penulis x 40 transaksi berurutan terbalik + 2 pemadat bersamaan (min_age 0): 0 galat/deadlock, 560 pemadatan (366 baris dihapus), `max(changed_at)` per WO tidak pernah di bawah waktu commit terakhir. Kontrol negatif sahih (0016 deadlock). Fase C: setelah ROLLBACK dan DROP SCHEMA, sambungan baru membuktikan objek 0017 tidak ada (fungsi, indeks, job cron, PK 0016 masih ada, trigger masih memakai on conflict, view versi 0016, isi tabel identik) dan `n3_scratch` tidak ada.
Catatan: `sleep` hanya pemerlebar jendela balapan pada salinan scratch, bukan pada fungsi produksi.

## Yang TIDAK diuji
- `npm run test:isolasi` (tests/isolation) tidak dijalankan terhadap 0017 (tidak boleh ada commit ke public). Uji D1-D3 pada database nyata baru dapat dibuktikan setelah penerapan; bukti 0017 saat ini ada di scratch.
- Eksekusi nyata job pg_cron (hanya pendaftarannya; fungsi dipanggil langsung). Konkurensi pemadat pada tabel produksi (hanya pada salinan scratch). Beban/ukuran besar. Perilaku PostgREST/RLS teknisi atas view baru lewat JWT (hak dan definisi diperiksa, bukan baca via peran authenticated).
- Celah lama yang tidak diubah: `changed_at` diambil saat fase COMMIT sebelum commit terlihat; pull dengan kursor harus memberi tumpang tindih/jaminan (bukan lingkup N3).

## Pengaruh
- Klien `/sync/pull`: baca `children_changed_at` dari `tech_work_orders` (tanpa perubahan kontrak). Bila membaca `wo_child_changes` langsung: harus `max(changed_at) group by wo_id` karena baris ganda sementara; jangan mengandalkan satu baris per WO. Retry 40P01 pada rute tetap disarankan sebagai sabuk pengaman tetapi tidak lagi diperlukan untuk trigger ini.
- tests/isolation setelah penerapan (tidak saya ubah): `migrasi-0016.test.ts` D3 menyisipkan dengan `on conflict (wo_id) do nothing` -> galat 42P10 (tidak ada constraint unik) dan perlu diganti; uji G-05 membaca `select changed_at ... rows[0]` tanpa urutan dan `expect(s).toHaveLength(1)` pada sinyal per WO akan gagal setelah ada baris kedua (butuh `order by changed_at desc limit 1` / `max`); D2 yang merah karena N3 diharapkan hijau tanpa ubah uji. Penyesuaian uji harus dikerjakan WP uji terpisah.
- Perlu persetujuan user untuk menerapkan 0017 (`tools/apply-migrations.mjs`). Disarankan menerapkan di jendela sepi: `drop constraint` PK mengambil kunci tabel singkat.
