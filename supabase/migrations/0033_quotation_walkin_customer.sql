-- ==========================================================
-- Walk-in customer name on quotations and service quotations
-- Applied directly to the live TAE database on 2026-09-26 (Supabase migration
-- 20260926093705_add_quotation_walkin_customer) and checked in here afterwards so a fresh project built from this
-- folder matches production.
-- ==========================================================
alter table quotations         add column if not exists walkin_name text;
alter table service_quotations add column if not exists walkin_name text;
