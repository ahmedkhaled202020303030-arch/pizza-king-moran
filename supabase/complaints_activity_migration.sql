-- Pizza King & Morin: complaints and admin activity log
-- Run this script once in Supabase Dashboard > SQL Editor.

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

create table if not exists public.customer_complaints (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  phone text,
  branch text not null,
  description text not null,
  status text not null default 'new'
    check (status in ('new','in_progress','resolved')),
  resolution_notes text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.admin_activity_logs (
  id bigint generated always as identity primary key,
  table_name text not null,
  record_id text,
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  actor_id uuid,
  summary jsonb,
  created_at timestamptz not null default now()
);

alter table public.customer_complaints enable row level security;
alter table public.admin_activity_logs enable row level security;

drop policy if exists "Admins manage complaints" on public.customer_complaints;
create policy "Admins manage complaints"
on public.customer_complaints
for all to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "Admins read activity logs" on public.admin_activity_logs;
create policy "Admins read activity logs"
on public.admin_activity_logs
for select to authenticated
using (public.is_admin());

revoke all on public.customer_complaints from anon, authenticated;
grant select, insert, update, delete on public.customer_complaints to authenticated;
revoke all on public.admin_activity_logs from anon, authenticated;
grant select on public.admin_activity_logs to authenticated;

create or replace function public.set_complaint_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists customer_complaints_set_updated_at on public.customer_complaints;
create trigger customer_complaints_set_updated_at
before update on public.customer_complaints
for each row execute function public.set_complaint_updated_at();

create or replace function public.capture_admin_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_data jsonb;
  row_id text;
begin
  if tg_op = 'DELETE' then
    row_data := to_jsonb(old);
    row_id := row_data ->> 'id';
  else
    row_data := to_jsonb(new);
    row_id := row_data ->> 'id';
  end if;

  insert into public.admin_activity_logs(table_name, record_id, action, actor_id, summary)
  values (
    tg_table_name,
    row_id,
    tg_op,
    auth.uid(),
    jsonb_build_object(
      'customer_name', row_data ->> 'customer_name',
      'branch', row_data ->> 'branch',
      'status', row_data ->> 'status'
    )
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists customers_activity_audit on public.customers;
create trigger customers_activity_audit
after insert or update or delete on public.customers
for each row execute function public.capture_admin_activity();

drop trigger if exists complaints_activity_audit on public.customer_complaints;
create trigger complaints_activity_audit
after insert or update or delete on public.customer_complaints
for each row execute function public.capture_admin_activity();
