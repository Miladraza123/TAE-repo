-- ==========================================================
-- Fix: Postgres grants EXECUTE on every new function to PUBLIC by default.
-- `revoke ... from anon` only removes anon's own direct grant — it still
-- inherits EXECUTE through the PUBLIC grant, so anon could call these
-- regardless of the earlier revokes. Must revoke from PUBLIC directly,
-- then re-grant precisely to authenticated where that's intended.
-- Caught via get_advisors still flagging anon-callability after the
-- earlier "revoke from anon" migrations.
-- ==========================================================

revoke execute on function trial_balance(date) from public;
revoke execute on function receivable_aging(date) from public;
revoke execute on function aging_reconcile(date) from public;
revoke execute on function smart_merge_update(text, uuid, jsonb, jsonb, text[]) from public;
revoke execute on function smart_merge_lines(text, text, uuid, jsonb, jsonb, text[]) from public;
revoke execute on function apply_merged_lines(text, text, uuid, jsonb) from public;
revoke execute on function recompute_item_cost(uuid, boolean) from public;
revoke execute on function recompute_all_item_costs(date) from public;
revoke execute on function has_perm(text) from public;
revoke execute on function is_app_admin() from public;
revoke execute on function next_recurring_date(date, text, integer) from public;

grant execute on function trial_balance(date) to authenticated;
grant execute on function receivable_aging(date) to authenticated;
grant execute on function aging_reconcile(date) to authenticated;
grant execute on function smart_merge_update(text, uuid, jsonb, jsonb, text[]) to authenticated;
grant execute on function smart_merge_lines(text, text, uuid, jsonb, jsonb, text[]) to authenticated;
grant execute on function apply_merged_lines(text, text, uuid, jsonb) to authenticated;
grant execute on function recompute_item_cost(uuid, boolean) to authenticated;
grant execute on function recompute_all_item_costs(date) to authenticated;
grant execute on function has_perm(text) to authenticated;
grant execute on function is_app_admin() to authenticated;
grant execute on function next_recurring_date(date, text, integer) to authenticated;

-- Trigger-only functions: also close the PUBLIC gap (belt-and-suspenders;
-- Postgres already refuses to call a trigger-return-type function outside
-- trigger context, but no reason to leave them in the exposed API at all).
revoke execute on function stamp_audit_fields() from public;
revoke execute on function bump_version() from public;
revoke execute on function enforce_perm_on_update() from public;
revoke execute on function log_audit_event() from public;
revoke execute on function companies_manage_default() from public;
revoke execute on function warehouses_manage_default() from public;
revoke execute on function warehouses_block_delete_default() from public;
revoke execute on function items_protect_computed_cols() from public;
revoke execute on function period_lock_invalidate_snapshots() from public;
revoke execute on function assign_voucher_number() from public;
revoke execute on function check_period_lock_vouchers() from public;
revoke execute on function voucher_lines_protect_cost() from public;
revoke execute on function assign_sales_return_number() from public;
revoke execute on function sales_return_lines_cap_qty() from public;
revoke execute on function sales_return_lines_stamp_cost() from public;
revoke execute on function _recompute_item_cost_core(uuid, boolean) from public;
revoke execute on function trg_recompute_voucher_lines() from public;
revoke execute on function trg_recompute_sales_return_lines() from public;
revoke execute on function trg_recompute_sales_returns_header() from public;
revoke execute on function trg_recompute_stock_adjustments() from public;
revoke execute on function trg_recompute_items_opening() from public;
revoke execute on function trg_recompute_vouchers_header() from public;
revoke execute on function _smart_merge_allowed_tables() from public;
revoke execute on function _smart_merge_allowed_line_tables() from public;
revoke execute on function assign_quotation_number() from public;
revoke execute on function assign_po_number() from public;
revoke execute on function assign_service_invoice_number() from public;
revoke execute on function assign_service_quotation_number() from public;
revoke execute on function recurring_templates_default_next_date() from public;
revoke execute on function trg_service_invoice_lines_totals() from public;
revoke execute on function trg_service_invoice_header_totals() from public;
revoke execute on function assign_stock_transfer_number() from public;
revoke execute on function check_period_lock_sheets() from public;
revoke execute on function enforce_active_user_limit() from public;
