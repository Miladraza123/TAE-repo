-- ==========================================================
-- One LIVE sheet per day. The full unique (sheet_date) constraint from
-- 0020 also counted deleted sheets, so after "Delete sheet" that day could
-- never be written again (the first save hit 23505 and said someone else
-- had just made the sheet). 0020 needed a full constraint only for the old
-- upsert(onConflict: sheet_date); first save is a plain insert since 0021,
-- so a partial unique index is enough again. Restoring a deleted sheet
-- while that day has a live one is refused by the same index.
-- ==========================================================
alter table sheets drop constraint if exists sheets_date_unique;
create unique index if not exists sheets_date_unique_live on sheets (sheet_date) where deleted_at is null;
