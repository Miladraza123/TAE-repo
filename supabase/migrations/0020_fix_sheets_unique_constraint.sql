-- ==========================================================
-- Fix: sheets_date_unique_idx was a PARTIAL unique index (where deleted_at
-- is null). PostgREST's upsert(..., {onConflict:'sheet_date'}) emits a
-- plain `ON CONFLICT (sheet_date) DO UPDATE` with no WHERE predicate,
-- which Postgres cannot match against a partial index — every upsert from
-- daily-ledger.html would fail with "no unique or exclusion constraint
-- matching the ON CONFLICT specification". One sheet per calendar day is
-- a genuine invariant regardless of soft-delete state, so a real (full)
-- unique constraint is both correct and required here.
-- ==========================================================

drop index if exists sheets_date_unique_idx;
alter table sheets add constraint sheets_date_unique unique (sheet_date);
