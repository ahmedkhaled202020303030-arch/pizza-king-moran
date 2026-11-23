-- Delivery receipt storage and private access
-- Run once in Supabase SQL Editor.
alter table public.delivery_orders
  add column if not exists receipt_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'delivery-order-receipts',
  'delivery-order-receipts',
  false,
  8388608,
  array['image/jpeg','image/png','image/webp','application/pdf']
)
on conflict (id) do update
set public = false,
    file_size_limit = 8388608,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "delivery receipt upload access" on storage.objects;
create policy "delivery receipt upload access"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'delivery-order-receipts'
  and exists (
    select 1
    from public.delivery_orders o
    where o.id::text = split_part(name, '/', 1)
      and (
        o.created_by = auth.uid()
        or o.assigned_rep_user_id = auth.uid()
        or public.current_profile_role() in ('admin','operations_manager')
        or (
          public.current_profile_role() = 'branch_manager'
          and o.branch = public.current_profile_branch()
        )
      )
  )
);

drop policy if exists "delivery receipt read access" on storage.objects;
create policy "delivery receipt read access"
on storage.objects for select to authenticated
using (
  bucket_id = 'delivery-order-receipts'
  and exists (
    select 1
    from public.delivery_orders o
    where o.id::text = split_part(name, '/', 1)
      and (
        o.created_by = auth.uid()
        or o.assigned_rep_user_id = auth.uid()
        or public.current_profile_role() in ('admin','operations_manager')
        or (
          public.current_profile_role() = 'branch_manager'
          and o.branch = public.current_profile_branch()
        )
      )
  )
);

-- No public bucket: the app must create short-lived signed URLs after checking access.
