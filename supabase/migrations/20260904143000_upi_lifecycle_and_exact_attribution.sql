-- Forward-only UPI lifecycle and exact attribution hardening.
alter table public.provider_upi_accounts drop constraint if exists provider_upi_accounts_status_check;
alter table public.provider_upi_accounts add constraint provider_upi_accounts_status_check check (status in ('active','paused','archived','deleted'));

alter table public.provider_upi_accounts add column if not exists blocked_by_user boolean not null default false;
alter table public.provider_upi_accounts add column if not exists blocked_by_user_at timestamptz;
alter table public.provider_upi_accounts add column if not exists blocked_by_admin boolean not null default false;
alter table public.provider_upi_accounts add column if not exists blocked_by_admin_at timestamptz;
alter table public.provider_upi_accounts add column if not exists blocked_by_admin_by uuid references public.profiles(id);
alter table public.provider_upi_accounts add column if not exists admin_block_reason text;
alter table public.provider_upi_accounts add column if not exists archived_at timestamptz;
alter table public.provider_upi_accounts add column if not exists archived_by uuid references public.profiles(id);

create or replace function public.post_collection_by_share(
  p_share_link_id uuid,p_provider_id uuid,p_amount_inr numeric,p_bank_name text,
  p_account_number text,p_transaction_date date,p_note text default null,
  p_idempotency_key text default null,p_upi_account_id uuid default null
) returns public.ledger_entries
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.ledger_entries; a record; provider public.providers; account public.provider_upi_accounts;
begin
  if p_upi_account_id is null then raise exception 'UPI account is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_upi_account_id::text,0));
  if not exists(select 1 from public.share_links where id=p_share_link_id and scope='merchant' and is_active and (expires_at is null or expires_at>now())) then raise exception 'merchant share link is invalid or revoked'; end if;
  if p_idempotency_key is not null then select * into result from public.ledger_entries where idempotency_key=p_idempotency_key; if found then return result; end if; end if;
  select * into provider from public.providers where id=p_provider_id and is_active and status='active';
  if not found then raise exception 'active provider not found'; end if;
  select * into account from public.provider_upi_accounts where id=p_upi_account_id and provider_id=p_provider_id for update;
  if not found then raise exception 'UPI account is unavailable'; end if;
  if account.status <> 'active' or account.merchant_operational is not true or account.blocked_by_user or account.blocked_by_admin then raise exception 'UPI account is blocked'; end if;
  select * into a from public.accounting_for_upi(p_upi_account_id);
  if p_amount_inr is null or p_amount_inr<=0 then raise exception 'positive collection amount required'; end if;
  if provider.funding_model='commission' and coalesce(account.configured_limit_inr,0)<=0 then raise exception 'Collection limit not configured'; end if;
  if p_amount_inr > coalesce(a.available_limit_inr,0) then raise exception 'Collection exceeds available account limit.'; end if;
  insert into public.ledger_entries(provider_id,upi_account_id,entry_type,amount_inr,bank_name,account_number,transaction_date,note,status,idempotency_key)
  values(p_provider_id,p_upi_account_id,'collection',p_amount_inr,p_bank_name,p_account_number,p_transaction_date,p_note,'posted',p_idempotency_key) returning * into result;
  update public.share_links set last_accessed_at=now() where id=p_share_link_id;
  return result;
end; $$;
revoke all on function public.post_collection_by_share(uuid,uuid,numeric,text,text,date,text,text,uuid) from public,anon,authenticated;
grant execute on function public.post_collection_by_share(uuid,uuid,numeric,text,text,date,text,text,uuid) to service_role;

create or replace function public.post_ledger_entry(
  p_actor_id uuid, p_provider_id uuid, p_entry_type text, p_amount_inr numeric default null,
  p_amount_usdt numeric default null, p_rate numeric default null, p_bank_name text default null,
  p_account_number text default null, p_transaction_date date default current_date, p_reference_no text default null,
  p_note text default null, p_status text default 'posted', p_idempotency_key text default null,
  p_upi_account_id uuid default null
) returns public.ledger_entries
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.ledger_entries; a record; provider public.providers; account public.provider_upi_accounts; credit numeric; actor_role text;
begin
  perform private.require_staff(p_actor_id);
  select role into actor_role from public.profiles where id=p_actor_id;
  perform pg_advisory_xact_lock(hashtextextended(p_provider_id::text, 0));
  if p_idempotency_key is not null then
    select * into result from public.ledger_entries where idempotency_key=p_idempotency_key;
    if found then return result; end if;
  end if;
  select * into provider from public.providers where id=p_provider_id and is_active and status='active';
  if not found then raise exception 'active provider not found'; end if;
  if p_entry_type in ('collection','inr_received') and p_upi_account_id is null then raise exception 'UPI account is required'; end if;
  if p_upi_account_id is not null then
    select * into account from public.provider_upi_accounts where id=p_upi_account_id and provider_id=p_provider_id and status<>'deleted';
    if not found then raise exception 'UPI account does not belong to provider'; end if;
  end if;
  if p_entry_type not in ('collection','inr_received','user_usdt','merchant_usdt','frozen') then raise exception 'invalid ledger type'; end if;
  if p_entry_type in ('collection','inr_received','frozen') and coalesce(p_amount_inr,0) <= 0 then raise exception 'positive INR amount required'; end if;
  if p_entry_type in ('user_usdt','merchant_usdt') and (coalesce(p_amount_usdt,0) <= 0 or coalesce(p_rate,0) <= 0) then raise exception 'positive USDT and rate required'; end if;
  if p_entry_type='collection' and actor_role<>'admin' then
    if account.status <> 'active' or account.merchant_operational is not true or account.blocked_by_user or account.blocked_by_admin then raise exception 'UPI account is blocked'; end if;
    if provider.funding_model='commission' and coalesce(account.configured_limit_inr,0)<=0 then raise exception 'Collection limit not configured'; end if;
    select * into a from public.accounting_for_upi(p_upi_account_id);
    if p_amount_inr > a.available_limit_inr then raise exception 'collection exceeds available account limit'; end if;
  end if;
  if p_entry_type='user_usdt' and provider.funding_model='deposit' then
    select round(deposit_base_rate*(1+deposit_markup_pct/100),6) into credit from public.app_settings where id;
  end if;
  insert into public.ledger_entries(provider_id,upi_account_id,entry_type,amount_inr,amount_usdt,rate,bank_name,account_number,transaction_date,reference_no,note,status,created_by,idempotency_key,credit_rate,accounting_source)
  values (p_provider_id,p_upi_account_id,p_entry_type,p_amount_inr,p_amount_usdt,p_rate,p_bank_name,p_account_number,p_transaction_date,p_reference_no,p_note,p_status,p_actor_id,p_idempotency_key,credit,case when credit is null then 'legacy' else 'manual_usdt_from_user' end)
  returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data)
  values (p_actor_id,'ledger_entry_posted','ledger_entry',result.id::text,jsonb_build_object('provider_id',p_provider_id,'upi_account_id',p_upi_account_id,'entry_type',p_entry_type,'amount_inr',p_amount_inr,'amount_usdt',p_amount_usdt));
  return result;
end; $$;
revoke all on function public.post_ledger_entry(uuid,uuid,text,numeric,numeric,numeric,text,text,date,text,text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.post_ledger_entry(uuid,uuid,text,numeric,numeric,numeric,text,text,date,text,text,text,text,uuid) to service_role;
