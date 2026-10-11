# PRD: VASTA, Field Service & Work Order Management

| Item | Keterangan |
|---|---|
| Versi | 0.1 (draf awal untuk validasi) |
| Tanggal | 2026-10-11 |
| Jenis proyek | Aplikasi portofolio, skala menengah-besar, tanpa AI |
| Sumber kebutuhan | `Kebutuhan_Field_Service_Work_Order_Management.md.pdf` (teks hasil ekstraksi `req.txt`, revisi 2) |
| Kanal | Teknisi dan pelanggan memakai PWA. Admin, dispatcher, supervisor, gudang, finance, dan manajemen memakai web desktop |
| Stack yang diasumsikan | Next.js (fullstack) + Supabase. Detail teknis dan skema database ada di dokumen 02 |
| Status validasi | Belum divalidasi dengan perusahaan servis nyata |

## Legenda Penanda

Dokumen ini membedakan sumber informasi dengan penanda berikut:

- **[D] Dokumen**: isi dokumen kebutuhan sumber. Ini klaim dari dokumen, bukan fakta yang sudah divalidasi. Dokumen sumber sendiri menyatakan pola masalah harus dikonfirmasi lewat wawancara.
- **[A] Asumsi**: dugaan yang dipakai untuk melanjutkan perencanaan. Harus divalidasi.
- **[U] Usulan**: keputusan atau tambahan dari PM yang belum ada di dokumen sumber. Perlu persetujuan.
- **[T] Target**: angka atau ambang yang diusulkan sebagai target. Bukan komitmen. Ditetapkan ulang setelah baseline dari wawancara.

Catatan: tidak ada angka pasar, jumlah pengguna, atau data operasional yang diambil dari luar dokumen sumber. Semua angka operasional ditandai sebagai asumsi atau target.

---

## 1. Ringkasan

VASTA adalah sistem yang menghubungkan seluruh siklus pekerjaan jasa servis dan pemeliharaan, dari permintaan pelanggan, penugasan teknisi, bukti kerja di lapangan, persetujuan, sampai penagihan dan pemeliharaan berkala berikutnya **[D]**.

Sasaran utamanya:

- Setiap pekerjaan punya status yang jelas dan tercatat **[D]**.
- Teknisi bekerja dari ponsel tanpa kertas, termasuk ketika sinyal buruk **[D]**.
- Manajemen melihat SLA, produktivitas, stok, dan profitabilitas kontrak **[D]**.

Produk dibagi tiga lapis supaya selalu ada versi yang bisa didemokan **[D]**:

- **Lapis 1 (Inti)**: master data, WO, penugasan manual, PWA teknisi, PWA pelanggan versi inti, laporan PDF.
- **Lapis 2 (Proses dan kontrol)**: SLA, kontrak berkala, persetujuan, suku cadang, notifikasi, papan jadwal, log audit.
- **Lapis 3 (Penyempurnaan)**: invoice dan ekspor, dashboard manajemen, riwayat aset, pencarian lanjutan, impor Excel.

Proyek ini dibangun untuk portofolio. Hasil akhirnya berupa demo dengan data fiktif dan paket studi kasus. Klaim hasil bisnis hanya boleh dibuat setelah ada data pilot nyata.

---

## 2. Problem Statement

### 2.1 Masalah yang diklaim dokumen sumber [D]

Perusahaan jasa servis skala menengah (servis AC dan pendingin, genset, lift, mesin industri, alat kesehatan non-klinik, instalasi jaringan atau CCTV, kebersihan dan fasilitas) biasanya menjalankan operasi lewat WhatsApp, telepon, Excel, dan kertas. Pola yang disebut:

1. Permintaan lewat telepon atau chat dicatat di buku atau Excel.
2. Admin mencari teknisi yang kosong lewat grup WhatsApp.
3. Teknisi mengisi form kertas dan memotret kerusakan dengan kamera pribadi.
4. Pemakaian suku cadang dicatat belakangan, sering tidak lengkap.
5. Laporan diketik ulang di kantor, invoice menyusul beberapa hari kemudian.
6. Jadwal servis berkala dilacak manual sehingga ada yang terlewat.
7. Pemilik tidak tahu pekerjaan mana yang terlambat, teknisi mana yang paling produktif, suku cadang mana yang habis, dan kontrak mana yang menguntungkan.

Dampak yang diklaim: respons lambat, SLA dilanggar tanpa disadari, suku cadang hilang atau tidak tertagih, pekerjaan tidak tertagih, dan sulit membuktikan pekerjaan kepada pelanggan.

### 2.2 Status bukti [A]

Seluruh poin di atas belum divalidasi. Yang perlu dikonfirmasi lewat wawancara adalah: seberapa sering tiap pola terjadi, siapa yang paling terdampak, dan seberapa besar biayanya. Tanpa itu, prioritas fitur di Bagian 6 adalah hipotesis.

### 2.3 Problem statement ringkas

> Untuk perusahaan servis skala menengah yang menjalankan operasi lewat WhatsApp, telepon, dan kertas **[A]**, pencatatan permintaan, penugasan, bukti kerja, suku cadang, dan penagihan yang terpisah-pisah **[D]** membuat SLA terlewat tanpa terdeteksi, pekerjaan dan suku cadang tidak tertagih, dan pemilik tidak punya gambaran kinerja yang real-time **[D]**. Kami ingin satu sistem yang menghubungkan siklus kerja dari permintaan sampai penagihan, dengan teknisi dan pelanggan memakai ponsel.

---

## 3. Tujuan dan Non-Goals

### 3.1 Tujuan produk [D]

- Satu sistem untuk siklus: permintaan, penugasan, kunjungan teknisi, bukti kerja, persetujuan, penagihan, dan pemeliharaan berkala berikutnya.
- Hasil yang dituju: semua pekerjaan punya status jelas dan terlacak; teknisi bekerja dari ponsel tanpa kertas; manajemen melihat SLA, produktivitas, stok, dan profitabilitas kontrak secara real-time.

### 3.2 Tujuan portofolio [U]

- Menunjukkan alur end-to-end yang bisa didemokan per lapis, dengan data fiktif yang realistis.
- Menunjukkan keputusan desain yang disengaja: offline-first untuk teknisi, isolasi data pelanggan, kontrol akses per peran, dan log audit.
- Menghasilkan paket studi kasus: BRD/FSD ringkas, arsitektur, laporan quality gate, dan metrik hasil **[D]** (Bagian 11, langkah 6).

### 3.3 Non-goals: sengaja tidak dibuat di awal [D]

- Optimasi rute otomatis.
- Pelacakan GPS real-time terus-menerus.
- Pembelian dan pengadaan penuh.
- Penggajian dan absensi lengkap.
- Aplikasi native iOS dan Android.

### 3.4 Non-goals turunan [U]

Diturunkan dari batasan dokumen sumber. Perlu dikonfirmasi.

- Fitur AI dalam bentuk apa pun (kebutuhan sumber: tanpa AI).
- Integrasi pembayaran online (payment gateway). Sumber hanya menyebut "pembayaran tercatat" di Lapis 3.
- Integrasi langsung ke aplikasi akuntansi tertentu. Cukup ekspor CSV atau format impor.
- Tanda tangan digital bersertifikat hukum. Tanda tangan di kanvas hanya sebagai bukti penerimaan internal.
- Chat real-time antara pelanggan dan teknisi.
- Penagihan langganan (SaaS) untuk banyak perusahaan penyedia servis.
- Pelacakan lokasi teknisi di latar belakang (sesuai batasan PWA di Bagian 6 sumber).

---

## 4. Persona dan Jobs-to-be-Done

### 4.1 Persona

Peran diambil dari Bagian 3 sumber **[D]**. Peran tambahan dari risiko sumber dan usulan PM diberi tanda [U].

| Peran | Platform | Kebutuhan utama [D] | Catatan |
|---|---|---|---|
| Pelanggan korporat | PWA | Pesan servis, pantau status, setujui biaya, tanda tangan, unduh laporan, lihat jadwal berkala | Bisa punya beberapa pemesan (cabang atau divisi) [A] |
| Pelanggan perorangan | PWA | Sama dengan korporat, flow lebih sederhana | Pelanggan umum, hambatan masuk harus rendah |
| Admin pelanggan | PWA (web) | Mengelola pengguna di perusahaan pelanggan | [U] Muncul dari risiko "pergantian karyawan di pihak pelanggan" **[D]**. Waktu masuk belum jelas |
| Admin CS | Web desktop | Mencatat dan memvalidasi permintaan, kelola pelanggan, aset, kontrak | Juga menginput pesanan atas nama pelanggan yang telepon atau chat **[D]** |
| Dispatcher | Web desktop | Menugaskan teknisi (keahlian, lokasi, ketersediaan), memantau pekerjaan hari ini | Penentu jadwal final **[D]** |
| Teknisi | PWA | Lihat tugas, detail aset dan riwayat, checklist, foto, suku cadang, tanda tangan, meski sinyal buruk | Pengguna lapangan utama |
| Supervisor | Web desktop | Menyetujui laporan kerja, menangani eskalasi, memantau kualitas | Review supervisor ada di Lapis 2 **[D]** |
| Gudang | Web desktop | Kelola stok, permintaan, dan penyerahan suku cadang ke teknisi | |
| Finance | Web desktop | Terbitkan invoice dari pekerjaan disetujui, tagih kontrak berkala | |
| Pemilik / manajer | Web desktop | Dashboard SLA, produktivitas, biaya, profitabilitas | |
| Administrator sistem | Web desktop | Mengatur peran dan hak akses, data referensi | [U] Peran teknis yang diperlukan untuk "peran dan hak akses dasar" **[D]** |
| Sistem (otomatis) | Latar belakang | Membuat WO berkala, menandai jadwal terlewat, menghitung SLA | Bukan pengguna. Disebut untuk kejelasan aturan **[D]** |

### 4.2 Jobs-to-be-Done

Format: saat [situasi], saya ingin [tujuan], agar [hasil].

- **Pelanggan**: saat mesin atau fasilitas rusak, saya ingin memesan servis dan memilih waktu sendiri tanpa menelepon, agar pekerjaan segera dijadwalkan dan saya tahu statusnya.
- **Pelanggan**: saat teknisi sudah bekerja, saya ingin menyetujui biaya tambahan dan menandatangani hasil, agar saya tidak kaget dengan tagihan dan punya bukti.
- **Admin CS**: saat pesanan masuk lewat telepon atau chat, saya ingin mencatatnya dengan cepat dan benar, agar WO tidak hilang atau ganda.
- **Dispatcher**: saat ada WO baru, saya ingin melihat teknisi mana yang kosong dan cocok, agar penugasan cepat dan tidak melanggar SLA.
- **Dispatcher**: saat WO mendekati batas waktu atau jadwal berkala terlewat, saya ingin mendapat tanda dan eskalasi, agar saya bisa bertindak sebelum terlambat.
- **Teknisi**: saat berada di lokasi, saya ingin mengisi checklist, foto, dan tanda tangan dari ponsel, agar saya tidak mengetik ulang di kantor dan laporan langsung tersimpan.
- **Teknisi**: saat sinyal hilang di basement atau ruang mesin, saya ingin tetap bisa bekerja, agar pekerjaan tidak tertunda.
- **Teknisi**: saat butuh suku cadang, saya ingin meminta dan mencatat pemakaiannya, agar stok dan tagihan akurat.
- **Supervisor**: saat laporan kerja masuk, saya ingin menyetujui atau mengembalikannya dengan catatan, agar kualitas terjaga.
- **Gudang**: saat suku cadang keluar dan kembali, saya ingin stok tercatat dan selisihnya terlihat, agar kehilangan terdeteksi.
- **Finance**: saat pekerjaan selesai dan disetujui, saya ingin membuat invoice dan mengekspornya, agar penagihan tidak tertunda.
- **Pemilik**: saat mengambil keputusan, saya ingin melihat SLA, produktivitas, dan profit per kontrak, agar keputusan berbasis data.

---

## 5. Success Metrics

### 5.1 Metrik dari dokumen sumber [D]

Bagian 9 sumber menyebut tujuh metrik. Definisi pengukuran di bawah adalah usulan PM [U]. Target bersifat [T] dan ditetapkan setelah baseline wawancara.

| No | Metrik (sumber) | Definisi pengukuran [U] | Sumber data | Layer | Baseline | Target [T] |
|---|---|---|---|---|---|---|
| M1 | Waktu dari permintaan sampai teknisi ditugaskan | Selisih waktu permintaan masuk dan waktu status "Dijadwalkan" atau penugasan pertama. Dilaporkan median dan persentil 90 | Log status WO | L1 (pencatatan), L2 (penugasan) | Wawancara (sebelum), dihitung dari sistem (sesudah) | Turun dibanding baseline. Angka ditetapkan setelah baseline |
| M2 | Persentase WO selesai dalam SLA | Jumlah WO yang ditutup pada atau sebelum batas SLA dibagi jumlah WO yang ditutup pada periode. Dihitung per bulan | WO dan konfigurasi SLA | L2 | Wawancara | Naik dibanding baseline. Angka ditetapkan setelah definisi SLA disepakati |
| M3 | Waktu dari pekerjaan selesai sampai invoice terbit | Selisih hari antara WO disetujui (status final) dan waktu invoice diterbitkan. Dilaporkan rata-rata dan median | WO dan invoice | L3 | Wawancara | Turun dibanding baseline |
| M4 | Persentase servis berkala yang terlaksana tepat waktu | Jumlah WO berkala selesai pada atau sebelum jatuh tempo ditambah toleransi [A] dibagi jumlah WO berkala yang jatuh tempo pada periode | WO berkala | L2 | Wawancara | Naik dibanding baseline |
| M5 | Jam administrasi yang dihemat | Selisih jam administrasi per minggu sebelum dan sesudah. Diukur dengan pencatatan waktu (time sampling) dan bukan hanya perkiraan | Catatan waktu admin | L1 sampai L3 | Pengukuran sebelum rilis | Ditetapkan per pilot. Catatan: angka perkiraan sendiri bersifat bias |
| M6 | Selisih stok suku cadang | Jumlah dan nilai dari: diserahkan dikurangi dipakai dikurangi dikembalikan. Nilai memakai harga satuan dari master barang | Transaksi gudang dan WO | L2 | Wawancara dan stock opname | Turun dibanding baseline. Ditandai per WO dan per periode |
| M7 | Tingkat adopsi teknisi | Jumlah WO yang ditutup lewat aplikasi dibagi jumlah WO yang ditutup oleh teknisi | WO | L1 | Tidak ada (pekerjaan belum digital) | Tinggi dan mendekati seluruh WO teknisi. Angka ditetapkan per pilot |

Catatan penting [U]: dalam tahap portofolio, metrik M1 sampai M7 hanya bisa diukur dari data fiktif atau dari pilot design partner. Jangan mengklaim hasil bisnis dari simulasi.

### 5.2 Metrik tambahan (guardrail) [U]

| No | Metrik | Definisi | Target [T] |
|---|---|---|---|
| G1 | Kebocoran data antarpelanggan | Jumlah temuan akses lintas pelanggan pada uji isolasi | 0 temuan. Ini persyaratan kualitas, bukan asumsi bisnis |
| G2 | Kehilangan data offline | Jumlah kasus data hilang pada uji sinkron offline | 0 kasus |
| G3 | Pesanan ganda atau palsu | Proporsi pesanan yang ditandai ganda atau ditolak admin, dari total pesanan lewat PWA pelanggan | Ditetapkan per pilot |
| G4 | Adopsi pemesanan mandiri pelanggan | Proporsi pesanan yang masuk lewat PWA dibanding telepon atau chat | Ditetapkan per pilot. Terkait pertanyaan wawancara nomor 12 **[D]** |
| G5 | Keberhasilan pesan servis tanpa bantuan | Proporsi peserta uji yang menyelesaikan pesan servis tanpa bantuan | Ditetapkan dari usability test |

---

## 6. Scope per Lapis

Prioritas memakai MoSCoW:

- **M** (Must): wajib ada agar lapis bisa didemokan dan berfungsi.
- **S** (Should): penting, tetapi lapis bisa tetap didemokan tanpanya bila waktu terbatas.
- **C** (Could): nilai tambah, dikerjakan bila kapasitas tersedia.
- **W** (Won't): tidak dikerjakan di rilis ini. Masuk daftar tunggu.

Durasi lapis hanya indikatif. Lihat Bagian 12.

### 6.1 Lapis 1: Inti

Fitur dari sumber **[D]** dengan prioritas. Baris bertanda [U] adalah tambahan PM. Baris bertanda [D-tersirat] berasal dari bagian lain sumber tetapi tidak tercantum di daftar Lapis 1.

| Fitur | Prioritas | Catatan |
|---|---|---|
| Master data: pelanggan, lokasi, aset, teknisi, jenis layanan | M | Data diisi manual dan dari data fiktif |
| Pembuatan dan pengelolaan WO (nomor unik) | M | |
| Validasi pesanan pelanggan oleh admin sebelum menjadi WO | M [D-tersirat] | Dari alur 4.1 langkah 2 dan risiko pesanan palsu |
| Penugasan manual oleh dispatcher | M | |
| PWA teknisi: daftar tugas, detail WO, check-in dan check-out, checklist, foto, catatan, tanda tangan pelanggan | M | |
| Mode offline untuk teknisi (buka tugas, isi checklist, foto, dan sinkron otomatis) | M [D-tersirat] | Sumber menyebut offline di Bagian 6 dan 8 dan meminta uji di Bagian 11. Tidak masuk daftar Lapis 1 secara eksplisit. Perlu konfirmasi |
| Indikator "belum terkirim" dan antrean sinkron | M [D-tersirat] | Mitigasi risiko data offline hilang |
| Kompresi dan batas ukuran foto | M [D-tersirat] | Mitigasi sinyal lemah di Bagian 6 |
| Terima, tolak (dengan alasan), atau minta bantuan atas tugas | M [U] | Langkah 5 alur 4.1. Tidak ada di daftar Lapis 1 |
| Status WO dan riwayat perubahan status | M | Aturan: satu status aktif per WO |
| Laporan servis (PDF) | M | Pembuatan dan akses. Pengiriman otomatis ke pelanggan ada di Lapis 2 |
| Peran dan hak akses dasar | M | |
| Log akses data pelanggan | S [U] | Mendukung mitigasi kebocoran data. Lengkapnya di Lapis 2 |
| PWA pelanggan: registrasi dan masuk | M | Model belum diputuskan (lihat Bagian 14) |
| PWA pelanggan: daftar aset milik sendiri | M | |
| PWA pelanggan: pesan servis (aset, jenis masalah, foto, jadwal diinginkan) | M | Kolom wajib sesedikit mungkin |
| PWA pelanggan: status pesanan dan riwayat pesanan | M | Status ringkas sesuai Bagian 6.1 sumber |
| Pemulihan kata sandi | M [U] | Dari risiko "lupa kata sandi" **[D]**. Tidak ada di daftar Lapis 1 |
| Pembatasan laju pemesanan dan validasi unggahan foto (jenis dan ukuran) | M [U] | Mitigasi penyalahgunaan. Dibutuhkan sejak pelanggan bisa mengunggah |
| Check-in berbasis lokasi (GPS, atas izin) | S [D-tersirat] | Batasan sumber: cukup lokasi saat check-in dan check-out |
| Pemindaian QR aset (teknisi dan pelanggan) | C [U] | Disebut di Bagian 6 dan 6.1 sumber. Tidak ada di daftar Lapis 1. Perlu keputusan |
| Ajakan memasang PWA ke layar utama (opsional) | C [U] | Hanya ditawarkan, tidak dipaksa **[D]** |

**User stories Lapis 1**

Pelanggan:

- **L1-P01 (M)**: sebagai pelanggan, saya ingin masuk atau mendaftar dengan langkah sesedikit mungkin, agar saya bisa memesan servis tanpa hambatan.
- **L1-P02 (M)**: sebagai pelanggan, saya ingin melihat daftar aset milik saya, agar saya memilih aset yang tepat saat memesan.
- **L1-P03 (M)**: sebagai pelanggan, saya ingin mengisi formulir pesan servis yang singkat (aset, jenis masalah, foto, jadwal yang diinginkan), agar permintaan tercatat tanpa harus menelepon.
- **L1-P04 (M)**: sebagai pelanggan, saya ingin melihat status pesanan dengan bahasa sederhana, agar saya tahu tahap pekerjaan saat ini.
- **L1-P05 (M)**: sebagai pelanggan, saya ingin melihat riwayat servis saya, agar saya bisa mengecek pekerjaan sebelumnya.
- **L1-P06 (M)**: sebagai pelanggan, saya ingin hanya melihat aset dan pesanan milik saya sendiri, agar data saya tidak bocor ke pihak lain.
- **L1-P07 (M)**: sebagai pelanggan, saya ingin memulihkan kata sandi saya, agar saya tidak terkunci dari akun.
- **L1-P08 (C)**: sebagai pelanggan, saya ingin memindai QR di aset, agar saya tidak perlu mencari nama aset secara manual.
- **L1-P09 (C)**: sebagai pelanggan, saya ingin ditawari pemasangan aplikasi ke layar utama, agar saya bisa membukanya lebih cepat jika saya mau.

Admin CS:

- **L1-A01 (M)**: sebagai admin CS, saya ingin menginput pesanan atas nama pelanggan yang menelepon atau chat, agar permintaan lewat telepon tetap tercatat dalam sistem.
- **L1-A02 (M)**: sebagai admin CS, saya ingin memvalidasi pesanan (pelanggan, aset, status kontrak atau garansi, prioritas) sebelum menjadi WO, agar WO yang dibuat sah.
- **L1-A03 (M)**: sebagai admin CS, saya ingin mengelola data pelanggan, lokasi, dan aset, agar data servis akurat.
- **L1-A04 (M)**: sebagai admin CS, saya ingin membatalkan WO dengan alasan yang tercatat, agar pesanan yang tidak jadi tidak mengotori daftar kerja.

Dispatcher:

- **L1-D01 (M)**: sebagai dispatcher, saya ingin menugaskan teknisi ke WO secara manual, agar pekerjaan segera diambil.
- **L1-D02 (M)**: sebagai dispatcher, saya ingin melihat daftar pekerjaan hari ini beserta statusnya, agar saya tahu mana yang belum berjalan.
- **L1-D03 (M)**: sebagai dispatcher, saya ingin menugaskan ulang WO yang ditolak teknisi, agar pekerjaan tidak macet.

Teknisi:

- **L1-T01 (M)**: sebagai teknisi, saya ingin melihat daftar tugas hari ini di ponsel, agar saya tahu tujuan berikutnya.
- **L1-T02 (M)**: sebagai teknisi, saya ingin membuka detail WO, aset, dan riwayat singkat aset, agar saya siap sebelum datang ke lokasi.
- **L1-T03 (M)**: sebagai teknisi, saya ingin menerima, menolak dengan alasan, atau meminta bantuan atas tugas, agar dispatcher tahu kondisi di lapangan.
- **L1-T04 (M)**: sebagai teknisi, saya ingin check-in dan check-out di lokasi, agar kunjungan tercatat.
- **L1-T05 (M)**: sebagai teknisi, saya ingin mengisi checklist dan mencatat diagnosa, agar laporan tidak perlu diketik ulang.
- **L1-T06 (M)**: sebagai teknisi, saya ingin memotret kondisi sebelum dan sesudah langsung dari aplikasi, agar bukti kerja tersimpan.
- **L1-T07 (M)**: sebagai teknisi, saya ingin tetap bisa membuka tugas dan mengisi checklist serta foto tanpa sinyal, agar pekerjaan tidak tertunda, lalu data terkirim otomatis saat online.
- **L1-T08 (M)**: sebagai teknisi, saya ingin melihat indikator "belum terkirim", agar saya tahu data mana yang belum sampai ke server.
- **L1-T09 (M)**: sebagai teknisi, saya ingin meminta tanda tangan pelanggan di layar ponsel dan menutup WO, agar hasil kerja langsung terbukti.
- **L1-T10 (M)**: sebagai teknisi, saya ingin diberi tahu jika WO belum bisa ditutup karena checklist, foto, atau tanda tangan belum lengkap, agar saya tidak perlu kembali ke kantor.
- **L1-T11 (C)**: sebagai teknisi, saya ingin memindai QR aset, agar saya yakin berada di aset yang benar.

Pengguna internal dan administrator:

- **L1-X01 (M)**: sebagai administrator, saya ingin mengatur peran dan hak akses, agar setiap orang hanya melihat data yang diperlukan perannya.
- **L1-X02 (M)**: sebagai pengguna internal, saya ingin melihat status WO dan riwayat perubahannya, agar saya tahu apa yang sudah terjadi.
- **L1-X03 (M)**: sebagai admin CS, saya ingin membuat laporan servis PDF dari WO yang sudah ditutup, agar pelanggan mendapat bukti kerja.

### 6.2 Lapis 2: Proses dan Kontrol

| Fitur | Prioritas | Catatan |
|---|---|---|
| Prioritas dan SLA (batas respons dan penyelesaian, penanda terlambat, eskalasi) | M | Definisi SLA dan jam kerja kontrak belum ada (lihat Bagian 14) |
| Kontrak pemeliharaan dan WO berkala otomatis | M | Dibuat sebelum jatuh tempo dan tidak boleh digandakan **[D]** |
| Penanda jadwal berkala yang terlewat dan eskalasinya | M | Alur 4.2 langkah 4 |
| Persetujuan biaya tambahan di atas estimasi | M | Teknisi tidak boleh lanjut sebelum disetujui pelanggan **[D]** |
| Review supervisor (setuju atau kembalikan dengan catatan) | M | |
| Suku cadang: master barang, stok gudang, permintaan dan pemakaian per WO | M | |
| Selisih suku cadang (diserahkan, tetapi tidak dipakai dan tidak dikembalikan) ditandai | M | Aturan bisnis **[D]** |
| Aturan penutupan WO: checklist wajib, foto wajib, tanda tangan atau persetujuan | M | Kecuali dengan alasan tercatat **[D]**. Sebagian sudah di Lapis 1 |
| Notifikasi in-app dan email | M | Kanal utama **[D]** |
| Notifikasi pelanggan: pesanan diterima, teknisi ditugaskan dan jadwal, teknisi menuju lokasi, pekerjaan selesai | M | |
| Notifikasi via WhatsApp | S [U] | Pelanggan awam disarankan memakai email dan WhatsApp **[D]**. Perlu keputusan kebijakan API (lihat Bagian 14) |
| Push notification | C | Hanya untuk PWA yang terpasang. Di iPhone terbatas **[D]** |
| PWA pelanggan: persetujuan biaya tambahan | M | |
| PWA pelanggan: tanda tangan penerimaan hasil kerja | M | |
| PWA pelanggan: unduh laporan servis (PDF) | M | |
| PWA pelanggan: penilaian layanan | S | |
| PWA pelanggan: pengajuan ulang atau komplain atas pekerjaan | S | |
| Papan penjadwalan (kalender atau papan kerja) untuk dispatcher | S | Lapis 1 hanya penugasan manual dari daftar |
| Log audit (perubahan penting) | M | Aturan bisnis **[D]** |
| Pengaturan (jam kerja kontrak, kebijakan SLA, template checklist per jenis layanan) | M [U] | Dibutuhkan agar SLA dan checklist bisa dikonfigurasi |
| Pengiriman laporan PDF otomatis ke pelanggan | S [U] | Alur 4.1 langkah 11 |

**User stories Lapis 2**

- **L2-01 (M)**: sebagai admin CS, saya ingin SLA dihitung otomatis dari prioritas dan jam kerja kontrak, agar saya tahu tenggat setiap WO.
- **L2-02 (M)**: sebagai dispatcher, saya ingin WO yang mendekati batas SLA ditandai dan dieskalasi, agar saya bisa bertindak sebelum terlambat.
- **L2-03 (M)**: sebagai admin CS, saya ingin kontrak pemeliharaan mendefinisikan aset dan frekuensi (bulanan, triwulan, tahunan), agar servis berkala tidak terlewat.
- **L2-04 (M)**: sebagai dispatcher, saya ingin WO berkala dibuat otomatis sebelum jatuh tempo dan tidak digandakan, agar setiap servis terjadwal tepat satu kali.
- **L2-05 (M)**: sebagai dispatcher, saya ingin jadwal berkala yang terlewat ditandai dan dieskalasi, agar tidak ada servis yang terlupakan.
- **L2-06 (M)**: sebagai teknisi, saya ingin mengajukan biaya tambahan beserta alasannya, agar pelanggan bisa menyetujuinya sebelum saya melanjutkan.
- **L2-07 (M)**: sebagai pelanggan, saya ingin menyetujui atau menolak biaya tambahan di PWA, agar saya mengontrol biaya.
- **L2-08 (M)**: sebagai supervisor, saya ingin menyetujui laporan kerja atau mengembalikannya dengan catatan, agar kualitas terjaga.
- **L2-09 (M)**: sebagai teknisi, saya ingin menerima WO yang dikembalikan beserta catatannya, agar saya tahu apa yang perlu diperbaiki.
- **L2-10 (M)**: sebagai teknisi, saya ingin meminta suku cadang untuk sebuah WO, agar pekerjaan tidak berhenti karena kekurangan barang.
- **L2-11 (M)**: sebagai petugas gudang, saya ingin menyerahkan suku cadang ke teknisi dengan stok berkurang otomatis, agar stok akurat.
- **L2-12 (M)**: sebagai teknisi, saya ingin mencatat pemakaian aktual dan mengembalikan sisa barang, agar tagihan dan stok sesuai.
- **L2-13 (M)**: sebagai petugas gudang, saya ingin melihat selisih antara barang yang diserahkan dan yang dipakai, agar kehilangan terdeteksi.
- **L2-14 (M)**: sebagai pelanggan, saya ingin menandatangani penerimaan hasil kerja di ponsel, agar saya menyetujui hasilnya secara tercatat.
- **L2-15 (M)**: sebagai pelanggan, saya ingin mengunduh laporan servis PDF, agar saya punya arsip.
- **L2-16 (M)**: sebagai pelanggan, saya ingin diberi tahu saat pesanan diterima, teknisi ditugaskan beserta jadwalnya, teknisi menuju lokasi, dan pekerjaan selesai, agar saya tidak perlu menelepon untuk bertanya.
- **L2-17 (S)**: sebagai pelanggan, saya ingin menerima notifikasi lewat WhatsApp jika kanal itu disetujui, agar saya melihatnya di kanal yang saya pakai sehari-hari.
- **L2-18 (S)**: sebagai pelanggan, saya ingin memberi penilaian layanan, agar penyedia tahu kualitas kerjanya.
- **L2-19 (S)**: sebagai pelanggan, saya ingin mengajukan ulang atau komplain atas pekerjaan, agar masalah saya ditangani.
- **L2-20 (S)**: sebagai dispatcher, saya ingin papan penjadwalan, agar saya melihat beban setiap teknisi.
- **L2-21 (C)**: sebagai teknisi, saya ingin menerima push notification saat ada tugas baru, agar tugas terlihat lebih cepat (bila PWA terpasang).
- **L2-22 (M)**: sebagai supervisor, saya ingin WO tidak bisa ditutup tanpa checklist, foto wajib, dan tanda tangan atau persetujuan (kecuali dengan alasan tercatat), agar kualitas data terjaga.
- **L2-23 (M)**: sebagai pemilik, saya ingin setiap perubahan penting tercatat di log audit, agar bisa ditelusuri siapa mengubah apa dan kapan.

### 6.3 Lapis 3: Penyempurnaan

| Fitur | Prioritas | Catatan |
|---|---|---|
| Invoice dari WO yang disetujui atau tercakup kontrak | M | Pekerjaan dalam garansi atau tercakup kontrak tidak ditagihkan terpisah **[D]** |
| Ekspor invoice ke CSV atau format impor akuntansi | M | Format target belum diketahui (lihat Bagian 14) |
| Pencatatan pembayaran (manual) | S | "Pembayaran tercatat", bukan payment gateway (lihat non-goal) |
| PWA pelanggan: dashboard aset dan jadwal servis berkala | S | |
| PWA pelanggan: pelacakan status yang lebih rinci | S | |
| PWA pelanggan: lihat dan unduh invoice | S | |
| PWA pelanggan: akun multi-pengguna per perusahaan pelanggan | S | Ada risiko kebutuhan ini muncul lebih awal (lihat Bagian 14) |
| Dashboard manajemen: SLA dan waktu penyelesaian | M | |
| Dashboard manajemen: produktivitas teknisi | M | |
| Dashboard manajemen: perulangan kerusakan per aset | S | |
| Dashboard manajemen: biaya dan profit per kontrak | S | Membutuhkan data biaya (lihat Bagian 14) |
| Riwayat dan statistik per aset | S | |
| Pencarian dan laporan lanjutan | S | |
| Impor data awal (aset, pelanggan, stok) dari Excel dengan validasi | S | Sumber menempatkannya di Lapis 3. Lihat Bagian 14 |

**User stories Lapis 3**

- **L3-01 (M)**: sebagai finance, saya ingin membuat invoice dari WO yang sudah disetujui atau tercakup kontrak, agar penagihan cepat.
- **L3-02 (M)**: sebagai finance, saya ingin mengekspor invoice ke CSV dengan format impor, agar tidak perlu mengetik ulang di aplikasi akuntansi.
- **L3-03 (S)**: sebagai finance, saya ingin mencatat pembayaran pada invoice, agar status tagihan jelas.
- **L3-04 (S)**: sebagai pelanggan, saya ingin melihat dan mengunduh invoice, agar saya bisa memprosesnya di sisi saya.
- **L3-05 (S)**: sebagai pelanggan, saya ingin melihat dashboard aset dan jadwal servis berkala, agar tahu kapan servis berikutnya.
- **L3-06 (S)**: sebagai pelanggan, saya ingin melihat tahap status yang lebih rinci, agar tahu di mana pekerjaan saya sekarang.
- **L3-07 (S)**: sebagai pelanggan korporat, saya ingin beberapa orang di perusahaan saya memakai akun masing-masing, agar data tiap cabang atau divisi terpisah.
- **L3-08 (S)**: sebagai admin pelanggan, saya ingin mengelola pengguna di perusahaan saya, agar pergantian karyawan tidak perlu menunggu penyedia servis.
- **L3-09 (M)**: sebagai pemilik, saya ingin dashboard SLA dan waktu penyelesaian, agar tahu performa operasi.
- **L3-10 (M)**: sebagai manajer operasional, saya ingin melihat produktivitas per teknisi, agar tahu beban dan hasil kerja.
- **L3-11 (S)**: sebagai pemilik, saya ingin melihat perulangan kerusakan per aset, agar aset bermasalah terdeteksi.
- **L3-12 (S)**: sebagai pemilik, saya ingin melihat biaya dan profit per kontrak, agar tahu kontrak mana yang menguntungkan.
- **L3-13 (S)**: sebagai teknisi atau admin, saya ingin melihat riwayat dan statistik per aset, agar paham kondisi aset sebelum bekerja.
- **L3-14 (S)**: sebagai pengguna internal, saya ingin mencari WO, pelanggan, dan aset dengan filter lanjutan dan membuat laporan, agar saya cepat menemukan data.
- **L3-15 (S)**: sebagai admin, saya ingin mengimpor data awal dari Excel dengan validasi, agar setup awal tidak perlu input manual satu per satu. Baris bermasalah harus dilaporkan.

---

## 7. Definisi Demo-Ready dan Quality Gate per Lapis

### 7.1 Lapis 1

**Definisi demo-ready**

- Skenario demo naskah tertulis dan bisa diulang dengan data fiktif. Skenario minimal: pelanggan memesan lewat PWA dari ponsel, admin memvalidasi, WO dibuat, dispatcher menugaskan, teknisi bekerja (termasuk sesi mode pesawat), teknisi meminta tanda tangan dan menutup WO, lalu laporan PDF terbit dan bisa diakses pelanggan.
- Status WO terlihat sama di web internal dan PWA pelanggan, termasuk riwayat perubahannya.
- Data fiktif mencakup minimal satu kasus untuk setiap jenis layanan yang dipilih untuk demo [U].
- Demo dijalankan di perangkat nyata: minimal satu Android dan satu iPhone [A].
- Kasus tepi yang didemokan: WO dibatalkan dan WO ditugaskan ulang setelah ditolak teknisi [U].

**Quality gate Lapis 1**

- Semua user story M lulus uji (uji manual dan otomatis untuk alur inti).
- Uji isolasi data pelanggan: pelanggan A tidak bisa membaca aset, pesanan, atau dokumen pelanggan B lewat antarmuka maupun akses langsung. Lulus 100% pada kasus uji yang ditetapkan. Dokumen sumber mewajibkan pengujian khusus **[D]**.
- Uji offline di perangkat nyata: teknisi membuka tugas, mengisi checklist dan foto tanpa sinyal, lalu data tersinkron tanpa kehilangan. Indikator "belum terkirim" tampil dengan benar.
- Uji unggahan foto: jenis dan ukuran ditolak bila tidak valid. Foto dikompresi di perangkat.
- Uji pembatasan laju pada pemesanan.
- Uji kontrol akses per peran pada setiap endpoint dan halaman.
- Pemindaian keamanan dasar: pemeriksaan dependensi, pemindaian rahasia (secret scan), dan tinjauan kode keamanan dasar.
- Pemeriksaan data pribadi: inventaris data pribadi dan foto lokasi, kebijakan retensi (draf), dan alasan pengumpulan. Selaras dengan UU PDP **[D]**.
- Matriks perangkat dan browser yang didukung sudah tertulis. Pengujian dilakukan pada perangkat di matriks itu.
- Uji penerimaan oleh orang yang tidak terlibat dalam pengembangan: seluruh alur demo dijalankan satu kali tanpa bantuan pengembang [U].

### 7.2 Lapis 2

**Definisi demo-ready**

- Mencakup semua demo Lapis 1, dengan regresi yang lulus.
- SLA berjalan: WO yang mendekati batas ditandai dan dieskalasi. Demo menggunakan waktu uji yang bisa dimajukan.
- Berkala: WO berkala dibuat sebelum jatuh tempo dengan waktu uji, dan tidak muncul dua kali.
- Persetujuan biaya tambahan: teknisi mengajukan, pelanggan menyetujui di PWA, teknisi melanjutkan. Teknisi tidak bisa melanjutkan sebelum persetujuan.
- Review supervisor: WO dikembalikan dengan catatan, lalu teknisi melihatnya.
- Suku cadang: permintaan, penyerahan, pemakaian, dan selisih tampil.
- Notifikasi pelanggan terkirim ke kanal yang aktif (email, atau WhatsApp jika disetujui).

**Quality gate Lapis 2**

- Regresi seluruh uji Lapis 1 lulus.
- Uji aturan bisnis: WO tidak bisa ditutup tanpa checklist, foto, dan tanda tangan atau persetujuan, kecuali dengan alasan tercatat.
- Uji idempotensi: WO berkala tidak digandakan meskipun job dijalankan dua kali.
- Uji persetujuan biaya: tidak ada pekerjaan lanjutan tanpa persetujuan yang tercatat.
- Uji log audit: setiap perubahan penting tercatat, dengan pengguna dan waktu.
- Uji notifikasi: kegagalan kirim tercatat dan bisa dicoba ulang.
- Uji perhitungan SLA terhadap jam kerja kontrak pada beberapa kasus tepi (lintas hari, hari libur yang dikonfigurasi).
- Pemindaian keamanan diulang untuk fitur baru.
- Uji ulang di perangkat nyata untuk alur persetujuan dan tanda tangan.

### 7.3 Lapis 3

**Definisi demo-ready**

- Mencakup semua demo Lapis 1 dan 2.
- Invoice dibuat dari WO fiktif, lalu diekspor ke CSV dengan format yang sudah disepakati.
- Dashboard menampilkan angka yang konsisten dengan data sumber pada sampel fiktif.
- Impor Excel didemokan dengan satu file yang sengaja berisi baris bermasalah. Baris bermasalah ditampilkan dengan alasan.

**Quality gate Lapis 3**

- Rekonsiliasi: angka dashboard dicocokkan dengan kueri mentah pada sampel. Selisih nol.
- Uji format CSV terhadap contoh format impor target yang sudah disepakati.
- Uji impor Excel: validasi tipe, duplikat, dan referensi. Baris salah tidak masuk diam-diam.
- Uji performa dashboard pada kumpulan data fiktif yang besar. Ambang performa ditetapkan [T].
- Tinjauan data pribadi akhir dan pemeriksaan retensi.
- Dokumentasi pengguna dan panduan admin tersedia.

### 7.4 Quality gate lintas rilis [U]

- Setiap rilis menyertakan catatan perubahan, skrip demo yang sudah dijalankan ulang, dan laporan hasil uji.
- Tidak ada rilis yang membawa temuan kebocoran data yang belum ditutup.

---

## 8. Menu dan Halaman Tingkat Tinggi per Peran

Angka lapis di dalam kurung menunjukkan lapis tempat fitur itu masuk. Menu adalah usulan awal [U] dan bisa berubah setelah wawancara dan prototipe.

### 8.1 PWA Pelanggan

Navigasi bawah: Beranda, Pesan Servis, Pesanan, Aset, Akun.

- **Masuk, daftar, lupa kata sandi** (L1)
- **Beranda**: pesanan aktif dengan status ringkas (L1)
- **Pesan Servis**: formulir singkat, pilih aset, jenis masalah, foto, jadwal yang diinginkan (L1). Pemindai QR (C, L1)
- **Pesanan**: daftar pesanan, detail status dan tahapan (L1). Tahap rinci (L3)
- **Persetujuan biaya tambahan** (L2)
- **Tanda tangan penerimaan** (L2)
- **Laporan servis**: unduh PDF (L2)
- **Penilaian dan komplain** (L2)
- **Riwayat servis** (L1)
- **Aset**: daftar aset (L1). Riwayat dan dashboard aset (L3)
- **Jadwal berkala dan kontrak** (L3)
- **Invoice dan pembayaran tercatat** (L3)
- **Akun dan pengguna perusahaan** (L3)
- **Pasang ke layar utama** (ajakan, C, L1)

### 8.2 PWA Teknisi

Navigasi bawah: Tugas Hari Ini, Semua Tugas, Sinkron, Profil.

- **Masuk** (L1)
- **Tugas Hari Ini**: daftar tugas, urutan, status (L1)
- **Detail WO**: info pelanggan, lokasi, aset, riwayat singkat aset (L1). Riwayat dan statistik lengkap (L3)
- **Terima, tolak, minta bantuan** (L1)
- **Check-in dan check-out** (L1)
- **Checklist** (L1)
- **Foto sebelum dan sesudah** (L1)
- **Catatan diagnosa** (L1)
- **Tanda tangan pelanggan dan tutup WO** (L1)
- **Permintaan suku cadang dan pengembalian sisa** (L2)
- **Pengajuan biaya tambahan** (L2)
- **Hasil review dan WO dikembalikan** (L2)
- **Sinkron dan antrean offline**: status "belum terkirim", percobaan ulang (L1)
- **Pemindai QR aset** (C, L1)
- **Profil dan perangkat** (L1)

### 8.3 Web Internal (Desktop)

Menu mengikuti peran. Pengguna hanya melihat menu sesuai hak aksesnya.

- **Dashboard** (L1 daftar hari ini; L3 dashboard manajemen)
- **Permintaan Masuk**: daftar pesanan, validasi, input atas nama pelanggan (L1)
- **Work Order**: daftar, buat, detail, status dan riwayat, pembatalan (L1)
- **Penugasan**: penugasan manual (L1). Papan penjadwalan (L2)
- **Monitor Hari Ini**: pekerjaan hari ini dan statusnya (L1)
- **Persetujuan**: biaya tambahan, review supervisor (L2)
- **SLA dan Eskalasi**: WO mendekati batas, jadwal berkala terlewat (L2)
- **Kontrak dan Berkala**: definisi kontrak, WO berkala (L2)
- **Pelanggan, Lokasi, Aset**: master data (L1)
- **Jenis Layanan dan Template Checklist** (L1 dasar, L2 pengaturan lanjut)
- **Teknisi**: master teknisi, keahlian (L1)
- **Gudang**: master barang, stok, permintaan, penyerahan, pengembalian, selisih (L2)
- **Finance**: antrean WO siap ditagih, invoice, ekspor CSV, pencatatan pembayaran (L3)
- **Laporan Servis**: daftar dan unduh PDF (L1)
- **Pengguna dan Hak Akses** (L1)
- **Notifikasi dan Template Pesan** (L2)
- **Log Audit** (L2)
- **Pengaturan**: jam kerja kontrak, kebijakan SLA (L2)
- **Dashboard Manajemen**: SLA, produktivitas, perulangan kerusakan, profit kontrak (L3)
- **Statistik Aset** (L3)
- **Pencarian Lanjutan dan Laporan** (L3)
- **Impor Excel** (L3)

---

## 9. Dependensi

| No | Dependensi | Jenis | Dibutuhkan untuk | Status |
|---|---|---|---|---|
| D1 | Keputusan model registrasi pelanggan (undangan atau mandiri dengan OTP) | Keputusan | L1 pelanggan | Terbuka. Diputuskan lewat wawancara |
| D2 | Definisi SLA, prioritas, dan jam kerja kontrak | Keputusan | L2 | Terbuka. Diputuskan lewat wawancara |
| D3 | Matriks perangkat dan browser yang didukung | Keputusan dan uji | Quality gate L1 | Terbuka |
| D4 | Perangkat uji nyata (minimal satu Android, satu iPhone) | Sumber daya | Uji L1 dan seterusnya | [A] Tersedia |
| D5 | Kebijakan dan API WhatsApp (resmi atau alternatif) | Eksternal | Notifikasi L2 | Terbuka. Biaya dan persetujuan belum diketahui |
| D6 | Layanan email transaksional | Eksternal | Notifikasi L2 | [A] Tersedia |
| D7 | Push notification via Web Push, dengan batasan iOS | Teknis | Push L2 | Terbatas di iPhone **[D]** |
| D8 | Layanan autentikasi, penyimpanan berkas (foto dan PDF), dan database (Supabase) | Teknis | Semua lapis | [A] Stack diasumsikan |
| D9 | Hosting aplikasi Next.js | Teknis | Semua lapis | [A] |
| D10 | Pustaka pendukung: PDF, pemindai QR, kanvas tanda tangan, kompresi foto | Teknis | L1 | Pemilihan di dokumen 02 |
| D11 | Set data fiktif realistis per jenis layanan | Konten | Demo semua lapis | Terbuka. Dibuat oleh tim |
| D12 | Format CSV atau impor akuntansi target | Eksternal | L3 invoice | Terbuka |
| D13 | Template laporan servis (tata letak PDF) | Konten | L1 | Terbuka |
| D14 | Kebijakan retensi data dan lokasi penyimpanan data | Kebijakan | Sebelum pilot dan publikasi | Terbuka. Mengikuti UU PDP **[D]** |
| D15 | Design partner pilot | Eksternal | Validasi dan studi kasus | Terbuka. Lihat Bagian 10 |

---

## 10. Risiko dan Mitigasi

Baris dengan penanda [D] berasal dari Bagian 8 sumber. Baris [U] adalah tambahan PM.

| No | Risiko | Dampak | Mitigasi | Asal |
|---|---|---|---|---|
| R1 | Teknisi menolak memakai aplikasi karena dianggap menambah pekerjaan | Adopsi M7 rendah | Layar sederhana, sedikit ketikan, tombol besar. Libatkan teknisi sejak desain | [D] |
| R2 | Sinyal buruk di lokasi | Data hilang atau tertunda | Offline-first sejak awal, sinkron yang tahan gangguan, indikator "belum terkirim" | [D] |
| R3 | Data pelanggan dan foto lokasi, termasuk data pribadi atau sensitif | Pelanggaran UU PDP, reputasi | Akses berbasis peran, enkripsi, kebijakan penyimpanan, selaras UU PDP | [D] |
| R4 | Cakupan membengkak | Tidak ada lapis yang selesai | Pegang lapisan. Fitur di luar lapisan masuk daftar tunggu | [D] |
| R5 | Master data awal berantakan | Demo dan pilot gagal | Impor dari Excel dengan validasi. Tahap pembersihan data | [D] |
| R6 | Kasus tepi (WO dibatalkan, ditugaskan ulang, pelanggan menolak) | Status tidak konsisten | Daftarkan di FSD dan uji khusus | [D] |
| R7 | Terlihat meniru proyek DOT | Masalah reputasi atau kekayaan intelektual | Pakai data fiktif dan struktur sendiri. Jangan memakai dokumen, template, atau istilah internal DOT | [D] |
| R8 | Pesanan sembarangan, ganda, atau palsu | Beban admin, WO salah | Verifikasi akun, batas laju, deteksi ganda, validasi admin sebelum menjadi WO | [D] |
| R9 | Pelanggan melihat data pelanggan lain | Kebocoran data | Kontrol akses per pelanggan di setiap kueri, uji khusus, log akses | [D] |
| R10 | Pelanggan berharap respons instan | Keluhan | Tampilkan estimasi respons sesuai SLA dan status yang jelas | [D] |
| R11 | Lupa kata sandi dan pergantian karyawan di pihak pelanggan | Akses terkunci atau akun tidak relevan | Alur pemulihan dan peran admin pelanggan | [D] |
| R12 | Wawancara belum dilakukan, tetapi build sudah jalan | Produk dibangun di atas asumsi | Gerbang keputusan di Bagian 11. Build Lapis 1 dimulai setelah wawancara minimal selesai | [U] |
| R13 | Konflik data offline: dispatcher mengubah WO saat teknisi offline | Data tertimpa atau hilang | Kebijakan konflik tertulis (misalnya: status dari server menang, perubahan teknisi tetap tercatat sebagai usulan) | [U] |
| R14 | Variasi jenis layanan (AC, lift, CCTV, dan lainnya) membuat checklist membengkak | Scope naik | Template checklist dikelola admin. Demo dibatasi pada beberapa jenis layanan | [U] |
| R15 | Biaya operasional layanan pihak ketiga (WhatsApp, email, penyimpanan foto) | Biaya tak terduga | Estimasi biaya per kanal sebelum memilih. Kompresi foto. Batas ukuran | [U] |
| R16 | Metrik dari data fiktif dibaca sebagai bukti bisnis | Klaim menyesatkan | Semua metrik diberi label simulasi atau pilot. Tidak ada klaim hasil tanpa data pilot | [U] |
| R17 | Pelanggan tidak mau memesan lewat PWA dan tetap memakai telepon atau WhatsApp | Adopsi pelanggan rendah | Admin tetap bisa input atas nama pelanggan. Ukur G4. Validasi di wawancara nomor 12 | [U] |
| R18 | Data biaya tenaga kerja dan suku cadang tidak tersedia untuk profit per kontrak | Dashboard profit tidak akurat | Tetapkan sumber biaya di Lapis 3. Tanpa penggajian, biaya tenaga kerja mungkin hanya estimasi | [U] |

---

## 11. Rencana Validasi: Wawancara dan Design Partner

### 11.1 Tujuan validasi

- Mengonfirmasi atau membantah pola masalah di Bagian 2.
- Menentukan prioritas fitur, terutama batas antara Lapis 1, 2, dan 3.
- Menjawab open questions yang menjadi dependensi (Bagian 14).
- Mendapatkan calon design partner.

### 11.2 Wawancara

- **Jumlah dan durasi**: 3 sampai 5 perusahaan, 30 sampai 45 menit per wawancara **[D]**.
- **Sampel**: di luar jaringan DOT **[D]**. Usulan: pilih minimal dua jenis layanan berbeda, misalnya pendingin dan kebersihan, atau genset dan CCTV [U].
- **Pertanyaan**: 15 pertanyaan dari Bagian 10 sumber. Disalin apa adanya sebagai panduan **[D]**:
  1. Jenis layanan apa yang diberikan, dan berapa WO per hari atau bulan?
  2. Bagaimana permintaan masuk, dan siapa yang mencatat dan menugaskan?
  3. Berapa teknisi, dan bagaimana mereka mendapat tugas dan melapor?
  4. Apa yang dicatat teknisi di lokasi, dan apa yang sering terlewat?
  5. Apakah ada SLA dengan pelanggan, dan seberapa sering terlewat?
  6. Bagaimana kontrak pemeliharaan berkala dilacak?
  7. Bagaimana suku cadang dikelola, dan seberapa sering ada selisih atau kehabisan?
  8. Berapa lama dari pekerjaan selesai sampai invoice terbit?
  9. Alat apa yang dipakai sekarang (Excel, WhatsApp, aplikasi akuntansi)?
  10. Bagaimana kondisi sinyal di lokasi kerja, dan ponsel teknisi apa yang dipakai?
  11. Apa yang paling melelahkan atau paling sering salah?
  12. Apakah pelanggan bersedia memesan lewat aplikasi sendiri, atau lebih nyaman lewat telepon atau WhatsApp? Siapa pelanggan terbesar?
  13. Apakah pelanggan korporat punya beberapa orang yang memesan (cabang atau divisi)?
  14. Informasi apa yang paling sering ditanyakan pelanggan setelah memesan?
  15. Bersediakah menjadi design partner dengan imbalan akses gratis dan studi kasus?
- **Output yang diharapkan**: catatan wawancara per perusahaan, baseline untuk M1 sampai M7 jika tersedia, dan keputusan atas open questions yang relevan.

### 11.3 Design partner

- **Imbalan** (dari sumber): akses gratis dan studi kasus **[D]**.
- **Kriteria** [U]: bersedia meluangkan waktu untuk satu sesi uji dengan teknisi; bersedia memberi data fiktif atau anonim sebagai contoh; setuju aturan penggunaan nama dan studi kasus secara tertulis; memiliki minimal satu teknisi lapangan yang bisa menguji di perangkat sendiri.
- **Kesepakatan tertulis** [U]: ruang lingkup, data yang dipakai, cara penyimpanan, cara penghentian, dan hak penggunaan studi kasus.

### 11.4 Uji usabilitas

- **Teknisi**: uji berbasis tugas (task-based) dengan teknisi nyata, minimal 3 sampai 5 orang [A]. Tugas: buka tugas hari ini, isi checklist, ambil foto, minta tanda tangan, dan lakukan satu skenario tanpa sinyal.
- **Pelanggan**: uji pesan servis dengan 3 sampai 5 pelanggan awam [A]. Ukur keberhasilan tugas (G5) dan waktu.
- **Prototipe**: prototipe alur Lapis 1 (pelanggan dan teknisi) diuji sebelum build besar. Alat prototipe dipilih di tahap desain [U].

### 11.5 Gerbang keputusan [U]

- **G0, sebelum build Lapis 1**: wawancara minimal dilakukan. D1 (model registrasi pelanggan) dan D3 (matriks perangkat) sudah diputuskan. Ada minimal satu calon design partner atau keputusan tertulis untuk menggunakan data fiktif saja.
- **G1, sebelum build Lapis 2**: definisi SLA dan jam kerja kontrak (D2) sudah disetujui. Alur persetujuan biaya diuji dengan prototipe.
- **G2, sebelum build Lapis 3**: format CSV target (D12) sudah dipilih. Kebutuhan data biaya untuk profit per kontrak sudah jelas (R18).

---

## 12. Roadmap Rilis (Indikatif)

Semua durasi di bawah berasal dari estimasi dokumen sumber dan bersifat indikatif, bukan komitmen **[D]**. Estimasi ini harus dihitung ulang setelah blueprint (menu, use case, ERD, alur status WO) selesai **[D]**.

| Fase | Isi | Durasi indikatif (sumber) | Keluaran |
|---|---|---|---|
| Fase 0: Validasi dan desain | Wawancara 3 sampai 5 perusahaan, design partner, prototipe, blueprint, keputusan open questions | Tidak ditetapkan di sumber. Ditentukan setelah wawancara [U] | Keputusan G0, blueprint |
| R1: Lapis 1 | Inti, PWA teknisi, PWA pelanggan versi inti, laporan PDF | Sekitar 3 sampai 4 minggu **[D]** | Demo-ready Lapis 1, quality gate Lapis 1 |
| R2: Lapis 2 | SLA, berkala, persetujuan, suku cadang, notifikasi, papan jadwal, log audit | Sekitar 2 sampai 3 minggu **[D]** | Demo-ready Lapis 2, quality gate Lapis 2 |
| R3: Lapis 3 | Invoice dan ekspor, dashboard manajemen, riwayat aset, pencarian, impor Excel | Sekitar 2 sampai 3 minggu **[D]** | Demo-ready Lapis 3, quality gate Lapis 3 |
| Pilot | Uji dengan design partner, pengumpulan baseline dan metrik nyata | Tidak ditetapkan [U] | Data pilot untuk studi kasus |
| Paket studi kasus | BRD atau FSD ringkas, arsitektur, laporan quality gate, metrik hasil | Tidak ditetapkan [U] | Paket studi kasus |

Catatan:

- Jumlah estimasi sumber (sekitar 7 sampai 10 minggu untuk tiga lapis) tidak boleh dikutip sebagai komitmen **[D]**.
- Rilis berikutnya hanya dimulai setelah demo dan quality gate lapis sebelumnya lulus.
- Lapis tidak boleh dipecah lagi dengan memindahkan fitur M dari satu lapis ke lapis lain tanpa keputusan tertulis [U].

---

## 13. Asumsi Kunci

- **A1**: pelanggan terdiri dari korporat dan perorangan, dan keduanya memakai PWA yang sama [A].
- **A2**: volume WO per hari atau bulan belum diketahui. Ini ditanyakan di wawancara nomor 1 [A].
- **A3**: teknisi memakai campuran Android dan iPhone [A].
- **A4**: sinyal buruk terjadi cukup sering untuk menjadi kebutuhan utama [A].
- **A5**: stack Next.js dan Supabase dipakai untuk fullstack [A, dari permintaan].
- **A6**: bahasa antarmuka adalah Bahasa Indonesia [D untuk pelanggan, A untuk internal].
- **A7**: ada minimal satu design partner untuk pilot. Jika tidak, produk tetap bisa diselesaikan dengan data fiktif saja [A].
- **A8**: integrasi pihak ketiga terbatas pada email, WhatsApp (jika disetujui), dan ekspor CSV [U].
- **A9**: tidak ada fitur AI [D].

---

## 14. Open Questions

Setiap pertanyaan punya tenggat keputusan. Tenggat mengikuti gerbang di Bagian 11.5.

| No | Pertanyaan | Mengapa penting | Tenggat |
|---|---|---|---|
| Q1 | Model registrasi pelanggan: undangan admin (tautan sekali pakai) untuk korporat, dan mandiri dengan verifikasi untuk umum? Atau keduanya? | Menentukan alur masuk dan risiko pendaftaran palsu | G0 (D1) |
| Q2 | Apakah pelanggan bersedia memesan lewat PWA atau tetap lewat telepon dan WhatsApp? | Menentukan nilai PWA pelanggan dan G4 | G0 (wawancara 12) |
| Q3 | Berapa jenis layanan yang didemokan di Lapis 1? | Menentukan data fiktif dan template checklist | G0 |
| Q4 | Definisi SLA: tingkat prioritas, batas respons dan penyelesaian, dan definisi jam kerja kontrak. Bagaimana garansi dihitung? | Menentukan M2, eskalasi, dan aturan tagihan | G1 (D2) |
| Q5 | Kanal WhatsApp: API resmi (perlu kebijakan dan biaya), atau alternatif lain seperti tautan yang dibagikan? | Menentukan kanal notifikasi utama pelanggan | G1 (D5) |
| Q6 | Apakah review supervisor masuk Lapis 1 atau tetap Lapis 2? Apakah WO di Lapis 1 ditutup final oleh teknisi? | Alur status dan aturan penutupan | G0 [U] |
| Q7 | Penerimaan tugas (terima, tolak, minta bantuan) masuk Lapis 1 atau Lapis 2? | Alur teknisi dan penugasan ulang | G0 [U] |
| Q8 | Akun multi-pengguna pelanggan: Lapis 3 sesuai sumber, atau perlu lebih awal untuk pelanggan korporat? | Risiko pergantian karyawan dan isolasi data | G1 |
| Q9 | Pemulihan kata sandi di Lapis 1: diterima sebagai tambahan? | Kebutuhan dasar akun | G0 [U] |
| Q10 | Matriks perangkat dan browser: versi minimum Android, iOS, dan browser yang didukung? | Quality gate dan uji | G0 (D3) |
| Q11 | Pemindai QR: Lapis 1 (C) atau Lapis 2? | Ruang lingkup Lapis 1 | G0 |
| Q12 | Impor Excel: tetap Lapis 3 atau dipindah lebih awal untuk setup pilot? | Kesiapan data demo dan pilot | G1 |
| Q13 | Format CSV atau aplikasi akuntansi target untuk ekspor? | Kriteria uji Lapis 3 | G2 (D12) |
| Q14 | Aturan pajak (PPN), penomoran invoice, dan template laporan servis | Invoice yang sah secara format | G2 (D13) |
| Q15 | Retensi foto dan data pribadi, dan lokasi penyimpanan data | Kepatuhan UU PDP | Sebelum pilot (D14) |
| Q16 | GPS pada check-in: wajib atau opsional? Apa yang terjadi bila izin ditolak? | Privasi dan kelengkapan data | G0 [U] |
| Q17 | Siapa yang menetapkan estimasi biaya dan batas persetujuan tambahan? | Alur persetujuan biaya | G1 |
| Q18 | Aturan pembatalan WO: siapa yang boleh membatalkan, dan kapan? | Kasus tepi R6 | G0 |
| Q19 | Sumber data biaya (tenaga kerja, suku cadang, dan lainnya) untuk profit per kontrak, tanpa penggajian | Akurasi M-profit dan dashboard | G2 (R18) |
| Q20 | Apakah ada design partner nyata untuk pilot, atau semua pengujian memakai data fiktif? | Klaim studi kasus dan metrik | G0 |
| Q21 | Kebijakan konflik data offline (R13): aturan mana yang menang saat perubahan bertabrakan? | Integritas data lapangan | G0 [U] |

---

## 15. Catatan Terakhir

- Dokumen ini adalah gambaran kebutuhan awal untuk keperluan portofolio **[D]**. Detail proses, angka, dan klaim studi kasus harus divalidasi dengan perusahaan servis nyata **[D]**.
- Angka target di Bagian 5 bukan komitmen dan harus ditetapkan ulang setelah baseline.
- Detail teknis, arsitektur, dan skema database ada di dokumen 02.
