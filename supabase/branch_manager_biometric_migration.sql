-- WebAuthn / phone-native biometric verification for Pizza King & Morin branch attendance.
-- Apply after branch_attendance_migration.sql and branch_attendance_geofence.sql.
-- This is additive: it preserves existing attendance records and branch configuration.

create table if not exists public.branch_manager_webauthn_credentials (
  credential_id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  public_key text not null,
  counter bigint not null default 0,
  transports text[] not null default '{}',
  device_type text,
  backed_up boolean not null default false,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index if not exists branch_manager_webauthn_user_idx
  on public.branch_manager_webauthn_credentials(user_id);

create table if not exists public.branch_manager_webauthn_challenges (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  challenge text not null,
  purpose text not null check (purpose in ('registration','authentication')),
  attendance_kind text check (attendance_kind in ('check_in','check_out')),
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists branch_manager_webauthn_challenges_expiry_idx
  on public.branch_manager_webauthn_challenges(expires_at);

create table if not exists public.branch_attendance_biometric_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  attendance_kind text not null check (attendance_kind in ('check_in','check_out')),
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.branch_manager_webauthn_credentials enable row level security;
alter table public.branch_manager_webauthn_challenges enable row level security;
alter table public.branch_attendance_biometric_tickets enable row level security;
revoke all on public.branch_manager_webauthn_credentials from anon, authenticated, public;
revoke all on public.branch_manager_webauthn_challenges from anon, authenticated, public;
revoke all on public.branch_attendance_biometric_tickets from anon, authenticated, public;

-- A ticket is short-lived, single-use, and bound to the authenticated manager and action.
create or replace function public.consume_branch_attendance_biometric_ticket(
  p_biometric_ticket uuid,
  p_attendance_kind text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket public.branch_attendance_biometric_tickets;
begin
  if auth.uid() is null or public.current_profile_role() <> 'branch_manager' then
    raise exception 'غير مصرح لهذا الحساب';
  end if;
  if p_biometric_ticket is null or p_attendance_kind not in ('check_in','check_out') then
    raise exception 'يلزم التحقق بالبصمة قبل تسجيل الحركة';
  end if;

  select * into v_ticket
  from public.branch_attendance_biometric_tickets
  where id = p_biometric_ticket
    and user_id = auth.uid()
    and attendance_kind = p_attendance_kind
    and used_at is null
    and expires_at > now()
  for update;

  if not found then
    raise exception 'انتهت صلاحية التحقق بالبصمة أو تم استخدامه بالفعل. أعد المحاولة.';
  end if;

  update public.branch_attendance_biometric_tickets
  set used_at = now()
  where id = v_ticket.id;
end;
$$;

create or replace function public.record_branch_check_in_biometric(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision,
  p_biometric_ticket uuid
)
returns public.branch_attendance
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.branch_attendance;
begin
  perform public.consume_branch_attendance_biometric_ticket(p_biometric_ticket, 'check_in');
  select * into v_row
  from public.record_branch_check_in(p_lat, p_lng, p_accuracy_m);
  return v_row;
end;
$$;

create or replace function public.record_branch_check_out_biometric(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision,
  p_biometric_ticket uuid
)
returns public.branch_attendance
language plpgsql
security definer
set search_path = public
as $$
declare v_row public.branch_attendance;
begin
  perform public.consume_branch_attendance_biometric_ticket(p_biometric_ticket, 'check_out');
  select * into v_row
  from public.record_branch_check_out(p_lat, p_lng, p_accuracy_m);
  return v_row;
end;
$$;

-- Disable the old direct RPC entry points so a manager cannot bypass biometric verification.
revoke all on function public.record_branch_check_in(double precision,double precision,double precision) from public, anon, authenticated;
revoke all on function public.record_branch_check_out(double precision,double precision,double precision) from public, anon, authenticated;
revoke all on function public.consume_branch_attendance_biometric_ticket(uuid,text) from public, anon, authenticated;
grant execute on function public.record_branch_check_in_biometric(double precision,double precision,double precision,uuid) to authenticated;
grant execute on function public.record_branch_check_out_biometric(double precision,double precision,double precision,uuid) to authenticated;

-- Remove expired one-time material opportunistically; no attendance history is touched.
delete from public.branch_manager_webauthn_challenges where expires_at < now() - interval '1 day';
delete from public.branch_attendance_biometric_tickets where expires_at < now() - interval '1 day';
