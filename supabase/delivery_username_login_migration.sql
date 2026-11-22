-- Username-only delivery representative login compatibility.
-- Supabase Auth still requires an email-shaped internal identifier; it is never shown to reps.
alter table public.delivery_rep_profiles
  add column if not exists email text;

-- Keep previously created accounts eligible unless explicitly rejected.
update public.delivery_rep_profiles
set approval_status = 'approved'
where approval_status is null;

create index if not exists delivery_rep_profiles_username_login_idx
  on public.delivery_rep_profiles (lower(username));
