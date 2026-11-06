# ClipFoundry (working name)

A marketplace connecting long-form creators with short-form video editors. Initial currency: INR (₹).

> **Status:** Phase 1 – project foundation only. No authentication, database schema, campaigns,
> view verification or payments exist yet.

## Stack

Next.js 15 (App Router) · React 19 · TypeScript · Tailwind CSS 3 · Supabase (Auth, Postgres, Storage) · Vercel

## Setup

Requires Node.js 20+ (developed on 24) and npm.

```bash
npm install
cp .env.example .env.local   # Windows: copy .env.example .env.local
npm run dev                  # http://localhost:3000
```

The app runs without Supabase credentials. Fill in `.env.local` once a Supabase project exists.

> On Windows PowerShell, if `npm` is blocked by execution policy, use `npm.cmd`.

## Commands

| Command             | Purpose                  |
| ------------------- | ------------------------ |
| `npm run dev`       | Start dev server         |
| `npm run build`     | Production build         |
| `npm run start`     | Serve production build   |
| `npm run typecheck` | TypeScript check         |
| `npm run lint`      | ESLint                   |

## Environment variables

See [.env.example](.env.example).

| Variable                        | Exposure    | Notes                                         |
| ------------------------------- | ----------- | --------------------------------------------- |
| `NEXT_PUBLIC_SUPABASE_URL`      | Browser     | Supabase project URL                          |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Browser     | Protected by Row Level Security               |
| `SUPABASE_SERVICE_ROLE_KEY`     | Server only | Bypasses RLS. Never expose or prefix `NEXT_PUBLIC_` |

Never commit `.env.local`. On Vercel, set these in Project Settings → Environment Variables.

## Structure

```
src/
  app/                 Routes, layout, global styles
  components/layout/   Shell components (header, footer)
  lib/
    constants.ts       App name, currency
    env.ts             Safe env access
    supabase/          client.ts (browser), server.ts (SSR), admin.ts (service role, server-only)
supabase/              Future SQL migrations
```

## Security principles

- `src/lib/supabase/admin.ts` and `server.ts` import `server-only`, so bundling them into client code fails the build.
- All financial calculations must run on the server (or in the database); the client is never trusted.
