import Link from "next/link";
import { APP_NAME } from "@/lib/constants";

export function SiteHeader() {
  return (
    <header className="border-b border-border">
      <div className="mx-auto flex h-14 max-w-5xl items-center px-6">
        <Link href="/" className="font-semibold tracking-tight">
          <span className="text-accent-light">●</span> {APP_NAME}
        </Link>
      </div>
    </header>
  );
}
