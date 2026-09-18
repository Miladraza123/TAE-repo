-- ==========================================================
-- smart_merge_lines currently discards its whole computed merge result
-- when ANY line conflicts, returning only {status:'conflict', conflicts,
-- current} — forcing every caller to redo 100% of the work even when only
-- one line out of many genuinely clashed. This is a purely additive,
-- backward-compatible change: the conflict response also carries
-- 'merged_lines', the exact same v_result the function already computes
-- (every line that merged cleanly, INCLUDING concurrently-added lines
-- from someone else) — v_result never includes the actually-conflicting
-- line(s), so it's immediately safe to combine with a per-conflict
-- resolution and pass straight to apply_merged_lines(). Existing callers
-- that don't read this key are unaffected.
-- ==========================================================

create or replace function smart_merge_lines(
  p_line_table     text,
  p_fk_col         text,
  p_fk_id          uuid,
  p_original_lines jsonb,
  p_new_lines      jsonb,
  p_ignore         text[] default array['id','created_at']
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
  if p_line_table <> any (_smart_merge_allowed_line_tables()) then
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
      v_result := v_result || jsonb_build_array(v_line); -- genuinely new line
      continue;
    end if;

    v_submitted_ids := array_append(v_submitted_ids, v_id);

    if not (v_id = any (coalesce(v_current_ids, array[]::uuid[]))) then
      continue; -- deleted by someone else concurrently — silently dropped
    end if;

    select l into v_cur_line from jsonb_array_elements(v_current_lines) l where (l->>'id')::uuid = v_id;

    if not (v_id = any (coalesce(v_original_ids, array[]::uuid[]))) then
      v_result := v_result || jsonb_build_array(v_cur_line); -- concurrently-added, keep server version
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

  -- Lines that exist in the current DB but the user's submission never
  -- mentioned at all AND weren't in their original snapshot: added
  -- concurrently by someone else, survive untouched.
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
$$;
