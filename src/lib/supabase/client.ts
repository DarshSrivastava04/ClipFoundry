import { createBrowserClient } from "@supabase/ssr";
import { getPublicSupabaseConfig } from "@/lib/env";

/** Browser Supabase client (anon key only; protected by Row Level Security). */
export function createClient() {
  const config = getPublicSupabaseConfig();
  if (!config) {
    throw new Error("Supabase is not configured. See .env.example.");
  }
  return createBrowserClient(config.url, config.anonKey);
}
