-- ==========================================================
-- Costing engine: Delivery Challans and Material Issues move stock.
--   * 'dc'             — a DC line of a stock item sold as is
--                        (consumption_type general_goods): stock out on the
--                        DC date, dc_lines.cost_amount = qty × avg cost.
--   * 'material_issue' — raw material issued against a quotation: stock out
--                        on the issue date, cost_amount = qty × avg cost.
--   * sale lines made from a DC (voucher_lines.dc_line_id) no longer move
--     stock — the DC already did.
-- Everything else is identical to the previous definition (0029).
-- ==========================================================
create or replace function _recompute_item_cost_core(p_item_id uuid, p_full boolean)
returns void
language plpgsql
set search_path = public
as $function$
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
      where vl.item_id = p_item_id and vl.consumption_type = 'general_goods' and vl.dc_line_id is null
        and (v_start_date is null or v.vdate >= v_start_date)

      union all

      select dl.id, 'dc', dc.dc_date, dl.qty, null::numeric, null::numeric
      from dc_lines dl
      join delivery_challans dc on dc.id = dl.dc_id and dc.deleted_at is null
      where dl.item_id = p_item_id and dl.consumption_type = 'general_goods'
        and (v_start_date is null or dc.dc_date >= v_start_date)

      union all

      select mi.id, 'material_issue', mi.issue_date, mi.qty, null::numeric, null::numeric
      from material_issues mi
      where mi.item_id = p_item_id and mi.deleted_at is null
        and (v_start_date is null or mi.issue_date >= v_start_date)

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

    elsif r.kind = 'dc' then
      update dc_lines set cost_amount = round(r.qty * v_avg_cost, 2) where id = r.line_id;
      v_qty := v_qty - r.qty;

    elsif r.kind = 'material_issue' then
      update material_issues set cost_amount = round(r.qty * v_avg_cost, 2) where id = r.line_id;
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
$function$;

-- Cost of a DC line for Profit & Loss: a stock line carries its own
-- cost_amount; a manufactured line gets a share of everything issued
-- against its quotation, in proportion to its qty among that quotation's
-- delivered manufactured lines.
create or replace view dc_line_costs as
select dl.id as dc_line_id,
       case when dl.consumption_type = 'general_goods' then coalesce(dl.cost_amount, 0)
            else coalesce(
              (select sum(mi.cost_amount) from material_issues mi
                 where mi.quotation_id = dc.quotation_id and mi.deleted_at is null)
              * dl.qty / nullif((select sum(d2.qty) from dc_lines d2
                 join delivery_challans c2 on c2.id = d2.dc_id and c2.deleted_at is null
                 where c2.quotation_id = dc.quotation_id and d2.consumption_type = 'manufactured'), 0), 0)
       end as cost
from dc_lines dl
join delivery_challans dc on dc.id = dl.dc_id;
alter view dc_line_costs set (security_invoker = true);
grant select on dc_line_costs to authenticated;
