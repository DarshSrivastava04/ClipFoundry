import { APP_NAME } from "@/lib/constants";

const roles = [
  {
    title: "For creators",
    body: "Fund clipping campaigns, set reward rates and requirements, and review editor submissions.",
  },
  {
    title: "For editors",
    body: "Join campaigns for free, publish short-form clips, and earn from verified eligible views.",
  },
];

export default function HomePage() {
  return (
    <section className="mx-auto max-w-5xl px-6 py-24">
      <p className="text-sm font-medium uppercase tracking-widest text-accent-light">
        Early development
      </p>
      <h1 className="mt-4 text-4xl font-semibold tracking-tight sm:text-5xl">{APP_NAME}</h1>
      <p className="mt-4 max-w-2xl text-lg text-muted">
        A marketplace connecting long-form creators with short-form video editors. Accounts,
        campaigns and payouts are not available yet.
      </p>
      <div className="mt-12 grid gap-4 sm:grid-cols-2">
        {roles.map((r) => (
          <div key={r.title} className="rounded-xl border border-border bg-card p-6">
            <h2 className="font-medium">{r.title}</h2>
            <p className="mt-2 text-sm text-muted">{r.body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
