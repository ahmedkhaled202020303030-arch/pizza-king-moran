-- Push notifications for main admin and branch managers only.
create table if not exists public.delivery_push_subscriptions (
 id bigint generated always as identity primary key,
 user_id uuid not null references auth.users(id) on delete cascade,
 branch text,
 endpoint text not null unique,
 subscription jsonb not null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists delivery_push_subscriptions_user_idx on public.delivery_push_subscriptions(user_id);
alter table public.delivery_push_subscriptions enable row level security;
revoke all on public.delivery_push_subscriptions from anon, authenticated;
grant select,insert,update,delete on public.delivery_push_subscriptions to authenticated;
drop policy if exists "Managers manage own push subscriptions" on public.delivery_push_subscriptions;
create policy "Managers manage own push subscriptions" on public.delivery_push_subscriptions
 for all to authenticated using (
  user_id=auth.uid() and public.current_profile_role() in ('admin','branch_manager')
 ) with check (
  user_id=auth.uid() and public.current_profile_role() in ('admin','branch_manager')
 );
create table if not exists public.delivery_push_notification_log (
 id bigint generated always as identity primary key,
 event_key text not null unique,
 order_id uuid references public.delivery_orders(id) on delete cascade,
 created_at timestamptz not null default now()
);
alter table public.delivery_push_notification_log enable row level security;
revoke all on public.delivery_push_notification_log from anon,authenticated;
