-- ==========================================================
-- Party categories (one Category dropdown in the party form)
--
-- Fixed categories are parties.kind values; three new ones join the
-- original four: bank, head (owner / CEO account) and other. None of the
-- three counts as a receivable/payable (Trial Balance and Aging still read
-- only customer/supplier/both) or as an operating expense (P&L reads only
-- expense).
--
-- User-made categories stay in party_kinds; base_kind says how such a
-- party behaves in the books, and a party in one gets kind = base_kind
-- plus party_kind_id = the category. Deleting a category moves its
-- parties to "other".
--
-- Data: the parties in the old "HEAD" label became kind = 'head', and that
-- label was retired; "Expense 2" behaves like Customer & Supplier, as its
-- one party already did.
-- ==========================================================

alter table parties drop constraint if exists parties_kind_check;
alter table parties add constraint parties_kind_check
  check (kind in ('customer','supplier','both','expense','bank','head','other'));

alter table party_kinds add column if not exists base_kind text not null default 'other'
  check (base_kind in ('customer','supplier','both','expense','bank','head','other'));

do $$
begin
  perform set_config('app.system_write', 'on', true);
  update parties set kind = 'head', party_kind_id = null
   where party_kind_id = (select id from party_kinds where name = 'HEAD' and deleted_at is null limit 1) and deleted_at is null;
  update party_kinds set base_kind = 'both' where name = 'Expense 2';
  update party_kinds set deleted_at = now() where name = 'HEAD' and deleted_at is null;
end $$;

-- Daily Ledger: a linked party now shows as its own badge and the
-- particulars box holds remarks only. Old rows carried the party name at
-- the start of the remarks — strip it (only where it is exactly that).
do $$
begin
  perform set_config('app.system_write', 'on', true);
  update sheet_rows r set d_rem = nullif(btrim(substr(r.d_rem, length(p.name) + 1)), '')
    from parties p where p.id = r.d_party and r.d_rem is not null and lower(r.d_rem) like lower(p.name) || '%';
  update sheet_rows r set c_rem = nullif(btrim(substr(r.c_rem, length(p.name) + 1)), '')
    from parties p where p.id = r.c_party and r.c_rem is not null and lower(r.c_rem) like lower(p.name) || '%';
end $$;
