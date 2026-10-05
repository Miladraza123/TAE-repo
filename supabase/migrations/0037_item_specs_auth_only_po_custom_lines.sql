-- ==========================================================
-- 1) item_specs: its four policies were created without a role
--    (0035), so they applied to PUBLIC — including the anon role, which
--    could read every item's specs with just the public anon key. Every
--    other table limits its policies to `authenticated`; recreate these
--    four the same way. Same conditions as before, only the role changes.
--
-- 2) po_lines: custom (non-stock) item lines on Purchase Orders, the
--    same as quotation_lines already has (0032/0036). item_id is already
--    nullable on po_lines. Converting a PO to a Purchase skips these
--    lines (a purchase line must be a real stock item) — handled in
--    billing.html, which tells the user how many were left out.
-- ==========================================================

drop policy if exists item_specs_select on item_specs;
drop policy if exists item_specs_insert on item_specs;
drop policy if exists item_specs_update on item_specs;
drop policy if exists item_specs_delete on item_specs;

create policy item_specs_select on item_specs for select to authenticated using (true);
create policy item_specs_insert on item_specs for insert to authenticated
  with check (is_app_admin() or has_perm('masters_edit'));
create policy item_specs_update on item_specs for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy item_specs_delete on item_specs for delete to authenticated using (is_app_admin());

alter table po_lines add column if not exists custom_name text;
alter table po_lines add column if not exists custom_unit text;
