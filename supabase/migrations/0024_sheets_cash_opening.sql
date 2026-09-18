-- ==========================================================
-- Daily Ledger: separate "Cash in Hand" tracking (§13 follow-up).
--
-- The existing sheets.opening/side pair is the COMBINED balance (cash +
-- bank/cheque entries mixed in the same Debit/Credit columns). The
-- per-row "tick" checkboxes (rows[i][4]/[5], already existed, previously
-- cosmetic-only — just printed a checkmark) mark which entries were
-- physically cash. Cash in Hand is a second, independent running total
-- fed only by ticked rows, so it needs its own opening figure — carried
-- forward the same "display a brought-forward hint, let the user confirm
-- it" way sheets.opening already works, not silently auto-filled.
-- ==========================================================

alter table sheets add column cash_opening numeric not null default 0;
