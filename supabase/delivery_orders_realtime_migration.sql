-- Enable live order-board updates in Supabase Realtime.
-- Safe to run more than once.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'delivery_orders'
     ) then
    alter publication supabase_realtime add table public.delivery_orders;
  end if;
end $$;
