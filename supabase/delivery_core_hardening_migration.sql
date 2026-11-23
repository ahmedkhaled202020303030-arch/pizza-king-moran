-- Core delivery safeguards: prevent invalid cash collection and hiding reps with active orders.
-- Additive migration. Run after delivery_orders_migration.sql,
-- delivery_reps_migration.sql, and delivery_cash_handover_migration.sql.

create or replace function public.validate_delivery_order_core()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.collected_amount is not null
     and new.collected_amount > new.total_amount then
    raise exception 'المبلغ المحصل لا يمكن أن يتجاوز إجمالي الطلب';
  end if;

  if new.collection_status in ('collected', 'handed_over') then
    if new.status <> 'delivered'
       or new.payment_method <> 'cash'
       or new.collected_amount is null then
      raise exception 'حالة التحصيل النقدي لا تتوافق مع بيانات الطلب';
    end if;
  end if;

  if new.collection_status = 'not_applicable'
     and (new.status <> 'delivered' or new.payment_method = 'cash') then
    raise exception 'حالة التحصيل غير النقدي لا تتوافق مع الطلب';
  end if;

  return new;
end;
$$;

drop trigger if exists delivery_orders_core_validation on public.delivery_orders;
create trigger delivery_orders_core_validation
before insert or update of status, total_amount, payment_method, collected_amount, collection_status
on public.delivery_orders
for each row execute function public.validate_delivery_order_core();

-- A rep with an active delivery must remain visible as busy, not disappear
-- from dispatch because they manually switched themselves to unavailable.
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

  if p_status = 'unavailable' and exists (
    select 1
    from public.delivery_orders o
    where o.assigned_rep_user_id = auth.uid()
      and o.status in ('assigned', 'accepted', 'picked_up')
  ) then
    raise exception 'لا يمكن إخفاء المندوب أثناء وجود طلبات قيد التنفيذ؛ أكمل الطلبات أولاً';
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

revoke all on function public.set_delivery_rep_status(text) from public, anon;
grant execute on function public.set_delivery_rep_status(text) to authenticated;
