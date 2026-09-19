-- ==========================================================
-- Phase 5 (bug-fix plan): a 4th, custom-named extra charge — same on/off +
-- amount shape as loading/cartage/cutting, but with a user-typed label —
-- on vouchers (Sale/Purchase Invoice) and quotations. NOT added to
-- purchase_orders (which never had loading/cartage/cutting either — no
-- landed-cost or period-lock effect until converted) or service
-- invoices/quotations (out of scope per the approved plan).
-- ==========================================================

alter table vouchers
  add column other_charge_on   boolean not null default false,
  add column other_charge_name text,
  add column other_charge_amt  numeric not null default 0;

alter table quotations
  add column other_charge_on   boolean not null default false,
  add column other_charge_name text,
  add column other_charge_amt  numeric not null default 0;

-- Landed-cost spread for purchases (§18) must include the new charge type
-- exactly like loading/cartage/cutting, or a purchase's item cost would be
-- understated whenever "Other Charges" is the one used.
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
    v_start_date := null;
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
            + case when v.cutting_on then v.cutting_amt else 0 end
            + case when v.other_charge_on then v.other_charge_amt else 0 end) as extra_charges
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
      where vl.item_id = p_item_id and vl.consumption_type = 'general_goods'
        and (v_start_date is null or v.vdate >= v_start_date)

      union all

      select srl.id, 'return', sr.rdate, srl.qty, null::numeric, srl.cost_amount
      from sales_return_lines srl
      join sales_returns sr on sr.id = srl.return_id and sr.deleted_at is null
      join voucher_lines vl on vl.id = srl.sale_line_id
      where srl.item_id = p_item_id and vl.consumption_type = 'general_goods'
        and (v_start_date is null or sr.rdate >= v_start_date)

      union all

      select sa.id, 'adjustment', sa.adj_date, sa.qty, null::numeric, null::numeric
      from stock_adjustments sa
      where sa.item_id = p_item_id and sa.deleted_at is null
        and (v_start_date is null or sa.adj_date >= v_start_date)

      union all

      select vlmc.id, 'material_consumption', v.vdate, vlmc.qty, null::numeric, null::numeric
      from voucher_line_material_consumption vlmc
      join voucher_lines vl on vl.id = vlmc.voucher_line_id
      join vouchers v on v.id = vl.voucher_id and v.deleted_at is null
      where vlmc.raw_item_id = p_item_id and (v_start_date is null or v.vdate >= v_start_date)

      union all

      select srmr.id, 'material_restoration', sr.rdate, srmr.qty, null::numeric, srmr.cost_amount
      from sales_return_material_restoration srmr
      join sales_return_lines srl on srl.id = srmr.return_line_id
      join sales_returns sr on sr.id = srl.return_id and sr.deleted_at is null
      join voucher_line_material_consumption vlmc on vlmc.id = srmr.consumption_id
      where vlmc.raw_item_id = p_item_id and (v_start_date is null or sr.rdate >= v_start_date)
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

    elsif r.kind = 'material_consumption' then
      update voucher_line_material_consumption set cost_amount = round(r.qty * v_avg_cost, 2) where id = r.line_id;
      v_qty := v_qty - r.qty;

    elsif r.kind = 'material_restoration' then
      v_new_cost := round(((v_qty * v_avg_cost) + coalesce(r.return_cost, 0)) / nullif(v_qty + r.qty, 0), 4);
      v_avg_cost := coalesce(v_new_cost, v_avg_cost);
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

-- Period lock guard (§9/§12): the "did anything besides deleted_at change"
-- tuple comparison must also cover the new columns, or they could be
-- silently edited on a voucher dated before the lock.
create or replace function check_period_lock_vouchers()
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

  if tg_op = 'INSERT' and new.vdate < v_lock then
    raise exception 'Cannot create a voucher dated before the locked period (%).', v_lock
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.vdate < v_lock then
    if (old.vno, old.vtype, old.vdate, old.due_date, old.party_id, old.company_id,
        old.narration, old.tax_on, old.sub_total, old.discount, old.tax_total,
        old.grand_total, old.paid, old.loading_on, old.loading_amt, old.cartage_on,
        old.cartage_amt, old.cutting_on, old.cutting_amt,
        old.other_charge_on, old.other_charge_name, old.other_charge_amt)
       is distinct from
       (new.vno, new.vtype, new.vdate, new.due_date, new.party_id, new.company_id,
        new.narration, new.tax_on, new.sub_total, new.discount, new.tax_total,
        new.grand_total, new.paid, new.loading_on, new.loading_amt, new.cartage_on,
        new.cartage_amt, new.cutting_on, new.cutting_amt,
        new.other_charge_on, new.other_charge_name, new.other_charge_amt)
    then
      raise exception 'This voucher is dated before the locked period (%) and cannot be edited.', v_lock
        using errcode = '23514';
    end if;
  end if;

  if tg_op = 'DELETE' and old.vdate < v_lock then
    raise exception 'Cannot permanently delete a voucher dated before the locked period (%).', v_lock
      using errcode = '23514';
  end if;

  return coalesce(new, old);
end;
$$;
