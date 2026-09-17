-- ==========================================================
-- Fix: the costing engine's own writes (voucher_lines.cost_amount,
-- items.avg_cost/stock_qty under app.system_write='on') re-fired the AFTER
-- triggers that call recompute_item_cost() again, causing infinite
-- recursion (stack depth exceeded) on the very first sale line insert.
-- Every recompute-trigger wrapper must skip when the write it's reacting
-- to is itself a system-driven write from inside the engine.
-- ==========================================================

create or replace function trg_recompute_voucher_lines()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    if old.item_id is not null then perform recompute_item_cost(old.item_id); end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.item_id is distinct from new.item_id then
    if old.item_id is not null then perform recompute_item_cost(old.item_id); end if;
  end if;

  if new.item_id is not null then perform recompute_item_cost(new.item_id); end if;
  return new;
end;
$$;

create or replace function trg_recompute_sales_return_lines()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    if old.item_id is not null then perform recompute_item_cost(old.item_id); end if;
    return old;
  end if;

  if tg_op = 'UPDATE' and old.item_id is distinct from new.item_id then
    if old.item_id is not null then perform recompute_item_cost(old.item_id); end if;
  end if;

  if new.item_id is not null then perform recompute_item_cost(new.item_id); end if;
  return new;
end;
$$;

create or replace function trg_recompute_sales_returns_header()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_item_id uuid;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is distinct from new.deleted_at then
    for v_item_id in select distinct item_id from sales_return_lines where return_id = new.id and item_id is not null loop
      perform recompute_item_cost(v_item_id);
    end loop;
  end if;
  return new;
end;
$$;

create or replace function trg_recompute_stock_adjustments()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    perform recompute_item_cost(old.item_id);
    return old;
  end if;
  perform recompute_item_cost(new.item_id);
  return new;
end;
$$;

create or replace function trg_recompute_items_opening()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return new;
  end if;
  perform recompute_item_cost(new.id);
  return new;
end;
$$;

create or replace function trg_recompute_vouchers_header()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_item_id uuid;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is distinct from new.deleted_at then
    for v_item_id in select distinct item_id from voucher_lines where voucher_id = new.id and item_id is not null loop
      perform recompute_item_cost(v_item_id);
    end loop;
  end if;
  return new;
end;
$$;
