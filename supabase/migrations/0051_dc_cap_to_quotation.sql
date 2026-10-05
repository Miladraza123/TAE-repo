-- ==========================================================
-- A DC line made from a quotation line can't deliver more than that line
-- ordered (summed over every live challan). Until now the pending qty was
-- only a hint, so 10 could go out against an order of 5. To deliver more,
-- raise the quantity on the quotation first. Rows already saved are not
-- touched; the check runs when a DC line is added or its qty changes.
-- ==========================================================
create or replace function dc_lines_quote_cap()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_ordered numeric;
  v_other numeric;
begin
  if new.quotation_line_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.qty <= old.qty and new.quotation_line_id is not distinct from old.quotation_line_id then
    return new; -- lowering a qty is always allowed
  end if;
  select qty into v_ordered from quotation_lines where id = new.quotation_line_id;
  select coalesce(sum(d.qty), 0) into v_other
    from dc_lines d join delivery_challans c on c.id = d.dc_id and c.deleted_at is null
    where d.quotation_line_id = new.quotation_line_id and d.id is distinct from new.id;
  if v_other + new.qty > coalesce(v_ordered, 0) + 0.0005 then
    raise exception 'The quotation ordered %, other challans already delivered % — only % is pending. To deliver more, increase the qty on the quotation first.',
      v_ordered, v_other, greatest(coalesce(v_ordered, 0) - v_other, 0) using errcode = '23514';
  end if;
  return new;
end; $$;
create or replace trigger dc_lines_quote_cap_before before insert or update of qty, quotation_line_id on dc_lines
  for each row execute function dc_lines_quote_cap();
