-- ==========================================================
-- Daily Ledger: move sheets.rows (a single JSONB blob) into a real child
-- table, sheet_rows — so it can reuse the exact same battle-tested
-- row-level 3-way merge infrastructure every other document already uses
-- (smart_merge_lines/apply_merged_lines, §27), instead of the whole-blob
-- comparison smart_merge_update did on the old `rows` column (which
-- flagged a conflict on ANY concurrent edit to the day's entries, even
-- when two people touched completely different rows).
--
-- sheets.cash_opening (added in 0024) is also dropped here: the approved
-- design for the new per-day Cash Received/Paid/In Hand summary does NOT
-- carry forward day-to-day (only the existing opening/side balance does),
-- so that column is no longer needed.
-- ==========================================================

create table sheet_rows (
  id         uuid primary key default gen_random_uuid(),
  sheet_id   uuid not null references sheets(id) on delete cascade,
  line_no    integer not null default 1,
  d_amt      numeric not null default 0,
  d_rem      text,
  d_tick     boolean not null default false,
  d_party    uuid references parties(id),
  c_amt      numeric not null default 0,
  c_rem      text,
  c_tick     boolean not null default false,
  c_party    uuid references parties(id),
  created_at timestamptz not null default now()
);

create index sheet_rows_sheet_idx on sheet_rows (sheet_id);

alter table sheet_rows enable row level security;

create policy sheet_rows_select on sheet_rows for select to authenticated using (true);
create policy sheet_rows_insert on sheet_rows for insert to authenticated
  with check (is_app_admin() or has_perm('ledger_create')
    or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy sheet_rows_update on sheet_rows for update to authenticated
  using (is_app_admin() or has_perm('ledger_create') or coalesce(current_setting('app.system_write', true), '') = 'on')
  with check (is_app_admin() or has_perm('ledger_create') or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy sheet_rows_delete on sheet_rows for delete to authenticated
  using (is_app_admin() or has_perm('ledger_create') or coalesce(current_setting('app.system_write', true), '') = 'on');

-- ----------------------------------------------------------
-- Data migration: existing sheets.rows JSONB arrays -> sheet_rows.
-- Old shape per row: [d_amt, d_rem, c_amt, c_rem, d_tick, c_tick, d_party, c_party]
-- ----------------------------------------------------------
insert into sheet_rows (sheet_id, line_no, d_amt, d_rem, d_tick, d_party, c_amt, c_rem, c_tick, c_party)
select
  s.id,
  row_number() over (partition by s.id order by ordinality),
  coalesce((elem->>0)::numeric, 0),
  nullif(elem->>1, ''),
  coalesce((elem->>4)::boolean, false),
  nullif(elem->>6, '')::uuid,
  coalesce((elem->>2)::numeric, 0),
  nullif(elem->>3, ''),
  coalesce((elem->>5)::boolean, false),
  nullif(elem->>7, '')::uuid
from sheets s
cross join lateral jsonb_array_elements(coalesce(s.rows, '[]'::jsonb)) with ordinality as t(elem, ordinality)
where s.deleted_at is null;

alter table sheets drop column rows;
alter table sheets drop column cash_opening;

-- ----------------------------------------------------------
-- Register with the existing generic line-merge infrastructure (0011) —
-- no new merge function needed, sheet_rows plugs straight into
-- smart_merge_lines/apply_merged_lines exactly like voucher_lines etc.
-- ----------------------------------------------------------
create or replace function _smart_merge_allowed_line_tables()
returns text[]
language sql
immutable
as $$
  select array[
    'voucher_lines','sales_return_lines','quotation_lines','po_lines',
    'service_invoice_lines','service_quotation_lines','stock_transfer_lines',
    'sheet_rows'
  ];
$$;
