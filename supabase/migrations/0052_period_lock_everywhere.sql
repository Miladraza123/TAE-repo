-- ==========================================================
-- Period Lock that actually locks. Before this:
--  * soft-delete / restore of a locked bill or ledger sheet was allowed
--    (the header check compared business columns only, not deleted_at);
--  * sales returns, service invoices, stock adjustments, stock transfers
--    had no lock check at all;
--  * lines (bill lines, ledger rows, return lines, raw material used, DC
--    lines …) were only checked when saved through apply_merged_lines —
--    any other write path could change a locked document's lines.
-- Now every table that moves money or stock refuses insert / change /
-- delete / restore when its document date (or its parent's) is before
-- the lock. System recomputes (app.system_write) still pass.
-- locked_before keeps its meaning: dates BEFORE it are locked.
-- ==========================================================

create or replace function check_period_lock_doc()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_lock date; v_col text := tg_argv[0]; v_old date; v_new date;
  v_skip text[] := array['updated_at', 'updated_by', 'version'];
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then return coalesce(new, old); end if;
  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is null then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and (to_jsonb(new) - v_skip) = (to_jsonb(old) - v_skip) then return new; end if;
  if tg_op <> 'INSERT' then v_old := (to_jsonb(old) ->> v_col)::date; end if;
  if tg_op <> 'DELETE' then v_new := (to_jsonb(new) ->> v_col)::date; end if;
  if (v_old is not null and v_old < v_lock) or (v_new is not null and v_new < v_lock) then
    raise exception 'Period Lock: entries up to % are locked — they can''t be added, changed, deleted or restored.',
      to_char(v_lock - 1, 'DD Mon YYYY') using errcode = '23514';
  end if;
  return coalesce(new, old);
end; $$;

-- Lines: argv = parent table, fk column on the line, date column on the parent.
create or replace function check_period_lock_line()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_lock date; v_parent text := tg_argv[0]; v_fk text := tg_argv[1]; v_col text := tg_argv[2];
  v_old date; v_new date; v_id text;
  v_skip text[] := array['cost_amount', 'updated_at'];
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then return coalesce(new, old); end if;
  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is null then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and (to_jsonb(new) - v_skip) = (to_jsonb(old) - v_skip) then return new; end if;
  if tg_op <> 'INSERT' then
    v_id := to_jsonb(old) ->> v_fk;
    if v_id is not null then execute format('select %I from %I where id = $1', v_col, v_parent) into v_old using v_id::uuid; end if;
  end if;
  if tg_op <> 'DELETE' then
    v_id := to_jsonb(new) ->> v_fk;
    if v_id is not null then execute format('select %I from %I where id = $1', v_col, v_parent) into v_new using v_id::uuid; end if;
  end if;
  if (v_old is not null and v_old < v_lock) or (v_new is not null and v_new < v_lock) then
    raise exception 'Period Lock: entries up to % are locked — this document''s lines can''t be changed.',
      to_char(v_lock - 1, 'DD Mon YYYY') using errcode = '23514';
  end if;
  return coalesce(new, old);
end; $$;

-- Raw material used on a sale line, and material restored on a return
-- line: two levels up to the dated document.
create or replace function check_period_lock_vlmc()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_lock date; v_old date; v_new date;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then return coalesce(new, old); end if;
  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is null then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'cost_amount') = (to_jsonb(old) - 'cost_amount') then return new; end if;
  if tg_op <> 'INSERT' then
    select v.vdate into v_old from voucher_lines vl join vouchers v on v.id = vl.voucher_id where vl.id = old.voucher_line_id;
  end if;
  if tg_op <> 'DELETE' then
    select v.vdate into v_new from voucher_lines vl join vouchers v on v.id = vl.voucher_id where vl.id = new.voucher_line_id;
  end if;
  if (v_old is not null and v_old < v_lock) or (v_new is not null and v_new < v_lock) then
    raise exception 'Period Lock: entries up to % are locked — this bill''s raw material can''t be changed.',
      to_char(v_lock - 1, 'DD Mon YYYY') using errcode = '23514';
  end if;
  return coalesce(new, old);
end; $$;

create or replace function check_period_lock_srmr()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_lock date; v_old date; v_new date;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then return coalesce(new, old); end if;
  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is null then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'cost_amount') = (to_jsonb(old) - 'cost_amount') then return new; end if;
  if tg_op <> 'INSERT' then
    select r.rdate into v_old from sales_return_lines l join sales_returns r on r.id = l.return_id where l.id = old.return_line_id;
  end if;
  if tg_op <> 'DELETE' then
    select r.rdate into v_new from sales_return_lines l join sales_returns r on r.id = l.return_id where l.id = new.return_line_id;
  end if;
  if (v_old is not null and v_old < v_lock) or (v_new is not null and v_new < v_lock) then
    raise exception 'Period Lock: entries up to % are locked — this return can''t be changed.',
      to_char(v_lock - 1, 'DD Mon YYYY') using errcode = '23514';
  end if;
  return coalesce(new, old);
end; $$;

-- Documents (the old vouchers/sheets triggers are replaced in place).
create or replace trigger vouchers_period_lock before insert or update or delete on vouchers
  for each row execute function check_period_lock_doc('vdate');
create or replace trigger sheets_period_lock before insert or update or delete on sheets
  for each row execute function check_period_lock_doc('sheet_date');
create or replace trigger sales_returns_period_lock before insert or update or delete on sales_returns
  for each row execute function check_period_lock_doc('rdate');
create or replace trigger service_invoices_period_lock before insert or update or delete on service_invoices
  for each row execute function check_period_lock_doc('sidate');
create or replace trigger stock_adjustments_period_lock before insert or update or delete on stock_adjustments
  for each row execute function check_period_lock_doc('adj_date');
create or replace trigger stock_transfers_period_lock before insert or update or delete on stock_transfers
  for each row execute function check_period_lock_doc('tdate');

-- Lines.
create or replace trigger voucher_lines_period_lock before insert or update or delete on voucher_lines
  for each row execute function check_period_lock_line('vouchers', 'voucher_id', 'vdate');
create or replace trigger sheet_rows_period_lock before insert or update or delete on sheet_rows
  for each row execute function check_period_lock_line('sheets', 'sheet_id', 'sheet_date');
create or replace trigger sales_return_lines_period_lock before insert or update or delete on sales_return_lines
  for each row execute function check_period_lock_line('sales_returns', 'return_id', 'rdate');
create or replace trigger service_invoice_lines_period_lock before insert or update or delete on service_invoice_lines
  for each row execute function check_period_lock_line('service_invoices', 'invoice_id', 'sidate');
create or replace trigger stock_transfer_lines_period_lock before insert or update or delete on stock_transfer_lines
  for each row execute function check_period_lock_line('stock_transfers', 'transfer_id', 'tdate');
create or replace trigger dc_lines_period_lock before insert or update or delete on dc_lines
  for each row execute function check_period_lock_line('delivery_challans', 'dc_id', 'dc_date');
create or replace trigger vlmc_period_lock before insert or update or delete on voucher_line_material_consumption
  for each row execute function check_period_lock_vlmc();
create or replace trigger srmr_period_lock before insert or update or delete on sales_return_material_restoration
  for each row execute function check_period_lock_srmr();
