import type { ReactNode } from "react";
import "../styles/tokens.css";
import "../components/ui/ui.css";
import { DemoBanner } from "../components/ui";

export const metadata = { title: "VASTA", description: "Field Service & Work Order Management" };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="id">
      <body>
        <DemoBanner />
        {children}
      </body>
    </html>
  );
}
