export default function HomePage() {
  const env = process.env.NEXT_PUBLIC_APP_ENV ?? "demo";
  return (
    <main>
      <h1>VASTA</h1>
      <p>Lingkungan: {env}. Data di lingkungan ini hanya data fiktif.</p>
    </main>
  );
}
