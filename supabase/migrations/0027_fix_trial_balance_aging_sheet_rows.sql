-- ==========================================================
-- Fix trial_balance()/receivable_aging(): both still queried the old
-- `sheets.rows` JSONB blob (dropped in 0025 when Daily Ledger moved to the
-- sheet_rows child table for row-level merge). This broke both reports and
-- aging_reconcile() (which calls them) with "column s.rows does not exist".
--
-- Pure column-reference fix — the amount/party pairing is reproduced exactly
-- as it was against the old JSONB shape (documented in 0025):
--   old index 0 -> d_amt, 2 -> c_amt, 6 -> d_party, 7 -> c_party
-- No change to the accounting calculation itself.
-- ==========================================================

create or replace function trial_balance(p_as_of date default current_date)
returns table(party_id uuid, party_name text, side text, balance numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (is_app_admin() or has_perm('reports_view')) then
    raise exception 'permission denied: reports_view required' using errcode = '42501';
  end if;
  return query
  with net as (
    select p.id as party_id, p.name as party_name,
      round(
        (case when p.opening_side = 'dr' then p.opening else -p.opening end)
        + coalesce((select sum(v.grand_total - v.paid) from vouchers v
                    where v.party_id = p.id and v.vtype = 'sale' and v.deleted_at is null and v.vdate <= p_as_of), 0)
        - coalesce((select sum(v.grand_total - v.paid) from vouchers v
                    where v.party_id = p.id and v.vtype = 'purchase' and v.deleted_at is null and v.vdate <= p_as_of), 0)
        - coalesce((select sum(sr.grand_total) from sales_returns sr
                    where sr.party_id = p.id and sr.deleted_at is null and sr.rdate <= p_as_of), 0)
        + coalesce((select sum(si.grand_total - si.paid) from service_invoices si
                    where si.party_id = p.id and si.status <> 'cancelled' and si.deleted_at is null and si.sidate <= p_as_of), 0)
        - coalesce((select sum(sr2.c_amt) from sheets s join sheet_rows sr2 on sr2.sheet_id = s.id
                    where s.deleted_at is null and s.sheet_date <= p_as_of and sr2.d_party = p.id), 0)
        + coalesce((select sum(sr2.d_amt) from sheets s join sheet_rows sr2 on sr2.sheet_id = s.id
                    where s.deleted_at is null and s.sheet_date <= p_as_of and sr2.c_party = p.id), 0)
      , 2) as net_bal
    from parties p
    where p.kind in ('customer', 'supplier', 'both') and p.deleted_at is null
  )
  select net.party_id, net.party_name, case when net_bal >= 0 then 'dr' else 'cr' end, abs(net_bal)
  from net where net_bal <> 0
  order by net.party_name;
end;
$$;

-- ----------------------------------------------------------
-- receivable_aging(as_of) — FIFO charge/pool allocation (§20's exact algorithm)
-- ----------------------------------------------------------
create or replace function receivable_aging(p_as_of date default current_date)
returns table(
  party_id uuid, party_name text, doc_kind text, doc_no text, doc_id uuid,
  doc_date date, due_date date, original_amount numeric, applied_amount numeric,
  outstanding numeric, days_overdue integer, bucket text
)
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

  for p in select * from parties where kind in ('customer','supplier','both') and deleted_at is null loop
    v_pool := 0;

    select v_pool + coalesce(sum(sr2.c_amt), 0) into v_pool
      from sheets s join sheet_rows sr2 on sr2.sheet_id = s.id
      where s.deleted_at is null and s.sheet_date <= p_as_of and sr2.d_party = p.id;

    select v_pool + coalesce(sum(v.grand_total), 0) into v_pool
      from vouchers v where v.party_id = p.id and v.vtype = 'purchase' and v.deleted_at is null and v.vdate <= p_as_of;

    select v_pool + coalesce(sum(sr.grand_total), 0) into v_pool
      from sales_returns sr where sr.party_id = p.id and sr.sale_id is null and sr.deleted_at is null and sr.rdate <= p_as_of;

    if p.opening_side <> 'dr' and coalesce(p.opening, 0) > 0 then
      v_pool := v_pool + p.opening;
    end if;

    -- Charges, chronological (opening first), each with its direct-applied amount.
    for c in (
      select * from (
        select 0 as ord, p.opening_date as doc_date, p.opening_date as due_date,
               'opening'::text as doc_kind, 'Opening balance'::text as doc_no, null::uuid as doc_id,
               p.opening as amount, 0::numeric as direct
        where p.opening_side = 'dr' and coalesce(p.opening, 0) > 0

        union all
        select 1, v.vdate, coalesce(v.due_date, v.vdate + (p.credit_days || ' days')::interval), 'sale', v.vno, v.id,
               v.grand_total,
               v.paid + coalesce((select sum(sr.grand_total) from sales_returns sr
                                   where sr.sale_id = v.id and sr.deleted_at is null and sr.rdate <= p_as_of), 0)
        from vouchers v where v.party_id = p.id and v.vtype = 'sale' and v.deleted_at is null and v.vdate <= p_as_of

        union all
        select 1, si.sidate, coalesce(si.due_date, si.sidate + (p.credit_days || ' days')::interval), 'service_invoice', si.sino, si.id,
               si.grand_total, si.paid
        from service_invoices si where si.party_id = p.id and si.status <> 'cancelled' and si.deleted_at is null and si.sidate <= p_as_of

        union all
        select 1, v.vdate, v.vdate, 'purchase_paid', v.vno, v.id, v.paid, v.paid
        from vouchers v where v.party_id = p.id and v.vtype = 'purchase' and v.deleted_at is null
          and v.vdate <= p_as_of and v.paid > 0

        union all
        select 1, s.sheet_date, s.sheet_date, 'cash_paid', 'Cash paid'::text, null::uuid,
               sr2.d_amt, 0::numeric
        from sheets s join sheet_rows sr2 on sr2.sheet_id = s.id
        where s.deleted_at is null and s.sheet_date <= p_as_of and sr2.c_party = p.id
      ) charges
      order by ord, doc_date, doc_id
    ) loop
      v_remaining := c.amount - c.direct;

      if v_remaining > 0.004 then
        v_from_pool := least(v_remaining, greatest(v_pool, 0));
        v_pool := v_pool - v_from_pool;
        v_outstanding := v_remaining - v_from_pool;
      else
        v_outstanding := v_remaining;
        if v_outstanding < -0.004 then
          v_pool := v_pool + (-v_outstanding); -- overpayment pushed back into the pool
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
      doc_kind := case when p.kind = 'supplier' then 'payable' else 'advance' end;
      doc_no := case when p.kind = 'supplier' then 'Payable to supplier' else 'Customer advance' end;
      doc_id := null; doc_date := p_as_of; due_date := null;
      original_amount := v_pool; applied_amount := 0; outstanding := v_pool; days_overdue := 0;
      bucket := case when p.kind = 'supplier' then 'payable' else 'advance' end;
      return next;
    end if;
  end loop;
end;
$$;
