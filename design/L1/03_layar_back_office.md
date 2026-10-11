# Back-office (Web Desktop): Spesifikasi Layar L1

Rujukan: 01 L1-A01..A04, L1-D01..D03, L1-X01..X03, bagian 8.3; 02 matriks peran 1.3. Menu mengikuti peran dan akses URL langsung tanpa hak ditolak.
Penulisan tabel WO lewat Jalur B (API), tidak langsung ke Supabase dari halaman.

| Menu                                 | Peran                 | Layar dan fungsi                                                                                                                            | Catatan                                                   |
| ------------------------------------ | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| Dashboard (daftar hari ini)          | semua staf sesuai hak | Ringkasan WO hari ini                                                                                                                       | Dashboard manajemen ada di L3                             |
| Permintaan Masuk                     | ADM                   | Antrean validasi (setujui, minta info, tolak dengan alasan); input atas nama pelanggan (telepon/chat); tanda duplikat                       | Menyetujui membuat WO (FR-022)                            |
| Work Order                           | ADM, DSP, SPV, OWN    | Daftar + filter; detail dengan riwayat status; batalkan dengan alasan                                                                       | Konflik versi menampilkan keadaan terbaru (03 bagian 4.6) |
| Penugasan                            | DSP                   | WO belum ditugaskan; pilih teknisi dengan keahlian dan beban; peringatan lunak + `override_reason` (05 D20); tugaskan ulang setelah ditolak | Papan jadwal ada di L2                                    |
| Monitor Hari Ini                     | DSP, SPV              | Pekerjaan hari ini dan statusnya (`v_today_work_orders`)                                                                                    |                                                           |
| Pelanggan, Lokasi, Aset              | ADM                   | CRUD master, kode/QR cetak aset                                                                                                             | Nonaktifkan, bukan hapus (FR-015)                         |
| Teknisi                              | ADM                   | Master teknisi + keahlian                                                                                                                   |                                                           |
| Jenis Layanan dan Template Checklist | ADM                   | AC, genset, CCTV (K-03)                                                                                                                     | Pengaturan lanjut di L2                                   |
| Laporan Servis                       | ADM, SPV              | Daftar dan unduh PDF                                                                                                                        |                                                           |
| Pengguna dan Hak Akses               | ADM, OWN              | Kelola pengguna; ubah peran OWNER/ADMIN_CS hanya OWNER (05 D22)                                                                             |                                                           |

Tabel data: baris dapat diklik penuh, kolom dapat diurutkan, galat jelas, dialog konfirmasi untuk aksi yang tidak bisa dibatalkan. Tidak ada angka bisnis bawaan (SLA, tarif).
