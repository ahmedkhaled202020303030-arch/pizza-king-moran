-- Geofence for branch attendance: Abbas El Akkad
-- Run once in Supabase SQL Editor after confirming the branch entrance coordinates.
-- Radius is 100 meters. Validation runs server-side for both check-in and check-out.

create table if not exists public.branch_attendance_locations (
  branch text primary key,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  radius_m integer not null default 100 check (radius_m between 25 and 1000),
  updated_at timestamptz not null default now()
);

alter table public.branch_attendance_locations enable row level security;
revoke all on public.branch_attendance_locations from anon, authenticated;

insert into public.branch_attendance_locations (branch, latitude, longitude, radius_m)
values ('عباس العقاد', 30.061883, 31.332486, 100)
on conflict (branch) do update
set latitude = excluded.latitude,
    longitude = excluded.longitude,
    radius_m = excluded.radius_m,
    updated_at = now();

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
  v_location public.branch_attendance_locations;
  v_distance double precision;
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

  select * into v_location
  from public.branch_attendance_locations
  where branch = v_branch;

  if not found then
    raise exception 'لم يتم إعداد موقع الحضور لهذا الفرع بعد';
  end if;

  v_distance := 6371000 * 2 * asin(sqrt(
    power(sin(radians(p_lat - v_location.latitude) / 2), 2) +
    cos(radians(v_location.latitude)) * cos(radians(p_lat)) *
    power(sin(radians(p_lng - v_location.longitude) / 2), 2)
  ));

  if v_distance > v_location.radius_m then
    raise exception 'أنت خارج نطاق الفرع المسموح. المسافة التقريبية: % متر', round(v_distance)::integer;
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
  v_branch text;
  v_location public.branch_attendance_locations;
  v_distance double precision;
begin
  if auth.uid() is null or public.current_profile_role() <> 'branch_manager' then
    raise exception 'غير مصرح بتسجيل الانصراف لهذا الحساب';
  end if;

  v_branch := public.current_profile_branch();
  if v_branch is null or length(trim(v_branch)) = 0 then
    raise exception 'الحساب غير مرتبط بفرع';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'إحداثيات الموقع غير صحيحة';
  end if;

  select * into v_location
  from public.branch_attendance_locations
  where branch = v_branch;

  if not found then
    raise exception 'لم يتم إعداد موقع الحضور لهذا الفرع بعد';
  end if;

  v_distance := 6371000 * 2 * asin(sqrt(
    power(sin(radians(p_lat - v_location.latitude) / 2), 2) +
    cos(radians(v_location.latitude)) * cos(radians(p_lat)) *
    power(sin(radians(p_lng - v_location.longitude) / 2), 2)
  ));

  if v_distance > v_location.radius_m then
    raise exception 'أنت خارج نطاق الفرع المسموح. المسافة التقريبية: % متر', round(v_distance)::integer;
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
