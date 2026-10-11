import type { ButtonHTMLAttributes } from "react";

type Props = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "secondary" | "danger";
  block?: boolean;
  loading?: boolean;
};

export function Button({
  variant = "primary",
  block = false,
  loading = false,
  disabled,
  className,
  children,
  type = "button",
  ...rest
}: Props) {
  const classes = ["ui-btn", `ui-btn--${variant}`, block ? "ui-btn--block" : "", className ?? ""]
    .filter(Boolean)
    .join(" ");
  return (
    <button
      type={type}
      className={classes}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      {...rest}
    >
      {loading ? "Memproses..." : children}
    </button>
  );
}
