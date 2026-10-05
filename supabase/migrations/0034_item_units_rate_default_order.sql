-- ==========================================================
-- item_units: per-unit rate, default unit flag, display order
-- Applied directly to the live TAE database on 2026-09-26 (Supabase migration
-- 20260926093717_fix_item_units_missing_columns) and checked in here afterwards so a fresh project built from this
-- folder matches production.
-- ==========================================================
alter table item_units add column if not exists rate numeric;
alter table item_units add column if not exists is_default boolean not null default false;
alter table item_units add column if not exists line_no integer not null default 1;
