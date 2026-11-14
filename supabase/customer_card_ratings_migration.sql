-- Add customer card ratings to existing customer records.
-- Safe additive migration: existing records and access policies are unchanged.
ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS food_rating text,
  ADD COLUMN IF NOT EXISTS atmosphere_rating text,
  ADD COLUMN IF NOT EXISTS value_rating text,
  ADD COLUMN IF NOT EXISTS service_rating text,
  ADD COLUMN IF NOT EXISTS cleanliness_rating text;

ALTER TABLE public.customers
  DROP CONSTRAINT IF EXISTS customers_food_rating_check,
  DROP CONSTRAINT IF EXISTS customers_atmosphere_rating_check,
  DROP CONSTRAINT IF EXISTS customers_value_rating_check,
  DROP CONSTRAINT IF EXISTS customers_service_rating_check,
  DROP CONSTRAINT IF EXISTS customers_cleanliness_rating_check;

ALTER TABLE public.customers
  ADD CONSTRAINT customers_food_rating_check CHECK (food_rating IS NULL OR food_rating IN ('سيئ','متوسط','جيد','ممتاز')),
  ADD CONSTRAINT customers_atmosphere_rating_check CHECK (atmosphere_rating IS NULL OR atmosphere_rating IN ('سيئ','متوسط','جيد','ممتاز')),
  ADD CONSTRAINT customers_value_rating_check CHECK (value_rating IS NULL OR value_rating IN ('سيئ','متوسط','جيد','ممتاز')),
  ADD CONSTRAINT customers_service_rating_check CHECK (service_rating IS NULL OR service_rating IN ('سيئ','متوسط','جيد','ممتاز')),
  ADD CONSTRAINT customers_cleanliness_rating_check CHECK (cleanliness_rating IS NULL OR cleanliness_rating IN ('سيئ','متوسط','جيد','ممتاز'));
