-- Server-side dispatch guardrails.
-- Enforce the same maximum of 3 active deliveries used by the dispatch UI.
-- Run after delivery_orders_migration.sql and delivery_core_hardening_migration.sql.

create or replace function public.assign_delivery_order(p_order_id uuid,p_rep_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.delivery_orders;
  v_rep public.delivery_rep_profiles;
  v_active_count integer;
begin
  if auth.uid() is null
     or public.current_profile_role() not in ('admin','operations_manager') then
    raise exception 'توزيع الطلبات متاح لمدير التشغيل أو المدير الرئيسي فقط';
  end if;

  select * into v_order
  from public.delivery_orders
  where id = p_order_id
  for update;

  if not found then raise exception 'الطلب غير موجود'; end if;
  if v_order.status not in ('new','assigned') then
    raise exception 'لا يمكن تغيير المندوب بعد بدء تنفيذ الطلب';
  end if;

  -- Lock the rep row so simultaneous assignments cannot exceed the limit.
  select * into v_rep
  from public.delivery_rep_profiles
  where user_id = p_rep_user_id and is_active = true
  for update;

  if not found or v_rep.branch <> v_order.branch then
    raise exception 'اختر مندوباً نشطاً من نفس فرع الطلب';
  end if;
  if v_rep.availability_status = 'unavailable' then
    raise exception 'المندوب غير متاح حالياً';
  end if;

  select count(*) into v_active_count
  from public.delivery_orders
  where assigned_rep_user_id = p_rep_user_id
    and id <> p_order_id
    and status in ('assigned','accepted','picked_up');

  if v_active_count >= 3 then
    raise exception 'هذا المندوب لديه 3 طلبات نشطة بالفعل؛ اختر مندوباً آخر';
  end if;

  update public.delivery_orders
  set assigned_rep_user_id = p_rep_user_id,
      assigned_by = auth.uid(),
      assigned_at = now(),
      status = 'assigned',
      updated_at = now()
  where id = p_order_id;

  if v_order.assigned_rep_user_id is not null
     and v_order.assigned_rep_user_id <> p_rep_user_id
     and not exists (
       select 1 from public.delivery_orders
       where assigned_rep_user_id = v_order.assigned_rep_user_id
         and id <> p_order_id
         and status in ('assigned','accepted','picked_up')
     ) then
    update public.delivery_rep_profiles
    set availability_status = 'available', updated_at = now()
    where user_id = v_order.assigned_rep_user_id and is_active = true;
  end if;

  update public.delivery_rep_profiles
  set availability_status = 'busy', updated_at = now()
  where user_id = p_rep_user_id;
end;
$$;

revoke all on function public.assign_delivery_order(uuid,uuid) from public, anon;
grant execute on function public.assign_delivery_order(uuid,uuid) to authenticated;
