import { defineConfig } from "vitest/config";

// Uji isolasi memanggil Supabase nyata; dipisah dari `npm test` agar CI dasar tidak butuh rahasia.
export default defineConfig({
  test: {
    include: ["tests/isolation/**/*.test.ts"],
    testTimeout: 60_000,
    hookTimeout: 120_000,
    fileParallelism: false,
  },
});
