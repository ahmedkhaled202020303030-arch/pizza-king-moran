-- Harden delivery lifecycle actor authorization.
-- Run after delivery_lifecycle_guard_migration.sql.
-- Enforces the acting user's identity at the database trigger, not only in the RPC.

create or replace function public.guard_delivery_order_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_actor uuid;
  v_assignment_changed boolean;
  v_rep_branch text;
  v_rep_active boolean;
begin
  v_actor := auth.uid();
  v_role := public.current_profile_role();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  if tg_op = 'INSERT' then
    if v_role <> 'branch_manager' or new.created_by is distinct from v_actor then
      raise exception 'إنشاء الطلب متاح لمدير الفرع المسجل فقط';
    end if;
    if new.status <> 'new' then
      raise exception 'يجب إنشاء الطلب بحالة جديد أولاً';
    end if;
    if new.assigned_rep_user_id is not null
       or new.assigned_at is not null
       or new.assigned_by is not null
       or new.accepted_at is not null
       or new.picked_up_at is not null
       or new.delivered_at is not null then
      raise exception 'لا يمكن إضافة طلب جديد ببيانات مراحل تنفيذ مسبقة';
    end if;
    return new;
  end if;

  -- Core order identity and commercial details are immutable after creation.
  if new.created_by is distinct from old.created_by
     or new.branch is distinct from old.branch
     or new.customer_name is distinct from old.customer_name
     or new.customer_phone is distinct from old.customer_phone
     or new.delivery_address is distinct from old.delivery_address
     or new.total_amount is distinct from old.total_amount
     or new.payment_method is distinct from old.payment_method then
    raise exception 'لا يمكن تعديل بيانات الطلب الأساسية بعد إنشائه';
  end if;

  v_assignment_changed :=
    new.assigned_rep_user_id is distinct from old.assigned_rep_user_id
    or new.assigned_at is distinct from old.assigned_at
    or new.assigned_by is distinct from old.assigned_by;

  if v_assignment_changed then
    if v_role not in ('admin','operations_manager')
       or new.status <> 'assigned'
       or old.status not in ('new','assigned')
       or new.assigned_rep_user_id is null
       or new.assigned_at is null
       or new.assigned_by is distinct from v_actor then
      raise exception 'إعادة إسناد الطلب متاحة للإدارة فقط وبالشروط الصحيحة';
    end if;

    select branch, is_active into v_rep_branch, v_rep_active
    from public.delivery_rep_profiles
    where user_id = new.assigned_rep_user_id;

    if not found or v_rep_active is not true or v_rep_branch is distinct from new.branch then
      raise exception 'المندوب المختار غير مفعل أو لا يتبع نفس فرع الطلب';
    end if;
  end if;

  -- Lifecycle timestamps cannot be erased or rewritten.
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
      if new.accepted_at is distinct from old.accepted_at
         or new.picked_up_at is distinct from old.picked_up_at
         or new.delivered_at is distinct from old.delivered_at then
        raise exception 'لا يمكن تعديل أوقات التنفيذ أثناء إلغاء الطلب';
      end if;
    elsif old.status = 'new' and new.status = 'assigned' then
      if v_role not in ('admin','operations_manager')
         or new.assigned_rep_user_id is null
         or new.assigned_at is null then
        raise exception 'إسناد الطلب متاح للإدارة فقط ويستلزم مندوباً ووقت إسناد';
      end if;
    elsif old.status = 'assigned' and new.status = 'accepted' then
      if v_role <> 'delivery_rep'
         or old.assigned_rep_user_id is distinct from v_actor
         or new.assigned_rep_user_id is distinct from old.assigned_rep_user_id
         or new.accepted_at is null then
        raise exception 'قبول الطلب متاح للمندوب المسند إليه فقط';
      end if;
    elsif old.status = 'accepted' and new.status = 'picked_up' then
      if v_role <> 'delivery_rep'
         or old.assigned_rep_user_id is distinct from v_actor
         or new.assigned_rep_user_id is distinct from old.assigned_rep_user_id
         or new.picked_up_at is null then
        raise exception 'تأكيد استلام الطلب متاح للمندوب المسند إليه فقط';
      end if;
    elsif old.status = 'picked_up' and new.status = 'delivered' then
      if v_role <> 'delivery_rep'
         or old.assigned_rep_user_id is distinct from v_actor
         or new.assigned_rep_user_id is distinct from old.assigned_rep_user_id
         or new.delivered_at is null then
        raise exception 'تأكيد التسليم متاح للمندوب المسند إليه فقط';
      end if;
    else
      raise exception 'انتقال حالة الطلب غير مسموح: % إلى %', old.status, new.status;
    end if;
  else
    -- A timestamp may only be written by the matching state transition.
    if new.accepted_at is distinct from old.accepted_at
       or new.picked_up_at is distinct from old.picked_up_at
       or new.delivered_at is distinct from old.delivered_at then
      raise exception 'لا يمكن تسجيل وقت مرحلة دون الانتقال إلى حالتها';
    end if;
  end if;

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
before insert or update of status, assigned_rep_user_id, assigned_at, assigned_by,
  accepted_at, picked_up_at, delivered_at, created_by, branch, customer_name,
  customer_phone, delivery_address, total_amount, payment_method
on public.delivery_orders
for each row execute function public.guard_delivery_order_lifecycle();

revoke all on function public.guard_delivery_order_lifecycle() from public, anon, authenticated;
