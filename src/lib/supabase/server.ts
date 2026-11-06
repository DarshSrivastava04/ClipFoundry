import "server-only";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { getPublicSupabaseConfig } from "@/lib/env";

/** Server Supabase client bound to the current user's session cookies (anon key + RLS). */
export async function createClient() {
  const config = getPublicSupabaseConfig();
  if (!config) {
    throw new Error("Supabase is not configured. See .env.example.");
  }
  const cookieStore = await cookies();
  return createServerClient(config.url, config.anonKey, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) =>
            cookieStore.set(name, value, options),
          );
        } catch {
          // Called from a Server Component; session refresh is handled elsewhere.
        }
      },
    },
  });
}
