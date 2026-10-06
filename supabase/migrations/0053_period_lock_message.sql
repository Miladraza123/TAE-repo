-- ==========================================================
-- Same Period Lock wording everywhere: the line-merge check said "dated
-- before the locked period (2026-10-06)", while the screen now says
-- "locked up to and including 05 Oct 2026".
-- ==========================================================
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
      raise exception 'Period Lock: entries up to % are locked — this document''s lines can''t be changed.', to_char(v_lock - 1, 'DD Mon YYYY')
        using errcode = '23514';
    end if;
  end if;
end;
$$;
