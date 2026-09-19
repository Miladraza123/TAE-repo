-- ==========================================================
-- Phase 9 (bug-fix plan): an optional warehouse for an item's opening
-- quantity. items.opening_qty/opening_rate already existed (feed the
-- costing engine's starting balance) but carried no warehouse of their
-- own — there was no record of which warehouse an item's stock actually
-- sits in. Nullable: an item still saves fine with neither set.
-- ==========================================================

alter table items
  add column opening_warehouse_id uuid references warehouses(id) on delete set null;
