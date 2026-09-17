-- ==========================================================
-- Transactional schema needed by the costing engine (§18): vouchers
-- (sale/purchase, §9/§10), sales_returns (§6), stock_adjustments (§12).
-- UI/validation for these lands in later phases; this migration is the
-- schema + numbering + cost-carry-back/returnable-qty triggers only.
-- ==========================================================

create sequence seq_sale_no;
create sequence seq_purchase_no;
create sequence seq_sales_return_no;

-- ----------------------------------------------------------
-- vouchers — sale + purchase invoices, distinguished by vtype (§6/§9/§10)
-- ----------------------------------------------------------
create table vouchers (
  id            uuid primary key default gen_random_uuid(),
  vtype         text not null check (vtype in ('sale','purchase')),
  vno           text not null default '',
  vdate         date not null default current_date,
  due_date      date,
  party_id      uuid references parties(id),
  company_id    uuid references companies(id),
  narration     text,
  tax_on        boolean not null default false,
  sub_total     numeric not null default 0,
  discount      numeric not null default 0,
  tax_total     numeric not null default 0,
  grand_total   numeric not null default 0,
  paid          numeric not null default 0,
  loading_on    boolean not null default false,
  loading_amt   numeric not null default 0,
  cartage_on    boolean not null default false,
  cartage_amt   numeric not null default 0,
  cutting_on    boolean not null default false,
  cutting_amt   numeric not null default 0,
  version       integer not null default 1,
  created_by    uuid references app_users(id),
  updated_by    uuid references app_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz,
  deleted_at    timestamptz
);

create unique index vouchers_vno_unique_idx on vouchers (vtype, vno) where deleted_at is null;
create index vouchers_party_idx on vouchers (party_id);
create index vouchers_vdate_idx on vouchers (vdate);
create index vouchers_active_idx on vouchers (deleted_at);

-- Server-side numbering (§6's corrected recommendation): always assigned on
-- INSERT from a dedicated sequence, never trusts a client-supplied value.
create or replace function assign_voucher_number()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.vtype = 'sale' then
    new.vno := 'S-' || lpad(nextval('seq_sale_no')::text, 4, '0');
  elsif new.vtype = 'purchase' then
    new.vno := 'P-' || lpad(nextval('seq_purchase_no')::text, 4, '0');
  end if;
  return new;
end;
$$;

create trigger vouchers_assign_number
  before insert on vouchers
  for each row execute function assign_voucher_number();

-- Period lock: blocks any change to a voucher dated before the lock, except
-- a pure soft-delete/restore (deleted_at-only change) (§9/§12).
create or replace function check_period_lock_vouchers()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_lock date;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return new;
  end if;
  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is null then
    return new;
  end if;

  if tg_op = 'INSERT' and new.vdate < v_lock then
    raise exception 'Cannot create a voucher dated before the locked period (%).', v_lock
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.vdate < v_lock then
    -- allow if this update ONLY changes deleted_at (soft-delete/restore)
    if (old.vno, old.vtype, old.vdate, old.due_date, old.party_id, old.company_id,
        old.narration, old.tax_on, old.sub_total, old.discount, old.tax_total,
        old.grand_total, old.paid, old.loading_on, old.loading_amt, old.cartage_on,
        old.cartage_amt, old.cutting_on, old.cutting_amt)
       is distinct from
       (new.vno, new.vtype, new.vdate, new.due_date, new.party_id, new.company_id,
        new.narration, new.tax_on, new.sub_total, new.discount, new.tax_total,
        new.grand_total, new.paid, new.loading_on, new.loading_amt, new.cartage_on,
        new.cartage_amt, new.cutting_on, new.cutting_amt)
    then
      raise exception 'This voucher is dated before the locked period (%) and cannot be edited.', v_lock
        using errcode = '23514';
    end if;
  end if;

  if tg_op = 'DELETE' and old.vdate < v_lock then
    raise exception 'Cannot permanently delete a voucher dated before the locked period (%).', v_lock
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger vouchers_period_lock
  before insert or update or delete on vouchers
  for each row execute function check_period_lock_vouchers();

alter table vouchers enable row level security;

create policy vouchers_select on vouchers for select to authenticated using (true);
create policy vouchers_insert on vouchers for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create'));
create policy vouchers_update on vouchers for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy vouchers_delete on vouchers for delete to authenticated using (is_app_admin());

create trigger vouchers_stamp before update on vouchers
  for each row execute function stamp_audit_fields();
create trigger vouchers_perm before update on vouchers
  for each row execute function enforce_perm_on_update('bill_edit', 'bill_delete', 'recycle_bin');
create trigger vouchers_audit after insert or update or delete on vouchers
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- voucher_lines
-- ----------------------------------------------------------
create table voucher_lines (
  id           uuid primary key default gen_random_uuid(),
  voucher_id   uuid not null references vouchers(id) on delete cascade,
  line_no      integer not null default 1,
  item_id      uuid references items(id),
  qty          numeric not null default 0, -- always in the item's base unit
  rate         numeric not null default 0,
  tax_pct      numeric not null default 0,
  amount       numeric not null default 0,
  cost_amount  numeric, -- COGS at time of sale — costing engine only, never client-set
  pcs_on       boolean not null default false,
  pcs          numeric,
  warehouse_id uuid references warehouses(id),
  sale_unit    text,
  sale_qty     numeric,
  unit_factor  numeric not null default 1,
  created_at   timestamptz not null default now()
);

create index voucher_lines_voucher_idx on voucher_lines (voucher_id);
create index voucher_lines_item_idx on voucher_lines (item_id);

-- cost_amount is engine-owned: protect it from direct client writes exactly
-- like items.avg_cost/stock_qty (§18).
create or replace function voucher_lines_protect_cost()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') <> 'on' then
    if tg_op = 'UPDATE' then
      new.cost_amount := old.cost_amount;
    else
      new.cost_amount := null;
    end if;
  end if;
  return new;
end;
$$;

create trigger voucher_lines_protect_cost_before
  before insert or update on voucher_lines
  for each row execute function voucher_lines_protect_cost();

alter table voucher_lines enable row level security;

create policy voucher_lines_select on voucher_lines for select to authenticated using (true);
create policy voucher_lines_insert on voucher_lines for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create') or has_perm('bill_edit')
    or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy voucher_lines_update on voucher_lines for update to authenticated
  using (is_app_admin() or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on')
  with check (is_app_admin() or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy voucher_lines_delete on voucher_lines for delete to authenticated
  using (is_app_admin() or has_perm('bill_edit'));

-- ----------------------------------------------------------
-- sales_returns / sales_return_lines
-- ----------------------------------------------------------
create table sales_returns (
  id           uuid primary key default gen_random_uuid(),
  rno          text not null default '',
  sale_id      uuid references vouchers(id),
  party_id     uuid references parties(id),
  rdate        date not null default current_date,
  narration    text,
  subtotal     numeric not null default 0,
  grand_total  numeric not null default 0,
  version      integer not null default 1,
  created_by   uuid references app_users(id),
  updated_by   uuid references app_users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz,
  deleted_at   timestamptz
);

create unique index sales_returns_rno_unique_idx on sales_returns (rno) where deleted_at is null;
create index sales_returns_sale_idx on sales_returns (sale_id);
create index sales_returns_party_idx on sales_returns (party_id);
create index sales_returns_active_idx on sales_returns (deleted_at);

create or replace function assign_sales_return_number()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.rno := 'SR-' || lpad(nextval('seq_sales_return_no')::text, 4, '0');
  return new;
end;
$$;

create trigger sales_returns_assign_number
  before insert on sales_returns
  for each row execute function assign_sales_return_number();

alter table sales_returns enable row level security;

create policy sales_returns_select on sales_returns for select to authenticated using (true);
create policy sales_returns_insert on sales_returns for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create'));
create policy sales_returns_update on sales_returns for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy sales_returns_delete on sales_returns for delete to authenticated using (is_app_admin());

create trigger sales_returns_stamp before update on sales_returns
  for each row execute function stamp_audit_fields();
create trigger sales_returns_perm before update on sales_returns
  for each row execute function enforce_perm_on_update('bill_edit', 'bill_delete', 'recycle_bin');
create trigger sales_returns_audit after insert or update or delete on sales_returns
  for each row execute function log_audit_event();

create table sales_return_lines (
  id           uuid primary key default gen_random_uuid(),
  return_id    uuid not null references sales_returns(id) on delete cascade,
  sale_line_id uuid not null references voucher_lines(id),
  item_id      uuid references items(id),
  qty          numeric not null default 0,
  rate         numeric not null default 0,
  amount       numeric not null default 0,
  cost_amount  numeric not null default 0, -- auto-stamped, carries back the ORIGINAL sale's per-unit cost
  line_no      integer not null default 1,
  warehouse_id uuid references warehouses(id),
  sale_unit    text,
  sale_qty     numeric,
  unit_factor  numeric not null default 1,
  created_at   timestamptz not null default now()
);

create index sales_return_lines_return_idx on sales_return_lines (return_id);
create index sales_return_lines_sale_line_idx on sales_return_lines (sale_line_id);

-- Cap return qty at what's still returnable on the specific original sale
-- line (sold qty minus what's already been returned against it), correctly
-- excluding THIS row's own prior value when editing an existing return line.
create or replace function sales_return_lines_cap_qty()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_sold_qty numeric;
  v_already_returned numeric;
  v_returnable numeric;
begin
  select qty into v_sold_qty from voucher_lines where id = new.sale_line_id;
  if v_sold_qty is null then
    raise exception 'Return line must reference a real original sale line' using errcode = '23514';
  end if;

  select coalesce(sum(qty), 0) into v_already_returned
  from sales_return_lines srl
  join sales_returns sr on sr.id = srl.return_id
  where srl.sale_line_id = new.sale_line_id
    and sr.deleted_at is null
    and srl.id is distinct from new.id;

  v_returnable := v_sold_qty - v_already_returned;
  if new.qty > v_returnable then
    raise exception 'Return quantity (%) exceeds what is still returnable on this sale line (%)', new.qty, v_returnable
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger sales_return_lines_cap_qty_before
  before insert or update on sales_return_lines
  for each row execute function sales_return_lines_cap_qty();

-- Auto-stamp cost_amount from the ORIGINAL sale line's own per-unit cost,
-- not today's average (§6/§18) — runs BEFORE the costing engine's own
-- recompute trigger on this table.
create or replace function sales_return_lines_stamp_cost()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_sale_qty numeric;
  v_sale_cost numeric;
begin
  select qty, cost_amount into v_sale_qty, v_sale_cost from voucher_lines where id = new.sale_line_id;
  if v_sale_qty is null or v_sale_qty = 0 then
    new.cost_amount := 0;
  else
    new.cost_amount := round((coalesce(v_sale_cost, 0) / v_sale_qty) * new.qty, 2);
  end if;
  return new;
end;
$$;

create trigger sales_return_lines_stamp_cost_before
  before insert or update on sales_return_lines
  for each row execute function sales_return_lines_stamp_cost();

alter table sales_return_lines enable row level security;

create policy sales_return_lines_select on sales_return_lines for select to authenticated using (true);
create policy sales_return_lines_insert on sales_return_lines for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create') or has_perm('bill_edit'));
create policy sales_return_lines_update on sales_return_lines for update to authenticated
  using (is_app_admin() or has_perm('bill_edit')) with check (is_app_admin() or has_perm('bill_edit'));
create policy sales_return_lines_delete on sales_return_lines for delete to authenticated
  using (is_app_admin() or has_perm('bill_edit'));

-- ----------------------------------------------------------
-- stock_adjustments (§12) — shares bill_create/bill_edit/bill_delete like
-- stock_transfers do (§17): no dedicated permission key exists for either.
-- ----------------------------------------------------------
create table stock_adjustments (
  id          uuid primary key default gen_random_uuid(),
  item_id     uuid not null references items(id),
  qty         numeric not null, -- positive adds, negative removes
  reason      text,
  adj_date    date not null default current_date,
  version     integer not null default 1,
  created_by  uuid references app_users(id),
  updated_by  uuid references app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  deleted_at  timestamptz
);

create index stock_adjustments_item_idx on stock_adjustments (item_id);
create index stock_adjustments_active_idx on stock_adjustments (deleted_at);

alter table stock_adjustments enable row level security;

create policy stock_adjustments_select on stock_adjustments for select to authenticated using (true);
create policy stock_adjustments_insert on stock_adjustments for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create'));
create policy stock_adjustments_update on stock_adjustments for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy stock_adjustments_delete on stock_adjustments for delete to authenticated using (is_app_admin());

create trigger stock_adjustments_stamp before update on stock_adjustments
  for each row execute function stamp_audit_fields();
create trigger stock_adjustments_perm before update on stock_adjustments
  for each row execute function enforce_perm_on_update('bill_edit', 'bill_delete', 'recycle_bin');
create trigger stock_adjustments_audit after insert or update or delete on stock_adjustments
  for each row execute function log_audit_event();

revoke execute on function assign_voucher_number() from public, anon, authenticated;
revoke execute on function check_period_lock_vouchers() from public, anon, authenticated;
revoke execute on function voucher_lines_protect_cost() from public, anon, authenticated;
revoke execute on function assign_sales_return_number() from public, anon, authenticated;
revoke execute on function sales_return_lines_cap_qty() from public, anon, authenticated;
revoke execute on function sales_return_lines_stamp_cost() from public, anon, authenticated;
