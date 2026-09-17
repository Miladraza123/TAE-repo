-- ==========================================================
-- Stock Transfers (§17, no cost/stock effect by design), Daily Cash Book
-- `sheets` table (§13), and the Professional 15-active-user limit (§24).
-- ==========================================================

create sequence seq_stock_transfer_no;

create table stock_transfers (
  id             uuid primary key default gen_random_uuid(),
  tno            text not null default '',
  tdate          date not null default current_date,
  from_warehouse uuid references warehouses(id),
  to_warehouse   uuid references warehouses(id),
  narration      text,
  version        integer not null default 1,
  created_by     uuid references app_users(id),
  updated_by     uuid references app_users(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz,
  deleted_at     timestamptz,
  check (from_warehouse is distinct from to_warehouse)
);

create unique index stock_transfers_tno_unique_idx on stock_transfers (tno) where deleted_at is null;
create index stock_transfers_active_idx on stock_transfers (deleted_at);

create or replace function assign_stock_transfer_number()
returns trigger language plpgsql set search_path = public as $$
begin
  new.tno := 'ST-' || lpad(nextval('seq_stock_transfer_no')::text, 4, '0');
  return new;
end; $$;

create trigger stock_transfers_assign_number before insert on stock_transfers
  for each row execute function assign_stock_transfer_number();

alter table stock_transfers enable row level security;
create policy stock_transfers_select on stock_transfers for select to authenticated using (true);
create policy stock_transfers_insert on stock_transfers for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create'));
create policy stock_transfers_update on stock_transfers for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy stock_transfers_delete on stock_transfers for delete to authenticated using (is_app_admin());

create trigger stock_transfers_stamp before update on stock_transfers
  for each row execute function stamp_audit_fields();
create trigger stock_transfers_perm before update on stock_transfers
  for each row execute function enforce_perm_on_update('bill_edit', 'bill_delete', 'recycle_bin');
create trigger stock_transfers_audit after insert or update or delete on stock_transfers
  for each row execute function log_audit_event();

create table stock_transfer_lines (
  id          uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references stock_transfers(id) on delete cascade,
  item_id     uuid references items(id),
  qty         numeric not null default 0,
  line_no     integer not null default 1,
  created_at  timestamptz not null default now()
);

create index stock_transfer_lines_transfer_idx on stock_transfer_lines (transfer_id);

alter table stock_transfer_lines enable row level security;
create policy stock_transfer_lines_select on stock_transfer_lines for select to authenticated using (true);
create policy stock_transfer_lines_insert on stock_transfer_lines for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create') or has_perm('bill_edit'));
create policy stock_transfer_lines_update on stock_transfer_lines for update to authenticated
  using (is_app_admin() or has_perm('bill_edit')) with check (is_app_admin() or has_perm('bill_edit'));
create policy stock_transfer_lines_delete on stock_transfer_lines for delete to authenticated
  using (is_app_admin() or has_perm('bill_edit'));

-- ----------------------------------------------------------
-- sheets — Daily Cash Book (§13): one row per calendar day, rows is a
-- jsonb array of fixed-shape [debit_amt, debit_remarks, credit_amt,
-- credit_remarks, debit_check, credit_check, credit_party_id, debit_party_id]
-- ----------------------------------------------------------
create table sheets (
  id          uuid primary key default gen_random_uuid(),
  sheet_date  date not null,
  firm        text,
  opening     numeric not null default 0,
  side        text not null default 'dr' check (side in ('dr','cr')),
  page        text,
  rows        jsonb not null default '[]'::jsonb,
  version     integer not null default 1,
  created_by  uuid references app_users(id),
  updated_by  uuid references app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  deleted_at  timestamptz
);

create unique index sheets_date_unique_idx on sheets (sheet_date) where deleted_at is null;

-- Period lock (§13): blocks any insert/update/delete on a locked date
-- except a pure soft-delete/restore, identical pattern to vouchers.
create or replace function check_period_lock_sheets()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_lock date;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is null then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' and new.sheet_date < v_lock then
    raise exception 'Cannot create a cash-book sheet dated before the locked period (%).', v_lock
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.sheet_date < v_lock then
    if (old.firm, old.opening, old.side, old.page, old.rows) is distinct from (new.firm, new.opening, new.side, new.page, new.rows) then
      raise exception 'This sheet is dated before the locked period (%) and cannot be edited.', v_lock
        using errcode = '23514';
    end if;
  end if;

  if tg_op = 'DELETE' and old.sheet_date < v_lock then
    raise exception 'Cannot permanently delete a sheet dated before the locked period (%).', v_lock
      using errcode = '23514';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger sheets_period_lock
  before insert or update or delete on sheets
  for each row execute function check_period_lock_sheets();

alter table sheets enable row level security;
create policy sheets_select on sheets for select to authenticated using (true);
create policy sheets_insert on sheets for insert to authenticated
  with check (is_app_admin() or has_perm('ledger_create'));
create policy sheets_update on sheets for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy sheets_delete on sheets for delete to authenticated using (is_app_admin());

create trigger sheets_stamp before update on sheets
  for each row execute function stamp_audit_fields();
-- sheets reuses ledger_create as its own "edit" permission — no separate
-- ledger_edit key exists (§22).
create trigger sheets_perm before update on sheets
  for each row execute function enforce_perm_on_update('ledger_create', 'ledger_delete', 'recycle_bin');
create trigger sheets_audit after insert or update or delete on sheets
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- Professional 15-active-user limit (§24) — new requirement, not extracted
-- from source behavior. One small BEFORE INSERT/UPDATE check.
-- ----------------------------------------------------------
create or replace function enforce_active_user_limit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_count integer;
begin
  if new.is_active then
    select count(*) into v_count from app_users
      where is_active = true and id <> new.id;
    if v_count >= 15 then
      raise exception 'Professional plan allows up to 15 active users — deactivate someone first, or upgrade.'
        using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create trigger app_users_active_limit
  before insert or update on app_users
  for each row execute function enforce_active_user_limit();

revoke execute on function assign_stock_transfer_number() from public, anon, authenticated;
revoke execute on function check_period_lock_sheets() from public, anon, authenticated;
revoke execute on function enforce_active_user_limit() from public, anon, authenticated;
