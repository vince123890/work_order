# Review WP-007 v1: harness uji isolasi (security-auditor, read-only)

Status: **DITOLAK** (4 blocker). Reviewer tidak menjalankan uji; temuan berasal dari pembacaan file. Disimpan oleh orchestrator dari laporan agen. S1 dan S2 sudah diverifikasi ulang orchestrator ke `0010:902-916` dan `0013:461-462`.

## 1. Pemetaan 05 bagian 7.2 ke uji
Dari 18 baris: 1 tercakup penuh (`tables_without_rls`), 15 sebagian, 2 TIDAK tercakup (pengguna tanpa pemetaan pelanggan; pengguna `is_active=false`). Baris yang lemah: Tabel (hanya cek `customer_id`), Tebakan ID (lampiran tidak), View (`customer_extra_cost_approvals` tidak ada), RPC (`extra_cost_decide` tidak diuji), Storage (hanya sisi `false`), Teknisi (skenario setelah REASSIGN tidak ada), Append-only (TRUNCATE tidak, `stock_movements` di-skip).

## 2. Temuan uji
| No | Tingkat | Ringkas |
|---|---|---|
| T1 | blocker | Fixture hanya 1 WO `ASSIGNED` per pelanggan: tidak ada WO CLOSED, lampiran, persetujuan biaya, laporan, tanda tangan, invoice, rating, komplain, notifikasi. Banyak asersi "0 baris" lulus vakum (`customer_wo_photos`, `customer_service_reports`, `wo_part_usages`, `wo_labor_lines`, `extra_cost_approvals`, `wo_attachments`, `wo_signatures`). Perbandingan silang `ids(rb)` kosong sehingga tidak menjalankan asersi. Perlu kontrol positif `rows.length>0`. |
| T2 | blocker | Storage nyata memakai `x.jpg` yang tidak pernah ada, jadi >=400 muncul walau policy bocor. Perlu objek terdaftar yang sah + kontrol positif. |
| T3 | blocker | `can_read_object`: semua asersi `false`; fungsi yang selalu `false` lulus. Perlu kasus positif, kind `OTHER`/`FAILED_VISIT`, WO belum CLOSED, dan bukti `auth.uid()` terbaca (`app.my_customer_ids()`). |
| T4 | blocker | `customer_extra_cost_approvals` (mengekspos total, unit_price, subtotal, content_hash) dan RPC `extra_cost_decide` tidak diuji sama sekali. |
| T5 | major | `wo_cost_summary` selalu `WO005` bagi pelanggan (bahkan WO sendiri), jadi tidak membuktikan isolasi; uji "404 seragam" bisa sama-sama `undefined`. Bandingkan code/status/message/details/hint + kontrol staf berhasil. |
| T6 | major | Cek hanya `"customer_id" in row`: `customers` memakai kolom `id`; relasi tanpa `customer_id` dilewati; `rowsOf()` menelan galat; `limit=200`+`break`; tak ada ALLOWED_TABLES; tak ada kontrol positif. |
| T7 | major | Uji "schema app tidak terekspos" tautologis (`>=0`) dan meminta `app_settings` yang ada di `public`. Pakai objek nyata di `app` + harapkan `PGRST106`. |
| T8 | major | "ADM tidak bisa memberi OWNER" menulis langsung ke `user_roles` (ditolak karena tak ada GRANT), bukan menguji guard di `admin_set_user_roles`. |
| T9 | major | `denied()` = status>=400 menerima 500/404/RL001/400/23502; tak ada kontrol payload sah; `duplicate_of` tidak diuji; 23503 FK komposit tidak diverifikasi. |
| T10 | major | ASSIGN/APPROVE_CLOSE menerima `WO002/WO001/WO005`; 05 mensyaratkan `WO002`. |
| T11 | major | Kolom harga di `tech_*`, `v_items_catalog` tidak diuji; `it.fails` G-08 lulus pada kegagalan apa pun (token/jaringan). Pecah jadi dua uji. |
| T12 | major | PATCH `work_orders.status` ditolak karena tak ada GRANT UPDATE, bukan trigger `WO001`; `after[0]?.status` bisa `undefined`. |
| T13 | major | `stock_movements` kosong di-skip; TRUNCATE, `access_logs`, `user_consents` tidak diuji. |
| T14 | major | Kolom terlarang hanya diperiksa di `customer_work_orders` dengan daftar hitam; pakai allow-list dari `information_schema`. |
| T15 | major | Hanya 6 dari ~28 RPC yang di-GRANT ke `authenticated` diuji dari sisi pelanggan. Turunkan dari `pg_proc`. |
| T16 | major | Hilang: pengguna tanpa pemetaan pelanggan, pelanggan multi-customer, `is_active=false`, REASSIGN lalu teknisi lama, update status permintaan oleh pelanggan, `duplicate_of`, lampiran B. |
| T17-T20 | minor | Kontrol positif update aset sendiri; `search_path` harus tepat `''`; anon untuk seluruh relasi + kode 42501; `CUSTOMER_FORBIDDEN` diturunkan dari `pg_class`. |

## 3. Tabel/view/RPC yang belum terliput
- Harus 0 baris bagi pelanggan: `wo_photo_requirements, wo_transitions, sla_pauses, extra_cost_approval_items, part_request_lines, part_return_lines, stock_locations, stock_balances, customer_invitations, import_jobs, job_runs, business_calendars, calendar_hours, calendar_holidays, sla_policy_sets, escalation_rules, priorities, reason_codes, skills, asset_categories, checklist_templates, checklist_template_items, photo_requirements, service_items, items, rate_limits, document_counters` (beberapa mungkin memang boleh dibaca; perlu dicek ke matriks 05 bagian 3).
- Harus "hanya milik sendiri" tanpa asersi positif: `customers, customer_sites, assets, contracts, contract_assets, pm_periods, request_attachments, invoices, invoice_lines, payments, ratings, complaints, notifications, customer_users, user_roles, user_consents, profiles`.
- View belum diuji dari sisi pelanggan: `tech_wo_part_usages, tech_wo_labor_lines, tech_extra_cost_approvals, v_items_catalog, v_wh_part_requests, v_tech_asset_service_history, v_today_work_orders, v_open_part_variances, v_job_health, v_finance_ready_to_bill, v_kpi_sla_monthly`.

## 4. Risiko di SQL (dibaca reviewer dari file)
| No | Tingkat | Lokasi | Ringkas |
|---|---|---|---|
| S1 | major | `0010:902-916` | `wo_cost_summary` boleh dipanggil teknisi pada WO aktifnya dan mengembalikan `estimate_total`, `projected_total`, `tolerance`: bocor harga ke teknisi (AP-2/D16); belum tercatat di G-08. **Diverifikasi orchestrator.** |
| S2 | major | `0013:461-462` | `payments_customer` tidak memfilter `i.status in ('ISSUED','PAID')` (berbeda dari `invoices_customer` dan `invoice_lines_customer`): pelanggan melihat pembayaran invoice DRAFT. **Diverifikasi orchestrator.** |
| S3 | minor | `0013:170-175` | `app.wo_storage_prefix` dkk di-GRANT ke `authenticated`; aman hanya selama schema `app` tidak terekspos. |
| S4 | minor | `0013:54-56,44-47` | `can_read_object` cabang `req` tidak memeriksa bucket; teknisi bisa membaca bucket `reports` untuk WO aktifnya. |
| S5 | minor | `0010:724-727` | `extra_cost_decide` mengunci baris (`FOR UPDATE`) sebelum cek otorisasi. |
| S6 | minor | `0013:67-85` | `admin_set_user_roles`: ADMIN_CS bebas memberi SUPERVISOR/FINANCE/WAREHOUSE/TECHNICIAN (termasuk ke dirinya). |
| S7 | minor | `0013:471,212` | `sync_operations_insert_own` tidak memverifikasi `wo_id` milik pengguna (tergantung API). |
| S8 | minor | `0013:164-165` | `alter default privileges` hanya untuk peran penjalan migrasi; tidak terverifikasi. |
| S9 | minor | `0003:69` | Pelanggan membaca `customers.auto_approve` (kontrol internal SP-02). |

Positif terverifikasi: enam view `customer_*` memakai `security_barrier` + filter `customer_id`; fungsi SECURITY DEFINER yang dibaca memakai `search_path = ''`; RLS aktif di semua tabel `public`; hak `anon` dicabut.

Kesimpulan reviewer: perbaiki T1-T4 sebelum WP-007 dinyatakan selesai.
