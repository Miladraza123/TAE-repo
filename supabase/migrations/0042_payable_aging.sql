-- ==========================================================
-- payable_aging(): what we owe each supplier, bill by bill, with due
-- dates — the mirror of receivable_aging() for the Payments Due screen.
--
-- Per supplier (kind supplier/both): the "pool" is everything already paid
-- to them that is not tied to a bill — Daily Ledger cash paid TO them
-- (c_amt with c_party) plus an opening balance on the Dr side (an advance).
-- Charges are an opening Cr balance and each purchase bill (less what was
-- paid on the bill itself), oldest first; the pool settles them FIFO.
-- Due date = the bill's due_date, else bill date + the party's credit days.
-- Whatever pool is left is an advance we gave them.
-- ==========================================================
create or replace function payable_aging(p_as_of date default current_date)
returns table(party_id uuid, party_name text, doc_kind text, doc_no text, doc_id uuid, doc_date date, due_date date,
              original_amount numeric, applied_amount numeric, outstanding numeric, days_overdue integer, bucket text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p record;
  c record;
  v_pool numeric;
  v_remaining numeric;
  v_from_pool numeric;
  v_outstanding numeric;
  v_days integer;
  v_bucket text;
begin
  if not (is_app_admin() or has_perm('reports_view')) then
    raise exception 'permission denied: reports_view required' using errcode = '42501';
  end if;

  for p in select * from parties where kind in ('supplier','both') and deleted_at is null loop
    v_pool := 0;

    select v_pool + coalesce(sum(sr2.c_amt), 0) into v_pool
      from sheets s join sheet_rows sr2 on sr2.sheet_id = s.id
      where s.deleted_at is null and s.sheet_date <= p_as_of and sr2.c_party = p.id;

    if p.opening_side = 'dr' and coalesce(p.opening, 0) > 0 then
      v_pool := v_pool + p.opening;
    end if;

    for c in (
      select * from (
        select 0 as ord, p.opening_date as doc_date, p.opening_date as due_date,
               'opening'::text as doc_kind, 'Opening balance'::text as doc_no, null::uuid as doc_id,
               p.opening as amount, 0::numeric as direct
        where p.opening_side = 'cr' and coalesce(p.opening, 0) > 0

        union all
        select 1, v.vdate, coalesce(v.due_date, v.vdate + (coalesce(p.credit_days, 0) || ' days')::interval)::date,
               'purchase', v.vno, v.id, v.grand_total, v.paid
        from vouchers v where v.party_id = p.id and v.vtype = 'purchase' and v.deleted_at is null and v.vdate <= p_as_of
      ) charges
      order by ord, doc_date, doc_id
    ) loop
      v_remaining := c.amount - c.direct;

      if v_remaining > 0.004 then
        v_from_pool := least(v_remaining, greatest(v_pool, 0));
        v_pool := v_pool - v_from_pool;
        v_outstanding := v_remaining - v_from_pool;
      else
        if v_remaining < -0.004 then
          v_pool := v_pool + (-v_remaining);
        end if;
        v_outstanding := 0;
      end if;

      if v_outstanding > 0.004 then
        if c.due_date is null or c.due_date::date >= p_as_of then
          v_bucket := 'notdue'; v_days := 0;
        else
          v_days := p_as_of - c.due_date::date;
          v_bucket := case when v_days <= 30 then 'b0' when v_days <= 60 then 'b30' when v_days <= 90 then 'b60' else 'b90' end;
        end if;

        party_id := p.id; party_name := p.name; doc_kind := c.doc_kind; doc_no := c.doc_no;
        doc_id := c.doc_id; doc_date := c.doc_date; due_date := c.due_date::date;
        original_amount := c.amount; applied_amount := c.amount - v_outstanding;
        outstanding := v_outstanding; days_overdue := v_days; bucket := v_bucket;
        return next;
      end if;
    end loop;

    if v_pool > 0.004 then
      party_id := p.id; party_name := p.name;
      doc_kind := 'advance'; doc_no := 'Advance paid to supplier';
      doc_id := null; doc_date := p_as_of; due_date := null;
      original_amount := v_pool; applied_amount := 0; outstanding := v_pool; days_overdue := 0;
      bucket := 'advance';
      return next;
    end if;
  end loop;
end;
$$;
grant execute on function payable_aging(date) to authenticated;
