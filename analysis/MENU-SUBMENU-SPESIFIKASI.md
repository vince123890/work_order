# Spesifikasi Menu & Sub Menu — VASTA Field Service & Work Order Management

| | |
|---|---|
| Dokumen | MS-01 |
| Versi | 1.0 (POC) |
| Sudut pandang | Developer: "layar apa saja yang saya buat dan apa isinya" |
| Turunan dari | `analysis/01_system_analysis.md`, `docs/01_PRD.md` (Bagian 8), `docs/02_business_analysis_technical_logic.md`, `docs/03_api_design.md`, `docs/04_database_schema.sql`, `docs/05_rls_and_security.md` |
| Status | Menu & sub menu selesai. Belum ada angka mandays (dikerjakan di tahap estimasi) |

## Cara membaca

Setiap sub menu dibahas dari **lima sudut pandang**: ① List · ② Sync · ③ Create/Edit/Upload · ④ View Detail + Approval · ⑤ Delete. Bagian yang tidak berlaku ditulis **"— tidak ada —"** beserta alasannya (ketiadaan tombol adalah keputusan, bukan kelalaian).

| Penanda | Arti |
|---|---|
| ✅ **TERKONFIRMASI** | Disebut eksplisit di dokumen sumber |
| ⚠️ **ASUMSI** | Turunan rancangan, perlu konfirmasi saat UAT |
| 🔒 **MENUNGGU** | Bergantung pertanyaan terbuka (OQ) yang belum dijawab |
| `[+]` | Usulan analis, tidak ada di dokumen sumber |

Ini POC: keputusan terbuka diserahkan ke agent dan diberi tanda ⚠️. Perubahan dilakukan atas permintaan user.

---

## ⚠️ Keputusan yang Mengubah Bentuk Aplikasi

Jawaban atas tujuh pertanyaan pembentuk aplikasi (ditetapkan oleh analis karena POC; semuanya ⚠️ ASUMSI kecuali dinyatakan lain).

| # | Keputusan | Akibat pada menu |
|---|---|---|
| 1 | **Autentikasi berdiri sendiri** (skenario A, Supabase Auth). Staf: email+sandi. Pelanggan: undangan sekali pakai atau OTP | Ada menu Pengguna & Peran, halaman Masuk/Daftar/Lupa sandi. Tidak ada SSO |
| 2 | **Semua master dimiliki sistem ini** (CRUD penuh); tidak ada sinkronisasi master dari sistem lain | Semua kolom **Sync** bertuliskan "— tidak ada —". Impor Excel hanya pemuatan data awal |
| 3 | **Approval sungguhan, 6 titik**: validasi permintaan (Admin), biaya tambahan (Pelanggan), review WO (Supervisor), pengecualian penutupan (Supervisor), selisih stok (Supervisor), penyesuaian stok di atas ambang [P] (Supervisor) | Ada menu **Persetujuan** terpusat; tiap titik punya log (siapa, kapan, catatan) |
| 4 | **Tidak ada hapus fisik.** Master: nonaktifkan (soft delete). Riwayat status, audit, mutasi stok, tanda tangan: **immutable**, koreksi lewat entri pembalik/revisi | Kolom Delete = Nonaktifkan atau "— tidak ada —". Ada layar **Koreksi stok (reversal)** |
| 5 | **Integrasi minim**: email, in-app, Web Push (opsional), WhatsApp `wa.me` (default), ekspor CSV. Tidak ada ERP/payment gateway/SSO | Tidak ada menu "Integrasi". Pengaturan kanal ada di Notifikasi |
| 6 | **Laporan tetap** (daftar & kolom ditentukan), bukan report builder | Katalog laporan (Bagian Laporan), tiap laporan punya panel filter sendiri |
| 7 | **Dashboard satu halaman, isi menyesuaikan peran** | Widget × Role (Bagian 1) |
| 8 | **Tiga permukaan**: PWA Teknisi (offline-first), PWA Pelanggan (online + riwayat offline), Web Internal (desktop) ✅ | Tiga peta menu terpisah |
| 9 | **Teknisi tidak melihat harga**; pelanggan tidak melihat biaya internal | Kolom harga/margin tidak ada di layar teknisi/pelanggan |
| 10 | **Status WO diubah hanya lewat fungsi transisi server** (T-01..T-27) | Tidak ada form "ubah status" bebas; hanya tombol aksi sesuai status |

---

## 🗺️ Peta Menu Lengkap

### A. Web Internal (desktop)

```
VASTA Web Internal
│
├── 📊 Dashboard                              /
├── 📥 Permintaan Masuk                       /requests
│   ├── Daftar Permintaan                     /requests
│   ├── Input atas Nama Pelanggan             /requests/new
│   └── Detail & Validasi                     /requests/[id]
├── 🧾 Work Order                             /work-orders
│   ├── Daftar WO                             /work-orders
│   ├── Buat WO Manual                        /work-orders/new
│   └── Detail WO                             /work-orders/[id]
│       ├── Tab Ringkasan · Penugasan · Kunjungan
│       ├── Tab Checklist & Temuan · Foto & Lampiran
│       ├── Tab Jasa & Suku Cadang · Biaya Tambahan
│       ├── Tab Tanda Tangan & Laporan · SLA · Riwayat Status
├── 🗓️ Penugasan & Jadwal                     /dispatch
│   ├── Monitor Hari Ini                      /dispatch/today
│   ├── Antrean Penugasan                     /dispatch/queue
│   └── Papan Penjadwalan (L2)                /dispatch/board
├── ✅ Persetujuan (L2)                       /approvals
│   ├── Review WO                             /approvals/review
│   ├── Pengecualian Penutupan                /approvals/close-exception
│   ├── Biaya Tambahan (atas nama pelanggan)  /approvals/extra-cost
│   └── Selisih & Penyesuaian Stok            /approvals/stock
├── ⏱️ SLA & Eskalasi (L2)                    /sla
│   ├── Monitor SLA                           /sla
│   └── Servis Berkala Terlewat               /sla/pm-missed
├── 📑 Kontrak & Berkala (L2)                 /contracts
│   ├── Daftar Kontrak                        /contracts
│   ├── Detail Kontrak (aset, frekuensi)      /contracts/[id]
│   └── Jadwal Berkala (pm_periods)           /contracts/schedule
├── 📁 Master Data                            /master
│   ├── Pelanggan                             /master/customers
│   ├── Lokasi                                /master/sites
│   ├── Aset (+ QR)                           /master/assets
│   ├── Teknisi & Keahlian                    /master/technicians
│   ├── Jenis Layanan & Jenis Masalah         /master/service-types
│   └── Template Checklist & Syarat Foto      /master/checklists
├── 📦 Gudang (L2)                            /warehouse
│   ├── Master Barang                         /warehouse/items
│   ├── Stok & Mutasi                         /warehouse/stock
│   ├── Permintaan Suku Cadang                /warehouse/requests
│   ├── Serah-Terima & Retur                  /warehouse/handover
│   ├── Selisih                               /warehouse/variance
│   └── Opname & Koreksi                      /warehouse/adjust
├── 📄 Laporan Servis                         /reports/service
├── 🔔 Notifikasi (L2)                        /notifications
│   ├── Kotak Masuk                           /notifications
│   └── Template & Kanal                      /notifications/templates
├── 💰 Finance (L3)                           /finance
│   ├── Antrean Siap Tagih                    /finance/queue
│   ├── Invoice                               /finance/invoices
│   ├── Pembayaran Tercatat                   /finance/payments
│   └── Ekspor Akuntansi                      /finance/export
├── 📑 Laporan & Statistik (L3)               /analytics
│   ├── Dashboard Manajemen                   /analytics
│   ├── Statistik Aset                        /analytics/assets
│   └── Katalog Laporan & Pencarian Lanjutan  /analytics/reports
└── ⚙️ Administrasi                           /admin
    ├── Pengguna & Peran                      /admin/users
    ├── Pengaturan (SLA, Kalender, Parameter) /admin/settings
    ├── Log Audit (L2)                        /admin/audit
    ├── Log Akses Data (L2)                   /admin/access-log
    ├── Impor Excel (L3)                      /admin/import
    └── Monitor Job & Sinkron                 /admin/jobs
```

### B. PWA Teknisi

```
VASTA Teknisi (bottom nav: Tugas Hari Ini · Semua Tugas · Sinkron · Profil)
├── Masuk / Lupa Sandi                        /t/login
├── 📋 Tugas Hari Ini                         /t
├── 📋 Semua Tugas                            /t/tasks
├── 🧾 Detail WO                              /t/wo/[id]
│   ├── Terima / Tolak / Minta Bantuan
│   ├── Berangkat · Check-in · Check-out
│   ├── Detail Aset & Riwayat Singkat
│   ├── Checklist · Temuan/Diagnosa · Catatan
│   ├── Foto Sebelum/Sesudah
│   ├── Jasa & Suku Cadang Dipakai (L2 terhubung stok)
│   ├── Minta Suku Cadang · Retur Sisa (L2)
│   ├── Ajukan Biaya Tambahan (L2)
│   ├── Tanda Tangan Pelanggan & Tutup WO
│   └── Hasil Review / WO Dikembalikan (L2)
├── 🔲 Pindai QR Aset                         /t/scan
├── 🔄 Sinkron & Antrean Offline              /t/sync
└── 👤 Profil & Perangkat                     /t/profile
```

### C. PWA Pelanggan

```
VASTA Pelanggan (bottom nav: Beranda · Pesan Servis · Pesanan · Aset · Akun)
├── Masuk / Daftar / Lupa Sandi / Terima Undangan   /c/login
├── 🏠 Beranda (pesanan aktif)                      /c
├── ➕ Pesan Servis                                  /c/order
├── 🧾 Pesanan                                      /c/orders
│   └── Detail Pesanan                              /c/orders/[id]
│       ├── Status 6 tahap
│       ├── Persetujuan Biaya Tambahan (L2)
│       ├── Tanda Tangan Penerimaan (L2)
│       ├── Unduh Laporan (L2)
│       └── Nilai & Komplain (L2)
├── 🏷️ Aset                                         /c/assets
│   └── Detail Aset (riwayat · jadwal berkala L3)
├── 🗓️ Jadwal Berkala & Kontrak (L3)                /c/schedule
├── 💳 Invoice & Pembayaran (L3)                    /c/invoices
└── 👤 Akun (profil, pengguna perusahaan L3)        /c/account
```

**Hitungan**: 3 permukaan · Web 14 menu utama (47 sub menu/halaman) · PWA Teknisi 7 layar utama · PWA Pelanggan 8 layar utama · **6 titik approval**.

### Menu × Role (Web Internal)

Legenda: **C** buat · **R** baca · **U** ubah · **D** nonaktifkan · **A** setujui/putuskan · **X** aksi khusus · `*` milik sendiri/ditugaskan · `-` tidak ada.
Kolom: ADM Admin/CS · DSP Dispatcher · SPV Supervisor · GDG Gudang · FIN Finance · OWN Pemilik/Manajer.

| Menu | ADM | DSP | SPV | GDG | FIN | OWN |
|---|---|---|---|---|---|---|
| Dashboard | R | R (operasional) | R | R (stok) | R (keuangan) | R |
| Permintaan Masuk | C R U A | R | R | - | R | R |
| Work Order | C R U X | R U X | R A X | R (suku cadang) | R | R |
| Penugasan & Jadwal | R | C R U X | R | - | - | R |
| Persetujuan | X (biaya atas nama) | - | R A | A (stok) | - | R |
| SLA & Eskalasi | R | R X (akui) | R | - | - | R |
| Kontrak & Berkala | C R U D | R | R | - | R | R A (opsional) |
| Master Data | C R U D | R | R | - | R | R |
| Gudang | R | R | R A | C R U D | R | R |
| Laporan Servis | R | R | R X (terbit ulang) | - | R | R |
| Notifikasi | R U* | R U* | R U* | R U* | R U* | C R U D |
| Finance | R | - | R | - | C R U X | R |
| Laporan & Statistik | - | R | R | - | R | R |
| Administrasi | C R U D (pengguna), X (impor) | - | R (audit terbatas) | X (impor stok) | - | R, C R U D (SLA/kalender) |

---

# 0. 👥 Role & Kewenangan per Modul

## 0.1 Daftar role

| Role | Permukaan | Boleh | **Tidak** boleh |
|---|---|---|---|
| Pelanggan ✅ | PWA Pelanggan | Pesan servis, lihat aset/pesanan/dokumen sendiri, putuskan biaya tambahan, tanda tangan, unduh laporan, nilai, komplain | Melihat data pelanggan lain, melihat biaya internal/HPP, membaca tabel mentah `work_orders` |
| Admin Pelanggan ⚠️ (L3) | PWA Pelanggan | Semua pelanggan + kelola pengguna perusahaannya | Mengelola perusahaan lain |
| Admin/CS ✅ | Web | Validasi permintaan, master data, kontrak, input atas nama pelanggan, batalkan WO | Menyetujui laporan (hak SPV), mengubah SLA (hak OWN) |
| Dispatcher ✅ | Web | Tugaskan/tugaskan ulang, jadwal, monitor | Mengubah master, menyetujui |
| Teknisi ✅ | PWA Teknisi | WO yang ditugaskan: terima/tolak, check-in/out, checklist, foto, tanda tangan, ajukan biaya | Melihat harga/margin, menghapus foto terkirim, melihat WO orang lain |
| Supervisor ✅ | Web | Review, override dengan alasan, putuskan selisih, pengecualian penutupan | Membuat invoice |
| Gudang ✅ | Web | Master barang, mutasi, serah-terima, opname | Menyetujui selisih sendiri |
| Finance ✅ | Web | Invoice, pembayaran tercatat, ekspor | Mengubah data kerja WO |
| Pemilik/Manajer ✅ | Web | Dashboard, audit, konfigurasi SLA/kalender ⚠️ | Mengubah data operasional harian |

## 0.2 Matriks permission

Permission teknis diperiksa **di backend/RLS**, role hanya pengelompokan. Peran dibaca dari tabel (`user_roles`, `customer_users`), bukan hanya JWT.

| Permission | Pemilik role |
|---|---|
| `request.create` / `request.validate` | PLG, ADM / ADM |
| `wo.create` `wo.transition` `wo.cancel` | ADM, DSP, SPV (sesuai tabel transisi) |
| `wo.assign` | DSP |
| `wo.field_write` (checklist, foto, check-in) | TEK (hanya WO ditugaskan) |
| `wo.review` `wo.close_exception` | SPV |
| `extra_cost.request` / `extra_cost.decide` | TEK / PLG (SPV override, ADM atas nama + bukti) |
| `stock.move` `stock.adjust` `stock.variance.decide` | GDG / GDG+SPV / SPV |
| `contract.manage` | ADM |
| `invoice.issue` `invoice.export` `payment.record` | FIN |
| `settings.sla` `settings.calendar` | OWN (⚠️ atau ADM, OQ-12) |
| `user.manage` | ADM |
| `audit.read` `access_log.read` | OWN, SPV (terbatas) |
| `import.run` | ADM, GDG (stok) |
| `analytics.read` | DSP, SPV, FIN, OWN (per widget) |

Sumber: matriks 02 §1.3 dan 05 (RLS). **Segregation of Duties** (per record): penyetuju selisih stok ≠ pembuat mutasi; pengaju biaya tambahan (teknisi) ≠ pemutus (pelanggan/SPV); Supervisor tidak me-review WO yang ia kerjakan sendiri ⚠️.

## 0.3 Bila satu orang memegang dua role ⚠️
Role bersifat himpunan (user dapat punya beberapa baris `user_roles`). Aturan SoD per record tetap berlaku: satu orang tidak bisa menyetujui hal yang ia ajukan sendiri.

---

# 1. 📊 Dashboard

## 1.1 Prinsip
Satu halaman `/`; widget tampil sesuai role. Lapis 1: daftar operasional hari ini. Lapis 3: dashboard manajemen penuh (modul Laporan & Statistik).

## 1.2 Daftar widget

| # | Widget | Isi & sumber | Lapis |
|---|---|---|---|
| W1 | Pekerjaan hari ini | WO terjadwal hari ini + status (`work_orders`, `wo_assignments`) | 1 |
| W2 | Permintaan menunggu validasi | Jumlah & umur (`service_requests`) | 1 |
| W3 | WO belum ditugaskan | Antrean dispatcher | 1 |
| W4 | WO mendekati/lewat SLA | `sla_events` | 2 |
| W5 | Menunggu persetujuan saya | Antrean `/approvals` per role | 2 |
| W6 | Servis berkala terlewat | `pm_periods` | 2 |
| W7 | Stok di bawah minimum | `stock_balances` vs batas | 2 |
| W8 | Selisih suku cadang terbuka | `parts_variances` | 2 |
| W9 | WO siap ditagih | Antrean Finance | 3 |
| W10 | % WO dalam SLA (bulanan) | KPI | 3 |
| W11 | Waktu rata-rata penyelesaian | KPI | 3 |
| W12 | Produktivitas teknisi | WO selesai per teknisi | 3 |
| W13 | Perulangan kerusakan per aset | Top-N aset | 3 |
| W14 | Biaya & profit per kontrak | Butuh data biaya (OQ) | 3 |

## 1.3 Widget × Role

| Widget | ADM | DSP | SPV | GDG | FIN | OWN | Alasan pembatasan |
|---|---|---|---|---|---|---|---|
| W1 | ✓ | ✓ | ✓ | - | - | ✓ | Operasional |
| W2 | ✓ | - | ✓ | - | - | ✓ | Hak validasi di ADM |
| W3 | - | ✓ | ✓ | - | - | ✓ | Hak tugaskan di DSP |
| W4 | ✓ | ✓ | ✓ | - | - | ✓ | |
| W5 | ✓ | - | ✓ | ✓ | - | ✓ | Hanya yang punya hak putus |
| W6 | ✓ | ✓ | ✓ | - | - | ✓ | |
| W7, W8 | - | - | ✓ | ✓ | - | ✓ | Data stok |
| W9 | - | - | - | - | ✓ | ✓ | Data keuangan |
| W10–W13 | - | W10 saja | ✓ | - | - | ✓ | |
| W14 | - | - | - | - | ✓ | ✓ | Biaya internal |

## 1.4 Perilaku
Angka dihitung dari record (bukan dari rentang sel); klik widget = drilldown ke daftar terfilter; refresh otomatis via Realtime untuk W1–W4 ⚠️.

## 1.5 Lima sudut pandang
① List: **— tidak ada —** (halaman widget). ② Sync: **— tidak ada —**. ③ Create/Edit: **— tidak ada —**. ④ Detail: drilldown ke modul asal. Approval: **— tidak ada —**. ⑤ Delete: **— tidak ada —**.

---

# 2. 📥 Permintaan Masuk (service_requests) ✅

**Rute**: `/requests` · **Permission**: `request.create`, `request.validate`

### 2.1 Daftar Permintaan

**① List**
| Elemen | Isi |
|---|---|
| Kolom | No. permintaan · Pelanggan · Lokasi · Aset · Jenis masalah · Kanal (PWA/Telepon/Chat) · Jadwal diinginkan · Status · Umur · Peringatan ganda |
| Search | Nomor, pelanggan, aset · debounce 300 ms |
| Filter | Status · kanal · tanggal · pelanggan · ada peringatan ganda |
| Sort / Paging | Semua kolom, default terbaru · server-side 50/halaman |
| Print/Download | Export Excel ⚠️ |
| Batch action | **— tidak ada —** (validasi satu per satu karena butuh keputusan per permintaan) |

**② Sync**: **— tidak ada —** (data masuk dari PWA/admin sendiri).
**③ Create/Edit/Upload**: lihat 2.2. Upload massal: **— tidak ada —**.
**④ Detail + Approval**: lihat 2.3.
**⑤ Delete**: **— tidak ada —** hapus. Permintaan yang tidak jadi diberi status Ditolak/Dibatalkan.

### 2.2 Input atas Nama Pelanggan ✅ (UC-03)

| Grup | Field | Catatan |
|---|---|---|
| Pelanggan | Pelanggan *, lokasi *, aset * | Aset tercakup kontrak/garansi ditandai otomatis |
| Masalah | Jenis masalah *, deskripsi, foto (jenis/ukuran divalidasi) | |
| Jadwal | Jadwal diinginkan (preferensi) | Jadwal final oleh dispatcher ✅ |
| Kanal | Telepon / Chat / Lainnya * | Wajib, tercatat di `channel` |
Validasi: peringatan pesanan ganda (aset sama + masalah serupa dalam jendela [P]); rate limit ⚠️.

### 2.3 Detail & Validasi ⭐ APPROVAL #1
**Mekanisme**:
```
  DITERIMA ──► DIVALIDASI (jadi WO)
      │   └──► MINTA INFO ──► (pelanggan menjawab) ──► DITERIMA
      └──────► DITOLAK (alasan wajib)
```
| Aksi | Siapa | Aturan |
|---|---|---|
| ✅ Setujui → buat WO | ADM | Cek pelanggan, aset, kontrak/garansi, prioritas; nomor WO unik |
| 📝 Minta info | ADM | Catatan wajib, pelanggan diberi tahu |
| ❌ Tolak | ADM | **Alasan wajib**, dialog tidak bisa ditutup tanpa diisi |
Auto-validasi untuk pelanggan kontrak aktif dengan aset tercakup: 🔒 Lapis 2 (FR-023).
**Log**: status sebelum→sesudah, oleh, kapan, catatan. Role lain: hanya baca.

---

# 3. 🧾 Work Order ✅

**Rute**: `/work-orders` · **Permission**: `wo.create`, `wo.transition`, `wo.cancel`

### 3.1 Daftar WO

**① List**
| Elemen | Isi |
|---|---|
| Kolom | No. WO · Tipe (Korektif/Preventif/Rework) · Pelanggan · Aset · Prioritas · Status (internal) · Teknisi · Jadwal · SLA (L2) · Billing type |
| Search | Nomor, pelanggan, aset, teknisi |
| Filter | Status · prioritas · pelanggan · teknisi · tanggal · tipe · SLA (L2) ✅ FR-039 |
| Sort / Paging | Default terbaru · server-side |
| Print/Download | Export Excel ⚠️; pencarian lanjutan L3 |
| Batch action | **— tidak ada —** (transisi status harus per WO) |

**② Sync**: **— tidak ada —**.
**③ Create/Edit**: Buat WO manual (tanpa permintaan, mis. preventif/rework): pelanggan, lokasi, aset, tipe, prioritas, jenis layanan, estimasi, jadwal. Edit terbatas pada status awal; field status tidak bisa diubah bebas (hanya lewat tombol transisi). Upload Excel: **— tidak ada —**.

### 3.2 Detail WO

**Tab**: Ringkasan · Penugasan (histori) · Kunjungan (check-in/out, GPS) · Checklist & Temuan · Foto & Lampiran · Jasa & Suku Cadang · Biaya Tambahan · Tanda Tangan & Laporan · SLA · Riwayat Status.

| Aksi (tombol sesuai status & role) | Siapa |
|---|---|
| Tugaskan / Tugaskan ulang | DSP |
| Batalkan (alasan wajib) | ADM, DSP, SPV (guard per status) |
| Buat WO Rework dari komplain | ADM |
| Terbitkan ulang laporan | SPV |

**Approval pada WO**: lihat Modul 5 (Persetujuan): review SPV dan pengecualian penutupan.
**Syarat penutupan (BR-040)** ✅: checklist wajib lengkap, foto yang disyaratkan, tanda tangan/persetujuan pelanggan; pengecualian hanya dengan alasan + persetujuan SPV.

**⑤ Delete**: **— tidak ada —** hapus fisik. **Batalkan** (status), bukan hapus; riwayat utuh.

---

# 4. 🗓️ Penugasan & Jadwal ✅

### 4.1 Monitor Hari Ini
① List: WO hari ini (teknisi, status, terlambat). Filter teknisi/status/wilayah. Realtime ⚠️. ②–⑤ **— tidak ada —**.

### 4.2 Antrean Penugasan
① List: WO tervalidasi belum ditugaskan + WO ditolak teknisi. ③ Aksi **Tugaskan**: pilih teknisi (kartu: keahlian, lokasi, beban, jadwal), jadwal final (tanggal + jendela), helper opsional ✅ FR-040/041/044. Peringatan bentrok/ketidakcocokan keahlian bisa di-override dengan alasan ⚠️ FR-043 (L2). Approval: **— tidak ada —** (dispatcher berwenang langsung). ⑤ **— tidak ada —**.

### 4.3 Papan Penjadwalan (L2) ✅
Kalender/papan kerja per teknisi, drag-and-drop, filter wilayah/keahlian. Perubahan jadwal memicu notifikasi ke pelanggan. Sketsa:
```
 Teknisi │ Sen 12   │ Sel 13   │ Rab 14
 Anto    │ [WO-101] │ [WO-107] │
 Budi    │ [WO-102] │          │ [WO-110]
 (kolom kiri: WO belum ditugaskan, tarik ke sel)
```
Sync/Create/Delete: **— tidak ada —**.

---

# 5. ✅ Persetujuan (L2) ⭐

Antrean terpusat untuk semua titik approval berikut. Semua aksi memeriksa permission di backend dan menulis log.

| Sub menu | Titik approval | Siapa | Aksi | Aturan |
|---|---|---|---|---|
| Review WO (#3) ✅ | WO selesai dikerjakan | SPV | Setujui · Kembalikan dengan catatan | Kembali ke teknisi + catatan; setuju → kunci snapshot & terbit PDF |
| Pengecualian Penutupan (#4) ✅ | Tutup tanpa TTD/foto/checklist lengkap | SPV | Setujui · Tolak | Alasan teknisi wajib; alasan SPV wajib saat tolak |
| Biaya Tambahan (#2) ✅ | Biaya melebihi estimasi | **Pelanggan** (PWA); ADM atas nama dengan bukti; SPV override dengan alasan | Setuju · Tolak | Pekerjaan terkait **berhenti** sampai diputuskan; keputusan hanya lewat `extra_cost_decide` |
| Selisih Stok (#5) ✅ | Barang diserahkan ≠ dipakai + dikembalikan | SPV | Putuskan (terima selisih / tagih / koreksi) | Alasan wajib |
| Penyesuaian Stok (#6) ⚠️ | Opname di atas ambang [P] | SPV | Setujui · Tolak | Pembuat (GDG) ≠ penyetuju |

**Log approval** (permanen): status sebelum→sesudah · oleh (nama, role) · kapan · catatan/alasan.
Role lain: hanya daftar, **tanpa tombol**.
① List: kolom jenis · WO/dokumen · diajukan oleh · umur · SLA. Filter jenis/status. ② Sync **— tidak ada —**. ③ Create/Edit **— tidak ada —** (item muncul dari proses lain). ⑤ Delete **— tidak ada —**.

---

# 6. ⏱️ SLA & Eskalasi (L2) ✅

### 6.1 Monitor SLA
① List: WO + tenggat respons/selesai, sisa waktu, warning/breach, level eskalasi. Filter prioritas/pelanggan/status. ③ Aksi **Akui eskalasi** (DSP) ⚠️ (gap G-12 di 03). ④ Detail: garis waktu `sla_events`, jeda (`sla_pauses`). Approval **— tidak ada —**. Sync/Delete **— tidak ada —**.
🔒 Definisi SLA (apa dihitung respons, kapan jeda) menunggu wawancara (OQ).

### 6.2 Servis Berkala Terlewat
① List: `pm_periods` lewat jatuh tempo tanpa WO selesai; aksi **Buat WO manual** / **Akui**. Sync: job `pg_cron` internal (lihat Modul 7). Lainnya **— tidak ada —**.

---

# 7. 📑 Kontrak & Berkala (L2) ✅

### 7.1 Daftar & Detail Kontrak
**① List**: No. kontrak · pelanggan · periode · frekuensi · kebijakan SLA · status. Filter status/pelanggan/jatuh tempo.
**② Sync**: **— tidak ada —**.
**③ Create/Edit**: pelanggan, periode, aset tercakup (`contract_assets`), frekuensi (bulanan/triwulan/tahunan), kebijakan SLA, aturan cakupan (penagihan). Upload Excel aset tercakup ⚠️ `[+]`.
**④ Detail**: tab Aset · Jadwal · WO terkait · SLA · Biaya & profit (L3). Approval kontrak: **— tidak ada —** (opsional OWN, OQ).
**⑤ Delete**: Nonaktifkan/akhiri kontrak; WO historis tetap.

### 7.2 Jadwal Berkala
Daftar `pm_periods` per kontrak/aset: periode, tanggal jatuh tempo, WO terbentuk, status. **Job otomatis** (`pg_cron`) membuat WO sebelum jatuh tempo, **idempoten** (tidak boleh digandakan) ✅. Tombol manual **Jalankan sekarang** (ADM) ⚠️ untuk demo. Create/Edit/Delete jadwal: **— tidak ada —** (turunan kontrak).

---

# 8. 📁 Master Data ✅ (dimiliki sistem ini, CRUD penuh)

Semua sub menu memakai pola yang sama; perbedaan field di tabel.

| Sub menu | Rute | Kolom List utama | Field Create/Edit | Delete |
|---|---|---|---|---|
| Pelanggan | `/master/customers` | Kode · Nama · Tipe (korporat/perorangan) · Kontak · Status | Identitas, kontak, tipe, undang pengguna | Nonaktifkan (blok bila punya kontrak aktif) |
| Lokasi | `/master/sites` | Pelanggan · Nama lokasi · Alamat · Koordinat | Alamat, kontak lokasi, koordinat (opsional) | Nonaktifkan |
| Aset | `/master/assets` | Kode aset · Kategori · Serial · Lokasi · Garansi s/d · Status | Kategori, serial, tanggal garansi, lokasi; **Cetak QR** | Nonaktifkan |
| Teknisi & Keahlian | `/master/technicians` | Nama · Keahlian · Wilayah · Status | Profil, keahlian (skill), wilayah, akun pengguna | Nonaktifkan (blok bila punya WO aktif) |
| Jenis Layanan & Masalah | `/master/service-types` | Kode · Nama · Template checklist | Jenis layanan, jenis masalah, kategori aset terkait | Nonaktifkan |
| Template Checklist & Syarat Foto | `/master/checklists` | Nama · Jenis layanan · Jumlah item | Item (wajib/opsional), syarat foto (sebelum/sesudah) | Nonaktifkan; versi lama tetap dipakai WO lama |

Seragam untuk semua:
- **① List**: search (nama/kode), filter status & relasi, sort, paging server-side, Export Excel ⚠️. Batch action: **— tidak ada —**.
- **② Sync**: **— tidak ada —** (milik sistem ini).
- **③ Upload Excel**: tersedia di Lapis 3 (Modul Impor) untuk Pelanggan/Lokasi/Aset/Stok; **— tidak ada —** di Lapis 1 ✅ FR-014.
- **④ Detail**: identitas + relasi (aset per lokasi, WO terkait, riwayat) + riwayat perubahan. Approval **— tidak ada —**; perubahan tercatat di audit.
- **⑤ Delete**: hanya **nonaktifkan**; tombol disabled + tooltip bila dipakai transaksi aktif.

Catatan Aset: halaman Detail Aset memuat tab **Riwayat Servis** (L1, ringkas) dan **Statistik** (L3).

---

# 9. 📦 Gudang (L2) ✅

| Sub menu | ① List | ③ Create/Edit | ④ Detail/Approval | ⑤ Delete |
|---|---|---|---|---|
| **Master Barang** | Kode · nama · satuan · batas min · stok total; filter kategori/di bawah minimum | Kode, nama, satuan, harga jual/biaya (kolom), batas minimum | — | Nonaktifkan |
| **Stok & Mutasi** | Saldo per lokasi (gudang, teknisi/kendaraan); filter lokasi/barang; mutasi ledger | Mutasi masuk manual (GDG) dengan alasan | Detail barang: ledger mutasi (immutable) | **— tidak ada —**; koreksi lewat Opname & Koreksi |
| **Permintaan Suku Cadang** | Dari teknisi/dispatcher per WO: barang, jumlah, status | Dispatcher/teknisi membuat; GDG menyetujui/menolak sebagian | Approval ringan: **GDG setujui & serahkan** | Batalkan (status) |
| **Serah-Terima & Retur** | Penyerahan ke teknisi; retur sisa | Catat serah-terima (stok gudang −, stok teknisi +); retur (kebalikan) | Detail per WO: diserahkan / dipakai / dikembalikan | **— tidak ada —**; koreksi lewat reversal |
| **Selisih** | Barang diserahkan − dipakai − dikembalikan ≠ 0 | **— tidak ada —** (otomatis `parts_variances`) | **Approval #5**: SPV putuskan + alasan | **— tidak ada —** |
| **Opname & Koreksi** | Riwayat penyesuaian | Buat penyesuaian (alasan wajib); entri pembalik untuk koreksi | **Approval #6** bila di atas ambang [P] | **— tidak ada —**; immutable, koreksi = reversal |

② Sync: **— tidak ada —** (stok dikelola sistem ini; tidak ada ERP). Upload Excel stok awal: lihat Impor Excel (L3).
Alert: stok < minimum → notifikasi & widget W7 ✅ FR-126.

---

# 10. 📄 Laporan Servis ✅

① List: No. laporan · WO · pelanggan · revisi · tanggal · status kirim. Filter pelanggan/tanggal. Download PDF.
② Sync: **— tidak ada —**.
③ Create/Edit: **— tidak ada —** manual. PDF dibuat server-side dari **snapshot data terkunci** saat WO disetujui; **Terbitkan ulang** (SPV) menaikkan nomor revisi, tidak menimpa. Isi PDF: data WO, aset, temuan, checklist, foto, jasa/suku cadang (**tanpa HPP**), tanda tangan, waktu check-in/out ✅ FR-140.
④ Detail: pratinjau PDF, riwayat revisi, status pengiriman ke pelanggan (L2). Approval: **— tidak ada —**.
⑤ Delete: **— tidak ada —** (arsip permanen).

---

# 11. 🔔 Notifikasi (L2) ✅

### 11.1 Kotak Masuk
Notifikasi in-app per pengguna: judul, WO terkait, waktu, dibaca/belum. Aksi tandai dibaca. ③ preferensi kanal per pengguna (in-app/email/push) ✅ FR-134. Delete: **— tidak ada —** (arsip).

### 11.2 Template & Kanal (OWN/ADM)
① List template per peristiwa. ③ Edit isi template (pesanan diterima, teknisi ditugaskan + jadwal, teknisi menuju lokasi, butuh persetujuan, selesai, dibatalkan, minta info) ✅ FR-132. Kanal: email (utama), in-app, Web Push (opsional), WhatsApp `wa.me` (default) 🔒 OQ-09. Log status kirim + **kirim ulang** bila gagal. ② Sync **— tidak ada —**. Approval/Delete **— tidak ada —** (template dinonaktifkan).

---

# 12. 💰 Finance (L3) ✅

| Sub menu | ① List | ③ Create/Edit | ④ Detail/Approval | ⑤ Delete |
|---|---|---|---|---|
| Antrean Siap Tagih | WO disetujui & `BILLABLE` (garansi/kontrak tidak muncul) ✅ | **— tidak ada —** | Aksi **Buat invoice** | — |
| Invoice | No. · pelanggan · total · status · jatuh tempo; filter status/periode | Terbitkan dari WO (`invoice_lines`); invoice periodik kontrak (FR-103) | Detail + cetak PDF; Approval **— tidak ada —** | **Batalkan** (status), bukan hapus |
| Pembayaran Tercatat | Pembayaran per invoice | Catat manual (tanggal, jumlah, metode); **bukan payment gateway** ✅ | — | Koreksi lewat entri pembalik |
| Ekspor Akuntansi | Riwayat ekspor | Pilih periode → **CSV** format impor 🔒 (format target belum diketahui) | — | — |
② Sync: **— tidak ada —** (ekspor berkas, bukan integrasi dua arah).

---

# 13. 📑 Laporan & Statistik (L3) ✅

### 13.1 Dashboard Manajemen
Widget W10–W14 (Bagian 1). Filter periode, pelanggan, kontrak. Angka direkonsiliasi dengan kueri mentah (selisih nol).

### 13.2 Statistik Aset
Per aset: jumlah WO, perulangan kerusakan, biaya, waktu henti ⚠️. Berasal dari Detail Aset (tab Statistik) ✅ FR-161.

### 13.3 Katalog Laporan & Pencarian Lanjutan ✅ FR-162
**Laporan tetap** (bukan report builder), masing-masing dengan panel filter sendiri:

| # | Laporan | Kolom utama | Filter | Pemakai |
|---|---|---|---|---|
| R1 | Kinerja SLA | Prioritas · jumlah WO · dalam SLA · breach · % | Periode, pelanggan, prioritas | OWN, SPV |
| R2 | Waktu penyelesaian | WO · diterima→ditugaskan→selesai | Periode, teknisi, jenis layanan | OWN, DSP |
| R3 | Produktivitas teknisi | Teknisi · WO selesai · rata-rata waktu · rework | Periode, teknisi | OWN, SPV |
| R4 | Perulangan kerusakan per aset | Aset · jumlah WO korektif | Periode, kategori | OWN |
| R5 | Servis berkala | Kontrak · terjadwal · tepat waktu · terlewat | Periode, kontrak | OWN, ADM |
| R6 | Stok & selisih | Barang · saldo · selisih (jumlah, nilai) | Periode, lokasi | GDG, SPV, OWN |
| R7 | Biaya & profit per kontrak | Kontrak · pendapatan · biaya · profit | Periode, kontrak | OWN, FIN |
| R8 | Ringkasan penagihan | Selesai→invoice (hari), status bayar | Periode | FIN, OWN |
| R9 | Adopsi aplikasi | % WO diselesaikan lewat aplikasi | Periode | OWN |
Pencarian lanjutan: WO/pelanggan/aset dengan filter bertingkat. Export Excel/CSV ⚠️. Sync/Create/Delete: **— tidak ada —**. Approval **— tidak ada —**.

---

# 14. ⚙️ Administrasi

| Sub menu | ① List | ③ Create/Edit | ④ Detail/Approval | ⑤ Delete |
|---|---|---|---|---|
| **Pengguna & Peran** ✅ | Staf: nama · email · peran · status | Tambah staf, tetapkan peran, undang pelanggan (tautan sekali pakai) | Riwayat peran; Approval **— tidak ada —** | **Nonaktifkan** (berlaku seketika) |
| **Pengaturan** (L2) | Parameter, kebijakan SLA, kalender kerja, hari libur, prioritas, kode alasan | Edit parameter [P]: batas laju, ukuran foto, jendela deteksi ganda, ambang opname, retensi | Riwayat perubahan tercatat di audit | Nonaktifkan (kebijakan/kalender) |
| **Log Audit** (L2) ✅ | Waktu · pengguna · aksi · objek · sebelum/sesudah; filter | **— tidak ada —** (append-only) | Detail diff | **— tidak ada —** |
| **Log Akses Data** (L2) ✅ | Staf yang membuka dokumen/foto pelanggan | **— tidak ada —** | — | **— tidak ada —**; retensi lewat kebijakan |
| **Impor Excel** (L3) ✅ | Riwayat impor (`import_jobs`) | Wizard: Unduh Template → Unggah & Pratinjau → Konfirmasi; baris salah ditolak dengan alasan, tidak masuk diam-diam | Detail galat per baris | **— tidak ada —** |
| **Monitor Job & Sinkron** ⚠️ | `job_runs` (PM, SLA, notifikasi); antrean sinkron offline bermasalah (`sync_operations`) | Tombol jalankan ulang job | Detail galat | **— tidak ada —** |

② Sync: **— tidak ada —** pada semua (tidak ada integrasi master).
Pengaturan SLA/kalender dibatasi ke OWN 🔒 OQ-12.

---

# 15. 📱 PWA Teknisi ✅

**Prinsip**: tombol besar, minim ketikan, offline-first, indikator "belum terkirim" per item dan global ✅ FR-060/063.

| Layar | ① List/Isi | ③ Create/Edit | ④ Detail/Approval | ⑤ Delete |
|---|---|---|---|---|
| **Tugas Hari Ini** | Kartu WO: waktu, pelanggan, aset, status, lencana belum-terkirim; tersedia offline | **— tidak ada —** | Buka Detail WO | — |
| **Semua Tugas** | Beberapa hari ke depan [P] + riwayat; filter status | **— tidak ada —** | | — |
| **Detail WO** | Info pelanggan, lokasi (peta/tautan), aset, riwayat singkat aset | **— tidak ada —** edit data master | Tombol aksi sesuai status | — |
| **Terima/Tolak/Minta Bantuan** | — | Terima; Tolak (**alasan wajib**); Minta bantuan | Dispatcher menindaklanjuti | — |
| **Berangkat** | — | Satu ketukan → status pelanggan "Teknisi menuju lokasi" | | — |
| **Check-in / Check-out** | — | GPS **hanya** saat check-in/out (atas izin) + waktu; gagal GPS ≠ blok (alasan tercatat) ⚠️ | | — |
| **Checklist** | Item wajib/opsional per template | Centang/isi; item wajib menahan penutupan | | — |
| **Temuan/Diagnosa/Catatan** | — | Teks singkat, pilihan kode | | — |
| **Foto Sebelum/Sesudah** | Slot sesuai syarat foto | Kamera/galeri; kompres di perangkat; unggah bertahap | | Foto terkirim tidak bisa dihapus teknisi ⚠️ (OQ Q-API-6) |
| **Jasa & Suku Cadang** | Jasa (labor); suku cadang dipakai (L2 terhubung stok) | Tambah jasa/pemakaian; teknisi **tidak melihat harga** | | Hapus baris sebelum sinkron saja |
| **Minta Suku Cadang / Retur** (L2) | Status permintaan | Pilih barang + jumlah; catat retur sisa | GDG menyerahkan | — |
| **Ajukan Biaya Tambahan** (L2) | Status pengajuan | Pilih item katalog, alasan, foto; harga dihitung server; pekerjaan terkait berhenti | Menunggu keputusan pelanggan/SPV | Batalkan pengajuan (selama menunggu) |
| **Tanda Tangan & Tutup WO** | Ringkasan syarat penutupan (centang lengkap/belum) | Kanvas tanda tangan + nama penandatangan; Tutup WO; pengecualian dengan alasan | Hasil review SPV; WO dikembalikan + catatan (L2) | — |
| **Pindai QR** | — | Kamera → buka aset/WO ✅ (Could) | | — |
| **Sinkron & Antrean** | Item per status: belum terkirim · menunggu · terkirim · gagal | Coba ulang; lihat konflik | | Hapus draf hanya bila dinyatakan "diselamatkan" ⚠️ (gap G-06) |
| **Profil & Perangkat** | Profil, versi aplikasi, izin kamera/GPS, ajakan pasang ke layar utama | Ganti sandi | | — |

② Sync (aplikasi): antrean `sync_operations` dengan `op_id` idempoten; unggah foto lewat signed URL (`/uploads/sign` → `/uploads/complete`). Detail di 03 §7.
Sketsa Detail WO:
```
┌─────────────────────────────┐
│ WO-2410-0012   ● Dikerjakan │  ⬆ 2 belum terkirim
│ AC Split – Lt.3 Ruang Rapat │
├─────────────────────────────┤
│ [ Check-in ✓ 09:12 ]        │
│ Checklist        6/8  ▸     │
│ Foto             3/4  ▸     │
│ Jasa & Suku Cadang   ▸     │
│ Ajukan Biaya Tambahan ▸     │
├─────────────────────────────┤
│ Syarat tutup: ✗ Foto sesudah│
│ [   Tanda Tangan & Tutup  ] │
└─────────────────────────────┘
```

---

# 16. 🙋 PWA Pelanggan ✅

**Prinsip**: tidak wajib dipasang; bahasa Indonesia sederhana, huruf besar; kolom wajib sesedikit mungkin; pelanggan hanya melihat data sendiri (RLS + view `customer_*`).

| Layar | ① List/Isi | ③ Create/Edit | ④ Detail/Approval | ⑤ Delete |
|---|---|---|---|---|
| **Masuk/Daftar/Lupa Sandi/Terima Undangan** | — | Registrasi mandiri (OTP/email) dan/atau undangan sekali pakai 🔒 (model diputuskan wawancara; keduanya disiapkan ⚠️); rate limit & captcha | — | — |
| **Beranda** | Pesanan aktif + status ringkas, tombol Pesan Servis | **— tidak ada —** | | — |
| **Pesan Servis** | — | Pilih aset (atau scan QR), jenis masalah, foto, jadwal diinginkan (preferensi). Offline: masuk antrean "belum terkirim" ✅ | Setelah kirim: estimasi respons sesuai SLA (L2) | Batalkan sebelum divalidasi |
| **Pesanan** | Daftar + riwayat; filter status | **— tidak ada —** | Detail: status 6 tahap (Diterima → Dijadwalkan → Teknisi menuju lokasi → Sedang dikerjakan → Menunggu persetujuan Anda → Selesai), jadwal, nama teknisi | — |
| **Persetujuan Biaya Tambahan** (L2) | — | **Setuju / Tolak** dengan rincian item & total | **Approval #2** (pelanggan); tercatat dengan waktu & pengguna | — |
| **Tanda Tangan Penerimaan** (L2) | — | Kanvas tanda tangan bila tidak dilakukan di perangkat teknisi | | — |
| **Laporan Servis** (L2) | Daftar laporan | **— tidak ada —** | Unduh PDF | — |
| **Nilai & Komplain** (L2) | — | Penilaian bintang + komentar; komplain/pengajuan ulang (admin membuat WO Rework) | | — |
| **Aset** | Daftar aset milik sendiri | **— tidak ada —** edit (admin yang mengelola master) | Detail: riwayat servis; dashboard & jadwal berkala (L3) | — |
| **Jadwal Berkala & Kontrak** (L3) | Jadwal servis berikutnya | — | Detail kontrak ringkas | — |
| **Invoice & Pembayaran** (L3) | Daftar invoice, status | — | Lihat/unduh invoice | — |
| **Akun** | Profil | Ubah profil/sandi; **Admin Pelanggan** (L3): undang/nonaktifkan pengguna perusahaan | | Nonaktifkan pengguna (L3) |

② Sync: **— tidak ada —** integrasi; offline: riwayat dapat dibuka (cache baca saja), pengiriman pesanan butuh koneksi atau antrean sederhana ✅.
Push: hanya tambahan; email/in-app kanal utama ✅.

---

# 17. 🔐 Autentikasi & Akun (lintas permukaan)

| Layar | Isi | Catatan |
|---|---|---|
| Masuk staf | Email + sandi | Sesi pendek + refresh; penonaktifan berlaku seketika |
| Masuk/daftar pelanggan | OTP/email atau tautan undangan | Rate limit, deteksi pendaftaran palsu |
| Lupa sandi | Tautan reset | FR-003 (ditambahkan analis karena belum ada di daftar Lapis) |
| Ganti sandi / profil | | |
| Penanganan galat | Sandi salah, akun nonaktif, tautan kedaluwarsa | Pesan jelas |
Skenario A: **ada** halaman login & CRUD pengguna (berbeda dengan aplikasi yang menumpang portal induk).

---

# 🔧 Perilaku Lintas Menu (dibangun sekali)

| Area | Aturan |
|---|---|
| **List** | Debounce pencarian 300 ms · filter & sort tersimpan di URL · paging server-side 50 · total dihitung dari record |
| **Uang** | `DECIMAL` di DB, **string** di JSON · pembulatan hanya saat tampil · tanpa penjumlahan lintas mata uang (satu mata uang IDR pada POC ⚠️) |
| **Form** | Field terhitung read-only · concurrency `If-Match`/versi baris · `Idempotency-Key`/`op_id` untuk aksi mengubah data/uang · validasi klien & server |
| **Status WO** | Hanya lewat tombol transisi (fungsi server `wo_transition`); tombol tidak sah disembunyikan **dan** ditolak backend |
| **Galat** | Sebut angka & tindakan, format RFC 9457, kode domain; contoh: "Foto sesudah belum ada (1 dari 2 wajib)", bukan "Data tidak lengkap" |
| **Lampiran/foto** | Jenis & ukuran divalidasi; kompres di perangkat; unggah lewat signed URL; bucket privat; akses per pelanggan |
| **Offline** | Indikator global + per item; antrean idempoten; konflik ditampilkan jelas |
| **Waktu** | Disimpan UTC, ditampilkan WIB; kalender kerja `Asia/Jakarta` |
| **Aksesibilitas** | Tombol besar (teknisi), teks besar (pelanggan), kontras cukup |
| **Audit** | Perubahan penting otomatis ke `audit_logs` oleh trigger |

---

# 🚫 Yang Sengaja TIDAK Dibangun

| Tidak ada | Alasan | Rujukan |
|---|---|---|
| Optimasi rute otomatis | Sengaja ditunda | PDF §5 |
| Pelacakan GPS real-time kontinu | Tidak andal di PWA; cukup saat check-in/out | PDF §5–6 |
| Pengadaan/pembelian penuh | Di luar cakupan | PDF §5 |
| Penggajian & absensi | Di luar cakupan | PDF §5 |
| Aplikasi native iOS/Android | PWA | PDF §5–6 |
| Payment gateway | Pembayaran hanya dicatat | PRD non-goal |
| Fitur AI | Proyek tanpa AI | PDF |
| SSO / portal induk / ERP | Berdiri sendiri | Keputusan #1 |
| Sinkronisasi master (SAP/ERP) | Tidak ada sistem sumber | Keputusan #2 |
| Report builder | Laporan tetap | Keputusan #6 |
| Hapus fisik data bisnis | Riwayat harus utuh | Keputusan #4 |
| Ubah status WO bebas | Hanya lewat transisi | Keputusan #10 |
| Hapus foto terkirim oleh teknisi | Bukti kerja | 02 matriks (Q-API-6 menunggu) |
| Teknisi melihat harga/margin | AP-2 | 02 §1.2 |
| Penutupan WO otomatis oleh sistem (Lapis 1) | Hanya SPV (T-19); demo butuh akun SPV | 03 gap G-01 |
| Edit transaksi stok/audit | Immutable, koreksi lewat reversal | Keputusan #4 |
| Optimasi/riset pasar & validasi bisnis nyata | Bukan fitur; dilakukan lewat wawancara | PRD §11 |

---

# 📊 Rekapitulasi

| Surface | Menu utama | Sub menu/layar | Titik approval |
|---|---|---|---|
| Web Internal | 14 | 47 | 6 (di antrean Persetujuan + validasi permintaan) |
| PWA Teknisi | 7 layar utama | 15 | 0 (mengajukan; tidak menyetujui) |
| PWA Pelanggan | 8 layar utama | 12 | 1 (biaya tambahan) |

**Kelengkapan fungsi**: tiap sub menu sudah diperiksa terhadap lima sudut pandang; **Sync = tidak ada** di seluruh aplikasi (keputusan #2).

**Urutan bangun yang disarankan** (mengikuti Lapis dan jalur kritis):
1. Fondasi: Auth, peran, RLS, master data, view `customer_*`/`tech_*`
2. Permintaan → WO → Penugasan (web)
3. PWA Teknisi + mesin sinkron offline (risiko terbesar)
4. PWA Pelanggan inti + Laporan PDF
5. Lapis 2: SLA, kontrak & berkala, persetujuan, gudang, notifikasi, audit
6. Lapis 3: Finance, dashboard, laporan, impor Excel

---

# 🎯 Yang Perlu Dikonfirmasi (urut dampak)

| # | Pertanyaan | Dampak | Status |
|---|---|---|---|
| 1 | Offline sync masuk Lapis 1? (BA menyarankan ya) | Besar: mengubah effort PWA Teknisi | ⚠️ diasumsikan **ya** |
| 2 | Definisi SLA (respons/selesai, jeda, jam kerja) | Besar: SLA, dashboard, metrik | 🔒 |
| 3 | Model registrasi pelanggan (undangan vs OTP mandiri) | Sedang: layar Masuk/Daftar | 🔒 keduanya disiapkan |
| 4 | Penutupan WO otomatis di Lapis 1 atau wajib SPV? | Sedang: demo Lapis 1 | ⚠️ wajib SPV (G-01) |
| 5 | Impor Excel dimajukan ke Lapis 1/2? | Sedang | ⚠️ tetap L3 `[+]` usulan maju |
| 6 | Akun multi-pengguna pelanggan lebih awal? | Sedang | ⚠️ tetap L3 |
| 7 | Kanal WhatsApp (wa.me vs Business API) | Kecil–sedang | 🔒 default `wa.me` |
| 8 | Format ekspor akuntansi target | Kecil | 🔒 |
| 9 | Data biaya untuk profit per kontrak | Sedang | 🔒 |
| 10 | Hapus foto oleh teknisi (matriks 02 vs 05) | Kecil | 🔒 Q-API-6 |
| 11 | Pemindai QR di Lapis 1 (Could) | Kecil | ⚠️ ditunda ke Lapis 2 |
| 12 | Uji skema di Supabase nyata | Besar (risiko teknis) | Harus dilakukan sebelum bergantung pada RLS |
