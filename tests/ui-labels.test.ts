import { describe, expect, it } from "vitest";
import {
  CUSTOMER_STATUS_LABEL,
  CUSTOMER_STATUS_TONE,
  SYNC_STATE_LABEL,
  SYNC_STATE_TONE,
} from "../src/components/ui/labels";

describe("label status UI", () => {
  it("memuat enam status pelanggan ditambah dua di luar enam", () => {
    expect(Object.keys(CUSTOMER_STATUS_LABEL)).toHaveLength(8);
  });

  it("tidak membocorkan nama status internal ke teks pelanggan", () => {
    const internal = /ASSIGNED|ACCEPTED|EN_ROUTE|IN_PROGRESS|ON_HOLD|UNDER_REVIEW|RETURNED|CLOSED/;
    for (const text of Object.values(CUSTOMER_STATUS_LABEL)) {
      expect(text).not.toMatch(internal);
    }
  });

  it("setiap status dan keadaan sinkron punya nada warna", () => {
    for (const key of Object.keys(CUSTOMER_STATUS_LABEL)) {
      expect(CUSTOMER_STATUS_TONE[key as keyof typeof CUSTOMER_STATUS_TONE]).toBeDefined();
    }
    for (const key of Object.keys(SYNC_STATE_LABEL)) {
      expect(SYNC_STATE_TONE[key as keyof typeof SYNC_STATE_TONE]).toBeDefined();
    }
  });

  it("empat keadaan sinkron sesuai FR-060", () => {
    expect(Object.values(SYNC_STATE_LABEL)).toEqual([
      "Belum terkirim",
      "Mengirim...",
      "Terkirim",
      "Gagal, akan dicoba lagi",
    ]);
  });
});
