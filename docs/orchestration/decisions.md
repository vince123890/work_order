# Keputusan Gerbang G0 (WP-000)

Tanggal: 2026-10-12. Dicatat atas arahan user: "gunakan semua usulan saja dulu".
Artinya: setiap butir di bawah memakai usulan bawaan dari dokumen 01-05. Ini keputusan sementara untuk memulai, bukan validasi bisnis. Butir tanpa usulan bawaan tetap TERBUKA.

## A. Diputuskan: pakai usulan bawaan

| ID | Keputusan yang berlaku | Sumber usulan |
|---|---|---|
| K-01 | `customer_signup_mode` dapat dikonfigurasi (`INVITE_ONLY`/`SELF_OTP`/`BOTH`); pelanggan korporat ditautkan oleh ADM [A] | 03 bagian 3.1 |
| K-02 | Tanpa design partner; seluruhnya data fiktif; metrik berlabel simulasi (R16) | 01 A7 |
| K-03 | Tiga jenis layanan demo Lapis 1, dipilih penyusun atas arahan user "pilih sendiri": servis AC/pendingin, servis genset, instalasi/servis CCTV (selaras saran 01 bagian 11.2: pendingin dan genset atau CCTV). Template checklist dibuat per jenis | Arahan user 2026-10-12 |
| K-04 | **DIUBAH 2026-10-12 oleh user:** penutupan WO di demo Lapis 1 dilakukan oleh **Supervisor** (T-19 `APPROVE_CLOSE`, sesuai database). Teknisi hanya `SUBMIT_REVIEW`. Tidak ada setelan penutupan otomatis. Usulan awal (teknisi menutup final, API-AS-03) dicabut | G-01 di `gaps_for_decision.md` |
| K-05 | Usulan 02 bagian 10 diterima: RK-01..08, RK-11, RK-14 masuk Lapis 1; RK-13 (persetujuan) dan model data RK-10 ke Lapis 1; RK-09 (impor sederhana) ke Lapis 1.5; UI multi-pengguna RK-10 ke Lapis 2. Lapis 1 belum dipecah 1a/1b | 02 bagian 10 |
| K-06 | Deviasi 05 D01, D02, D08, D10, D11, D16, D17, D18, D19, D21, D22 disetujui (sudah diterapkan di 04) | 05 bagian 0 |
| K-07 | WP-003 melaporkan tabel tambahan mana yang sudah ada di 04; sisanya lewat CR. Persetujuan user hanya bila perubahan skema substansial | 01 plan K-07 |
| K-09 | Nilai awal foto (sekitar 1600 px, kualitas sekitar 0,7, di bawah sekitar 500 KB) sebagai titik awal [A][P]; ditetapkan final setelah WP-116 mengukur. Nilai lain ([P]) diusulkan agen, disetujui user | 02 NFR-P1 |
| K-10 | Server menang untuk data back-office; teknisi menang untuk data lapangan; tidak ada data lapangan dibuang diam-diam | 02 DEC-06 |
| K-11 | QR aset dan ajakan pasang PWA (C) tidak dijadwalkan di Lapis 1 | 01 bagian 6.1 |
| K-13 | Pelanggan batal langsung hanya dari `NEW`; setelahnya hanya mengajukan | 02 DEC-04, 05 D10 |
| K-14 (sebagian) | Check-in tanpa lokasi tetap boleh dengan alasan bila izin GPS ditolak | 02 acceptance FR-053 |
| K-17 | Delapan peran (ADM dan DSP tidak digabung) | 05 D03 |

API-AS-01, 02, 04, 05, 06, 07, 08, 09, 11, 13 (03 bagian 10.1, rangkuman di plan 4.4) dianggap disetujui kolektif.

## B. TERBUKA: tidak ada usulan bawaan di dokumen

| ID | Yang masih dibutuhkan | WP tertahan |
|---|---|---|
| K-08 | Hosting dan region data | WP-010 |
| K-12 | Retensi data pribadi dan penilaian hukum UU PDP oleh manusia/ahli | WP-111, WP-311 |
| K-14 (sisa) | Matriks versi minimum Android, iOS, browser | WP-112, WP-117 |
| K-15 | Template tata letak laporan servis PDF | WP-104 |
| K-16 | Persetujuan akhir tiap gerbang kualitas dan ambang performa [T]. Selalu oleh user | WP-119, WP-219, WP-316 |

## C. Pekerjaan manusia yang masih ada

- Membuat proyek Supabase dan menyimpan rahasia di luar repo.
- Menyiapkan perangkat uji nyata (D4): satu Android, satu iPhone.
- Menyetujui atau menolak safety net git (03 bagian 8).
- Gerbang G0 (01 bagian 11.5) menyatakan wawancara minimal sebelum build Lapis 1. Keputusan K-02 (data fiktif) memenuhi syarat "keputusan tertulis memakai data fiktif saja", tetapi wawancara tetap disarankan.

## D. Keputusan tambahan 2026-10-12 (jawaban user atas `gaps_for_decision.md`)
| ID | Keputusan |
|---|---|
| G-01 | Supervisor menutup WO di demo L1 (lihat K-04 di atas). |
| G-02 | Batas laju pemesanan hanya per pelanggan (trigger), tanpa batas per IP. |
| G-06 | Status operasi sinkron dicatat lewat RPC baru (`sync_op_record`), bukan memperluas daftar `service_role`. |
| Migrasi `0016` | **Menunggu persetujuan eksplisit user sebelum DITERAPKAN.** File boleh disiapkan dan diuji dalam transaksi yang di-rollback. |
