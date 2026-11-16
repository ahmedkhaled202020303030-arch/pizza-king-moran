-- Pizza King & Morin: branch manager attendance foundation
-- Run once in Supabase Dashboard > SQL Editor.
-- Additive migration: does not change customers, existing auth users, or their policies.

alter table public.profiles
  add column if not exists username text,
  add column if not exists branch text;

create unique index if not exists profiles_username_unique
  on public.profiles (lower(username))
  where username is not null;

create or replace function public.current_profile_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.role from public.profiles p where p.user_id = auth.uid() limit 1;
$$;

create or replace function public.current_profile_branch()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.branch from public.profiles p where p.user_id = auth.uid() limit 1;
$$;

revoke all on function public.current_profile_role() from public;
revoke all on function public.current_profile_branch() from public;
grant execute on function public.current_profile_role() to authenticated;
grant execute on function public.current_profile_branch() to authenticated;

create table if not exists public.branch_attendance (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  branch text not null check (length(trim(branch)) > 0),
  work_date date not null default ((now() at time zone 'Africa/Cairo')::date),
  check_in_at timestamptz not null,
  check_in_lat double precision not null check (check_in_lat between -90 and 90),
  check_in_lng double precision not null check (check_in_lng between -180 and 180),
  check_in_accuracy_m double precision,
  check_out_at timestamptz,
  check_out_lat double precision,
  check_out_lng double precision,
  check_out_accuracy_m double precision,
  created_at timestamptz not null default now(),
  constraint branch_attendance_checkout_after_checkin
    check (check_out_at is null or check_out_at >= check_in_at),
  constraint branch_attendance_checkout_coordinates
    check (
      (check_out_at is null and check_out_lat is null and check_out_lng is null)
      or
      (check_out_at is not null and check_out_lat between -90 and 90 and check_out_lng between -180 and 180)
    ),
  constraint branch_attendance_one_day_per_manager unique (user_id, work_date)
);

create index if not exists branch_attendance_branch_date_idx
  on public.branch_attendance (branch, work_date desc);
create index if not exists branch_attendance_user_date_idx
  on public.branch_attendance (user_id, work_date desc);

alter table public.branch_attendance enable row level security;
revoke all on public.branch_attendance from anon, authenticated;
grant select on public.branch_attendance to authenticated;

drop policy if exists "Managers see own attendance and admins see all" on public.branch_attendance;
create policy "Managers see own attendance and admins see all"
on public.branch_attendance
for select to authenticated
using (
  public.current_profile_role() = 'admin'
  or user_id = auth.uid()
);

create or replace function public.record_branch_check_in(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision default null
)
returns public.branch_attendance
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.branch_attendance;
  v_branch text;
begin
  if auth.uid() is null or public.current_profile_role() <> 'branch_manager' then
    raise exception 'غير مصرح بتسجيل الحضور لهذا الحساب';
  end if;

  v_branch := public.current_profile_branch();
  if v_branch is null or length(trim(v_branch)) = 0 then
    raise exception 'الحساب غير مرتبط بفرع';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'إحداثيات الموقع غير صحيحة';
  end if;

  insert into public.branch_attendance (
    user_id, branch, work_date, check_in_at,
    check_in_lat, check_in_lng, check_in_accuracy_m
  )
  values (
    auth.uid(), v_branch, (now() at time zone 'Africa/Cairo')::date, now(),
    p_lat, p_lng, p_accuracy_m
  )
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'تم تسجيل الحضور لهذا اليوم بالفعل';
end;
$$;

create or replace function public.record_branch_check_out(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision default null
)
returns public.branch_attendance
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.branch_attendance;
begin
  if auth.uid() is null or public.current_profile_role() <> 'branch_manager' then
    raise exception 'غير مصرح بتسجيل الانصراف لهذا الحساب';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'إحداثيات الموقع غير صحيحة';
  end if;

  update public.branch_attendance
  set check_out_at = now(),
      check_out_lat = p_lat,
      check_out_lng = p_lng,
      check_out_accuracy_m = p_accuracy_m
  where user_id = auth.uid()
    and work_date = (now() at time zone 'Africa/Cairo')::date
    and check_out_at is null
  returning * into v_row;

  if not found then
    raise exception 'لا يوجد حضور مفتوح لهذا اليوم أو تم تسجيل الانصراف بالفعل';
  end if;

  return v_row;
end;
$$;

revoke all on function public.record_branch_check_in(double precision,double precision,double precision) from public;
revoke all on function public.record_branch_check_out(double precision,double precision,double precision) from public;
grant execute on function public.record_branch_check_in(double precision,double precision,double precision) to authenticated;
grant execute on function public.record_branch_check_out(double precision,double precision,double precision) to authenticated;
