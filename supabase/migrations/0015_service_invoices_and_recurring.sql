-- ==========================================================
-- Service Invoices + Service Quotations + Recurring Service Templates
-- (§6). Built with the CORRECTED consistent pattern the spec explicitly
-- calls for: granular quotation_*-style permissions, the enforce_perm_on_
-- update trigger wired (source system's OBSERVED GAP, fixed here), and
-- the same smart_merge save path as every other document — NOT the
-- source's blanket-RLS/plain-optimistic-lock shortcut.
-- Totals ARE authoritatively recomputed by a DB trigger on line changes
-- or header tax_on/discount changes (§6's explicit description for this
-- table pair specifically, unlike vouchers).
-- ==========================================================

create sequence seq_service_invoice_no;

create table service_invoices (
  id            uuid primary key default gen_random_uuid(),
  sino          text not null default '',
  party_id      uuid references parties(id),
  company_id    uuid references companies(id),
  sidate        date not null default current_date,
  due_date      date,
  billing_from  date,
  billing_to    date,
  billing_label text,
  narration     text,
  notes         text,
  tax_on        boolean not null default false,
  sub_total     numeric not null default 0,
  discount      numeric not null default 0,
  tax_total     numeric not null default 0,
  grand_total   numeric not null default 0,
  paid          numeric not null default 0,
  status        text not null default 'open' check (status in ('open','paid','cancelled')),
  version       integer not null default 1,
  created_by    uuid references app_users(id),
  updated_by    uuid references app_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz,
  deleted_at    timestamptz
);

create unique index service_invoices_sino_unique_idx on service_invoices (sino) where deleted_at is null;
create index service_invoices_party_idx on service_invoices (party_id);
create index service_invoices_active_idx on service_invoices (deleted_at);

create or replace function assign_service_invoice_number()
returns trigger language plpgsql set search_path = public as $$
begin
  new.sino := 'SV-' || lpad(nextval('seq_service_invoice_no')::text, 4, '0');
  return new;
end; $$;

create trigger service_invoices_assign_number before insert on service_invoices
  for each row execute function assign_service_invoice_number();

alter table service_invoices enable row level security;
create policy service_invoices_select on service_invoices for select to authenticated using (true);
create policy service_invoices_insert on service_invoices for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create'));
create policy service_invoices_update on service_invoices for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy service_invoices_delete on service_invoices for delete to authenticated using (is_app_admin());

create trigger service_invoices_stamp before update on service_invoices
  for each row execute function stamp_audit_fields();
create trigger service_invoices_perm before update on service_invoices
  for each row execute function enforce_perm_on_update('bill_edit', 'bill_delete', 'recycle_bin');
create trigger service_invoices_audit after insert or update or delete on service_invoices
  for each row execute function log_audit_event();

create table service_invoice_lines (
  id            uuid primary key default gen_random_uuid(),
  invoice_id    uuid not null references service_invoices(id) on delete cascade,
  service_id    uuid references services(id),
  description   text,
  qty           numeric not null default 1,
  rate          numeric not null default 0,
  tax_pct       numeric not null default 0,
  amount        numeric not null default 0,
  line_no       integer not null default 1,
  created_at    timestamptz not null default now()
);

create index service_invoice_lines_invoice_idx on service_invoice_lines (invoice_id);

alter table service_invoice_lines enable row level security;
create policy service_invoice_lines_select on service_invoice_lines for select to authenticated using (true);
create policy service_invoice_lines_insert on service_invoice_lines for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create') or has_perm('bill_edit')
    or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy service_invoice_lines_update on service_invoice_lines for update to authenticated
  using (is_app_admin() or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on')
  with check (is_app_admin() or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy service_invoice_lines_delete on service_invoice_lines for delete to authenticated
  using (is_app_admin() or has_perm('bill_edit'));

-- Authoritative totals recompute (§6): fires on line AIUD or on header
-- tax_on/discount change. Guarded by app.system_write to avoid recursion
-- when this same trigger's own header UPDATE fires the header-side branch.
create or replace function recompute_service_invoice_totals(p_invoice_id uuid)
returns void language plpgsql set search_path = public as $$
declare
  v_sub numeric; v_tax numeric; v_disc numeric; v_tax_on boolean;
begin
  select coalesce(sum(qty * rate), 0) into v_sub from service_invoice_lines where invoice_id = p_invoice_id;
  select tax_on, discount into v_tax_on, v_disc from service_invoices where id = p_invoice_id;
  if v_tax_on then
    select coalesce(sum(qty * rate * tax_pct / 100), 0) into v_tax from service_invoice_lines where invoice_id = p_invoice_id;
  else
    v_tax := 0;
  end if;

  perform set_config('app.system_write', 'on', true);
  update service_invoices
    set sub_total = v_sub, tax_total = v_tax, grand_total = v_sub - coalesce(v_disc, 0) + v_tax
    where id = p_invoice_id;
  perform set_config('app.system_write', 'off', true);
end; $$;

create or replace function trg_service_invoice_lines_totals()
returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  perform recompute_service_invoice_totals(coalesce(new.invoice_id, old.invoice_id));
  return coalesce(new, old);
end; $$;

create trigger service_invoice_lines_totals_after
  after insert or update or delete on service_invoice_lines
  for each row execute function trg_service_invoice_lines_totals();

create or replace function trg_service_invoice_header_totals()
returns trigger language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return new;
  end if;
  if old.tax_on is distinct from new.tax_on or old.discount is distinct from new.discount then
    perform recompute_service_invoice_totals(new.id);
  end if;
  return new;
end; $$;

create trigger service_invoices_header_totals_after
  after update on service_invoices
  for each row execute function trg_service_invoice_header_totals();

-- ----------------------------------------------------------
-- service_quotations / service_quotation_lines — mirrors service_invoices
-- ----------------------------------------------------------
create sequence seq_service_quotation_no;

create table service_quotations (
  id                   uuid primary key default gen_random_uuid(),
  sqno                 text not null default '',
  party_id             uuid references parties(id),
  company_id           uuid references companies(id),
  sqdate               date not null default current_date,
  valid_till           date,
  billing_from         date,
  billing_to           date,
  billing_label        text,
  narration            text,
  notes                text,
  tax_on               boolean not null default false,
  sub_total            numeric not null default 0,
  discount             numeric not null default 0,
  tax_total            numeric not null default 0,
  grand_total          numeric not null default 0,
  status               text not null default 'open' check (status in ('open','converted','cancelled')),
  converted_invoice_id uuid references service_invoices(id),
  converted_at         timestamptz,
  version              integer not null default 1,
  created_by           uuid references app_users(id),
  updated_by           uuid references app_users(id),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz,
  deleted_at           timestamptz
);

create unique index service_quotations_sqno_unique_idx on service_quotations (sqno) where deleted_at is null;
create index service_quotations_party_idx on service_quotations (party_id);
create index service_quotations_active_idx on service_quotations (deleted_at);

create or replace function assign_service_quotation_number()
returns trigger language plpgsql set search_path = public as $$
begin
  new.sqno := 'SQ-' || lpad(nextval('seq_service_quotation_no')::text, 4, '0');
  return new;
end; $$;

create trigger service_quotations_assign_number before insert on service_quotations
  for each row execute function assign_service_quotation_number();

alter table service_quotations enable row level security;
create policy service_quotations_select on service_quotations for select to authenticated using (true);
create policy service_quotations_insert on service_quotations for insert to authenticated
  with check (is_app_admin() or has_perm('quotation_create'));
create policy service_quotations_update on service_quotations for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy service_quotations_delete on service_quotations for delete to authenticated using (is_app_admin());

create trigger service_quotations_stamp before update on service_quotations
  for each row execute function stamp_audit_fields();
create trigger service_quotations_perm before update on service_quotations
  for each row execute function enforce_perm_on_update('quotation_edit', 'quotation_delete', 'recycle_bin');
create trigger service_quotations_audit after insert or update or delete on service_quotations
  for each row execute function log_audit_event();

create table service_quotation_lines (
  id            uuid primary key default gen_random_uuid(),
  quotation_id  uuid not null references service_quotations(id) on delete cascade,
  service_id    uuid references services(id),
  description   text,
  qty           numeric not null default 1,
  rate          numeric not null default 0,
  tax_pct       numeric not null default 0,
  amount        numeric not null default 0,
  line_no       integer not null default 1,
  created_at    timestamptz not null default now()
);

create index service_quotation_lines_quotation_idx on service_quotation_lines (quotation_id);

alter table service_quotation_lines enable row level security;
create policy service_quotation_lines_select on service_quotation_lines for select to authenticated using (true);
create policy service_quotation_lines_insert on service_quotation_lines for insert to authenticated
  with check (is_app_admin() or has_perm('quotation_create') or has_perm('quotation_edit'));
create policy service_quotation_lines_update on service_quotation_lines for update to authenticated
  using (is_app_admin() or has_perm('quotation_edit')) with check (is_app_admin() or has_perm('quotation_edit'));
create policy service_quotation_lines_delete on service_quotation_lines for delete to authenticated
  using (is_app_admin() or has_perm('quotation_edit'));

-- ----------------------------------------------------------
-- recurring_service_templates (§6)
-- ----------------------------------------------------------
create table recurring_service_templates (
  id            uuid primary key default gen_random_uuid(),
  party_id      uuid references parties(id),
  company_id    uuid references companies(id),
  lines         jsonb not null default '[]'::jsonb, -- [{service_id,description,qty,rate,tax_pct}]
  frequency     text not null check (frequency in ('monthly','quarterly','half_yearly','yearly','custom_months','custom_days')),
  n             integer, -- required for custom_months/custom_days
  start_date    date not null,
  next_date     date,
  active        boolean not null default true,
  version       integer not null default 1,
  created_by    uuid references app_users(id),
  updated_by    uuid references app_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz,
  deleted_at    timestamptz
);

create or replace function recurring_templates_default_next_date()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.next_date is null then
    new.next_date := new.start_date;
  end if;
  return new;
end; $$;

create trigger recurring_templates_default_next_before
  before insert on recurring_service_templates
  for each row execute function recurring_templates_default_next_date();

alter table recurring_service_templates enable row level security;
create policy recurring_templates_select on recurring_service_templates for select to authenticated using (true);
create policy recurring_templates_insert on recurring_service_templates for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create'));
create policy recurring_templates_update on recurring_service_templates for update to authenticated
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy recurring_templates_delete on recurring_service_templates for delete to authenticated using (is_app_admin());

create trigger recurring_templates_stamp before update on recurring_service_templates
  for each row execute function stamp_audit_fields();
create trigger recurring_templates_perm before update on recurring_service_templates
  for each row execute function enforce_perm_on_update('bill_edit', 'bill_delete', 'recycle_bin');
create trigger recurring_templates_audit after insert or update or delete on recurring_service_templates
  for each row execute function log_audit_event();

-- next_recurring_date(from, freq, n) — exact frequency rules (§6)
create or replace function next_recurring_date(p_from date, p_freq text, p_n integer default null)
returns date language plpgsql immutable as $$
begin
  return (case p_freq
    when 'monthly' then p_from + interval '1 month'
    when 'quarterly' then p_from + interval '3 months'
    when 'half_yearly' then p_from + interval '6 months'
    when 'yearly' then p_from + interval '1 year'
    when 'custom_months' then p_from + (coalesce(p_n, 1) || ' months')::interval
    when 'custom_days' then p_from + (coalesce(p_n, 1) || ' days')::interval
    else p_from::timestamp
  end)::date;
end; $$;

revoke execute on function assign_service_invoice_number() from public, anon, authenticated;
revoke execute on function assign_service_quotation_number() from public, anon, authenticated;
revoke execute on function recurring_templates_default_next_date() from public, anon, authenticated;
revoke execute on function trg_service_invoice_lines_totals() from public, anon, authenticated;
revoke execute on function trg_service_invoice_header_totals() from public, anon, authenticated;
grant execute on function next_recurring_date(date, text, integer) to authenticated;
