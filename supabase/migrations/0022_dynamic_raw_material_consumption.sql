-- ==========================================================
-- Dynamic Raw Material Consumption on Sales Invoice — no manufacturing
-- module, no fixed BOM. A sale line for a "Raw Material"-type final
-- product does NOT deduct its own item's stock; instead the user enters
-- the actual raw materials consumed for that specific invoice line, and
-- THOSE items' stock is deducted (and their cost captured) through the
-- exact same weighted-average replay engine every other stock movement
-- already goes through (recompute_item_cost / _recompute_item_cost_core,
-- migration 0007) — no parallel stock system, no new manufacturing
-- voucher, no persistent BOM.
-- ==========================================================

-- ----------------------------------------------------------
-- items.item_type — default classification, user can override per invoice
-- line (see voucher_lines.consumption_type below).
-- ----------------------------------------------------------
alter table items add column item_type text not null default 'general_goods'
  check (item_type in ('general_goods', 'raw_material_consumption'));

-- ----------------------------------------------------------
-- voucher_lines.consumption_type — what was ACTUALLY used for this specific
-- invoice line, defaulted from the item's own item_type but independently
-- overridable per line (§ "kabhi Raw Material hi bechna ho"). Stored so
-- audit/reports can see exactly what happened on a given invoice, and so
-- the costing engine knows whether to deduct this line's own item stock.
-- ----------------------------------------------------------
alter table voucher_lines add column consumption_type text not null default 'general_goods'
  check (consumption_type in ('general_goods', 'raw_material_consumption'));

-- ----------------------------------------------------------
-- voucher_line_material_consumption — the raw materials entered against ONE
-- specific sale line, for THIS invoice only. Never a template/BOM: rows
-- live and die with their voucher_line (on delete cascade), and nothing
-- here is reused automatically for a future invoice (the client's "last
-- used" quick-fill offer is a pure UI convenience read from history, not a
-- stored template row).
-- ----------------------------------------------------------
create table voucher_line_material_consumption (
  id              uuid primary key default gen_random_uuid(),
  voucher_line_id uuid not null references voucher_lines(id) on delete cascade,
  raw_item_id     uuid not null references items(id),
  warehouse_id    uuid references warehouses(id),
  qty             numeric not null check (qty > 0),
  unit            text,
  unit_factor     numeric not null default 1,
  cost_amount     numeric, -- engine-owned (weighted-avg cost at time of consumption) — never client-set
  notes           text,
  line_no         integer not null default 1,
  created_at      timestamptz not null default now()
);

create index vlmc_voucher_line_idx on voucher_line_material_consumption (voucher_line_id);
create index vlmc_raw_item_idx on voucher_line_material_consumption (raw_item_id);

-- A final product can never be listed as its own raw material.
create or replace function vlmc_prevent_self_consumption()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_final_item_id uuid;
begin
  select item_id into v_final_item_id from voucher_lines where id = new.voucher_line_id;
  if v_final_item_id is not null and v_final_item_id = new.raw_item_id then
    raise exception 'An item cannot be entered as its own raw material' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger vlmc_prevent_self_before
  before insert or update on voucher_line_material_consumption
  for each row execute function vlmc_prevent_self_consumption();

-- cost_amount is engine-owned, exactly like voucher_lines.cost_amount (0006).
create or replace function vlmc_protect_cost()
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

create trigger vlmc_protect_cost_before
  before insert or update on voucher_line_material_consumption
  for each row execute function vlmc_protect_cost();

alter table voucher_line_material_consumption enable row level security;

create policy vlmc_select on voucher_line_material_consumption for select to authenticated using (true);
create policy vlmc_insert on voucher_line_material_consumption for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create') or has_perm('bill_edit')
    or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy vlmc_update on voucher_line_material_consumption for update to authenticated
  using (is_app_admin() or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on')
  with check (is_app_admin() or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy vlmc_delete on voucher_line_material_consumption for delete to authenticated
  using (is_app_admin() or has_perm('bill_edit'));

-- ----------------------------------------------------------
-- sales_return_material_restoration — optional, partial-allowed restoration
-- of previously-consumed raw materials when a sale with dynamic consumption
-- is returned. Never assumed automatic (§ spec) — always an explicit line
-- the user enters, capped at what's still restorable.
-- ----------------------------------------------------------
create table sales_return_material_restoration (
  id             uuid primary key default gen_random_uuid(),
  return_line_id uuid not null references sales_return_lines(id) on delete cascade,
  consumption_id uuid not null references voucher_line_material_consumption(id),
  warehouse_id   uuid references warehouses(id),
  qty            numeric not null check (qty > 0),
  cost_amount    numeric, -- engine-owned, carries back the ORIGINAL consumption's per-unit cost
  created_at     timestamptz not null default now()
);

create index srmr_return_line_idx on sales_return_material_restoration (return_line_id);
create index srmr_consumption_idx on sales_return_material_restoration (consumption_id);

-- Cap restoration at what's still restorable on that specific consumption
-- line (consumed qty minus already-restored), same pattern as
-- sales_return_lines_cap_qty (0006).
create or replace function srmr_cap_qty()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_consumed_qty numeric;
  v_already_restored numeric;
  v_restorable numeric;
begin
  select qty into v_consumed_qty from voucher_line_material_consumption where id = new.consumption_id;
  if v_consumed_qty is null then
    raise exception 'Restoration must reference a real original consumption line' using errcode = '23514';
  end if;

  select coalesce(sum(qty), 0) into v_already_restored
  from sales_return_material_restoration
  where consumption_id = new.consumption_id and id is distinct from new.id;

  v_restorable := v_consumed_qty - v_already_restored;
  if new.qty > v_restorable then
    raise exception 'Restoration quantity (%) exceeds what is still restorable on this consumption line (%)', new.qty, v_restorable
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger srmr_cap_qty_before
  before insert or update on sales_return_material_restoration
  for each row execute function srmr_cap_qty();

-- Auto-stamp cost_amount from the ORIGINAL consumption's own per-unit cost,
-- not today's average — same pattern as sales_return_lines_stamp_cost (0006).
create or replace function srmr_stamp_cost()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_qty  numeric;
  v_cost numeric;
begin
  select qty, cost_amount into v_qty, v_cost from voucher_line_material_consumption where id = new.consumption_id;
  if v_qty is null or v_qty = 0 then
    new.cost_amount := 0;
  else
    new.cost_amount := round((coalesce(v_cost, 0) / v_qty) * new.qty, 2);
  end if;
  return new;
end;
$$;

create trigger srmr_stamp_cost_before
  before insert or update on sales_return_material_restoration
  for each row execute function srmr_stamp_cost();

alter table sales_return_material_restoration enable row level security;

create policy srmr_select on sales_return_material_restoration for select to authenticated using (true);
create policy srmr_insert on sales_return_material_restoration for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create') or has_perm('bill_edit'));
create policy srmr_update on sales_return_material_restoration for update to authenticated
  using (is_app_admin() or has_perm('bill_edit')) with check (is_app_admin() or has_perm('bill_edit'));
create policy srmr_delete on sales_return_material_restoration for delete to authenticated
  using (is_app_admin() or has_perm('bill_edit'));

-- ----------------------------------------------------------
-- Costing engine integration (extends 0007's _recompute_item_cost_core):
-- 1. A 'sale' line whose consumption_type is 'raw_material_consumption'
--    no longer deducts its OWN item's stock (the final product isn't
--    stock-tracked through selling it — §"do not deduct Final Product
--    stock").
-- 2. Two new event kinds replay exactly like 'sale'/'return' do, but
--    sourced from the new tables: 'material_consumption' (deducts the raw
--    material, stamps its cost at that point in the replay) and
--    'material_restoration' (adds it back, at the ORIGINAL consumption's
--    carried-back cost).
-- ----------------------------------------------------------
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

      -- A raw-material-type line never deducts the final product's own
      -- stock: it's excluded here, its cost_amount is synced separately
      -- (see recompute_item_cost below) from its material consumption.
      select vl.id, 'sale', v.vdate, vl.qty, null::numeric, null::numeric
      from voucher_lines vl
      join vouchers v on v.id = vl.voucher_id and v.vtype = 'sale' and v.deleted_at is null
      where vl.item_id = p_item_id and vl.consumption_type = 'general_goods'
        and (v_start_date is null or v.vdate >= v_start_date)

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

      union all

      -- Raw material consumed against a final-product sale line: deducts
      -- like a sale, cost captured at time of consumption.
      select vlmc.id, 'material_consumption', v.vdate, vlmc.qty, null::numeric, null::numeric
      from voucher_line_material_consumption vlmc
      join voucher_lines vl on vl.id = vlmc.voucher_line_id
      join vouchers v on v.id = vl.voucher_id and v.deleted_at is null
      where vlmc.raw_item_id = p_item_id and (v_start_date is null or v.vdate >= v_start_date)

      union all

      -- Raw material restored via a sales return: adds back at the
      -- ORIGINAL consumption's carried-back cost, like a sales return does.
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

-- recompute_item_cost (public entry point) now also syncs every voucher_line
-- whose material consumption touched THIS item: a raw-material-type sale
-- line's own cost_amount (used as its COGS in reports/§P&L) is the SUM of
-- its consumption children's cost_amount, which the core replay above just
-- updated. This has to happen in the wrapper (not the core), because one
-- voucher_line can draw on MULTIPLE different raw materials — the full,
-- correct sum is only knowable after each contributing item's own replay
-- has run, and the wrapper is what every call site already goes through.
create or replace function recompute_item_cost(p_item_id uuid, p_full boolean default false)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_vl_id uuid;
begin
  perform set_config('app.system_write', 'on', true);
  perform _recompute_item_cost_core(p_item_id, p_full);

  for v_vl_id in
    select distinct voucher_line_id from voucher_line_material_consumption where raw_item_id = p_item_id
  loop
    update voucher_lines
    set cost_amount = (
      select coalesce(sum(cost_amount), 0) from voucher_line_material_consumption where voucher_line_id = v_vl_id
    )
    where id = v_vl_id and consumption_type = 'raw_material_consumption';
  end loop;

  perform set_config('app.system_write', 'off', true);
exception when others then
  perform set_config('app.system_write', 'off', true);
  raise;
end;
$$;

-- ----------------------------------------------------------
-- Trigger wiring for the two new tables — identical trio pattern to
-- voucher_lines/sales_return_lines/stock_adjustments (0007): AFTER
-- INSERT/UPDATE/DELETE calls recompute_item_cost(raw_item_id), guarded by
-- app.system_write so the engine's own writes never recurse.
-- ----------------------------------------------------------
create or replace function trg_recompute_vlmc()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    perform recompute_item_cost(old.raw_item_id);
    return old;
  end if;

  if tg_op = 'UPDATE' and old.raw_item_id is distinct from new.raw_item_id then
    perform recompute_item_cost(old.raw_item_id);
  end if;

  perform recompute_item_cost(new.raw_item_id);
  return new;
end;
$$;

create trigger vlmc_recompute_after
  after insert or update or delete on voucher_line_material_consumption
  for each row execute function trg_recompute_vlmc();

create or replace function trg_recompute_srmr()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_raw_item_id uuid;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    select raw_item_id into v_raw_item_id from voucher_line_material_consumption where id = old.consumption_id;
    if v_raw_item_id is not null then perform recompute_item_cost(v_raw_item_id); end if;
    return old;
  end if;

  select raw_item_id into v_raw_item_id from voucher_line_material_consumption where id = new.consumption_id;
  if v_raw_item_id is not null then perform recompute_item_cost(v_raw_item_id); end if;
  return new;
end;
$$;

create trigger srmr_recompute_after
  after insert or update or delete on sales_return_material_restoration
  for each row execute function trg_recompute_srmr();

-- A voucher_lines UPDATE that flips consumption_type (general_goods <->
-- raw_material_consumption) must also trigger a recompute of the item's OWN
-- stock (since whether its 'sale' event counts changed), same as any other
-- item_id-affecting edit already does via trg_recompute_voucher_lines.
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

-- ----------------------------------------------------------
-- material_cost_view permission (§22-style, additive): the ONLY new
-- permission key this feature introduces — everything else (viewing/
-- adding/editing raw-material lines, posting, reversing) reuses the
-- existing bill_create/bill_edit/bill_delete/reports_view keys that
-- already gate the rest of the same invoice, matching this app's existing
-- coarse-grained permission model rather than fragmenting it further.
-- Enforced client-side (masters.html's PERM_GROUPS + billing.html's cost
-- display) — same enforcement style already used for reports_view.
-- ----------------------------------------------------------

revoke execute on function vlmc_prevent_self_consumption() from public, anon, authenticated;
revoke execute on function vlmc_protect_cost() from public, anon, authenticated;
revoke execute on function srmr_cap_qty() from public, anon, authenticated;
revoke execute on function srmr_stamp_cost() from public, anon, authenticated;
revoke execute on function trg_recompute_vlmc() from public, anon, authenticated;
revoke execute on function trg_recompute_srmr() from public, anon, authenticated;
