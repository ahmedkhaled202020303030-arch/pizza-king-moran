-- Allow the main admin to create delivery orders and select their branch.
-- Run this migration in Supabase SQL Editor after the delivery lifecycle actor guard migration.

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
    if v_role not in ('admin','branch_manager') or new.created_by is distinct from v_actor then
      raise exception 'إنشاء الطلب متاح لمدير الفرع أو المدير الرئيسي فقط';
    end if;
    if new.branch is null or length(trim(new.branch))=0 then
      raise exception 'يجب تحديد فرع الطلب';
    end if;
    if v_role='branch_manager' and new.branch is distinct from public.current_profile_branch() then
      raise exception 'لا يمكنك إنشاء طلب لفرع آخر';
    end if;
    if new.status <> 'new' then
      raise exception 'يجب إنشاء الطلب بحالة جديد أولاً';
    end if;
    if new.assigned_rep_user_id is not null or new.assigned_at is not null
       or new.assigned_by is not null or new.accepted_at is not null
       or new.picked_up_at is not null or new.delivered_at is not null then
      raise exception 'لا يمكن إضافة طلب جديد ببيانات مراحل تنفيذ مسبقة';
    end if;
    return new;
  end if;

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
       or new.status <> 'assigned' or old.status not in ('new','assigned')
       or new.assigned_rep_user_id is null or new.assigned_at is null
       or new.assigned_by is distinct from v_actor then
      raise exception 'إعادة إسناد الطلب متاحة للإدارة فقط وبالشروط الصحيحة';
    end if;
    select branch,is_active into v_rep_branch,v_rep_active
    from public.delivery_rep_profiles where user_id=new.assigned_rep_user_id;
    if not found or v_rep_active is not true or v_rep_branch is distinct from new.branch then
      raise exception 'المندوب المختار غير مفعل أو لا يتبع نفس فرع الطلب';
    end if;
  end if;

  if old.accepted_at is not null and new.accepted_at is distinct from old.accepted_at then raise exception 'لا يمكن تعديل وقت قبول الطلب بعد تسجيله'; end if;
  if old.picked_up_at is not null and new.picked_up_at is distinct from old.picked_up_at then raise exception 'لا يمكن تعديل وقت استلام الطلب بعد تسجيله'; end if;
  if old.delivered_at is not null and new.delivered_at is distinct from old.delivered_at then raise exception 'لا يمكن تعديل وقت تسليم الطلب بعد تسجيله'; end if;
  if old.status='delivered' and new.status is distinct from old.status then raise exception 'الطلب الذي تم تسليمه لا يمكن إعادة فتحه أو تغيير حالته'; end if;
  if old.status='cancelled' and new.status is distinct from old.status then raise exception 'الطلب الملغي لا يمكن إعادة فتحه'; end if;

  if new.status is distinct from old.status then
    if new.status='cancelled' then
      if v_role not in ('admin','operations_manager') then raise exception 'إلغاء الطلب متاح للمدير الرئيسي أو مدير التشغيل فقط'; end if;
      if old.status in ('delivered','cancelled') then raise exception 'لا يمكن إلغاء هذا الطلب'; end if;
      if new.accepted_at is distinct from old.accepted_at or new.picked_up_at is distinct from old.picked_up_at or new.delivered_at is distinct from old.delivered_at then raise exception 'لا يمكن تعديل أوقات التنفيذ أثناء إلغاء الطلب'; end if;
    elsif old.status='new' and new.status='assigned' then
      if v_role not in ('admin','operations_manager') or new.assigned_rep_user_id is null or new.assigned_at is null then raise exception 'إسناد الطلب متاح للإدارة فقط ويستلزم مندوباً ووقت إسناد'; end if;
    elsif old.status='assigned' and new.status='accepted' then
      if v_role<>'delivery_rep' or old.assigned_rep_user_id is distinct from v_actor or new.assigned_rep_user_id is distinct from old.assigned_rep_user_id or new.accepted_at is null then raise exception 'قبول الطلب متاح للمندوب المسند إليه فقط'; end if;
    elsif old.status='accepted' and new.status='picked_up' then
      if v_role<>'delivery_rep' or old.assigned_rep_user_id is distinct from v_actor or new.assigned_rep_user_id is distinct from old.assigned_rep_user_id or new.picked_up_at is null then raise exception 'تأكيد استلام الطلب متاح للمندوب المسند إليه فقط'; end if;
    elsif old.status='picked_up' and new.status='delivered' then
      if v_role<>'delivery_rep' or old.assigned_rep_user_id is distinct from v_actor or new.assigned_rep_user_id is distinct from old.assigned_rep_user_id or new.delivered_at is null then raise exception 'تأكيد التسليم متاح للمندوب المسند إليه فقط'; end if;
    else
      raise exception 'انتقال حالة الطلب غير مسموح: % إلى %',old.status,new.status;
    end if;
  else
    if new.accepted_at is distinct from old.accepted_at or new.picked_up_at is distinct from old.picked_up_at or new.delivered_at is distinct from old.delivered_at then raise exception 'لا يمكن تسجيل وقت مرحلة دون الانتقال إلى حالتها'; end if;
  end if;

  if new.status in ('assigned','accepted','picked_up','delivered') and (new.assigned_at is null or new.assigned_rep_user_id is null) then raise exception 'بيانات إسناد الطلب غير مكتملة'; end if;
  if new.status in ('accepted','picked_up','delivered') and new.accepted_at is null then raise exception 'وقت قبول المندوب غير مسجل'; end if;
  if new.status in ('picked_up','delivered') and new.picked_up_at is null then raise exception 'وقت استلام الطلب من الفرع غير مسجل'; end if;
  if new.status='delivered' and new.delivered_at is null then raise exception 'وقت تسليم الطلب غير مسجل'; end if;
  return new;
end;
$$;

drop function if exists public.create_delivery_order(text,text,text,double precision,double precision,text,numeric,text,text);

create or replace function public.create_delivery_order(
 p_customer_name text,
 p_customer_phone text,
 p_delivery_address text,
 p_latitude double precision default null,
 p_longitude double precision default null,
 p_items text default '',
 p_total_amount numeric default 0,
 p_payment_method text default 'cash',
 p_notes text default null,
 p_branch text default null
) returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
 v_id uuid;
 v_role text;
 v_branch text;
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
 v_role:=public.current_profile_role();
 if v_role='branch_manager' then
   v_branch:=public.current_profile_branch();
   if p_branch is not null and p_branch is distinct from v_branch then raise exception 'لا يمكنك إنشاء طلب لفرع آخر'; end if;
 elsif v_role='admin' then
   v_branch:=nullif(trim(coalesce(p_branch,'')),'');
 else
   raise exception 'إنشاء الطلب متاح لمدير الفرع أو المدير الرئيسي فقط';
 end if;
 if v_branch is null or length(trim(v_branch))=0 then raise exception 'اختر فرع الطلب'; end if;
 if length(trim(coalesce(p_customer_name,'')))<2 or length(trim(coalesce(p_customer_phone,'')))<5 or length(trim(coalesce(p_delivery_address,'')))<5 then raise exception 'اكتب اسم العميل والهاتف والعنوان بالتفصيل'; end if;
 if p_total_amount is null or p_total_amount<0 or p_payment_method not in ('cash','card','wallet') then raise exception 'راجع إجمالي الطلب وطريقة الدفع'; end if;
 if (p_latitude is null)<>(p_longitude is null) then raise exception 'أدخل إحداثيات الموقع معاً أو اتركهما فارغين'; end if;
 insert into public.delivery_orders(branch,customer_name,customer_phone,delivery_address,latitude,longitude,items,total_amount,payment_method,notes,created_by)
 values(v_branch,trim(p_customer_name),trim(p_customer_phone),trim(p_delivery_address),p_latitude,p_longitude,coalesce(p_items,''),p_total_amount,p_payment_method,nullif(trim(coalesce(p_notes,'')),''),auth.uid())
 returning id into v_id;
 return v_id;
end;
$$;

revoke all on function public.create_delivery_order(text,text,text,double precision,double precision,text,numeric,text,text,text) from public,anon;
grant execute on function public.create_delivery_order(text,text,text,double precision,double precision,text,numeric,text,text,text) to authenticated;
