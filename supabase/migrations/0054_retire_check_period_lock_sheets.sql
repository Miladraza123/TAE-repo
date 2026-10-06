-- ==========================================================
-- check_period_lock_sheets() still read the sheets.rows column (removed
-- when rows moved to sheet_rows). 0052 already moved the sheets trigger to
-- check_period_lock_doc('sheet_date') and gave sheet_rows its own
-- check_period_lock_line trigger, so nothing calls it; it is now a no-op
-- that reads no columns, kept only so anything that still names it works.
-- ==========================================================
create or replace function check_period_lock_sheets()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  return coalesce(new, old);
end; $$;
comment on function check_period_lock_sheets() is 'Retired: sheets use check_period_lock_doc(''sheet_date''), sheet_rows use check_period_lock_line (migration 0052).';
