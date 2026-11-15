-- Pizza King & Morin: Branch Staff Directory
-- Run once in Supabase Dashboard > SQL Editor.
-- This is additive and does not change customers, profiles, authentication, or existing policies.

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid() and p.role = 'admin'
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

create table if not exists public.branch_staff (
  id uuid primary key default gen_random_uuid(),
  staff_name text not null check (length(trim(staff_name)) > 0),
  phone text not null check (length(trim(phone)) > 0),
  branch text not null check (length(trim(branch)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.branch_staff enable row level security;

drop policy if exists "Authenticated users read branch staff" on public.branch_staff;
create policy "Authenticated users read branch staff"
on public.branch_staff
for select to authenticated
using (true);

drop policy if exists "Admins insert branch staff" on public.branch_staff;
create policy "Admins insert branch staff"
on public.branch_staff
for insert to authenticated
with check (public.is_admin());

drop policy if exists "Admins update branch staff" on public.branch_staff;
create policy "Admins update branch staff"
on public.branch_staff
for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Admins delete branch staff" on public.branch_staff;
create policy "Admins delete branch staff"
on public.branch_staff
for delete to authenticated
using (public.is_admin());

revoke all on public.branch_staff from anon, authenticated;
grant select, insert, update, delete on public.branch_staff to authenticated;

create or replace function public.set_branch_staff_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists branch_staff_set_updated_at on public.branch_staff;
create trigger branch_staff_set_updated_at
before update on public.branch_staff
for each row execute function public.set_branch_staff_updated_at();
