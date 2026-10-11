# Desain API: VASTA, Field Service & Work Order Management

Versi: 0.2 (draf, diselaraskan dengan 04 dan 05) | Tanggal: 2026-10-11 | Status: belum divalidasi dengan perusahaan servis nyata

Dokumen pendamping: `01_PRD.md` (kebutuhan dan lapis), `02_business_analysis_technical_logic.md` (FR, state machine T-01..T-27, BR, offline sync, entitas), `04_database_schema.sql` dan `05_rls_and_security.md` (**acuan nama** tabel, kolom, enum, RPC, view, kode galat), `openapi.yaml` (kontrak mesin-baca untuk Jalur B).

## 0. Cara Membaca Dokumen Ini

### 0.1 Penanda

| Penanda | Arti |
|---|---|
| **[S]** | Bersumber dari dokumen kebutuhan (lewat 01/02). |
| **[A]** | Asumsi desain API. Harus divalidasi. |
| **[P]** | Parameter yang dikonfigurasi. Nilainya **tidak ditetapkan** di dokumen ini (batas laju, ukuran, kedaluwarsa, ukuran halaman, dan sebagainya). |
| **[U]** | Usulan perancang API yang belum ada di 01/02; perlu persetujuan. |
| **D01..D28** | Keputusan skema di 05 bagian 0 (mis. D08 = keputusan biaya tambahan hanya lewat `extra_cost_decide`). |
| **G-nn** | Celah antara kebutuhan API dan 04/05. Daftar di bagian 10.2; keputusannya ada pada pengguna, 04 tidak diubah dari dokumen ini. |

Dua istilah "lapis" dipakai dan tidak boleh tertukar:

- **Lapis 1/2/3** = lapis produk menurut 01 (Inti, Proses dan Kontrol, Penyempurnaan).
- **Jalur A/B** = jalur akses API: **Jalur A** lewat Supabase langsung (PostgREST: tabel/view dengan RLS, dan RPC `public.*` yang di-`GRANT EXECUTE` ke `authenticated`), **Jalur B** lewat Route Handler Next.js (butuh rahasia server, penandatanganan, sinkron, job, atau pemetaan galat ke RFC 9457).

### 0.2 Peran: singkatan di dokumen ini vs enum `app_role` di 04

| Singkatan (02) | Enum `app_role` | | Singkatan (02) | Enum `app_role` |
|---|---|---|---|---|
| PLG | `CUSTOMER` | | SPV | `SUPERVISOR` |
| ADM | `ADMIN_CS` | | GDG | `WAREHOUSE` |
| DSP | `DISPATCHER` | | FIN | `FINANCE` |
| TEK | `TECHNICIAN` | | OWN | `OWNER` |

`openapi.yaml` memakai nama enum (`x-roles`); tabel di dokumen ini memakai singkatan. Tambahan: ANY (pengguna terautentikasi), PUB (publik), SYS (job/webhook).

### 0.3 Status penyelarasan dengan 04 dan 05 (perubahan terhadap draf 0.1)

`04_database_schema.sql` dan `05_rls_and_security.md` kini ada dan menjadi acuan. Seluruh TODO-04 pada draf 0.1 telah diselesaikan atau dipindahkan menjadi gap G-nn. Ringkasan perubahan:

| Topik | Draf 0.1 | Sekarang (mengikuti 04/05) |
|---|---|---|
| Peran untuk otorisasi | Klaim JWT `app_metadata.roles` | Dibaca dari tabel (`app.my_roles()`, D01). Klaim JWT hanya petunjuk UI. |
| Akses pelanggan | Sebagian tabel via view | Pelanggan **tanpa** akses `work_orders`/`wo_*`; hanya view `customer_*` (D17). |
| Harga untuk teknisi | Respons dibersihkan | Teknisi baca lewat `tech_*`/`v_items_catalog`; INSERT jasa/pemakaian dengan `Prefer: return=minimal` (D16). |
| Unggahan | Endpoint khusus per konteks | Satu pola: klien INSERT baris metadata, API `POST /uploads/sign`, PUT, `POST /uploads/complete`; hanya server menandai `UPLOADED` (D19). |
| Keputusan biaya | Dua endpoint approve/reject | Satu endpoint `decision` -> `extra_cost_decide` (D08). |
| Idempotensi umum | Tabel `idempotency_keys` | Tidak ada; idempotensi lewat `p_op_id`, `client_request_id`, kunci alami (G-03). |
| Outbox event | Tabel `domain_events` | Tidak dipakai: `notifications` (dibuat oleh fungsi DB, dedupe unik) adalah antrean. |
| Pelanggan membuat WO/komplain | Endpoint | Pelanggan hanya INSERT `service_requests`, `ratings`, `complaints` (Jalur A). |
| Aksi penutupan otomatis Lapis 1 | Setting `requires_supervisor_review` | Tidak ada di 04; T-19 hanya SUPERVISOR (G-01). |
| Nama enum | `UPPER_SNAKE` bebas | Persis 04, mis. status tampil `RECEIVED/SCHEDULED/EN_ROUTE/IN_PROGRESS/AWAITING_CUSTOMER/COMPLETED/CANCELLED`. |

Perubahan atas asumsi API-AS-01..13 dicatat di bagian 10.1.

### 0.4 Cakupan

Jumlah operasi Jalur B yang didokumentasikan: **59** (Lapis 1: 28, Lapis 2: 25, Lapis 3 ringkas: 6). Tabel bagian 6, katalog error bagian 5, katalog operasi sinkron bagian 7.3, dan `openapi.yaml` dihasilkan dari satu daftar data sehingga konsisten.

| Modul | Operasi |
|---|---|
| Akun, registrasi, undangan | 7 |
| Permintaan servis dan unggahan | 5 |
| Work order: transisi status (wo_transition) dan RPC kecil | 25 |
| Persetujuan biaya tambahan | 2 |
| Suku cadang dan stok | 8 |
| Pemeliharaan berkala | 1 |
| Berkas | 1 |
| Sinkronisasi offline teknisi | 2 |
| Endpoint internal (job, webhook) | 2 |
| Lapis 3 (ringkas) | 6 |

Dokumen ini tidak menetapkan angka bisnis. Contoh nominal, tanggal, dan nama pada bagian 9 adalah data fiktif untuk ilustrasi, bukan tarif atau SLA.

---

## 1. Prinsip Desain

1. **Invarian bisnis hidup di database** (05 bagian 1). Status WO hanya berubah lewat `wo_transition` (WO001 bila aksi tidak ada di `wo_transitions`); stok lewat ledger append-only; persetujuan biaya hanya lewat `extra_cost_decide`. Route Handler tipis: validasi bentuk, pemetaan galat, penandatanganan, rate limit tepi. Memanggil RPC langsung lewat PostgREST tidak membuka celah karena RPC memeriksa peran di dalamnya.
2. **Satu jalur tulis per fakta bisnis.** `authenticated` tidak punya INSERT/UPDATE pada tabel WO/stok/persetujuan kecuali bidang lapangan dengan hak kolom sempit (05 bagian 3).
3. **Baca murah, tulis hati-hati.** Pembacaan lewat tabel/view ber-RLS (Jalur A); penulisan beraturan lewat RPC.
4. **Isolasi pelanggan berlapis** (05 bagian 1.4): policy `customer_id = ANY(my_customer_ids())`, FK komposit, tanpa akses tabel WO, Storage via objek terdaftar, galat seragam `WO005` -> 404.
5. **Idempoten dan dapat diulang.** Tulis dari klien yang bisa terputus membawa kunci buatan klien (`p_op_id`, `client_request_id`, `id` klien). Replay mengembalikan hasil lama (`replayed=true`).
6. **Offline-first memengaruhi bentuk API.** Teknisi menulis lewat `outbox` -> `POST /sync/push` dengan operasi granular; data lapangan tidak pernah dibuang diam-diam (DEC-06, `sync_operations.status = RESCUED`).
7. **Klien tidak pernah mengirim harga, status akhir, `billing_type`, `upload_status`, atau `content_hash` tanda tangan** (BR-067, D12, D19).
8. **Galat dapat ditindaklanjuti.** Satu format RFC 9457; kode domain stabil; kegagalan penutupan WO mengembalikan seluruh kekurangan sekaligus (DETAIL jsonb WO003).
9. **Aditif dahulu** (bagian 4.1).
10. **Kecil tapi lengkap untuk portofolio.** Satu penyedia servis (AS-01), tanpa payment gateway, tanpa GPS kontinu [S].

---

## 2. Pembagian Jalur: Supabase Langsung vs Route Handler

### 2.1 Kriteria

| Pertanyaan | Ya -> | Tidak -> |
|---|---|---|
| Butuh rahasia server (`service_role`, penyedia email, HMAC), menandatangani URL Storage, atau menjalankan auth admin? | **Jalur B** | lanjut |
| Butuh orkestrasi lintas langkah (sinkron batch, urutan `seq`, penyelamatan draf)? | **Jalur B** | lanjut |
| Butuh bentuk galat RFC 9457 + `Idempotency-Key` seragam bagi klien (PWA)? | **Jalur B** (fasad tipis di atas RPC) | lanjut |
| Cukup CRUD ber-RLS, atau satu RPC definer yang sudah memeriksa semuanya? | **Jalur A** | Jalur B |

### 2.2 Jalur A: PostgREST + RLS + RPC (tanpa kode server)

Klien memakai `supabase-js` dengan JWT pengguna. Skema `app` **tidak** diekspos (05 bagian 6.6). Nama di bawah persis dari 04.

**Tabel dan view yang dibaca/ditulis langsung**

| Sumber | Baca | Tulis langsung (hak kolom sempit) | Catatan |
|---|---|---|---|
| `customers`, `customer_sites`, `assets`, `asset_categories`, `service_types`, `problem_types`, `service_items`, `skills`, `technicians`, `technician_skills`, `checklist_templates` + `_items`, `photo_requirements`, `contracts`, `contract_assets` | Staf menurut matriks 05 bagian 3.1; PLG `R*` perusahaan sendiri; TEK `R*` untuk yang terkait WO aktif | **ADM** (INSERT/UPDATE; nonaktif bukan hapus, FR-015). Perubahan kontrak memicu `tg_contract_changed` (BR-026) tanpa endpoint | Trigger audit mengisi `audit_logs`. |
| `items`, `stock_locations` | Staf; TEK lewat `v_items_catalog` (tanpa harga) | **GDG** | |
| `business_calendars`, `calendar_hours`, `calendar_holidays`, `sla_policy_sets`, `sla_policies`, `escalation_rules`, `app_settings`, `priorities`, `reason_codes` | ADM, DSP, SPV, OWN (baca) | **OWN** (D21; OQ-12 belum diputuskan) | Tanpa angka di seed (D14, D25). |
| `customer_invitations` | ADM, OWN | **ADM** (INSERT/UPDATE) | Pembuatan token + email lewat Jalur B (`POST /customers/{id}/invitations`). |
| `service_requests` | PLG `R*`; staf | **PLG INSERT** kolom `id, customer_id, site_id, asset_id, problem_type_id, description, preferred_start, preferred_end, channel, client_request_id`; **PLG UPDATE** kolom `description, preferred_*, problem_type_id, site_id, asset_id, status` (trigger membatasi `status` ke batal atau melengkapi info) | Batas laju `RL001` dan peringatan duplikat (`duplicate_of`) di trigger. **Pemesanan, pembatalan oleh pelanggan, dan melengkapi info = Jalur A** (G-02). Keputusan ADM lewat RPC `request_decide`. |
| `request_attachments` | PLG `R*`; staf | PLG/ADM INSERT `id, request_id, customer_id, storage_path, mime, bytes, checksum` (path wajib prefix `{customer_id}/req/{request_id}/`) | `upload_status` hanya server. |
| `customer_requests`, `customer_work_orders`, `customer_wo_timeline`, `customer_extra_cost_approvals`, `customer_wo_photos`, `customer_service_reports` | **PLG hanya lewat view ini** | - | Kolom internal sengaja tidak ada (05 bagian 5.1). `display_status`, `awaiting_customer_action`, `pending_approval_id`, `wo_version` tersedia. |
| `work_orders`, `wo_status_history`, `wo_assignments`, `wo_visits`, `wo_checklist_items`, `wo_findings`, `wo_attachments`, `wo_signatures`, `sla_events`, `sla_pauses`, `service_reports` | Staf menurut peran; **TEK `R*`** untuk WO di `my_active_wo_ids()` | Lihat baris lapangan di bawah | `work_orders` tidak punya policy tulis; status berubah hanya lewat RPC. |
| `tech_wo_labor_lines`, `tech_wo_part_usages`, `tech_extra_cost_approvals`, `v_items_catalog`, `v_tech_asset_service_history` | TEK | - | Tanpa harga/total (D16). |
| `part_requests`, `part_request_lines`, `part_returns`, `stock_balances`, `stock_movements`, `parts_variances`, `v_wh_part_requests`, `v_open_part_variances` | GDG, SPV, DSP, FIN, OWN; TEK lokasi sendiri | Tidak ada (RPC) | |
| `invoices`, `invoice_lines`, `payments`, `v_finance_ready_to_bill`, `v_kpi_sla_monthly` | FIN, ADM, SPV, OWN; PLG invoice `ISSUED/PAID` miliknya | **FIN** (sementara; RPC penerbitan TODO di 04, G-10) | Dashboard Lapis 3 selain `v_kpi_sla_monthly` belum ada. |
| `notifications` | Pemilik baris | `UPDATE read_at, status` oleh pemilik | Realtime hanya tabel (bukan view), lihat 8.1. |
| `notification_prefs`, `profiles` (`full_name`, `phone`) | Pemilik | Pemilik | |
| `ratings`, `complaints` | PLG `R*` | **PLG INSERT** (`wo_id, score, comment`; `wo_id, description`); ADM/SPV UPDATE `complaints` | Pelanggan tidak membuat WO rework (D09). |
| `audit_logs`, `access_logs`, `job_runs` | OWN (SPV terbatas; ADM `job_runs`) | Tidak ada | Append-only (IMM01). |
| `sync_operations` | Pemilik/staf | TEK INSERT `op_id, device_id, user_id, wo_id, type, seq, schema_version, payload, client_captured_at` | Status/hasil oleh API (G-06). |

**Tulis data lapangan teknisi (Jalur A, hak kolom sempit; WO harus editable)**

| Tabel | Hak TEK | Catatan |
|---|---|---|
| `wo_checklist_items` | UPDATE `value, is_na, na_reason, client_captured_at, op_id` per `id` | Baris dibuat server (`app.instantiate_checklist`). |
| `wo_findings` | INSERT/UPDATE `diagnosis, action_taken, recommendation, internal_note` | Satu baris per WO (`wo_id` unik). |
| `wo_attachments` | INSERT `id, wo_id, kind, storage_path, mime, bytes, checksum, taken_at, op_id, extra_approval_id`; UPDATE `deleted_at` | `id` klien = kunci idempotensi `ADD_PHOTO`. `kind` termasuk `FAILED_VISIT`. |
| `wo_signatures` | INSERT `id, wo_id, signer_type, signer_name, storage_path, signed_via, device_meta, op_id` | `content_hash` diisi trigger. |
| `wo_labor_lines` | INSERT `id, wo_id, service_item_id, description, qty, is_extra, extra_approval_id, emergency, emergency_reason, op_id`; UPDATE `deleted_at` | **Wajib `Prefer: return=minimal`**: SELECT tabel mentah tertutup bagi TEK sehingga `RETURNING`/`.select()` gagal (D16). |
| `wo_part_usages` | INSERT `id, wo_id, item_id, qty, is_extra, extra_approval_id, emergency, emergency_reason, source_location_id, op_id`; UPDATE `deleted_at` | Idem. Mutasi `CONSUME_ON_WO` oleh trigger; `STK01`/`unsourced` mengikuti 04. |

**RPC yang boleh dipanggil langsung (`/rest/v1/rpc/<nama>`)**: `wo_transition`, `request_decide`, `extra_cost_request`, `extra_cost_decide`, `wo_customer_sign`, `wo_request_help`, `wo_add_helper`, `wo_request_cancel`, `wo_change_priority`, `wo_override_billing`, `wo_create_rework`, `wo_cost_summary`, `wo_set_estimate`, `pm_period_resolve`, `part_request_create`, `part_request_decide`, `part_issue`, `part_return_create`, `part_return_confirm`, `stock_receive`, `stock_adjust`, `parts_variance_resolve`, `log_data_access`, `register_individual_customer`, `accept_customer_invitation`, `admin_set_user_roles`, `admin_set_user_active`. Galat PostgREST berbentuk `{code: "WO003", message, details}`; fasad Jalur B menerjemahkannya (bagian 4.4).

### 2.3 Jalur B: Route Handler (+ Server Action tipis di web back-office)

**Mengapa Route Handler dan bukan Server Action sebagai kontrak utama** [A]: PWA teknisi mengirim dari antrean/service worker dan harus bisa memanggil HTTP biasa; Server Action terikat ke React dan tidak cocok untuk Background Sync atau uji kontrak. Server Action hanya pembungkus tipis di web back-office yang memanggil fungsi domain yang sama.

Alur satu permintaan Jalur B (05 bagian 6):

1. Validasi sesi Supabase (JWT) dan bentuk body (skema = `openapi.yaml`); gagal cepat 401/422/413.
2. Rate limit tepi (IP) bila berlaku.
3. Memanggil RPC/tabel **dengan JWT pengguna** (default; `auth.uid()` menjadi aktor di audit, `wo_transition` mensyaratkannya). `Idempotency-Key` -> `p_op_id`; `If-Match` -> `p_expected_version`.
4. Galat Postgres dipetakan ke Problem Details (tabel 4.4).
5. `service_role` **hanya** untuk daftar tertutup 05 bagian 6.3: (a) signed upload URL dan menandai `UPLOADED`, (b) `auth.admin.*` dan pencabutan sesi, (c) bootstrap OWNER, (d) pengirim notifikasi, (e) render PDF, (f) penjadwal cadangan `app.run_job`, (g) retensi. Tiap rute service role memverifikasi sesi dan kepemilikan lebih dulu lewat klien ber-JWT. Rute `POST /sync/push` memerlukan penulisan `sync_operations.status/result` oleh service role yang **belum ada** di daftar itu (G-06).

### 2.4 Tabel keputusan per fitur kritis

| Fitur | Jalur | Alasan |
|---|---|---|
| Transisi status WO (T-01..T-27) | **A (RPC) / B (fasad)** | `wo_transition` satu-satunya pintu; fasad B memberi RFC 9457 dan `Idempotency-Key`. PWA teknisi memakai `/sync/push`. |
| Penutupan WO | **A/B** (`SUBMIT_REVIEW`, `APPROVE_CLOSE`) | BR-040/042 dievaluasi di `app.wo_submit_deficiencies`, mengembalikan semua kekurangan (WO003). |
| Persetujuan biaya | **A/B** (`extra_cost_request`, `extra_cost_decide`) | Versi + `content_hash`, bukti atas nama pelanggan; `wo_transition` menolak T-12/T-13/T-15 tanpa keputusan tercatat (D08). |
| Stok | **A/B** (RPC `part_*`, `stock_*`) | Ledger append-only, `STK01`. |
| Pembuatan WO dari permintaan | **A/B** (`request_decide`) | Nomor WO, billing, SLA dalam satu transaksi. |
| Pembuatan permintaan | **A** (INSERT `service_requests`) | RLS + hak kolom + trigger (batas laju, duplikat, idempotensi `client_request_id`). Batas IP di tepi tidak mungkin (G-02). |
| Unggah/unduh berkas | **B** | Signed URL, verifikasi, `access_logs`; tanpa policy tulis di Storage (D19). |
| Sinkron offline | **B** | Batch, `seq`, penyelamatan draf. |
| Undangan, pengguna staf | **B** | Token, email, `auth.admin`. |
| Job SLA/PM/notifikasi/PDF | **B (internal)** | Worker dan cadangan `pg_cron`. |
| Daftar, detail, filter | **A** | RLS + view. |
| Master data, konfigurasi, kontrak | **A** | CRUD biasa + trigger audit. |

---

## 3. Autentikasi dan Otorisasi

### 3.1 Identitas

| Pengguna | Metode masuk | Pembuatan akun | Catatan |
|---|---|---|---|
| Staf | Email + kata sandi (Supabase Auth). Pemulihan lewat Auth (FR-003) | `POST /admin/staff-users` (ADM atau OWN): `auth.admin` + `admin_set_user_roles`. Peran pertama OWNER di-bootstrap lewat service role/SQL (D22) | **[U]** TOTP MFA untuk ADM, FIN, OWN. |
| Pelanggan | OTP email (magic link/kode) atau undangan; kata sandi opsional | Undangan ADM, atau registrasi mandiri **perorangan** | Mode `registration.mode` = `SELF` / `INVITE` / `BOTH` di `app_settings`; NULL = registrasi mandiri mati (D1, Q1 belum diputuskan). |

Alur pelanggan:

- **Undangan**: ADM `POST /customers/{customerId}/invitations` -> server membuat token acak, menyimpan `token_hash` di `customer_invitations`, mengirim email. Pelanggan membuka tautan, masuk (Auth), lalu `POST /me/invitations/accept` -> RPC `accept_customer_invitation(p_token, p_policy_version)`: menautkan `customer_users`, memberi peran `CUSTOMER`, mencatat `user_consents`. Galat seragam `WO005` (-> `INVITATION_INVALID`).
- **Registrasi mandiri (perorangan)**: `POST /auth/registrations` (captcha, rate limit, OTP) -> setelah verifikasi `POST /me/registration` -> RPC `register_individual_customer(p_full_name, p_phone, p_policy_version)` membuat `customers` bertipe `INDIVIDUAL`, `customer_users` (`ADMIN`), peran, dan consent. **Pelanggan korporat tidak punya jalur mandiri di 04**; hanya undangan (draf 0.1 mengusulkan penautan ADM; dihapus).
- Pergantian karyawan pelanggan (R11): Lapis 1 ADM menonaktifkan/mengundang; UI/RPC admin pelanggan = TODO Lapis 3 di 05 (G-10).
- Persetujuan kebijakan (NFR-D2) hanya tercatat saat registrasi/undangan; tidak ada RPC consent ulang (G-11).

### 3.2 Sumber otorisasi: tabel, bukan klaim JWT (D01)

RLS dan RPC membaca peran dan keanggotaan dari tabel: `app.my_roles()`, `app.has_any_role()`, `app.my_customer_ids()` (via `customer_users`), `app.my_technician_id()`, `app.my_active_wo_ids()`, `app.my_editable_wo_ids()`. Pengguna `profiles.is_active = false` mendapat himpunan kosong dari semua helper, jadi akses hilang seketika tanpa menunggu token kedaluwarsa (FR-007). Setelah `admin_set_user_active`, API server memanggil `auth.admin.signOut` untuk mencabut sesi.

Custom Access Token Hook boleh dipasang, tetapi isinya **hanya petunjuk UI** (peran untuk menu, `customer_ids`, `technician_id`). Tidak ada endpoint, RPC, atau policy yang boleh mempercayainya. Contoh isi:

```json
{ "sub": "4a1d0c52-7a43-4b0e-9c0f-5d0f0e2b9a10", "role": "authenticated",
  "app_metadata": { "roles": ["DISPATCHER"], "hint_only": true } }
```

Klaim `role` tingkat atas tetap `authenticated` (dipakai Postgres/PostgREST). `raw_user_meta_data` dapat diubah pengguna dan tidak pernah dipakai untuk otorisasi (05 bagian 9). `CUSTOMER` eksklusif terhadap peran staf (trigger `tg_user_roles_exclusive`); satu staf boleh banyak peran (D03).

### 3.3 Lapisan otorisasi

| Lapis | Mekanisme | Hasil bila gagal |
|---|---|---|
| 1. Route Handler | Sesi valid; peran kasar dari `GET /me` di-cache pendek (gagal cepat) | 401 `UNAUTHENTICATED`, 403 `FORBIDDEN_ROLE` |
| 2. RPC | `app.has_any_role`, `resolve_actor_roles(wo)`, kepemilikan, guard status | `WO002` -> 403, `WO005` -> 404, `WO001/3/4` |
| 3. RLS / hak kolom | Policy per tabel/view | Baris tidak terlihat; `42501` untuk `anon` |

Aturan 403 vs 404: bila WO/permintaan **ada tetapi di luar cakupan** pemanggil, RPC mengembalikan `WO005` (404 seragam, NFR-S10); `WO002` (403) hanya bila peran pemanggil memang tidak boleh melakukan aksi itu pada sumber daya yang terlihat olehnya.

### 3.4 Cakupan data per peran

| Peran | Cakupan | Penegak |
|---|---|---|
| PLG | `customer_id = ANY(my_customer_ids())`; hanya lewat view `customer_*` untuk WO; tanpa `billing_*`, `estimate_*`, `policy_snapshot`, `internal_note`, `unit_cost`, `help_*` (05 bagian 5.1). Nama dan jadwal teknisi baru tampil setelah teknisi menerima (DEC-02) | View `security_barrier` + RLS |
| TEK | WO dengan penugasan `ASSIGNED/ACCEPTED/COMPLETED/CANCELLED` (`my_active_wo_ids`); tulis lapangan hanya bila editable (penugasan ACCEPTED dan WO `IN_PROGRESS/ON_HOLD_PARTS/AWAITING_CUSTOMER_APPROVAL`); `REJECTED/RELEASED/REASSIGNED` -> hilang (CONFLICT_REASSIGNED) | RLS `my_active_wo_ids`, `can_edit_wo` |
| ADM, DSP, SPV, GDG, FIN, OWN | Global (AS-01), per matriks 05 bagian 3 | RLS + pemeriksaan di RPC |
| SYS | Job dan webhook | Rahasia server / HMAC |

### 3.5 Ringkasan kemampuan per peran

| Peran | Dapat (ringkas) |
|---|---|
| PLG | INSERT permintaan/rating/komplain (Jalur A), baca view `customer_*`; Jalur B: registrasi, terima undangan, unggah, batal/ajukan batal WO, keputusan biaya, tanda tangan PWA, URL unduh. |
| ADM | Master data, undangan, `request_decide`, batal WO NEW..EN_ROUTE, ubah prioritas/estimasi, keputusan biaya atas nama (bukti), `pm_period_resolve`, `wo_create_rework`, impor. |
| DSP | `ASSIGN`, `REASSIGN`, `RELEASE`, `RESUME_PARTS`, helper, prioritas, batal NEW..EN_ROUTE, permintaan suku cadang. |
| TEK | `ACCEPT`..`SUBMIT_REVIEW`, `VISIT_FAILED`, `REQUEST_EXTRA_COST`, tulis lapangan (Jalur A), permintaan/retur suku cadang, sinkron. |
| SPV | `APPROVE_CLOSE`, `RETURN`, `CANCEL_ACTIVE`, `wo_override_billing`, `stock_adjust` di atas ambang, resolusi selisih penuh. |
| GDG | `part_request_decide`, `part_issue`, `part_return_confirm`, `stock_receive`, `stock_adjust` (bawah ambang), resolusi selisih (EXPLAINED/RETURNED_LATE). |
| FIN | Invoice/pembayaran (Jalur A sementara). |
| OWN | Baca luas, konfigurasi SLA/kalender/setting, peran (OWNER/ADMIN_CS). |

### 3.6 Berkas dan Storage (05 bagian 5.2)

- Bucket privat `wo-media` (gambar) dan `reports` (PDF). Path: `{customer_id}/req/{request_id}/{file}` dan `{customer_id}/wo/{wo_id}/{file}` (D18); path yang tidak cocok regex ditolak `app.can_read_object`.
- **Tidak ada policy INSERT/UPDATE/DELETE di `storage.objects`.** Alur: (1) klien INSERT baris metadata (path wajib berprefix miliknya, `upload_status=PENDING`); (2) `POST /uploads/sign` (server membaca baris dengan JWT, menyetujui, membuat signed upload URL dengan service role); (3) klien `PUT`; (4) `POST /uploads/complete` -> server memverifikasi magic bytes, ukuran, `sha256`, lalu menandai `UPLOADED`.
- Unduh: `POST /files/download-urls` -> signed URL berumur pendek; akses staf ke data pelanggan dicatat dengan RPC `log_data_access` (FR-171). Pelanggan hanya melihat foto `BEFORE/AFTER/FINDING` yang `UPLOADED` dari WO `CLOSED`, tanda tangan `VALID`, laporan `READY`; `OTHER/FAILED_VISIT` tidak pernah terlihat.
- EXIF lokasi pada foto pelanggan dibuang di klien (NFR-D4).

### 3.7 Endpoint internal

`/internal/jobs/{job}` memakai `Authorization: Bearer <CRON_SECRET>`; `/internal/webhooks/{provider}` memakai HMAC-SHA256 (`X-Vasta-Signature: t=<unix>,v1=<hex>` atas `"<t>.<raw body>"`, toleransi waktu [P]). Keduanya tidak untuk pengguna dan dapat dibatasi jaringan [A].

---

## 4. Konvensi

### 4.1 Versi dan kompatibilitas

- Jalur B: prefiks **`/api/v1`**. Perubahan aditif tidak menaikkan versi; klien mengabaikan field tak dikenal. Perubahan merusak -> `/api/v2` berdampingan; `v1` ditandai `Deprecation`/`Sunset` selama masa transisi [P].
- Jalur A: kontrak adalah **view** (`customer_*`, `tech_*`, `v_*`) dan **RPC** `public.*`. View hanya boleh bertambah kolom; perubahan merusak = view/RPC baru (kontrak sulit diubah, D17). Tabel mentah bukan kontrak untuk PLG.
- Skema `app` bukan kontrak.
- Sinkron: `schema_version` di amplop; terlalu lama -> 426 tanpa menghapus antrean (02 bagian 6.6).

### 4.2 Format umum

- JSON UTF-8; `snake_case`. Enum persis 04 (`NEW`, `AWAITING_CUSTOMER_APPROVAL`, `COVERED_CONTRACT`, `RECEIVED`, dan seterusnya).
- ID `uuid`. Waktu ISO 8601 UTC. Tanggal murni `YYYY-MM-DD` dalam zona kalender kontrak (BR-028; default `Asia/Jakarta`, D26).
- Uang: `{ "amount": "150000.00", "currency": "IDR" }`, string desimal (kolom `numeric(14,2)`); mata uang tunggal implisit (D24).
- `Cache-Control: private, no-store` untuk JSON; `X-Request-Id` pada setiap respons (dari klien atau dibuat server) dan masuk Problem Details serta `audit_logs.request_id`.
- `detail` berbahasa Indonesia sederhana; `code` adalah kontrak.

### 4.3 Pagination, filter, urut

**Jalur A (PostgREST)**: daftar besar memakai keyset (`order=created_at.desc,id.desc&limit=N` + kondisi `or=(created_at.lt.<ts>,and(created_at.eq.<ts>,id.lt.<id>))`), bukan `offset`; tabel master kecil boleh `limit`/`offset` atau `Range`. `Prefer: count=estimated`. `limit` default dan `max-rows` = [P]. Filter operator PostgREST: `status=in.(NEW,ASSIGNED)`, `scheduled_start=gte.<ts>`. Indeks pendukung: `ix_wo_customer_status`, `ix_sr_customer`, dan lainnya (05 bagian 8). View `security_barrier` menghambat sebagian optimasi (05 bagian 8): beri filter bernilai tinggi (`wo_id`, `display_status`).

**Jalur B**: respons daftar `{ "data": [...], "page": { "next_cursor", "has_more", "limit" } }`, `cursor` opaque (keyset), `limit` [P]. Cursor rusak -> 400/422 `VALIDATION_FAILED` dengan `errors[].pointer=/cursor`. Saat ini hanya `GET /sync/pull` yang berpaginasi di Jalur B.

### 4.4 Format galat (RFC 9457) dan pemetaan dari 04

`Content-Type: application/problem+json`. Field: `type`, `title`, `status`, `detail`, `instance` + ekstensi `code`, `request_id`, opsional `errors[]`, `unmet[]`, `warnings[]`, `allowed_actions[]`, `current_version`, `current_status`, `retry_after_seconds`, `db_sqlstate`.

Pemetaan galat RPC (SQLSTATE kustom di header 04; `DETAIL` berisi jsonb):

| SQLSTATE | HTTP | `code` | Sumber isi |
|---|---|---|---|
| `WO001` | 409 | `INVALID_TRANSITION` (atau `DATA_IMMUTABLE` untuk WO final) | `allowed_actions` dari `wo_transitions` untuk status saat ini |
| `WO002` | 403 | `FORBIDDEN_ROLE` (`REGISTRATION_DISABLED` untuk registrasi) | |
| `WO003` | 422 | `DETAIL.code` bila objek (mis. `SOFT_GUARD`, `GPS_OR_REASON_REQUIRED`); `CLOSURE_REQUIREMENTS_NOT_MET` bila `DETAIL` berupa array -> `unmet[]` | `DETAIL.warnings` -> `warnings[]` |
| `WO004` | 409 | `DETAIL.code` bila ada (`APPROVAL_VERSION_STALE`, `APPROVAL_STALE`, `APPROVAL_EXPIRED`); selain itu `VERSION_CONFLICT` | `DETAIL` -> `current_version`, `current_status` |
| `WO005` | 404 | `NOT_FOUND` (`INVITATION_INVALID` untuk undangan) | seragam, tanpa membedakan |
| `WO006` | 422 | `VALIDATION_FAILED` | |
| `STK01` | 409 | `INSUFFICIENT_STOCK` | |
| `RL001` | 429 | `RATE_LIMITED` | |
| `IMM01` | 409 | `DATA_IMMUTABLE` | |
| `42501` | 403 | `FORBIDDEN_ROLE` | hak tabel/kolom dicabut |

```json
HTTP/1.1 409 Conflict
Content-Type: application/problem+json

{
  "type": "/problems/invalid-transition",
  "title": "Transisi status tidak diizinkan",
  "status": 409,
  "detail": "WO berstatus ASSIGNED; check-in belum bisa dilakukan. Terima tugas lebih dulu.",
  "instance": "/api/v1/work-orders/b0b0b0b0-0000-4000-8000-000000000001/check-in",
  "code": "INVALID_TRANSITION",
  "db_sqlstate": "WO001",
  "request_id": "req_01JABCXYZ",
  "current_status": "ASSIGNED",
  "allowed_actions": ["ACCEPT", "REJECT", "REASSIGN", "CANCEL"]
}
```

Aturan: tidak membocorkan keberadaan data pelanggan lain; tidak mengirim jejak tumpukan; 5xx hanya `request_id`. Katalog kode di bagian 5.

### 4.5 Idempotensi

| Mekanisme | Dipakai oleh | Kunci | Penegak di 04 | Perilaku ulang |
|---|---|---|---|---|
| Header `Idempotency-Key` = `p_op_id` | Fasad Jalur B untuk `wo_transition`, `extra_cost_request`, `extra_cost_decide`, `wo_customer_sign`, `cancel-requests` | UUID v7 buatan klien | `uq_wsh_op` (op unik per WO di `wo_status_history`) | `replayed=true` dengan hasil sebelumnya |
| `op_id` operasi sinkron | `/sync/push` | `ops[].op_id` | `sync_operations.op_id` PK + kolom `op_id` di tabel lapangan | Hasil tersimpan dikembalikan |
| `client_request_id` | INSERT `service_requests` | Kolom | `UNIQUE (customer_id, client_request_id)`; retry tidak dihitung batas laju | Satu baris; klien membaca ulang |
| `id` buatan klien | Foto, tanda tangan, jasa, pemakaian, lampiran | UUID | PK tabel | Konflik PK -> diperlakukan sudah diterapkan |
| Constraint domain | PM, eskalasi SLA, invoice, WO per permintaan | `uq_wo_preventive_period`, `uq_sla_events_*`, `uq_wo_request`, `pm_periods` unik | Database | `ON CONFLICT DO NOTHING`; job aman dijalankan ganda |

**Tidak ada** tabel `idempotency_keys`. RPC tanpa `p_op_id` (`part_request_create`, `part_return_create`, `wo_request_help`, `stock_receive`, `stock_adjust`, `part_issue`) tidak idempoten di level DB; replay sinkron mengandalkan `sync_operations.op_id` (G-03, G-06). `Idempotency-Key` wajib hanya pada endpoint yang kolom "Idem-Key" bertanda W di bagian 6; tanpa itu -> 400 `IDEMPOTENCY_KEY_REQUIRED`.

### 4.6 Konkurensi

`If-Match: "<version>"` pada fasad = `p_expected_version` (`work_orders.version`, `service_requests.version`). Kosong pada aksi back-office -> 428 `PRECONDITION_REQUIRED`. Tidak cocok -> 409 `VERSION_CONFLICT` (`WO004`) dengan `current_version` dan `current_status`. `wo_transition` mewajibkan `expected_version` (`WO004: expected_version wajib`); karena itu pada aksi teknisi `If-Match`/`base_version` dikirim PWA dari cache dan konflik ditafsirkan per kategori data (bagian 7.4), bukan sebagai kegagalan mentah. Keputusan biaya tidak memakai versi WO; ia memakai `content_hash`.

### 4.7 Rate limit

Tujuan: mencegah pesanan sembarangan dan pendaftaran palsu (FR-005, FR-025, NFR-S8, BR-072, R8). **Semua angka adalah [P] dan belum ditetapkan** (`rate_limit.service_request.max/window_seconds` bernilai NULL di `app_settings`; `app.rate_limit_hit` mengizinkan semua bila NULL).

| Kebijakan | Titik | Dimensi | Penegak |
|---|---|---|---|
| `service_request` | INSERT `service_requests` (Jalur A) | per `customer_id` | Trigger `tg_sr_before_insert` + tabel `rate_limits` -> `RL001` -> 429. **Tanpa batas IP** (G-02) |
| `registration` | `POST /auth/registrations` | IP, email | Tepi + Supabase Auth + captcha |
| `upload` | `POST /uploads/sign` | per pengguna, per permintaan/WO | Tepi; jumlah per WO [P] |
| `sync` | `POST /sync/push`, `GET /sync/pull` | per `device_id` | Tepi; longgar |
| `download_urls` | `POST /files/download-urls` | per pengguna | Tepi |

Respons Jalur B: 429 `RATE_LIMITED` + `Retry-After` + `RateLimit-Limit/Remaining/Reset` [A]. PWA yang mendapat 429 menunda sesuai `Retry-After` dan tidak menghapus antrean.

### 4.8 Validasi dan keamanan HTTP

Ukuran body maksimum per endpoint [P]; foto tidak lewat JSON; tanda tangan lewat Storage (bukan base64). `Content-Type: application/json` wajib. CORS hanya origin aplikasi. CSP dan header keamanan (NFR-S9). Input divalidasi dengan skema yang sama dengan `openapi.yaml`.

---

## 5. Katalog Kode Error Domain

`code` adalah kontrak stabil; `detail` boleh berubah. Kolom "Asal" menunjuk SQLSTATE 04 (atau `-` bila dihasilkan lapisan API).

| Kode | HTTP | Asal di database | Arti |
|---|---|---|---|
| `VALIDATION_FAILED` | 422 | WO006 | Body/parameter tidak lolos validasi atau RPC `WO006`; rincian di errors[]. |
| `UNAUTHENTICATED` | 401 | - | Token tidak ada, kedaluwarsa, atau tidak valid. |
| `ACCOUNT_INACTIVE` | 403 | - | Pengguna dinonaktifkan; RLS menolak seketika (FR-007). |
| `FORBIDDEN_ROLE` | 403 | WO002 | Peran pemanggil tidak berhak (RPC `WO002`). |
| `NOT_FOUND` | 404 | WO005 | Tidak ada ATAU bukan milik/di luar cakupan pemanggil, seragam (RPC `WO005`, NFR-S10). |
| `INVALID_TRANSITION` | 409 | WO001 | Aksi tidak ada di `wo_transitions` untuk status saat ini (`WO001`); body memuat allowed_actions. |
| `VERSION_CONFLICT` | 409 | WO004 | `expected_version` tidak cocok (`WO004`); body memuat current_version dan current_status. |
| `PRECONDITION_REQUIRED` | 428 | WO004 | If-Match (expected_version) wajib namun tidak dikirim. |
| `IDEMPOTENCY_KEY_REQUIRED` | 400 | - | Idempotency-Key (menjadi p_op_id) wajib untuk endpoint ini. |
| `DATA_IMMUTABLE` | 409 | IMM01 | WO sudah CLOSED/CANCELLED atau tabel append-only (`IMM01`, BR-044). |
| `INSUFFICIENT_STOCK` | 409 | STK01 | Stok tidak cukup; saldo tidak boleh negatif (`STK01`, BR-030). |
| `RATE_LIMITED` | 429 | RL001 | Batas laju terlampaui (`RL001` atau limiter tepi); lihat Retry-After. |
| `PAYLOAD_TOO_LARGE` | 413 | - | Ukuran body/berkas melebihi batas [P]. |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | - | Content-Type/MIME tidak didukung. |
| `APP_UPDATE_REQUIRED` | 426 | - | schema_version klien terlalu lama; antrean klien TIDAK boleh dihapus. |
| `DEPENDENCY_UNAVAILABLE` | 503 | - | Layanan pendukung (Storage, email) tidak tersedia; aman diulang. |
| `REASON_REQUIRED` | 422 | WO003 | Alasan/catatan wajib. |
| `TECHNICIAN_INVALID` | 422 | WO003 | Teknisi tidak ada atau tidak aktif. |
| `SCHEDULE_REQUIRED` | 422 | WO003 | Jadwal final wajib (T-02). |
| `SOFT_GUARD` | 422 | WO003 | Peringatan lunak penugasan (SKILL_MISMATCH, SCHEDULE_OVERLAP); ulangi dengan override_reason. DETAIL memuat warnings[] (D20). |
| `ALREADY_CHECKED_IN` | 422 | WO003 | Sudah check-in; gunakan serah-terima, bukan release. |
| `NOT_SCHEDULED_TODAY` | 422 | WO003 | Bukan hari jadwal dalam toleransi [P] (T-07). |
| `GPS_OR_REASON_REQUIRED` | 422 | WO003 | Check-in wajib lat+lng atau no_gps_reason (FR-053). |
| `NO_OPEN_PART_REQUEST` | 422 | WO003 | Tidak ada permintaan suku cadang terbuka (T-09). |
| `PART_REQUEST_OPEN` | 422 | WO003 | Permintaan suku cadang masih terbuka (T-10). |
| `EXTRA_COST_REQUEST_MISSING` | 422 | WO003 | Belum ada pengajuan biaya tambahan PENDING berisi item (T-11). |
| `APPROVAL_DECISION_MISSING` | 422 | WO003 | Keputusan persetujuan belum tercatat; gunakan extra_cost_decide (D08). |
| `NO_BLOCKING_REJECTION` | 422 | WO003 | Tidak ada penolakan yang menghalangi lingkup awal (T-14). |
| `OUTCOME_INVALID` | 422 | WO003 | T-14 mensyaratkan outcome PARTIAL atau UNRESOLVED. |
| `EXCEPTION_NOTE_REQUIRED` | 422 | WO003 | Catatan pengecualian penutupan wajib (BR-041). |
| `CLOSURE_REQUIREMENTS_NOT_MET` | 422 | WO003 | Syarat BR-040 belum lengkap; unmet[] berisi SEMUA kekurangan (DETAIL berupa array jsonb). |
| `CLOSURE_EXCEPTION_NOT_APPROVED` | 422 | WO003 | Pengecualian penutupan wajib disetujui eksplisit SPV (approve_exception, BR-041). |
| `FAILED_VISIT_EVIDENCE_MISSING` | 422 | WO003 | Kunjungan gagal wajib satu foto kind FAILED_VISIT. |
| `ON_BEHALF_EVIDENCE_REQUIRED` | 422 | WO003 | Keputusan atas nama pelanggan wajib bukti dan kanal non-PWA (BR-053). |
| `EXTRA_COST_NOT_APPROVED` | 422 | WO003 | Jasa/pemakaian is_extra tanpa extra_approval_id berstatus APPROVED pada WO yang sama, kecuali emergency (BR-052). Muncul dari trigger saat INSERT lapangan. |
| `ASSET_REQUIRED` | 422 | WO003 | Aset wajib sebelum permintaan disetujui. |
| `SERVICE_TYPE_REQUIRED` | 422 | WO003 | Jenis layanan wajib. |
| `PRIORITY_REQUIRED` | 422 | WO003 | Prioritas wajib (jenis layanan tak punya default). |
| `APPROVAL_STALE` | 409 | WO004 | Persetujuan tidak lagi PENDING atau WO tidak lagi menunggu (mis. SUPERSEDED). |
| `APPROVAL_VERSION_STALE` | 409 | WO004 | content_hash tidak sama dengan versi saat ini (BR-051); tampilkan ulang. |
| `APPROVAL_EXPIRED` | 409 | WO004 | Persetujuan kedaluwarsa (BR-055). |
| `UPLOAD_TYPE_NOT_ALLOWED` | 415 | - | MIME/magic bytes tidak diizinkan (NFR-S7). |
| `UPLOAD_TOO_LARGE` | 413 | - | Ukuran melebihi batas [P]. |
| `UPLOAD_LIMIT_EXCEEDED` | 422 | - | Jumlah berkas melebihi batas per permintaan/WO [P]. |
| `UPLOAD_NOT_FOUND` | 409 | - | Objek belum ada di Storage saat complete dipanggil. |
| `CHECKSUM_MISMATCH` | 422 | - | sha256/ukuran objek tidak cocok dengan metadata; unggah ulang. |
| `UPLOAD_PATH_INVALID` | 422 | - | storage_path pada baris metadata tidak berprefix kepemilikan (konvensi D18). |
| `CAPTCHA_FAILED` | 422 | - | Verifikasi captcha gagal. |
| `REGISTRATION_DISABLED` | 403 | WO002 | registration.mode belum mengizinkan registrasi mandiri (D1). |
| `INVITATION_INVALID` | 404 | WO005 | Undangan tidak valid/kedaluwarsa/email tidak cocok, pesan seragam. |
| `EMAIL_ALREADY_REGISTERED` | 409 | - | Hanya ke staf berhak; registrasi mandiri tidak membocorkan keberadaan akun. |
| `CONFLICT_CANCELLED` | 409 | WO001/IMM01 | WO dibatalkan saat teknisi offline; operasi disimpan sebagai RESCUED. Muncul di results[].code (HTTP tetap 200). |
| `CONFLICT_REASSIGNED` | 409 | WO005/WO002 | WO ditugaskan ulang saat offline (WO keluar dari my_active_wo_ids). Muncul di results[].code (HTTP tetap 200). |
| `SEQ_GAP` | 409 | - | Celah seq; operasi ditahan (HELD) sampai expected_seq diterima. Muncul di results[].code (HTTP tetap 200). |
| `WO_NOT_CLOSED` | 409 | - | WO belum CLOSED. |
| `WO_NOT_BILLABLE` | 409 | - | WO NOT_BILLABLE (BR-065). |
| `ALREADY_INVOICED` | 409 | - | Baris sudah ditagih (UNIQUE source_type, source_id). |
| `INVOICE_NOT_DRAFT` | 409 | - | Invoice bukan DRAFT. |
| `IMPORT_HAS_ERRORS` | 409 | - | Impor memiliki baris galat; perbaiki berkas. |

---

## 6. Daftar Endpoint Jalur B per Modul

Path relatif terhadap `/api/v1`. **Peran** memakai singkatan (tabel 0.2); **Lp** = lapis produk; **If-Match**: W wajib, o opsional; **Idem-Key**: W = `Idempotency-Key` wajib (menjadi `p_op_id`). Baris *DB* menunjukkan RPC/tabel pendukung dengan nama persis 04. Galat generik 401/403/404/429 tidak diulang di kolom kode. Pembacaan, pembuatan permintaan, dan tulis data lapangan ada di Jalur A (bagian 2.2).

### 6.1 Peta transisi 02 ke aksi `wo_transition` dan endpoint

| Transisi | Aksi `wo_transition` | Endpoint / mekanisme |
|---|---|---|
| T-01 | (RPC `request_decide` APPROVE) | `POST /service-requests/{id}/approve`; auto-approve SYSTEM_RULE oleh trigger (SP-02) |
| T-02 | `ASSIGN` | `POST /work-orders/{id}/assign` |
| T-03 | `ACCEPT` | `POST .../accept` |
| T-04 | `REJECT` | `POST .../reject-assignment` |
| T-05 | `REASSIGN` | `POST .../reassign` |
| T-06 | `RELEASE` | `POST .../release` |
| T-07 | `DEPART` | `POST .../depart` |
| T-08 | `CHECK_IN` | `POST .../check-in` |
| T-09 / T-10 | `HOLD_PARTS` / `RESUME_PARTS` | `POST .../hold-parts` / `POST .../resume-parts` |
| T-11 | `REQUEST_EXTRA_COST` | `POST .../extra-cost-approvals` (RPC `extra_cost_request`) |
| T-12 / T-13 | `APPROVE_EXTRA_COST` / `REJECT_EXTRA_COST` | `POST /extra-cost-approvals/{id}/decision` (RPC `extra_cost_decide`) |
| T-14 | `CLOSE_AFTER_REJECTION` | `POST .../submit` dari `AWAITING_CUSTOMER_APPROVAL` |
| T-15 | `EXPIRE_EXTRA_COST` | job `expire_customer_actions` (SYS) |
| T-16 | `SUBMIT_REVIEW` | `POST .../submit` |
| T-17 | `REQUEST_SIGNOFF` | `POST .../request-signoff` |
| T-18 | `SIGNOFF` / `EXPIRE_SIGNOFF` | `POST .../signoff` (RPC `wo_customer_sign`) / job `expire_customer_actions` |
| T-19 | `APPROVE_CLOSE` | `POST .../review/approve` |
| T-20 / T-21 | `RETURN` / `RESUME_AFTER_RETURN` | `POST .../review/return` / `POST .../resume-after-return` |
| T-22 | `CANCEL`, `CANCEL_BY_CUSTOMER` | `POST .../cancel`; PLG `POST .../cancel-requests` |
| T-23 | `CANCEL_ACTIVE` | `POST .../cancel` (hanya SPV, status berjalan) |
| T-24 | (RPC `request_decide` REJECT; PLG UPDATE status `CANCELLED_BY_CUSTOMER`) | `POST /service-requests/{id}/reject`; Jalur A |
| T-25 | (RPC `wo_create_rework`) | `POST .../rework`; PLG INSERT `complaints` (Jalur A) |
| T-26 | (RPC `wo_request_help`) | `POST .../help-requests` |
| T-27 | `VISIT_FAILED` | `POST .../failed-visit` |

### 6.2 Akun, registrasi, undangan

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /auth/registrations`<br>Mulai registrasi mandiri: captcha + OTP email<br>*DB:* Supabase Auth signInWithOtp (server) | PUB | 1 | - | - | - | - | `CAPTCHA_FAILED`, `RATE_LIMITED`, `VALIDATION_FAILED` |
| `POST /me/registration`<br>Selesaikan registrasi pelanggan perorangan (customer + consent)<br>*DB:* rpc register_individual_customer(p_full_name, p_phone, p_policy_version) | ANY | 1 | - | - | - | - | `REGISTRATION_DISABLED`, `VALIDATION_FAILED`, `INVALID_TRANSITION` |
| `POST /me/invitations/accept`<br>Terima undangan pelanggan (token sekali pakai)<br>*DB:* rpc accept_customer_invitation(p_token, p_policy_version) | ANY | 1 | - | - | - | - | `INVITATION_INVALID`, `VALIDATION_FAILED`, `INVALID_TRANSITION` |
| `GET /me`<br>Profil, peran, keanggotaan pelanggan, dan technician_id pemanggil<br>*DB:* select profiles, user_roles, customer_users, technicians (JWT) | ANY | 1 | - | - | - | - | - |
| `POST /customers/{customerId}/invitations`<br>Buat undangan pelanggan dan kirim email<br>*DB:* insert customer_invitations (token_hash) dengan JWT ADM + kirim email (server) | ADM | 1 | - | - | - | - | `VALIDATION_FAILED`, `NOT_FOUND` |
| `POST /admin/staff-users`<br>Buat pengguna staf lalu tetapkan peran<br>*DB:* auth.admin.inviteUserByEmail (service role) + rpc admin_set_user_roles | ADM, OWN | 1 | - | - | - | - | `EMAIL_ALREADY_REGISTERED`, `FORBIDDEN_ROLE`, `VALIDATION_FAILED` |
| `PATCH /admin/staff-users/{userId}`<br>Ubah peran dan/atau status aktif; sesi dicabut saat dinonaktifkan<br>*DB:* rpc admin_set_user_roles / admin_set_user_active + auth.admin.signOut (service role) | ADM, OWN | 1 | - | - | - | - | `FORBIDDEN_ROLE`, `VALIDATION_FAILED` |

### 6.3 Permintaan servis dan unggahan

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /uploads/sign`<br>Minta signed upload URL untuk baris metadata yang sudah dibuat klien<br>*DB:* baca baris metadata (JWT, RLS membuktikan hak) lalu createSignedUploadUrl (service role, 05 bagian 6a) | PLG, ADM, TEK | 1 | - | - | - | - | `UPLOAD_TYPE_NOT_ALLOWED`, `UPLOAD_TOO_LARGE`, `UPLOAD_LIMIT_EXCEEDED`, `UPLOAD_PATH_INVALID`, `DATA_IMMUTABLE`, `RATE_LIMITED`, `NOT_FOUND` |
| `POST /uploads/complete`<br>Konfirmasi unggahan: server memverifikasi lalu menandai UPLOADED<br>*DB:* service role: cek objek (ukuran, magic bytes, sha256) lalu update upload_status=UPLOADED | PLG, ADM, TEK | 1 | - | - | - | - | `UPLOAD_NOT_FOUND`, `CHECKSUM_MISMATCH`, `UPLOAD_TYPE_NOT_ALLOWED`, `NOT_FOUND` |
| `POST /service-requests/{requestId}/approve`<br>Setujui permintaan dan buat WO (T-01)<br>*DB:* rpc request_decide(p_request_id, 'APPROVE', p_priority_code, p_service_type_id, p_estimate_total, p_reason, p_expected_version) | ADM | 1 | T-01 | - | W | - | `ASSET_REQUIRED`, `SERVICE_TYPE_REQUIRED`, `PRIORITY_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND`, `FORBIDDEN_ROLE` |
| `POST /service-requests/{requestId}/request-info`<br>Minta info tambahan ke pelanggan (NEEDS_INFO)<br>*DB:* rpc request_decide(..., 'NEEDS_INFO', p_reason := catatan) | ADM | 1 | - | - | W | - | `REASON_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /service-requests/{requestId}/reject`<br>Tolak permintaan dengan alasan (T-24)<br>*DB:* rpc request_decide(..., 'REJECT', p_reason) | ADM | 1 | T-24 | - | W | - | `REASON_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |

### 6.4 Work order: transisi status dan RPC kecil

Catatan Lapis 1 (G-01): T-19 hanya oleh `SUPERVISOR` dan tidak ada pengaturan penutupan otomatis di 04. Demo Lapis 1 "teknisi menutup lalu laporan PDF terbit" membutuhkan akun SPV yang menyetujui, atau keputusan baru (lihat G-01).

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /work-orders/{workOrderId}/assign`<br>Tugaskan teknisi + jadwal final<br>*DB:* wo_transition('ASSIGN'; p_payload {technician_id, scheduled_start, scheduled_end, override_reason}) | DSP | 1 | T-02 | - | W | W | `TECHNICIAN_INVALID`, `SCHEDULE_REQUIRED`, `SOFT_GUARD`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `FORBIDDEN_ROLE`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/reassign`<br>Tugas ulang ke teknisi lain (alasan wajib)<br>*DB:* wo_transition('REASSIGN') | DSP | 1 | T-05 | - | W | W | `TECHNICIAN_INVALID`, `SCHEDULE_REQUIRED`, `SOFT_GUARD`, `REASON_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/accept`<br>Teknisi menerima tugas<br>*DB:* wo_transition('ACCEPT') | TEK | 1 | T-03 | `ACCEPT` | o | W | `INVALID_TRANSITION`, `VERSION_CONFLICT`, `FORBIDDEN_ROLE`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/reject-assignment`<br>Teknisi menolak tugas (alasan wajib)<br>*DB:* wo_transition('REJECT') | TEK | 1 | T-04 | `REJECT` | o | W | `REASON_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/release`<br>Lepas tugas yang sudah diterima (sebelum check-in)<br>*DB:* wo_transition('RELEASE') | TEK, DSP | 1 | T-06 | `RELEASE` | o | W | `REASON_REQUIRED`, `ALREADY_CHECKED_IN`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/depart`<br>Berangkat menuju lokasi<br>*DB:* wo_transition('DEPART') | TEK | 1 | T-07 | `DEPART` | o | W | `NOT_SCHEDULED_TODAY`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/check-in`<br>Check-in di lokasi (GPS atas izin; bukan pelacakan kontinu)<br>*DB:* wo_transition('CHECK_IN'; payload {lat, lng, accuracy_m, no_gps_reason, client_ts}) | TEK | 1 | T-08 | `CHECK_IN` | o | W | `GPS_OR_REASON_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/hold-parts`<br>Tunda menunggu suku cadang<br>*DB:* wo_transition('HOLD_PARTS') | TEK | 2 | T-09 | `HOLD_PARTS` | o | W | `NO_OPEN_PART_REQUEST`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/resume-parts`<br>Lanjutkan setelah suku cadang tiba/dibatalkan<br>*DB:* wo_transition('RESUME_PARTS') | TEK, DSP | 2 | T-10 | `RESUME_PARTS` | o | W | `PART_REQUEST_OPEN`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/request-signoff`<br>Minta pelanggan menandatangani lewat PWA (AWAITING_SIGNOFF)<br>*DB:* wo_transition('REQUEST_SIGNOFF') | TEK | 2 | T-17 | `REQUEST_SIGNOFF` | o | W | `CLOSURE_REQUIREMENTS_NOT_MET`, `EXCEPTION_NOTE_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/signoff`<br>Pelanggan menandatangani penerimaan hasil kerja di PWA (T-18)<br>*DB:* rpc wo_customer_sign(p_wo_id, p_signer_name, p_storage_path, p_expected_version, p_op_id, p_device_meta) | PLG | 2 | T-18 | - | W | W | `INVALID_TRANSITION`, `CLOSURE_REQUIREMENTS_NOT_MET`, `VERSION_CONFLICT`, `NOT_FOUND`, `VALIDATION_FAILED` |
| `POST /work-orders/{workOrderId}/submit`<br>Tutup oleh teknisi: check-out dan kirim ke review (T-16), atau tutup tidak tuntas (T-14)<br>*DB:* wo_transition('SUBMIT_REVIEW') dari IN_PROGRESS; ('CLOSE_AFTER_REJECTION') dari AWAITING_CUSTOMER_APPROVAL (T-14: outcome PARTIAL/UNRESOLVED + alasan) | TEK | 1 | T-16 | `SUBMIT_REVIEW` | o | W | `CLOSURE_REQUIREMENTS_NOT_MET`, `EXCEPTION_NOTE_REQUIRED`, `NO_BLOCKING_REJECTION`, `OUTCOME_INVALID`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND`, `VALIDATION_FAILED` |
| `POST /work-orders/{workOrderId}/review/approve`<br>Supervisor menyetujui dan menutup WO (T-19)<br>*DB:* wo_transition('APPROVE_CLOSE'; payload {approve_exception}) | SPV | 2 | T-19 | - | W | W | `CLOSURE_REQUIREMENTS_NOT_MET`, `CLOSURE_EXCEPTION_NOT_APPROVED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `FORBIDDEN_ROLE`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/review/return`<br>Supervisor mengembalikan ke teknisi dengan catatan (T-20)<br>*DB:* wo_transition('RETURN') | SPV | 2 | T-20 | - | W | W | `REASON_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `FORBIDDEN_ROLE`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/resume-after-return`<br>Teknisi mulai memperbaiki WO yang dikembalikan (T-21)<br>*DB:* wo_transition('RESUME_AFTER_RETURN') | TEK | 2 | T-21 | `RESUME_AFTER_RETURN` | o | W | `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/cancel`<br>Batalkan WO (alasan wajib)<br>*DB:* wo_transition('CANCEL') untuk NEW..EN_ROUTE (ADM/DSP); ('CANCEL_ACTIVE') untuk IN_PROGRESS/ON_HOLD_PARTS/AWAITING_* (hanya SPV, T-23) | ADM, DSP, SPV | 1 | T-22 | - | W | W | `REASON_REQUIRED`, `FORBIDDEN_ROLE`, `DATA_IMMUTABLE`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/cancel-requests`<br>Pelanggan membatalkan (status NEW) atau mengajukan pembatalan (DEC-04)<br>*DB:* status NEW: wo_transition('CANCEL_BY_CUSTOMER'); ASSIGNED/ACCEPTED/EN_ROUTE: rpc wo_request_cancel(p_wo_id, p_note) (hanya mencatat; keputusan ADM/DSP) | PLG | 1 | T-22 | - | - | W | `INVALID_TRANSITION`, `NOT_FOUND`, `REASON_REQUIRED` |
| `POST /work-orders/{workOrderId}/help-requests`<br>Minta bantuan (flag help_requested_at; status tidak berubah, T-26)<br>*DB:* rpc wo_request_help(p_wo_id, p_note) | TEK | 1 | T-26 | `HELP_REQUEST` | - | - | `DATA_IMMUTABLE`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/helpers`<br>Tambah teknisi pendamping (langsung ACCEPTED, D28)<br>*DB:* rpc wo_add_helper(p_wo_id, p_technician_id) | DSP | 1 | - | - | - | - | `TECHNICIAN_INVALID`, `INVALID_TRANSITION`, `FORBIDDEN_ROLE` |
| `POST /work-orders/{workOrderId}/failed-visit`<br>Kunjungan gagal: WO kembali ke NEW (T-27)<br>*DB:* wo_transition('VISIT_FAILED') | TEK | 2 | T-27 | `VISIT_FAILED` | o | W | `FAILED_VISIT_EVIDENCE_MISSING`, `REASON_REQUIRED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/priority`<br>Ubah prioritas (SLA dihitung ulang dari sla_clock_start_at, BR-015)<br>*DB:* rpc wo_change_priority(p_wo_id, p_priority_code, p_reason, p_expected_version) | ADM, DSP, SPV | 1 | - | - | W | - | `REASON_REQUIRED`, `DATA_IMMUTABLE`, `VERSION_CONFLICT`, `NOT_FOUND`, `FORBIDDEN_ROLE` |
| `POST /work-orders/{workOrderId}/estimate`<br>Tetapkan estimasi awal (acuan BR-050)<br>*DB:* rpc wo_set_estimate(p_wo_id, p_estimate, p_expected_version) | ADM, SPV | 2 | - | - | W | - | `DATA_IMMUTABLE`, `VERSION_CONFLICT`, `NOT_FOUND`, `FORBIDDEN_ROLE` |
| `POST /work-orders/{workOrderId}/billing-override`<br>Ubah billing_type dengan alasan (BR-062)<br>*DB:* rpc wo_override_billing(p_wo_id, p_billing_type, p_reason) | SPV | 2 | - | - | - | - | `REASON_REQUIRED`, `INVALID_TRANSITION`, `FORBIDDEN_ROLE`, `NOT_FOUND` |
| `POST /work-orders/{workOrderId}/rework`<br>Buat WO REWORK dari WO CLOSED (T-25); induk tidak dibuka kembali<br>*DB:* rpc wo_create_rework(p_parent_wo_id, p_reason, p_priority_code, p_complaint_id) | ADM, SPV | 2 | T-25 | - | - | - | `INVALID_TRANSITION`, `FORBIDDEN_ROLE`, `NOT_FOUND` |
| `GET /work-orders/{workOrderId}/cost-summary`<br>Ringkasan estimasi vs proyeksi dan needs_approval (BR-050)<br>*DB:* rpc wo_cost_summary(p_wo_id) | ADM, DSP, SPV, FIN, OWN, TEK | 2 | - | - | - | - | `NOT_FOUND` |

### 6.5 Persetujuan biaya tambahan

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /work-orders/{workOrderId}/extra-cost-approvals`<br>Ajukan biaya tambahan; WO masuk AWAITING_CUSTOMER_APPROVAL (T-11)<br>*DB:* rpc extra_cost_request(p_wo_id, p_reason, p_items, p_expected_version, p_op_id) | TEK | 2 | T-11 | `REQUEST_EXTRA_COST` | W | W | `VALIDATION_FAILED`, `INVALID_TRANSITION`, `VERSION_CONFLICT`, `NOT_FOUND` |
| `POST /extra-cost-approvals/{approvalId}/decision`<br>Setujui atau tolak biaya tambahan (satu-satunya pintu keputusan; T-12/T-13/T-14)<br>*DB:* rpc extra_cost_decide(p_approval_id, p_decision, p_content_hash, p_continue_original_scope, p_channel, p_evidence_note, p_op_id, p_meta) | PLG, ADM | 2 | T-12 | - | - | W | `APPROVAL_VERSION_STALE`, `APPROVAL_STALE`, `APPROVAL_EXPIRED`, `ON_BEHALF_EVIDENCE_REQUIRED`, `VALIDATION_FAILED`, `NOT_FOUND` |

### 6.6 Suku cadang dan stok

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /work-orders/{workOrderId}/part-requests`<br>Minta suku cadang untuk WO<br>*DB:* rpc part_request_create(p_wo_id, p_lines [{item_id, qty}], p_note) | TEK, DSP | 2 | - | `CREATE_PART_REQUEST` | - | - | `DATA_IMMUTABLE`, `VALIDATION_FAILED`, `NOT_FOUND` |
| `POST /part-requests/{partRequestId}/decision`<br>Setujui atau tolak permintaan suku cadang<br>*DB:* rpc part_request_decide(p_request_id, 'APPROVE'\|'REJECT', p_note) | GDG | 2 | - | - | - | - | `INVALID_TRANSITION`, `FORBIDDEN_ROLE` |
| `POST /part-request-lines/{lineId}/issue`<br>Serahkan satu baris ke teknisi (ISSUE_TO_TECH); boleh sebagian<br>*DB:* rpc part_issue(p_line_id, p_qty, p_from_location_id) | GDG | 2 | - | - | - | - | `INSUFFICIENT_STOCK`, `INVALID_TRANSITION`, `VALIDATION_FAILED`, `FORBIDDEN_ROLE` |
| `POST /work-orders/{workOrderId}/part-returns`<br>Ajukan pengembalian sisa (PENDING)<br>*DB:* rpc part_return_create(p_wo_id, p_lines [{item_id, qty}], p_note) | TEK | 2 | - | `CREATE_PART_RETURN` | - | - | `DATA_IMMUTABLE`, `VALIDATION_FAILED`, `NOT_FOUND` |
| `POST /part-returns/{returnId}/confirm`<br>Konfirmasi fisik (RETURN_FROM_TECH) atau tolak<br>*DB:* rpc part_return_confirm(p_return_id, p_lines [{item_id, confirmed_qty}], p_to_location_id, p_reject) | GDG | 2 | - | - | - | - | `INVALID_TRANSITION`, `VALIDATION_FAILED`, `FORBIDDEN_ROLE` |
| `POST /stock/receipts`<br>Penerimaan barang (RECEIPT)<br>*DB:* rpc stock_receive(p_item_id, p_location_id, p_qty, p_note) | GDG | 2 | - | - | - | - | `VALIDATION_FAILED`, `FORBIDDEN_ROLE` |
| `POST /stock/adjustments`<br>Penyesuaian/opname (ADJUSTMENT); di atas ambang hanya SPV<br>*DB:* rpc stock_adjust(p_item_id, p_location_id, p_delta, p_reason) | GDG, SPV | 2 | - | - | - | - | `INSUFFICIENT_STOCK`, `VALIDATION_FAILED`, `FORBIDDEN_ROLE` |
| `POST /parts-variances/{varianceId}/resolve`<br>Selesaikan selisih (mutasi koreksi, BR-033)<br>*DB:* rpc parts_variance_resolve(p_variance_id, p_status, p_note) | GDG, SPV | 2 | - | - | - | - | `REASON_REQUIRED`, `FORBIDDEN_ROLE`, `INVALID_TRANSITION`, `VALIDATION_FAILED` |

### 6.7 Pemeliharaan berkala

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /pm-periods/{periodId}/resolve`<br>Periode PM MISSED: buat WO sekarang atau lewati (BR-025)<br>*DB:* rpc pm_period_resolve(p_period_id, 'SKIP'\|'CREATE_NOW', p_reason) | ADM | 2 | - | - | - | - | `REASON_REQUIRED`, `INVALID_TRANSITION`, `FORBIDDEN_ROLE`, `VALIDATION_FAILED` |

### 6.8 Berkas

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /files/download-urls`<br>Signed URL unduh berumur pendek; akses staf ke data pelanggan dicatat<br>*DB:* app.can_read_object (policy storage) via createSignedUrl dengan JWT pengguna, atau service role setelah pemeriksaan; rpc log_data_access(p_customer_id, p_resource_type, p_resource_id, p_action) untuk staf | ANY | 1 | - | - | - | - | `NOT_FOUND`, `RATE_LIMITED` |

### 6.9 Sinkronisasi offline

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /sync/push`<br>Kirim batch operasi outbox (idempoten per op_id, sukses parsial)<br>*DB:* insert sync_operations (JWT, hak kolom sempit); terapkan via wo_transition / RPC / tulis tabel lapangan (JWT); update status+result sync_operations oleh service role (G-06) | TEK | 1 | - | - | - | - | `APP_UPDATE_REQUIRED`, `PAYLOAD_TOO_LARGE`, `RATE_LIMITED`, `VALIDATION_FAILED` |
| `GET /sync/pull`<br>Ambil perubahan server (snapshot bila tanpa cursor) dan himpunan WO aktif<br>*DB:* select view tech_*, work_orders, anak WO (JWT, RLS my_active_wo_ids) memakai updated_at; tidak ada sync_changes (G-05) | TEK | 1 | - | - | - | - | `RATE_LIMITED`, `APP_UPDATE_REQUIRED` |

### 6.10 Internal

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /internal/jobs/{job}`<br>Picu job terjadwal (cadangan pg_cron) atau worker aplikasi<br>*DB:* app.run_job(p_name) / worker | SYS | 2 | - | - | - | - | - |
| `POST /internal/webhooks/{provider}`<br>Terima status pengiriman dari penyedia email/WA<br>*DB:* update notifications (service role) | SYS | 2 | - | - | - | - | - |

### 6.11 Lapis 3 (ringkas)

Logika invoice, pembayaran, ekspor, dan impor belum ada di 04 (TODO di 05); endpoint di bawah adalah rencana kontrak (G-10).

| Endpoint | Peran | Lp | Aturan | Sync op | If-Match | Idem-Key | Kode error domain |
|---|---|---|---|---|---|---|---|
| `POST /invoices`<br>Buat invoice DRAFT dari WO CLOSED siap tagih (v_finance_ready_to_bill)<br>*DB:* RPC belum ada di 04 (G-10); sementara insert invoices/invoice_lines oleh FIN (Jalur A) | FIN | 3 | - | - | - | - | `WO_NOT_CLOSED`, `WO_NOT_BILLABLE`, `ALREADY_INVOICED` |
| `POST /invoices/{invoiceId}/issue`<br>Terbitkan invoice<br>*DB:* RPC belum ada (G-10) | FIN | 3 | - | - | - | - | `INVOICE_NOT_DRAFT` |
| `POST /invoices/{invoiceId}/payments`<br>Catat pembayaran manual (bukan payment gateway)<br>*DB:* RPC belum ada (G-10) | FIN | 3 | - | - | - | - | `INVOICE_NOT_DRAFT`, `VALIDATION_FAILED` |
| `POST /invoice-exports`<br>Ekspor invoice ke CSV (format menunggu D12)<br>*DB:* Route Handler (render CSV); sumber invoices/invoice_lines | FIN | 3 | - | - | - | - | `VALIDATION_FAILED` |
| `POST /imports`<br>Mulai impor Excel (dry-run)<br>*DB:* insert import_jobs; logika validasi TODO di 04 (G-10) | ADM, GDG | 3 | - | - | - | - | `VALIDATION_FAILED` |
| `POST /imports/{importId}/commit`<br>Commit impor bebas galat<br>*DB:* TODO di 04 (G-10) | ADM, GDG | 3 | - | - | - | - | `IMPORT_HAS_ERRORS` |

---

## 7. Kontrak Sinkronisasi Offline Teknisi

Dasar: 02 bagian 6 dan 4.5. Bagian ini menetapkan **kontrak HTTP** di atas apa yang disediakan 04: `sync_operations` (idempotensi `op_id`, status `RECEIVED/APPLIED/REJECTED/RESCUED`, D27), kolom `op_id` pada tabel lapangan, dan penolakan data lapangan pada WO final (`IMM01`). Penerapan operasi ada di lapisan API ini. Mekanisme klien (IndexedDB, Web Locks, backoff) mengikuti 02.

### 7.1 Prinsip

1. **Satu jalur tulis untuk teknisi**: aksi di PWA menulis `drafts` + `outbox` atomik, lalu dikirim lewat `POST /sync/push`. Endpoint transisi bagian 6 memakai RPC yang sama dan tersedia untuk uji/back-office.
2. **Tiga tahap berurutan**: push data terstruktur, unggah blob (7.6), pull perubahan server.
3. **Tidak ada data lapangan dibuang diam-diam** (DEC-06): konflik -> `REJECTED` berkode + `sync_operations.status = RESCUED` dengan `payload` utuh.
4. **Antrean klien tidak dihapus** karena 401, 426, 429, 5xx, atau jaringan; hanya setelah ACK atau penolakan permanen yang sudah tersimpan.
5. Server mengeksekusi dengan **JWT teknisi** (RLS dan `can_edit_wo` berlaku, `auth.uid()` menjadi aktor). INSERT jasa/pemakaian memakai `Prefer: return=minimal` (D16).

### 7.2 `POST /sync/push`

Amplop:

```json
{
  "device_id": "dev-7e7e7e7e-pwa-01",
  "schema_version": 1,
  "client_time": "2026-11-02T08:20:00Z",
  "ops": [
    { "op_id": "0192f1a0-0000-7000-8000-00000000a001", "seq": 1,
      "wo_id": "b0b0b0b0-0000-4000-8000-000000000001", "type": "ACCEPT", "base_version": 2,
      "client_captured_at": "2026-11-02T07:58:10Z", "payload": {} }
  ]
}
```

Pemrosesan server per operasi [A]:

1. Autentikasi. `schema_version` di bawah minimum [P] -> seluruh batch 426 `APP_UPDATE_REQUIRED`.
2. `INSERT INTO sync_operations (op_id, device_id, user_id, wo_id, type, seq, schema_version, payload, client_captured_at)` (hak kolom TEK) dengan `ON CONFLICT (op_id) DO NOTHING`. Bila sudah ada -> kembalikan `result` tersimpan, `replayed=true`.
3. Urutan per WO menurut `seq`; celah -> `status=HELD`, `expected_seq`; tidak diterapkan.
4. Terapkan sesuai katalog 7.3: `wo_transition(p_wo_id, p_action, p_expected_version := base_version, p_op_id := op_id, ...)`, RPC, atau tulis tabel lapangan (kolom `op_id` = `op_id` operasi).
5. Perbarui `sync_operations.status` (`APPLIED` / `REJECTED` / `RESCUED`), `result`, `applied_at`, `clock_skew`. **Klien tidak punya hak UPDATE kolom ini**; pembaruan oleh service role yang belum tercantum di 05 bagian 6.3 (G-06).
6. `clock_skew = true` bila `|client_captured_at - server_time|` melebihi [P]; urutan memakai `seq`, bukan jam klien.

Respons selalu **HTTP 200** bila amplop sah; hasil per operasi di `results[]` (sukses parsial):

```json
{
  "server_time": "2026-11-02T08:20:01Z",
  "results": [
    { "op_id": "0192f1a0-0000-7000-8000-00000000a001", "status": "ACKED", "db_status": "APPLIED", "replayed": false,
      "result": { "status": "ACCEPTED", "version": 3, "replayed": false } },
    { "op_id": "0192f1a0-0000-7000-8000-00000000a003", "status": "HELD", "code": "SEQ_GAP", "expected_seq": 2 }
  ]
}
```

| `status` | Arti | Tindakan klien |
|---|---|---|
| `ACKED` | Diterapkan atau replay duplikat | Hapus dari `outbox` setelah hasil disimpan lokal; indikator "terkirim". |
| `REJECTED` | Ditolak permanen (konflik, guard, validasi); ada `code` | Jangan kirim ulang. Tandai "gagal" dengan alasan; bila `db_status=RESCUED`, tampilkan banner konflik. Data lokal dipertahankan. |
| `RETRY` | Galat sementara (kunci basis data, 503) | Backoff eksponensial + jitter. |
| `HELD` | Celah `seq` | Kirim ulang mulai `expected_seq`. |

Tingkat HTTP: 401 -> segarkan token, **antrean tetap**; 413 -> pecah batch; 426 -> perbarui aplikasi; 429 -> tunggu `Retry-After`; 5xx/jaringan -> backoff.

### 7.3 Katalog operasi

`payload` + ID di amplop (`wo_id`, id klien) membentuk argumen RPC/kolom tabel. Tipe operasi untuk transisi sama dengan nama aksi `wo_transition` di 04.

| Tipe op | Eksekusi di database | Payload | Kepemilikan / konflik | Kunci idempotensi |
|---|---|---|---|---|
| `ACCEPT` | wo_transition('ACCEPT') | `{}` | Server menang (transisi) | op_id |
| `REJECT` | wo_transition('REJECT') | `{reason_code, reason}` | Server menang (transisi) | op_id |
| `RELEASE` | wo_transition('RELEASE') | `{reason_code, reason}` | Server menang (transisi) | op_id |
| `DEPART` | wo_transition('DEPART') | `{}` | Server menang (transisi) | op_id |
| `CHECK_IN` | wo_transition('CHECK_IN') | `{lat, lng, accuracy_m, no_gps_reason, client_ts}` | Server menang (transisi) | op_id |
| `HOLD_PARTS` | wo_transition('HOLD_PARTS') | `{}` | Server menang (transisi) | op_id |
| `RESUME_PARTS` | wo_transition('RESUME_PARTS') | `{}` | Server menang (transisi) | op_id |
| `REQUEST_SIGNOFF` | wo_transition('REQUEST_SIGNOFF') | `{outcome, client_pending_ops, ...}` | Server menang (transisi) | op_id |
| `SUBMIT_REVIEW` | wo_transition('SUBMIT_REVIEW') | `{outcome, lat, lng, client_pending_ops, closure_exception_code, closure_exception_note}` | Server menang (transisi + BR-040) | op_id |
| `CLOSE_AFTER_REJECTION` | wo_transition('CLOSE_AFTER_REJECTION') | `{outcome: PARTIAL atau UNRESOLVED, client_pending_ops}; reason wajib` | Server menang (transisi) | op_id |
| `RESUME_AFTER_RETURN` | wo_transition('RESUME_AFTER_RETURN') | `{}` | Server menang (transisi) | op_id |
| `VISIT_FAILED` | wo_transition('VISIT_FAILED') | `{result}; reason wajib; foto FAILED_VISIT sudah ACK` | Server menang (transisi) | op_id |
| `HELP_REQUEST` | rpc wo_request_help | `{note}` | Flag, tanpa transisi | op_id |
| `REQUEST_EXTRA_COST` | rpc extra_cost_request | `{reason, items[]}` | Server menang (transisi) | op_id |
| `SET_CHECKLIST_ITEM` | update wo_checklist_items (id; value, is_na, na_reason, client_captured_at, op_id) | `{item_id, value, is_na, na_reason}` | Teknisi menang per item (urut seq) | item_id |
| `SET_FINDINGS` | upsert wo_findings (wo_id unik) | `{diagnosis, action_taken, recommendation, internal_note}` | Teknisi menang per kolom | wo_id |
| `ADD_PHOTO` | insert wo_attachments (id, wo_id, kind, storage_path, mime, bytes, checksum, taken_at, op_id) | `{photo_id, kind, mime, bytes, sha256, taken_at, storage_path}` | Append-only | id = photo_id |
| `TOMBSTONE_PHOTO` | update wo_attachments set deleted_at | `{photo_id}` | Tombstone | photo_id |
| `ADD_SIGNATURE` | insert wo_signatures (signed_via TECH_DEVICE; content_hash oleh trigger) | `{signature_id, signer_name, storage_path, device_meta}` | Append-only | id = signature_id |
| `ADD_LABOR_LINE` | insert wo_labor_lines, Prefer: return=minimal | `{line_id, service_item_id, description, qty, is_extra, extra_approval_id, emergency, emergency_reason}` | Append (tombstone) | id = line_id |
| `REMOVE_LABOR_LINE` | update wo_labor_lines set deleted_at | `{line_id}` | Tombstone | line_id |
| `ADD_PART_USAGE` | insert wo_part_usages, Prefer: return=minimal (mutasi CONSUME_ON_WO oleh trigger) | `{usage_id, item_id, qty, is_extra, extra_approval_id, emergency, emergency_reason, source_location_id}` | Append (tombstone) + stok | id = usage_id |
| `REMOVE_PART_USAGE` | update wo_part_usages set deleted_at (mutasi koreksi USAGE_REVERSAL) | `{usage_id}` | Tombstone | usage_id |
| `CREATE_PART_REQUEST` | rpc part_request_create | `{lines[], note}` | Append-only | op_id (tanpa kunci alami; G-06) |
| `CREATE_PART_RETURN` | rpc part_return_create | `{lines[], note}` | Append-only | op_id (tanpa kunci alami; G-06) |

Catatan: penghapusan foto yang sudah ACK diizinkan hanya sebagai tombstone `deleted_at` (05 bagian 3.2 memberi TEK hak `update (deleted_at)`); foto wajib BR-040 dihitung dari baris yang tidak terhapus dan `UPLOADED`. Pernyataan "tidak ada suku cadang dipakai" (`work_orders.no_parts_used`, BR-040 butir 6) **belum punya jalur tulis** bagi teknisi (G-13).

### 7.4 Konflik: respons server dan perilaku klien

Kepemilikan data menentukan pemenang (02 bagian 6.3). API menerjemahkan hasil eksekusi:

| Kasus | Sinyal dari database | `results[].code` | Server | Klien |
|---|---|---|---|---|
| WO dibatalkan saat offline | `IMM01` pada data lapangan, atau `WO001`; WO `CANCELLED` | `CONFLICT_CANCELLED` | Operasi tidak diterapkan; `sync_operations.status = RESCUED` | Banner "WO dibatalkan"; data lokal jadi draf |
| WO ditugaskan ulang / dilepas | WO keluar dari `my_active_wo_ids()` -> RLS menolak (`WO005`/`42501`) | `CONFLICT_REASSIGNED` | `RESCUED` | Sama; cache WO dibersihkan lewat `active_wo_ids` pada pull |
| WO sudah CLOSED saat data lapangan terlambat | `IMM01` | `DATA_IMMUTABLE` | `RESCUED` | Draf; SPV/DSP melihat |
| Transisi tidak mungkin | `WO001` | `INVALID_TRANSITION` | `REJECTED` | Muat ulang status dari pull |
| Konflik versi | `WO004` | `VERSION_CONFLICT` | `REJECTED` bila transisi; data lapangan tidak memakai versi | Muat ulang lalu ulangi bila masih relevan |
| Tutup, ada biaya tambahan PENDING baru | `WO003` array `EXTRA_COST_PENDING` | `CLOSURE_REQUIREMENTS_NOT_MET` | `REJECTED` | Tampilkan `unmet` |
| Antrean belum kosong | `WO003` `SYNC_PENDING` / `SYNC_UNAPPLIED` | `CLOSURE_REQUIREMENTS_NOT_MET` | `REJECTED` (kirim ulang `SUBMIT_REVIEW` sesudah sisa ACK) | |
| Pemakaian di luar estimasi tanpa persetujuan | `WO003` `EXTRA_COST_NOT_APPROVED` | `EXTRA_COST_NOT_APPROVED` | `REJECTED` | Arahkan ke pengajuan biaya tambahan |
| Stok kurang | `STK01` | `INSUFFICIENT_STOCK` (pemakaian dengan `unsourced` bila setting mengizinkan) | `REJECTED`/`RESCUED` | Tandai "perlu verifikasi gudang" |
| Back-office mengubah penugasan/jadwal/prioritas/billing | (tidak ada operasi terkait) | - | Server menang | Diterima lewat pull (`UPSERT`) |

Draf `RESCUED` terlihat lewat `select` pada `sync_operations` (ADM, DSP, SPV, OWN dapat membaca). **Tidak ada RPC atau kolom untuk menyelesaikan (dismiss/tautkan) draf** di 04 (G-06); sampai diputuskan, draf hanya dibaca.

### 7.5 `GET /sync/pull`

04 tidak punya umpan perubahan (`sync_changes`) atau tombstone (G-05). Desain yang tersedia:

- Parameter: `device_id` (wajib), `cursor`, `limit` [P].
- **Tanpa cursor = snapshot**: baca (JWT, RLS) WO di `my_active_wo_ids()` dalam jendela hari [P] (`work_orders`, `wo_assignments`, `wo_checklist_items`, `wo_findings`, `wo_attachments`, `wo_signatures`, `tech_wo_labor_lines`, `tech_wo_part_usages`, `tech_extra_cost_approvals`, `part_requests` miliknya, `v_tech_asset_service_history`, saldo `stock_balances` lokasi sendiri). `snapshot=true`.
- **Dengan cursor**: entitas dengan `updated_at > cursor` per tabel; `next_cursor` opaque berisi stempel waktu per kelompok tabel (`updated_at`, `id`). Tidak ada jaminan bahwa perubahan anak WO menaikkan `work_orders.updated_at`; karena itu tiap tabel dibaca terpisah.
- **Penghapusan cache**: respons memuat `active_wo_ids` (himpunan lengkap `app.my_active_wo_ids()`). WO di cache yang tidak ada di himpunan itu dibersihkan setelah outbox WO tersebut kosong atau sudah menjadi draf diselamatkan.
- `server_time` dikembalikan untuk mendeteksi selisih jam. Respons tidak memuat harga; `internal_note` hanya milik penulisnya dan SPV.

### 7.6 Foto dan tanda tangan: unggah bertahap

Selaras 05 bagian 5.2 dan 02 bagian 6.4:

1. **Tahap A (metadata)**: operasi `ADD_PHOTO` / `ADD_SIGNATURE` meng-INSERT baris dengan `id` buatan klien dan `storage_path` berprefix `{customer_id}/wo/{wo_id}/` (policy `WITH CHECK`; salah prefix ditolak). `upload_status = PENDING`. Server mengisi `content_hash` tanda tangan (trigger).
2. **Tahap B (biner)**: `POST /uploads/sign {resource: WO_ATTACHMENT|WO_SIGNATURE, id}` -> `UploadTarget` (`PUT` signed upload URL berumur pendek). Path ditentukan baris metadata sehingga unggah ulang menimpa objek yang sama (idempoten). Maksimum unggahan paralel [P], prioritas di bawah operasi data.
3. **Selesai**: `POST /uploads/complete {resource, id}` -> server memverifikasi keberadaan objek, ukuran, `checksum`, MIME + magic bytes, lalu service role menandai `UPLOADED` (hanya server yang bisa, D19). Tidak cocok -> 422 `CHECKSUM_MISMATCH`/415; objek belum ada -> 409 `UPLOAD_NOT_FOUND`.
4. URL kedaluwarsa -> minta lagi. Gagal N kali [P] -> klien menandai "gagal, ketuk untuk ulang". `SUBMIT_REVIEW` ditolak (`PHOTO_MISSING`) selama foto wajib belum `UPLOADED` dan tidak terhapus.
5. Blob lokal dihapus hanya setelah `complete` sukses.
6. `wo_signatures` tidak punya `upload_status` (G-04): `complete` hanya memverifikasi objek; keberadaan gambar tidak ikut dicek BR-040.

Foto bukti kunjungan gagal memakai `kind = FAILED_VISIT` dan wajib ada (dan terhapus-lunak tidak) sebelum `VISIT_FAILED`.

### 7.7 Kompatibilitas versi aplikasi

`schema_version` per batch dan per operasi tersimpan di `sync_operations.schema_version`. Versi lama diterima selama kompatibel; di bawah minimum [P] -> 426 dan antrean aman. Pembaruan service worker tidak boleh memigrasi/membersihkan `outbox` sebelum kosong atau dimigrasi (RK-11).

### 7.8 Pelanggan (PWA) offline

Pemesanan offline (FR-028): klien mengantre INSERT `service_requests` dengan `id` dan `client_request_id` tetap, lalu INSERT `request_attachments`, `/uploads/sign`, PUT, `/uploads/complete` sesudah baris permintaan ada. Pengulangan tidak menggandakan karena `UNIQUE (customer_id, client_request_id)` dan PK `id`. Riwayat dibaca offline dari cache (NFR-O7). Pelanggan tidak memakai `/sync/push`.

---

## 8. Event dan Notifikasi

### 8.1 Arsitektur (disesuaikan dengan 04)

04 tidak memiliki tabel outbox terpisah. Fungsi DB (`app.enqueue_notification`, `app.notify_role`, `app.notify_customer`, `app.notify_wo_technicians`) langsung menulis baris `notifications` (satu baris per kanal per penerima) **dalam transaksi yang sama** dengan perubahan bisnis, dengan `dedupe_key` unik per kanal (`uq_notif_dedupe`). `notifications` itulah antrean.

```
fungsi transisi / job (transaksi DB)
   |-- wo_status_history, audit_logs
   |-- notifications (status PENDING, per kanal; ON CONFLICT DO NOTHING pada dedupe_key)
   v
worker pengirim (job aplikasi `dispatch_notifications`, service role; pg_cron atau Vercel Cron)
   |-- IN_APP : baris notifications + Supabase Realtime (filter user_id; tabel, bukan view)
   |-- EMAIL  : penyedia email transaksional (D6, belum dipilih)
   |-- PUSH   : Web Push (D7) -> tidak ada tabel langganan di 04 (G-11)
   |-- WHATSAPP: ditunda (D5, OQ-09); default tautan wa.me di UI
   v
status: PENDING -> SENT | FAILED (attempts, last_error) -> READ (oleh pemilik)
```

- Kanal default dari `app_settings['notification.default_channels']` (`IN_APP`, `EMAIL`); preferensi pengguna di `notification_prefs` (`event_group` = awalan event atau `*`) memfilter saat enqueue.
- **Webhook internal**: hanya (a) Database Webhook/pg_cron -> `/internal/jobs/dispatch_notifications` dan (b) status pengiriman penyedia -> `/internal/webhooks/{provider}` (HMAC). Tidak ada webhook keluar [A].
- **Jaminan**: *at-least-once*; konsumen idempoten lewat `dedupe_key`. Retry: worker memproses `FAILED` dengan `attempts` di bawah batas [P] (backoff); ADM dapat melihat kegagalan lewat `notifications`. Endpoint retry manual tidak ada (service role bukan di daftar 05; G-11).
- **Privasi**: payload email/push pelanggan hanya nomor WO, `display_status`, tautan; tanpa `internal_note`, harga internal, alasan eskalasi (AP-3).

### 8.2 Amplop event (payload `notifications.payload` + kolom)

```json
{
  "id": "0192f1b2-0000-7000-8000-00000000e101",
  "event": "wo.scheduled",
  "channel": "EMAIL",
  "wo_id": "b0b0b0b0-0000-4000-8000-000000000001",
  "dedupe_key": "assign:9a9a9a9a-0000-4000-8000-000000000001:EMAIL",
  "payload": { "wo_number": "WO-2026-000123" },
  "status": "PENDING",
  "scheduled_at": "2026-11-02T08:05:00Z"
}
```

Webhook penyedia: `X-Vasta-Signature: t=<unix>,v1=<hmac>`; tolak bila `|now - t|` melebihi toleransi [P]; abaikan `event_id` yang sudah diproses.

### 8.3 Katalog event (nama persis dari 04)

Kanal mengikuti `notification.default_channels` kecuali ditandai; penerima menurut fungsi pengirim di 04.

| Event | Pemicu | Penerima | Dedupe (awalan) |
|---|---|---|---|
| `request.received` / `request.new` | INSERT `service_requests` | PLG ("pesanan diterima") / ADM (antrean validasi) | per permintaan |
| `request.accepted` | `request_decide` APPROVE (T-01) | PLG | `req-acc:{request_id}` |
| `request.needs_info` | `request_decide` NEEDS_INFO | PLG | `req-info:{request_id}:{version}` |
| `request.rejected` | `request_decide` REJECT (T-24) | PLG | `req-rej:{request_id}` |
| `wo.assigned` | T-02 | TEK | per penugasan |
| `wo.scheduled` | T-03 (teknisi menerima) | PLG ("teknisi ditugaskan + jadwal") | per penugasan |
| `wo.rescheduled`, `wo.reassigned_away` | T-05 | PLG; TEK lama | `reassign-old:{op_id}` |
| `wo.assignment_rejected`, `wo.rejection_escalation` | T-04, T-06; ambang `reject.escalation_threshold` | DSP; SPV | per WO |
| `wo.released` | T-06 | DSP | per WO |
| `wo.en_route` | T-07 | PLG | per WO+versi |
| `wo.help_requested` | `wo_request_help` | DSP | `help:{wo_id}:{version}` |
| `wo.helper_assigned` | `wo_add_helper` | TEK helper | `helper:{assignment_id}` |
| `wo.on_hold_parts` | T-09 | GDG, DSP | per WO |
| `wo.approval_needed` | T-11 / revisi pengajuan | PLG ("menunggu persetujuan Anda") | `approval:{approval_id}` |
| `wo.approval_approve` / `wo.approval_reject` | T-12 / T-13 | TEK | `apprres:{approval_id}` |
| `wo.approval_reject_close_needed` | `extra_cost_decide` REJECT, `continue_original_scope=false` | TEK | `apprc:{approval_id}` |
| `wo.approval_expired` | T-15 (job) | DSP, ADM | `appexp:{approval_id}` |
| `wo.signoff_needed` | T-17 | PLG | per WO |
| `wo.review_needed` | T-16/T-18 | SPV | `review:{wo_id}:{version}` |
| `wo.returned`, `wo.return_escalation` | T-20; ambang `return.escalation_threshold` | TEK; OWN | `ret:{wo_id}:{n}` |
| `wo.closed` | T-19 | PLG | `closed:{wo_id}` |
| `wo.visit_failed` | T-27 | DSP | `vf:{wo_id}:{version}` |
| `wo.cancelled`, `wo.cancel_requested` | T-22/T-23; `wo_request_cancel` | PLG, DSP; ADM, DSP | `cancelled:{wo_id}`, `cxl:{wo_id}` |
| `sla.*`, `sla.pm_missed` | `app.run_sla_checks` per aturan `escalation_rules` | peran penerima (DSP L1, SPV L2, OWN L3 bila dikonfigurasi) | `uq_sla_events_*` |
| `pm.generated` | `pm_generate` | DSP | per periode |
| `parts.requested`, `parts.issued`, `parts.return_pending`, `parts.variance_open` | RPC `part_*`, selisih | GDG; TEK; GDG; GDG, SPV | per dokumen |
| `stock.below_min` | saldo di bawah `min_stock` | GDG | `below_min_notified` |

Event Lapis 3 (`invoice.issued`) belum ada di 04. Laporan siap (`report.ready`) belum dikirim oleh 04; worker `render_reports` dapat menambah notifikasi setelah `service_reports.status = READY` (G-11).

### 8.4 Notifikasi SLA

Satu tingkat satu kali: `sla_events` unik pada `(wo_id, kind, level, target)` dengan `target` = peran penerima (D06); notifikasi dibuat hanya bila baris `sla_events` benar-benar baru. Pengakuan eskalasi (`acknowledged_by/at` ada di tabel) belum punya RPC (G-12).

---

## 9. Contoh Request/Response Alur Kritikal

Data fiktif. ID dipendekkan polanya: pelanggan `c1c1c1c1-...-0001`, aset `a5a5a5a5-...-0001`, permintaan `e0e0e0e0-...-0001`, WO `b0b0b0b0-...-0001` (nomor `WO-2026-000123`), teknisi `7e7e7e7e-...-0001`. Nominal ilustrasi, **bukan tarif**. Header `Authorization: Bearer <JWT>` tidak diulang. Contoh Jalur A memakai PostgREST (`/rest/v1`); contoh Jalur B memakai `/api/v1`.

### 9.1 Pelanggan memesan servis (L1, FR-020): Jalur A

```http
POST /rest/v1/service_requests
Prefer: return=representation
Content-Type: application/json

{
  "id": "e0e0e0e0-0000-4000-8000-000000000001",
  "client_request_id": "0192f200-0000-7000-8000-000000000001",
  "customer_id": "c1c1c1c1-0000-4000-8000-000000000001",
  "asset_id": "a5a5a5a5-0000-4000-8000-000000000001",
  "problem_type_id": "9b9b9b9b-0000-4000-8000-000000000001",
  "description": "AC ruang rapat tidak dingin sejak pagi.",
  "preferred_start": "2026-11-03T02:00:00Z",
  "preferred_end": "2026-11-03T06:00:00Z",
  "channel": "PWA"
}
```

```http
HTTP/1.1 201 Created
[ { "id": "e0e0e0e0-0000-4000-8000-000000000001", "request_no": "REQ-2026-000045", "status": "SUBMITTED",
    "channel": "PWA", "duplicate_of": null, "version": 1, "created_at": "2026-11-02T07:00:00Z" } ]
```

`status`, `request_no`, `created_by`, `duplicate_of` diisi trigger; klien tidak bisa menyuplainya. Status untuk pelanggan dibaca dari `customer_requests` (`display_status = RECEIVED`, `possible_duplicate`). Pesanan serupa terbuka bukan penolakan: `duplicate_of` terisi dan admin diberi peringatan (BR-071). Batas laju:

```http
HTTP/1.1 400 Bad Request
{ "code": "RL001", "message": "RL001: batas pemesanan terlampaui", "details": null, "hint": null }
```

(PostgREST mengembalikan 400 untuk SQLSTATE kustom; klien memetakan `RL001` ke pesan "terlalu banyak pesanan". Via fasad Jalur B menjadi 429 `RATE_LIMITED`.) Foto pesanan:

```http
POST /rest/v1/request_attachments
{ "id": "f1f1f1f1-0000-4000-8000-000000000001", "request_id": "e0e0e0e0-0000-4000-8000-000000000001",
  "customer_id": "c1c1c1c1-0000-4000-8000-000000000001",
  "storage_path": "c1c1c1c1-0000-4000-8000-000000000001/req/e0e0e0e0-0000-4000-8000-000000000001/f1f1f1f1.jpg",
  "mime": "image/jpeg", "bytes": 412345, "checksum": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" }

POST /api/v1/uploads/sign
{ "resource": "REQUEST_ATTACHMENT", "id": "f1f1f1f1-0000-4000-8000-000000000001" }
-> 200 { "id": "f1f1f1f1-...", "method": "PUT", "upload_url": "https://<project>.supabase.co/storage/v1/object/upload/sign/wo-media/...?token=...",
         "max_bytes": <[P]>, "expires_at": "2026-11-02T07:10:00Z" }
(klien PUT berkas ke upload_url)
POST /api/v1/uploads/complete
{ "resource": "REQUEST_ATTACHMENT", "id": "f1f1f1f1-0000-4000-8000-000000000001" }
-> 200 { "id": "f1f1f1f1-...", "upload_status": "UPLOADED" }
```

### 9.2 Admin memvalidasi dan membuat WO (T-01)

```http
POST /api/v1/service-requests/e0e0e0e0-0000-4000-8000-000000000001/approve
If-Match: "1"

{ "priority_code": "HIGH", "service_type_id": "5e5e5e5e-0000-4000-8000-000000000001" }
```

`priority_code` hanya contoh dari seed D25 (`LOW, NORMAL, HIGH, CRITICAL`). Fasad memanggil `rpc/request_decide` dengan `p_decision = 'APPROVE'`:

```http
HTTP/1.1 200 OK
{ "decision": "APPROVE", "wo_id": "b0b0b0b0-0000-4000-8000-000000000001", "wo_number": "WO-2026-000123" }
```

Pada WO baru: `billing_type`, `response_due_at`, `policy_snapshot` dihitung server dari kontrak/kebijakan SLA yang dikonfigurasi (kosong sampai bisnis mengisi; `NOT_TRACKED` bila tanpa kebijakan, D25). Aset bukan milik pemohon ditolak oleh FK komposit `(asset_id, customer_id)`.

### 9.3 Dispatcher menugaskan (T-02)

```http
POST /api/v1/work-orders/b0b0b0b0-0000-4000-8000-000000000001/assign
Idempotency-Key: 0192f220-0000-7000-8000-000000000001
If-Match: "1"

{ "technician_id": "7e7e7e7e-0000-4000-8000-000000000001",
  "scheduled_start": "2026-11-03T02:00:00Z", "scheduled_end": "2026-11-03T04:00:00Z" }
```

Peringatan lunak (D20) menolak sampai `override_reason` diisi:

```http
HTTP/1.1 422 Unprocessable Content
{ "type": "/problems/soft-guard", "title": "Perlu konfirmasi dispatcher", "status": 422,
  "detail": "Teknisi memiliki tugas lain pada jam yang sama. Isi override_reason untuk melanjutkan.",
  "code": "SOFT_GUARD", "db_sqlstate": "WO003", "request_id": "req_01JABCYAA",
  "warnings": [ { "code": "SCHEDULE_OVERLAP" } ] }
```

Berhasil:

```http
HTTP/1.1 200 OK
{ "status": "ASSIGNED", "display_status": "RECEIVED", "version": 2, "replayed": false, "warnings": [] }
```

`display_status` tetap `RECEIVED` (DEC-02); pelanggan melihat `SCHEDULED` setelah T-03.

### 9.4 Teknisi menerima dan check-in via sinkron (offline lalu online)

```http
POST /api/v1/sync/push

{ "device_id": "dev-7e7e7e7e-pwa-01", "schema_version": 1, "client_time": "2026-11-03T02:05:00Z",
  "ops": [
    { "op_id": "0192f300-0000-7000-8000-000000000001", "seq": 1, "wo_id": "b0b0b0b0-0000-4000-8000-000000000001",
      "type": "ACCEPT", "base_version": 2, "client_captured_at": "2026-11-02T08:30:00Z", "payload": {} },
    { "op_id": "0192f300-0000-7000-8000-000000000002", "seq": 2, "wo_id": "b0b0b0b0-0000-4000-8000-000000000001",
      "type": "CHECK_IN", "base_version": 3, "client_captured_at": "2026-11-03T02:01:12Z",
      "payload": { "lat": -6.2, "lng": 106.8, "accuracy_m": 18 } } ] }
```

```http
HTTP/1.1 200 OK
{ "server_time": "2026-11-03T02:05:01Z",
  "results": [
    { "op_id": "0192f300-0000-7000-8000-000000000001", "status": "ACKED", "db_status": "APPLIED", "replayed": false,
      "result": { "status": "ACCEPTED", "version": 3, "replayed": false } },
    { "op_id": "0192f300-0000-7000-8000-000000000002", "status": "ACKED", "db_status": "APPLIED", "replayed": false,
      "result": { "status": "IN_PROGRESS", "version": 4, "replayed": false } } ] }
```

Padanan online: `POST /work-orders/{id}/check-in`. Tanpa izin GPS, `lat/lng` kosong dan `no_gps_reason` wajib (`GPS_OR_REASON_REQUIRED`), bukan memblokir. Bila WO dibatalkan saat offline:

```json
{ "op_id": "0192f300-0000-7000-8000-000000000002", "status": "REJECTED", "db_status": "RESCUED",
  "code": "CONFLICT_CANCELLED", "detail": "WO dibatalkan oleh admin. Data Anda disimpan sebagai draf." }
```

### 9.5 Teknisi menambah suku cadang (L2)

1. Minta (RPC `part_request_create`, lewat sinkron `CREATE_PART_REQUEST`):

```http
POST /api/v1/work-orders/b0b0b0b0-0000-4000-8000-000000000001/part-requests
{ "lines": [ { "item_id": "1a1a1a1a-0000-4000-8000-000000000001", "qty": 2 } ], "note": "Filter dan kapasitor" }
-> 201 { "id": "0192f400-0000-7000-8000-000000000001" }
```

2. Gudang menyetujui lalu menyerahkan **per baris** (`part_request_decide`, `part_issue`):

```http
POST /api/v1/part-requests/0192f400-0000-7000-8000-000000000001/decision   { "decision": "APPROVE" }
POST /api/v1/part-request-lines/ab000000-0000-4000-8000-000000000001/issue { "qty": 2 }
```

Stok kurang:

```http
HTTP/1.1 409 Conflict
{ "type": "/problems/insufficient-stock", "title": "Stok tidak cukup", "status": 409,
  "detail": "Stok gudang untuk item ini tidak mencukupi jumlah yang diminta.",
  "code": "INSUFFICIENT_STOCK", "db_sqlstate": "STK01", "request_id": "req_01JABCYBB" }
```

3. Teknisi mencatat pemakaian: INSERT langsung, **tanpa `RETURNING`** (D16):

```http
POST /rest/v1/wo_part_usages
Prefer: return=minimal

{ "id": "0192f402-0000-7000-8000-000000000001", "wo_id": "b0b0b0b0-0000-4000-8000-000000000001",
  "item_id": "1a1a1a1a-0000-4000-8000-000000000001", "qty": 1, "op_id": "0192f402-0000-7000-8000-0000000000aa" }
-> 201 (tanpa body)
```

Klien tidak mengirim harga; `unit_price_snapshot`, `billable`, `technician_id` diisi trigger. Item `is_extra` tanpa persetujuan APPROVED:

```http
HTTP/1.1 400 Bad Request   (PostgREST; fasad: 422)
{ "code": "WO003", "message": "WO003: biaya tambahan hanya boleh dicatat dengan persetujuan APPROVED (BR-052)",
  "details": "{\"code\":\"EXTRA_COST_NOT_APPROVED\"}" }
```

Sisa barang: `POST /work-orders/{id}/part-returns` (PENDING), lalu Gudang `POST /part-returns/{id}/confirm`. Selisih `issued - used - returned` dihitung database (BR-031).

### 9.6 Meminta dan memutuskan persetujuan biaya tambahan (L2)

Teknisi mengajukan (harga LABOR/PART dari master):

```http
POST /api/v1/work-orders/b0b0b0b0-0000-4000-8000-000000000001/extra-cost-approvals
Idempotency-Key: 0192f500-0000-7000-8000-000000000001
If-Match: "5"

{ "reason": "Kompresor perlu diganti; kerusakan baru ditemukan setelah pembongkaran.",
  "items": [ { "kind": "PART", "ref_id": "1a1a1a1a-0000-4000-8000-000000000002", "description": "Kompresor", "qty": 1 },
             { "kind": "LABOR", "ref_id": "5b5b5b5b-0000-4000-8000-000000000001", "description": "Penggantian", "qty": 1 } ] }

HTTP/1.1 201 Created
{ "status": "AWAITING_CUSTOMER_APPROVAL", "version": 6, "replayed": false,
  "approval_id": "0192f500-0000-7000-8000-0000000000a1", "approval_version": 1,
  "content_hash": "7d1c...e9", "total": 1250000.00 }
```

(`total` ilustrasi; UI teknisi tidak menampilkannya, G-08.) Pelanggan membaca rincian dari `customer_extra_cost_approvals` (`approval_id`, `version_no`, `status`, `total`, `reason`, `expires_at`, `content_hash`, `items[]`) dan memutuskan:

```http
POST /api/v1/extra-cost-approvals/0192f500-0000-7000-8000-0000000000a1/decision
Idempotency-Key: 0192f501-0000-7000-8000-000000000001

{ "decision": "APPROVE", "content_hash": "7d1c...e9" }

HTTP/1.1 200 OK
{ "status": "IN_PROGRESS", "display_status": "IN_PROGRESS", "version": 7, "replayed": false }
```

Versi sudah digantikan:

```http
HTTP/1.1 409 Conflict
{ "type": "/problems/approval-version-stale", "title": "Rincian biaya sudah berubah", "status": 409,
  "detail": "Teknisi memperbarui rincian biaya. Mohon periksa kembali sebelum menyetujui.",
  "code": "APPROVAL_VERSION_STALE", "db_sqlstate": "WO004", "request_id": "req_01JABCYDD" }
```

Penolakan: `{ "decision": "REJECT", "content_hash": "...", "continue_original_scope": true }` -> T-13 (kembali `IN_PROGRESS`). Dengan `false`, WO tetap `AWAITING_CUSTOMER_APPROVAL` dan teknisi menutup lewat `submit` (T-14). ADM atas nama pelanggan menambah `"channel": "PHONE", "evidence_note": "..."` (bukan `PWA`).

### 9.7 Menutup WO (T-16)

`POST /sync/push` dengan `SUBMIT_REVIEW` (padanan: `POST /work-orders/{id}/submit`):

```http
POST /api/v1/work-orders/b0b0b0b0-0000-4000-8000-000000000001/submit
Idempotency-Key: 0192f600-0000-7000-8000-000000000001
If-Match: "9"

{ "outcome": "RESOLVED", "client_pending_ops": 0, "lat": -6.2, "lng": 106.8 }
```

Belum lengkap: seluruh kekurangan sekaligus (DETAIL array jsonb WO003):

```http
HTTP/1.1 422 Unprocessable Content
{ "type": "/problems/closure-requirements-not-met", "title": "WO belum bisa ditutup", "status": 422,
  "detail": "Lengkapi foto sesudah dan tanda tangan pelanggan, atau pilih pengecualian dengan alasan.",
  "code": "CLOSURE_REQUIREMENTS_NOT_MET", "db_sqlstate": "WO003", "request_id": "req_01JABCYEE",
  "unmet": [ { "code": "PHOTO_MISSING", "kind": "AFTER" }, { "code": "SIGNATURE_MISSING" } ] }
```

Pelanggan tidak di lokasi: sertakan `closure_exception_code: "CUSTOMER_ABSENT"` dan `closure_exception_note`. Berhasil:

```http
HTTP/1.1 200 OK
{ "status": "UNDER_REVIEW", "display_status": "IN_PROGRESS", "version": 10, "replayed": false, "warnings": [] }
```

Jalur tanda tangan lewat PWA pelanggan (SP-07): teknisi `request-signoff` (T-17); pelanggan mengunggah gambar lewat `POST /uploads/sign` dengan `resource: WO_SIGNATURE_PWA`, `wo_id`, `file_name` (barisnya baru dibuat oleh `wo_customer_sign`, jadi tidak ada metadata lebih dulu; API memeriksa `customer_owns_wo` dan status `AWAITING_SIGNOFF`), PUT, `complete`, lalu `POST /work-orders/{id}/signoff` dengan `signer_name` dan `storage_path` (T-18).

### 9.8 Review supervisor (L2, T-19/T-20)

```http
POST /api/v1/work-orders/b0b0b0b0-0000-4000-8000-000000000001/review/return
Idempotency-Key: 0192f700-0000-7000-8000-000000000001
If-Match: "10"

{ "reason": "Foto sesudah kurang jelas dan nomor serial kompresor baru belum dicatat." }

HTTP/1.1 200 OK
{ "status": "RETURNED", "display_status": "IN_PROGRESS", "version": 11, "replayed": false }
```

Pelanggan tidak melihat kemunduran. Teknisi menerima catatan lewat pull, memanggil `resume-after-return` (T-21), lalu `submit` ulang. Persetujuan:

```http
POST /api/v1/work-orders/b0b0b0b0-0000-4000-8000-000000000001/review/approve
Idempotency-Key: 0192f701-0000-7000-8000-000000000001
If-Match: "13"

{ "approve_exception": true, "comment": "Lengkap." }

HTTP/1.1 200 OK
{ "status": "CLOSED", "display_status": "COMPLETED", "version": 14, "replayed": false, "warnings": [] }
```

`approve_exception` hanya relevan bila WO punya pengecualian (BR-041); tanpanya `CLOSURE_EXCEPTION_NOT_APPROVED`. Penutupan membuat baris `service_reports` revisi 1 status `GENERATING`; worker `render_reports` merender PDF lalu `READY`. Pelanggan mendapatkan laporan dari `customer_service_reports` (hanya `READY`) dan mengunduh:

```http
POST /api/v1/files/download-urls
{ "items": [ { "type": "SERVICE_REPORT", "id": "5a5a5a5a-0000-4000-8000-000000000001" } ] }

HTTP/1.1 200 OK
{ "items": [ { "type": "SERVICE_REPORT", "id": "5a5a5a5a-0000-4000-8000-000000000001",
               "url": "https://<project>.supabase.co/storage/v1/object/sign/reports/...?token=...",
               "expires_at": "2026-11-03T05:25:00Z" } ] }
```

---

## 10. Asumsi, Gap, dan Pertanyaan Terbuka

### 10.1 Asumsi desain API (direvisi terhadap 05)

| ID | Asumsi (draf 0.2) | Perubahan terhadap draf 0.1 |
|---|---|---|
| API-AS-01 | Route Handler memanggil RPC/tabel dengan JWT pengguna; `service_role` hanya untuk daftar tertutup 05 bagian 6.3 (ditambah kebutuhan G-06, G-07). | Tetap; diperketat ke daftar 05. |
| API-AS-02 | Teknisi menulis hanya lewat `/sync/push`; endpoint transisi dan tulis lapangan ada untuk uji/back-office. | Tetap. Tulis lapangan kini dijelaskan sebagai **Jalur A** (hak kolom), bukan endpoint Jalur B. |
| API-AS-03 | ~~Lapis 1 menutup WO otomatis (T-19 oleh SYS) lewat `requires_supervisor_review=false`~~ | **Dicabut**: bertentangan dengan 04 (T-19 hanya `SUPERVISOR`, tidak ada setting itu). Menjadi G-01. |
| API-AS-04 | ~~Tafsiran T-13/T-14 lewat field `continue_original_scope` pada endpoint approve/reject terpisah~~ | **Disesuaikan**: tafsiran dikonfirmasi D08, tetapi keputusan satu endpoint `decision`; `wo_transition` menolak T-12/T-13/T-15 tanpa keputusan tercatat. |
| API-AS-05 | ~~Teknisi tidak melihat harga; item bebas tanpa katalog tidak didukung~~ | **Dicabut sebagian**: item `OTHER` didukung dengan `unit_price` dari pengaju (04). Harga LABOR/PART tetap dari master. Risiko pengungkapan angka ke teknisi menjadi G-08. |
| API-AS-06 | ~~Foto yang sudah ACK tidak bisa dihapus teknisi; tombstone hanya jasa/suku cadang~~ | **Dicabut**: 05 memberi TEK `update (deleted_at)` pada `wo_attachments`; tombstone foto diizinkan (`TOMBSTONE_PHOTO`). Matriks 02 ("tidak bisa hapus setelah sinkron") bertentangan dengan 05; perlu keputusan. |
| API-AS-07 | PLG mengajukan komplain; ADM/SPV membuat WO REWORK. | Diperkuat D09: `wo_create_rework` oleh ADM/SPV; komplain = INSERT Jalur A. |
| API-AS-08 | Pelanggan membatalkan hanya dari NEW; setelah itu mengajukan (`wo_request_cancel` mencatat di `work_orders.cancel_requested_*`). | Disesuaikan D10; tidak ada tabel `wo_cancel_requests`. |
| API-AS-09 | Unggah lewat signed upload URL; **tanpa TUS** (foto kecil setelah kompresi). | TUS dihapus dari kontrak; evaluasi bila unggahan sering terputus. |
| API-AS-10 | Keanggotaan pelanggan via `customer_users` (N:M); tanpa klaim JWT. | Menggantikan klaim `customer_id`/`site_scope`; pemisahan cabang = OQ-03, belum ada model. |
| API-AS-11 | Realtime hanya tabel; pelanggan berlangganan `notifications` atau `service_requests` (RLS langsung) lalu memuat ulang view. | Disesuaikan 05 bagian 8. |
| API-AS-12 | Resolusi selisih: GDG/SPV untuk `EXPLAINED/RETURNED_LATE`; hanya SPV untuk `WRITTEN_OFF/CHARGED_TO_CUSTOMER`. | Dikonfirmasi 04. |
| API-AS-13 | Kunjungan gagal memakai T-27 (`VISIT_FAILED`, ke `NEW`, foto `FAILED_VISIT` wajib). | Dikonfirmasi D11. |
| API-AS-14 (baru) | Pemesanan pelanggan = INSERT Jalur A; batas laju per pelanggan di trigger. | Menggantikan `POST /service-requests`; batas IP perlu keputusan (G-02). |
| API-AS-15 (baru) | `notifications` adalah antrean; tidak ada `domain_events`. | Menggantikan outbox terpisah. |

### 10.2 Gap terhadap 04/05 (untuk diputuskan pengguna; 04 tidak diubah)

Tabel yang diminta sebelumnya: `idempotency_keys` (tidak ada, G-03), `domain_events` (tidak diperlukan, API-AS-15), `sync_changes` (tidak ada, G-05), `wo_cancel_requests` (tidak diperlukan, kolom di `work_orders`), `push_subscriptions` (tidak ada, G-11), `job_runs` (**ada**).

| ID | Gap | Dampak pada API | Opsi |
|---|---|---|---|
| G-01 | T-19 hanya `SUPERVISOR`; tidak ada pengaturan penutupan otomatis | Demo Lapis 1 (teknisi tutup lalu laporan terbit) butuh akun SPV yang menyetujui; PRD memasukkan review SPV ke Lapis 2 | (a) terima SPV di demo L1; (b) tambah setting dan `allow_system` untuk `APPROVE_CLOSE` di 04 |
| G-02 | Batas laju IP tidak mungkin untuk INSERT `service_requests` lewat PostgREST (04 menyebut IP di edge/Next.js) | Hanya batas per pelanggan di trigger | (a) terima; (b) pemesanan lewat Route Handler (satu endpoint) |
| G-03 | Tidak ada `idempotency_keys` | RPC tanpa `p_op_id` (`part_request_create`, `part_return_create`, `wo_request_help`, `stock_receive`, `stock_adjust`, `part_issue`) tidak idempoten pada retry di luar sinkron | tambah `p_op_id` + tabel atau andalkan `sync_operations` untuk jalur teknisi |
| G-04 | `wo_signatures` tanpa `upload_status` | BR-040 butir 4 tidak memeriksa gambar tanda tangan sudah terunggah; `/uploads/complete` hanya memverifikasi objek | tambah kolom `upload_status` dan cek di `wo_submit_deficiencies` |
| G-05 | Tidak ada `sync_changes`/`change_seq`/tombstone | Pull berbasis `updated_at` per tabel + `active_wo_ids`; tidak ada jaminan anak WO menaikkan `updated_at` induk | tambah umpan perubahan atau trigger yang menaikkan `work_orders.updated_at` dari anak |
| G-06 | `sync_operations`: klien tanpa hak UPDATE status/hasil; service role untuk itu tidak ada di daftar 05 bagian 6.3; tidak ada RPC/kolom untuk menyelesaikan draf `RESCUED`; beberapa RPC tanpa `p_op_id` | `/sync/push` butuh service role untuk status/hasil; draf tidak bisa di-dismiss/tautkan; replay CREATE_PART_* bergantung `sync_operations` | tambah daftar service role (h), RPC `sync_op_record(op_id, status, result)`, kolom `resolved_*`, dan `p_op_id` pada RPC terkait |
| G-07 | `app.run_job` tidak terekspos PostgREST | Cadangan `pg_cron` (job aplikasi dan DB) tidak bisa dipicu dari Route Handler | tambah `public.run_job` khusus `service_role` |
| G-08 | TEK dapat `SELECT` seluruh kolom `work_orders` (mis. `estimate_total`, `billing_*`) dan RPC `wo_cost_summary`/`extra_cost_request` mengembalikan angka rupiah | Bertentangan dengan AP-2 bila UI teknisi mengambilnya | view `tech_work_orders` tanpa kolom harga + cabut SELECT tabel untuk TEK; RPC tanpa total untuk TEK |
| G-09 | `stock_adjust` tanpa alur persetujuan dua langkah (hanya ambang SPV) | Tidak ada `POST /stock/adjustments/{id}/approve` | terima atau tambah status `PENDING_APPROVAL` |
| G-10 | Lapis 3: RPC invoice (terbit, pembayaran), ekspor CSV, impor Excel, anonimisasi, UI/RPC admin pelanggan, dashboard selain `v_kpi_sla_monthly` belum ada | Endpoint Lapis 3 di `openapi.yaml` adalah rencana kontrak | implementasi di 04 saat Lapis 3 dikerjakan |
| G-11 | Tidak ada `push_subscriptions`; tidak ada RPC consent ulang; `report.ready`/`invoice.issued` belum menghasilkan notifikasi; tidak ada endpoint retry notifikasi (service role di luar daftar) | Web Push (L2 C), WhatsApp (D5) belum bisa; retry manual ADM ditiadakan | tambah tabel/RPC saat dibutuhkan |
| G-12 | Tidak ada RPC: ubah jadwal tanpa `REASSIGN`; serah-terima mid-visit; pengakuan eskalasi SLA (`sla_events.acknowledged_*`); pratinjau syarat penutupan (`app.wo_submit_deficiencies` tak terekspos) | Dispatcher mengubah jadwal lewat `REASSIGN`; PWA menghitung kekurangan lokal dan mengandalkan penolakan WO003 | tambah RPC `wo_closure_check`, `sla_acknowledge`, `wo_reschedule` |
| G-13 | `work_orders.no_parts_used` (BR-040 butir 6) tidak punya jalur tulis (TEK tanpa UPDATE `work_orders`, tanpa RPC) | Teknisi tidak bisa menyatakan "tidak ada suku cadang dipakai", sehingga `PARTS_NOT_DECLARED` tak dapat dihindari pada WO tanpa suku cadang | tambah RPC `wo_declare_no_parts` |

### 10.3 TODO lain

- Tetapkan semua nilai [P] (ukuran halaman, batas laju, umur signed URL, kedaluwarsa persetujuan/tanda tangan, batas batch sync, ukuran foto, ambang `clock_skew`).
- Pilih penyedia email dan kebijakan WhatsApp (D5, D6); format ekspor invoice (D12).
- Uji kontrak otomatis: tiap endpoint di `openapi.yaml` per peran (matriks 403/404 dan uji isolasi 05 bagian 7), uji replay `op_id`, uji sinkron konflik `CONFLICT_*`, uji `Prefer: return=minimal` pada PostgREST Supabase nyata (belum diuji, 05 bagian 10).

### 10.4 Pertanyaan terbuka yang memengaruhi API

| ID | Pertanyaan | Rujukan |
|---|---|---|
| Q-API-1 | Model akun pelanggan (undangan, mandiri, keduanya); korporat mandiri? | D1, OQ-04 |
| Q-API-2 | Jam SLA mulai dari permintaan atau WO (`sla.clock_starts_at`)? | OQ-06, OQ-11, D13 |
| Q-API-3 | Satu WO banyak aset? (`asset_id` menjadi larik) | OQ-23 |
| Q-API-4 | Prosedur darurat tanpa persetujuan biaya (`emergency`) dan siapa menyetujui | OQ-19 |
| Q-API-5 | Perubahan bermakna yang membatalkan tanda tangan (definisi `app.wo_content_hash`) | OQ-18, D12 |
| Q-API-6 | Foto yang sudah terkirim: boleh di-tombstone teknisi (05) atau tidak (matriks 02)? | API-AS-06 |
| Q-API-7 | Endpoint hak subjek data UU PDP (ekspor/anonimisasi) belum didesain | OQ-21 |
