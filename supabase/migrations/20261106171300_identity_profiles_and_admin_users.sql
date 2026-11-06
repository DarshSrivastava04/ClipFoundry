-- ============================================================================
-- ClipFoundry — Phase 2.2 Foundational Migration 1
-- Scope: Extensions, profile_status enum, profiles, admin_users,
--        role/admin mutual-exclusion & race-condition protections,
--        auth.users signup trigger, RLS helper functions, and own_profile view.
-- Source of truth: database_architecture.md (Revision 3)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Required extensions and custom types
-- ----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA extensions;

CREATE TYPE public.profile_status AS ENUM (
  'active',
  'suspended',
  'deleted'
);

-- ----------------------------------------------------------------------------
-- 2. Shared utility trigger functions (timestamps & deletion prevention)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.set_updated_at() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.prevent_row_deletion()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'Deletion is prohibited on %.% — records must be retained for audit integrity.',
    TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END;
$$;

REVOKE ALL ON FUNCTION public.prevent_row_deletion() FROM PUBLIC, anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. Identity tables: profiles and admin_users (§2.1)
-- ----------------------------------------------------------------------------

CREATE TABLE public.profiles (
  id uuid NOT NULL,
  username extensions.citext NOT NULL,
  display_name text NOT NULL,
  avatar_path text NULL,
  bio text NULL,
  is_creator boolean NOT NULL DEFAULT false,
  is_editor boolean NOT NULL DEFAULT false,
  account_scope text NOT NULL DEFAULT 'member',
  status public.profile_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT profiles_pkey
    PRIMARY KEY (id),
  CONSTRAINT profiles_id_fkey
    FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE RESTRICT,
  CONSTRAINT profiles_username_key
    UNIQUE (username),
  CONSTRAINT profiles_id_account_scope_key
    UNIQUE (id, account_scope),
  CONSTRAINT profiles_username_format_chk
    CHECK (username::text ~ '^[a-z0-9_]{3,30}$'),
  CONSTRAINT profiles_display_name_len_chk
    CHECK (char_length(btrim(display_name)) >= 1 AND char_length(display_name) <= 60),
  CONSTRAINT profiles_avatar_path_nonblank_chk
    CHECK (avatar_path IS NULL OR char_length(btrim(avatar_path)) >= 1),
  CONSTRAINT profiles_bio_len_chk
    CHECK (bio IS NULL OR char_length(bio) <= 500),
  CONSTRAINT profiles_account_scope_chk
    CHECK (account_scope IN ('member', 'admin')),
  CONSTRAINT profiles_admin_role_exclusion_chk
    CHECK (account_scope = 'member' OR (NOT is_creator AND NOT is_editor))
);

CREATE INDEX profiles_status_idx ON public.profiles (status);

CREATE TABLE public.admin_users (
  user_id uuid NOT NULL,
  account_scope text NOT NULL DEFAULT 'admin',
  granted_by uuid NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT admin_users_pkey
    PRIMARY KEY (user_id),
  CONSTRAINT admin_users_user_scope_fkey
    FOREIGN KEY (user_id, account_scope)
    REFERENCES public.profiles(id, account_scope)
    ON DELETE RESTRICT
    ON UPDATE RESTRICT,
  CONSTRAINT admin_users_granted_by_fkey
    FOREIGN KEY (granted_by)
    REFERENCES public.profiles(id)
    ON DELETE RESTRICT,
  CONSTRAINT admin_users_account_scope_chk
    CHECK (account_scope = 'admin'),
  CONSTRAINT admin_users_no_self_grant_chk
    CHECK (granted_by <> user_id),
  CONSTRAINT admin_users_revoked_after_granted_chk
    CHECK (revoked_at IS NULL OR revoked_at >= granted_at)
);

-- At most one bootstrap admin row may have granted_by IS NULL (§2.1).
CREATE UNIQUE INDEX admin_users_single_bootstrap_idx
  ON public.admin_users ((true))
  WHERE granted_by IS NULL;

CREATE INDEX admin_users_granted_by_idx
  ON public.admin_users (granted_by)
  WHERE granted_by IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 4. Role activation & admin-grant race-condition protections (§2.1, §4)
-- ----------------------------------------------------------------------------

-- 4a. SECURITY INVOKER guard: inspects actual invoking SQL role (current_user)
--     to enforce client immutability and false -> true flag monotonicity.
CREATE OR REPLACE FUNCTION public.enforce_profiles_caller_rules()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF current_user IN ('anon', 'authenticated') THEN
      RAISE EXCEPTION 'Direct profile insertion by client roles is prohibited.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'profiles.id is immutable.'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'profiles.created_at is immutable.'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- username is immutable in v1; only privileged profile anonymisation on deletion may alter it.
  IF NEW.username::text IS DISTINCT FROM OLD.username::text THEN
    IF current_user IN ('anon', 'authenticated') OR NEW.status <> 'deleted' THEN
      RAISE EXCEPTION 'profiles.username is immutable.'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
  END IF;

  IF current_user IN ('anon', 'authenticated') THEN
    IF OLD.status <> 'active' OR NEW.status <> 'active' THEN
      RAISE EXCEPTION 'Only active profiles may be modified by clients.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF OLD.account_scope <> 'member' OR NEW.account_scope <> 'member' THEN
      RAISE EXCEPTION 'account_scope cannot be modified or held as admin by client operations.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF OLD.is_creator AND NOT NEW.is_creator THEN
      RAISE EXCEPTION 'is_creator cannot be disabled once enabled.'
        USING ERRCODE = 'check_violation';
    END IF;

    IF OLD.is_editor AND NOT NEW.is_editor THEN
      RAISE EXCEPTION 'is_editor cannot be disabled once enabled.'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_profiles_caller_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4b. SECURITY DEFINER guard on profiles: checks admin_users (inaccessible to clients)
--     while PostgreSQL holds the row lock on profiles(id = NEW.id).
CREATE OR REPLACE FUNCTION public.enforce_profiles_admin_exclusion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.is_creator OR NEW.is_editor OR NEW.account_scope = 'member' THEN
    IF EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = NEW.id
    ) THEN
      RAISE EXCEPTION 'Accounts with an admin_users record cannot hold member scope or marketplace roles.'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF NEW.account_scope = 'admin' THEN
    IF NEW.is_creator OR NEW.is_editor THEN
      RAISE EXCEPTION 'Admin-scoped profiles must have is_creator = false and is_editor = false.'
        USING ERRCODE = 'check_violation';
    END IF;

    IF TG_OP = 'INSERT' AND NEW.status <> 'active' THEN
      RAISE EXCEPTION 'Admin-scoped profiles must be active upon creation.'
        USING ERRCODE = 'check_violation';
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.account_scope = 'member' THEN
      IF OLD.is_creator OR OLD.is_editor OR OLD.status <> 'active' OR NEW.status <> 'active' THEN
        RAISE EXCEPTION 'Only active profiles without creator or editor roles may transition to admin scope.'
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_profiles_admin_exclusion() FROM PUBLIC, anon, authenticated, service_role;

-- 4c. SECURITY DEFINER guard on admin_users: locks profiles FOR UPDATE first (§2.1, §4)
--     to serialize against concurrent role-flag updates under READ COMMITTED.
CREATE OR REPLACE FUNCTION public.enforce_admin_users_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_profile record;
  v_grantor_check integer;
BEGIN
  -- Acquire exclusive row lock on parent profile first to prevent write skew (§4).
  SELECT p.id, p.is_creator, p.is_editor, p.account_scope, p.status
    INTO v_profile
  FROM public.profiles p
  WHERE p.id = NEW.user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target profile % does not exist.', NEW.user_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_profile.account_scope <> 'admin' OR v_profile.is_creator OR v_profile.is_editor THEN
    RAISE EXCEPTION 'Admin user % must have account_scope = admin and no marketplace role flags.', NEW.user_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.revoked_at IS NULL AND v_profile.status <> 'active' THEN
    RAISE EXCEPTION 'Active admin user % must have an active profile.', NEW.user_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.granted_by IS NULL THEN
      -- Null granted_by is allowed strictly for the very first bootstrap admin (§2.1).
      IF EXISTS (SELECT 1 FROM public.admin_users) THEN
        RAISE EXCEPTION 'granted_by may be null only for the initial bootstrap admin.'
          USING ERRCODE = 'check_violation';
      END IF;
    ELSE
      IF NEW.granted_by = NEW.user_id THEN
        RAISE EXCEPTION 'Admin grant cannot be self-granted.'
          USING ERRCODE = 'check_violation';
      END IF;

      -- Lock grantor's active admin_users row first, then profiles row (admin_users -> profiles)
      -- to serialize against concurrent grantor revocation or suspension without deadlocking.
      SELECT 1
        INTO v_grantor_check
      FROM public.admin_users au
      WHERE au.user_id = NEW.granted_by
        AND au.revoked_at IS NULL
      FOR SHARE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'granted_by (%) must be an active admin.', NEW.granted_by
          USING ERRCODE = 'insufficient_privilege';
      END IF;

      SELECT 1
        INTO v_grantor_check
      FROM public.profiles gp
      WHERE gp.id = NEW.granted_by
        AND gp.account_scope = 'admin'
        AND NOT gp.is_creator
        AND NOT gp.is_editor
        AND gp.status = 'active'
      FOR SHARE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'granted_by (%) must be an active admin.', NEW.granted_by
          USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id
       OR NEW.account_scope IS DISTINCT FROM OLD.account_scope
       OR NEW.granted_by IS DISTINCT FROM OLD.granted_by
       OR NEW.granted_at IS DISTINCT FROM OLD.granted_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'admin_users grant identity and timestamps are immutable.'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
      RAISE EXCEPTION 'Revoked admin grants cannot be un-revoked or altered.'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_admin_users_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4d. Tier 3 atomic admin-grant function (§4, §5.2):
--     Locks profiles FOR UPDATE first, transitions account_scope -> 'admin',
--     and inserts admin_users in one transaction. (Audit log write added when audit_logs is created.)
CREATE OR REPLACE FUNCTION public.admin_grant_admin(
  p_user_id uuid,
  p_granted_by uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_profile record;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id is required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_granted_by IS NOT NULL AND p_granted_by = p_user_id THEN
    RAISE EXCEPTION 'Admin grant cannot be self-granted.'
      USING ERRCODE = 'check_violation';
  END IF;

  IF char_length(btrim(coalesce(p_reason, ''))) < 5 THEN
    RAISE EXCEPTION 'A reason of at least 5 characters is required to grant admin.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Step 1: Lock target profile row FOR UPDATE to serialize against Tier 1 role activation (§4).
  SELECT p.id, p.is_creator, p.is_editor, p.account_scope, p.status
    INTO v_profile
  FROM public.profiles p
  WHERE p.id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile % not found.', p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_profile.status <> 'active' THEN
    RAISE EXCEPTION 'Cannot grant admin to non-active profile %.', p_user_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_profile.is_creator OR v_profile.is_editor THEN
    RAISE EXCEPTION 'Cannot grant admin to profile % because creator or editor role is enabled.', p_user_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = p_user_id) THEN
    RAISE EXCEPTION 'Profile % already has an admin_users record.', p_user_id
      USING ERRCODE = 'unique_violation';
  END IF;

  -- Step 2: Transition profile to admin scope under the held row lock.
  UPDATE public.profiles
  SET account_scope = 'admin'
  WHERE id = p_user_id;

  -- Step 3: Insert admin_users record (validated by composite FK and enforce_admin_users_rules).
  INSERT INTO public.admin_users (user_id, account_scope, granted_by)
  VALUES (p_user_id, 'admin', p_granted_by);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_grant_admin(uuid, uuid, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_grant_admin(uuid, uuid, text) TO service_role;

-- Attach triggers to profiles and admin_users (alphabetical firing order on profiles)
CREATE TRIGGER trg_10_profiles_caller_rules
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_profiles_caller_rules();

CREATE TRIGGER trg_20_profiles_admin_exclusion
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_profiles_admin_exclusion();

CREATE TRIGGER trg_30_profiles_set_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_40_profiles_prevent_delete
  BEFORE DELETE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_row_deletion();

CREATE TRIGGER trg_10_admin_users_rules
  BEFORE INSERT OR UPDATE ON public.admin_users
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_admin_users_rules();

CREATE TRIGGER trg_20_admin_users_set_updated_at
  BEFORE UPDATE ON public.admin_users
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_30_admin_users_prevent_delete
  BEFORE DELETE ON public.admin_users
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_row_deletion();

-- ----------------------------------------------------------------------------
-- 5. auth.users signup trigger (§2.1)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_meta jsonb := coalesce(NEW.raw_user_meta_data, '{}'::jsonb);
  v_raw_username text;
  v_username text;
  v_display_name text;
  v_is_creator boolean := false;
  v_is_editor boolean := false;
BEGIN
  -- Derive username: preserve explicit input (normalized to lowercase) so invalid formats fail;
  -- generate a deterministic valid username only when omitted (e.g. dashboard user creation).
  v_raw_username := v_meta ->> 'username';
  IF v_raw_username IS NOT NULL AND btrim(v_raw_username) <> '' THEN
    v_username := lower(btrim(v_raw_username));
  ELSE
    v_username := 'user_' || substr(replace(NEW.id::text, '-', ''), 1, 20);
  END IF;

  -- Derive display_name: preserve explicit display_name if key provided; fallback otherwise.
  IF v_meta ? 'display_name' AND jsonb_typeof(v_meta -> 'display_name') <> 'null' THEN
    v_display_name := btrim(v_meta ->> 'display_name');
  ELSE
    v_display_name := nullif(btrim(coalesce(v_meta ->> 'full_name', v_meta ->> 'name', '')), '');
    IF v_display_name IS NULL THEN
      v_display_name := left(
        coalesce(nullif(btrim(split_part(coalesce(NEW.email, ''), '@', 1)), ''), v_username),
        60
      );
    END IF;
  END IF;

  -- Role flags may only request creator and/or editor; admin can never be granted here.
  IF jsonb_typeof(v_meta -> 'is_creator') = 'boolean' THEN
    v_is_creator := (v_meta -> 'is_creator')::boolean;
  END IF;

  IF jsonb_typeof(v_meta -> 'is_editor') = 'boolean' THEN
    v_is_editor := (v_meta -> 'is_editor')::boolean;
  END IF;

  INSERT INTO public.profiles (
    id,
    username,
    display_name,
    is_creator,
    is_editor,
    account_scope,
    status
  )
  VALUES (
    NEW.id,
    v_username::extensions.citext,
    v_display_name,
    v_is_creator,
    v_is_editor,
    'member',
    'active'
  );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_auth_user() FROM PUBLIC, anon, authenticated, service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.handle_new_auth_user() TO supabase_auth_admin';
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_auth_user();

-- ----------------------------------------------------------------------------
-- 6. Security & RLS helper functions (§4, §5.3)
-- ----------------------------------------------------------------------------

-- Active admin check: requires active admin_users row + admin account_scope + MFA aal2 (§4, §5.3).
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
    AND EXISTS (
      SELECT 1
      FROM public.admin_users au
      JOIN public.profiles p ON p.id = au.user_id
      WHERE au.user_id = auth.uid()
        AND au.revoked_at IS NULL
        AND p.account_scope = 'admin'
        AND NOT p.is_creator
        AND NOT p.is_editor
        AND p.status = 'active'
    );
$$;

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;

-- Marketplace capability check for the current authenticated user (§5.3).
CREATE OR REPLACE FUNCTION public.has_role(p_role text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND p_role IN ('creator', 'editor')
    AND EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = auth.uid()
        AND p.status = 'active'
        AND p.account_scope = 'member'
        AND (
          (p_role = 'creator' AND p.is_creator)
          OR (p_role = 'editor' AND p.is_editor)
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.admin_users au
          WHERE au.user_id = p.id
        )
    );
$$;

REVOKE ALL ON FUNCTION public.has_role(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.has_role(text) TO authenticated, service_role;

-- Helper for profiles Tier 1 UPDATE policy so RLS checks private status/scope/admin state
-- strictly for auth.uid() without exposing private columns or admin_users to authenticated.
CREATE OR REPLACE FUNCTION public.can_update_own_profile(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND p_user_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = p_user_id
        AND p.status = 'active'
        AND p.account_scope = 'member'
        AND NOT EXISTS (
          SELECT 1
          FROM public.admin_users au
          WHERE au.user_id = p.id
        )
    );
$$;

REVOKE ALL ON FUNCTION public.can_update_own_profile(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_update_own_profile(uuid) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 7. Row Level Security & table/column privileges (§0 C5/C6, §5.3)
-- ----------------------------------------------------------------------------

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_users FORCE ROW LEVEL SECURITY;

-- Clear any default privileges granted by Supabase's public schema defaults.
REVOKE ALL ON TABLE public.profiles FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.admin_users FROM PUBLIC, anon, authenticated, service_role;

-- profiles: authenticated may read public columns only, and Tier-1 update own editable columns only.
GRANT SELECT (
  id,
  username,
  display_name,
  avatar_path,
  bio,
  is_creator,
  is_editor,
  created_at
) ON TABLE public.profiles TO authenticated;

GRANT UPDATE (
  display_name,
  avatar_path,
  bio,
  is_creator,
  is_editor
) ON TABLE public.profiles TO authenticated;

-- Server-side service_role retains non-destructive table access (no DELETE/TRUNCATE per C6).
GRANT SELECT, INSERT, UPDATE ON TABLE public.profiles TO service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.admin_users TO service_role;

-- RLS policies on public.profiles (admin_users intentionally has NO policies — §2.1, §5.3).
CREATE POLICY profiles_select_authenticated
  ON public.profiles
  FOR SELECT
  TO authenticated, postgres
  USING (auth.uid() IS NOT NULL);

CREATE POLICY profiles_update_own
  ON public.profiles
  FOR UPDATE
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND id = auth.uid()
    AND public.can_update_own_profile(id)
  )
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND id = auth.uid()
    AND public.can_update_own_profile(id)
  );

-- ----------------------------------------------------------------------------
-- 8. Secure own_profile view and privileges (§1, §5.3)
-- ----------------------------------------------------------------------------

CREATE VIEW public.own_profile
WITH (security_barrier = true, security_invoker = false)
AS
SELECT
  p.id,
  p.username,
  p.display_name,
  p.avatar_path,
  p.bio,
  p.is_creator,
  p.is_editor,
  p.account_scope,
  p.status,
  p.created_at,
  p.updated_at
FROM public.profiles p
WHERE auth.uid() IS NOT NULL
  AND p.id = auth.uid();

REVOKE ALL ON TABLE public.own_profile FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.own_profile TO authenticated;
