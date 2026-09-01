-- Store the company's merchant settlement earning separately from provider commission.
alter table public.ledger_entries
  add column if not exists merchant_commission_rate numeric(8,4) default 4.5,
  add column if not exists merchant_commission_inr numeric(14,2) default 0;

alter table public.ledger_entries
  drop constraint if exists ledger_entries_merchant_commission_rate_check;

alter table public.ledger_entries
  add constraint ledger_entries_merchant_commission_rate_check
  check (merchant_commission_rate is null or (merchant_commission_rate >= 0 and merchant_commission_rate <= 100));
