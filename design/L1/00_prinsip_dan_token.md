# Desain Lapis 1: Prinsip dan Token (WP-006)

Status: draf untuk disetujui user. Pelaksana: orkestrator. Belum diuji dengan orang nyata (G5, M7 adalah tindakan manusia).
Rujukan: 01 bagian 4, 6.1, 8; 02 FR-060, FR-063, FR-081, bagian 4.2; keputusan di `docs/orchestration/decisions.md`.

## 1. Prinsip

1. **Tombol besar, sedikit ketikan** (FR-063, R1). Pilih daripada ketik; isian wajib sesedikit mungkin.
2. **Satu tujuan per layar** di PWA teknisi dan pelanggan. Aksi utama selalu satu tombol penuh lebar di bawah.
3. **Bahasa Indonesia sederhana, huruf besar** (FR-081). Tidak ada istilah internal (`ASSIGNED`, `SLA`) di layar pelanggan (FR-036).
4. **Keadaan sinkron selalu terlihat** (FR-060): global di header, per item di daftar. Tidak pernah menyiratkan "tersimpan di server" sebelum ACK (NFR-O3).
5. **Tidak ada aksi diam-diam**: setiap kegagalan menampilkan apa yang terjadi dan apa yang bisa dilakukan.
6. **Tidak mengandalkan warna saja**: status selalu punya teks dan ikon.
7. **Teknisi tidak melihat harga** (AP-2, 05 D16). Pelanggan tidak melihat catatan internal.
8. **Penanda lingkungan demo** terlihat di semua kanal (pita "DEMO: data fiktif"), RK-16.

## 2. Token (diimplementasi di `src/styles/tokens.css`)

Kontras dihitung dengan rumus WCAG 2.x (skrip lokal, 2026-10-12). Batas 4.5:1 untuk teks biasa.

| Token                          | Nilai             | Pasangan      | Rasio terhitung |
| ------------------------------ | ----------------- | ------------- | --------------- |
| `--fg`                         | #14213D           | latar #FFFFFF | 15.97           |
| `--fg-muted`                   | #4B5563           | #FFFFFF       | 7.56            |
| `--primary` / teks pada primer | #1D4ED8 / #FFFFFF |               | 6.70            |
| `--success`                    | #166534           | #DCFCE7       | 6.49            |
| `--warning`                    | #92400E           | #FEF3C7       | 6.37            |
| `--danger`                     | #B91C1C           | #FEE2E2       | 5.30            |
| `--danger` solid               | #FFFFFF           | #B91C1C       | 6.47            |
| `--info`                       | #1E40AF           | #DBEAFE       | 7.15            |
| `--neutral`                    | #374151           | #F3F4F6       | 9.37            |
| fokus (cincin)                 | #1D4ED8           | #FFFFFF       | 6.70            |

Ukuran dan jarak:

- **Area sentuh minimum 48 x 48 px**; tombol aksi utama tinggi 56 px (angka ini usulan; WCAG 2.2 meminta minimum 24 px, dan menyarankan 44 px).
- Huruf dasar **18 px** di PWA (staf desktop 16 px). Judul 24/28 px. Jarak antar target sentuh minimal 8 px.
- Skala jarak: 4, 8, 12, 16, 24, 32. Radius 12 px.
- Gerak: hormati `prefers-reduced-motion`.
- Fokus terlihat: cincin 3 px, offset 2 px.

Catatan: kontras dan ukuran ini dihitung, bukan diuji di layar ponsel nyata di bawah matahari. Uji nyata ada di WP-115 dan WP-117.

## 3. Pola komponen dasar (`src/components/ui/`)

| Komponen        | Pakai untuk  | Aturan                                                                                     |
| --------------- | ------------ | ------------------------------------------------------------------------------------------ |
| `Button`        | Aksi         | Varian `primary`, `secondary`, `danger`; tinggi 56 px; `loading` mematikan klik ganda      |
| `Field`         | Isian        | Label di atas, bantuan di bawah, galat dengan teks (bukan hanya warna), `aria-describedby` |
| `StatusBadge`   | Status       | Warna + ikon + teks                                                                        |
| `SyncIndicator` | Sinkron      | Empat keadaan FR-060: belum terkirim, mengirim, terkirim, gagal                            |
| `DemoBanner`    | Penanda demo | Tampil bila `NEXT_PUBLIC_APP_ENV` bukan `production`                                       |

Komponen lain (kanvas tanda tangan, kamera/foto, tabel data, dialog) ditulis di WP yang memakainya (WP-105, WP-107, WP-108) mengikuti token ini.
