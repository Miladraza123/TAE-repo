-- ==========================================================
-- Fix: check_period_lock_vouchers() did `return new;` at every exit point,
-- including for DELETE operations — but NEW is undefined in a DELETE
-- trigger, so Postgres silently treated it as NULL, which cancels a BEFORE
-- trigger's operation with no error. Every hard delete on vouchers has
-- been silently no-op'ing since migration 0006. Must return OLD for
-- DELETE, NEW for INSERT/UPDATE.
-- Caught by testing cleanup deletes against test data and finding rows
-- that should have been removed were still present.
-- ==========================================================

create or replace function check_period_lock_vouchers()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_lock date;
begin
  if coalesce(current_setting('app.system_write', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  select locked_before into v_lock from period_lock where id = 1;
  if v_lock is null then
    return coalesce(new, old);
  end if;

  if tg_op = 'INSERT' and new.vdate < v_lock then
    raise exception 'Cannot create a voucher dated before the locked period (%).', v_lock
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' and old.vdate < v_lock then
    if (old.vno, old.vtype, old.vdate, old.due_date, old.party_id, old.company_id,
        old.narration, old.tax_on, old.sub_total, old.discount, old.tax_total,
        old.grand_total, old.paid, old.loading_on, old.loading_amt, old.cartage_on,
        old.cartage_amt, old.cutting_on, old.cutting_amt)
       is distinct from
       (new.vno, new.vtype, new.vdate, new.due_date, new.party_id, new.company_id,
        new.narration, new.tax_on, new.sub_total, new.discount, new.tax_total,
        new.grand_total, new.paid, new.loading_on, new.loading_amt, new.cartage_on,
        new.cartage_amt, new.cutting_on, new.cutting_amt)
    then
      raise exception 'This voucher is dated before the locked period (%) and cannot be edited.', v_lock
        using errcode = '23514';
    end if;
  end if;

  if tg_op = 'DELETE' and old.vdate < v_lock then
    raise exception 'Cannot permanently delete a voucher dated before the locked period (%).', v_lock
      using errcode = '23514';
  end if;

  return coalesce(new, old);
end;
$$;
