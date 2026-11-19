-- Delivery representative self-registration and manager approval workflow
-- Existing delivery representative accounts remain approved and active.
ALTER TABLE public.delivery_rep_profiles
  ALTER COLUMN created_by DROP NOT NULL;

ALTER TABLE public.delivery_rep_profiles
  ADD COLUMN IF NOT EXISTS approval_status text NOT NULL DEFAULT 'approved',
  ADD COLUMN IF NOT EXISTS reviewed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS rejection_reason text;

ALTER TABLE public.delivery_rep_profiles
  DROP CONSTRAINT IF EXISTS delivery_rep_profiles_approval_status_check;

ALTER TABLE public.delivery_rep_profiles
  ADD CONSTRAINT delivery_rep_profiles_approval_status_check
  CHECK (approval_status IN ('pending', 'approved', 'rejected'));

CREATE INDEX IF NOT EXISTS delivery_rep_profiles_pending_branch_idx
  ON public.delivery_rep_profiles (branch, created_at DESC)
  WHERE approval_status = 'pending';
