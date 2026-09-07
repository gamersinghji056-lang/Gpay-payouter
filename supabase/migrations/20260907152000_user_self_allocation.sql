-- SettleFlow Deposit User self-allocation
-- Forward-only targeted migration.
-- Does not modify historical tables or reset data.

create or replace function public.allocate_upi_capacity_for_provider(
  p_provider_id uuid,
  p_upi_account_id uuid,
  p_allocated_limit_inr numeric
)
returns public.provider_upi_accounts
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider public.providers;
  v_account public.provider_upi_accounts;
  v_result public.provider_upi_accounts;
  v_used numeric := 0;
  v_funded_pool numeric := 0;
  v_other_allocated numeric := 0;
begin
  if p_provider_id is null then
    raise exception 'provider is required';
  end if;

  if p_upi_account_id is null then
    raise exception 'UPI account is required';
  end if;

  if p_allocated_limit_inr is null or p_allocated_limit_inr < 0 then
    raise exception 'allocation must be non-negative';
  end if;

  -- Lock the provider first so concurrent allocation requests for
  -- the same Deposit user serialize safely.
  select *
  into v_provider
  from public.providers
  where id = p_provider_id
    and status <> 'deleted'
  for update;

  if not found then
    raise exception 'provider not found';
  end if;

  if v_provider.funding_model <> 'deposit' then
    raise exception 'allocation applies only to Deposit Based users';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_provider_id::text, 0)
  );

  select *
  into v_account
  from public.provider_upi_accounts
  where id = p_upi_account_id
    and provider_id = p_provider_id
    and status <> 'deleted'
  for update;

  if not found then
    raise exception 'UPI account does not belong to this provider';
  end if;

  -- Collection already consumed by this UPI cannot be moved away.
  select coalesce(sum(le.amount_inr), 0)
  into v_used
  from public.ledger_entries le
  where le.provider_id = p_provider_id
    and le.upi_account_id = p_upi_account_id
    and le.entry_type = 'collection'
    and le.status = 'posted'
    and not le.is_voided;

  if p_allocated_limit_inr < v_used then
    raise exception
      'allocation cannot be below consumed collection (% INR)',
      v_used;
  end if;

  -- Deposit capacity consists of:
  -- 1. confirmed blockchain deposits at their stored INR value
  -- 2. valid manual user_usdt credits at their stored historical
  --    credit_rate/rate.
  select
    coalesce((
      select sum(dr.inr_value)
      from public.deposit_requests dr
      where dr.provider_id = p_provider_id
        and dr.status = 'confirmed'
    ), 0)
    +
    coalesce((
      select sum(
        le.amount_usdt * coalesce(le.credit_rate, le.rate)
      )
      from public.ledger_entries le
      where le.provider_id = p_provider_id
        and le.entry_type = 'user_usdt'
        and le.status = 'posted'
        and not le.is_voided
    ), 0)
  into v_funded_pool;

  select coalesce(sum(a.allocated_limit_inr), 0)
  into v_other_allocated
  from public.provider_upi_accounts a
  where a.provider_id = p_provider_id
    and a.id <> p_upi_account_id
    and a.status <> 'deleted';

  if v_other_allocated + p_allocated_limit_inr > v_funded_pool + 0.0001 then
    raise exception
      'UPI allocations exceed funded Deposit capacity. Funded: %, allocated to other UPIs: %, requested: %',
      v_funded_pool,
      v_other_allocated,
      p_allocated_limit_inr;
  end if;

  update public.provider_upi_accounts
  set
    allocated_limit_inr = p_allocated_limit_inr,
    updated_at = now()
  where id = p_upi_account_id
    and provider_id = p_provider_id
  returning *
  into v_result;

  insert into public.audit_logs(
    action,
    entity_type,
    entity_id,
    new_data
  )
  values (
    'deposit_user_upi_allocation_changed',
    'provider_upi_account',
    p_upi_account_id::text,
    jsonb_build_object(
      'provider_id', p_provider_id,
      'old_allocation_inr', v_account.allocated_limit_inr,
      'new_allocation_inr', p_allocated_limit_inr,
      'consumed_collection_inr', v_used,
      'total_funded_capacity_inr', v_funded_pool,
      'other_upi_allocations_inr', v_other_allocated,
      'source', 'user_self_service'
    )
  );

  return v_result;
end;
$$;

revoke all
on function public.allocate_upi_capacity_for_provider(uuid, uuid, numeric)
from public, anon, authenticated;

grant execute
on function public.allocate_upi_capacity_for_provider(uuid, uuid, numeric)
to service_role;
