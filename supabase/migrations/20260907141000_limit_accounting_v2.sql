-- SettleFlow Limit + Accounting V2
-- Forward-only migration.
-- Historical migrations are intentionally untouched.

create or replace function public.accounting_for_provider(p_provider_id uuid)
returns table (
  collection_inr numeric,
  successful_withdrawal_inr numeric,
  user_usdt_inr numeric,
  merchant_settled_inr numeric,
  frozen_inr numeric,
  confirmed_deposit_inr numeric,
  collection_capacity_inr numeric,
  commission_earned_inr numeric
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  with p as (
    select *
    from public.providers
    where id = p_provider_id
  ),
  u as (
    select
      coalesce(
        nullif(
          sum(configured_limit_inr)
          filter (where status <> 'deleted'),
          0
        ),
        (select commission_limit_inr from p),
        0
      ) as commission_limit
    from public.provider_upi_accounts
    where provider_id = p_provider_id
  ),
  l as (
    select
      coalesce(sum(amount_inr) filter (
        where entry_type = 'collection'
          and status = 'posted'
          and not is_voided
      ), 0) as collection,

      coalesce(sum(amount_inr) filter (
        where entry_type = 'inr_received'
          and status = 'posted'
          and not is_voided
      ), 0) as withdrawal,

      coalesce(sum(
        amount_usdt * coalesce(credit_rate, rate)
      ) filter (
        where entry_type = 'user_usdt'
          and status = 'posted'
          and not is_voided
          and (select funding_model from p) = 'deposit'
      ), 0) as manual_deposit,

      coalesce(sum(
        amount_usdt * rate
      ) filter (
        where entry_type = 'user_usdt'
          and status = 'posted'
          and not is_voided
          and (select funding_model from p) = 'commission'
      ), 0) as user_usdt,

      coalesce(sum(
        amount_usdt * rate
      ) filter (
        where entry_type = 'merchant_usdt'
          and status = 'posted'
          and not is_voided
      ), 0) as merchant,

      coalesce(sum(amount_inr) filter (
        where entry_type = 'frozen'
          and status = 'active'
          and not is_voided
      ), 0) as frozen

    from public.ledger_entries
    where provider_id = p_provider_id
  ),
  d as (
    select
      coalesce(sum(inr_value) filter (
        where status = 'confirmed'
      ), 0) as deposit
    from public.deposit_requests
    where provider_id = p_provider_id
  ),
  w as (
    select
      coalesce(sum(amount_inr) filter (
        where requester_type = 'provider'
          and provider_id = p_provider_id
          and status in ('pending', 'paid')
          and not is_voided
      ), 0) as paid_or_reserved
    from public.withdrawal_requests
  )
  select
    l.collection,
    l.withdrawal,
    l.user_usdt,
    l.merchant,
    l.frozen,
    d.deposit + l.manual_deposit,

    case
      when p.funding_model = 'deposit'
        then greatest(
          0,
          d.deposit + l.manual_deposit - l.collection
        )
      else least(
        u.commission_limit,
        greatest(
          0,
          u.commission_limit - (l.collection - l.withdrawal)
        )
      )
    end,

    case
      when p.funding_model = 'commission'
        then greatest(
          0,
          (
            l.withdrawal *
            (
              select commission_rate_pct / 100
              from public.app_settings
              where id
            )
          ) - w.paid_or_reserved
        )
      else 0
    end
  from p, u, l, d, w;
$$;

grant execute on function public.accounting_for_provider(uuid)
to authenticated, service_role;


create or replace function public.accounting_for_upi(p_upi_account_id uuid)
returns table (
  provider_id uuid,
  funding_model text,
  total_collection_inr numeric,
  successful_withdrawal_inr numeric,
  configured_limit_inr numeric,
  allocated_limit_inr numeric,
  available_limit_inr numeric
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  with a as (
    select
      ua.*,
      p.funding_model
    from public.provider_upi_accounts ua
    join public.providers p
      on p.id = ua.provider_id
    where ua.id = p_upi_account_id
  ),
  l as (
    select
      coalesce(sum(le.amount_inr) filter (
        where le.entry_type = 'collection'
          and le.status = 'posted'
          and not le.is_voided
      ), 0) as collection,

      coalesce(sum(le.amount_inr) filter (
        where le.entry_type = 'inr_received'
          and le.status = 'posted'
          and not le.is_voided
      ), 0) as withdrawal

    from public.ledger_entries le
    where le.upi_account_id = p_upi_account_id
  )
  select
    a.provider_id,
    a.funding_model,
    l.collection,
    l.withdrawal,
    a.configured_limit_inr,
    a.allocated_limit_inr,

    case
      when a.funding_model = 'deposit'
        then greatest(
          0,
          a.allocated_limit_inr - l.collection
        )
      else least(
        a.configured_limit_inr,
        greatest(
          0,
          a.configured_limit_inr
          - l.collection
          + l.withdrawal
        )
      )
    end

  from a, l;
$$;

grant execute on function public.accounting_for_upi(uuid)
to authenticated, service_role;


create or replace function public.allocate_upi_capacity(
  p_actor_id uuid,
  p_upi_account_id uuid,
  p_allocated_limit_inr numeric
)
returns public.provider_upi_accounts
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  a public.provider_upi_accounts;
  p public.providers;
  used numeric := 0;
  pool numeric := 0;
  allocated_other numeric := 0;
  result public.provider_upi_accounts;
begin
  if p_allocated_limit_inr is null
     or p_allocated_limit_inr < 0 then
    raise exception 'allocation must be non-negative';
  end if;

  select *
  into a
  from public.provider_upi_accounts
  where id = p_upi_account_id
    and status <> 'deleted'
  for update;

  if not found then
    raise exception 'UPI account not found';
  end if;

  select *
  into p
  from public.providers
  where id = a.provider_id
  for update;

  if not found then
    raise exception 'provider not found';
  end if;

  if p.funding_model <> 'deposit' then
    raise exception 'allocation applies only to Deposit Based users';
  end if;

  if not (
    private.current_role() in ('admin', 'operator')
    or p.created_by = p_actor_id
  ) then
    raise exception 'not authorized';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p.id::text, 0)
  );

  select coalesce(sum(le.amount_inr), 0)
  into used
  from public.ledger_entries le
  where le.upi_account_id = a.id
    and le.entry_type = 'collection'
    and le.status = 'posted'
    and not le.is_voided;

  if p_allocated_limit_inr < used then
    raise exception 'allocation cannot be below consumed collection';
  end if;

  select
    coalesce((
      select sum(dr.inr_value)
      from public.deposit_requests dr
      where dr.provider_id = p.id
        and dr.status = 'confirmed'
    ), 0)
    +
    coalesce((
      select sum(
        le.amount_usdt *
        coalesce(le.credit_rate, le.rate)
      )
      from public.ledger_entries le
      where le.provider_id = p.id
        and le.entry_type = 'user_usdt'
        and le.status = 'posted'
        and not le.is_voided
    ), 0)
  into pool;

  select coalesce(sum(x.allocated_limit_inr), 0)
  into allocated_other
  from public.provider_upi_accounts x
  where x.provider_id = p.id
    and x.id <> a.id
    and x.status <> 'deleted';

  if allocated_other + p_allocated_limit_inr > pool then
    raise exception 'UPI allocations exceed funded deposit credit';
  end if;

  update public.provider_upi_accounts
  set
    allocated_limit_inr = p_allocated_limit_inr,
    updated_at = now()
  where id = a.id
  returning *
  into result;

  insert into public.audit_logs(
    actor_id,
    action,
    entity_type,
    entity_id,
    new_data
  )
  values (
    p_actor_id,
    'upi_capacity_allocated',
    'provider_upi_account',
    a.id::text,
    jsonb_build_object(
      'previous_allocated_limit_inr',
      a.allocated_limit_inr,
      'allocated_limit_inr',
      p_allocated_limit_inr,
      'consumed_collection_inr',
      used,
      'total_funded_credit_inr',
      pool,
      'allocated_other_upis_inr',
      allocated_other
    )
  );

  return result;
end;
$$;

revoke all on function public.allocate_upi_capacity(uuid,uuid,numeric)
from public, anon, authenticated;

grant execute on function public.allocate_upi_capacity(uuid,uuid,numeric)
to service_role;


create or replace function public.merchant_available_balance_inr()
returns numeric
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  select greatest(
    0,

    coalesce((
      select sum(le.amount_inr)
      from public.ledger_entries le
      where le.entry_type = 'collection'
        and le.status = 'posted'
        and not le.is_voided
    ), 0)

    - coalesce((
      select sum(le.amount_inr)
      from public.ledger_entries le
      where le.entry_type = 'frozen'
        and le.status = 'active'
        and not le.is_voided
    ), 0)

    - coalesce((
      select sum(le.amount_usdt * le.rate)
      from public.ledger_entries le
      where le.entry_type = 'merchant_usdt'
        and le.status = 'posted'
        and not le.is_voided
    ), 0)

    - coalesce((
      select sum(ms.amount_inr)
      from public.merchant_settlements ms
    ), 0)

    - coalesce((
      select sum(wr.amount_inr)
      from public.withdrawal_requests wr
      where wr.requester_type = 'merchant'
        and wr.status = 'paid'
        and not wr.is_voided
    ), 0)

    - coalesce((
      select sum(wr.amount_inr)
      from public.withdrawal_requests wr
      where wr.requester_type = 'merchant'
        and wr.status = 'pending'
        and not wr.is_voided
    ), 0)

    - coalesce((
      select sum(mc.amount_inr)
      from public.merchant_charges mc
      where mc.status = 'active'
    ), 0)
  );
$$;

grant execute on function public.merchant_available_balance_inr()
to authenticated, service_role;


create or replace function public.merchant_accounting_summary()
returns table (
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
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with v as (
    select

      coalesce((
        select sum(le.amount_inr)
        from public.ledger_entries le
        where le.entry_type = 'collection'
          and le.status = 'posted'
          and not le.is_voided
      ), 0) as total_collection_inr,

      coalesce((
        select sum(le.amount_inr)
        from public.ledger_entries le
        where le.entry_type = 'frozen'
          and le.status = 'active'
          and not le.is_voided
      ), 0) as frozen_inr,

      coalesce((
        select sum(le.amount_usdt * le.rate)
        from public.ledger_entries le
        where le.entry_type = 'merchant_usdt'
          and le.status = 'posted'
          and not le.is_voided
      ), 0) as merchant_ledger_settled_inr,

      coalesce((
        select sum(ms.amount_inr)
        from public.merchant_settlements ms
      ), 0) as manual_settled_inr,

      coalesce((
        select sum(ms.amount_usdt)
        from public.merchant_settlements ms
      ), 0) as manual_settled_usdt,

      coalesce((
        select sum(le.merchant_commission_inr)
        from public.ledger_entries le
        where le.entry_type = 'merchant_usdt'
          and le.status = 'posted'
          and not le.is_voided
      ), 0)
      +
      coalesce((
        select sum(ms.commission_inr)
        from public.merchant_settlements ms
      ), 0) as merchant_commission_inr,

      coalesce((
        select sum(mc.amount_inr)
        from public.merchant_charges mc
        where mc.status = 'active'
      ), 0) as charges_inr,

      coalesce((
        select sum(wr.amount_inr)
        from public.withdrawal_requests wr
        where wr.requester_type = 'merchant'
          and wr.status = 'pending'
          and not wr.is_voided
      ), 0) as reserved_inr,

      coalesce((
        select sum(wr.amount_inr)
        from public.withdrawal_requests wr
        where wr.requester_type = 'merchant'
          and wr.status = 'paid'
          and not wr.is_voided
      ), 0) as paid_withdrawal_inr
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

    greatest(
      0,
      total_collection_inr
      - frozen_inr
      - merchant_ledger_settled_inr
      - manual_settled_inr
      - paid_withdrawal_inr
      - reserved_inr
      - charges_inr
    ) as available_inr

  from v;
$$;

grant execute on function public.merchant_accounting_summary()
to authenticated, service_role;
