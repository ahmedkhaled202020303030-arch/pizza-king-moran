-- Branch-scoped inventory access.
-- Run once in Supabase Dashboard > SQL Editor after the existing inventory migration.
-- Admin and operations_manager can access all branches; branch_manager is restricted
-- to the branch stored on their own profiles row.

drop policy if exists inventory_items_auth_all on public.inventory_items;
drop policy if exists inventory_docs_auth_all on public.inventory_documents;
drop policy if exists inventory_lines_auth_all on public.inventory_document_lines;
drop policy if exists inventory_items_roles on public.inventory_items;
drop policy if exists inventory_docs_branch_scope on public.inventory_documents;
drop policy if exists inventory_lines_branch_scope on public.inventory_document_lines;

create policy inventory_items_roles on public.inventory_items for all to authenticated
using (exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role in ('admin','operations_manager','branch_manager')))
with check (exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.role in ('admin','operations_manager','branch_manager')));

create policy inventory_docs_branch_scope on public.inventory_documents for all to authenticated
using (exists (select 1 from public.profiles p where p.user_id = auth.uid() and (p.role in ('admin','operations_manager') or (p.role = 'branch_manager' and p.branch = inventory_documents.branch))))
with check (exists (select 1 from public.profiles p where p.user_id = auth.uid() and (p.role in ('admin','operations_manager') or (p.role = 'branch_manager' and p.branch = inventory_documents.branch))));

create policy inventory_lines_branch_scope on public.inventory_document_lines for all to authenticated
using (exists (select 1 from public.inventory_documents d join public.profiles p on p.user_id = auth.uid() where d.id = inventory_document_lines.document_id and (p.role in ('admin','operations_manager') or (p.role = 'branch_manager' and p.branch = d.branch))))
with check (exists (select 1 from public.inventory_documents d join public.profiles p on p.user_id = auth.uid() where d.id = inventory_document_lines.document_id and (p.role in ('admin','operations_manager') or (p.role = 'branch_manager' and p.branch = d.branch))));

grant select, insert, update, delete on public.inventory_items, public.inventory_documents, public.inventory_document_lines to authenticated;