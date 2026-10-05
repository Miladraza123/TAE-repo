-- ==========================================================
-- Material Issue against a direct Delivery Challan (one made without a
-- quotation). An issue now belongs to a quotation (the order's pool, as
-- before) OR to a DC. A direct DC's manufactured lines share the cost of
-- that DC's own issues by qty; a DC made from a quotation keeps sharing
-- the quotation's pool. A DC with live issues of its own can't be deleted
-- until they are (the material would otherwise have left stock for no DC).
-- ==========================================================
alter table material_issues add column if not exists dc_id uuid references delivery_challans(id);
alter table material_issues alter column quotation_id drop not null;
alter table material_issues add constraint material_issues_target_check
  check ((quotation_id is not null) <> (dc_id is not null));
create index if not exists material_issues_dc_idx on material_issues (dc_id);

create or replace view dc_line_costs as
select dl.id as dc_line_id,
       case when dl.consumption_type = 'general_goods' then coalesce(dl.cost_amount, 0)
            when dc.quotation_id is not null then coalesce(
              (select sum(mi.cost_amount) from material_issues mi
                 where mi.quotation_id = dc.quotation_id and mi.deleted_at is null)
              * dl.qty / nullif((select sum(d2.qty) from dc_lines d2
                 join delivery_challans c2 on c2.id = d2.dc_id and c2.deleted_at is null
                 where c2.quotation_id = dc.quotation_id and d2.consumption_type = 'manufactured'), 0), 0)
            else coalesce(
              (select sum(mi.cost_amount) from material_issues mi
                 where mi.dc_id = dc.id and mi.deleted_at is null)
              * dl.qty / nullif((select sum(d2.qty) from dc_lines d2
                 where d2.dc_id = dc.id and d2.consumption_type = 'manufactured'), 0), 0)
       end as cost
from dc_lines dl
join delivery_challans dc on dc.id = dl.dc_id;
alter view dc_line_costs set (security_invoker = true);

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
  if old.deleted_at is null and new.deleted_at is not null and exists (
    select 1 from material_issues mi where mi.dc_id = new.id and mi.deleted_at is null
  ) then
    raise exception 'Material was issued against this Delivery Challan — delete its material issues first.' using errcode = '23514';
  end if;
  if new.party_id is distinct from old.party_id and exists (
    select 1 from voucher_lines vl join dc_lines dl on dl.id = vl.dc_line_id where dl.dc_id = new.id
  ) then
    raise exception 'This Delivery Challan is already billed — its party can''t change.' using errcode = '23514';
  end if;
  return new;
end; $$;
