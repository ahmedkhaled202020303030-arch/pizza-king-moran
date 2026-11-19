-- Pizza King & Morin: Delivery representative foundation
-- Additive migration. Does not modify existing attendance, biometric, or manager-account tables.
-- Run in Supabase Dashboard > SQL Editor after reviewing this file.

create table if not exists public.delivery_rep_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) between 3 and 100),
  phone text not null check (length(trim(phone)) between 5 and 20),
  username text not null,
  branch text not null check (length(trim(branch)) > 0),
  is_active boolean not null default true,
  availability_status text not null default 'unavailable'
    check (availability_status in ('available', 'busy', 'unavailable')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists delivery_rep_profiles_username_unique
  on public.delivery_rep_profiles (lower(username));
create index if not exists delivery_rep_profiles_branch_status_idx
  on public.delivery_rep_profiles (branch, availability_status)
  where is_active = true;

create table if not exists public.delivery_rep_locations (
  user_id uuid primary key references public.delivery_rep_profiles(user_id) on delete cascade,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_m double precision,
  recorded_at timestamptz not null default now()
);
create index if not exists delivery_rep_locations_recorded_at_idx
  on public.delivery_rep_locations (recorded_at desc);

create or replace function public.current_delivery_rep_branch()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select d.branch
  from public.delivery_rep_profiles d
  where d.user_id = auth.uid() and d.is_active = true
  limit 1;
$$;

revoke all on function public.current_delivery_rep_branch() from public;
grant execute on function public.current_delivery_rep_branch() to authenticated;

alter table public.delivery_rep_profiles enable row level security;
alter table public.delivery_rep_locations enable row level security;

revoke all on public.delivery_rep_profiles from anon, authenticated;
revoke all on public.delivery_rep_locations from anon, authenticated;
grant select on public.delivery_rep_profiles to authenticated;
grant select on public.delivery_rep_locations to authenticated;

drop policy if exists "Delivery reps and managers read scoped rep profiles" on public.delivery_rep_profiles;
create policy "Delivery reps and managers read scoped rep profiles"
on public.delivery_rep_profiles
for select to authenticated
using (
  (public.current_profile_role() in ('admin', 'operations_manager'))
  or (
    public.current_profile_role() = 'branch_manager'
    and branch = public.current_profile_branch()
  )
  or user_id = auth.uid()
);

drop policy if exists "Delivery reps and managers read scoped locations" on public.delivery_rep_locations;
create policy "Delivery reps and managers read scoped locations"
on public.delivery_rep_locations
for select to authenticated
using (
  (public.current_profile_role() in ('admin', 'operations_manager'))
  or (
    public.current_profile_role() = 'branch_manager'
    and exists (
      select 1 from public.delivery_rep_profiles d
      where d.user_id = delivery_rep_locations.user_id
        and d.branch = public.current_profile_branch()
    )
  )
  or user_id = auth.uid()
);

drop policy if exists "Delivery reps update own location" on public.delivery_rep_locations;
create policy "Delivery reps update own location"
on public.delivery_rep_locations
for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.delivery_rep_profiles d
    where d.user_id = auth.uid()
      and d.is_active = true
      and d.availability_status in ('available', 'busy')
  )
);

drop policy if exists "Delivery reps modify own location" on public.delivery_rep_locations;
create policy "Delivery reps modify own location"
on public.delivery_rep_locations
for update to authenticated
using (user_id = auth.uid())
with check (
  user_id = auth.uid()
  and exists (
    select 1 from public.delivery_rep_profiles d
    where d.user_id = auth.uid()
      and d.is_active = true
      and d.availability_status in ('available', 'busy')
  )
);

create or replace function public.set_delivery_rep_status(p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if p_status not in ('available', 'busy', 'unavailable') then
    raise exception 'حالة المندوب غير صحيحة';
  end if;

  update public.delivery_rep_profiles
  set availability_status = p_status,
      updated_at = now()
  where user_id = auth.uid()
    and is_active = true;

  if not found then
    raise exception 'حساب المندوب غير مفعل';
  end if;

  if p_status = 'unavailable' then
    delete from public.delivery_rep_locations where user_id = auth.uid();
  end if;
end;
$$;

create or replace function public.update_delivery_rep_location(
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m double precision default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  if p_latitude is null or p_latitude not between -90 and 90
     or p_longitude is null or p_longitude not between -180 and 180 then
    raise exception 'إحداثيات الموقع غير صحيحة';
  end if;

  if not exists (
    select 1 from public.delivery_rep_profiles d
    where d.user_id = auth.uid()
      and d.is_active = true
      and d.availability_status in ('available', 'busy')
  ) then
    raise exception 'يجب أن تكون حالة المندوب متاح أو مشغول لتحديث الموقع';
  end if;

  insert into public.delivery_rep_locations (user_id, latitude, longitude, accuracy_m, recorded_at)
  values (auth.uid(), p_latitude, p_longitude, p_accuracy_m, now())
  on conflict (user_id) do update
    set latitude = excluded.latitude,
        longitude = excluded.longitude,
        accuracy_m = excluded.accuracy_m,
        recorded_at = now();
end;
$$;

revoke all on function public.set_delivery_rep_status(text) from public;
revoke all on function public.update_delivery_rep_location(double precision,double precision,double precision) from public;
grant execute on function public.set_delivery_rep_status(text) to authenticated;
grant execute on function public.update_delivery_rep_location(double precision,double precision,double precision) to authenticated;
