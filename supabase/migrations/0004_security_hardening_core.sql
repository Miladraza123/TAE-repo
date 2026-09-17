-- ==========================================================
-- Security hardening: fix mutable search_path on trigger functions, and
-- revoke direct RPC-callability of functions that are only ever meant to
-- run as triggers (Postgres already blocks calling a trigger-return-type
-- function outside trigger context, but the linter is right that it
-- shouldn't be in the exposed API surface at all).
-- ==========================================================

create or replace function stamp_audit_fields()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

create or replace function bump_version()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.version := coalesce(old.version, 1) + 1;
  return new;
end;
$$;

create or replace function enforce_perm_on_update()
returns trigger
language plpgsql
set search_path = public
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

create or replace function companies_manage_default()
returns trigger
language plpgsql
set search_path = public
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

create or replace function warehouses_manage_default()
returns trigger
language plpgsql
set search_path = public
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

create or replace function warehouses_block_delete_default()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.deleted_at is null and new.deleted_at is not null and old.is_default then
    raise exception 'Cannot delete the default warehouse — make another warehouse default first'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

-- Trigger-only functions: revoke direct RPC callability entirely.
revoke execute on function stamp_audit_fields() from public, anon, authenticated;
revoke execute on function bump_version() from public, anon, authenticated;
revoke execute on function enforce_perm_on_update() from public, anon, authenticated;
revoke execute on function log_audit_event() from public, anon, authenticated;
revoke execute on function companies_manage_default() from public, anon, authenticated;
revoke execute on function warehouses_manage_default() from public, anon, authenticated;
revoke execute on function warehouses_block_delete_default() from public, anon, authenticated;

-- has_perm/is_app_admin are intentionally callable by authenticated (the app
-- checks its own permissions before showing UI); anon has no legitimate use
-- for them (an unauthenticated caller always gets false back anyway, but
-- there's no reason to expose it).
revoke execute on function has_perm(text) from anon;
revoke execute on function is_app_admin() from anon;
