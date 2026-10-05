-- ==========================================================
-- Quotation custom item unit
-- Applied directly to the live TAE database on 2026-09-30 (Supabase migration
-- 20260930104140_add_quotation_custom_unit) and checked in here afterwards so a fresh project built from this
-- folder matches production.
-- ==========================================================
alter table quotation_lines add column if not exists custom_unit text;
