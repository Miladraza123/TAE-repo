-- ==========================================================
-- Parties + Party Kinds + Items + item_units + Services (§8/§9 masters)
-- Plus the two period-lock-invalidated caches that belong to this layer:
-- item_cost_snapshot and party_opening_balances (§6/§18).
-- ==========================================================

-- ----------------------------------------------------------
-- party_kinds — custom categories beyond the built-in kind values, UI only
-- ----------------------------------------------------------
create table party_kinds (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  version     integer not null default 1,
  created_by  uuid references app_users(id),
  updated_by  uuid references app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  deleted_at  timestamptz
);

alter table party_kinds enable row level security;

create policy party_kinds_select on party_kinds for select to authenticated using (true);
create policy party_kinds_insert on party_kinds for insert to authenticated
  with check (is_app_admin() or has_perm('masters_categories'));
create policy party_kinds_update on party_kinds for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy party_kinds_delete on party_kinds for delete to authenticated using (is_app_admin());

create trigger party_kinds_stamp before update on party_kinds
  for each row execute function stamp_audit_fields();
create trigger party_kinds_perm before update on party_kinds
  for each row execute function enforce_perm_on_update('masters_categories', 'masters_categories', 'masters_categories');
create trigger party_kinds_audit after insert or update or delete on party_kinds
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- parties — customers, suppliers, AND expense heads (kind='expense', §6)
-- ----------------------------------------------------------
create table parties (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  kind          text not null default 'customer' check (kind in ('customer','supplier','both','expense')),
  phone         text,
  city          text,
  address       text,
  ntn           text,
  opening       numeric not null default 0,
  opening_side  text not null default 'dr' check (opening_side in ('dr','cr')),
  opening_date  date,
  credit_days   integer not null default 0,
  expense_type  text, -- only meaningful when kind='expense'; 'bank_charges' is the one recognized special value
  notes         text,
  active        boolean not null default true,
  version       integer not null default 1,
  created_by    uuid references app_users(id),
  updated_by    uuid references app_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz,
  deleted_at    timestamptz
);

create index parties_active_idx on parties (deleted_at);
create index parties_kind_idx on parties (kind);
create index parties_name_idx on parties (name);

alter table parties enable row level security;

create policy parties_select on parties for select to authenticated using (true);
create policy parties_insert on parties for insert to authenticated
  with check (is_app_admin() or has_perm('masters_edit'));
create policy parties_update on parties for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy parties_delete on parties for delete to authenticated using (is_app_admin());

create trigger parties_stamp before update on parties
  for each row execute function stamp_audit_fields();
create trigger parties_perm before update on parties
  for each row execute function enforce_perm_on_update('masters_edit', 'masters_delete', 'recycle_bin');
create trigger parties_audit after insert or update or delete on parties
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- items
-- ----------------------------------------------------------
create table items (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  unit           text not null default 'pcs',
  sale_rate      numeric not null default 0,
  buy_rate       numeric not null default 0,
  tax_pct        numeric not null default 0,
  opening_qty    numeric not null default 0,
  opening_rate   numeric not null default 0,
  hs_code        text,
  notes          text,
  reorder_level  numeric not null default 0,
  active         boolean not null default true,
  avg_cost       numeric not null default 0, -- computed by the costing engine only, §18
  stock_qty      numeric not null default 0, -- computed by the costing engine only, §18 — GLOBAL, not per-warehouse
  version        integer not null default 1,
  created_by     uuid references app_users(id),
  updated_by     uuid references app_users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz,
  deleted_at     timestamptz
);

create index items_active_idx on items (deleted_at);
create index items_name_idx on items (name);

-- avg_cost/stock_qty are computed-only columns: no direct write path, ever,
-- even for an admin — only the costing engine (running under the
-- app.system_write flag) may change them. Editing opening_qty/opening_rate
-- is allowed (it feeds the costing replay) and is NOT blocked here.
create or replace function items_protect_computed_cols()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') <> 'on' then
    new.avg_cost := old.avg_cost;
    new.stock_qty := old.stock_qty;
  end if;
  return new;
end;
$$;

create trigger items_protect_computed_before
  before update on items
  for each row execute function items_protect_computed_cols();

alter table items enable row level security;

create policy items_select on items for select to authenticated using (true);
create policy items_insert on items for insert to authenticated
  with check (is_app_admin() or has_perm('masters_edit'));
create policy items_update on items for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy items_delete on items for delete to authenticated using (is_app_admin());

create trigger items_stamp before update on items
  for each row execute function stamp_audit_fields();
create trigger items_perm before update on items
  for each row execute function enforce_perm_on_update('masters_edit', 'masters_delete', 'recycle_bin');
create trigger items_audit after insert or update or delete on items
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- item_units — alternate selling units + conversion factor to the base unit
-- ----------------------------------------------------------
create table item_units (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid not null references items(id) on delete cascade,
  unit        text not null,
  factor      numeric not null default 1, -- 1 <unit> = <factor> base units
  version     integer not null default 1,
  created_by  uuid references app_users(id),
  updated_by  uuid references app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  deleted_at  timestamptz
);

create index item_units_item_idx on item_units (item_id);

alter table item_units enable row level security;

create policy item_units_select on item_units for select to authenticated using (true);
create policy item_units_insert on item_units for insert to authenticated
  with check (is_app_admin() or has_perm('masters_edit'));
create policy item_units_update on item_units for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy item_units_delete on item_units for delete to authenticated using (is_app_admin());

create trigger item_units_stamp before update on item_units
  for each row execute function stamp_audit_fields();
create trigger item_units_perm before update on item_units
  for each row execute function enforce_perm_on_update('masters_edit', 'masters_delete', 'recycle_bin');
create trigger item_units_audit after insert or update or delete on item_units
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- services — billable service catalog (referenced by §31 step 4 / §28's
-- permission-gap note alongside service_invoices/service_quotations;
-- prefills service_invoice_lines/service_quotation_lines the same way
-- items prefill voucher_lines).
-- ----------------------------------------------------------
create table services (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  rate        numeric not null default 0,
  tax_pct     numeric not null default 0,
  notes       text,
  active      boolean not null default true,
  version     integer not null default 1,
  created_by  uuid references app_users(id),
  updated_by  uuid references app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  deleted_at  timestamptz
);

create index services_active_idx on services (deleted_at);
create index services_name_idx on services (name);

alter table services enable row level security;

create policy services_select on services for select to authenticated using (true);
create policy services_insert on services for insert to authenticated
  with check (is_app_admin() or has_perm('masters_edit'));
create policy services_update on services for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy services_delete on services for delete to authenticated using (is_app_admin());

create trigger services_stamp before update on services
  for each row execute function stamp_audit_fields();
create trigger services_perm before update on services
  for each row execute function enforce_perm_on_update('masters_edit', 'masters_delete', 'recycle_bin');
create trigger services_audit after insert or update or delete on services
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- item_cost_snapshot — costing checkpoint cache (§6/§18)
-- ----------------------------------------------------------
create table item_cost_snapshot (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid not null references items(id) on delete cascade,
  as_of_date  date not null,
  avg_cost    numeric not null default 0,
  stock_qty   numeric not null default 0,
  created_at  timestamptz not null default now(),
  unique (item_id, as_of_date)
);

alter table item_cost_snapshot enable row level security;

create policy item_cost_snapshot_select on item_cost_snapshot for select to authenticated using (true);
create policy item_cost_snapshot_write on item_cost_snapshot for all to authenticated
  using (is_app_admin() or has_perm('period_lock'))
  with check (is_app_admin() or has_perm('period_lock'));

-- ----------------------------------------------------------
-- party_opening_balances — ledger opening-balance checkpoint cache (§6/§11)
-- ----------------------------------------------------------
create table party_opening_balances (
  id             uuid primary key default gen_random_uuid(),
  party_id       uuid not null references parties(id) on delete cascade,
  as_of_date     date not null,
  balance        numeric not null default 0,
  last_txn_date  date,
  created_at     timestamptz not null default now(),
  unique (party_id, as_of_date)
);

alter table party_opening_balances enable row level security;

create policy party_opening_balances_select on party_opening_balances for select to authenticated using (true);
create policy party_opening_balances_write on party_opening_balances for all to authenticated
  using (is_app_admin() or has_perm('period_lock'))
  with check (is_app_admin() or has_perm('period_lock'));

-- ----------------------------------------------------------
-- period_lock invalidation: changing locked_before empties both caches,
-- forcing a fresh recompute next time they're needed (§6/§13).
-- SECURITY DEFINER so it can clear the caches regardless of the acting
-- user's own delete rights on those two tables.
-- ----------------------------------------------------------
create or replace function period_lock_invalidate_snapshots()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from item_cost_snapshot;
  delete from party_opening_balances;
  return new;
end;
$$;

create trigger period_lock_invalidate
  after update on period_lock
  for each row
  when (old.locked_before is distinct from new.locked_before)
  execute function period_lock_invalidate_snapshots();

revoke execute on function items_protect_computed_cols() from public, anon, authenticated;
revoke execute on function period_lock_invalidate_snapshots() from public, anon, authenticated;
