-- Read-only Operations Manager role and secure shared-code sign-in.
-- Run this migration in Supabase SQL Editor after deploying the frontend and Edge Function.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check
  check (role = any (array['admin'::text,'guest'::text,'branch_manager'::text,'operations_manager'::text]));

-- Used only by the Edge Function (service role); no client access.
create table if not exists public.operations_login_attempts (
  id bigint generated always as identity primary key,
  ip_hash text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists operations_login_attempts_ip_time_idx
  on public.operations_login_attempts (ip_hash, attempted_at desc);
alter table public.operations_login_attempts enable row level security;
revoke all on public.operations_login_attempts from anon, authenticated;

-- Operations managers can read all profiles (for attendance names), but receive no write policy.
grant select on public.profiles to authenticated;
drop policy if exists "Operations managers read profiles" on public.profiles;
create policy "Operations managers read profiles"
on public.profiles for select to authenticated
using (public.current_profile_role() = 'operations_manager');

-- Customers: read-only access to the full customer directory.
drop policy if exists "Operations managers read customers" on public.customers;
create policy "Operations managers read customers"
on public.customers for select to authenticated
using (public.current_profile_role() = 'operations_manager');
grant select on public.customers to authenticated;

-- Complaints and activity log: read-only.
drop policy if exists "Operations managers read complaints" on public.customer_complaints;
create policy "Operations managers read complaints"
on public.customer_complaints for select to authenticated
using (public.current_profile_role() = 'operations_manager');
grant select on public.customer_complaints to authenticated;

drop policy if exists "Operations managers read activity logs" on public.admin_activity_logs;
create policy "Operations managers read activity logs"
on public.admin_activity_logs for select to authenticated
using (public.current_profile_role() = 'operations_manager');
grant select on public.admin_activity_logs to authenticated;

-- All branches' attendance, without adding any insert/update/delete policy.
drop policy if exists "Operations managers read all attendance" on public.branch_attendance;
create policy "Operations managers read all attendance"
on public.branch_attendance for select to authenticated
using (public.current_profile_role() = 'operations_manager');
grant select on public.branch_attendance to authenticated;

-- Read access to customer audio attachments used by customer profiles.
drop policy if exists "Operations managers read customer audio" on storage.objects;
create policy "Operations managers read customer audio"
on storage.objects for select to authenticated
using (
  bucket_id = 'customer-audio'
  and public.current_profile_role() = 'operations_manager'
);

-- The existing branch_staff migration already permits authenticated SELECT
-- and keeps all write policies restricted to the main admin.
