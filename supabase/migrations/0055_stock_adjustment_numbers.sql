-- ==========================================================
-- Stock Adjustment screen support
--
-- stock_adjustments already exists (0006) and is already counted by the
-- costing engine, the Item Stock Ledger, Period Lock, Recycle Bin and the
-- audit log. The new screen only needs:
--   * a document number, SA-0001, like ST-/DC- numbers;
--   * a guard that an adjustment actually changes something (qty <> 0).
-- ==========================================================

create sequence if not exists seq_stock_adjustment_no;

alter table stock_adjustments add column if not exists adjno text not null default '';

create or replace function assign_stock_adjustment_number()
returns trigger language plpgsql set search_path = public as $$
begin
  new.adjno := 'SA-' || lpad(nextval('seq_stock_adjustment_no')::text, 4, '0');
  return new;
end; $$;

create or replace trigger stock_adjustments_assign_number before insert on stock_adjustments
  for each row execute function assign_stock_adjustment_number();

create unique index if not exists stock_adjustments_adjno_unique_idx
  on stock_adjustments (adjno) where deleted_at is null and adjno <> '';

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'stock_adjustments_qty_nonzero') then
    alter table stock_adjustments add constraint stock_adjustments_qty_nonzero check (qty <> 0);
  end if;
end $$;

grant usage on sequence seq_stock_adjustment_no to authenticated;
