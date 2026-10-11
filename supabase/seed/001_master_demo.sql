-- Seed data fiktif Lapis 1 (WP-008). Idempoten: aman dijalankan berulang.
-- SEMUA DATA FIKTIF (NFR-D8). Tidak ada angka bisnis: tarif, SLA, dan harga dibiarkan NULL.
-- Tanda seed: kode pelanggan/aset berawalan "DEMO-", email @demo.vasta.test.
-- Akun pengguna dibuat oleh tools/seed.mjs (butuh hash kata sandi), bukan di berkas ini.

do $seed$
declare
  v_tpl_ac uuid; v_tpl_gs uuid; v_tpl_cc uuid;
  v_sk_ac uuid; v_sk_gs uuid; v_sk_cc uuid;
  v_cat_ac uuid; v_cat_gs uuid; v_cat_cc uuid;
  v_st_ac uuid; v_st_gs uuid; v_st_cc uuid;
  v_ca uuid; v_cb uuid; v_cc uuid;
  v_sa1 uuid; v_sa2 uuid; v_sb1 uuid; v_sc1 uuid;
begin
  -- ---- keahlian --------------------------------------------------------------
  insert into public.skills (code, name) values
    ('AC', 'Servis AC / pendingin'), ('GENSET', 'Servis genset'), ('CCTV', 'Instalasi / servis CCTV')
  on conflict (code) do nothing;
  select id into v_sk_ac from public.skills where code = 'AC';
  select id into v_sk_gs from public.skills where code = 'GENSET';
  select id into v_sk_cc from public.skills where code = 'CCTV';

  -- ---- template checklist ----------------------------------------------------
  insert into public.checklist_templates (code, version_no, name) values
    ('CL-AC', 1, 'Checklist servis AC'),
    ('CL-GENSET', 1, 'Checklist servis genset'),
    ('CL-CCTV', 1, 'Checklist servis CCTV')
  on conflict (code, version_no) do nothing;
  select id into v_tpl_ac from public.checklist_templates where code = 'CL-AC' and version_no = 1;
  select id into v_tpl_gs from public.checklist_templates where code = 'CL-GENSET' and version_no = 1;
  select id into v_tpl_cc from public.checklist_templates where code = 'CL-CCTV' and version_no = 1;

  insert into public.checklist_template_items (template_id, seq, label, input_type, choices, required, photo_required) values
    (v_tpl_ac, 1, 'Kondisi fisik unit dalam dan luar', 'BOOLEAN', null, true, true),
    (v_tpl_ac, 2, 'Filter udara dibersihkan', 'BOOLEAN', null, true, false),
    (v_tpl_ac, 3, 'Aliran pembuangan air (drain) lancar', 'BOOLEAN', null, true, false),
    (v_tpl_ac, 4, 'Arus kompresor (ampere)', 'NUMBER', null, false, false),
    (v_tpl_ac, 5, 'Suhu udara keluar (derajat C)', 'NUMBER', null, false, false),
    (v_tpl_ac, 6, 'Kondisi tekanan freon', 'CHOICE', '["Normal","Kurang","Berlebih"]'::jsonb, true, false),
    (v_tpl_ac, 7, 'Catatan tambahan', 'TEXT', null, false, false),
    (v_tpl_gs, 1, 'Kondisi fisik dan kebocoran', 'BOOLEAN', null, true, true),
    (v_tpl_gs, 2, 'Level oli mesin', 'CHOICE', '["Cukup","Kurang"]'::jsonb, true, false),
    (v_tpl_gs, 3, 'Level bahan bakar', 'CHOICE', '["Cukup","Kurang"]'::jsonb, true, false),
    (v_tpl_gs, 4, 'Kondisi aki', 'BOOLEAN', null, true, false),
    (v_tpl_gs, 5, 'Tes start tanpa beban berhasil', 'BOOLEAN', null, true, false),
    (v_tpl_gs, 6, 'Tes ATS / transfer beban', 'CHOICE', '["Baik","Perlu perbaikan","Tidak ada ATS"]'::jsonb, true, false),
    (v_tpl_gs, 7, 'Catatan tambahan', 'TEXT', null, false, false),
    (v_tpl_cc, 1, 'Semua kamera menampilkan gambar', 'BOOLEAN', null, true, true),
    (v_tpl_cc, 2, 'Perekam (DVR/NVR) menyala normal', 'BOOLEAN', null, true, false),
    (v_tpl_cc, 3, 'Kondisi kabel dan catu daya', 'BOOLEAN', null, true, false),
    (v_tpl_cc, 4, 'Waktu perekam sesuai waktu setempat', 'BOOLEAN', null, true, false),
    (v_tpl_cc, 5, 'Uji putar ulang rekaman berhasil', 'BOOLEAN', null, true, false),
    (v_tpl_cc, 6, 'Catatan tambahan', 'TEXT', null, false, false)
  on conflict (template_id, seq) do nothing;

  insert into public.photo_requirements (template_id, kind, min_count) values
    (v_tpl_ac, 'BEFORE', 1), (v_tpl_ac, 'AFTER', 1),
    (v_tpl_gs, 'BEFORE', 1), (v_tpl_gs, 'AFTER', 1),
    (v_tpl_cc, 'BEFORE', 1), (v_tpl_cc, 'AFTER', 1)
  on conflict (template_id, kind) do nothing;

  -- ---- kategori aset dan jenis layanan --------------------------------------------
  insert into public.asset_categories (code, name, default_checklist_template_id) values
    ('AC', 'AC / pendingin', v_tpl_ac), ('GENSET', 'Genset', v_tpl_gs), ('CCTV', 'CCTV', v_tpl_cc)
  on conflict (code) do nothing;
  select id into v_cat_ac from public.asset_categories where code = 'AC';
  select id into v_cat_gs from public.asset_categories where code = 'GENSET';
  select id into v_cat_cc from public.asset_categories where code = 'CCTV';

  insert into public.service_types (code, name, skill_id, default_checklist_template_id, default_priority_code) values
    ('SVC-AC', 'Servis AC', v_sk_ac, v_tpl_ac, 'NORMAL'),
    ('SVC-GENSET', 'Servis genset', v_sk_gs, v_tpl_gs, 'NORMAL'),
    ('SVC-CCTV', 'Servis CCTV', v_sk_cc, v_tpl_cc, 'NORMAL')
  on conflict (code) do nothing;
  select id into v_st_ac from public.service_types where code = 'SVC-AC';
  select id into v_st_gs from public.service_types where code = 'SVC-GENSET';
  select id into v_st_cc from public.service_types where code = 'SVC-CCTV';

  insert into public.problem_types (code, name, service_type_id) values
    ('AC-NOT-COLD', 'AC tidak dingin', v_st_ac),
    ('AC-LEAK', 'AC bocor air', v_st_ac),
    ('AC-NOISE', 'AC berisik', v_st_ac),
    ('AC-ROUTINE', 'Servis rutin AC', v_st_ac),
    ('GS-NO-START', 'Genset tidak mau menyala', v_st_gs),
    ('GS-ROUTINE', 'Servis rutin genset', v_st_gs),
    ('CC-NO-IMAGE', 'Kamera tidak menampilkan gambar', v_st_cc),
    ('CC-NO-RECORD', 'Rekaman tidak tersimpan', v_st_cc),
    ('CC-ROUTINE', 'Pemeriksaan rutin CCTV', v_st_cc)
  on conflict (code) do nothing;

  -- ---- pelanggan fiktif ----------------------------------------------------------
  insert into public.customers (code, name, type, contact_name, contact_phone, contact_email, address) values
    ('DEMO-PLG-A', 'PT Contoh Sejahtera (fiktif)', 'CORPORATE', 'Rina Contoh', '0812-0000-0001', 'rina@demo.vasta.test', 'Jl. Fiktif No. 1, Jakarta'),
    ('DEMO-PLG-B', 'CV Maju Bersama (fiktif)', 'CORPORATE', 'Dedi Contoh', '0812-0000-0002', 'dedi@demo.vasta.test', 'Jl. Fiktif No. 2, Bandung'),
    ('DEMO-PLG-C', 'Budi Santoso (fiktif)', 'INDIVIDUAL', 'Budi Santoso', '0812-0000-0003', 'budi@demo.vasta.test', 'Jl. Fiktif No. 3, Bekasi')
  on conflict (code) do nothing;
  select id into v_ca from public.customers where code = 'DEMO-PLG-A';
  select id into v_cb from public.customers where code = 'DEMO-PLG-B';
  select id into v_cc from public.customers where code = 'DEMO-PLG-C';

  -- lokasi (nama unik per pelanggan dijaga lewat pemeriksaan eksistensi)
  insert into public.customer_sites (customer_id, name, address, lat, lng, pic_name, pic_phone)
  select v_ca, 'Kantor Pusat', 'Jl. Fiktif No. 1, Jakarta', -6.200000, 106.816666, 'Rina Contoh', '0812-0000-0001'
  where not exists (select 1 from public.customer_sites where customer_id = v_ca and name = 'Kantor Pusat');
  insert into public.customer_sites (customer_id, name, address, lat, lng, pic_name, pic_phone)
  select v_ca, 'Gudang Timur', 'Jl. Fiktif Gudang No. 9, Bekasi', -6.241586, 106.992416, 'Agus Gudang', '0812-0000-0004'
  where not exists (select 1 from public.customer_sites where customer_id = v_ca and name = 'Gudang Timur');
  insert into public.customer_sites (customer_id, name, address, lat, lng, pic_name, pic_phone)
  select v_cb, 'Toko Utama', 'Jl. Fiktif No. 2, Bandung', -6.917464, 107.619125, 'Dedi Contoh', '0812-0000-0002'
  where not exists (select 1 from public.customer_sites where customer_id = v_cb and name = 'Toko Utama');
  insert into public.customer_sites (customer_id, name, address, lat, lng, pic_name, pic_phone)
  select v_cc, 'Rumah', 'Jl. Fiktif No. 3, Bekasi', -6.234800, 106.992000, 'Budi Santoso', '0812-0000-0003'
  where not exists (select 1 from public.customer_sites where customer_id = v_cc and name = 'Rumah');

  select id into v_sa1 from public.customer_sites where customer_id = v_ca and name = 'Kantor Pusat';
  select id into v_sa2 from public.customer_sites where customer_id = v_ca and name = 'Gudang Timur';
  select id into v_sb1 from public.customer_sites where customer_id = v_cb and name = 'Toko Utama';
  select id into v_sc1 from public.customer_sites where customer_id = v_cc and name = 'Rumah';

  -- ---- aset fiktif ---------------------------------------------------------------
  insert into public.assets (customer_id, site_id, category_id, asset_code, serial_no, brand, model, install_date, warranty_start, warranty_end) values
    (v_ca, v_sa1, v_cat_ac, 'DEMO-A-AC-01', 'SN-FIKTIF-0001', 'MerekFiktif', 'AC-9000', '2024-03-01', '2024-03-01', '2027-03-01'),
    (v_ca, v_sa1, v_cat_ac, 'DEMO-A-AC-02', 'SN-FIKTIF-0002', 'MerekFiktif', 'AC-9000', '2022-06-15', '2022-06-15', '2024-06-15'),
    (v_ca, v_sa1, v_cat_cc, 'DEMO-A-CC-01', 'SN-FIKTIF-0003', 'LensaFiktif', 'NVR-16', '2023-01-10', '2023-01-10', '2025-01-10'),
    (v_ca, v_sa2, v_cat_gs, 'DEMO-A-GS-01', 'SN-FIKTIF-0004', 'DayaFiktif', 'GS-50', '2021-09-01', '2021-09-01', '2023-09-01'),
    (v_ca, v_sa2, v_cat_ac, 'DEMO-A-AC-03', 'SN-FIKTIF-0005', 'MerekFiktif', 'AC-12000', '2025-02-01', '2025-02-01', '2028-02-01'),
    (v_ca, v_sa2, v_cat_cc, 'DEMO-A-CC-02', 'SN-FIKTIF-0006', 'LensaFiktif', 'CAM-8', '2023-05-05', '2023-05-05', '2025-05-05'),
    (v_cb, v_sb1, v_cat_ac, 'DEMO-B-AC-01', 'SN-FIKTIF-0101', 'MerekFiktif', 'AC-9000', '2024-08-01', '2024-08-01', '2027-08-01'),
    (v_cb, v_sb1, v_cat_ac, 'DEMO-B-AC-02', 'SN-FIKTIF-0102', 'MerekFiktif', 'AC-9000', '2023-02-01', '2023-02-01', '2025-02-01'),
    (v_cb, v_sb1, v_cat_cc, 'DEMO-B-CC-01', 'SN-FIKTIF-0103', 'LensaFiktif', 'DVR-8', '2022-11-20', '2022-11-20', '2024-11-20'),
    (v_cc, v_sc1, v_cat_ac, 'DEMO-C-AC-01', 'SN-FIKTIF-0201', 'MerekFiktif', 'AC-9000', '2025-01-15', '2025-01-15', '2028-01-15')
  on conflict (asset_code) do nothing;
end
$seed$;
