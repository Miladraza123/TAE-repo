-- ==========================================================
-- Auto Cost & Profit Engine (§18) — moving weighted-average costing with
-- landed purchase costs. Two-layer design:
--   _recompute_item_cost_core(item, full)  — pure replay logic, ASSUMES
--     app.system_write is already 'on' (never call directly from a trigger).
--   recompute_item_cost(item, full)        — public entry point: manages
--     the system_write flag itself, safe to call from triggers or RPCs.
--   recompute_all_item_costs(lock_date)    — admin rebuild-everything,
--     manages the flag once for the whole loop.
-- ==========================================================

create or replace function _recompute_item_cost_core(p_item_id uuid, p_full boolean)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_lock_date   date;
  v_qty         numeric;
  v_avg_cost    numeric;
  v_start_date  date;
  v_full_replay boolean;
  v_do_snapshot boolean;
  v_snapshotted boolean := false;
  r             record;
  v_new_cost    numeric;
begin
  select locked_before into v_lock_date from period_lock where id = 1;

  if not p_full and v_lock_date is not null then
    select stock_qty, avg_cost into v_qty, v_avg_cost
    from item_cost_snapshot where item_id = p_item_id and as_of_date = v_lock_date;
  end if;

  if v_qty is null then
    select opening_qty, opening_rate into v_qty, v_avg_cost from items where id = p_item_id;
    v_qty := coalesce(v_qty, 0);
    v_avg_cost := coalesce(v_avg_cost, 0);
    v_start_date := null; -- replay everything
    v_full_replay := true;
  else
    v_start_date := v_lock_date;
    v_full_replay := false;
  end if;

  v_do_snapshot := v_lock_date is not null and v_full_replay;

  for r in (
    with voucher_totals as (
      select v.id as voucher_id,
             sum(vl.qty * vl.rate) as total_amount,
             (case when v.loading_on then v.loading_amt else 0 end
            + case when v.cartage_on then v.cartage_amt else 0 end
            + case when v.cutting_on then v.cutting_amt else 0 end) as extra_charges
      from vouchers v
      join voucher_lines vl on vl.voucher_id = v.id
      where v.vtype = 'purchase' and v.deleted_at is null
      group by v.id
    ),
    events as (
      select vl.id as line_id, 'purchase'::text as kind, v.vdate as evt_date, vl.qty as qty,
             case when coalesce(vt.total_amount, 0) = 0 or vl.qty = 0 then vl.rate
                  else vl.rate + (vt.extra_charges * (vl.qty * vl.rate) / vt.total_amount) / vl.qty
             end as rate,
             null::numeric as return_cost
      from voucher_lines vl
      join vouchers v on v.id = vl.voucher_id and v.vtype = 'purchase' and v.deleted_at is null
      left join voucher_totals vt on vt.voucher_id = v.id
      where vl.item_id = p_item_id and (v_start_date is null or v.vdate >= v_start_date)

      union all

      select vl.id, 'sale', v.vdate, vl.qty, null::numeric, null::numeric
      from voucher_lines vl
      join vouchers v on v.id = vl.voucher_id and v.vtype = 'sale' and v.deleted_at is null
      where vl.item_id = p_item_id and (v_start_date is null or v.vdate >= v_start_date)

      union all

      select srl.id, 'return', sr.rdate, srl.qty, null::numeric, srl.cost_amount
      from sales_return_lines srl
      join sales_returns sr on sr.id = srl.return_id and sr.deleted_at is null
      where srl.item_id = p_item_id and (v_start_date is null or sr.rdate >= v_start_date)

      union all

      select sa.id, 'adjustment', sa.adj_date, sa.qty, null::numeric, null::numeric
      from stock_adjustments sa
      where sa.item_id = p_item_id and sa.deleted_at is null
        and (v_start_date is null or sa.adj_date >= v_start_date)
    )
    select * from events order by evt_date, line_id
  )
  loop
    if v_do_snapshot and not v_snapshotted and r.evt_date > v_lock_date then
      insert into item_cost_snapshot (item_id, as_of_date, avg_cost, stock_qty)
      values (p_item_id, v_lock_date, v_avg_cost, v_qty)
      on conflict (item_id, as_of_date) do update set avg_cost = excluded.avg_cost, stock_qty = excluded.stock_qty;
      v_snapshotted := true;
    end if;

    if r.kind = 'purchase' then
      v_new_cost := round(((v_qty * v_avg_cost) + (r.qty * r.rate)) / nullif(v_qty + r.qty, 0), 4);
      v_avg_cost := coalesce(v_new_cost, r.rate, v_avg_cost);
      v_qty := v_qty + r.qty;

    elsif r.kind = 'sale' then
      update voucher_lines set cost_amount = round(r.qty * v_avg_cost, 2) where id = r.line_id;
      v_qty := v_qty - r.qty;

    elsif r.kind = 'return' then
      v_new_cost := round(((v_qty * v_avg_cost) + coalesce(r.return_cost, 0)) / nullif(v_qty + r.qty, 0), 4);
      v_avg_cost := coalesce(v_new_cost, v_avg_cost);
      v_qty := v_qty + r.qty;

    elsif r.kind = 'adjustment' then
      v_qty := v_qty + r.qty;
    end if;
  end loop;

  if v_do_snapshot and not v_snapshotted then
    insert into item_cost_snapshot (item_id, as_of_date, avg_cost, stock_qty)
    values (p_item_id, v_lock_date, v_avg_cost, v_qty)
    on conflict (item_id, as_of_date) do update set avg_cost = excluded.avg_cost, stock_qty = excluded.stock_qty;
  end if;

  update items set avg_cost = coalesce(v_avg_cost, 0), stock_qty = coalesce(v_qty, 0) where id = p_item_id;
end;
$$;

create or replace function recompute_item_cost(p_item_id uuid, p_full boolean default false)
returns void
language plpgsql
set search_path = public
as $$
begin
  perform set_config('app.system_write', 'on', true);
  perform _recompute_item_cost_core(p_item_id, p_full);
  perform set_config('app.system_write', 'off', true);
exception when others then
  perform set_config('app.system_write', 'off', true);
  raise;
end;
$$;

create or replace function recompute_all_item_costs(p_lock_date date default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  item_row record;
begin
  if not (is_app_admin() or has_perm('period_lock')) then
    raise exception 'permission denied: period_lock required' using errcode = '42501';
  end if;

  perform set_config('app.system_write', 'on', true);

  delete from item_cost_snapshot;

  if p_lock_date is not null then
    update period_lock set locked_before = p_lock_date where id = 1;
  end if;

  for item_row in select id from items loop
    perform _recompute_item_cost_core(item_row.id, true);
  end loop;

  perform set_config('app.system_write', 'off', true);
exception when others then
  perform set_config('app.system_write', 'off', true);
  raise;
end;
$$;

-- ----------------------------------------------------------
-- Trigger wiring: AIUD on voucher_lines, sales_return_lines,
-- stock_adjustments, and items.opening_qty/opening_rate changes.
-- ----------------------------------------------------------
create or replace function trg_recompute_voucher_lines()
returns trigger
language plpgsql
set search_path = public
as $$
begin
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

create trigger voucher_lines_recompute_after
  after insert or update or delete on voucher_lines
  for each row execute function trg_recompute_voucher_lines();

create or replace function trg_recompute_sales_return_lines()
returns trigger
language plpgsql
set search_path = public
as $$
begin
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

create trigger sales_return_lines_recompute_after
  after insert or update or delete on sales_return_lines
  for each row execute function trg_recompute_sales_return_lines();

-- A sales_returns HEADER change (e.g. soft-delete of the whole return) must
-- also ripple: recompute every distinct item among its lines.
create or replace function trg_recompute_sales_returns_header()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_item_id uuid;
begin
  if tg_op = 'UPDATE' and old.deleted_at is distinct from new.deleted_at then
    for v_item_id in select distinct item_id from sales_return_lines where return_id = new.id and item_id is not null loop
      perform recompute_item_cost(v_item_id);
    end loop;
  end if;
  return new;
end;
$$;

create trigger sales_returns_recompute_after
  after update on sales_returns
  for each row execute function trg_recompute_sales_returns_header();

create or replace function trg_recompute_stock_adjustments()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform recompute_item_cost(old.item_id);
    return old;
  end if;
  perform recompute_item_cost(new.item_id);
  return new;
end;
$$;

create trigger stock_adjustments_recompute_after
  after insert or update or delete on stock_adjustments
  for each row execute function trg_recompute_stock_adjustments();

create or replace function trg_recompute_items_opening()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  perform recompute_item_cost(new.id);
  return new;
end;
$$;

create trigger items_recompute_opening_after
  after update on items
  for each row
  when (old.opening_qty is distinct from new.opening_qty or old.opening_rate is distinct from new.opening_rate)
  execute function trg_recompute_items_opening();

-- A soft-delete/restore of a purchase/sale voucher (whose lines aren't
-- themselves touched) must also ripple to every item among its lines.
create or replace function trg_recompute_vouchers_header()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_item_id uuid;
begin
  if tg_op = 'UPDATE' and old.deleted_at is distinct from new.deleted_at then
    for v_item_id in select distinct item_id from voucher_lines where voucher_id = new.id and item_id is not null loop
      perform recompute_item_cost(v_item_id);
    end loop;
  end if;
  return new;
end;
$$;

create trigger vouchers_recompute_after
  after update on vouchers
  for each row execute function trg_recompute_vouchers_header();

revoke execute on function _recompute_item_cost_core(uuid, boolean) from public, anon, authenticated;
revoke execute on function trg_recompute_voucher_lines() from public, anon, authenticated;
revoke execute on function trg_recompute_sales_return_lines() from public, anon, authenticated;
revoke execute on function trg_recompute_sales_returns_header() from public, anon, authenticated;
revoke execute on function trg_recompute_stock_adjustments() from public, anon, authenticated;
revoke execute on function trg_recompute_items_opening() from public, anon, authenticated;
revoke execute on function trg_recompute_vouchers_header() from public, anon, authenticated;

grant execute on function recompute_item_cost(uuid, boolean) to authenticated;
grant execute on function recompute_all_item_costs(date) to authenticated;
