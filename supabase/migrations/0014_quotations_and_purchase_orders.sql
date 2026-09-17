-- ==========================================================
-- Goods Quotations + Purchase Orders (§15/§16) — paper-only documents,
-- zero stock/ledger impact, converting to a real Sales/Purchase Invoice.
-- Unlike the source system, both get status/converted_invoice_id/
-- converted_at tracking (§15's explicit "strict improvement" instruction)
-- and server-side BEFORE INSERT numbering (§6's corrected recommendation).
-- ==========================================================

create sequence seq_quotation_no;
create sequence seq_po_no;

create table quotations (
  id                  uuid primary key default gen_random_uuid(),
  qno                 text not null default '',
  party_id            uuid references parties(id),
  company_id          uuid references companies(id),
  qdate               date not null default current_date,
  narration           text,
  subtotal            numeric not null default 0,
  tax_on              boolean not null default false,
  discount            numeric not null default 0,
  tax_total           numeric not null default 0,
  grand_total         numeric not null default 0,
  loading_on          boolean not null default false,
  loading_amt         numeric not null default 0,
  cartage_on          boolean not null default false,
  cartage_amt         numeric not null default 0,
  cutting_on          boolean not null default false,
  cutting_amt         numeric not null default 0,
  status              text not null default 'open' check (status in ('open','converted','cancelled')),
  converted_invoice_id uuid references vouchers(id),
  converted_at        timestamptz,
  version             integer not null default 1,
  created_by          uuid references app_users(id),
  updated_by          uuid references app_users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz,
  deleted_at          timestamptz
);

create unique index quotations_qno_unique_idx on quotations (qno) where deleted_at is null;
create index quotations_party_idx on quotations (party_id);
create index quotations_active_idx on quotations (deleted_at);

create or replace function assign_quotation_number()
returns trigger language plpgsql set search_path = public as $$
begin
  new.qno := 'QT-' || lpad(nextval('seq_quotation_no')::text, 4, '0');
  return new;
end; $$;

create trigger quotations_assign_number before insert on quotations
  for each row execute function assign_quotation_number();

alter table quotations enable row level security;
create policy quotations_select on quotations for select to authenticated using (true);
create policy quotations_insert on quotations for insert to authenticated
  with check (is_app_admin() or has_perm('quotation_create'));
create policy quotations_update on quotations for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy quotations_delete on quotations for delete to authenticated using (is_app_admin());

create trigger quotations_stamp before update on quotations
  for each row execute function stamp_audit_fields();
create trigger quotations_perm before update on quotations
  for each row execute function enforce_perm_on_update('quotation_edit', 'quotation_delete', 'recycle_bin');
create trigger quotations_audit after insert or update or delete on quotations
  for each row execute function log_audit_event();

create table quotation_lines (
  id         uuid primary key default gen_random_uuid(),
  quotation_id uuid not null references quotations(id) on delete cascade,
  item_id    uuid references items(id),
  qty        numeric not null default 0,
  rate       numeric not null default 0,
  amount     numeric not null default 0,
  line_no    integer not null default 1,
  tax_pct    numeric not null default 0,
  pcs_on     boolean not null default false,
  pcs        numeric,
  created_at timestamptz not null default now()
);

create index quotation_lines_quotation_idx on quotation_lines (quotation_id);

alter table quotation_lines enable row level security;
create policy quotation_lines_select on quotation_lines for select to authenticated using (true);
create policy quotation_lines_insert on quotation_lines for insert to authenticated
  with check (is_app_admin() or has_perm('quotation_create') or has_perm('quotation_edit'));
create policy quotation_lines_update on quotation_lines for update to authenticated
  using (is_app_admin() or has_perm('quotation_edit')) with check (is_app_admin() or has_perm('quotation_edit'));
create policy quotation_lines_delete on quotation_lines for delete to authenticated
  using (is_app_admin() or has_perm('quotation_edit'));

-- ----------------------------------------------------------
-- purchase_orders / po_lines — same pattern, NO loading/cartage/cutting
-- columns (asymmetry with quotations is intentional, §6).
-- ----------------------------------------------------------
create table purchase_orders (
  id                   uuid primary key default gen_random_uuid(),
  pono                 text not null default '',
  party_id             uuid references parties(id),
  company_id           uuid references companies(id),
  podate               date not null default current_date,
  narration            text,
  subtotal             numeric not null default 0,
  tax_on               boolean not null default false,
  discount             numeric not null default 0,
  tax_total            numeric not null default 0,
  grand_total          numeric not null default 0,
  status               text not null default 'open' check (status in ('open','converted','cancelled')),
  converted_invoice_id uuid references vouchers(id),
  converted_at         timestamptz,
  version              integer not null default 1,
  created_by           uuid references app_users(id),
  updated_by           uuid references app_users(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz,
  deleted_at           timestamptz
);

create unique index purchase_orders_pono_unique_idx on purchase_orders (pono) where deleted_at is null;
create index purchase_orders_party_idx on purchase_orders (party_id);
create index purchase_orders_active_idx on purchase_orders (deleted_at);

create or replace function assign_po_number()
returns trigger language plpgsql set search_path = public as $$
begin
  new.pono := 'PO-' || lpad(nextval('seq_po_no')::text, 4, '0');
  return new;
end; $$;

create trigger purchase_orders_assign_number before insert on purchase_orders
  for each row execute function assign_po_number();

alter table purchase_orders enable row level security;
create policy purchase_orders_select on purchase_orders for select to authenticated using (true);
create policy purchase_orders_insert on purchase_orders for insert to authenticated
  with check (is_app_admin() or has_perm('po_create'));
create policy purchase_orders_update on purchase_orders for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy purchase_orders_delete on purchase_orders for delete to authenticated using (is_app_admin());

create trigger purchase_orders_stamp before update on purchase_orders
  for each row execute function stamp_audit_fields();
create trigger purchase_orders_perm before update on purchase_orders
  for each row execute function enforce_perm_on_update('po_edit', 'po_delete', 'recycle_bin');
create trigger purchase_orders_audit after insert or update or delete on purchase_orders
  for each row execute function log_audit_event();

create table po_lines (
  id         uuid primary key default gen_random_uuid(),
  po_id      uuid not null references purchase_orders(id) on delete cascade,
  item_id    uuid references items(id),
  qty        numeric not null default 0,
  rate       numeric not null default 0,
  amount     numeric not null default 0,
  line_no    integer not null default 1,
  tax_pct    numeric not null default 0,
  pcs_on     boolean not null default false,
  pcs        numeric,
  created_at timestamptz not null default now()
);

create index po_lines_po_idx on po_lines (po_id);

alter table po_lines enable row level security;
create policy po_lines_select on po_lines for select to authenticated using (true);
create policy po_lines_insert on po_lines for insert to authenticated
  with check (is_app_admin() or has_perm('po_create') or has_perm('po_edit'));
create policy po_lines_update on po_lines for update to authenticated
  using (is_app_admin() or has_perm('po_edit')) with check (is_app_admin() or has_perm('po_edit'));
create policy po_lines_delete on po_lines for delete to authenticated
  using (is_app_admin() or has_perm('po_edit'));

revoke execute on function assign_quotation_number() from public, anon, authenticated;
revoke execute on function assign_po_number() from public, anon, authenticated;
