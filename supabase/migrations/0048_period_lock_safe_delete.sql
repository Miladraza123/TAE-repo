-- ==========================================================
-- Period Lock could not be set: its trigger cleared the cost/opening
-- snapshots with a bare DELETE, which Supabase's safe-update guard refuses
-- ("DELETE requires a WHERE clause") — so every Save lock date failed with
-- a 400. Same clearing, with an explicit WHERE. The snapshots rebuild on
-- the next recompute, exactly as before.
-- ==========================================================
create or replace function period_lock_invalidate_snapshots()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  delete from item_cost_snapshot where true;
  delete from party_opening_balances where true;
  return new;
end;
$$;
