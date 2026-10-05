-- ==========================================================
-- Security hardening
--
-- 1) Reads: every table's SELECT policy was `using (true)` for the
--    authenticated role, so ANY signed-in account — including one made by
--    public sign-up that has no app_users profile, or a deactivated user —
--    could read every party, bill and ledger row through the REST API.
--    Reads now require an active app user (app_users.is_active).
--    app_users additionally lets a user read their own row, so the sign-in
--    screen can still tell "disabled" from "not set up".
--
-- 2) apply_merged_lines (SECURITY DEFINER, so it bypasses RLS) had no
--    permission check: any signed-in account could delete or rewrite all
--    lines of any bill or Daily Ledger sheet, even inside a locked period.
--    It now requires the same permission as the line table's own
--    UPDATE/DELETE policies, and refuses lines of a document dated before
--    the Period Lock. smart_merge_lines (read + diff only) requires an
--    active app user.
-- ==========================================================

create or replace function is_active_app_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select is_active from app_users where id = auth.uid()), false);
$$;
revoke execute on function is_active_app_user() from public, anon;
grant execute on function is_active_app_user() to authenticated;

-- ---- 1) reads: active app users only ----
do $$
declare t text;
begin
  foreach t in array array[
    'companies','item_cost_snapshot','item_specs','item_units','items','parties','party_kinds',
    'party_opening_balances','period_lock','po_lines','purchase_orders','quotation_lines','quotations',
    'recurring_service_templates','sales_return_lines','sales_return_material_restoration','sales_returns',
    'service_invoice_lines','service_invoices','service_quotation_lines','service_quotations','services',
    'sheet_rows','sheets','stock_adjustments','stock_transfer_lines','stock_transfers',
    'voucher_line_material_consumption','voucher_lines','vouchers','warehouses']
  loop
    execute format('alter policy %I on %I using ((select is_active_app_user()))',
      case t
        when 'recurring_service_templates' then 'recurring_templates_select'
        when 'sales_return_material_restoration' then 'srmr_select'
        when 'voucher_line_material_consumption' then 'vlmc_select'
        else t || '_select' end,
      t);
  end loop;
end $$;

alter policy app_users_select on app_users using (id = (select auth.uid()) or (select is_active_app_user()));

-- ---- 2) line merge: permission + period lock ----
create or replace function _line_table_edit_allowed(p_line_table text, p_fk_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_perm text;
  v_lock date;
  v_doc_date date;
begin
  if not is_active_app_user() then
    raise exception 'permission denied: active app user required' using errcode = '42501';
  end if;

  v_perm := case p_line_table
    when 'voucher_lines' then 'bill_edit'
    when 'sales_return_lines' then 'bill_edit'
    when 'service_invoice_lines' then 'bill_edit'
    when 'stock_transfer_lines' then 'bill_edit'
    when 'quotation_lines' then 'quotation_edit'
    when 'service_quotation_lines' then 'quotation_edit'
    when 'po_lines' then 'po_edit'
    when 'sheet_rows' then 'ledger_create'
  end;
  if v_perm is null then
    raise exception 'line table % is not allowed', p_line_table using errcode = '42501';
  end if;
  if not (is_app_admin() or has_perm(v_perm)) then
    raise exception 'permission denied: % required', v_perm using errcode = '42501';
  end if;

  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is not null then
    v_doc_date := case p_line_table
      when 'voucher_lines' then (select vdate from vouchers where id = p_fk_id)
      when 'sales_return_lines' then (select rdate from sales_returns where id = p_fk_id)
      when 'sheet_rows' then (select sheet_date from sheets where id = p_fk_id)
    end;
    if v_doc_date is not null and v_doc_date < v_lock then
      raise exception 'This document is dated before the locked period (%) and its lines cannot be changed.', v_lock
        using errcode = '23514';
    end if;
  end if;
end;
$$;
revoke execute on function _line_table_edit_allowed(text, uuid) from public, anon, authenticated;

create or replace function apply_merged_lines(p_line_table text, p_fk_col text, p_fk_id uuid, p_result_lines jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_line       jsonb;
  v_id         uuid;
  v_kept_ids   uuid[] := array[]::uuid[];
  v_set_clause text;
  v_cols       text;
  v_placeholders text;
  v_line_no_ctr integer := 0;
  v_final      jsonb;
begin
  if not (p_line_table = any (_smart_merge_allowed_line_tables())) then
    raise exception 'apply_merged_lines: table % is not allowed', p_line_table using errcode = '42501';
  end if;
  perform _line_table_edit_allowed(p_line_table, p_fk_id);

  for v_line in select * from jsonb_array_elements(p_result_lines) loop
    v_id := nullif(v_line->>'id', '')::uuid;
    if v_id is not null then
      v_kept_ids := array_append(v_kept_ids, v_id);
    end if;
  end loop;

  if array_length(v_kept_ids, 1) > 0 then
    execute format('delete from %I where %I = $1 and id <> all($2)', p_line_table, p_fk_col)
      using p_fk_id, v_kept_ids;
  else
    execute format('delete from %I where %I = $1', p_line_table, p_fk_col) using p_fk_id;
  end if;

  for v_line in select * from jsonb_array_elements(p_result_lines) loop
    v_id := nullif(v_line->>'id', '')::uuid;
    v_line_no_ctr := v_line_no_ctr + 1;
    v_line := v_line || jsonb_build_object('line_no', coalesce((v_line->>'line_no')::int, v_line_no_ctr));

    if v_id is not null then
      select string_agg(format('%I = ($1 ->> %L)::%s', c.column_name, c.column_name, c.udt_name), ', ')
      into v_set_clause
      from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = p_line_table
        and c.column_name in (select jsonb_object_keys(v_line))
        and c.column_name not in ('id', p_fk_col, 'created_at');

      if v_set_clause is not null then
        execute format('update %I set %s where id = $2', p_line_table, v_set_clause) using v_line, v_id;
      end if;
    else
      select string_agg(format('%I', c.column_name), ', '),
             string_agg(format('($2 ->> %L)::%s', c.column_name, c.udt_name), ', ')
      into v_cols, v_placeholders
      from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = p_line_table
        and c.column_name in (select jsonb_object_keys(v_line))
        and c.column_name not in ('id', 'created_at');

      if v_cols is not null then
        execute format('insert into %I (%I, %s) values ($1, %s)', p_line_table, p_fk_col, v_cols, v_placeholders)
          using p_fk_id, v_line;
      end if;
    end if;
  end loop;

  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from %I t where %I = $1', p_line_table, p_fk_col)
    into v_final using p_fk_id;
  return v_final;
end;
$function$;

-- smart_merge_lines (read + diff) and smart_merge_update: active app
-- users only. smart_merge_update's writes are additionally guarded by the
-- per-table enforce_perm_on_update triggers, unchanged.
create or replace function smart_merge_lines(p_line_table text, p_fk_col text, p_fk_id uuid, p_original_lines jsonb, p_new_lines jsonb, p_ignore text[] default array['id'::text, 'created_at'::text])
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_current_lines jsonb;
  v_result        jsonb := '[]'::jsonb;
  v_conflict_names text[] := array[]::text[];
  v_line          jsonb;
  v_id            uuid;
  v_orig_line     jsonb;
  v_cur_line      jsonb;
  v_key           text;
  v_merged_line   jsonb;
  v_had_conflict  boolean;
  v_current_ids   uuid[];
  v_original_ids  uuid[];
  v_submitted_ids uuid[] := array[]::uuid[];
begin
  if not is_active_app_user() then
    raise exception 'permission denied: active app user required' using errcode = '42501';
  end if;
  if not (p_line_table = any (_smart_merge_allowed_line_tables())) then
    raise exception 'smart_merge_lines: table % is not allowed', p_line_table using errcode = '42501';
  end if;

  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from %I t where %I = $1', p_line_table, p_fk_col)
    into v_current_lines using p_fk_id;

  select array_agg((l->>'id')::uuid) into v_current_ids
    from jsonb_array_elements(v_current_lines) l;
  select array_agg((l->>'id')::uuid) into v_original_ids
    from jsonb_array_elements(p_original_lines) l where l->>'id' is not null;

  for v_line in select * from jsonb_array_elements(p_new_lines) loop
    v_id := nullif(v_line->>'id', '')::uuid;

    if v_id is null then
      v_result := v_result || jsonb_build_array(v_line);
      continue;
    end if;

    v_submitted_ids := array_append(v_submitted_ids, v_id);

    if not (v_id = any (coalesce(v_current_ids, array[]::uuid[]))) then
      continue;
    end if;

    select l into v_cur_line from jsonb_array_elements(v_current_lines) l where (l->>'id')::uuid = v_id;

    if not (v_id = any (coalesce(v_original_ids, array[]::uuid[]))) then
      v_result := v_result || jsonb_build_array(v_cur_line);
      continue;
    end if;

    select l into v_orig_line from jsonb_array_elements(p_original_lines) l where (l->>'id')::uuid = v_id;

    v_merged_line := v_cur_line;
    v_had_conflict := false;
    for v_key in select jsonb_object_keys(v_line) loop
      if v_key = any (p_ignore) then continue; end if;
      if (v_line -> v_key) is not distinct from (v_orig_line -> v_key) then
        continue;
      elsif (v_cur_line -> v_key) is not distinct from (v_orig_line -> v_key) then
        v_merged_line := v_merged_line || jsonb_build_object(v_key, v_line -> v_key);
      elsif (v_cur_line -> v_key) is not distinct from (v_line -> v_key) then
        continue;
      else
        v_had_conflict := true;
      end if;
    end loop;

    if v_had_conflict then
      v_conflict_names := array_append(v_conflict_names,
        coalesce(v_cur_line->>'item_id', v_id::text));
    else
      v_result := v_result || jsonb_build_array(v_merged_line);
    end if;
  end loop;

  v_result := v_result || (
    select coalesce(jsonb_agg(l), '[]'::jsonb)
    from jsonb_array_elements(v_current_lines) l
    where not ((l->>'id')::uuid = any (coalesce(v_original_ids, array[]::uuid[])))
      and not ((l->>'id')::uuid = any (v_submitted_ids))
  );

  if array_length(v_conflict_names, 1) > 0 then
    return jsonb_build_object(
      'status', 'conflict', 'conflicts', to_jsonb(v_conflict_names),
      'current', v_current_lines, 'merged_lines', v_result
    );
  end if;

  return jsonb_build_object('status', 'ok', 'lines', v_result);
end;
$function$;

create or replace function smart_merge_update(p_table text, p_id uuid, p_original jsonb, p_new jsonb, p_ignore text[] default array['id'::text, 'created_at'::text, 'created_by'::text, 'updated_at'::text, 'updated_by'::text, 'version'::text, 'deleted_at'::text])
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_current  jsonb;
  v_key      text;
  v_merged   jsonb := '{}'::jsonb;
  v_conflicts text[] := array[]::text[];
  v_set_clause text;
begin
  if not is_active_app_user() then
    raise exception 'permission denied: active app user required' using errcode = '42501';
  end if;
  if not (p_table = any (_smart_merge_allowed_tables())) then
    raise exception 'smart_merge_update: table % is not allowed', p_table using errcode = '42501';
  end if;

  execute format('select to_jsonb(t) from %I t where id = $1 for update', p_table)
    into v_current using p_id;

  if v_current is null then
    return jsonb_build_object('status', 'deleted');
  end if;

  for v_key in select jsonb_object_keys(p_new) loop
    if v_key = any (p_ignore) then
      continue;
    end if;

    if (p_new -> v_key) is not distinct from (p_original -> v_key) then
      continue;
    elsif (v_current -> v_key) is not distinct from (p_original -> v_key) then
      v_merged := v_merged || jsonb_build_object(v_key, p_new -> v_key);
    elsif (v_current -> v_key) is not distinct from (p_new -> v_key) then
      continue;
    else
      v_conflicts := array_append(v_conflicts, v_key);
    end if;
  end loop;

  if array_length(v_conflicts, 1) > 0 then
    return jsonb_build_object('status', 'conflict', 'conflicts', to_jsonb(v_conflicts), 'current', v_current);
  end if;

  if v_merged <> '{}'::jsonb then
    select string_agg(format('%I = ($1 ->> %L)::%s', c.column_name, c.column_name, c.udt_name), ', ')
    into v_set_clause
    from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = p_table
      and c.column_name in (select jsonb_object_keys(v_merged));

    if v_set_clause is not null then
      execute format('update %I set %s, version = coalesce(version,1) + 1 where id = $2', p_table, v_set_clause)
        using v_merged, p_id;
    end if;
  end if;

  execute format('select to_jsonb(t) from %I t where id = $1', p_table) into v_current using p_id;
  return jsonb_build_object('status', 'ok', 'current', v_current);
end;
$function$;

alter function _smart_merge_allowed_line_tables() set search_path = public;
