-- ==========================================================
-- Delivery Challans (DC) + Material Issue + custom invoice lines
--
-- Flow: Quotation → DC (partial, many) → Sales Invoice (from one or more
-- DCs). Stock moves at the DC and at the Material Issue, never again on
-- the invoice made from a DC.
--
-- * delivery_challans / dc_lines — what left the godown for a customer.
--   No rates (rates live on the invoice). A dc_line is either
--     - a stock item sold as is  (consumption_type general_goods):
--       its own stock goes out at the DC, or
--     - a manufactured product   (consumption_type manufactured): a Masters
--       item or a custom name; its stock does NOT move — its raw material
--       leaves through Material Issues against the quotation.
--   quotation_line_id ties a DC line to the order line it delivers, for
--   Ordered / Delivered / Pending.
-- * material_issues — raw material taken out against a quotation (the
--   order), as many times as needed; stock goes out on the issue date.
-- * voucher_lines.dc_line_id — an invoice line made from a DC line; the
--   costing engine skips such sale lines (the DC already moved the stock).
--   voucher_lines.custom_name/custom_unit — a custom product on a direct
--   invoice; its stock effect is only its raw materials
--   (voucher_line_material_consumption), as for Raw Material lines today.
-- ==========================================================

create sequence if not exists seq_dc_no;

create table if not exists delivery_challans (
  id uuid primary key default gen_random_uuid(),
  dcno text unique,
  dc_date date not null default current_date,
  party_id uuid not null references parties(id),
  company_id uuid references companies(id),
  quotation_id uuid references quotations(id),
  narration text,
  version integer not null default 1,
  created_by uuid references app_users(id),
  updated_by uuid references app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  deleted_at timestamptz
);
create index if not exists delivery_challans_party_idx on delivery_challans (party_id);
create index if not exists delivery_challans_quotation_idx on delivery_challans (quotation_id);

create table if not exists dc_lines (
  id uuid primary key default gen_random_uuid(),
  dc_id uuid not null references delivery_challans(id) on delete cascade,
  line_no integer not null default 1,
  item_id uuid references items(id),
  custom_name text,
  custom_unit text,
  description text,
  qty numeric not null default 0 check (qty >= 0),
  consumption_type text not null default 'general_goods' check (consumption_type in ('general_goods','manufactured')),
  warehouse_id uuid references warehouses(id),
  quotation_line_id uuid references quotation_lines(id),
  cost_amount numeric,
  created_at timestamptz not null default now(),
  check (item_id is not null or coalesce(btrim(custom_name), '') <> ''),
  check (item_id is not null or consumption_type = 'manufactured')
);
create index if not exists dc_lines_dc_idx on dc_lines (dc_id);
create index if not exists dc_lines_item_idx on dc_lines (item_id);
create index if not exists dc_lines_qline_idx on dc_lines (quotation_line_id);

create table if not exists material_issues (
  id uuid primary key default gen_random_uuid(),
  quotation_id uuid not null references quotations(id),
  issue_date date not null default current_date,
  item_id uuid not null references items(id),
  qty numeric not null check (qty > 0),
  warehouse_id uuid references warehouses(id),
  notes text,
  cost_amount numeric,
  version integer not null default 1,
  created_by uuid references app_users(id),
  updated_by uuid references app_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  deleted_at timestamptz
);
create index if not exists material_issues_quotation_idx on material_issues (quotation_id);
create index if not exists material_issues_item_idx on material_issues (item_id);

alter table voucher_lines add column if not exists dc_line_id uuid references dc_lines(id);
alter table voucher_lines add column if not exists custom_name text;
alter table voucher_lines add column if not exists custom_unit text;
create index if not exists voucher_lines_dc_line_idx on voucher_lines (dc_line_id);

-- ---- numbering / audit / permission triggers (same pattern as other docs) ----
create or replace function assign_dc_number()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.dcno is null or btrim(new.dcno) = '' then
    new.dcno := 'DC-' || lpad(nextval('seq_dc_no')::text, 4, '0');
  end if;
  return new;
end; $$;

create trigger delivery_challans_assign_number before insert on delivery_challans
  for each row execute function assign_dc_number();
create trigger delivery_challans_audit after insert or update or delete on delivery_challans
  for each row execute function log_audit_event();
create trigger delivery_challans_perm before update on delivery_challans
  for each row execute function enforce_perm_on_update('bill_edit', 'bill_delete', 'recycle_bin');
create trigger delivery_challans_stamp before update on delivery_challans
  for each row execute function stamp_audit_fields();

create trigger material_issues_audit after insert or update or delete on material_issues
  for each row execute function log_audit_event();
create trigger material_issues_perm before update on material_issues
  for each row execute function enforce_perm_on_update('bill_edit', 'bill_delete', 'recycle_bin');
create trigger material_issues_stamp before update on material_issues
  for each row execute function stamp_audit_fields();

-- Period Lock: nothing dated before the lock may be created or changed.
create or replace function check_period_lock_dc_mi()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_lock date;
  v_old date;
  v_new date;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is null then return coalesce(new, old); end if;
  if tg_table_name = 'delivery_challans' then
    v_old := case when tg_op <> 'INSERT' then old.dc_date end;
    v_new := case when tg_op <> 'DELETE' then new.dc_date end;
  else
    v_old := case when tg_op <> 'INSERT' then old.issue_date end;
    v_new := case when tg_op <> 'DELETE' then new.issue_date end;
  end if;
  if (v_old is not null and v_old < v_lock) or (v_new is not null and v_new < v_lock) then
    raise exception 'This document is dated before the locked period (%).', v_lock using errcode = '23514';
  end if;
  return coalesce(new, old);
end; $$;
create trigger delivery_challans_period_lock before insert or update or delete on delivery_challans
  for each row execute function check_period_lock_dc_mi();
create trigger material_issues_period_lock before insert or update or delete on material_issues
  for each row execute function check_period_lock_dc_mi();

-- ---- stock recompute when DC lines / DCs / issues change ----
create or replace function trg_recompute_dc_lines()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op <> 'INSERT' and old.item_id is not null then
    perform recompute_item_cost(old.item_id);
  end if;
  if tg_op <> 'DELETE' and new.item_id is not null
     and (tg_op = 'INSERT' or old.item_id is distinct from new.item_id or old.qty is distinct from new.qty
          or old.consumption_type is distinct from new.consumption_type) then
    perform recompute_item_cost(new.item_id);
  end if;
  return coalesce(new, old);
end; $$;
create trigger dc_lines_recompute_after after insert or update or delete on dc_lines
  for each row execute function trg_recompute_dc_lines();

create or replace function trg_recompute_dc_header()
returns trigger
language plpgsql
set search_path = public
as $$
declare v_item uuid;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return new;
  end if;
  if old.deleted_at is distinct from new.deleted_at or old.dc_date is distinct from new.dc_date then
    for v_item in select distinct item_id from dc_lines where dc_id = new.id and item_id is not null loop
      perform recompute_item_cost(v_item);
    end loop;
  end if;
  return new;
end; $$;
create trigger delivery_challans_recompute_after after update on delivery_challans
  for each row execute function trg_recompute_dc_header();

create or replace function trg_recompute_material_issues()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op <> 'INSERT' then perform recompute_item_cost(old.item_id); end if;
  if tg_op <> 'DELETE' and (tg_op = 'INSERT' or old.item_id is distinct from new.item_id) then
    perform recompute_item_cost(new.item_id);
  end if;
  return coalesce(new, old);
end; $$;
create trigger material_issues_recompute_after after insert or update or delete on material_issues
  for each row execute function trg_recompute_material_issues();

-- ---- RLS ----
alter table delivery_challans enable row level security;
alter table dc_lines enable row level security;
alter table material_issues enable row level security;

create policy delivery_challans_select on delivery_challans for select to authenticated using ((select is_active_app_user()));
create policy delivery_challans_insert on delivery_challans for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create'));
create policy delivery_challans_update on delivery_challans for update to authenticated
  using (is_app_admin() or has_perm('bill_edit') or has_perm('bill_delete') or has_perm('recycle_bin'))
  with check (is_app_admin() or has_perm('bill_edit') or has_perm('bill_delete') or has_perm('recycle_bin'));

create policy dc_lines_select on dc_lines for select to authenticated using ((select is_active_app_user()));
create policy dc_lines_insert on dc_lines for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create') or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy dc_lines_update on dc_lines for update to authenticated
  using (is_app_admin() or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on')
  with check (is_app_admin() or has_perm('bill_edit') or coalesce(current_setting('app.system_write', true), '') = 'on');
create policy dc_lines_remove on dc_lines for delete to authenticated
  using (is_app_admin() or has_perm('bill_edit'));

create policy material_issues_select on material_issues for select to authenticated using ((select is_active_app_user()));
create policy material_issues_insert on material_issues for insert to authenticated
  with check (is_app_admin() or has_perm('bill_create') or has_perm('bill_edit'));
create policy material_issues_update on material_issues for update to authenticated
  using (is_app_admin() or has_perm('bill_edit') or has_perm('bill_delete') or has_perm('recycle_bin') or coalesce(current_setting('app.system_write', true), '') = 'on')
  with check (is_app_admin() or has_perm('bill_edit') or has_perm('bill_delete') or has_perm('recycle_bin') or coalesce(current_setting('app.system_write', true), '') = 'on');

grant select, insert, update on delivery_challans, material_issues to authenticated;
grant select, insert, update, delete on dc_lines to authenticated;
grant usage on sequence seq_dc_no to authenticated;
