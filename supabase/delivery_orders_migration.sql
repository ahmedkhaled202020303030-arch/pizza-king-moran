-- Delivery orders for Pizza King & Morin. Run after delivery_reps_migration.sql and delivery_rep_approval_migration.sql.
create table if not exists public.delivery_orders (
 id uuid primary key default gen_random_uuid(),
 order_no bigint generated always as identity unique,
 branch text not null,
 customer_name text not null check(length(trim(customer_name)) between 2 and 120),
 customer_phone text not null check(length(trim(customer_phone)) between 5 and 30),
 delivery_address text not null check(length(trim(delivery_address)) between 5 and 500),
 latitude double precision check(latitude is null or latitude between -90 and 90),
 longitude double precision check(longitude is null or longitude between -180 and 180),
 items text not null default '',
 total_amount numeric(12,2) not null default 0 check(total_amount>=0),
 payment_method text not null default 'cash' check(payment_method in ('cash','card','wallet')),
 notes text,
 status text not null default 'new' check(status in ('new','assigned','accepted','picked_up','delivered','cancelled')),
 assigned_rep_user_id uuid references public.delivery_rep_profiles(user_id) on delete set null,
 created_by uuid not null references auth.users(id),
 assigned_by uuid references auth.users(id),
 assigned_at timestamptz, accepted_at timestamptz, picked_up_at timestamptz, delivered_at timestamptz,
 collected_amount numeric(12,2) check(collected_amount is null or collected_amount>=0),
 collection_status text not null default 'pending' check(collection_status in ('pending','collected','not_applicable')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists delivery_orders_branch_created_idx on public.delivery_orders(branch,created_at desc);
create index if not exists delivery_orders_rep_status_idx on public.delivery_orders(assigned_rep_user_id,status,created_at desc);
create table if not exists public.delivery_order_events (
 id bigint generated always as identity primary key,
 order_id uuid not null references public.delivery_orders(id) on delete cascade,
 actor_user_id uuid references auth.users(id) on delete set null,
 event_type text not null, old_status text, new_status text,
 details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create index if not exists delivery_order_events_order_idx on public.delivery_order_events(order_id,created_at desc);
alter table public.delivery_orders enable row level security;
alter table public.delivery_order_events enable row level security;
revoke all on public.delivery_orders from anon,authenticated;
revoke all on public.delivery_order_events from anon,authenticated;
grant select on public.delivery_orders to authenticated;
grant select on public.delivery_order_events to authenticated;
drop policy if exists "Scoped delivery order reads" on public.delivery_orders;
create policy "Scoped delivery order reads" on public.delivery_orders for select to authenticated using (
 public.current_profile_role() in ('admin','operations_manager')
 or (public.current_profile_role()='branch_manager' and branch=public.current_profile_branch())
 or (public.current_profile_role()='delivery_rep' and assigned_rep_user_id=auth.uid())
);
drop policy if exists "Scoped delivery order event reads" on public.delivery_order_events;
create policy "Scoped delivery order event reads" on public.delivery_order_events for select to authenticated using (
 public.current_profile_role() in ('admin','operations_manager')
 or exists(select 1 from public.delivery_orders o where o.id=delivery_order_events.order_id and
 ((public.current_profile_role()='branch_manager' and o.branch=public.current_profile_branch())
 or (public.current_profile_role()='delivery_rep' and o.assigned_rep_user_id=auth.uid())))
);
create or replace function public.log_delivery_order_event() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='INSERT' then
  insert into public.delivery_order_events(order_id,actor_user_id,event_type,new_status,details)
  values(new.id,auth.uid(),'created',new.status,jsonb_build_object('branch',new.branch,'order_no',new.order_no));
 else
  if old.status is distinct from new.status then
   insert into public.delivery_order_events(order_id,actor_user_id,event_type,old_status,new_status)
   values(new.id,auth.uid(),'status_changed',old.status,new.status);
  end if;
  if old.assigned_rep_user_id is distinct from new.assigned_rep_user_id then
   insert into public.delivery_order_events(order_id,actor_user_id,event_type,old_status,new_status,details)
   values(new.id,auth.uid(),'rep_assigned',old.status,new.status,jsonb_build_object('rep_user_id',new.assigned_rep_user_id));
  end if;
  if old.collected_amount is distinct from new.collected_amount or old.collection_status is distinct from new.collection_status then
   insert into public.delivery_order_events(order_id,actor_user_id,event_type,new_status,details)
   values(new.id,auth.uid(),'collection_updated',new.status,jsonb_build_object('collected_amount',new.collected_amount,'collection_status',new.collection_status));
  end if;
 end if;
 return new;
end; $$;
drop trigger if exists delivery_orders_audit_trigger on public.delivery_orders;
create trigger delivery_orders_audit_trigger after insert or update on public.delivery_orders for each row execute function public.log_delivery_order_event();

create or replace function public.create_delivery_order(
 p_customer_name text,p_customer_phone text,p_delivery_address text,
 p_latitude double precision default null,p_longitude double precision default null,
 p_items text default '',p_total_amount numeric default 0,p_payment_method text default 'cash',p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_branch text;
begin
 if auth.uid() is null or public.current_profile_role()<>'branch_manager' then raise exception 'إنشاء الطلبات متاح لمدير الفرع فقط'; end if;
 v_branch:=public.current_profile_branch();
 if v_branch is null or length(trim(v_branch))=0 then raise exception 'حساب مدير الفرع غير مرتبط بفرع'; end if;
 if length(trim(coalesce(p_customer_name,'')))<2 or length(trim(coalesce(p_customer_phone,'')))<5 or length(trim(coalesce(p_delivery_address,'')))<5 then raise exception 'اكتب اسم العميل والهاتف والعنوان بالتفصيل'; end if;
 if p_total_amount is null or p_total_amount<0 or p_payment_method not in ('cash','card','wallet') then raise exception 'راجع إجمالي الطلب وطريقة الدفع'; end if;
 if (p_latitude is null)<>(p_longitude is null) then raise exception 'أدخل إحداثيات الموقع معاً أو اتركهما فارغين'; end if;
 insert into public.delivery_orders(branch,customer_name,customer_phone,delivery_address,latitude,longitude,items,total_amount,payment_method,notes,created_by)
 values(v_branch,trim(p_customer_name),trim(p_customer_phone),trim(p_delivery_address),p_latitude,p_longitude,coalesce(p_items,''),p_total_amount,p_payment_method,nullif(trim(coalesce(p_notes,'')),''),auth.uid())
 returning id into v_id;
 return v_id;
end; $$;

create or replace function public.assign_delivery_order(p_order_id uuid,p_rep_user_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_order public.delivery_orders; v_rep public.delivery_rep_profiles;
begin
 if auth.uid() is null or public.current_profile_role() not in ('admin','operations_manager') then raise exception 'توزيع الطلبات متاح لمدير التشغيل أو المدير الرئيسي فقط'; end if;
 select * into v_order from public.delivery_orders where id=p_order_id for update;
 if not found then raise exception 'الطلب غير موجود'; end if;
 if v_order.status not in ('new','assigned') then raise exception 'لا يمكن تغيير المندوب بعد بدء تنفيذ الطلب'; end if;
 select * into v_rep from public.delivery_rep_profiles where user_id=p_rep_user_id and is_active=true for update;
 if not found or v_rep.branch<>v_order.branch then raise exception 'اختر مندوباً نشطاً من نفس فرع الطلب'; end if;
 if v_rep.availability_status='unavailable' then raise exception 'المندوب غير متاح حالياً'; end if;
 update public.delivery_orders set assigned_rep_user_id=p_rep_user_id,assigned_by=auth.uid(),assigned_at=now(),status='assigned',updated_at=now() where id=p_order_id;
 update public.delivery_rep_profiles set availability_status='busy',updated_at=now() where user_id=p_rep_user_id;
end; $$;

create or replace function public.update_delivery_order_status(p_order_id uuid,p_status text,p_collected_amount numeric default null)
returns void language plpgsql security definer set search_path=public as $$
declare v_order public.delivery_orders; v_role text;
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
 v_role:=public.current_profile_role();
 select * into v_order from public.delivery_orders where id=p_order_id for update;
 if not found then raise exception 'الطلب غير موجود'; end if;
 if p_status='cancelled' and v_role in ('admin','operations_manager') then
  if v_order.status in ('delivered','cancelled') then raise exception 'لا يمكن إلغاء هذا الطلب'; end if;
  update public.delivery_orders set status='cancelled',updated_at=now() where id=p_order_id; return;
 end if;
 if v_role<>'delivery_rep' or v_order.assigned_rep_user_id<>auth.uid() then raise exception 'غير مصرح بتحديث هذا الطلب'; end if;
 if (v_order.status='assigned' and p_status<>'accepted') or (v_order.status='accepted' and p_status<>'picked_up') or (v_order.status='picked_up' and p_status<>'delivered') then raise exception 'حالة الطلب لا تسمح بهذه الخطوة'; end if;
 if p_status='delivered' then
  if v_order.payment_method='cash' then
   if p_collected_amount is null or p_collected_amount<0 then raise exception 'سجّل المبلغ النقدي الذي تم تحصيله'; end if;
   update public.delivery_orders set status='delivered',delivered_at=now(),collected_amount=p_collected_amount,collection_status='collected',updated_at=now() where id=p_order_id;
  else
   update public.delivery_orders set status='delivered',delivered_at=now(),collected_amount=total_amount,collection_status='not_applicable',updated_at=now() where id=p_order_id;
  end if;
 elsif p_status='accepted' then update public.delivery_orders set status='accepted',accepted_at=now(),updated_at=now() where id=p_order_id;
 elsif p_status='picked_up' then update public.delivery_orders set status='picked_up',picked_up_at=now(),updated_at=now() where id=p_order_id;
 else raise exception 'حالة الطلب غير صحيحة';
 end if;
 if p_status='delivered' and not exists(select 1 from public.delivery_orders where assigned_rep_user_id=auth.uid() and id<>p_order_id and status in ('assigned','accepted','picked_up')) then
  update public.delivery_rep_profiles set availability_status='available',updated_at=now() where user_id=auth.uid() and is_active=true;
 end if;
end; $$;
revoke all on function public.create_delivery_order(text,text,text,double precision,double precision,text,numeric,text,text) from public,anon;
revoke all on function public.assign_delivery_order(uuid,uuid) from public,anon;
revoke all on function public.update_delivery_order_status(uuid,text,numeric) from public,anon;
grant execute on function public.create_delivery_order(text,text,text,double precision,double precision,text,numeric,text,text) to authenticated;
grant execute on function public.assign_delivery_order(uuid,uuid) to authenticated;
grant execute on function public.update_delivery_order_status(uuid,text,numeric) to authenticated;
