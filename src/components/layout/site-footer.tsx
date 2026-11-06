import { APP_NAME } from "@/lib/constants";

export function SiteFooter() {
  return (
    <footer className="border-t border-border">
      <div className="mx-auto max-w-5xl px-6 py-6 text-sm text-muted">
        © {new Date().getFullYear()} {APP_NAME}
      </div>
    </footer>
  );
}
