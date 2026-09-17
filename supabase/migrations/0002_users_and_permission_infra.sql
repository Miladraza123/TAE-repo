-- ==========================================================
-- app_users + core permission/audit infrastructure (§7/§22/§28)
-- ==========================================================

create table app_users (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text not null,
  is_admin     boolean not null default false,
  is_active    boolean not null default true,
  perms        jsonb not null default '{}'::jsonb,
  version      integer not null default 1,
  created_by   uuid references app_users(id),
  updated_by   uuid references app_users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz
  -- no deleted_at: a login identity is deactivated (is_active=false), never soft-deleted
);

comment on table app_users is 'Profile + permission row for each Supabase Auth user. Admin-provisioned only, see §7.';

-- ----------------------------------------------------------
-- audit_log — written ONLY by log_audit_event(), never directly by the app
-- ----------------------------------------------------------
create table audit_log (
  id          uuid primary key default gen_random_uuid(),
  table_name  text not null,
  row_id      uuid,
  action      text not null check (action in ('insert','update','delete')),
  changed_by  uuid references app_users(id),
  changed_at  timestamptz not null default now(),
  old_data    jsonb,
  new_data    jsonb
);

create index audit_log_table_row_idx on audit_log (table_name, row_id);
create index audit_log_changed_at_idx on audit_log (changed_at);

-- ----------------------------------------------------------
-- has_perm(key) / is_app_admin() — SECURITY DEFINER, used throughout RLS + triggers
-- ----------------------------------------------------------
create or replace function has_perm(key text)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select is_active and (is_admin or coalesce((perms->>key)::boolean, false))
     from app_users
     where id = auth.uid()),
    false
  );
$$;

create or replace function is_app_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (select is_active and is_admin from app_users where id = auth.uid()),
    false
  );
$$;

-- ----------------------------------------------------------
-- stamp_audit_fields — BEFORE UPDATE trigger: sets updated_at/updated_by
-- ----------------------------------------------------------
create or replace function stamp_audit_fields()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

-- ----------------------------------------------------------
-- bump_version — BEFORE UPDATE trigger for tables outside the smart_merge_update
-- RPC path (that RPC increments version itself; don't double-wire both on one table)
-- ----------------------------------------------------------
create or replace function bump_version()
returns trigger
language plpgsql
as $$
begin
  new.version := coalesce(old.version, 1) + 1;
  return new;
end;
$$;

-- ----------------------------------------------------------
-- log_audit_event — AFTER INSERT/UPDATE/DELETE trigger, generic per-table
-- ----------------------------------------------------------
create or replace function log_audit_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into audit_log(table_name, row_id, action, changed_by, new_data)
    values (tg_table_name, new.id, 'insert', auth.uid(), to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into audit_log(table_name, row_id, action, changed_by, old_data, new_data)
    values (tg_table_name, new.id, 'update', auth.uid(), to_jsonb(old), to_jsonb(new));
    return new;
  elsif tg_op = 'DELETE' then
    insert into audit_log(table_name, row_id, action, changed_by, old_data)
    values (tg_table_name, old.id, 'delete', auth.uid(), to_jsonb(old));
    return old;
  end if;
  return null;
end;
$$;

-- ----------------------------------------------------------
-- enforce_perm_on_update(edit_perm, delete_perm, restore_perm) — BEFORE UPDATE trigger
-- Distinguishes soft-delete / restore / ordinary edit by the deleted_at transition.
-- is_app_admin() and the app.system_write session flag both bypass this check.
-- ----------------------------------------------------------
create or replace function enforce_perm_on_update()
returns trigger
language plpgsql
as $$
declare
  edit_perm    text := tg_argv[0];
  delete_perm  text := tg_argv[1];
  restore_perm text := tg_argv[2];
  required     text;
begin
  if is_app_admin() then
    return new;
  end if;
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return new;
  end if;

  if old.deleted_at is null and new.deleted_at is not null then
    required := delete_perm;
  elsif old.deleted_at is not null and new.deleted_at is null then
    required := restore_perm;
  else
    required := edit_perm;
  end if;

  if not has_perm(required) then
    raise exception 'permission denied: % required', required
      using errcode = '42501';
  end if;

  return new;
end;
$$;

comment on function enforce_perm_on_update() is
  'Parameterized per table: enforce_perm_on_update(edit_perm, delete_perm, restore_perm). See §22/§28.';

-- ----------------------------------------------------------
-- RLS on app_users / audit_log
-- ----------------------------------------------------------
alter table app_users enable row level security;
alter table audit_log enable row level security;

create policy app_users_select on app_users
  for select to authenticated using (true);

-- Bootstrap exception: the very first app_users row (before any admin exists)
-- may be inserted by any authenticated user, since is_app_admin() can never be
-- true yet at that point. Once at least one row exists, only an admin can insert.
create policy app_users_insert on app_users
  for insert to authenticated with check (
    is_app_admin() or not exists (select 1 from app_users)
  );

create policy app_users_update on app_users
  for update to authenticated using (is_app_admin()) with check (is_app_admin());

create policy app_users_delete on app_users
  for delete to authenticated using (is_app_admin());

create policy audit_log_select on audit_log
  for select to authenticated using (is_app_admin());

-- audit_log has no insert/update/delete policy for authenticated users: it is written
-- only by log_audit_event(), a SECURITY DEFINER trigger function that bypasses RLS.

create trigger app_users_stamp
  before update on app_users
  for each row execute function stamp_audit_fields();

create trigger app_users_audit
  after insert or update or delete on app_users
  for each row execute function log_audit_event();
