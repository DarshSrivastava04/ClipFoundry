import "server-only";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { getPublicSupabaseConfig } from "@/lib/env";

/**
 * Service-role client. SERVER ONLY: bypasses Row Level Security.
 * Reserved for trusted server-side operations (e.g. financial calculations).
 * The `server-only` import makes the build fail if this is pulled into client code.
 */
export function createAdminClient() {
  const config = getPublicSupabaseConfig();
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!config || !serviceRoleKey) {
    throw new Error("Supabase admin credentials are not configured. See .env.example.");
  }
  return createSupabaseClient(config.url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
