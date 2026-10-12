// Katalog ekspektasi uji isolasi (WP-007): relasi yang BOLEH dibaca pelanggan beserta kolom pemiliknya,
// allow-list kolom view, dan klasifikasi RPC. Semua selain ALLOWED_TABLES wajib 0 baris bagi pelanggan.

export type Own =
  | { kind: "cust"; col: string } // nilai kolom = customer_id milik pemanggil
  | { kind: "user"; col: string } // nilai kolom = id user pemanggil
  | { kind: "via"; col: string; from: string; fromCol: string } // nilai harus ada di relasi lain yang sudah tersaring
  | { kind: "wo"; col: string } // wo_id harus salah satu WO pada customer_work_orders
  | { kind: "katalog" }; // katalog umum (tanpa pemilik)

export const ALLOWED_TABLES: Record<string, { own: Own; expectRows: boolean }> = {
  customers: { own: { kind: "cust", col: "id" }, expectRows: true },
  customer_users: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  customer_sites: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  assets: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  contracts: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  contract_assets: {
    own: { kind: "via", col: "contract_id", from: "contracts", fromCol: "id" },
    expectRows: false,
  },
  pm_periods: {
    own: { kind: "via", col: "contract_asset_id", from: "contract_assets", fromCol: "id" },
    expectRows: false,
  },
  service_requests: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  request_attachments: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  ratings: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  complaints: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  invoices: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  invoice_lines: {
    own: { kind: "via", col: "invoice_id", from: "invoices", fromCol: "id" },
    expectRows: true,
  },
  payments: {
    own: { kind: "via", col: "invoice_id", from: "invoices", fromCol: "id" },
    expectRows: true,
  },
  notifications: { own: { kind: "user", col: "user_id" }, expectRows: true },
  notification_prefs: { own: { kind: "user", col: "user_id" }, expectRows: false },
  profiles: { own: { kind: "user", col: "user_id" }, expectRows: true },
  user_roles: { own: { kind: "user", col: "user_id" }, expectRows: true },
  user_consents: { own: { kind: "user", col: "user_id" }, expectRows: true },
  sync_operations: { own: { kind: "user", col: "user_id" }, expectRows: true },
  service_types: { own: { kind: "katalog" }, expectRows: true },
  problem_types: { own: { kind: "katalog" }, expectRows: true },
  // view pelanggan
  customer_requests: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  customer_work_orders: { own: { kind: "cust", col: "customer_id" }, expectRows: true },
  customer_wo_timeline: { own: { kind: "wo", col: "wo_id" }, expectRows: true },
  customer_wo_photos: { own: { kind: "wo", col: "wo_id" }, expectRows: true },
  customer_service_reports: { own: { kind: "wo", col: "wo_id" }, expectRows: true },
  customer_extra_cost_approvals: { own: { kind: "wo", col: "wo_id" }, expectRows: true },
};

/** Relasi yang pasti harus tertutup bagi pelanggan (jaring pengaman: daftar turunan tak boleh menyusut). */
export const MUST_BE_FORBIDDEN = [
  "work_orders",
  "wo_assignments",
  "wo_visits",
  "wo_findings",
  "wo_checklist_items",
  "wo_attachments",
  "wo_signatures",
  "wo_labor_lines",
  "wo_part_usages",
  "wo_status_history",
  "extra_cost_approvals",
  "extra_cost_approval_items",
  "service_reports",
  "audit_logs",
  "access_logs",
  "stock_movements",
  "part_requests",
  "part_returns",
  "parts_variances",
  "technicians",
  "technician_skills",
  "sla_policies",
  "sla_events",
  "app_settings",
  "items",
  "service_items",
  "customer_invitations",
  "tech_wo_part_usages",
  "tech_wo_labor_lines",
  "tech_extra_cost_approvals",
  "v_items_catalog",
  "wo_child_changes",
  "tech_work_orders",
];

/** Tabel terlarang yang boleh kosong di DB uji (tidak ada data pembukti) beserta alasannya. */
export const KNOWN_EMPTY_FORBIDDEN: Record<string, string> = {
  business_calendars: "konfigurasi kalender belum diisi di seed",
  calendar_hours: "konfigurasi kalender belum diisi di seed",
  calendar_holidays: "konfigurasi kalender belum diisi di seed",
  escalation_rules: "konfigurasi SLA belum diisi di seed",
  sla_policies: "konfigurasi SLA belum diisi di seed",
  sla_policy_sets: "konfigurasi SLA belum diisi di seed",
  import_jobs: "fitur impor Lapis 3",
  customer_invitations: "undangan tidak dibuat fixture",
  part_return_lines: "fixture tidak membuat baris retur",
  rate_limits:
    "baris hanya muncul saat pemesanan lewat PWA; tidak dapat dibaca authenticated sama sekali",
};

export const CUSTOMER_VIEW_COLUMNS: Record<string, string[]> = {
  customer_requests: [
    "request_id",
    "request_no",
    "customer_id",
    "site_id",
    "asset_id",
    "problem_type_id",
    "description",
    "preferred_start",
    "preferred_end",
    "channel",
    "requested_at",
    "client_request_id",
    "request_version",
    "possible_duplicate",
    "wo_id",
    "wo_number",
    "display_status",
    "needs_info",
    "status_note",
  ],
  customer_work_orders: [
    "wo_id",
    "wo_number",
    "wo_type",
    "customer_id",
    "site_id",
    "asset_id",
    "request_id",
    "display_status",
    "status_note",
    "awaiting_customer_action",
    "awaiting_signoff",
    "pending_approval_id",
    "scheduled_start",
    "scheduled_end",
    "technician_name",
    "requested_at",
    "closed_at",
    "cancel_requested_at",
    "wo_version",
    "rated",
  ],
  customer_wo_timeline: ["wo_id", "at", "display_status", "customer_note"],
  customer_extra_cost_approvals: [
    "approval_id",
    "wo_id",
    "version_no",
    "status",
    "total",
    "reason",
    "requested_at",
    "expires_at",
    "content_hash",
    "items",
  ],
  customer_wo_photos: ["attachment_id", "wo_id", "kind", "storage_path", "taken_at"],
  customer_service_reports: [
    "report_id",
    "wo_id",
    "revision",
    "storage_path",
    "generated_at",
    "sent_at",
  ],
};

export const TECH_WORK_ORDERS_COLUMNS = [
  "id",
  "wo_number",
  "type",
  "customer_id",
  "site_id",
  "asset_id",
  "service_type_id",
  "request_id",
  "contract_id",
  "contract_asset_id",
  "pm_period_key",
  "parent_wo_id",
  "priority_code",
  "status",
  "scheduled_start",
  "scheduled_end",
  "requested_at",
  "sla_clock_start_at",
  "sla_policy_set_id",
  "sla_calendar_id",
  "policy_snapshot",
  "response_due_at",
  "resolution_due_at",
  "response_met_at",
  "resolution_met_at",
  "response_sla_state",
  "resolution_sla_state",
  "sla_paused_at",
  "next_sla_check_at",
  "pm_due_date",
  "started_at",
  "submitted_at",
  "closed_at",
  "cancelled_at",
  "cancel_reason_code",
  "cancel_reason",
  "cancel_requested_at",
  "cancel_requested_by",
  "cancel_request_note",
  "signoff_expires_at",
  "closure_exception",
  "closure_exception_code",
  "closure_exception_note",
  "closure_exception_approved_by",
  "closure_exception_approved_at",
  "outcome",
  "no_parts_used",
  "checklist_template_id",
  "checklist_template_version",
  "returned_count",
  "rejection_count",
  "failed_visit_count",
  "help_requested_at",
  "help_requested_by",
  "help_note",
  "customer_note",
  "created_by",
  "created_at",
  "updated_at",
  "version",
  "children_changed_at",
];

/** Kolom harga/penagihan yang TIDAK boleh ada di tech_work_orders (G-08). */
export const WO_PRICE_BILLING_COLUMNS = [
  "estimate_total",
  "estimate_version",
  "billing_type",
  "billing_status",
  "billing_override_reason",
  "warranty_exception_reason",
];

/** View teknisi/gudang (tanpa harga/margin, AP-2). */
export const TECH_VIEW_COLUMNS: Record<string, string[]> = {
  tech_work_orders: TECH_WORK_ORDERS_COLUMNS,
  tech_wo_part_usages: [
    "id",
    "wo_id",
    "item_id",
    "qty",
    "is_extra",
    "extra_approval_id",
    "emergency",
    "unsourced",
    "op_id",
    "deleted_at",
    "created_at",
  ],
  tech_wo_labor_lines: [
    "id",
    "wo_id",
    "service_item_id",
    "description",
    "qty",
    "is_extra",
    "extra_approval_id",
    "emergency",
    "op_id",
    "deleted_at",
    "created_at",
  ],
  tech_extra_cost_approvals: [
    "approval_id",
    "wo_id",
    "version_no",
    "status",
    "reason",
    "requested_at",
    "expires_at",
    "decided_at",
    "continue_original_scope",
  ],
  v_items_catalog: ["id", "sku", "name", "uom", "is_serialized", "tracking_mode", "is_active"],
  v_tech_asset_service_history: [
    "asset_id",
    "wo_id",
    "wo_number",
    "wo_type",
    "closed_at",
    "diagnosis",
    "action_taken",
  ],
};

export const PRICE_COLUMNS = [
  "unit_price",
  "unit_cost",
  "unit_price_snapshot",
  "unit_cost_snapshot",
  "billable",
  "subtotal",
  "total",
  "estimate_total",
  "amount",
];

/**
 * RPC yang SAH dipanggil peran tertentu (tidak boleh diuji dengan ekspektasi "ditolak" oleh peran itu).
 * Alasannya dicatat; semua RPC lain wajib menolak pelanggan dan teknisi (WO002/WO005/42501).
 */
export const RPC_ALLOWED: Record<string, { roles: ("CUSTOMER" | "TECHNICIAN")[]; reason: string }> =
  {
    wo_transition: {
      roles: ["CUSTOMER", "TECHNICIAN"],
      reason: "pintu status WO; aksi dibatasi tabel wo_transitions, diuji terpisah per aksi",
    },
    extra_cost_decide: {
      roles: ["CUSTOMER"],
      reason: "pelanggan menyetujui biaya tambahan; lintas pelanggan diuji terpisah (WO005)",
    },
    wo_customer_sign: {
      roles: ["CUSTOMER"],
      reason: "pelanggan menandatangani; lintas pelanggan diuji terpisah",
    },
    wo_request_cancel: {
      roles: ["CUSTOMER"],
      reason: "pelanggan mengajukan batal; lintas pelanggan diuji terpisah",
    },
    extra_cost_request: {
      roles: ["TECHNICIAN"],
      reason: "teknisi mengajukan biaya tambahan pada WO ACCEPTED miliknya",
    },
    wo_request_help: { roles: ["TECHNICIAN"], reason: "teknisi meminta bantuan pada WO miliknya" },
    wo_cost_summary: {
      roles: ["TECHNICIAN"],
      reason:
        "teknisi pemegang WO hanya menerima {needs_approval} (S1 ditutup 0016); pelanggan wajib ditolak",
    },
    part_request_create: {
      roles: ["TECHNICIAN"],
      reason: "teknisi membuat permintaan suku cadang untuk WO miliknya",
    },
    part_return_create: {
      roles: ["TECHNICIAN"],
      reason: "teknisi membuat retur untuk WO miliknya",
    },
    wo_declare_no_parts: {
      roles: ["TECHNICIAN"],
      reason:
        "teknisi LEAD menyatakan tanpa suku cadang pada WO miliknya (G-13); helper WO002, bukan pemegang WO005",
    },
    wo_closure_check: {
      roles: ["TECHNICIAN"],
      reason: "pratinjau kekurangan penutupan untuk teknisi pemegang WO dan staf (G-12)",
    },
    sync_op_record: {
      roles: ["TECHNICIAN"],
      reason: "pemilik baris sync_operations (teknisi) mencatat status operasinya sendiri (G-06)",
    },
    sync_rescued_resolve: {
      roles: [],
      reason: "hanya staf (ADM, DSP, SPV, OWN); pelanggan dan teknisi wajib WO002 (G-06)",
    },
    log_data_access: {
      roles: ["TECHNICIAN"],
      reason: "pencatatan akses oleh staf termasuk teknisi",
    },
    register_individual_customer: {
      roles: ["CUSTOMER", "TECHNICIAN"],
      reason:
        "RPC swalayan akun baru; mengubah data bila mode registrasi aktif, tidak dipanggil dummy",
    },
    accept_customer_invitation: {
      roles: ["CUSTOMER", "TECHNICIAN"],
      reason: "RPC swalayan penerimaan undangan; tidak dipanggil dummy",
    },
  };

/** Fungsi schema app yang sah diberi EXECUTE ke authenticated (0013). */
export const APP_FUNCTIONS_FOR_AUTHENTICATED = [
  "can_edit_wo",
  "can_read_object",
  "customer_owns_wo",
  "customer_status",
  "has_any_role",
  "my_active_wo_ids",
  "my_customer_ids",
  "my_editable_wo_ids",
  "my_location_ids",
  "my_roles",
  "my_technician_id",
  "tech_asset_ids",
  "tech_customer_ids",
  "tech_request_ids",
  "tech_site_ids",
  "wo_storage_prefix",
];

/**
 * Peran staf yang SAH untuk RPC yang tidak diperuntukkan pelanggan/teknisi. Dipakai sebagai kontrol positif:
 * dengan argumen dummy sah-tipe, peran ini harus MELEWATI penjagaan peran (kode bukan WO002/42501).
 */
export const RPC_LEGIT_STAFF: Record<string, string> = {
  request_decide: "admin",
  wo_add_helper: "dispatcher",
  wo_change_priority: "admin",
  wo_override_billing: "spv",
  wo_create_rework: "admin",
  wo_set_estimate: "admin",
  pm_period_resolve: "admin",
  part_request_decide: "gudang",
  part_issue: "gudang",
  part_return_confirm: "gudang",
  stock_receive: "gudang",
  stock_adjust: "gudang",
  parts_variance_resolve: "spv",
  admin_set_user_roles: "owner",
  admin_set_user_active: "admin",
  sync_rescued_resolve: "admin",
};

/**
 * Pengecualian: RPC yang berlingkup-WO/operasi menurut desain dan menjawab WO005 (404 seragam) kepada peran bukan-pemegang
 * SEBELUM penjagaan peran. Semua RPC lain WAJIB menjawab tepat WO002 kepada peran ini.
 */
export const RPC_DENY_WO005: Record<"CUSTOMER" | "TECHNICIAN", string[]> = {
  CUSTOMER: [
    "wo_cost_summary",
    "wo_closure_check",
    "wo_declare_no_parts",
    "extra_cost_request",
    "part_request_create",
    "part_return_create",
    "wo_request_help",
    "sync_op_record",
  ],
  TECHNICIAN: ["extra_cost_decide", "wo_customer_sign", "wo_request_cancel"],
};
