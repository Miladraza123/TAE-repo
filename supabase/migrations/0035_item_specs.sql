-- ==========================================================
-- item_specs: label/value specifications per item
-- Applied directly to the live TAE database on 2026-09-26 (Supabase migration
-- 20260926093729_create_item_specs_table) and checked in here afterwards so a fresh project built from this
-- folder matches production.
-- ==========================================================
create table item_specs (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references items(id) on delete cascade,
  label text not null,
  value text not null,
  line_no integer not null default 1,
  version integer not null default 1,
  created_by uuid references app_users(id),
  updated_by uuid references app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  deleted_at timestamptz
);
alter table item_specs enable row level security;
create policy item_specs_select on item_specs for select using (true);
create policy item_specs_insert on item_specs for insert with check (is_app_admin() or has_perm('masters_edit'));
create policy item_specs_update on item_specs for update using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy item_specs_delete on item_specs for delete using (is_app_admin());
create trigger item_specs_audit after insert or update or delete on item_specs
  for each row execute function log_audit_event();
create trigger item_specs_perm before update on item_specs
  for each row execute function enforce_perm_on_update('masters_edit', 'masters_delete', 'recycle_bin');
create trigger item_specs_stamp before update on item_specs
  for each row execute function stamp_audit_fields();
