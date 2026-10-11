-- ===== MIGRATION 0015: seed struktural (TANPA angka bisnis) ============================
-- Hanya lookup & konfigurasi kerangka. Nilai [P] diisi bisnis (lihat app_settings, sla_policies, escalation_rules).
insert into public.priorities (code, name, sort_rank) values
  ('LOW', 'Rendah', 10), ('NORMAL', 'Normal', 20), ('HIGH', 'Tinggi', 30), ('CRITICAL', 'Kritis', 40)
on conflict (code) do nothing;    -- contoh awal; ganti/tambah sesuai hasil wawancara (OQ-06)

insert into public.reason_codes (category, code, label) values
  ('CLOSURE_EXCEPTION', 'CUSTOMER_ABSENT',  'Pelanggan tidak ada di lokasi'),
  ('CLOSURE_EXCEPTION', 'CUSTOMER_REFUSED', 'Pelanggan menolak menandatangani'),
  ('CLOSURE_EXCEPTION', 'NO_RESPONSE',      'Pelanggan tidak menjawab hingga batas waktu (sistem)'),
  ('CLOSURE_EXCEPTION', 'OTHER',            'Lainnya (catatan wajib)'),
  ('CANCEL', 'CUSTOMER_REQUEST', 'Permintaan pelanggan'),
  ('CANCEL', 'DUPLICATE',        'Pesanan ganda'),
  ('CANCEL', 'CONTRACT_CHANGED', 'Kontrak berubah (sistem)'),
  ('CANCEL', 'OTHER',            'Lainnya'),
  ('REJECT_ASSIGNMENT', 'UNAVAILABLE',    'Tidak tersedia'),
  ('REJECT_ASSIGNMENT', 'SKILL_MISMATCH', 'Keahlian tidak sesuai'),
  ('REJECT_ASSIGNMENT', 'OTHER',          'Lainnya'),
  ('FAILED_VISIT', 'CUSTOMER_ABSENT', 'Pelanggan tidak ada'),
  ('FAILED_VISIT', 'ACCESS_DENIED',   'Akses ke lokasi ditolak'),
  ('FAILED_VISIT', 'OTHER',           'Lainnya'),
  ('REQUEST_REJECT', 'INVALID_ASSET', 'Aset tidak valid'),
  ('REQUEST_REJECT', 'OUT_OF_SCOPE',  'Di luar cakupan layanan'),
  ('REQUEST_REJECT', 'DUPLICATE',     'Pesanan ganda'),
  ('REQUEST_REJECT', 'OTHER',         'Lainnya')
on conflict do nothing;

-- Kunci setting. value NULL = belum diputuskan/nonaktif. Hanya tiga yang berisi nilai struktural (bukan angka bisnis).
insert into public.app_settings (key, value, description) values
  ('default_timezone',                    '"Asia/Jakarta"'::jsonb, 'Zona waktu default (BR-011); kalender dapat menimpa'),
  ('sla.clock_starts_at',                 '"WO_CREATED"'::jsonb,   'WO_CREATED | REQUEST_RECEIVED (SP-01, OQ-11)'),
  ('notification.default_channels',       '["IN_APP","EMAIL"]'::jsonb, 'Kanal default (AS-10); WHATSAPP/PUSH setelah keputusan'),
  ('stock.allow_unsourced_usage',         'false'::jsonb,          'BR-035/OQ-17: izinkan pemakaian tanpa stok teknisi (UNSOURCED_USAGE)'),
  ('registration.mode',                   null, 'SELF | INVITE | BOTH (Q1/D1). NULL = registrasi mandiri mati'),
  ('rate_limit.service_request.max',      null, 'BR-072: maks permintaan per jendela per pelanggan'),
  ('rate_limit.service_request.window_seconds', null, 'BR-072: panjang jendela (detik)'),
  ('duplicate.window_minutes',            null, 'BR-071: jendela deteksi pesanan ganda'),
  ('approval.expiry_hours',               null, 'BR-055: kedaluwarsa persetujuan biaya tambahan'),
  ('signoff.expiry_hours',                null, 'T-17/T-18: kedaluwarsa tanda tangan via PWA'),
  ('extra_cost.tolerance_amount',         null, 'BR-050: toleransi nominal (NULL = 0)'),
  ('closure.min_note_length',             null, 'BR-040(7): panjang minimal temuan/tindakan (NULL = 1)'),
  ('en_route.tolerance_days',             null, 'T-07: toleransi hari jadwal (NULL = tidak diperiksa)'),
  ('pm.grace_days',                       null, 'BR-024: toleransi PM (NULL = 0)'),
  ('pm.default_priority_code',            null, 'Prioritas WO PM bila jenis layanan tak punya default'),
  ('rework.claim_window_days',            null, 'T-25: jendela klaim komplain/rework (NULL = tanpa batas)'),
  ('reject.escalation_threshold',         null, 'T-04: eskalasi setelah N penolakan'),
  ('return.escalation_threshold',         null, 'T-20: eskalasi setelah N pengembalian'),
  ('parts.return_deadline_hours',         null, 'BR-032: batas waktu retur sebelum selisih final (NULL = final saat WO selesai)'),
  ('stock.adjustment_supervisor_threshold', null, 'FR-127: ambang penyesuaian stok yang butuh Supervisor'),
  ('retention.notifications_days',        null, 'NFR-S6 (OQ-21)'),
  ('retention.sync_operations_days',      null, 'NFR-S6 (OQ-21)'),
  ('retention.job_runs_days',             null, 'NFR-S6'),
  ('retention.photos_days',               null, 'NFR-S6/NFR-D5: ditegakkan oleh worker Storage (TODO)'),
  ('retention.personal_data_days',        null, 'NFR-D5: anonimisasi (TODO)')
on conflict (key) do nothing;

insert into public.wo_transitions (code, action, from_status, to_status, allowed_roles, allow_system, requires_reason, description) values
  ('T-02',  'ASSIGN',  'NEW', 'ASSIGNED', '{DISPATCHER}', false, false, 'Dispatcher menugaskan teknisi + jadwal final'),
  ('T-03',  'ACCEPT',  'ASSIGNED', 'ACCEPTED', '{TECHNICIAN}', false, false, 'Teknisi menerima'),
  ('T-04',  'REJECT',  'ASSIGNED', 'NEW', '{TECHNICIAN}', false, true, 'Teknisi menolak (alasan wajib)'),
  ('T-05a', 'REASSIGN','ASSIGNED', 'ASSIGNED', '{DISPATCHER}', false, true, 'Tugas ulang'),
  ('T-05b', 'REASSIGN','ACCEPTED', 'ASSIGNED', '{DISPATCHER}', false, true, 'Tugas ulang'),
  ('T-06',  'RELEASE', 'ACCEPTED', 'NEW', '{TECHNICIAN,DISPATCHER}', false, true, 'Lepas tugas sebelum check-in'),
  ('T-07',  'DEPART',  'ACCEPTED', 'EN_ROUTE', '{TECHNICIAN}', false, false, 'Berangkat'),
  ('T-08a', 'CHECK_IN','ACCEPTED', 'IN_PROGRESS', '{TECHNICIAN}', false, false, 'Check-in tanpa berangkat'),
  ('T-08b', 'CHECK_IN','EN_ROUTE', 'IN_PROGRESS', '{TECHNICIAN}', false, false, 'Check-in'),
  ('T-09',  'HOLD_PARTS','IN_PROGRESS', 'ON_HOLD_PARTS', '{TECHNICIAN}', false, false, 'Menunggu suku cadang'),
  ('T-10',  'RESUME_PARTS','ON_HOLD_PARTS', 'IN_PROGRESS', '{TECHNICIAN,DISPATCHER}', false, false, 'Suku cadang tiba/dibatalkan'),
  ('T-11',  'REQUEST_EXTRA_COST','IN_PROGRESS', 'AWAITING_CUSTOMER_APPROVAL', '{TECHNICIAN}', false, false, 'Ajukan biaya tambahan'),
  ('T-12',  'APPROVE_EXTRA_COST','AWAITING_CUSTOMER_APPROVAL', 'IN_PROGRESS', '{CUSTOMER,ADMIN_CS}', false, false, 'Pelanggan menyetujui'),
  ('T-13',  'REJECT_EXTRA_COST','AWAITING_CUSTOMER_APPROVAL', 'IN_PROGRESS', '{CUSTOMER,ADMIN_CS}', false, false, 'Menolak, lanjut lingkup awal'),
  ('T-14',  'CLOSE_AFTER_REJECTION','AWAITING_CUSTOMER_APPROVAL', 'UNDER_REVIEW', '{TECHNICIAN}', false, true, 'Tutup tidak tuntas setelah penolakan'),
  ('T-15',  'EXPIRE_EXTRA_COST','AWAITING_CUSTOMER_APPROVAL', 'IN_PROGRESS', '{}', true, false, 'Kedaluwarsa (sistem)'),
  ('T-16',  'SUBMIT_REVIEW','IN_PROGRESS', 'UNDER_REVIEW', '{TECHNICIAN}', false, false, 'Teknisi menutup (BR-040)'),
  ('T-17',  'REQUEST_SIGNOFF','IN_PROGRESS', 'AWAITING_SIGNOFF', '{TECHNICIAN}', false, false, 'Minta tanda tangan lewat PWA'),
  ('T-18',  'SIGNOFF', 'AWAITING_SIGNOFF', 'UNDER_REVIEW', '{CUSTOMER}', false, false, 'Pelanggan menandatangani'),
  ('T-18s', 'EXPIRE_SIGNOFF','AWAITING_SIGNOFF', 'UNDER_REVIEW', '{}', true, false, 'Kedaluwarsa jadi pengecualian (sistem)'),
  ('T-19',  'APPROVE_CLOSE','UNDER_REVIEW', 'CLOSED', '{SUPERVISOR}', false, false, 'Supervisor menyetujui'),
  ('T-20',  'RETURN',  'UNDER_REVIEW', 'RETURNED', '{SUPERVISOR}', false, true, 'Supervisor mengembalikan'),
  ('T-21',  'RESUME_AFTER_RETURN','RETURNED', 'IN_PROGRESS', '{TECHNICIAN}', false, false, 'Teknisi mengerjakan catatan'),
  ('T-22a', 'CANCEL',  'NEW', 'CANCELLED', '{ADMIN_CS,DISPATCHER}', true, true, 'Batal'),
  ('T-22b', 'CANCEL',  'ASSIGNED', 'CANCELLED', '{ADMIN_CS,DISPATCHER}', true, true, 'Batal'),
  ('T-22c', 'CANCEL',  'ACCEPTED', 'CANCELLED', '{ADMIN_CS,DISPATCHER}', true, true, 'Batal'),
  ('T-22d', 'CANCEL',  'EN_ROUTE', 'CANCELLED', '{ADMIN_CS,DISPATCHER}', true, true, 'Batal'),
  ('T-22e', 'CANCEL_BY_CUSTOMER','NEW', 'CANCELLED', '{CUSTOMER}', false, true, 'Pelanggan batal sebelum penugasan'),
  ('T-23a', 'CANCEL_ACTIVE','IN_PROGRESS', 'CANCELLED', '{SUPERVISOR}', false, true, 'Batal saat berjalan'),
  ('T-23b', 'CANCEL_ACTIVE','ON_HOLD_PARTS', 'CANCELLED', '{SUPERVISOR}', false, true, 'Batal saat berjalan'),
  ('T-23c', 'CANCEL_ACTIVE','AWAITING_CUSTOMER_APPROVAL', 'CANCELLED', '{SUPERVISOR}', false, true, 'Batal saat berjalan'),
  ('T-23d', 'CANCEL_ACTIVE','AWAITING_SIGNOFF', 'CANCELLED', '{SUPERVISOR}', false, true, 'Batal saat berjalan'),
  ('T-27a', 'VISIT_FAILED','EN_ROUTE', 'NEW', '{TECHNICIAN}', false, true, 'Kunjungan gagal'),
  ('T-27b', 'VISIT_FAILED','IN_PROGRESS', 'NEW', '{TECHNICIAN}', false, true, 'Kunjungan gagal')
on conflict (code) do nothing;
