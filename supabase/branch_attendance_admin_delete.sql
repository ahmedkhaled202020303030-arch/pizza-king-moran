-- Allow only the main admin role to delete attendance records.
-- Run in Supabase SQL Editor after the frontend update is deployed.

grant delete on table public.branch_attendance to authenticated;

drop policy if exists "Only admins can delete attendance records" on public.branch_attendance;
create policy "Only admins can delete attendance records"
on public.branch_attendance
for delete
to authenticated
using (public.current_profile_role() = 'admin');
