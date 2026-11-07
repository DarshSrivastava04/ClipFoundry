-- ============================================================================
-- ClipFoundry — Phase 2.2 Migration 2: Core Marketplace Schema
-- Scope: Enums, social_accounts, campaigns, campaign_assets, campaign_members,
--        submissions, state-machine & integrity triggers, RLS helpers,
--        Tier 2 / Tier 3 marketplace functions, grants, and RLS policies.
-- Source of truth: database_architecture.md (Revision 3)
--
-- Deferred cross-migration integration points (do not invent substitutes):
--   1. campaign_fundings & ledger_accounts (later Funding/Ledger migration):
--      - Reward campaigns fail closed on transition out of 'draft' (except
--        'draft' -> 'cancelled') until campaign_fundings and campaign_escrow
--        ledger_accounts exist.
--      - campaign_accepts_activity(uuid) currently permits only active
--        organic campaigns within their open window; the Ledger migration
--        extends it to allow active reward campaigns with escrow balance > 0.
--      - withdraw_submission(uuid) fails closed if reward_accrued_paise >
--        reward_finalized_paise until ledger reward_reversal is provisioned.
--   2. moderation_cases (later Moderation migration):
--      - withdraw_submission(uuid) will add the open-case check once
--        moderation_cases is created.
--   3. audit_logs & notifications (later Support/Audit migrations):
--      - Atomic audit_logs triggers/writes and notify(...) calls will be
--        wired when those tables are created.
--   4. social_account_tokens: deferred until an OAuth integration is chosen.
--
-- Global lock hierarchy (§4, §6.5, §7.5):
--   admin_users (FOR SHARE)
--     -> profiles (FOR SHARE / FOR UPDATE)
--     -> social_accounts (FOR SHARE / FOR NO KEY UPDATE)
--     -> campaigns (FOR SHARE / FOR NO KEY UPDATE)
--     -> campaign_members (FOR SHARE / FOR NO KEY UPDATE)
--     -> submissions (FOR NO KEY UPDATE)
--     -> [later] withdrawal_requests -> ledger_accounts (ORDER BY id ASC)
--
--   Notes on PostgreSQL executor locks during Tier 1 direct DML:
--   - Tier 2 / Tier 3 functions read immutable parent FKs first so explicit
--     row locks always follow the top-down hierarchy above (including
--     review_submission, withdraw_submission, and verify_social_account).
--   - submissions BEFORE UPDATE reads immutable campaigns.campaign_type without
--     FOR SHARE (campaigns cannot be deleted and campaign_type is frozen once
--     activated), avoiding any submissions -> campaigns lock inversion.
--   - campaign_members BEFORE UPDATE skips parent locks on active -> left and
--     -> removed; only Tier 1 rejoin (left -> active) locks profiles/campaigns
--     FOR SHARE after the executor locks campaign_members, and Tier 1 DELETE on
--     campaign_assets locks campaigns FOR SHARE after campaign_assets. These
--     remain cycle-free because no transaction holding FOR NO KEY UPDATE or
--     FOR UPDATE on profiles or campaigns ever mutates campaign_members or
--     campaign_assets.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Core marketplace enum types (§0 C4, §2.2–§2.4, §8)
-- ----------------------------------------------------------------------------

CREATE TYPE public.social_platform AS ENUM (
  'youtube',
  'instagram',
  'tiktok'
);

CREATE TYPE public.verification_status AS ENUM (
  'unverified',
  'pending',
  'verified',
  'revoked'
);

CREATE TYPE public.campaign_type AS ENUM (
  'organic',
  'reward'
);

CREATE TYPE public.campaign_status AS ENUM (
  'draft',
  'pending_funding',
  'active',
  'paused',
  'settling',
  'completed',
  'cancelled',
  'suspended'
);

CREATE TYPE public.asset_kind AS ENUM (
  'source_video',
  'asset'
);

CREATE TYPE public.member_status AS ENUM (
  'active',
  'left',
  'removed'
);

CREATE TYPE public.submission_status AS ENUM (
  'pending_review',
  'approved',
  'rejected',
  'flagged',
  'finalized',
  'withdrawn'
);

-- ----------------------------------------------------------------------------
-- 2. Core marketplace tables (§2.2, §2.3, §2.4)
-- ----------------------------------------------------------------------------

-- 2a. Editor connected social identities (§2.2)
CREATE TABLE public.social_accounts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  editor_id uuid NOT NULL,
  platform public.social_platform NOT NULL,
  platform_user_id text NOT NULL,
  handle text NOT NULL,
  profile_url text NOT NULL,
  verification_status public.verification_status NOT NULL DEFAULT 'unverified',
  verification_method text NULL,
  verified_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT social_accounts_pkey
    PRIMARY KEY (id),
  CONSTRAINT social_accounts_editor_id_fkey
    FOREIGN KEY (editor_id) REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT social_accounts_editor_platform_user_key
    UNIQUE (editor_id, platform, platform_user_id),
  CONSTRAINT social_accounts_platform_user_id_chk
    CHECK (
      platform_user_id = btrim(platform_user_id)
      AND char_length(platform_user_id) >= 1
      AND char_length(platform_user_id) <= 255
    ),
  CONSTRAINT social_accounts_handle_chk
    CHECK (
      handle = btrim(handle)
      AND char_length(handle) >= 1
      AND char_length(handle) <= 100
    ),
  CONSTRAINT social_accounts_profile_url_https_chk
    CHECK (profile_url ~ '^https://[^[:space:]]+$' AND char_length(profile_url) <= 2048),
  CONSTRAINT social_accounts_verification_method_chk
    CHECK (verification_method IS NULL OR verification_method IN ('oauth', 'bio_code', 'manual')),
  CONSTRAINT social_accounts_verification_consistency_chk
    CHECK (
      (verification_status <> 'verified' OR (verified_at IS NOT NULL AND verification_method IS NOT NULL))
      AND (verification_status <> 'unverified' OR (verified_at IS NULL AND verification_method IS NULL))
      AND (verification_status <> 'pending' OR verified_at IS NULL)
      AND (verification_status <> 'revoked' OR ((verified_at IS NULL) = (verification_method IS NULL)))
    )
);

-- Only verified claims are exclusive so squatters cannot block real owners (§2.2, §10 #2).
CREATE UNIQUE INDEX social_accounts_verified_identity_idx
  ON public.social_accounts (platform, platform_user_id)
  WHERE verification_status = 'verified';

CREATE INDEX social_accounts_editor_id_idx
  ON public.social_accounts (editor_id);

-- 2b. Organic and reward campaigns (§2.3)
-- Note: Remaining budget is NOT a column; it will live in ledger_accounts (§2.3).
CREATE TABLE public.campaigns (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  creator_id uuid NOT NULL,
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  campaign_type public.campaign_type NOT NULL,
  status public.campaign_status NOT NULL DEFAULT 'draft',
  suspended_from public.campaign_status NULL,
  currency char(3) NOT NULL DEFAULT 'INR',
  cpm_paise bigint NULL,
  reward_pool_paise bigint NOT NULL DEFAULT 0,
  platform_fee_bps integer NULL,
  per_submission_cap_paise bigint NULL,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  requirements text NOT NULL DEFAULT '',
  allowed_platforms public.social_platform[] NOT NULL,
  activated_at timestamptz NULL,
  closed_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT campaigns_pkey
    PRIMARY KEY (id),
  CONSTRAINT campaigns_creator_id_fkey
    FOREIGN KEY (creator_id) REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT campaigns_title_len_chk
    CHECK (char_length(btrim(title)) >= 3 AND char_length(title) <= 120),
  CONSTRAINT campaigns_description_len_chk
    CHECK (char_length(description) <= 5000),
  CONSTRAINT campaigns_currency_chk
    CHECK (currency = 'INR'),
  CONSTRAINT campaigns_cpm_paise_positive_chk
    CHECK (cpm_paise IS NULL OR cpm_paise > 0),
  CONSTRAINT campaigns_reward_pool_nonneg_chk
    CHECK (reward_pool_paise >= 0),
  CONSTRAINT campaigns_platform_fee_bps_range_chk
    CHECK (platform_fee_bps IS NULL OR (platform_fee_bps >= 0 AND platform_fee_bps <= 10000)),
  CONSTRAINT campaigns_per_submission_cap_positive_chk
    CHECK (per_submission_cap_paise IS NULL OR per_submission_cap_paise > 0),
  CONSTRAINT campaigns_type_consistency_chk
    CHECK (
      (
        campaign_type = 'organic'
        AND cpm_paise IS NULL
        AND reward_pool_paise = 0
        AND platform_fee_bps IS NULL
        AND per_submission_cap_paise IS NULL
      )
      OR (
        campaign_type = 'reward'
        AND cpm_paise IS NOT NULL
        AND cpm_paise > 0
      )
    ),
  CONSTRAINT campaigns_window_order_chk
    CHECK (ends_at > starts_at),
  CONSTRAINT campaigns_requirements_len_chk
    CHECK (char_length(requirements) <= 10000),
  CONSTRAINT campaigns_allowed_platforms_nonempty_chk
    CHECK (
      cardinality(allowed_platforms) >= 1
      AND cardinality(allowed_platforms) <= 10
      AND array_position(allowed_platforms, NULL) IS NULL
    ),
  CONSTRAINT campaigns_suspended_from_consistency_chk
    CHECK (
      (status = 'suspended' AND suspended_from IS NOT NULL AND suspended_from IN ('active', 'paused'))
      OR (status <> 'suspended' AND suspended_from IS NULL)
    ),
  CONSTRAINT campaigns_activated_at_consistency_chk
    CHECK (
      (status IN ('draft', 'pending_funding', 'cancelled') AND activated_at IS NULL)
      OR (status IN ('active', 'paused', 'suspended', 'settling', 'completed') AND activated_at IS NOT NULL)
    ),
  CONSTRAINT campaigns_closed_at_consistency_chk
    CHECK (
      (status IN ('settling', 'completed', 'cancelled') AND closed_at IS NOT NULL)
      OR (status NOT IN ('settling', 'completed', 'cancelled') AND closed_at IS NULL)
    )
);

CREATE INDEX campaigns_creator_id_idx
  ON public.campaigns (creator_id);

CREATE INDEX campaigns_status_ends_at_idx
  ON public.campaigns (status, ends_at);

CREATE INDEX campaigns_active_idx
  ON public.campaigns (ends_at)
  WHERE status = 'active';

-- 2c. Source videos and campaign assets (§2.3)
CREATE TABLE public.campaign_assets (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL,
  kind public.asset_kind NOT NULL,
  title text NOT NULL,
  file_name text NULL,
  storage_path text NULL,
  external_url text NULL,
  mime_type text NULL,
  size_bytes bigint NULL,
  duration_seconds integer NULL,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT campaign_assets_pkey
    PRIMARY KEY (id),
  CONSTRAINT campaign_assets_campaign_id_fkey
    FOREIGN KEY (campaign_id) REFERENCES public.campaigns(id) ON DELETE RESTRICT,
  CONSTRAINT campaign_assets_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT campaign_assets_title_len_chk
    CHECK (char_length(btrim(title)) >= 1 AND char_length(title) <= 120),
  CONSTRAINT campaign_assets_file_name_nonblank_chk
    CHECK (file_name IS NULL OR (char_length(btrim(file_name)) >= 1 AND char_length(file_name) <= 255)),
  CONSTRAINT campaign_assets_storage_path_scoped_chk
    CHECK (
      storage_path IS NULL
      OR (
        storage_path = btrim(storage_path)
        AND char_length(storage_path) <= 1024
        AND storage_path !~ '[[:cntrl:]]'
        AND strpos(storage_path, '\') = 0
        AND strpos(storage_path, '//') = 0
        AND split_part(storage_path, '/', 1) = campaign_id::text
        AND char_length(storage_path) > char_length(campaign_id::text) + 1
        AND cardinality(string_to_array(storage_path, '/')) >= 2
        AND NOT ('' = ANY(string_to_array(storage_path, '/')))
        AND NOT ('.' = ANY(string_to_array(storage_path, '/')))
        AND NOT ('..' = ANY(string_to_array(storage_path, '/')))
      )
    ),
  CONSTRAINT campaign_assets_external_url_https_chk
    CHECK (external_url IS NULL OR (external_url ~ '^https://[^[:space:]]+$' AND char_length(external_url) <= 2048)),
  CONSTRAINT campaign_assets_source_xor_chk
    CHECK ((storage_path IS NOT NULL) <> (external_url IS NOT NULL)),
  CONSTRAINT campaign_assets_mime_type_nonblank_chk
    CHECK (mime_type IS NULL OR (char_length(btrim(mime_type)) >= 1 AND char_length(mime_type) <= 127)),
  CONSTRAINT campaign_assets_size_bytes_nonneg_chk
    CHECK (size_bytes IS NULL OR size_bytes >= 0),
  CONSTRAINT campaign_assets_duration_seconds_nonneg_chk
    CHECK (duration_seconds IS NULL OR duration_seconds >= 0)
);

CREATE UNIQUE INDEX campaign_assets_storage_path_idx
  ON public.campaign_assets (storage_path)
  WHERE storage_path IS NOT NULL;

CREATE INDEX campaign_assets_campaign_id_idx
  ON public.campaign_assets (campaign_id);

-- 2d. Editor <-> campaign membership (§2.3)
CREATE TABLE public.campaign_members (
  campaign_id uuid NOT NULL,
  editor_id uuid NOT NULL,
  status public.member_status NOT NULL DEFAULT 'active',
  joined_at timestamptz NOT NULL DEFAULT now(),
  left_at timestamptz NULL,
  removed_by uuid NULL,
  removed_reason text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT campaign_members_pkey
    PRIMARY KEY (campaign_id, editor_id),
  CONSTRAINT campaign_members_campaign_id_fkey
    FOREIGN KEY (campaign_id) REFERENCES public.campaigns(id) ON DELETE RESTRICT,
  CONSTRAINT campaign_members_editor_id_fkey
    FOREIGN KEY (editor_id) REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT campaign_members_removed_by_fkey
    FOREIGN KEY (removed_by) REFERENCES public.profiles(id) ON DELETE RESTRICT,
  CONSTRAINT campaign_members_removed_fields_chk
    CHECK (
      (
        status = 'removed'
        AND removed_by IS NOT NULL
        AND removed_reason IS NOT NULL
        AND char_length(btrim(removed_reason)) >= 5
        AND char_length(removed_reason) <= 2000
      )
      OR (status <> 'removed' AND removed_by IS NULL AND removed_reason IS NULL)
    ),
  CONSTRAINT campaign_members_left_at_chk
    CHECK (
      (status = 'left' AND left_at IS NOT NULL)
      OR (status = 'active' AND left_at IS NULL)
      OR (status = 'removed')
    )
);

CREATE INDEX campaign_members_editor_id_idx
  ON public.campaign_members (editor_id);

-- 2e. Published post submissions (§2.4)
CREATE TABLE public.submissions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  campaign_id uuid NOT NULL,
  editor_id uuid NOT NULL,
  social_account_id uuid NOT NULL,
  platform public.social_platform NOT NULL,
  author_handle text NOT NULL,
  author_profile_url text NOT NULL,
  post_url text NOT NULL,
  normalized_url text NOT NULL,
  external_post_id text NOT NULL,
  posted_at timestamptz NOT NULL,
  status public.submission_status NOT NULL DEFAULT 'pending_review',
  status_before_flag public.submission_status NULL,
  rejection_code text NULL,
  rejection_reason text NULL,
  reviewed_by uuid NULL,
  reviewed_at timestamptz NULL,
  approved_at timestamptz NULL,
  baseline_views bigint NOT NULL DEFAULT 0,
  latest_view_count bigint NOT NULL DEFAULT 0,
  eligible_views bigint NOT NULL DEFAULT 0,
  reward_entitled_paise bigint NOT NULL DEFAULT 0,
  reward_accrued_paise bigint NOT NULL DEFAULT 0,
  reward_finalized_paise bigint NOT NULL DEFAULT 0,
  finalized_at timestamptz NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT submissions_pkey
    PRIMARY KEY (id),
  CONSTRAINT submissions_campaign_member_fkey
    FOREIGN KEY (campaign_id, editor_id)
    REFERENCES public.campaign_members(campaign_id, editor_id)
    ON DELETE RESTRICT
    ON UPDATE RESTRICT,
  CONSTRAINT submissions_social_account_id_fkey
    FOREIGN KEY (social_account_id)
    REFERENCES public.social_accounts(id)
    ON DELETE RESTRICT,
  CONSTRAINT submissions_reviewed_by_fkey
    FOREIGN KEY (reviewed_by)
    REFERENCES public.profiles(id)
    ON DELETE RESTRICT,
  -- Unconditional duplicate-post locks across the entire platform (§2.4, §9):
  -- rejected and withdrawn submissions remain in place and permanently lock their post.
  CONSTRAINT submissions_platform_external_post_id_key
    UNIQUE (platform, external_post_id),
  CONSTRAINT submissions_normalized_url_key
    UNIQUE (normalized_url),
  CONSTRAINT submissions_author_handle_nonblank_chk
    CHECK (char_length(btrim(author_handle)) >= 1 AND char_length(author_handle) <= 100),
  CONSTRAINT submissions_author_profile_url_https_chk
    CHECK (author_profile_url ~ '^https://[^[:space:]]+$' AND char_length(author_profile_url) <= 2048),
  CONSTRAINT submissions_post_url_https_chk
    CHECK (post_url ~ '^https://[^[:space:]]+$' AND char_length(post_url) <= 2048),
  CONSTRAINT submissions_normalized_url_https_chk
    CHECK (normalized_url ~ '^https://[^[:space:]]+$' AND char_length(normalized_url) <= 2048),
  CONSTRAINT submissions_external_post_id_nonblank_chk
    CHECK (
      external_post_id = btrim(external_post_id)
      AND char_length(external_post_id) >= 1
      AND char_length(external_post_id) <= 255
    ),
  CONSTRAINT submissions_status_before_flag_chk
    CHECK (
      (status = 'flagged' AND status_before_flag IS NOT NULL AND status_before_flag IN ('pending_review', 'approved'))
      OR (status <> 'flagged' AND status_before_flag IS NULL)
    ),
  CONSTRAINT submissions_rejection_code_nonblank_chk
    CHECK (rejection_code IS NULL OR (char_length(btrim(rejection_code)) >= 1 AND char_length(rejection_code) <= 100)),
  CONSTRAINT submissions_rejection_reason_chk
    CHECK (
      (rejection_reason IS NULL OR char_length(rejection_reason) <= 2000)
      AND (status <> 'rejected' OR (rejection_reason IS NOT NULL AND char_length(btrim(rejection_reason)) >= 10))
    ),
  CONSTRAINT submissions_reviewed_pair_chk
    CHECK ((reviewed_by IS NULL) = (reviewed_at IS NULL)),
  CONSTRAINT submissions_approved_at_chk
    CHECK (
      (status NOT IN ('approved', 'finalized') OR approved_at IS NOT NULL)
      AND (status <> 'pending_review' OR approved_at IS NULL)
    ),
  CONSTRAINT submissions_finalized_at_chk
    CHECK (
      (status = 'finalized' AND finalized_at IS NOT NULL)
      OR (status <> 'finalized' AND finalized_at IS NULL)
    ),
  CONSTRAINT submissions_withdrawn_accrual_settled_chk
    CHECK (status <> 'withdrawn' OR reward_accrued_paise = reward_finalized_paise),
  CONSTRAINT submissions_views_nonneg_chk
    CHECK (baseline_views >= 0 AND latest_view_count >= 0 AND eligible_views >= 0),
  CONSTRAINT submissions_reward_hierarchy_chk
    CHECK (
      0 <= reward_finalized_paise
      AND reward_finalized_paise <= reward_accrued_paise
      AND reward_accrued_paise <= reward_entitled_paise
    )
);

CREATE INDEX submissions_campaign_status_idx
  ON public.submissions (campaign_id, status);

CREATE INDEX submissions_editor_status_idx
  ON public.submissions (editor_id, status);

CREATE INDEX submissions_pending_review_idx
  ON public.submissions (campaign_id, created_at)
  WHERE status = 'pending_review';

CREATE INDEX submissions_social_account_id_idx
  ON public.submissions (social_account_id);

-- ----------------------------------------------------------------------------
-- 3. RLS & state helper functions (§5.3, §6.3, §8)
-- ----------------------------------------------------------------------------

-- True if the authenticated caller is the creator/owner of p_campaign_id (§5.3).
CREATE OR REPLACE FUNCTION public.owns_campaign(p_campaign_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND p_campaign_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.campaigns c
      WHERE c.id = p_campaign_id
        AND c.creator_id = auth.uid()
    );
$$;

REVOKE ALL ON FUNCTION public.owns_campaign(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.owns_campaign(uuid) TO authenticated, service_role;

-- True if the authenticated caller is an active editor with an active membership on p_campaign_id (§5.3).
CREATE OR REPLACE FUNCTION public.is_active_member(p_campaign_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND p_campaign_id IS NOT NULL
    AND public.has_role('editor')
    AND EXISTS (
      SELECT 1
      FROM public.campaign_members cm
      WHERE cm.campaign_id = p_campaign_id
        AND cm.editor_id = auth.uid()
        AND cm.status = 'active'
    );
$$;

REVOKE ALL ON FUNCTION public.is_active_member(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_active_member(uuid) TO authenticated, service_role;

-- True when p_campaign_id is active, inside its open window, and has available budget (§5.1, §6.3, §8).
-- Note: Reward campaigns fail closed here until ledger_accounts (campaign_escrow) is added.
CREATE OR REPLACE FUNCTION public.campaign_accepts_activity(p_campaign_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND p_campaign_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.campaigns c
      WHERE c.id = p_campaign_id
        AND c.status = 'active'
        AND now() >= c.starts_at
        AND now() < c.ends_at
        AND c.campaign_type = 'organic'
    );
$$;

REVOKE ALL ON FUNCTION public.campaign_accepts_activity(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.campaign_accepts_activity(uuid) TO authenticated, service_role;

-- True when p_campaign_id is owned by the active creator auth.uid() and in draft/active/paused (§5.3).
CREATE OR REPLACE FUNCTION public.can_manage_campaign_assets(p_campaign_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND p_campaign_id IS NOT NULL
    AND public.has_role('creator')
    AND EXISTS (
      SELECT 1
      FROM public.campaigns c
      WHERE c.id = p_campaign_id
        AND c.creator_id = auth.uid()
        AND c.status IN ('draft', 'active', 'paused')
    );
$$;

REVOKE ALL ON FUNCTION public.can_manage_campaign_assets(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.can_manage_campaign_assets(uuid) TO authenticated, service_role;

-- True when p_campaign_id is in active/paused/settling so active members can read assets (§5.3).
CREATE OR REPLACE FUNCTION public.campaign_assets_visible_to_member(p_campaign_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND p_campaign_id IS NOT NULL
    AND public.is_active_member(p_campaign_id)
    AND EXISTS (
      SELECT 1
      FROM public.campaigns c
      WHERE c.id = p_campaign_id
        AND c.status IN ('active', 'paused', 'settling')
    );
$$;

REVOKE ALL ON FUNCTION public.campaign_assets_visible_to_member(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.campaign_assets_visible_to_member(uuid) TO authenticated, service_role;

-- True when any submission (regardless of status) references a social account visible to auth.uid() (§5.1, §5.3).
-- Scoped to account owner or active admin so direct RPC calls never leak cross-user submission existence.
CREATE OR REPLACE FUNCTION public.social_account_has_submissions(p_social_account_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    auth.uid() IS NOT NULL
    AND p_social_account_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.social_accounts sa
      JOIN public.submissions s ON s.social_account_id = sa.id
      WHERE sa.id = p_social_account_id
        AND (
          sa.editor_id = auth.uid()
          OR public.is_admin()
        )
    );
$$;

REVOKE ALL ON FUNCTION public.social_account_has_submissions(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.social_account_has_submissions(uuid) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. Row-level integrity & state-machine triggers (§2.2–§2.4, §5.1, §6, §8)
-- ----------------------------------------------------------------------------

-- 4a. social_accounts caller guard (SECURITY INVOKER: inspects current_user)
CREATE OR REPLACE FUNCTION public.enforce_social_accounts_caller_rules()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF current_user IN ('anon', 'authenticated') THEN
      IF NEW.verification_status IS DISTINCT FROM 'unverified'
         OR NEW.verification_method IS NOT NULL
         OR NEW.verified_at IS NOT NULL THEN
        RAISE EXCEPTION 'Client social account claims must be inserted as unverified.'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF current_user IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'Direct updates to social_accounts by client roles are prohibited.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.editor_id IS DISTINCT FROM OLD.editor_id
     OR NEW.platform IS DISTINCT FROM OLD.platform
     OR NEW.platform_user_id IS DISTINCT FROM OLD.platform_user_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'social_accounts identity fields and created_at are immutable.'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_social_accounts_caller_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4b. social_accounts domain guard (SECURITY DEFINER: locks owner profile FOR SHARE & guards revocation)
CREATE OR REPLACE FUNCTION public.enforce_social_accounts_domain_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ok integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.verification_status = 'revoked' THEN
      RAISE EXCEPTION 'Revoked social accounts cannot be deleted.'
        USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.verification_status IN ('verified', 'revoked') THEN
      IF NEW.verification_method IS DISTINCT FROM OLD.verification_method
         OR NEW.verified_at IS DISTINCT FROM OLD.verified_at THEN
        RAISE EXCEPTION 'social_accounts verification_method and verified_at are immutable once verified or revoked.'
          USING ERRCODE = 'integrity_constraint_violation';
      END IF;
    END IF;

    IF NEW.verification_status IS DISTINCT FROM OLD.verification_status THEN
      IF OLD.verification_status = 'revoked' THEN
        RAISE EXCEPTION 'Revoked social accounts cannot transition to %.', NEW.verification_status
          USING ERRCODE = 'check_violation';
      END IF;

      IF OLD.verification_status = 'verified' AND NEW.verification_status <> 'revoked' THEN
        RAISE EXCEPTION 'Verified social accounts may only transition to revoked (attempted: %).', NEW.verification_status
          USING ERRCODE = 'check_violation';
      END IF;
    END IF;
  END IF;

  IF TG_OP = 'INSERT'
     OR (TG_OP = 'UPDATE' AND NEW.verification_status = 'verified' AND OLD.verification_status <> 'verified') THEN
    SELECT 1
      INTO v_ok
    FROM public.profiles p
    WHERE p.id = NEW.editor_id
      AND p.status = 'active'
      AND p.account_scope = 'member'
      AND p.is_editor
      AND NOT EXISTS (
        SELECT 1
        FROM public.admin_users au
        WHERE au.user_id = p.id
      )
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'social_accounts.editor_id (%) must belong to an active editor profile.', NEW.editor_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_social_accounts_domain_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4c. campaigns caller guard (SECURITY INVOKER: blocks client status/money tampering)
CREATE OR REPLACE FUNCTION public.enforce_campaigns_caller_rules()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF current_user IN ('anon', 'authenticated') THEN
      IF NEW.status IS DISTINCT FROM 'draft'
         OR NEW.suspended_from IS NOT NULL
         OR NEW.reward_pool_paise IS DISTINCT FROM 0
         OR NEW.platform_fee_bps IS NOT NULL
         OR NEW.activated_at IS NOT NULL
         OR NEW.closed_at IS NOT NULL THEN
        RAISE EXCEPTION 'Clients may only create draft campaigns without server-managed fields.'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF current_user IN ('anon', 'authenticated') THEN
    IF OLD.status <> 'draft' OR NEW.status IS DISTINCT FROM 'draft' THEN
      RAISE EXCEPTION 'Clients may only edit campaigns while in draft status.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NEW.suspended_from IS DISTINCT FROM OLD.suspended_from
       OR NEW.reward_pool_paise IS DISTINCT FROM OLD.reward_pool_paise
       OR NEW.platform_fee_bps IS DISTINCT FROM OLD.platform_fee_bps
       OR NEW.activated_at IS DISTINCT FROM OLD.activated_at
       OR NEW.closed_at IS DISTINCT FROM OLD.closed_at THEN
      RAISE EXCEPTION 'Server-managed campaign fields cannot be modified by clients.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_campaigns_caller_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4d. campaigns domain & state-machine guard (SECURITY DEFINER: §2.3, §6, §8)
CREATE OR REPLACE FUNCTION public.enforce_campaigns_domain_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_ok integer;
BEGIN
  IF NEW.allowed_platforms IS NULL
     OR (
       SELECT count(DISTINCT p)
       FROM unnest(NEW.allowed_platforms) AS t(p)
     ) <> cardinality(NEW.allowed_platforms) THEN
    RAISE EXCEPTION 'campaigns.allowed_platforms must not contain duplicate platforms.'
      USING ERRCODE = 'check_violation';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status IS DISTINCT FROM 'draft'
       OR NEW.suspended_from IS NOT NULL
       OR NEW.reward_pool_paise IS DISTINCT FROM 0
       OR NEW.platform_fee_bps IS NOT NULL
       OR NEW.activated_at IS NOT NULL
       OR NEW.closed_at IS NOT NULL THEN
      RAISE EXCEPTION 'New campaigns must start in draft status with zero funded pool.'
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT 1
      INTO v_ok
    FROM public.profiles p
    WHERE p.id = NEW.creator_id
      AND p.status = 'active'
      AND p.account_scope = 'member'
      AND p.is_creator
      AND NOT EXISTS (
        SELECT 1
        FROM public.admin_users au
        WHERE au.user_id = p.id
      )
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'campaigns.creator_id (%) must belong to an active creator profile.', NEW.creator_id
        USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.creator_id IS DISTINCT FROM OLD.creator_id
     OR NEW.currency IS DISTINCT FROM OLD.currency
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'campaigns.id, creator_id, currency, and created_at are immutable.'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- Freeze fields after activation (§2.3: campaign_type, cpm_paise, starts_at, per_submission_cap_paise;
  -- ends_at can only be extended).
  IF OLD.activated_at IS NOT NULL THEN
    IF NEW.activated_at IS DISTINCT FROM OLD.activated_at THEN
      RAISE EXCEPTION 'campaigns.activated_at is immutable once set.'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF NEW.campaign_type IS DISTINCT FROM OLD.campaign_type
       OR NEW.cpm_paise IS DISTINCT FROM OLD.cpm_paise
       OR NEW.starts_at IS DISTINCT FROM OLD.starts_at
       OR NEW.per_submission_cap_paise IS DISTINCT FROM OLD.per_submission_cap_paise THEN
      RAISE EXCEPTION 'campaign_type, cpm_paise, starts_at, and per_submission_cap_paise are frozen after activation.'
        USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.ends_at IS NULL OR NEW.ends_at < OLD.ends_at THEN
      RAISE EXCEPTION 'campaigns.ends_at cannot be shortened after activation; it may only be extended.'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF OLD.closed_at IS NOT NULL AND NEW.closed_at IS DISTINCT FROM OLD.closed_at THEN
    RAISE EXCEPTION 'campaigns.closed_at is immutable once set.'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- Once closing/terminal (settling, completed, cancelled), freeze editable spec fields as well.
  IF OLD.status IN ('settling', 'completed', 'cancelled') THEN
    IF NEW.title IS DISTINCT FROM OLD.title
       OR NEW.description IS DISTINCT FROM OLD.description
       OR NEW.ends_at IS DISTINCT FROM OLD.ends_at
       OR NEW.requirements IS DISTINCT FROM OLD.requirements
       OR NEW.allowed_platforms IS DISTINCT FROM OLD.allowed_platforms THEN
      RAISE EXCEPTION 'Campaign specification fields are frozen once %.', OLD.status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- Enforce §8 campaign status state machine transitions.
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    CASE OLD.status
      WHEN 'draft' THEN
        IF NEW.status = 'active' THEN
          IF NEW.campaign_type <> 'organic' THEN
            RAISE EXCEPTION 'Reward campaigns cannot transition directly from draft to active.'
              USING ERRCODE = 'check_violation';
          END IF;
          NEW.activated_at := coalesce(NEW.activated_at, now());
        ELSIF NEW.status = 'pending_funding' THEN
          IF NEW.campaign_type <> 'reward' THEN
            RAISE EXCEPTION 'Only reward campaigns may transition to pending_funding.'
              USING ERRCODE = 'check_violation';
          END IF;
          -- Fail closed until campaign_fundings and ledger_accounts are created in the Ledger migration.
          RAISE EXCEPTION 'Reward campaign funding and activation are unavailable until campaign_fundings and ledger_accounts are provisioned.'
            USING ERRCODE = 'check_violation';
        ELSIF NEW.status = 'cancelled' THEN
          NEW.closed_at := coalesce(NEW.closed_at, now());
        ELSE
          RAISE EXCEPTION 'Illegal campaign status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'pending_funding' THEN
        IF NEW.status = 'draft' THEN
          NULL;
        ELSIF NEW.status = 'cancelled' THEN
          NEW.closed_at := coalesce(NEW.closed_at, now());
        ELSIF NEW.status = 'active' THEN
          RAISE EXCEPTION 'Reward campaign activation is unavailable until campaign_fundings and ledger_accounts are provisioned.'
            USING ERRCODE = 'check_violation';
        ELSE
          RAISE EXCEPTION 'Illegal campaign status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'active' THEN
        IF NEW.status = 'paused' THEN
          NULL;
        ELSIF NEW.status = 'settling' THEN
          NEW.closed_at := coalesce(NEW.closed_at, now());
        ELSIF NEW.status = 'suspended' THEN
          NEW.suspended_from := 'active';
        ELSE
          RAISE EXCEPTION 'Illegal campaign status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'paused' THEN
        IF NEW.status = 'active' THEN
          NULL;
        ELSIF NEW.status = 'settling' THEN
          NEW.closed_at := coalesce(NEW.closed_at, now());
        ELSIF NEW.status = 'suspended' THEN
          NEW.suspended_from := 'paused';
        ELSE
          RAISE EXCEPTION 'Illegal campaign status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'suspended' THEN
        IF OLD.suspended_from IS NOT NULL AND NEW.status = OLD.suspended_from THEN
          NEW.suspended_from := NULL;
        ELSIF NEW.status = 'settling' THEN
          NEW.suspended_from := NULL;
          NEW.closed_at := coalesce(NEW.closed_at, now());
        ELSE
          RAISE EXCEPTION 'Illegal campaign status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'settling' THEN
        IF NEW.status = 'completed' THEN
          NEW.closed_at := coalesce(OLD.closed_at, NEW.closed_at, now());
        ELSE
          RAISE EXCEPTION 'Illegal campaign status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'completed', 'cancelled' THEN
        RAISE EXCEPTION 'Terminal campaign status % cannot transition to %.', OLD.status, NEW.status
          USING ERRCODE = 'check_violation';
    END CASE;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_campaigns_domain_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4e. campaign_assets caller & domain guards (§2.3, §5.3)
CREATE OR REPLACE FUNCTION public.enforce_campaign_assets_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign record;
  v_ok integer;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT c.id, c.creator_id, c.status
      INTO v_campaign
    FROM public.campaigns c
    WHERE c.id = OLD.campaign_id
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Target campaign % does not exist.', OLD.campaign_id
        USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_campaign.status NOT IN ('draft', 'active', 'paused') THEN
      RAISE EXCEPTION 'Campaign assets may only be removed while the campaign is draft, active, or paused.'
        USING ERRCODE = 'check_violation';
    END IF;

    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF current_user IN ('anon', 'authenticated') THEN
      RAISE EXCEPTION 'Direct updates to campaign_assets by client roles are prohibited.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.campaign_id IS DISTINCT FROM OLD.campaign_id
       OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'campaign_assets identity fields and created_at are immutable.'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    RETURN NEW;
  END IF;

  -- TG_OP = 'INSERT'
  SELECT 1
    INTO v_ok
  FROM public.profiles p
  WHERE p.id = NEW.created_by
    AND p.status = 'active'
    AND p.account_scope = 'member'
    AND p.is_creator
    AND NOT EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = p.id
    )
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign_assets.created_by (%) must be an active creator.', NEW.created_by
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT c.id, c.creator_id, c.status
    INTO v_campaign
  FROM public.campaigns c
  WHERE c.id = NEW.campaign_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target campaign % does not exist.', NEW.campaign_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.created_by <> v_campaign.creator_id THEN
    RAISE EXCEPTION 'campaign_assets.created_by (%) must match campaigns.creator_id (%).', NEW.created_by, v_campaign.creator_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_campaign.status NOT IN ('draft', 'active', 'paused') THEN
    RAISE EXCEPTION 'Campaign assets may only be added while the campaign is draft, active, or paused.'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_campaign_assets_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4f. campaign_members caller guard (SECURITY INVOKER: enforces Tier 1 join/leave/rejoin rules)
CREATE OR REPLACE FUNCTION public.enforce_campaign_members_caller_rules()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF current_user IN ('anon', 'authenticated') THEN
      IF NEW.status IS DISTINCT FROM 'active'
         OR NEW.left_at IS NOT NULL
         OR NEW.removed_by IS NOT NULL
         OR NEW.removed_reason IS NOT NULL THEN
        RAISE EXCEPTION 'Clients may only join a campaign with active member status.'
          USING ERRCODE = 'insufficient_privilege';
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF current_user IN ('anon', 'authenticated') THEN
    IF OLD.status = 'removed' OR NEW.status = 'removed' THEN
      RAISE EXCEPTION 'Member removal is restricted to server-side functions.'
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NEW.status IS NULL
       OR NOT (
         (OLD.status = 'active' AND NEW.status = 'left')
         OR (OLD.status = 'left' AND NEW.status = 'active')
       ) THEN
      RAISE EXCEPTION 'Clients may only transition membership between active and left.'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_campaign_members_caller_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4g. campaign_members domain guard (SECURITY DEFINER: self-dealing, active editor, rejoin/removal rules)
--     Note on lock order: parent locks on profiles/campaigns are acquired ONLY on INSERT and on
--     left -> active rejoin (never on active -> left or -> removed).
CREATE OR REPLACE FUNCTION public.enforce_campaign_members_domain_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign record;
  v_ok integer;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.campaign_id IS DISTINCT FROM OLD.campaign_id
       OR NEW.editor_id IS DISTINCT FROM OLD.editor_id
       OR NEW.joined_at IS DISTINCT FROM OLD.joined_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'campaign_members identity fields, joined_at, and created_at are immutable.'
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF OLD.status = 'removed' THEN
      RAISE EXCEPTION 'Removed campaign memberships are immutable and cannot rejoin or be altered.'
        USING ERRCODE = 'check_violation';
    END IF;

    IF OLD.status = 'active' AND NEW.status = 'left' THEN
      NEW.left_at := now();
      RETURN NEW;
    ELSIF OLD.status IN ('active', 'left') AND NEW.status = 'removed' THEN
      NEW.left_at := OLD.left_at;
      RETURN NEW;
    ELSIF NEW.status IS NULL OR NOT (OLD.status = 'left' AND NEW.status = 'active') THEN
      RAISE EXCEPTION 'Illegal campaign membership status transition: % -> %.', OLD.status, NEW.status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- Reached only for TG_OP = 'INSERT' or TG_OP = 'UPDATE' (left -> active rejoin):
  -- Lock editor profile FOR SHARE, then parent campaign FOR SHARE.
  SELECT 1
    INTO v_ok
  FROM public.profiles p
  WHERE p.id = NEW.editor_id
    AND p.status = 'active'
    AND p.account_scope = 'member'
    AND p.is_editor
    AND NOT EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = p.id
    )
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign_members.editor_id (%) must belong to an active editor profile.', NEW.editor_id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT c.id, c.creator_id, c.campaign_type, c.status, c.starts_at, c.ends_at
    INTO v_campaign
  FROM public.campaigns c
  WHERE c.id = NEW.campaign_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target campaign % does not exist.', NEW.campaign_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.editor_id = v_campaign.creator_id THEN
    RAISE EXCEPTION 'Campaign creator (%) cannot join their own campaign (%).', NEW.editor_id, NEW.campaign_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'New campaign memberships must start in active status.'
        USING ERRCODE = 'check_violation';
    END IF;

    IF v_campaign.status <> 'active'
       OR now() < v_campaign.starts_at
       OR now() >= v_campaign.ends_at
       OR v_campaign.campaign_type <> 'organic' THEN
      RAISE EXCEPTION 'Campaign % is not currently accepting new members.', NEW.campaign_id
        USING ERRCODE = 'check_violation';
    END IF;

    NEW.left_at := NULL;
  ELSE
    -- TG_OP = 'UPDATE' (OLD.status = 'left' -> NEW.status = 'active')
    IF v_campaign.status <> 'active'
       OR now() < v_campaign.starts_at
       OR now() >= v_campaign.ends_at
       OR v_campaign.campaign_type <> 'organic' THEN
      RAISE EXCEPTION 'Campaign % is not currently accepting rejoining members.', NEW.campaign_id
        USING ERRCODE = 'check_violation';
    END IF;

    -- Advance joined_at on rejoin so posts published while 'left' cannot be submitted retroactively (D6).
    NEW.joined_at := now();
    NEW.left_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_campaign_members_domain_rules() FROM PUBLIC, anon, authenticated, service_role;

-- 4h. submissions caller & domain guard (SECURITY DEFINER: §2.4, §5.2, §6, §8, §9)
--     Note: current_user inside SECURITY DEFINER is postgres, so a separate SECURITY INVOKER
--     caller guard blocks direct client writes first.
CREATE OR REPLACE FUNCTION public.enforce_submissions_caller_rules()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'Direct client writes to submissions are prohibited; use server functions.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_submissions_caller_rules() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enforce_submissions_domain_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign record;
  v_member record;
  v_social record;
  v_ok integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status IS DISTINCT FROM 'pending_review'
       OR NEW.status_before_flag IS NOT NULL
       OR NEW.reviewed_by IS NOT NULL
       OR NEW.reviewed_at IS NOT NULL
       OR NEW.approved_at IS NOT NULL
       OR NEW.finalized_at IS NOT NULL
       OR NEW.rejection_code IS NOT NULL
       OR NEW.rejection_reason IS NOT NULL
       OR NEW.latest_view_count IS DISTINCT FROM 0
       OR NEW.eligible_views IS DISTINCT FROM 0
       OR NEW.reward_entitled_paise IS DISTINCT FROM 0
       OR NEW.reward_accrued_paise IS DISTINCT FROM 0
       OR NEW.reward_finalized_paise IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'New submissions must start in pending_review with zero views/rewards and no review fields.'
        USING ERRCODE = 'check_violation';
    END IF;

    -- Lock hierarchy: profiles -> social_accounts -> campaigns -> campaign_members
    SELECT 1
      INTO v_ok
    FROM public.profiles p
    WHERE p.id = NEW.editor_id
      AND p.status = 'active'
      AND p.account_scope = 'member'
      AND p.is_editor
      AND NOT EXISTS (
        SELECT 1
        FROM public.admin_users au
        WHERE au.user_id = p.id
      )
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'submissions.editor_id (%) must belong to an active editor profile.', NEW.editor_id
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT sa.id, sa.editor_id, sa.platform, sa.handle, sa.profile_url, sa.verification_status
      INTO v_social
    FROM public.social_accounts sa
    WHERE sa.id = NEW.social_account_id
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Social account % does not exist.', NEW.social_account_id
        USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_social.editor_id <> NEW.editor_id THEN
      RAISE EXCEPTION 'Social account % does not belong to editor %.', NEW.social_account_id, NEW.editor_id
        USING ERRCODE = 'check_violation';
    END IF;

    IF v_social.verification_status <> 'verified' THEN
      RAISE EXCEPTION 'Social account % must be verified before submitting posts.', NEW.social_account_id
        USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.platform IS DISTINCT FROM v_social.platform THEN
      RAISE EXCEPTION 'submissions.platform (%) must match social_accounts.platform (%).', NEW.platform, v_social.platform
        USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.author_handle IS DISTINCT FROM v_social.handle
       OR NEW.author_profile_url IS DISTINCT FROM v_social.profile_url THEN
      RAISE EXCEPTION 'Submission author snapshot must match social_accounts handle and profile_url.'
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT c.id, c.creator_id, c.campaign_type, c.status, c.starts_at, c.ends_at, c.allowed_platforms
      INTO v_campaign
    FROM public.campaigns c
    WHERE c.id = NEW.campaign_id
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Target campaign % does not exist.', NEW.campaign_id
        USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF NEW.editor_id = v_campaign.creator_id THEN
      RAISE EXCEPTION 'Campaign creator (%) cannot submit to their own campaign (%).', NEW.editor_id, NEW.campaign_id
        USING ERRCODE = 'check_violation';
    END IF;

    IF v_campaign.status <> 'active'
       OR now() < v_campaign.starts_at
       OR now() >= v_campaign.ends_at
       OR v_campaign.campaign_type <> 'organic' THEN
      RAISE EXCEPTION 'Campaign % is not currently accepting new submissions.', NEW.campaign_id
        USING ERRCODE = 'check_violation';
    END IF;

    IF NOT (NEW.platform = ANY(v_campaign.allowed_platforms)) THEN
      RAISE EXCEPTION 'Platform % is not permitted for campaign %.', NEW.platform, NEW.campaign_id
        USING ERRCODE = 'check_violation';
    END IF;

    SELECT cm.status, cm.joined_at
      INTO v_member
    FROM public.campaign_members cm
    WHERE cm.campaign_id = NEW.campaign_id
      AND cm.editor_id = NEW.editor_id
    FOR SHARE;

    IF NOT FOUND OR v_member.status <> 'active' THEN
      RAISE EXCEPTION 'Editor % must hold an active membership on campaign % before submitting.', NEW.editor_id, NEW.campaign_id
        USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.posted_at IS NULL OR NEW.posted_at < v_member.joined_at THEN
      RAISE EXCEPTION 'Submitted post timestamp (%) precedes campaign membership joined_at (%).', NEW.posted_at, v_member.joined_at
        USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.posted_at > now() + interval '5 minutes' THEN
      RAISE EXCEPTION 'Submitted post timestamp (%) cannot be in the future.', NEW.posted_at
        USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
  END IF;

  -- TG_OP = 'UPDATE'
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.campaign_id IS DISTINCT FROM OLD.campaign_id
     OR NEW.editor_id IS DISTINCT FROM OLD.editor_id
     OR NEW.social_account_id IS DISTINCT FROM OLD.social_account_id
     OR NEW.platform IS DISTINCT FROM OLD.platform
     OR NEW.author_handle IS DISTINCT FROM OLD.author_handle
     OR NEW.author_profile_url IS DISTINCT FROM OLD.author_profile_url
     OR NEW.post_url IS DISTINCT FROM OLD.post_url
     OR NEW.normalized_url IS DISTINCT FROM OLD.normalized_url
     OR NEW.external_post_id IS DISTINCT FROM OLD.external_post_id
     OR NEW.posted_at IS DISTINCT FROM OLD.posted_at
     OR NEW.baseline_views IS DISTINCT FROM OLD.baseline_views
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Submission identity, author snapshot, and post metadata are immutable.'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- Read immutable campaign_type without FOR SHARE so UPDATE on submissions never locks campaigns
  -- after holding FOR NO KEY UPDATE on submissions (preserving campaigns -> submissions lock order).
  SELECT c.id, c.creator_id, c.campaign_type
    INTO v_campaign
  FROM public.campaigns c
  WHERE c.id = NEW.campaign_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target campaign % does not exist.', NEW.campaign_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- Organic campaigns must always keep all reward columns at 0 (§2.4).
  IF v_campaign.campaign_type = 'organic'
     AND (
       NEW.reward_entitled_paise IS DISTINCT FROM 0
       OR NEW.reward_accrued_paise IS DISTINCT FROM 0
       OR NEW.reward_finalized_paise IS DISTINCT FROM 0
     ) THEN
    RAISE EXCEPTION 'Organic campaign submissions must keep all reward columns at 0.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Finalised reward amounts never decrease on submissions (§6.3).
  IF NEW.reward_finalized_paise IS NULL OR NEW.reward_finalized_paise < OLD.reward_finalized_paise THEN
    RAISE EXCEPTION 'submissions.reward_finalized_paise cannot decrease.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Enforce §8 submission status state machine transitions.
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    CASE OLD.status
      WHEN 'pending_review' THEN
        IF NEW.status = 'approved' THEN
          NEW.approved_at := coalesce(NEW.approved_at, now());
        ELSIF NEW.status = 'rejected' THEN
          NULL;
        ELSIF NEW.status = 'flagged' THEN
          NEW.status_before_flag := 'pending_review';
        ELSIF NEW.status = 'withdrawn' THEN
          NULL;
        ELSE
          RAISE EXCEPTION 'Illegal submission status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'approved' THEN
        IF NEW.status = 'flagged' THEN
          NEW.status_before_flag := 'approved';
        ELSIF NEW.status = 'finalized' THEN
          NEW.finalized_at := coalesce(NEW.finalized_at, now());
        ELSIF NEW.status = 'withdrawn' THEN
          NULL;
        ELSE
          RAISE EXCEPTION 'Illegal submission status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'flagged' THEN
        IF NEW.status = 'approved' THEN
          NEW.status_before_flag := NULL;
          NEW.approved_at := coalesce(NEW.approved_at, now());
        ELSIF NEW.status = 'pending_review' AND OLD.status_before_flag = 'pending_review' THEN
          NEW.status_before_flag := NULL;
        ELSIF NEW.status = 'rejected' THEN
          NEW.status_before_flag := NULL;
        ELSE
          RAISE EXCEPTION 'Illegal submission status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'rejected' THEN
        -- Appeal reversal by admin (§8: rejected -> approved).
        IF NEW.status = 'approved' THEN
          NEW.approved_at := coalesce(NEW.approved_at, now());
        ELSE
          RAISE EXCEPTION 'Illegal submission status transition: % -> %.', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
        END IF;

      WHEN 'finalized', 'withdrawn' THEN
        RAISE EXCEPTION 'Terminal submission status % cannot transition to %.', OLD.status, NEW.status
          USING ERRCODE = 'check_violation';
    END CASE;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_submissions_domain_rules() FROM PUBLIC, anon, authenticated, service_role;

-- Attach triggers in deterministic alphabetical order
CREATE TRIGGER trg_10_social_accounts_caller_rules
  BEFORE INSERT OR UPDATE ON public.social_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_social_accounts_caller_rules();

CREATE TRIGGER trg_20_social_accounts_domain_rules
  BEFORE INSERT OR UPDATE OR DELETE ON public.social_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_social_accounts_domain_rules();

CREATE TRIGGER trg_30_social_accounts_set_updated_at
  BEFORE UPDATE ON public.social_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_10_campaigns_caller_rules
  BEFORE INSERT OR UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_campaigns_caller_rules();

CREATE TRIGGER trg_20_campaigns_domain_rules
  BEFORE INSERT OR UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_campaigns_domain_rules();

CREATE TRIGGER trg_30_campaigns_set_updated_at
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_40_campaigns_prevent_delete
  BEFORE DELETE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_row_deletion();

CREATE TRIGGER trg_10_campaign_assets_rules
  BEFORE INSERT OR UPDATE OR DELETE ON public.campaign_assets
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_campaign_assets_rules();

CREATE TRIGGER trg_20_campaign_assets_set_updated_at
  BEFORE UPDATE ON public.campaign_assets
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_10_campaign_members_caller_rules
  BEFORE INSERT OR UPDATE ON public.campaign_members
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_campaign_members_caller_rules();

CREATE TRIGGER trg_20_campaign_members_domain_rules
  BEFORE INSERT OR UPDATE ON public.campaign_members
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_campaign_members_domain_rules();

CREATE TRIGGER trg_30_campaign_members_set_updated_at
  BEFORE UPDATE ON public.campaign_members
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_40_campaign_members_prevent_delete
  BEFORE DELETE ON public.campaign_members
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_row_deletion();

CREATE TRIGGER trg_10_submissions_caller_rules
  BEFORE INSERT OR UPDATE ON public.submissions
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_submissions_caller_rules();

CREATE TRIGGER trg_20_submissions_domain_rules
  BEFORE INSERT OR UPDATE ON public.submissions
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_submissions_domain_rules();

CREATE TRIGGER trg_30_submissions_set_updated_at
  BEFORE UPDATE ON public.submissions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_40_submissions_prevent_delete
  BEFORE DELETE ON public.submissions
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_row_deletion();

-- ----------------------------------------------------------------------------
-- 5. Tier 2 user-callable marketplace functions (actor = auth.uid(), §5.2)
-- ----------------------------------------------------------------------------

-- 5a. Campaign lifecycle transitions owned by creator (§5.2, §8):
--     Actions: publish_organic, pause, resume, close, cancel
CREATE OR REPLACE FUNCTION public.transition_campaign(
  p_campaign_id uuid,
  p_action text
)
RETURNS public.campaign_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_action text := btrim(coalesce(p_action, ''));
  v_campaign record;
  v_new_status public.campaign_status;
  v_ok integer;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication is required.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'p_campaign_id is required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_action NOT IN ('publish_organic', 'pause', 'resume', 'close', 'cancel') THEN
    RAISE EXCEPTION 'Unsupported campaign action: %.', v_action
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT 1
    INTO v_ok
  FROM public.profiles p
  WHERE p.id = v_actor_id
    AND p.status = 'active'
    AND p.account_scope = 'member'
    AND p.is_creator
    AND NOT EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = p.id
    )
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Caller must have an active creator profile.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT c.id, c.creator_id, c.campaign_type, c.status, c.starts_at, c.ends_at, c.title, c.allowed_platforms
    INTO v_campaign
  FROM public.campaigns c
  WHERE c.id = p_campaign_id
  FOR NO KEY UPDATE;

  IF NOT FOUND OR v_campaign.creator_id <> v_actor_id THEN
    RAISE EXCEPTION 'Campaign % not found or not owned by caller.', p_campaign_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  CASE v_action
    WHEN 'publish_organic' THEN
      IF v_campaign.campaign_type <> 'organic' THEN
        RAISE EXCEPTION 'publish_organic is valid only for organic campaigns.'
          USING ERRCODE = 'check_violation';
      END IF;
      IF v_campaign.status <> 'draft' THEN
        RAISE EXCEPTION 'Only draft organic campaigns can be published (current status: %).', v_campaign.status
          USING ERRCODE = 'check_violation';
      END IF;
      IF v_campaign.ends_at <= now() OR v_campaign.ends_at <= v_campaign.starts_at THEN
        RAISE EXCEPTION 'Campaign must have a valid future ends_at after starts_at to publish.'
          USING ERRCODE = 'check_violation';
      END IF;
      v_new_status := 'active';

    WHEN 'pause' THEN
      IF v_campaign.status <> 'active' THEN
        RAISE EXCEPTION 'Only active campaigns can be paused (current status: %).', v_campaign.status
          USING ERRCODE = 'check_violation';
      END IF;
      v_new_status := 'paused';

    WHEN 'resume' THEN
      IF v_campaign.status <> 'paused' THEN
        RAISE EXCEPTION 'Only paused campaigns can be resumed (current status: %).', v_campaign.status
          USING ERRCODE = 'check_violation';
      END IF;
      IF v_campaign.ends_at <= now() THEN
        RAISE EXCEPTION 'Cannot resume campaign % because ends_at has passed; close it instead.', p_campaign_id
          USING ERRCODE = 'check_violation';
      END IF;
      v_new_status := 'active';

    WHEN 'close' THEN
      IF v_campaign.status NOT IN ('active', 'paused') THEN
        RAISE EXCEPTION 'Only active or paused campaigns can be closed (current status: %).', v_campaign.status
          USING ERRCODE = 'check_violation';
      END IF;
      v_new_status := 'settling';

    WHEN 'cancel' THEN
      IF v_campaign.status NOT IN ('draft', 'pending_funding') THEN
        RAISE EXCEPTION 'Only draft or pending_funding campaigns can be cancelled (current status: %).', v_campaign.status
          USING ERRCODE = 'check_violation';
      END IF;
      v_new_status := 'cancelled';
  END CASE;

  UPDATE public.campaigns
  SET
    status = v_new_status,
    activated_at = CASE WHEN v_action = 'publish_organic' THEN coalesce(activated_at, now()) ELSE activated_at END,
    closed_at = CASE WHEN v_new_status IN ('settling', 'cancelled') THEN coalesce(closed_at, now()) ELSE closed_at END
  WHERE id = p_campaign_id
    AND status = v_campaign.status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign % state changed concurrently; retry action.', p_campaign_id
      USING ERRCODE = 'serialization_failure';
  END IF;

  RETURN v_new_status;
END;
$$;

REVOKE ALL ON FUNCTION public.transition_campaign(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.transition_campaign(uuid, text) TO authenticated, service_role;

-- 5b. Creator removal of a campaign member (§5.2):
--     Existing approved submissions remain intact and continue earning.
CREATE OR REPLACE FUNCTION public.remove_campaign_member(
  p_campaign_id uuid,
  p_editor_id uuid,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_reason text := btrim(coalesce(p_reason, ''));
  v_campaign record;
  v_member record;
  v_ok integer;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication is required.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_campaign_id IS NULL OR p_editor_id IS NULL THEN
    RAISE EXCEPTION 'p_campaign_id and p_editor_id are required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF char_length(v_reason) < 5 OR char_length(v_reason) > 2000 THEN
    RAISE EXCEPTION 'A reason between 5 and 2000 characters is required to remove a campaign member.'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT 1
    INTO v_ok
  FROM public.profiles p
  WHERE p.id = v_actor_id
    AND p.status = 'active'
    AND p.account_scope = 'member'
    AND p.is_creator
    AND NOT EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = p.id
    )
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Caller must have an active creator profile.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT c.id, c.creator_id, c.status
    INTO v_campaign
  FROM public.campaigns c
  WHERE c.id = p_campaign_id
  FOR SHARE;

  IF NOT FOUND OR v_campaign.creator_id <> v_actor_id THEN
    RAISE EXCEPTION 'Campaign % not found or not owned by caller.', p_campaign_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_campaign.status NOT IN ('active', 'paused', 'settling') THEN
    RAISE EXCEPTION 'Campaign members can only be removed while campaign % is active, paused, or settling (current status: %).',
      p_campaign_id, v_campaign.status
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT cm.status
    INTO v_member
  FROM public.campaign_members cm
  WHERE cm.campaign_id = p_campaign_id
    AND cm.editor_id = p_editor_id
  FOR NO KEY UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Editor % is not a member of campaign %.', p_editor_id, p_campaign_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_member.status = 'removed' THEN
    RAISE EXCEPTION 'Editor % has already been removed from campaign %.', p_editor_id, p_campaign_id
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.campaign_members
  SET
    status = 'removed',
    removed_by = v_actor_id,
    removed_reason = v_reason
  WHERE campaign_id = p_campaign_id
    AND editor_id = p_editor_id
    AND status = v_member.status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Membership (%, %) state changed concurrently.', p_campaign_id, p_editor_id
      USING ERRCODE = 'serialization_failure';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.remove_campaign_member(uuid, uuid, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.remove_campaign_member(uuid, uuid, text) TO authenticated, service_role;

-- 5c. Creator review of a pending submission (§5.2, §8):
--     p_decision IN ('approve', 'reject'); reject requires reason >= 10 trimmed chars.
CREATE OR REPLACE FUNCTION public.review_submission(
  p_submission_id uuid,
  p_decision text,
  p_rejection_code text DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS public.submission_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_decision text := btrim(coalesce(p_decision, ''));
  v_reason text := btrim(coalesce(p_reason, ''));
  v_code text := nullif(btrim(coalesce(p_rejection_code, '')), '');
  v_campaign_id uuid;
  v_campaign record;
  v_sub record;
  v_new_status public.submission_status;
  v_ok integer;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication is required.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_submission_id IS NULL THEN
    RAISE EXCEPTION 'p_submission_id is required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_decision NOT IN ('approve', 'reject') THEN
    RAISE EXCEPTION 'p_decision must be approve or reject.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_code IS NOT NULL AND char_length(v_code) > 100 THEN
    RAISE EXCEPTION 'p_rejection_code must not exceed 100 characters.'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_decision = 'reject' AND (char_length(v_reason) < 10 OR char_length(v_reason) > 2000) THEN
    RAISE EXCEPTION 'A rejection reason between 10 and 2000 characters is required.'
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT 1
    INTO v_ok
  FROM public.profiles p
  WHERE p.id = v_actor_id
    AND p.status = 'active'
    AND p.account_scope = 'member'
    AND p.is_creator
    AND NOT EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = p.id
    )
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Caller must have an active creator profile.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Read immutable campaign_id first so we acquire locks in hierarchy order: campaigns -> submissions.
  SELECT s.campaign_id
    INTO v_campaign_id
  FROM public.submissions s
  WHERE s.id = p_submission_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission % not found or caller is not the campaign owner.', p_submission_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT c.id, c.creator_id, c.status
    INTO v_campaign
  FROM public.campaigns c
  WHERE c.id = v_campaign_id
  FOR SHARE;

  IF NOT FOUND OR v_campaign.creator_id <> v_actor_id THEN
    RAISE EXCEPTION 'Submission % not found or caller is not the campaign owner.', p_submission_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_campaign.status NOT IN ('active', 'paused', 'settling') THEN
    RAISE EXCEPTION 'Submissions can only be reviewed while campaign % is active, paused, or settling (current status: %).',
      v_campaign.id, v_campaign.status
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT s.id, s.status
    INTO v_sub
  FROM public.submissions s
  WHERE s.id = p_submission_id
  FOR NO KEY UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission % not found.', p_submission_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_sub.status <> 'pending_review' THEN
    RAISE EXCEPTION 'Only pending_review submissions can be reviewed (current status: %).', v_sub.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_decision = 'approve' THEN
    v_new_status := 'approved';
    UPDATE public.submissions
    SET
      status = 'approved',
      reviewed_by = v_actor_id,
      reviewed_at = now(),
      approved_at = now(),
      rejection_code = NULL,
      rejection_reason = NULL
    WHERE id = p_submission_id
      AND status = 'pending_review';
  ELSE
    v_new_status := 'rejected';
    UPDATE public.submissions
    SET
      status = 'rejected',
      reviewed_by = v_actor_id,
      reviewed_at = now(),
      rejection_code = v_code,
      rejection_reason = v_reason
    WHERE id = p_submission_id
      AND status = 'pending_review';
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission % state changed concurrently.', p_submission_id
      USING ERRCODE = 'serialization_failure';
  END IF;

  RETURN v_new_status;
END;
$$;

REVOKE ALL ON FUNCTION public.review_submission(uuid, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.review_submission(uuid, text, text, text) TO authenticated, service_role;

-- 5d. Editor withdrawal of own submission (§5.2, §8):
--     Post remains permanently locked in submissions against resubmission.
CREATE OR REPLACE FUNCTION public.withdraw_submission(
  p_submission_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_campaign_id uuid;
  v_editor_id uuid;
  v_sub record;
  v_ok integer;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication is required.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_submission_id IS NULL THEN
    RAISE EXCEPTION 'p_submission_id is required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT 1
    INTO v_ok
  FROM public.profiles p
  WHERE p.id = v_actor_id
    AND p.status = 'active'
    AND p.account_scope = 'member'
    AND p.is_editor
    AND NOT EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = p.id
    )
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Caller must have an active editor profile.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Read immutable campaign_id & editor_id first so locks follow global hierarchy:
  -- profiles -> campaigns -> submissions (-> ledger_accounts in later Ledger migration).
  SELECT s.campaign_id, s.editor_id
    INTO v_campaign_id, v_editor_id
  FROM public.submissions s
  WHERE s.id = p_submission_id;

  IF NOT FOUND OR v_editor_id <> v_actor_id THEN
    RAISE EXCEPTION 'Submission % not found or not owned by caller.', p_submission_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT 1
    INTO v_ok
  FROM public.campaigns c
  WHERE c.id = v_campaign_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target campaign % not found.', v_campaign_id
      USING ERRCODE = 'no_data_found';
  END IF;

  SELECT s.id, s.editor_id, s.status, s.reward_accrued_paise, s.reward_finalized_paise
    INTO v_sub
  FROM public.submissions s
  WHERE s.id = p_submission_id
  FOR NO KEY UPDATE;

  IF NOT FOUND OR v_sub.editor_id <> v_actor_id THEN
    RAISE EXCEPTION 'Submission % not found or not owned by caller.', p_submission_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_sub.status NOT IN ('pending_review', 'approved') THEN
    RAISE EXCEPTION 'Only pending_review or approved submissions can be withdrawn (current status: %).', v_sub.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- Fail closed if unfinalised accrual exists before ledger reward_reversal is provisioned.
  IF v_sub.reward_accrued_paise > v_sub.reward_finalized_paise THEN
    RAISE EXCEPTION 'Cannot withdraw submission with unfinalized reward accrual until ledger reversal is provisioned.'
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.submissions
  SET status = 'withdrawn'
  WHERE id = p_submission_id
    AND status = v_sub.status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submission % state changed concurrently.', p_submission_id
      USING ERRCODE = 'serialization_failure';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.withdraw_submission(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.withdraw_submission(uuid) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 6. Tier 3 service-role-only marketplace functions (§5.2)
-- ----------------------------------------------------------------------------

-- 6a. Verify an editor's social account claim (§5.2):
--     - oauth / bio_code: p_actor_id must be the active editor owning the claim.
--     - manual: p_actor_id must be an active admin (not the account owner).
CREATE OR REPLACE FUNCTION public.verify_social_account(
  p_social_account_id uuid,
  p_actor_id uuid,
  p_platform_user_id text,
  p_verification_method text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_method text := btrim(coalesce(p_verification_method, ''));
  v_platform_uid text := btrim(coalesce(p_platform_user_id, ''));
  v_owner_id uuid;
  v_account record;
  v_ok integer;
BEGIN
  IF p_social_account_id IS NULL OR p_actor_id IS NULL THEN
    RAISE EXCEPTION 'p_social_account_id and p_actor_id are required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_method NOT IN ('oauth', 'bio_code', 'manual') THEN
    RAISE EXCEPTION 'Invalid verification_method: %.', v_method
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_platform_uid = '' THEN
    RAISE EXCEPTION 'p_platform_user_id is required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Read immutable editor_id first so locks follow global order: admin_users -> profiles -> social_accounts.
  SELECT sa.editor_id
    INTO v_owner_id
  FROM public.social_accounts sa
  WHERE sa.id = p_social_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Social account % not found.', p_social_account_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_method IN ('oauth', 'bio_code') AND v_owner_id <> p_actor_id THEN
    RAISE EXCEPTION 'Social account % does not belong to caller %.', p_social_account_id, p_actor_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_method = 'manual' AND v_owner_id = p_actor_id THEN
    RAISE EXCEPTION 'Admin cannot manually verify their own account.'
      USING ERRCODE = 'check_violation';
  END IF;

  -- If manual verification, lock admin_users -> profiles in Migration 1 order first.
  IF v_method = 'manual' THEN
    SELECT 1
      INTO v_ok
    FROM public.admin_users au
    WHERE au.user_id = p_actor_id
      AND au.revoked_at IS NULL
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Manual social verification requires an active admin actor (%).', p_actor_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    SELECT 1
      INTO v_ok
    FROM public.profiles ap
    WHERE ap.id = p_actor_id
      AND ap.account_scope = 'admin'
      AND NOT ap.is_creator
      AND NOT ap.is_editor
      AND ap.status = 'active'
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Manual social verification requires an active admin actor (%).', p_actor_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- Lock account owner profile FOR SHARE before locking social_accounts row.
  SELECT 1
    INTO v_ok
  FROM public.profiles ep
  WHERE ep.id = v_owner_id
    AND ep.status = 'active'
    AND ep.account_scope = 'member'
    AND ep.is_editor
    AND NOT EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = ep.id
    )
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Owner (%) of social account % is not an active editor.', v_owner_id, p_social_account_id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT sa.id, sa.editor_id, sa.platform, sa.platform_user_id, sa.verification_status
    INTO v_account
  FROM public.social_accounts sa
  WHERE sa.id = p_social_account_id
  FOR NO KEY UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Social account % not found.', p_social_account_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_account.verification_status NOT IN ('unverified', 'pending') THEN
    RAISE EXCEPTION 'Social account % cannot be verified from status %.', p_social_account_id, v_account.verification_status
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_account.platform_user_id <> v_platform_uid THEN
    RAISE EXCEPTION 'Verified platform_user_id (%) does not match claimed platform_user_id (%).',
      v_platform_uid, v_account.platform_user_id
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.social_accounts
  SET
    verification_status = 'verified',
    verification_method = v_method,
    verified_at = now()
  WHERE id = p_social_account_id
    AND verification_status = v_account.verification_status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Social account % state changed concurrently; retry verification.', p_social_account_id
      USING ERRCODE = 'serialization_failure';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.verify_social_account(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verify_social_account(uuid, uuid, text, text) TO service_role;

-- 6b. Create a verified post submission (§5.2, §2.4, §9):
--     Snapshots handle/profile_url from verified social_accounts; duplicate posts fail closed.
CREATE OR REPLACE FUNCTION public.create_submission(
  p_actor_id uuid,
  p_campaign_id uuid,
  p_social_account_id uuid,
  p_post_url text,
  p_normalized_url text,
  p_external_post_id text,
  p_author_platform_id text,
  p_posted_at timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_post_url text := btrim(coalesce(p_post_url, ''));
  v_norm_url text := btrim(coalesce(p_normalized_url, ''));
  v_ext_post_id text := btrim(coalesce(p_external_post_id, ''));
  v_author_pid text := btrim(coalesce(p_author_platform_id, ''));
  v_social record;
  v_campaign record;
  v_member record;
  v_submission_id uuid;
  v_ok integer;
BEGIN
  IF p_actor_id IS NULL OR p_campaign_id IS NULL OR p_social_account_id IS NULL OR p_posted_at IS NULL THEN
    RAISE EXCEPTION 'p_actor_id, p_campaign_id, p_social_account_id, and p_posted_at are required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_post_url !~ '^https://[^[:space:]]+$' OR v_norm_url !~ '^https://[^[:space:]]+$' THEN
    RAISE EXCEPTION 'p_post_url and p_normalized_url must be valid https:// URLs.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_ext_post_id = '' OR v_author_pid = '' THEN
    RAISE EXCEPTION 'p_external_post_id and p_author_platform_id are required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Lock order: profiles -> social_accounts -> campaigns -> campaign_members
  SELECT 1
    INTO v_ok
  FROM public.profiles p
  WHERE p.id = p_actor_id
    AND p.status = 'active'
    AND p.account_scope = 'member'
    AND p.is_editor
    AND NOT EXISTS (
      SELECT 1
      FROM public.admin_users au
      WHERE au.user_id = p.id
    )
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Actor % must have an active editor profile.', p_actor_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT sa.id, sa.editor_id, sa.platform, sa.platform_user_id, sa.handle, sa.profile_url, sa.verification_status
    INTO v_social
  FROM public.social_accounts sa
  WHERE sa.id = p_social_account_id
  FOR SHARE;

  IF NOT FOUND OR v_social.editor_id <> p_actor_id THEN
    RAISE EXCEPTION 'Social account % not found or not owned by actor %.', p_social_account_id, p_actor_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_social.verification_status <> 'verified' THEN
    RAISE EXCEPTION 'Social account % must be verified before submitting.', p_social_account_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_social.platform_user_id <> v_author_pid THEN
    RAISE EXCEPTION 'Post author_platform_id (%) does not match verified social account platform_user_id (%).',
      v_author_pid, v_social.platform_user_id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT c.id, c.creator_id, c.campaign_type, c.status, c.starts_at, c.ends_at, c.allowed_platforms
    INTO v_campaign
  FROM public.campaigns c
  WHERE c.id = p_campaign_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign % not found.', p_campaign_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_campaign.creator_id = p_actor_id THEN
    RAISE EXCEPTION 'Campaign creator (%) cannot submit to their own campaign (%).', p_actor_id, p_campaign_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_campaign.status <> 'active'
     OR now() < v_campaign.starts_at
     OR now() >= v_campaign.ends_at
     OR v_campaign.campaign_type <> 'organic' THEN
    RAISE EXCEPTION 'Campaign % is not currently accepting new submissions.', p_campaign_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT (v_social.platform = ANY(v_campaign.allowed_platforms)) THEN
    RAISE EXCEPTION 'Platform % is not allowed on campaign %.', v_social.platform, p_campaign_id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT cm.status, cm.joined_at
    INTO v_member
  FROM public.campaign_members cm
  WHERE cm.campaign_id = p_campaign_id
    AND cm.editor_id = p_actor_id
  FOR SHARE;

  IF NOT FOUND OR v_member.status <> 'active' THEN
    RAISE EXCEPTION 'Actor % does not hold an active membership on campaign %.', p_actor_id, p_campaign_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_posted_at < v_member.joined_at THEN
    RAISE EXCEPTION 'Post published timestamp (%) must be on or after campaign joined_at (%).',
      p_posted_at, v_member.joined_at
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_posted_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'Post published timestamp (%) cannot be in the future.', p_posted_at
      USING ERRCODE = 'check_violation';
  END IF;

  -- Domain duplicate check (never treated as an idempotent retry — §5.1, §5.2, §9).
  IF EXISTS (
    SELECT 1
    FROM public.submissions s
    WHERE (s.platform = v_social.platform AND s.external_post_id = v_ext_post_id)
       OR s.normalized_url = v_norm_url
  ) THEN
    RAISE EXCEPTION 'This social post has already been submitted and cannot be submitted again.'
      USING ERRCODE = 'unique_violation';
  END IF;

  INSERT INTO public.submissions (
    campaign_id,
    editor_id,
    social_account_id,
    platform,
    author_handle,
    author_profile_url,
    post_url,
    normalized_url,
    external_post_id,
    posted_at,
    status
  )
  VALUES (
    p_campaign_id,
    p_actor_id,
    p_social_account_id,
    v_social.platform,
    v_social.handle,
    v_social.profile_url,
    v_post_url,
    v_norm_url,
    v_ext_post_id,
    p_posted_at,
    'pending_review'
  )
  RETURNING id INTO v_submission_id;

  RETURN v_submission_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_submission(uuid, uuid, uuid, text, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_submission(uuid, uuid, uuid, text, text, text, text, timestamptz) TO service_role;

-- 6c. Admin campaign status control (§5.2, §8):
--     Supports suspend (active/paused -> suspended), resume (suspended -> suspended_from/active),
--     and close to settling (active/paused/suspended -> settling).
CREATE OR REPLACE FUNCTION public.admin_set_campaign_status(
  p_campaign_id uuid,
  p_admin_id uuid,
  p_new_status public.campaign_status,
  p_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_reason text := btrim(coalesce(p_reason, ''));
  v_campaign record;
  v_ok integer;
BEGIN
  IF p_campaign_id IS NULL OR p_admin_id IS NULL OR p_new_status IS NULL THEN
    RAISE EXCEPTION 'p_campaign_id, p_admin_id, and p_new_status are required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF char_length(v_reason) < 5 OR char_length(v_reason) > 2000 THEN
    RAISE EXCEPTION 'A reason between 5 and 2000 characters is required.'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Lock active admin in Migration 1 order: admin_users -> profiles.
  SELECT 1
    INTO v_ok
  FROM public.admin_users au
  WHERE au.user_id = p_admin_id
    AND au.revoked_at IS NULL
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'p_admin_id (%) must be an active admin.', p_admin_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT 1
    INTO v_ok
  FROM public.profiles ap
  WHERE ap.id = p_admin_id
    AND ap.account_scope = 'admin'
    AND NOT ap.is_creator
    AND NOT ap.is_editor
    AND ap.status = 'active'
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'p_admin_id (%) must be an active admin.', p_admin_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT c.id, c.creator_id, c.status, c.suspended_from, c.ends_at
    INTO v_campaign
  FROM public.campaigns c
  WHERE c.id = p_campaign_id
  FOR NO KEY UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign % not found.', p_campaign_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_campaign.creator_id = p_admin_id THEN
    RAISE EXCEPTION 'Admin (%) cannot act on a campaign where they are a party.', p_admin_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT (
    (v_campaign.status IN ('active', 'paused') AND p_new_status = 'suspended')
    OR (v_campaign.status = 'suspended' AND v_campaign.suspended_from IS NOT NULL AND p_new_status = v_campaign.suspended_from)
    OR (v_campaign.status IN ('active', 'paused', 'suspended') AND p_new_status = 'settling')
  ) THEN
    RAISE EXCEPTION 'Illegal admin campaign status transition: % -> %.', v_campaign.status, p_new_status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_new_status = 'active' AND v_campaign.ends_at <= now() THEN
    RAISE EXCEPTION 'Cannot resume campaign % to active because ends_at has passed; transition to settling instead.', p_campaign_id
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.campaigns
  SET
    status = p_new_status,
    suspended_from = CASE WHEN p_new_status = 'suspended' THEN v_campaign.status ELSE NULL END,
    closed_at = CASE WHEN p_new_status = 'settling' THEN coalesce(closed_at, now()) ELSE closed_at END
  WHERE id = p_campaign_id
    AND status = v_campaign.status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Campaign % state changed concurrently.', p_campaign_id
      USING ERRCODE = 'serialization_failure';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_campaign_status(uuid, uuid, public.campaign_status, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_set_campaign_status(uuid, uuid, public.campaign_status, text) TO service_role;

-- ----------------------------------------------------------------------------
-- 7. Row Level Security, table/column privileges & RLS policies (§0 C5/C6, §5.3)
-- ----------------------------------------------------------------------------

ALTER TABLE public.social_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.social_accounts FORCE ROW LEVEL SECURITY;

ALTER TABLE public.campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaigns FORCE ROW LEVEL SECURITY;

ALTER TABLE public.campaign_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_assets FORCE ROW LEVEL SECURITY;

ALTER TABLE public.campaign_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_members FORCE ROW LEVEL SECURITY;

ALTER TABLE public.submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.submissions FORCE ROW LEVEL SECURITY;

-- Clear any default privileges granted by Supabase's public schema defaults.
REVOKE ALL ON TABLE public.social_accounts FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.campaigns FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.campaign_assets FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.campaign_members FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.submissions FROM PUBLIC, anon, authenticated, service_role;

-- 7a. social_accounts grants & policies (§5.3: creators have NO access; editors R own, W-T1 insert unverified & delete unused; admins R all)
GRANT SELECT ON TABLE public.social_accounts TO authenticated;
GRANT INSERT (
  editor_id,
  platform,
  platform_user_id,
  handle,
  profile_url
) ON TABLE public.social_accounts TO authenticated;
GRANT DELETE ON TABLE public.social_accounts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.social_accounts TO service_role;

CREATE POLICY social_accounts_select_own_or_admin
  ON public.social_accounts
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND (
      editor_id = auth.uid()
      OR public.is_admin()
    )
  );

CREATE POLICY social_accounts_insert_own_unverified
  ON public.social_accounts
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND editor_id = auth.uid()
    AND public.has_role('editor')
    AND verification_status = 'unverified'
    AND verification_method IS NULL
    AND verified_at IS NULL
  );

CREATE POLICY social_accounts_delete_own_unused
  ON public.social_accounts
  FOR DELETE
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND editor_id = auth.uid()
    AND public.has_role('editor')
    AND verification_status <> 'revoked'
    AND NOT public.social_account_has_submissions(id)
  );

-- 7b. campaigns grants & policies (§5.1, §5.3, D10: status, reward_pool_paise, platform_fee_bps, activated_at, closed_at excluded from client grants)
GRANT SELECT ON TABLE public.campaigns TO authenticated;
GRANT INSERT (
  creator_id,
  title,
  description,
  campaign_type,
  cpm_paise,
  per_submission_cap_paise,
  starts_at,
  ends_at,
  requirements,
  allowed_platforms
) ON TABLE public.campaigns TO authenticated;
GRANT UPDATE (
  title,
  description,
  campaign_type,
  cpm_paise,
  per_submission_cap_paise,
  starts_at,
  ends_at,
  requirements,
  allowed_platforms
) ON TABLE public.campaigns TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.campaigns TO service_role;

CREATE POLICY campaigns_select_authenticated
  ON public.campaigns
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND (
      creator_id = auth.uid()
      OR status IN ('active', 'paused', 'settling', 'completed')
      OR public.is_admin()
    )
  );

CREATE POLICY campaigns_insert_own_draft
  ON public.campaigns
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND creator_id = auth.uid()
    AND public.has_role('creator')
    AND status = 'draft'
  );

CREATE POLICY campaigns_update_own_draft
  ON public.campaigns
  FOR UPDATE
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND creator_id = auth.uid()
    AND public.has_role('creator')
    AND status = 'draft'
  )
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND creator_id = auth.uid()
    AND public.has_role('creator')
    AND status = 'draft'
  );

-- 7c. campaign_assets grants & policies (§5.3: creator R own, W-T1 insert/delete while draft/active/paused; active member R while active/paused/settling; admin R all)
GRANT SELECT ON TABLE public.campaign_assets TO authenticated;
GRANT INSERT (
  campaign_id,
  kind,
  title,
  file_name,
  storage_path,
  external_url,
  mime_type,
  size_bytes,
  duration_seconds,
  created_by
) ON TABLE public.campaign_assets TO authenticated;
GRANT DELETE ON TABLE public.campaign_assets TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.campaign_assets TO service_role;

CREATE POLICY campaign_assets_select_authorized
  ON public.campaign_assets
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND (
      public.owns_campaign(campaign_id)
      OR public.campaign_assets_visible_to_member(campaign_id)
      OR public.is_admin()
    )
  );

CREATE POLICY campaign_assets_insert_owner
  ON public.campaign_assets
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND created_by = auth.uid()
    AND public.can_manage_campaign_assets(campaign_id)
  );

CREATE POLICY campaign_assets_delete_owner
  ON public.campaign_assets
  FOR DELETE
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND public.can_manage_campaign_assets(campaign_id)
  );

-- 7d. campaign_members grants & policies (§5.3: creator R own campaigns; editor R own, W-T1 join/leave/rejoin; removal via Tier 2; no deletes)
GRANT SELECT ON TABLE public.campaign_members TO authenticated;
GRANT INSERT (
  campaign_id,
  editor_id,
  status
) ON TABLE public.campaign_members TO authenticated;
GRANT UPDATE (
  status
) ON TABLE public.campaign_members TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.campaign_members TO service_role;

CREATE POLICY campaign_members_select_party_or_admin
  ON public.campaign_members
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND (
      editor_id = auth.uid()
      OR public.owns_campaign(campaign_id)
      OR public.is_admin()
    )
  );

CREATE POLICY campaign_members_insert_join
  ON public.campaign_members
  FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND editor_id = auth.uid()
    AND status = 'active'
    AND public.has_role('editor')
    AND NOT public.owns_campaign(campaign_id)
    AND public.campaign_accepts_activity(campaign_id)
  );

CREATE POLICY campaign_members_update_own_status
  ON public.campaign_members
  FOR UPDATE
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND editor_id = auth.uid()
    AND public.has_role('editor')
    AND status IN ('active', 'left')
  )
  WITH CHECK (
    auth.uid() IS NOT NULL
    AND editor_id = auth.uid()
    AND public.has_role('editor')
    AND (
      status = 'left'
      OR (
        status = 'active'
        AND NOT public.owns_campaign(campaign_id)
        AND public.campaign_accepts_activity(campaign_id)
      )
    )
  );

-- 7e. submissions grants & policies (§5.3: read-only to editor, campaign creator, and admin; writes strictly via Tier 2 / Tier 3; no deletes)
GRANT SELECT ON TABLE public.submissions TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.submissions TO service_role;

CREATE POLICY submissions_select_party_or_admin
  ON public.submissions
  FOR SELECT
  TO authenticated
  USING (
    auth.uid() IS NOT NULL
    AND (
      editor_id = auth.uid()
      OR public.owns_campaign(campaign_id)
      OR public.is_admin()
    )
  );
