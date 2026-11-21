-- Run AFTER setting the same random secret in:
-- Supabase Dashboard > Edge Functions > Secrets as DELIVERY_PUSH_CRON_SECRET.
-- Replace the placeholder below with that exact secret, then run this SQL once.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
select vault.create_secret('REPLACE_WITH_THE_SAME_DELIVERY_PUSH_CRON_SECRET','delivery_push_cron_secret');
select cron.schedule(
 'delivery-push-late-orders',
 '*/5 * * * *',
 $job$
 select net.http_post(
  url := 'https://mrbdigdeawtoetqdpoye.supabase.co/functions/v1/delivery-push',
  headers := jsonb_build_object(
   'Content-Type','application/json',
   'x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='delivery_push_cron_secret' limit 1)
  ),
  body := jsonb_build_object('action','check_late_orders')
 );
 $job$
);
