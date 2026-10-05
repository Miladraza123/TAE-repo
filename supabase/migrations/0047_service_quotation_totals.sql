-- ==========================================================
-- Service Quotation totals. The app leaves service document totals to the
-- database (it never sends sub_total/tax_total/grand_total), but only
-- service_invoices had the recompute triggers — every service quotation
-- was saved with a 0 total and showed Rs 0 in its list. Same triggers as
-- service invoices, plus a one-time recompute of the existing rows.
-- ==========================================================
create or replace function recompute_service_quotation_totals(p_quotation_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_sub numeric; v_tax numeric; v_disc numeric; v_tax_on boolean;
begin
  select coalesce(sum(qty * rate), 0) into v_sub from service_quotation_lines where quotation_id = p_quotation_id;
  select tax_on, discount into v_tax_on, v_disc from service_quotations where id = p_quotation_id;
  if v_tax_on then
    select coalesce(sum(qty * rate * tax_pct / 100), 0) into v_tax from service_quotation_lines where quotation_id = p_quotation_id;
  else
    v_tax := 0;
  end if;
  perform set_config('app.system_write', 'on', true);
  update service_quotations
    set sub_total = v_sub, tax_total = v_tax, grand_total = v_sub - coalesce(v_disc, 0) + v_tax
    where id = p_quotation_id;
  perform set_config('app.system_write', 'off', true);
end; $$;

create or replace function trg_service_quotation_lines_totals()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  perform recompute_service_quotation_totals(coalesce(new.quotation_id, old.quotation_id));
  return coalesce(new, old);
end; $$;

create or replace function trg_service_quotation_header_totals()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return new;
  end if;
  if old.tax_on is distinct from new.tax_on or old.discount is distinct from new.discount then
    perform recompute_service_quotation_totals(new.id);
  end if;
  return new;
end; $$;

create or replace trigger service_quotation_lines_totals_after after insert or update or delete on service_quotation_lines
  for each row execute function trg_service_quotation_lines_totals();
create or replace trigger service_quotations_header_totals_after after update on service_quotations
  for each row execute function trg_service_quotation_header_totals();

do $$
declare r record;
begin
  for r in select id from service_quotations loop
    perform recompute_service_quotation_totals(r.id);
  end loop;
end $$;
