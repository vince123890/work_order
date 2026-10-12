# RLS dan Keamanan Data: VASTA (Field Service & Work Order)

Versi 0.1 (draf) | 2026-10-11 | Pasangan skema: `04_database_schema.sql` | Sumber: `01_PRD.md`, `02_business_analysis_technical_logic.md`

Penanda: **[S]** dari dokumen sumber/02, **[A]** asumsi atau keputusan desain skema ini, **[P]** parameter konfigurasi (nilai diisi bisnis, bukan angka tetap di kode).

---

## 0. Catatan Keputusan: Asumsi dan Deviasi dari Dokumen 02

Semua butir di bawah adalah keputusan sementara yang bisa dibalik. Kolom "Reversibilitas" menunjukkan biaya mengubahnya.

| No | Butir di 02 | Yang dilakukan di skema | Alasan | Reversibilitas |
|---|---|---|---|---|
| D01 | `user_roles` masuk JWT claim lewat Auth Hook (FR-001) | RLS membaca peran dari tabel (`app.my_roles()`, SECURITY DEFINER, STABLE). Auth Hook boleh tetap dipasang, tetapi hanya sebagai petunjuk UI, tidak dipakai otorisasi | FR-007: penonaktifan harus berlaku seketika. Claim JWT basi sampai token diperbarui. Biayanya satu lookup per statement (di-cache lewat initplan, lihat bagian 8) | Mudah |
| D02 | `profiles.customer_id` | Dihapus. Keanggotaan pelanggan hanya di `customer_users` (N:M), peran pelanggan `ADMIN`/`MEMBER` di sana | RK-10: RLS berbasis keanggotaan dibuat sekali, tidak dimigrasi saat multi-pengguna (Lapis 3) | Sedang |
| D03 | Enum 8 peran, `CUSTOMER` | `CUSTOMER` memakai enum yang sama dan eksklusif terhadap peran staf (trigger). Bila nanti hanya 7 peran (OQ-01), cukup beri satu orang dua peran: `user_roles` mengizinkan banyak peran per pengguna | Menyederhanakan cek `has_any_role` | Mudah |
| D04 | Persetujuan data pribadi `customers.consent_*` | Tabel `user_consents` (append-only, per pengguna, versi kebijakan, waktu, IP) | Persetujuan diberikan orang, bukan perusahaan (NFR-D2) | Mudah |
| D05 | Idempotensi PM cukup `UNIQUE (contract_asset_id, pm_period_key)` di `work_orders` | Constraint itu tetap ada **dan** ditambah tabel `pm_periods` unik per (contract_asset, tanggal jatuh tempo). Generator menyisipkan periode lebih dulu | BR-025 butuh periode MISSED tanpa WO; BR-024 butuh tempat status periode. Dua lapis constraint = aman untuk job ganda/dua instans (diuji paralel) | Sedang |
| D06 | `sla_state` satu kolom | Dua kolom `response_sla_state` dan `resolution_sla_state` (enum `sla_state`). `sla_events` unik pada `(wo, kind, level, target)` (ada kolom `target` = peran penerima), bukan `(wo, kind, level)` | Respons dan penyelesaian bisa berbeda status. Satu level eskalasi boleh punya beberapa penerima peran | Mudah |
| D07 | `work_orders.contract_asset_id` untuk semua kontrak | Ditambah `contract_id`. `contract_asset_id` + `pm_period_key` hanya untuk WO preventif | WO korektif yang `COVERED_CONTRACT` perlu kontrak untuk kebijakan SLA dan profit kontrak (FR-104), tanpa mengganggu unique PM | Mudah |
| D08 | T-12, T-13, T-14 digambarkan sebagai tiga transisi yang dipilih pelaku | Keputusan pelanggan hanya lewat RPC `extra_cost_decide` (cek versi + `content_hash`, bukti bila atas nama pelanggan). `wo_transition` untuk T-12/T-13/T-15 menolak bila keputusan belum tercatat. Penolakan dengan `continue_original_scope = false` menahan WO di `AWAITING_CUSTOMER_APPROVAL` sampai teknisi menjalankan T-14 | Menutup ambiguitas 02 (T-13 vs T-14 sama-sama berawal di status itu) dan mencegah persetujuan tanpa jejak | Sedang |
| D09 | T-25: pelanggan atau ADM membuat WO rework | Pelanggan hanya membuat baris `complaints`; `wo_create_rework` dipanggil ADM/Supervisor. WO induk tidak dibuka (sesuai 02) | Mencegah pelanggan membuat WO (BR-072); selaras matriks (ADM U tindak lanjut) | Mudah |
| D10 | T-22 pelanggan batal "sebelum EN_ROUTE lewat permintaan" | Batal langsung oleh pelanggan hanya dari `NEW` (`CANCEL_BY_CUSTOMER`). Setelah itu pelanggan memanggil `wo_request_cancel` (hanya mencatat), keputusan ADM/DSP (DEC-04) | Teknisi sudah ditugaskan = ada komitmen sumber daya | Mudah |
| D11 | T-27 (kunjungan gagal) belum ada di tabel 4.4 | Dimasukkan sebagai aksi `VISIT_FAILED` dari `EN_ROUTE`/`IN_PROGRESS` ke `NEW`; wajib alasan dan satu foto `FAILED_VISIT` | RK-12, 4.5 | Mudah |
| D12 | Tanda tangan terikat "hash snapshot" | Hash dihitung server (`app.wo_content_hash`) dari temuan, tindakan, rekomendasi, pemakaian suku cadang, jasa, dan biaya tambahan disetujui. Checklist dan `internal_note` tidak ikut. Klien tidak bisa menyuplai hash | OQ-18 belum diputuskan; definisi "bermakna" ada di satu fungsi sehingga mudah diubah | Mudah |
| D13 | Titik mulai jam SLA (T-01 vs SP-01) | Setting `sla.clock_starts_at` = `WO_CREATED` (default, mengikuti T-01) atau `REQUEST_RECEIVED` (usulan SP-01) | Keputusan bisnis belum ada (OQ-06/OQ-11) | Mudah |
| D14 | BR-013 respons terpenuhi; OQ-11 penyelesaian | Per kebijakan: `sla_policies.response_met_event` (default kolom `CHECK_IN`) dan `resolution_met_event` (default `SUBMIT`), `pause_on_hold_parts` (default `false`) | Default kolom adalah usulan 02 untuk demo, bukan fakta bisnis. Tidak ada angka menit/persen di seed | Mudah |
| D15 | Nomor dokumen dari sequence atau counter | Counter `document_counters` (prefix + tahun) dengan lock baris lewat `ON CONFLICT DO UPDATE` | Tidak ada lubang nomor saat transaksi rollback; format `WO-YYYY-nnnnnn` (lebar 6 hanya format tampilan) | Mudah |
| D16 | AP-2: teknisi tidak melihat harga | Tabel `wo_labor_lines`, `wo_part_usages`, `items`, `extra_cost_approvals(+items)` tertutup bagi teknisi. Mereka membaca lewat view `tech_wo_labor_lines`, `tech_wo_part_usages`, `v_items_catalog`, `tech_extra_cost_approvals` (tanpa harga/total). Harga snapshot diisi trigger. Harga item biaya tambahan diambil dari master (kecuali jenis `OTHER`) | Kolom tidak bisa disembunyikan per peran pada satu role Postgres (`authenticated`) | Sedang. Konsekuensi: INSERT oleh teknisi harus memakai `Prefer: return=minimal` (tanpa `RETURNING`/`.select()`) |
| D17 | Pelanggan membaca WO "lewat view/RPC" | Pelanggan tidak punya policy apa pun pada `work_orders` dan tabel `wo_*`. View `customer_*` (SECURITY DEFINER + `security_barrier`) menyaring `customer_id` dan hanya mengekspos kolom aman + status terpetakan | AP-3 | Sulit diubah (kontrak API) |
| D18 | Path Storage `{customer_id}/{wo_id}/{uuid}.jpg` (NFR-S5) | `{customer_id}/req/{request_id}/{file}` untuk foto pesanan dan `{customer_id}/wo/{wo_id}/{file}` untuk foto kerja, tanda tangan, dan laporan | Permintaan belum punya WO saat foto diunggah | Sedang |
| D19 | Teknisi mengunggah langsung ke Storage | Tidak ada policy INSERT/UPDATE/DELETE di `storage.objects`. Unggahan lewat signed upload URL yang dibuat server; server memverifikasi magic bytes/ukuran lalu mengubah `upload_status` menjadi `UPLOADED` (service role). Klien tidak dapat mengubah `upload_status` (hak kolom dicabut) | BR-040(2) mensyaratkan foto benar-benar terunggah; NFR-S7 validasi sisi server | Mudah |
| D20 | Peringatan lunak penugasan (FR-043) | Berlaku di Lapis 1 juga. Bila ada peringatan (`SKILL_MISMATCH`, `SCHEDULE_OVERLAP`) penugasan ditolak kecuali `override_reason` diisi, dan override tercatat | "Lunak, dapat di-override dengan alasan" | Mudah |
| D21 | Konfigurasi SLA/kalender: Owner atau Admin (OQ-12) | Hanya `OWNER` yang bisa menulis. Ganti ke `{ADMIN_CS,OWNER}` di loop policy 0013 bila diputuskan lain | Mengikuti baris matriks 02 yang menyebut Owner lebih dulu | Mudah |
| D22 | Matriks: ADM mengelola peran staf | `user_roles` hanya ditulis lewat RPC `admin_set_user_roles` (ADM atau OWNER). Mengubah peran `OWNER`/`ADMIN_CS` hanya boleh oleh `OWNER` | Mencegah ADM menaikkan hak sendiri (privilege escalation). Peran pertama (OWNER) di-bootstrap lewat service role/SQL | Mudah |
| D23 | Pemakaian suku cadang `used = SUM(CONSUME_ON_WO)` | `used` dihitung dari `wo_part_usages` aktif (bukan tombstone). Koreksi pemakaian = tombstone + mutasi `ADJUSTMENT` (ref `USAGE_REVERSAL`). Barang `BULK` tidak dilacak per WO (SP-04e) | Ledger append-only tetap utuh | Mudah |
| D24 | Skala penilaian, mata uang, PPN | Skor 1 sampai 5 (CHECK), satu mata uang implisit, PPN di luar cakupan (AS-14) | Perlu keputusan bisnis; kolom `tax` ada di `invoices` | Mudah |
| D25 | Daftar prioritas | Seed contoh `LOW, NORMAL, HIGH, CRITICAL` (tanpa durasi). Isi kebijakan SLA kosong sampai bisnis memutuskan; WO tanpa kebijakan ber-status `NOT_TRACKED` | OQ-06 | Mudah |
| D26 | Zona waktu | Default `Asia/Jakarta` di `business_calendars.timezone` dan setting `default_timezone`; jadwal pg_cron dalam UTC | BR-011/BR-028 | Mudah |
| D27 | Logika `/api/sync` | Skema hanya menyediakan `sync_operations` (idempotensi `op_id`, status `RESCUED` untuk draf yang diselamatkan) dan penolakan data lapangan pada WO final (`IMM01`). Penerapan operasi ada di lapisan API | 02 bagian 6 adalah rancangan aplikasi | n/a |
| D28 | Teknisi pembantu (helper) | `wo_add_helper` langsung membuat penugasan `HELPER` berstatus `ACCEPTED` | FR-044; konfirmasi helper dianggap tidak perlu | Mudah |
| D29 | (migrasi 0016, G-08, S1) AP-2: teknisi tidak melihat harga, juga di `work_orders` | Policy `work_orders_tech` dicabut; teknisi membaca WO aktifnya lewat view `tech_work_orders` (semua kolom kecuali `estimate_*`, `billing_*`, `warranty_exception_reason`; `security_barrier`; filter `my_active_wo_ids()`). `wo_cost_summary` untuk pemanggil yang hanya teknisi hanya mengembalikan `{needs_approval}`. Fungsi/view definer tidak terpengaruh; `v_today_work_orders` (security_invoker) kosong bagi teknisi | Satu role Postgres (`authenticated`) tidak bisa menyembunyikan kolom per peran (sama dengan D16). `extra_cost_request` tidak lagi mengembalikan `total` ke teknisi; `wo_cost_summary` memberi `WO005` bila `p_wo_id` NULL atau WO tidak ada | Sedang. Klien teknisi harus membaca `tech_work_orders`, bukan `work_orders` (kontrak API) |
| D30 | (0016, G-05) Sinyal perubahan untuk `/sync/pull` | Tabel `wo_child_changes` (satu baris per WO: `wo_id`, `changed_at`) diisi constraint trigger DEFERRABLE INITIALLY DEFERRED (upsert saat COMMIT, kunci singkat, satu kali per WO per transaksi) pada 11 tabel anak WO (checklist, temuan, lampiran, tanda tangan, jasa, pemakaian, penugasan, kunjungan, persetujuan biaya, permintaan suku cadang, laporan). Tidak ada kolom baru di `work_orders` | Kolom di `work_orders` akan menaikkan `version`/`updated_at` lewat `tg_touch` (WO004 palsu), ikut diaudit, dan ditolak `IMM01` pada WO final. DELETE tidak ditangkap (anak WO memakai tombstone) | Mudah. Konkurensi belum diuji (lihat handoff) |
| D31 | (0016, G-04) `wo_signatures` tanpa `upload_status` | Kolom `upload_status` (baris lama `UPLOADED`, baru `PENDING`); klien tidak punya hak kolom ini. `UPLOADED` hanya oleh service_role (tanda tangan teknisi, pola foto D19) atau oleh `wo_customer_sign` yang memverifikasi objek di `storage.objects` dan path berprefix WO. Path tanda tangan wajib `{customer}/wo/{wo}/sig/{file}` (policy `wo_signatures_insert_tech` dan `wo_customer_sign`), tidak boleh terdaftar di `wo_attachments`; objek harus berukuran > 0 dan mimetype gambar. Guard penutupan (`SIGNATURE_MISSING`) hanya menghitung tanda tangan `VALID` + `UPLOADED` | BR-040 butir 4 harus memeriksa gambar benar-benar ada | Mudah |
| D32 | (0016, G-06) Status operasi sinkron oleh service_role | Daftar service_role (bagian 6.3) TIDAK diperluas. RPC `sync_op_record` mengubah status/hasil hanya baris milik `auth.uid()` dengan transisi valid; draf `RESCUED` = baris `sync_operations` berstatus `RESCUED` (tidak ada tabel terpisah) dengan kolom `resolved_at/by/note` diisi RPC `sync_rescued_resolve` (ADM, DSP, SPV, OWN) | Keputusan user 2026-10-12 (decisions.md). KEMAMPUAN BARU (bukan keadaan lama): pemilik baris kini dapat menandai operasinya sendiri `APPLIED/REJECTED/RESCUED` (kepercayaan pada klien; `result` maks 64 KB); `APPLIED` pada baris RECEIVED milik sendiri melepas guard `SYNC_UNAPPLIED` WO-nya. Penyisipan `sync_operations` dibatasi: hanya TECHNICIAN aktif, `wo_id` NULL atau WO aktifnya (N2). Operasi untuk WO yang sudah dilepas disisipkan dengan `wo_id` NULL lalu dicatat `RESCUED`, sehingga draf tidak hilang | Mudah |
| D33 | (0016, N1) Akun nonaktif membaca baris sendiri | Hanya `customer_users_select` yang diperketat (`profiles.is_active` dan `customer_users.is_active`). `profiles`, `user_roles`, `user_consents`, `notifications`, `sync_operations` sengaja tetap dapat dibaca pemiliknya (matriks bagian 3: R\* diri; hak atas data sendiri; tidak memuat data pelanggan lain) | Menjaga perilaku yang diuji harness (`own.kind = user`) | Mudah |
| D34 | (0016, S2, S4) Pertahanan berlapis | `payments_customer` memfilter `invoices.status in ('ISSUED','PAID')` secara eksplisit. `can_read_object`: teknisi hanya bucket `wo-media`; cabang `req` (teknisi dan pelanggan) hanya `wo-media` | Temuan review WP-007 | Mudah |

**Belum diimplementasikan (ditandai TODO di SQL):** invoice terbit/ekspor CSV/pencatatan pembayaran lewat RPC (Lapis 3; tabel dan antrean `v_finance_ready_to_bill` sudah ada), dashboard selain `v_kpi_sla_monthly`, impor Excel, anonimisasi data pribadi (NFR-D5), retensi foto (worker Storage), kanal WhatsApp/Push, reservasi stok (BR-038), serah-terima mid-visit (4.5), perhitungan ulang jeda SLA saat prioritas berubah, penandaan lupa check-out, partisi `audit_logs`, `CHARGED_TO_CUSTOMER` otomatis lewat persetujuan biaya, UI/RPC admin pelanggan (Lapis 3).

---

## 1. Prinsip dan Model Ancaman

1. **Default tolak.** RLS aktif di semua tabel `public` (dipaksa oleh loop di 0013 dan diperiksa `app.tables_without_rls()` di CI, NFR-S3). Tabel tanpa policy untuk suatu peran = tertutup.
2. **`anon` tidak punya apa-apa.** Semua hak tabel/fungsi dicabut dari `anon` dan `authenticated`, lalu diberikan eksplisit. Fungsi baru tidak otomatis bisa dipanggil (default privilege dicabut).
3. **Tulis sensitif hanya lewat RPC.** Perubahan status WO, keputusan persetujuan, stok, penugasan, penutupan: fungsi SECURITY DEFINER yang mengecek peran di dalamnya, bukan policy. Tabel inti tidak punya policy INSERT/UPDATE untuk `authenticated` kecuali bidang lapangan (checklist, temuan, foto, tanda tangan, jasa, pemakaian) dengan hak kolom sempit.
4. **Isolasi pelanggan berlapis (G1):** (a) policy `customer_id = ANY(my_customer_ids())`, (b) FK komposit `(asset_id, customer_id)`, `(site_id, customer_id)`, `(request_id, customer_id)`, `(contract_id, customer_id)` sehingga data lintas pelanggan tidak bisa dirakit walau lewat service role, (c) pelanggan tidak punya akses tabel `work_orders`/`wo_*`, hanya view, (d) Storage hanya lewat objek yang terdaftar, (e) pesan galat seragam (`WO005`, dipetakan 404).
5. **Jalur tepercaya = fungsi SECURITY DEFINER milik `postgres`** (bypass RLS), semuanya `SET search_path = ''` dengan nama terkualifikasi. Jangan memakai `FORCE ROW LEVEL SECURITY` (akan memblokir jalur ini).
6. **Append-only ditegakkan trigger**, bukan hanya privilege: `audit_logs`, `access_logs`, `wo_status_history`, `stock_movements`, `user_consents` menolak UPDATE/DELETE/TRUNCATE (`IMM01`), termasuk dari superuser aplikasi.
7. **WO final immutable (BR-044).** Setelah `CLOSED`/`CANCELLED`: kolom inti WO dan semua tabel anak lapangan menolak perubahan (`IMM01`); hanya `billing_*` dan `customer_note` yang boleh. Koreksi lewat mode revisi (`app.revision_mode`, hanya sesi tepercaya) dan baris `service_reports` revisi baru.

Ancaman yang dibahas: pelanggan A membaca/menulis data B (IDOR, tebakan UUID, tebakan path Storage), teknisi melihat WO atau harga di luar haknya, eskalasi hak oleh staf, pengubahan status WO dari klien, duplikasi pesanan/penyalahgunaan batas laju, foto palsu/belum terunggah dianggap terunggah, kebocoran lewat view/RPC definer, pencatatan audit yang bisa dihapus.

---

## 2. Identitas dan Helper Policy

| Fungsi (schema `app`) | Kegunaan | Catatan |
|---|---|---|
| `my_roles()`, `has_any_role(roles[])` | Peran aktif pengguna (profil harus `is_active`) | Dipakai sebagai `(select app.has_any_role('{...}'))` agar menjadi initplan |
| `my_customer_ids()` | Semua `customer_id` aktif milik pengguna (dukung multi-pengguna) | Dipakai `= ANY ((select app.my_customer_ids())::uuid[])` |
| `my_technician_id()` | `technicians.id` pengguna | |
| `my_active_wo_ids()` | WO yang boleh dilihat teknisi: penugasan `ASSIGNED/ACCEPTED/COMPLETED/CANCELLED`. `REJECTED/RELEASED/REASSIGNED` hilang (CONFLICT_REASSIGNED) | Indeks `ix_wo_assign_tech` (include `wo_id`) |
| `my_editable_wo_ids()`, `can_edit_wo()` | WO yang boleh diisi data lapangan: penugasan `ACCEPTED` dan status WO `IN_PROGRESS/ON_HOLD_PARTS/AWAITING_CUSTOMER_APPROVAL` | Setelah `UNDER_REVIEW` teknisi tidak bisa mengubah |
| `tech_customer_ids()/tech_site_ids()/tech_asset_ids()/tech_request_ids()` | Himpunan master yang terkait WO aktif teknisi | |
| `customer_owns_wo()` | Kepemilikan WO oleh pelanggan, untuk RPC | |
| `resolve_actor_roles(wo)` | Peran pengguna untuk WO tertentu (`CUSTOMER` hanya bila WO miliknya) | Dipakai `wo_transition` |
| `is_system()` | `service_role` (JWT) atau sesi `postgres` tanpa user (pg_cron) | Aksi bertanda `allow_system` |
| `can_read_object(bucket, name)` | Otorisasi baca Storage | Bagian 5 |

Pengguna yang `profiles.is_active = false` otomatis mendapat himpunan kosong dari semua helper: akses hilang seketika tanpa menunggu token kedaluwarsa. Pencabutan sesi (`auth.admin.signOut`) tetap dijalankan API server setelah `admin_set_user_active` (FR-007).

---

## 3. Matriks RLS per Tabel dan per Peran

Legenda: **R** baca semua baris; **R\*** baca baris terbatas (milik sendiri/perusahaan sendiri/WO yang ditugaskan); **W** tulis langsung (INSERT/UPDATE oleh RLS, hak kolom sempit, trigger memvalidasi); **X** tulis hanya lewat RPC/trigger/job; **V** hanya lewat view tertentu; `-` tertutup. PLG pelanggan, ADM Admin/CS, DSP Dispatcher, TEK Teknisi, SPV Supervisor, GDG Gudang, FIN Finance, OWN Owner.

### 3.1 Identitas, konfigurasi, master

| Tabel | PLG | ADM | DSP | TEK | SPV | GDG | FIN | OWN | Tulis |
|---|---|---|---|---|---|---|---|---|---|
| `profiles` | R\* (diri) | R | R | R\* (diri) | R | R\* | R\* | R | W diri (`full_name`,`phone`); aktif/nonaktif: X `admin_set_user_active` |
| `user_roles` | R\* (diri) | R | R\* (diri) | R\* (diri) | R\* (diri) | R\* | R\* | R | X `admin_set_user_roles` |
| `user_consents` | R\* (diri) | R\* | R\* | R\* | R\* | R\* | R\* | R\* | X (RPC registrasi/undangan) |
| `app_settings` | - | R | R | - | R | R | R | R | W OWN |
| `priorities`, `reason_codes` | - | R | R | R | R | R | R | R | W OWN |
| `wo_transitions` | - | R | R | R | R | - | - | R | migrasi saja |
| `skills`, `asset_categories` | - | R W | R | R | R | - | R | R | W ADM |
| `technicians` | - | R W | R | R\* (diri) | R | - | R | R | W ADM |
| `technician_skills` | - | R W | R | R\* (diri) | R | - | - | R | W ADM |
| `customers` | R\* (perusahaan sendiri) | R W | R | R\* (WO aktif) | R | - | R | R | W ADM |
| `customer_users` | R\* (perusahaan sendiri; akun dan keanggotaan harus aktif, N1) | R W | - | - | - | - | - | R | W ADM (Lapis 3: admin pelanggan lewat RPC, TODO) |
| `customer_invitations` | - | R W | - | - | - | - | - | R | W ADM |
| `customer_sites`, `assets` | R\* | R W | R | R\* (WO aktif) | R | - | R | R | W ADM |
| `service_types`, `problem_types` | R | R W | R | R | R | R | R | R | W ADM |
| `service_items` | - | R W | R | - | R | - | R | R | W ADM |
| `checklist_templates`, `_items`, `photo_requirements` | - | R W | R | R | R | - | - | R | W ADM |
| `business_calendars`, `calendar_hours`, `calendar_holidays` | - | R | R | - | R | - | - | R W | W OWN |
| `sla_policy_sets`, `sla_policies`, `escalation_rules` | - | R | R | - | R | - | - | R W | W OWN |
| `contracts`, `contract_assets` | R\* | R W | R | - | R | - | R | R | W ADM |
| `pm_periods` | R\* | R | R | - | R | - | R | R | X (job, `pm_period_resolve`) |
| `import_jobs` | - | R W | - | - | - | R | - | R | W ADM (Lapis 3) |

### 3.2 Permintaan dan work order

| Tabel | PLG | ADM | DSP | TEK | SPV | GDG | FIN | OWN | Tulis |
|---|---|---|---|---|---|---|---|---|---|
| `service_requests` | R\* | R W | R | - | R | - | R | R | PLG\* insert (kanal `PWA`, hak kolom sempit) dan update (hanya `SUBMITTED/NEEDS_INFO`, trigger membatasi ke batal/lengkapi); keputusan X `request_decide` |
| `request_attachments` | R\* | R W | R | R\* (permintaan dari WO aktif) | R | - | - | R | W PLG\*/ADM (path wajib `{customer_id}/req/{request_id}/%`) |
| `work_orders` | V `customer_work_orders`, `customer_requests` | R | R | V `tech_work_orders` (tanpa kolom harga/penagihan, G-08) | R | V `v_wh_part_requests` | R | R | X `wo_transition`, `wo_change_priority`, `wo_set_estimate`, `wo_override_billing`, `wo_declare_no_parts` (TEK, G-13), dll. Trigger menolak ubah status langsung |
| `wo_child_changes` | - | R | R | R\* (WO aktif) | R | - | R | R | trigger pada tabel anak WO (G-05); sinyal untuk `/sync/pull`, tanpa mengubah `work_orders.version` |
| `wo_status_history` | V `customer_wo_timeline` | R | R | R\* | R | - | R | R | trigger (append-only) |
| `wo_assignments` | V (nama teknisi di view) | R | R | R\* | R | - | - | R | X |
| `wo_visits` | - | R | R | R\* | R | - | - | R | X (check-in/out lewat transisi) |
| `wo_checklist_items` | - | R | R | R\* | R | - | - | R | W TEK (kolom `value,is_na,na_reason,client_captured_at,op_id`, WO editable) |
| `wo_photo_requirements` | - | R | R | R\* | R | - | - | R | X (salinan template) |
| `wo_findings` | - | R | R | R\* | R | - | - | R | W TEK (WO editable). `internal_note` tidak ke pelanggan |
| `wo_attachments` | V `customer_wo_photos` (WO `CLOSED`, kind BEFORE/AFTER/FINDING, `UPLOADED`) | R | R | R\* | R | - | - | R | W TEK insert (status `PENDING`, path wajib prefix WO) dan tombstone `deleted_at`. `UPLOADED` hanya server |
| `wo_signatures` | V (lewat laporan) | R | R | R\* | R | - | R | R | W TEK insert (`TECH_DEVICE`, path `.../sig/`, `upload_status` selalu `PENDING`; `UPLOADED` hanya server, G-04); pelanggan X `wo_customer_sign`; `content_hash` diisi trigger |
| `wo_labor_lines` | - | R | R | V `tech_wo_labor_lines` | R | - | R | R | W TEK insert/tombstone (kolom sempit; `billable`, harga diisi trigger) |
| `wo_part_usages` | - | R | R | V `tech_wo_part_usages` | R W (tombstone) | R | R | R | W TEK insert/tombstone; SPV tombstone |
| `extra_cost_approvals`, `_items` | V `customer_extra_cost_approvals` | R | R | V `tech_extra_cost_approvals` | R | - | R | R | X `extra_cost_request`, `extra_cost_decide` |
| `sla_events`, `sla_pauses` | - | R | R | - | R | - | - | R | X (job/transisi) |
| `service_reports` | V `customer_service_reports` (`READY`, WO `CLOSED`) | R | R | R\* | R | - | R | R | X (saat `APPROVE_CLOSE`; worker PDF mengisi `storage_path`, `READY`) |
| `ratings` | R\* W (satu per WO, WO `CLOSED`) | R | R | - | R | - | - | R | W PLG insert |
| `complaints` | R\* W (insert) | R W (update) | R | - | R W (update) | - | - | R | W PLG insert; ADM/SPV update |

### 3.3 Suku cadang, penagihan, lintas sektor

| Tabel | PLG | ADM | DSP | TEK | SPV | GDG | FIN | OWN | Tulis |
|---|---|---|---|---|---|---|---|---|---|
| `items` | - | R | R | V `v_items_catalog` (tanpa harga) | R | R W | R | R | W GDG |
| `stock_locations` | - | R | R | R\* (lokasi sendiri) | R | R W | R | R | W GDG |
| `stock_balances` | - | - | R | R\* (lokasi sendiri) | R | R | R | R | X (trigger dari ledger) |
| `stock_movements` | - | - | R | R\* (lokasi sendiri) | R | R | R | R | X (append-only; `stock_receive`, `stock_adjust`, `part_issue`, retur) |
| `part_requests`, `_lines` | - | R | R | R\* | R | R | - | R | X `part_request_create/decide` |
| `part_returns`, `_lines` | - | - | R | R\* | R | R | - | R | X `part_return_create/confirm` |
| `parts_variances` | - | - | R | R\* (miliknya) | R | R | R | R | X `parts_variance_resolve`, job |
| `invoices`, `invoice_lines`, `payments` | R\* (`ISSUED/PAID`) | R | - | - | R | - | R W | R | W FIN (TODO: pindah ke RPC penerbitan) |
| `notifications` | R\* W (`read_at`,`status` milik sendiri) | idem | idem | idem | idem | idem | idem | idem | X (pembuatan oleh fungsi/worker) |
| `notification_prefs` | R\* W | idem | idem | idem | idem | idem | idem | idem | W diri |
| `sync_operations` | R\* | R | R | R\* W insert (TEK aktif; `wo_id` NULL atau WO aktif) | R | - | - | R | status/hasil: X `sync_op_record` (pemilik baris, G-06); penyelesaian draf `RESCUED` (`resolved_*`): X `sync_rescued_resolve` (ADM, DSP, SPV, OWN) |
| `audit_logs` | - | - | - | - | R terbatas (WO, penugasan, persetujuan, tanda tangan, permintaan, selisih) | - | - | R | trigger |
| `access_logs` | - | - | - | - | - | - | - | R | X `log_data_access` |
| `job_runs` | - | R | - | - | - | - | - | R | job |
| `rate_limits`, `document_counters` | - | - | - | - | - | - | - | - | hanya fungsi definer |

---

## 4. Katalog Antarmuka Database untuk API (acuan nama)

**RPC** (semua `SECURITY DEFINER`, `GRANT EXECUTE` hanya ke `authenticated`):

| RPC | Pemanggil | Fungsi |
|---|---|---|
| `wo_transition(p_wo_id, p_action, p_expected_version, p_op_id, p_reason, p_reason_code, p_payload jsonb)` | semua peran sesuai `wo_transitions` | Satu-satunya pintu status WO. Aksi: `ASSIGN, REASSIGN, ACCEPT, REJECT, RELEASE, DEPART, CHECK_IN, HOLD_PARTS, RESUME_PARTS, REQUEST_EXTRA_COST, APPROVE_EXTRA_COST, REJECT_EXTRA_COST, CLOSE_AFTER_REJECTION, SUBMIT_REVIEW, REQUEST_SIGNOFF, SIGNOFF, APPROVE_CLOSE, RETURN, RESUME_AFTER_RETURN, CANCEL, CANCEL_BY_CUSTOMER, CANCEL_ACTIVE, VISIT_FAILED` (sistem: `EXPIRE_EXTRA_COST, EXPIRE_SIGNOFF`). Mengembalikan `{status, version, replayed, warnings}` |
| `request_decide(request_id, decision APPROVE/NEEDS_INFO/REJECT, priority_code, service_type_id, estimate_total, reason, expected_version)` | ADM | T-01/T-24; membuat WO |
| `extra_cost_request`, `extra_cost_decide` | TEK; PLG atau ADM | BR-050 sampai BR-055 |
| `wo_customer_sign` | PLG | T-18 via PWA. Sejak 0016: path wajib `.../sig/{file}` (bukan foto terdaftar); objek harus sudah ada di Storage (ukuran > 0, gambar) agar tanda tangan `UPLOADED` (G-04) |
| `wo_request_help`, `wo_add_helper`, `wo_request_cancel`, `wo_change_priority`, `wo_override_billing`, `wo_create_rework`, `wo_cost_summary`, `wo_set_estimate` | sesuai peran | T-26, BR-015, BR-062, T-25, BR-050. `wo_cost_summary` untuk teknisi hanya `{needs_approval}` (S1) |
| `wo_declare_no_parts(p_wo_id, p_value, p_expected_version, p_op_id)` | TEK LEAD pemegang WO yang dapat diisi (helper: `WO002`) | G-13, BR-040(6). Menulis `no_parts_used` (menaikkan `version`; nilai sama atau `p_op_id` yang sudah `APPLIED` = replay); `WO005` bila bukan miliknya, `WO001` bila status tak dapat diisi, `WO003` `PARTS_ALREADY_RECORDED` bila pemakaian sudah tercatat |
| `wo_closure_check(p_wo_id)` | TEK pemegang WO; ADM, DSP, SPV, OWN | G-12. Array `[{code,...}]` dari `app.wo_submit_deficiencies` (mode `CLOSE` bila WO `UNDER_REVIEW`, selain itu `SUBMIT` dengan antrean klien 0). Lainnya `WO005` |
| `sync_op_record(p_op_id, p_status, p_result, p_clock_skew)` | pemilik baris `sync_operations` | G-06. `RECEIVED` ke `APPLIED/REJECTED/RESCUED`, `REJECTED` ke `RESCUED`; baris orang lain `WO005`; `p_result` maks 64 KB |
| `sync_rescued_resolve(p_op_id, p_note)` | ADM, DSP, SPV, OWN | G-06. Menutup draf `RESCUED` (`resolved_at/by/note`) |
| `pm_period_resolve` | ADM | BR-024/025 |
| `part_request_create/decide`, `part_issue`, `part_return_create/confirm`, `stock_receive`, `stock_adjust`, `parts_variance_resolve` | TEK, GDG, SPV | BR-030 sampai BR-038 |
| `register_individual_customer`, `accept_customer_invitation`, `admin_set_user_roles`, `admin_set_user_active`, `log_data_access` | sesuai | D1, FR-171 |

**Kode galat** (SQLSTATE kustom, lihat header SQL): `WO001` transisi tidak diizinkan, `WO002` tidak berhak, `WO003` guard gagal (`DETAIL` berisi jsonb `[{code,...}]`, mis. `CHECKLIST_INCOMPLETE, PHOTO_MISSING, SIGNATURE_MISSING, PARTS_NOT_DECLARED, FINDINGS_INCOMPLETE, SYNC_PENDING, SOFT_GUARD`), `WO004` konflik versi (`DETAIL`: versi/status saat ini), `WO005` tidak ditemukan (404 seragam), `WO006` input tidak valid, `STK01` stok kurang, `RL001` batas laju, `IMM01` data immutable.

**View baca**: pelanggan `customer_requests, customer_work_orders, customer_wo_timeline, customer_extra_cost_approvals, customer_wo_photos, customer_service_reports`; teknisi `tech_work_orders, tech_wo_part_usages, tech_wo_labor_lines, tech_extra_cost_approvals, v_tech_asset_service_history, v_items_catalog`; gudang `v_wh_part_requests`; operasional `v_today_work_orders, v_open_part_variances, v_job_health, v_finance_ready_to_bill, v_kpi_sla_monthly`.

---

## 5. Isolasi Data Pelanggan: View, RPC, Storage

### 5.1 View dan RPC
- View pelanggan memakai pola `where customer_id = any ((select app.my_customer_ids())::uuid[])` dengan `security_barrier = true` (mencegah fungsi bocor di predikat pengguna mengeksekusi sebelum filter). View itu dimiliki `postgres` sehingga membaca tabel mentah tanpa RLS; satu-satunya penjaga adalah filter di dalam view, jadi **setiap view `customer_*` baru wajib punya filter tersebut dan uji isolasinya (bagian 7)**.
- Kolom yang sengaja tidak ada di view pelanggan: `billing_*`, `estimate_*`, `policy_snapshot`, `help_*`, `closure_exception_*`, `internal_note`, `decision_by`, `duplicate_of`, `created_by`, `decided_by`, `unit_cost`.
- Nama teknisi dan jadwal baru tampil setelah teknisi menerima (DEC-02). `status_note` mengambil `customer_note`, alasan batal, atau catatan `NEEDS_INFO`/penolakan.
- RPC memakai 404 seragam: bila WO tidak ada atau bukan milik pemanggil, kode `WO005` yang sama.

### 5.2 Storage
- Bucket `wo-media` (gambar) dan `reports` (PDF) **privat**; `public = false` dipaksa saat migrasi. `file_size_limit` dibiarkan NULL sampai batas [P] diputuskan (NFR-S7); `allowed_mime_types` dibatasi.
- Path: `{customer_id}/req/{request_id}/{file}` dan `{customer_id}/wo/{wo_id}/{file}`. Path yang tidak cocok regex ditolak `can_read_object` (mencegah traversal dan tebakan).
- **SELECT** (policy `vasta_media_read` memanggil `app.can_read_object`): staf operasional (ADM, DSP, SPV, OWN) boleh; FIN hanya bucket `reports`; teknisi hanya objek WO/permintaan yang ia pegang di bucket `wo-media` (bukan `reports`, S4); pelanggan hanya objek yang **terdaftar** dan boleh dilihat: lampiran permintaan sendiri, foto `BEFORE/AFTER/FINDING` yang `UPLOADED` pada WO `CLOSED`, tanda tangan `VALID` pada WO `CLOSED`, laporan `READY`. Foto `OTHER`/`FAILED_VISIT` tidak pernah terlihat pelanggan.
- **Tulis**: tidak ada policy INSERT/UPDATE/DELETE. Alur: klien meminta URL unggah ke API, API mengecek hak (WO editable, atau permintaan milik pelanggan), menentukan path, membuat signed upload URL (service role), menerima unggahan, memverifikasi magic bytes/ukuran/checksum, lalu service role mengubah `upload_status` ke `UPLOADED` (juga untuk `wo_signatures` tanda tangan teknisi, G-04). Metadata (`wo_attachments`/`request_attachments`) dimasukkan klien lebih dulu dengan path yang wajib berprefix WO/permintaan miliknya (policy `WITH CHECK`).
- **Unduh**: signed URL berumur pendek dibuat dengan JWT pengguna (policy berlaku) atau service role setelah API memanggil `can_read_object`/memeriksa kepemilikan. Akses staf terhadap data pelanggan dicatat dengan `log_data_access` (FR-171); DB tidak bisa mencatat unduh Storage sendiri.
- EXIF lokasi pada foto pelanggan dibuang di klien (NFR-D4), foto teknisi disimpan dengan jejak terpisah.

---

## 6. Pemakaian Service Role

`service_role` melewati RLS. Aturan:

1. Kunci hanya ada di server Next.js (route handler/server action/worker), variabel lingkungan tanpa prefix `NEXT_PUBLIC_`, tidak pernah dikirim ke klien, tidak masuk log.
2. **Default adalah JWT pengguna**: pembacaan dan tulisan biasa memakai klien Supabase dengan token pengguna sehingga RLS dan `auth.uid()` (aktor di audit) berlaku. Fungsi `wo_transition` memerlukan `auth.uid()`.
3. Pemakaian yang sah (daftar tertutup): (a) membuat signed upload URL dan memverifikasi unggahan, lalu menandai `UPLOADED`; (b) pembuatan akun/undangan (`auth.admin.*`) dan pencabutan sesi; (c) bootstrap peran `OWNER` pertama; (d) worker pengirim notifikasi (membaca `notifications` berstatus `PENDING`, menulis `SENT/FAILED`); (e) worker render PDF (mengisi `service_reports.storage_path` dan `READY`); (f) penjadwal cadangan memanggil `app.run_job` bila `pg_cron` tidak tersedia; (g) pekerjaan retensi/anonimisasi.
4. Setiap rute service role harus: memvalidasi sesi pengguna dan kepemilikan sendiri lebih dulu (cek lewat klien ber-JWT), membatasi kolom/baris yang ia sentuh, dan menulis `request_id`. Jangan membuat endpoint generik "jalankan query/ubah tabel apa pun".
5. Operasi berhak tinggi yang bisa dilakukan lewat RPC (status WO, stok, persetujuan) **tidak** memakai service role; RPC sudah mengecek peran dan menulis audit atas nama pengguna.
6. Fungsi `SECURITY DEFINER`: `search_path = ''`, nama terkualifikasi, tidak menerima nama tabel/kolom/SQL dari parameter, cek peran di awal, `EXECUTE` dicabut dari `PUBLIC` lalu diberikan eksplisit (0013). Fungsi di schema `app` tidak diekspos PostgREST (jangan tambahkan `app` ke *exposed schemas*).
7. Jika `pg_cron` tidak aktif, `app.run_job(...)` hanya boleh dipanggil oleh service role/`postgres`; `GRANT EXECUTE` pada `app.*` tidak diberikan ke `authenticated` kecuali helper policy.

---

## 7. Rencana Pengujian Isolasi (FR-173, G1)

### 7.1 Prinsip dan data uji
- Dua pelanggan (A, B) masing-masing dengan aset, permintaan, WO di setiap status, lampiran, persetujuan, laporan; satu pengguna tanpa pemetaan pelanggan; pengguna ber-`customer_id` ganda (dua perusahaan) untuk uji `ANY`; dua teknisi; satu pengguna dinonaktifkan; semua peran staf. Data fiktif (NFR-D8).
- Meniru PostgREST: `set role authenticated; select set_config('request.jwt.claim.sub', '<uuid>', false);` lalu jalankan kueri. Untuk `anon`: `set role anon`.
- Uji di CI pada setiap migrasi; **tabel/view/RPC/bucket baru tanpa uji isolasi = build gagal**.

### 7.2 Kasus uji minimum

| Kelompok | Kasus | Harapan |
|---|---|---|
| Tabel | Pelanggan A `select` dari setiap tabel di `public` (daftar dari `pg_class`) | Hanya baris miliknya pada tabel yang diizinkan (customers, sites, assets, requests, attachments, contracts, ratings, complaints, invoices, notifikasi sendiri); 0 baris di tabel lain |
| Tabel | Pengguna tanpa pemetaan pelanggan | 0 baris di semua tabel data pelanggan |
| Tebakan ID | A `select`/`update` dengan UUID aset, permintaan, WO, lampiran milik B | 0 baris / 0 baris terpengaruh |
| Tulis lintas | A insert permintaan dengan `customer_id` B; dengan aset B + `customer_id` A; `channel='PHONE'`; menyetel `status/created_by/duplicate_of` | Ditolak (RLS, FK komposit, hak kolom) |
| View | A dan B memanggil setiap `customer_*` | Hanya baris sendiri; kolom daftar bagian 5.1 tidak ada |
| RPC | A/B memanggil `wo_transition`, `extra_cost_decide`, `wo_customer_sign`, `wo_request_cancel`, `wo_cost_summary` pada WO pihak lain | Kode `WO005`, tanpa membedakan "tidak ada" |
| Status | Pelanggan memanggil aksi staf (`ASSIGN`, `APPROVE_CLOSE`) pada WO sendiri | `WO002` |
| Storage | `can_read_object` untuk path foto sendiri, milik B, path tak terdaftar, kind `OTHER`, traversal (`../`), bucket salah | Hanya yang terdaftar dan boleh |
| Storage nyata | Dengan JWT A, `storage.from('wo-media').createSignedUrl`/`download` untuk objek B; upload langsung | Ditolak (uji di Supabase nyata) |
| Teknisi | Teknisi 2 mengakses WO teknisi 1; setelah `REASSIGN`, teknisi lama membaca WO | 0 baris |
| Teknisi/harga | Teknisi `select` `items`, `wo_part_usages`, `wo_labor_lines`, `extra_cost_approvals`, kolom harga di view `tech_*` | 0 baris / kolom tidak ada |
| Staf | Gudang membaca `work_orders`; Finance menulis `work_orders`; ADM memberi peran `OWNER` | Ditolak |
| anon | `anon` membaca tabel apa pun dan memanggil RPC | `42501` |
| Penonaktifan | Pengguna `is_active=false` membaca semua | 0 baris |
| Append-only | UPDATE/DELETE/TRUNCATE pada `audit_logs`, `wo_status_history`, `stock_movements` | `IMM01` |
| Status | `update work_orders set status=...` oleh siapa pun termasuk staf | `WO001` |
| Struktur | `select * from app.tables_without_rls()` | 0 baris |
| Kebocoran fungsi | Fungsi `SECURITY DEFINER` di `public`/`app` tanpa `search_path` terkunci | 0 (cek `pg_proc.proconfig`) |

### 7.3 Contoh pgTAP (belum dijalankan; pgTAP tidak tersedia di lingkungan lokal)

```sql
begin;
create schema if not exists tests;
select plan(6);

create or replace function tests.as_user(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;

select tests.as_user('<USER_PELANGGAN_A>'::uuid);

select is((select count(*) from public.assets where customer_id = '<CUSTOMER_B_ID>'), 0::bigint,
          'A tidak melihat aset B');
select is((select count(*) from public.work_orders), 0::bigint,
          'A tidak punya akses tabel work_orders');
select throws_ok($$ insert into public.service_requests (customer_id, asset_id, problem_type_id)
                    values ('<CUSTOMER_B_ID>', '<ASSET_B_ID>', '<PT_ID>') $$, '42501', null,
                 'A tidak bisa memesan atas nama B');
select throws_ok($$ select public.wo_transition('<WO_B_ID>', 'CANCEL_BY_CUSTOMER', 1) $$, 'WO005', null,
                 'WO milik B: 404 seragam');
select is((select count(*) from public.customer_work_orders where wo_id = '<WO_B_ID>'), 0::bigint,
          'view pelanggan tidak memuat WO B');
select is((select app.can_read_object('wo-media', '<CUSTOMER_B_ID>/wo/<WO_B_ID>/x.jpg')), false,
          'objek Storage B ditolak');

select * from finish();
rollback;
```


### 7.4 Uji isolasi lain yang wajib di luar DB
Uji E2E Playwright dengan dua sesi pelanggan; pemindaian rute API yang memakai service role (peninjauan kode); tes bahwa setiap Route Handler memverifikasi sesi sebelum memakai service role; uji `Realtime` bahwa langganan tabel hanya menerima baris sendiri (lihat bagian 8).

---

## 8. Indeks Pendukung Policy dan Catatan Performa

| Policy / jalur | Indeks / mekanisme |
|---|---|
| `my_customer_ids()` | `ix_customer_users_user (user_id) WHERE is_active` plus PK `profiles`, `customers` |
| Policy pelanggan `customer_id = ANY(...)` | `ix_assets_customer`, `ix_customer_sites_customer`, `ix_sr_customer (customer_id, created_at DESC)`, `ix_contracts_customer`, `ix_reports_customer`, `ix_ratings_customer`, `ix_complaints_customer`, `ix_invoices_customer`, `ix_wo_customer_status`, `ix_wo_customer_created` (view `customer_work_orders`), `ix_req_att_customer` |
| `my_active_wo_ids()` (teknisi) | `ix_wo_assign_tech (technician_id, status) INCLUDE (wo_id)`; semua anak WO memakai `wo_id IN (select ...)` sehingga butuh indeks `wo_id`: `ix_wo_att_wo`, `ix_wo_labor_wo`, `ix_wo_usage_wo`, `ix_wsh_wo`, `ix_wo_visits_wo`, `UNIQUE (wo_id, seq)` pada `wo_checklist_items`, `ix_pr_wo` |
| `tech_*_ids()` (master teknisi) | PK tabel master + `ix_wo_assign_tech`; himpunan kecil (WO aktif satu teknisi) |
| `customer_extra_cost_approvals` | `ix_extra_wo (wo_id, status)`, `ix_extra_items_approval` |
| Lookup Storage (`can_read_object`) | `storage_path` UNIQUE di `request_attachments`, `wo_attachments`, `wo_signatures`, `service_reports` |
| Idempotensi dan antrean | `uq_wsh_op`, `uq_notif_dedupe`, `uq_sla_events_*`, `uq_wo_preventive_period`, `uq_wo_request`, `ix_wo_sla_next`, `ix_notif_queue` |

Catatan performa (belum diukur dengan beban; tidak ada angka klaim):
- **Pola initplan**: semua helper dipanggil sebagai `(select app.fn())`, dan `ANY` memakai `(select ...)::uuid[]` supaya dievaluasi sekali per statement, bukan per baris. Tanpa pembungkus `select`, fungsi STABLE dievaluasi per baris. Periksa dengan `EXPLAIN` bahwa muncul `InitPlan`.
- Fungsi helper berupa SQL `STABLE SECURITY DEFINER` kecil; PostgreSQL tidak meng-inline fungsi SECURITY DEFINER, jadi jangan memperbanyak pemanggilan per baris. Policy `WITH CHECK ... can_edit_wo(wo_id)` dievaluasi per baris yang ditulis (volume rendah, aman).
- `my_active_wo_ids()` dipakai sebagai `IN (select ...)` (semi join hash). Jika satu teknisi menumpuk sangat banyak penugasan `COMPLETED`, pertimbangkan membatasi jendela riwayat (setting [P]) atau mengganti dengan tabel "WO terlihat" yang dipelihara trigger.
- View `security_barrier` menghambat sebagian optimasi (predikat pengguna tidak didorong turun). Beri filter bernilai tinggi (`wo_id`, `display_status`) dan batasi kolom; periksa `EXPLAIN` untuk daftar pelanggan yang panjang.
- `audit_logs` tumbuh cepat (trigger di banyak tabel, termasuk `wo_checklist_items`). Sudah ada indeks `(entity_type, entity_id, at DESC)` dan BRIN `at`. Rencanakan partisi bulanan dan arsip (TODO) sebelum pilot; retensi tidak bisa memakai DELETE karena append-only.
- `notifications`: satu baris per kanal per penerima; antrean dengan indeks parsial `PENDING`. `purge_expired_data` memangkas yang `SENT/READ` menurut setting retensi.
- Job SLA hanya memindai WO aktif dengan `next_sla_check_at <= now()` (indeks parsial), jadwal berikutnya dihitung dari instan warning/breach berikutnya sehingga tidak memindai seluruh WO.
- **Realtime (belum diuji):** Supabase Realtime menerapkan RLS pada tabel tetapi tidak pada view. Untuk status pesanan pelanggan, pakai langganan pada `service_requests` (RLS langsung) atau kanal broadcast yang dipicu server, lalu muat ulang lewat view. Policy yang memanggil fungsi definer menambah beban per perubahan pada Realtime.
- Statement trigger audit membaca `request.headers` dan `app.my_roles()` per baris; bila menjadi bottleneck untuk impor massal, nonaktifkan trigger audit pada sesi migrasi/impor dengan prosedur terkontrol, bukan permanen.

---

## 9. Pengamanan Lain yang Tertanam di Skema

| Ancaman | Kontrol |
|---|---|
| Pesanan ganda/palsu (R8) | Unique `(customer_id, client_request_id)`; trigger batas laju per pelanggan (`RL001`, setting [P]); `duplicate_of` (peringatan); kanal `PWA` wajib untuk pelanggan; validasi admin sebelum WO |
| Pelanggan menyuplai identitas/keputusan | Hak kolom INSERT `service_requests` tidak mencakup `status`, `created_by`, `decision_*`, `duplicate_of` (trigger memaksa `SUBMITTED` saat insert); UPDATE `status` oleh pelanggan dibatasi trigger ke batal atau melengkapi info |
| Biaya tambahan tanpa persetujuan (BR-052) | Trigger pada baris jasa dan suku cadang: `is_extra` wajib `extra_approval_id` berstatus `APPROVED` untuk WO yang sama (kecuali `emergency` + alasan) |
| Persetujuan basi/diubah | Hash isi persetujuan harus sama dengan yang ditampilkan (`WO004`); versi lama `SUPERSEDED`; satu `PENDING` per WO (unique parsial); keputusan atas nama pelanggan wajib bukti dan kanal non-PWA |
| Tanda tangan untuk isi lain | Hash dihitung server; tanda tangan lama menjadi `SUPERSEDED` bila isi berubah (BR-043) |
| Stok palsu/negatif | Ledger append-only; saldo diperbarui trigger dengan kunci baris berurutan; `STK01`; retur butuh konfirmasi Gudang (BR-034); pemakaian tanpa stok teknisi ditolak kecuali setting `stock.allow_unsourced_usage` |
| Transisi ganda/offline berulang | `expected_version` wajib; `p_op_id` unik per WO pada `wo_status_history`; replay mengembalikan hasil sebelumnya |
| Data lapangan terlambat setelah WO final | Trigger `IMM01`; klien memperlakukan sebagai `CONFLICT_*` dan menyimpan draf diselamatkan (`sync_operations.status = RESCUED`) |
| Pendaftaran | Registrasi mandiri mati bila `registration.mode` NULL; persetujuan kebijakan wajib; undangan menyimpan hash token, kedaluwarsa, email harus cocok, pesan galat seragam; batas laju pendaftaran/IP di edge (NFR-S8) |
| `raw_user_meta_data` dapat diubah pengguna | Hanya dipakai untuk nama tampilan, tidak pernah untuk peran/otorisasi |
| Eskalasi hak | `user_roles` tanpa DML langsung; `CUSTOMER` eksklusif; perubahan `OWNER/ADMIN_CS` oleh `OWNER`; semua perubahan peran diaudit |

---

## 10. Status Verifikasi

**Dijalankan:** seluruh `04_database_schema.sql` dieksekusi utuh (satu kali, database kosong) pada PostgreSQL 16.2 lokal (paket `pgserver`), lalu diuji dengan harness Python/psycopg2 yang menyamar sebagai role `authenticated`/`anon` lewat `set role` dan `request.jwt.claim.sub`. 171 pemeriksaan lulus, 0 gagal: isolasi pelanggan (tabel, view, RPC, tebakan ID, tulis lintas pelanggan), peran teknisi/staf/gudang, hak kolom, alur WO penuh (assign, tolak, terima, check-in, tutup, kembalikan, setujui, batal, kunjungan gagal, tugas ulang, tanda tangan via PWA, pengecualian), biaya tambahan (versi, hash, kedaluwarsa, tolak), SLA (kalender lintas hari/libur, jeda, eskalasi idempoten, level bertahap), PM (idempotensi termasuk dua sesi paralel, catch-up, MISSED, kontrak diakhiri), stok (serah-terima, pemakaian, retur, selisih, write-off, stok minimum), append-only, auto-approve, rework, registrasi, `anon`, penonaktifan pengguna, `app.can_read_object`.

**Belum diuji (jangan dianggap terbukti):**
- Proyek Supabase nyata: Auth Hook, trigger pada `auth.users` di lingkungan terkelola, `storage.buckets`/`storage.objects` dan policy Storage (bagian terkait dilewati otomatis bila schema `storage` tidak ada), unggahan/unduh signed URL, Realtime, PostgREST (hak kolom pada `INSERT ... RETURNING`, `Prefer: return=minimal`).
- `pg_cron` (blok 0014 dilewati bila ekstensi tidak ada) dan `pg_trgm` (indeks trigram dilewati). Ekstensi lokal tidak tersedia pada build uji.
- Zona waktu bernama `Asia/Jakarta`: build lokal tidak membawa tzdata, sehingga uji kalender memakai zona POSIX `WIB-7` (setara UTC+7). Logika sama; perilaku dengan tzdata penuh (DST, perubahan aturan) belum diuji.
- pgTAP (contoh di 7.3 belum dijalankan), uji beban dan `EXPLAIN` pada data besar, uji paralel selain generator PM, pengujian PostgreSQL 15 (Supabase) khusus `security_invoker` view.
- Kebijakan UU PDP: retensi, anonimisasi, dan prosedur insiden adalah interpretasi dan belum diverifikasi hukum (02 bagian 3.3).

**Cara memverifikasi di Supabase:** jalankan skrip pada proyek baru, aktifkan `pg_cron` di dashboard sebelum 0014, pastikan schema `app` TIDAK termasuk *exposed schemas*, lalu jalankan ulang rencana 7.2 memakai token pengguna uji sesungguhnya (termasuk Storage dan Realtime).
