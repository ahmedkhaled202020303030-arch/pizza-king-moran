-- Inventory receiving and accountant reconciliation module.
-- Run this file once in Supabase Dashboard > SQL Editor.

create table if not exists public.inventory_items (
 id uuid primary key default gen_random_uuid(),
 supplier text not null check (supplier in ('المصنع - نموذج 1','المصنع - نموذج 2','دومتي','جومو','كورنر')),
 item_name text not null,
 unit text not null default 'وحدة',
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique (supplier, item_name)
);
create table if not exists public.inventory_documents (
 id uuid primary key default gen_random_uuid(),
 doc_type text not null check (doc_type in ('receipt','accountant')),
 supplier text not null check (supplier in ('المصنع - نموذج 1','المصنع - نموذج 2','دومتي','جومو','كورنر')),
 branch text not null,
 doc_date date not null,
 reference_no text,
 notes text,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.inventory_document_lines (
 id uuid primary key default gen_random_uuid(),
 document_id uuid not null references public.inventory_documents(id) on delete cascade,
 item_name text not null,
 quantity numeric(14,3) not null check (quantity >= 0),
 unit text not null default 'وحدة',
 created_at timestamptz not null default now()
);
create index if not exists inventory_docs_lookup_idx on public.inventory_documents(supplier,branch,doc_date,doc_type);
create index if not exists inventory_lines_document_idx on public.inventory_document_lines(document_id);
alter table public.inventory_items enable row level security;
alter table public.inventory_documents enable row level security;
alter table public.inventory_document_lines enable row level security;
drop policy if exists inventory_items_auth_all on public.inventory_items;
create policy inventory_items_auth_all on public.inventory_items for all to authenticated using (true) with check (true);
drop policy if exists inventory_docs_auth_all on public.inventory_documents;
create policy inventory_docs_auth_all on public.inventory_documents for all to authenticated using (true) with check (true);
drop policy if exists inventory_lines_auth_all on public.inventory_document_lines;
create policy inventory_lines_auth_all on public.inventory_document_lines for all to authenticated using (true) with check (true);
grant select,insert,update,delete on public.inventory_items,public.inventory_documents,public.inventory_document_lines to authenticated;
