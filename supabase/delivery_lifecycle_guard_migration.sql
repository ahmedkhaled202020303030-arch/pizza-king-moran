-- Delivery lifecycle state-machine protection.
-- Run after delivery_orders_migration.sql and delivery_dispatch_guardrails_migration.sql.
-- This migration adds a database-level transition guard; it does not replace the RPCs.

create or replace function public.guard_delivery_order_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  if tg_op = 'INSERT' then
    if new.status <> 'new' then
      raise exception 'يجب إنشاء الطلب بحالة جديد أولاً';
    end if;
    if new.assigned_rep_user_id is not null
       or new.assigned_at is not null
       or new.accepted_at is not null
       or new.picked_up_at is not null
       or new.delivered_at is not null then
      raise exception 'لا يمكن إضافة طلب جديد ببيانات مراحل تنفيذ مسبقة';
    end if;
    return new;
  end if;

  v_role := public.current_profile_role();

  -- A lifecycle timestamp is write-once: it cannot be cleared or rewritten.
  if old.assigned_at is not null and new.assigned_at is distinct from old.assigned_at then
    raise exception 'لا يمكن تعديل وقت إسناد الطلب بعد تسجيله';
  end if;
  if old.accepted_at is not null and new.accepted_at is distinct from old.accepted_at then
    raise exception 'لا يمكن تعديل وقت قبول الطلب بعد تسجيله';
  end if;
  if old.picked_up_at is not null and new.picked_up_at is distinct from old.picked_up_at then
    raise exception 'لا يمكن تعديل وقت استلام الطلب بعد تسجيله';
  end if;
  if old.delivered_at is not null and new.delivered_at is distinct from old.delivered_at then
    raise exception 'لا يمكن تعديل وقت تسليم الطلب بعد تسجيله';
  end if;

  if old.status = 'delivered' and new.status is distinct from old.status then
    raise exception 'الطلب الذي تم تسليمه لا يمكن إعادة فتحه أو تغيير حالته';
  end if;
  if old.status = 'cancelled' and new.status is distinct from old.status then
    raise exception 'الطلب الملغي لا يمكن إعادة فتحه';
  end if;

  if new.status is distinct from old.status then
    if new.status = 'cancelled' then
      if v_role not in ('admin','operations_manager') then
        raise exception 'إلغاء الطلب متاح للمدير الرئيسي أو مدير التشغيل فقط';
      end if;
      if old.status in ('delivered','cancelled') then
        raise exception 'لا يمكن إلغاء هذا الطلب';
      end if;
    elsif old.status = 'new' and new.status = 'assigned' then
      if new.assigned_rep_user_id is null or new.assigned_at is null then
        raise exception 'يجب تعيين مندوب وتسجيل وقت الإسناد';
      end if;
    elsif old.status = 'assigned' and new.status = 'accepted' then
      if v_role <> 'delivery_rep' or new.accepted_at is null then
        raise exception 'قبول الطلب يجب أن يتم من المندوب المسند إليه';
      end if;
    elsif old.status = 'accepted' and new.status = 'picked_up' then
      if v_role <> 'delivery_rep' or new.picked_up_at is null then
        raise exception 'تأكيد استلام الطلب يجب أن يتم من المندوب المسند إليه';
      end if;
    elsif old.status = 'picked_up' and new.status = 'delivered' then
      if v_role <> 'delivery_rep' or new.delivered_at is null then
        raise exception 'تأكيد التسليم يجب أن يتم من المندوب المسند إليه';
      end if;
    else
      raise exception 'انتقال حالة الطلب غير مسموح: % إلى %', old.status, new.status;
    end if;
  end if;

  -- Once a stage is reached, its timestamp must exist and remain present.
  if new.status in ('assigned','accepted','picked_up','delivered')
     and (new.assigned_at is null or new.assigned_rep_user_id is null) then
    raise exception 'بيانات إسناد الطلب غير مكتملة';
  end if;
  if new.status in ('accepted','picked_up','delivered') and new.accepted_at is null then
    raise exception 'وقت قبول المندوب غير مسجل';
  end if;
  if new.status in ('picked_up','delivered') and new.picked_up_at is null then
    raise exception 'وقت استلام الطلب من الفرع غير مسجل';
  end if;
  if new.status = 'delivered' and new.delivered_at is null then
    raise exception 'وقت تسليم الطلب غير مسجل';
  end if;

  return new;
end;
$$;

drop trigger if exists delivery_orders_lifecycle_guard on public.delivery_orders;
create trigger delivery_orders_lifecycle_guard
before insert or update of status, assigned_rep_user_id, assigned_at, accepted_at, picked_up_at, delivered_at
on public.delivery_orders
for each row execute function public.guard_delivery_order_lifecycle();

revoke all on function public.guard_delivery_order_lifecycle() from public, anon, authenticated;
