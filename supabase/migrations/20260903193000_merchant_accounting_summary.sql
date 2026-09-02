create or replace function public.merchant_accounting_summary()
returns table(
  total_collection_inr numeric,
  frozen_inr numeric,
  merchant_ledger_settled_inr numeric,
  manual_settled_inr numeric,
  manual_settled_usdt numeric,
  merchant_commission_inr numeric,
  charges_inr numeric,
  reserved_inr numeric,
  available_inr numeric
)
language sql stable security definer set search_path=public,private,pg_temp as $$
  with v as (
    select
      coalesce((select sum(le.amount_inr) from public.ledger_entries le where le.entry_type='collection' and le.status='posted'),0) as total_collection_inr,
      coalesce((select sum(le.amount_inr) from public.ledger_entries le where le.entry_type='frozen' and le.status='active'),0) as frozen_inr,
      coalesce((select sum(le.amount_usdt*le.rate) from public.ledger_entries le where le.entry_type='merchant_usdt' and le.status='posted'),0) as merchant_ledger_settled_inr,
      coalesce((select sum(ms.amount_inr) from public.merchant_settlements ms),0) as manual_settled_inr,
      coalesce((select sum(ms.amount_usdt) from public.merchant_settlements ms),0) as manual_settled_usdt,
      coalesce((select sum(le.merchant_commission_inr) from public.ledger_entries le where le.entry_type='merchant_usdt' and le.status='posted'),0)
        + coalesce((select sum(ms.commission_inr) from public.merchant_settlements ms),0) as merchant_commission_inr,
      coalesce((select sum(mc.amount_inr) from public.merchant_charges mc where mc.status='active'),0) as charges_inr,
      coalesce((select sum(wr.amount_inr) from public.withdrawal_requests wr where wr.requester_type='merchant' and wr.status in('pending','paid')),0) as reserved_inr
  )
  select
    total_collection_inr,
    frozen_inr,
    merchant_ledger_settled_inr,
    manual_settled_inr,
    manual_settled_usdt,
    merchant_commission_inr,
    charges_inr,
    reserved_inr,
    greatest(0,total_collection_inr-frozen_inr-merchant_ledger_settled_inr-manual_settled_inr-reserved_inr-charges_inr) as available_inr
  from v;
$$;

grant execute on function public.merchant_accounting_summary() to authenticated,service_role;
