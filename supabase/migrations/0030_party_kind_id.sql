-- ==========================================================
-- Phase 7 (bug-fix plan): an optional "Party Kind" field on Parties,
-- sourced from the party_kinds table (added in an earlier migration but
-- never actually linked to anything). Deliberately separate from the
-- existing "kind" column (customer/supplier/both/expense), which drives
-- real accounting behaviour (ledgers, aging, P&L) and is NOT touched here
-- — this is a free-form category (e.g. "Wholesaler", "Contractor") with
-- no accounting effect of its own.
-- ==========================================================

alter table parties
  add column party_kind_id uuid references party_kinds(id) on delete set null;
