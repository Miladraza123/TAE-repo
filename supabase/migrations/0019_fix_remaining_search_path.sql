-- Cosmetic hardening: set search_path on the last few flagged functions.
create or replace function _smart_merge_allowed_tables()
returns text[] language sql immutable set search_path = public as $$
  select array[
    'companies','warehouses','parties','item_units','items','services','party_kinds',
    'vouchers','sales_returns','quotations','purchase_orders',
    'service_invoices','service_quotations','stock_transfers',
    'recurring_service_templates'
  ];
$$;

create or replace function _smart_merge_allowed_line_tables()
returns text[] language sql immutable set search_path = public as $$
  select array[
    'voucher_lines','sales_return_lines','quotation_lines','po_lines',
    'service_invoice_lines','service_quotation_lines','stock_transfer_lines'
  ];
$$;

create or replace function next_recurring_date(p_from date, p_freq text, p_n integer default null)
returns date language plpgsql immutable set search_path = public as $$
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
