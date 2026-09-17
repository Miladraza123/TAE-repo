-- Add `sheets` (Daily Cash Book, §13) to the smart-merge header allow-list.
-- Until now, saving a sheet always used a plain upsert(onConflict:sheet_date)
-- — a whole-row overwrite with no conflict detection, so two people editing
-- the SAME day's cash book could silently clobber each other's entries.
-- `sheets` already has the `id`/`version` columns smart_merge_update()
-- needs; it just wasn't in the allow-list yet.
create or replace function _smart_merge_allowed_tables()
returns text[] language sql immutable set search_path = public as $$
  select array[
    'companies','warehouses','parties','item_units','items','services','party_kinds',
    'vouchers','sales_returns','quotations','purchase_orders',
    'service_invoices','service_quotations','stock_transfers',
    'recurring_service_templates','sheets'
  ];
  -- NEVER add app_users/audit_log here — see §27/§28.
$$;
