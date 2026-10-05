-- ==========================================================
-- A new item's opening stock was not counted until its first purchase or
-- sale: the recompute trigger fired only on UPDATE of opening_qty /
-- opening_rate, never on INSERT, so an item created with an opening
-- quantity showed stock 0 (live: Angle iron 3*3, H Beam 12*12, ms channel
-- 5x 2 1/2, TRALLY). Fire it on insert too, and recompute every item that
-- has an opening quantity.
-- ==========================================================
create or replace trigger items_recompute_opening_insert after insert on items
  for each row when (new.opening_qty <> 0 or new.opening_rate <> 0)
  execute function trg_recompute_items_opening();

do $$
declare r record;
begin
  for r in select id from items where opening_qty <> 0 loop
    perform recompute_item_cost(r.id);
  end loop;
end $$;
