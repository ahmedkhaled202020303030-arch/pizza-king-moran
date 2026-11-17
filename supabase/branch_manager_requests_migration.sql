-- Secure self-registration requests for branch managers.
-- Run once in Supabase Dashboard > SQL Editor.

create table if not exists public.branch_manager_requests (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) between 3 and 100),
  phone text not null check (length(trim(phone)) between 5 and 20),
  username text not null,
  requested_branch text not null,
  assigned_branch text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);

create unique index if not exists branch_manager_requests_username_unique
  on public.branch_manager_requests (lower(username));

create index if not exists branch_manager_requests_status_created_idx
  on public.branch_manager_requests (status, created_at desc);

alter table public.branch_manager_requests enable row level security;
revoke all on public.branch_manager_requests from anon, authenticated;
grant all on public.branch_manager_requests to service_role;

-- No browser client can create, read, approve, or reject requests.
-- All operations are performed by the branch-manager-accounts Edge Function
-- after validating the main administrator's Supabase session.
