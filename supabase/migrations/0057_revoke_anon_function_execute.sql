-- ==========================================================
-- Hardening: no function in public is callable without a login.
--
-- Functions created after 0018 kept Postgres' default EXECUTE for PUBLIC
-- and anon. None of them leaks data today (trigger functions can't be
-- called directly, payable_aging checks the caller, the rest are blocked
-- by RLS), but anon has no business calling any of them. authenticated
-- keeps its explicit grant, so the app works exactly as before.
-- Also stops future functions from getting PUBLIC/anon EXECUTE by default.
-- Run in the Supabase SQL editor.
-- ==========================================================

revoke execute on function assign_dc_number() from public, anon;
revoke execute on function assign_stock_adjustment_number() from public, anon;
revoke execute on function check_period_lock_dc_mi() from public, anon;
revoke execute on function check_period_lock_doc() from public, anon;
revoke execute on function check_period_lock_line() from public, anon;
revoke execute on function check_period_lock_srmr() from public, anon;
revoke execute on function check_period_lock_vlmc() from public, anon;
revoke execute on function dc_lines_guard() from public, anon;
revoke execute on function dc_lines_quote_cap() from public, anon;
revoke execute on function delivery_challans_guard() from public, anon;
revoke execute on function material_issues_protect_cost() from public, anon;
revoke execute on function next_recurring_date(date, text, integer) from public, anon;
revoke execute on function payable_aging(date) from public, anon;
revoke execute on function recompute_service_invoice_totals(uuid) from public, anon;
revoke execute on function recompute_service_quotation_totals(uuid) from public, anon;
revoke execute on function trg_recompute_dc_header() from public, anon;
revoke execute on function trg_recompute_dc_lines() from public, anon;
revoke execute on function trg_recompute_material_issues() from public, anon;
revoke execute on function trg_service_quotation_header_totals() from public, anon;
revoke execute on function trg_service_quotation_lines_totals() from public, anon;
revoke execute on function voucher_lines_dc_cap() from public, anon;

alter default privileges for role postgres in schema public revoke execute on functions from public, anon;

-- Check: should return NO rows.
select p.proname as still_callable_without_login
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and (has_function_privilege('anon', p.oid, 'execute'));
