// Teks UI Indonesia untuk status. Sumber: design/L1/04_teks_ui_id.md dan 02 bagian 4.2, FR-060.

export type CustomerStatus =
  | "received"
  | "scheduled"
  | "en_route"
  | "in_progress"
  | "awaiting_you"
  | "done"
  | "cancelled"
  | "rejected";

export const CUSTOMER_STATUS_LABEL: Record<CustomerStatus, string> = {
  received: "Diterima",
  scheduled: "Dijadwalkan",
  en_route: "Teknisi menuju lokasi",
  in_progress: "Sedang dikerjakan",
  awaiting_you: "Menunggu persetujuan Anda",
  done: "Selesai",
  cancelled: "Dibatalkan",
  rejected: "Tidak dapat diproses",
};

export type SyncState = "pending" | "sending" | "synced" | "failed";

export const SYNC_STATE_LABEL: Record<SyncState, string> = {
  pending: "Belum terkirim",
  sending: "Mengirim...",
  synced: "Terkirim",
  failed: "Gagal, akan dicoba lagi",
};

export type Tone = "neutral" | "info" | "success" | "warning" | "danger";

export const CUSTOMER_STATUS_TONE: Record<CustomerStatus, Tone> = {
  received: "neutral",
  scheduled: "info",
  en_route: "info",
  in_progress: "info",
  awaiting_you: "warning",
  done: "success",
  cancelled: "neutral",
  rejected: "danger",
};

export const SYNC_STATE_TONE: Record<SyncState, Tone> = {
  pending: "warning",
  sending: "info",
  synced: "success",
  failed: "danger",
};

// Ikon teks sederhana agar status tidak bergantung pada warna saja.
export const TONE_ICON: Record<Tone, string> = {
  neutral: "•",
  info: "ℹ",
  success: "✓",
  warning: "!",
  danger: "✕",
};
