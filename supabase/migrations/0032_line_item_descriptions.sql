-- ==========================================================
-- Line description on voucher/quotation/PO lines + quotation custom item name
-- Applied directly to the live TAE database on 2026-09-26 (Supabase migration
-- 20260926093652_add_line_item_descriptions) and checked in here afterwards so a fresh project built from this
-- folder matches production.
-- ==========================================================
alter table voucher_lines   add column if not exists description text;
alter table quotation_lines add column if not exists description text;
alter table quotation_lines add column if not exists custom_name text;
alter table po_lines        add column if not exists description text;
