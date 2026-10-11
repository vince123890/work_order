/** Penanda lingkungan non-produksi (RK-16). Tampil kecuali NEXT_PUBLIC_APP_ENV=production. */
export function DemoBanner() {
  const env = process.env.NEXT_PUBLIC_APP_ENV ?? "demo";
  if (env === "production") return null;
  return (
    <div className="ui-demo-banner" role="note">
      {env === "staging" ? "STAGING" : "DEMO"}: data di lingkungan ini hanya data fiktif
    </div>
  );
}
