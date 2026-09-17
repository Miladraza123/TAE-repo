-- ==========================================================
-- Companies (Firms) + Warehouses + period_lock (§8/§17/§25 — minimal master data
-- every other module assumes exists)
-- ==========================================================

-- period_lock.id is an integer (singleton row), not a uuid like every other
-- table's id — widen audit_log.row_id to text so log_audit_event() can log
-- any table's primary key generically, and update the function to match.
alter table audit_log alter column row_id type text using row_id::text;

create or replace function log_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into audit_log(table_name, row_id, action, changed_by, new_data)
    values (tg_table_name, new.id::text, 'insert', auth.uid(), to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into audit_log(table_name, row_id, action, changed_by, old_data, new_data)
    values (tg_table_name, new.id::text, 'update', auth.uid(), to_jsonb(old), to_jsonb(new));
    return new;
  elsif tg_op = 'DELETE' then
    insert into audit_log(table_name, row_id, action, changed_by, old_data)
    values (tg_table_name, old.id::text, 'delete', auth.uid(), to_jsonb(old));
    return old;
  end if;
  return null;
end;
$$;

-- ----------------------------------------------------------
-- companies (Firms)
-- ----------------------------------------------------------
create table companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  address     text,
  city        text,
  phone       text,
  ntn         text,
  is_default  boolean not null default false,
  logo        text, -- data: URI
  signature   text, -- data: URI
  stamp       text, -- data: URI
  version     integer not null default 1,
  created_by  uuid references app_users(id),
  updated_by  uuid references app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  deleted_at  timestamptz
);

create index companies_active_idx on companies (deleted_at);

-- Only one default company at a time; the very first company created is
-- forced default regardless of what was passed (nothing to print with otherwise).
create or replace function companies_manage_default()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' and not exists (select 1 from companies) then
    new.is_default := true;
  end if;
  if new.is_default then
    update companies set is_default = false
      where id <> new.id and is_default = true;
  end if;
  return new;
end;
$$;

create trigger companies_default_before
  before insert or update on companies
  for each row execute function companies_manage_default();

alter table companies enable row level security;

create policy companies_select on companies
  for select to authenticated using (true);

create policy companies_insert on companies
  for insert to authenticated with check (is_app_admin() or has_perm('masters_edit'));

create policy companies_update on companies
  for update to authenticated using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

create policy companies_delete on companies
  for delete to authenticated using (is_app_admin());

create trigger companies_stamp
  before update on companies
  for each row execute function stamp_audit_fields();

create trigger companies_perm
  before update on companies
  for each row execute function enforce_perm_on_update('masters_edit', 'masters_delete', 'recycle_bin');

create trigger companies_audit
  after insert or update or delete on companies
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- warehouses
-- ----------------------------------------------------------
create table warehouses (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  city        text,
  active      boolean not null default true,
  is_default  boolean not null default false,
  version     integer not null default 1,
  created_by  uuid references app_users(id),
  updated_by  uuid references app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz,
  deleted_at  timestamptz
);

create index warehouses_active_idx on warehouses (deleted_at);

create or replace function warehouses_manage_default()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' and not exists (select 1 from warehouses) then
    new.is_default := true;
  end if;
  if new.is_default then
    update warehouses set is_default = false
      where id <> new.id and is_default = true;
  end if;
  return new;
end;
$$;

create trigger warehouses_default_before
  before insert or update on warehouses
  for each row execute function warehouses_manage_default();

-- Block soft-deleting the current default warehouse until another is made default first.
create or replace function warehouses_block_delete_default()
returns trigger
language plpgsql
as $$
begin
  if old.deleted_at is null and new.deleted_at is not null and old.is_default then
    raise exception 'Cannot delete the default warehouse — make another warehouse default first'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger warehouses_block_delete_default_before
  before update on warehouses
  for each row execute function warehouses_block_delete_default();

alter table warehouses enable row level security;

create policy warehouses_select on warehouses
  for select to authenticated using (true);

create policy warehouses_insert on warehouses
  for insert to authenticated with check (is_app_admin() or has_perm('masters_edit'));

create policy warehouses_update on warehouses
  for update to authenticated using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

create policy warehouses_delete on warehouses
  for delete to authenticated using (is_app_admin());

create trigger warehouses_stamp
  before update on warehouses
  for each row execute function stamp_audit_fields();

create trigger warehouses_perm
  before update on warehouses
  for each row execute function enforce_perm_on_update('masters_edit', 'masters_delete', 'recycle_bin');

create trigger warehouses_audit
  after insert or update or delete on warehouses
  for each row execute function log_audit_event();

-- ----------------------------------------------------------
-- period_lock — single row (id=1)
-- ----------------------------------------------------------
create table period_lock (
  id             integer primary key default 1 check (id = 1),
  locked_before  date,
  updated_by     uuid references app_users(id),
  updated_at     timestamptz
);

insert into period_lock (id, locked_before) values (1, null);

alter table period_lock enable row level security;

create policy period_lock_select on period_lock
  for select to authenticated using (true);

create policy period_lock_update on period_lock
  for update to authenticated
  using (is_app_admin() or has_perm('period_lock'))
  with check (is_app_admin() or has_perm('period_lock'));

create trigger period_lock_stamp
  before update on period_lock
  for each row execute function stamp_audit_fields();

create trigger period_lock_audit
  after update on period_lock
  for each row execute function log_audit_event();
