-- ==========================================================
-- Fix: item_cost_snapshot's RLS required has_perm('period_lock') for every
-- write with no exception for the costing engine's own system-driven
-- writes — so a user with only bill_create (not period_lock) would be
-- blocked from a full-replay recompute triggered by their own sale/purchase.
-- Add the same app.system_write bypass used everywhere else in the schema.
-- Apply the identical fix to party_opening_balances proactively (§11 will
-- write to it the same way).
-- ==========================================================

drop policy item_cost_snapshot_write on item_cost_snapshot;
create policy item_cost_snapshot_write on item_cost_snapshot for all to authenticated
  using (is_app_admin() or has_perm('period_lock') or coalesce(current_setting('app.system_write', true), '') = 'on')
  with check (is_app_admin() or has_perm('period_lock') or coalesce(current_setting('app.system_write', true), '') = 'on');

drop policy party_opening_balances_write on party_opening_balances;
create policy party_opening_balances_write on party_opening_balances for all to authenticated
  using (is_app_admin() or has_perm('period_lock') or coalesce(current_setting('app.system_write', true), '') = 'on')
  with check (is_app_admin() or has_perm('period_lock') or coalesce(current_setting('app.system_write', true), '') = 'on');
