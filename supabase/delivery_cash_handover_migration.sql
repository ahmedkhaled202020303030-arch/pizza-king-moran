-- Delivery cash handover and reconciliation.
-- Run after delivery_orders_migration.sql and delivery_reps_migration.sql.
-- Reps can submit a handover for already-collected cash orders only.
-- A manager must confirm physical receipt; orders cannot be handed over twice.

alter table public.delivery_orders
  add column if not exists cash_handover_id uuid;

alter table public.delivery_orders
  drop constraint if exists delivery_orders_collection_status_check;

alter table public.delivery_orders
  add constraint delivery_orders_collection_status_check
  check (collection_status in ('pending','collected','not_applicable','handed_over'));

create table if not exists public.delivery_cash_handovers (
  id uuid primary key default gen_random_uuid(),
  rep_user_id uuid not null references public.delivery_rep_profiles(user_id),
  branch text not null,
  amount numeric(12,2) not null check (amount >= 0),
  order_count integer not null check (order_count > 0),
  status text not null default 'pending' check (status in ('pending','received','rejected')),
  submitted_at timestamptz not null default now(),
  received_by uuid references auth.users(id),
  received_at timestamptz,
  manager_note text
);

create index if not exists delivery_cash_handovers_rep_date_idx
  on public.delivery_cash_handovers(rep_user_id, submitted_at desc);
create index if not exists delivery_cash_handovers_branch_date_idx
  on public.delivery_cash_handovers(branch, submitted_at desc);

alter table public.delivery_orders
  add constraint delivery_orders_cash_handover_fk
  foreign key (cash_handover_id) references public.delivery_cash_handovers(id);

alter table public.delivery_cash_handovers enable row level security;
revoke all on public.delivery_cash_handovers from anon, authenticated;
grant select on public.delivery_cash_handovers to authenticated;

drop policy if exists "Scoped delivery cash handover reads" on public.delivery_cash_handovers;
create policy "Scoped delivery cash handover reads"
on public.delivery_cash_handovers for select to authenticated
using (
  public.current_profile_role() in ('admin','operations_manager')
  or (public.current_profile_role() = 'branch_manager' and branch = public.current_profile_branch())
  or rep_user_id = auth.uid()
);

create or replace function public.submit_delivery_cash_handover()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rep public.delivery_rep_profiles;
  v_handover_id uuid;
  v_amount numeric(12,2);
  v_count integer;
begin
  if auth.uid() is null or public.current_profile_role() <> 'delivery_rep' then
    raise exception 'تسجيل تسليم العهدة متاح للمندوب فقط';
  end if;

  select * into v_rep
  from public.delivery_rep_profiles
  where user_id = auth.uid() and is_active = true
  for update;

  if not found then raise exception 'حساب المندوب غير مفعل'; end if;

  -- Serialize submissions for this rep, then lock eligible orders.
  perform 1
  from public.delivery_orders
  where assigned_rep_user_id = auth.uid()
    and status = 'delivered'
    and payment_method = 'cash'
    and collection_status = 'collected'
    and cash_handover_id is null
  order by delivered_at, id
  for update;

  select coalesce(sum(collected_amount),0), count(*)
    into v_amount, v_count
  from public.delivery_orders
  where assigned_rep_user_id = auth.uid()
    and status = 'delivered'
    and payment_method = 'cash'
    and collection_status = 'collected'
    and cash_handover_id is null;

  if v_count = 0 then raise exception 'لا توجد مبالغ نقدية جديدة لتسليمها'; end if;

  insert into public.delivery_cash_handovers(rep_user_id, branch, amount, order_count)
  values(auth.uid(), v_rep.branch, v_amount, v_count)
  returning id into v_handover_id;

  update public.delivery_orders
  set cash_handover_id = v_handover_id,
      collection_status = 'handed_over',
      updated_at = now()
  where assigned_rep_user_id = auth.uid()
    and status = 'delivered'
    and payment_method = 'cash'
    and collection_status = 'collected'
    and cash_handover_id is null;

  return v_handover_id;
end;
$$;

create or replace function public.confirm_delivery_cash_handover(
  p_handover_id uuid,
  p_decision text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_handover public.delivery_cash_handovers;
  v_role text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  v_role := public.current_profile_role();

  select * into v_handover
  from public.delivery_cash_handovers
  where id = p_handover_id
  for update;

  if not found then raise exception 'سجل التسليم غير موجود'; end if;
  if v_role not in ('admin','operations_manager','branch_manager') then
    raise exception 'غير مصرح بتأكيد استلام العهدة';
  end if;
  if v_role = 'branch_manager' and v_handover.branch <> public.current_profile_branch() then
    raise exception 'لا يمكنك اعتماد عهدة فرع آخر';
  end if;
  if v_handover.status <> 'pending' then
    raise exception 'تمت معالجة هذا التسليم من قبل';
  end if;
  if p_decision not in ('received','rejected') then
    raise exception 'قرار الاستلام غير صحيح';
  end if;

  update public.delivery_cash_handovers
  set status = p_decision,
      received_by = auth.uid(),
      received_at = now(),
      manager_note = nullif(trim(coalesce(p_note,'')),'')
  where id = p_handover_id;

  -- Rejected cash returns to the rep's unhanded collection balance.
  if p_decision = 'rejected' then
    update public.delivery_orders
    set cash_handover_id = null,
        collection_status = 'collected',
        updated_at = now()
    where cash_handover_id = p_handover_id;
  end if;
end;
$$;

revoke all on function public.submit_delivery_cash_handover() from public, anon;
revoke all on function public.confirm_delivery_cash_handover(uuid,text,text) from public, anon;
grant execute on function public.submit_delivery_cash_handover() to authenticated;
grant execute on function public.confirm_delivery_cash_handover(uuid,text,text) to authenticated;
