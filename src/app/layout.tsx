import type { ReactNode } from "react";

export const metadata = { title: "VASTA", description: "Field Service & Work Order Management" };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="id">
      <body>{children}</body>
    </html>
  );
}
