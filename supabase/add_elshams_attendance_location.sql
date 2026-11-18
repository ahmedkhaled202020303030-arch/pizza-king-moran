-- Add El Shams branch attendance geofence.
-- Run this migration in the ORIGINAL Pizza King & Moran Supabase project.
-- Coordinates were supplied from the branch Google Maps pin.
-- Allowed radius: 200 meters.

insert into public.branch_attendance_locations
  (branch, latitude, longitude, radius_m)
values
  ('الشمس', 30.1158793, 31.3457577, 200)
on conflict (branch) do update
set latitude = excluded.latitude,
    longitude = excluded.longitude,
    radius_m = excluded.radius_m,
    updated_at = now();
