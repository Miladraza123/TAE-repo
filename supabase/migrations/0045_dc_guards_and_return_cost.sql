-- ==========================================================
-- DC guards + Sales Return cost for invoice lines made from a DC
--
-- * voucher_lines: a line without a Masters item must be a custom product
--   (custom_name) that is either delivered on a DC or built from raw
--   materials — never a plain stock line with no item.
-- * An invoice can bill at most what a DC line delivered (summed across
--   every live invoice), and a DC line can't drop below what is billed.
-- * A DC that is already billed can't be deleted (delete the invoice first).
-- * cost_amount on dc_lines / material_issues is engine-only, like
--   voucher_lines.cost_amount.
-- * A Sales Return of a line made from a DC carries the DC's cost back
--   (the sale line itself has no cost: the DC moved the stock).
-- ==========================================================

alter table voucher_lines add constraint voucher_lines_item_or_custom_check
  check (item_id is not null
         or (coalesce(btrim(custom_name), '') <> ''
             and (dc_line_id is not null or consumption_type = 'raw_material_consumption')));

create or replace function voucher_lines_dc_cap()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_dc_qty numeric;
  v_billed numeric;
  v_dc_party uuid;
  v_party uuid;
  v_vtype text;
begin
  if new.dc_line_id is null then return new; end if;
  select dl.qty, dc.party_id into v_dc_qty, v_dc_party
    from dc_lines dl join delivery_challans dc on dc.id = dl.dc_id and dc.deleted_at is null
    where dl.id = new.dc_line_id;
  if v_dc_qty is null then
    raise exception 'This line points to a Delivery Challan that no longer exists.' using errcode = '23514';
  end if;
  select vtype, party_id into v_vtype, v_party from vouchers where id = new.voucher_id;
  if v_vtype <> 'sale' then
    raise exception 'Only a sales invoice can bill a Delivery Challan.' using errcode = '23514';
  end if;
  if v_party is distinct from v_dc_party then
    raise exception 'The invoice party must be the same as the Delivery Challan party.' using errcode = '23514';
  end if;
  select coalesce(sum(vl.qty), 0) into v_billed
    from voucher_lines vl join vouchers v on v.id = vl.voucher_id and v.deleted_at is null
    where vl.dc_line_id = new.dc_line_id and vl.id is distinct from new.id;
  if v_billed + new.qty > v_dc_qty + 0.0005 then
    raise exception 'Billing % but only % is left unbilled on this Delivery Challan line.', new.qty, v_dc_qty - v_billed
      using errcode = '23514';
  end if;
  return new;
end; $$;
create or replace trigger voucher_lines_dc_cap_before before insert or update of qty, dc_line_id on voucher_lines
  for each row execute function voucher_lines_dc_cap();

create or replace function dc_lines_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_billed numeric;
begin
  if coalesce(current_setting('app.system_write', true), '') <> 'on' then
    if tg_op = 'INSERT' then new.cost_amount := null;
    elsif tg_op = 'UPDATE' then new.cost_amount := old.cost_amount;
    end if;
  end if;
  if tg_op = 'INSERT' then return new; end if;
  select coalesce(sum(vl.qty), 0) into v_billed
    from voucher_lines vl join vouchers v on v.id = vl.voucher_id and v.deleted_at is null
    where vl.dc_line_id = old.id;
  if v_billed > 0 then
    if tg_op = 'DELETE' then
      raise exception 'This Delivery Challan line is already billed — delete the invoice line first.' using errcode = '23514';
    end if;
    if new.qty + 0.0005 < v_billed then
      raise exception 'Qty can''t go below % — that much is already billed.', v_billed using errcode = '23514';
    end if;
    if new.item_id is distinct from old.item_id or new.consumption_type is distinct from old.consumption_type then
      raise exception 'This Delivery Challan line is already billed — its item can''t change.' using errcode = '23514';
    end if;
  end if;
  return coalesce(new, old);
end; $$;
create or replace trigger dc_lines_guard_before before insert or update or delete on dc_lines
  for each row execute function dc_lines_guard();

create or replace function delivery_challans_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.deleted_at is null and new.deleted_at is not null and exists (
    select 1 from voucher_lines vl join vouchers v on v.id = vl.voucher_id and v.deleted_at is null
    join dc_lines dl on dl.id = vl.dc_line_id where dl.dc_id = new.id
  ) then
    raise exception 'This Delivery Challan is already billed — delete its invoice first.' using errcode = '23514';
  end if;
  if new.party_id is distinct from old.party_id and exists (
    select 1 from voucher_lines vl join dc_lines dl on dl.id = vl.dc_line_id where dl.dc_id = new.id
  ) then
    raise exception 'This Delivery Challan is already billed — its party can''t change.' using errcode = '23514';
  end if;
  return new;
end; $$;
create or replace trigger delivery_challans_guard_before before update on delivery_challans
  for each row execute function delivery_challans_guard();

create or replace function material_issues_protect_cost()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') <> 'on' then
    if tg_op = 'UPDATE' then new.cost_amount := old.cost_amount; else new.cost_amount := null; end if;
  end if;
  return new;
end; $$;
create or replace trigger material_issues_protect_cost_before before insert or update on material_issues
  for each row execute function material_issues_protect_cost();

create or replace function sales_return_lines_stamp_cost()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_sale_qty numeric;
  v_sale_cost numeric;
  v_dc_line uuid;
begin
  select qty, cost_amount, dc_line_id into v_sale_qty, v_sale_cost, v_dc_line from voucher_lines where id = new.sale_line_id;
  if v_dc_line is not null then
    -- A manufactured product returned does not go back into stock (its
    -- raw material was consumed), so its cost stays spent: carry back 0.
    select dl.qty, case when dl.consumption_type = 'general_goods' then c.cost else 0 end into v_sale_qty, v_sale_cost
      from dc_lines dl join dc_line_costs c on c.dc_line_id = dl.id where dl.id = v_dc_line;
  end if;
  if v_sale_qty is null or v_sale_qty = 0 then
    new.cost_amount := 0;
  else
    new.cost_amount := round((coalesce(v_sale_cost, 0) / v_sale_qty) * new.qty, 2);
  end if;
  return new;
end;
$$;
