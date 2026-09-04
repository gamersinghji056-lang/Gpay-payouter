create or replace function public.accounting_for_provider(p_provider_id uuid)
returns table (collection_inr numeric, successful_withdrawal_inr numeric, user_usdt_inr numeric, merchant_settled_inr numeric, frozen_inr numeric, confirmed_deposit_inr numeric, collection_capacity_inr numeric, commission_earned_inr numeric)
language sql stable security invoker set search_path = public, pg_temp as $$
  with p as (select * from public.providers where id=p_provider_id),
  u as (
    select coalesce(nullif(sum(configured_limit_inr),0), (select commission_limit_inr from p), 0) commission_limit
    from public.provider_upi_accounts
    where provider_id=p_provider_id and status<>'deleted'
  ),
  l as (select coalesce(sum(amount_inr) filter (where entry_type='collection' and status='posted' and not is_voided),0) collection,
               coalesce(sum(amount_inr) filter (where entry_type='inr_received' and status='posted' and not is_voided),0) withdrawal,
               coalesce(sum(amount_usdt * coalesce(credit_rate,rate)) filter (where entry_type='user_usdt' and status='posted' and not is_voided and (select funding_model from p)='deposit'),0) manual_deposit,
               coalesce(sum(amount_usdt * rate) filter (where entry_type='user_usdt' and status='posted' and not is_voided and (select funding_model from p)='commission'),0) user_usdt,
               coalesce(sum(amount_usdt * rate) filter (where entry_type='merchant_usdt' and status='posted' and not is_voided),0) merchant,
               coalesce(sum(amount_inr) filter (where entry_type='frozen' and status='active' and not is_voided),0) frozen
        from public.ledger_entries where provider_id=p_provider_id),
  d as (select coalesce(sum(inr_value) filter (where status='confirmed'),0) deposit from public.deposit_requests where provider_id=p_provider_id),
  w as (select coalesce(sum(amount_inr) filter (where requester_type='provider' and provider_id=p_provider_id and status in ('pending','paid') and not is_voided),0) paid_or_reserved from public.withdrawal_requests)
  select l.collection,l.withdrawal,l.user_usdt,l.merchant,l.frozen,d.deposit+l.manual_deposit,
    case when p.funding_model='deposit' then greatest(0,d.deposit+l.manual_deposit-l.collection)
      else least(u.commission_limit,greatest(0,u.commission_limit-(l.collection-l.withdrawal))) end,
    case when p.funding_model='commission' then greatest(0,l.withdrawal*(select commission_rate_pct/100 from public.app_settings where id)-w.paid_or_reserved) else 0 end
  from p,u,l,d,w;
$$;
grant execute on function public.accounting_for_provider(uuid) to authenticated, service_role;

create or replace function public.accounting_for_upi(p_upi_account_id uuid)
returns table(provider_id uuid, funding_model text, total_collection_inr numeric, successful_withdrawal_inr numeric,
  configured_limit_inr numeric, allocated_limit_inr numeric, available_limit_inr numeric)
language sql stable security invoker set search_path=public,pg_temp as $$
  with a as (select ua.*, p.funding_model from public.provider_upi_accounts ua join public.providers p on p.id=ua.provider_id where ua.id=p_upi_account_id),
  l as (select coalesce(sum(le.amount_inr) filter(where le.entry_type='collection' and le.status='posted' and not le.is_voided),0) collection,
               coalesce(sum(le.amount_inr) filter(where le.entry_type='inr_received' and le.status='posted' and not le.is_voided),0) withdrawal
        from public.ledger_entries le where le.upi_account_id=p_upi_account_id)
  select a.provider_id,a.funding_model,l.collection,l.withdrawal,a.configured_limit_inr,a.allocated_limit_inr,
    case when a.funding_model='deposit' then greatest(0,a.allocated_limit_inr-l.collection)
         else least(a.configured_limit_inr,greatest(0,a.configured_limit_inr-(l.collection-l.withdrawal))) end
  from a,l;
$$;
grant execute on function public.accounting_for_upi(uuid) to authenticated,service_role;

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
  if p_upi_account_id is not null then
    select * into account from public.provider_upi_accounts where id=p_upi_account_id and provider_id=p_provider_id and status<>'deleted';
    if not found then raise exception 'UPI account does not belong to provider'; end if;
  end if;
  if p_entry_type not in ('collection','inr_received','user_usdt','merchant_usdt','frozen') then raise exception 'invalid ledger type'; end if;
  if p_entry_type in ('collection','inr_received','frozen') and coalesce(p_amount_inr,0) <= 0 then raise exception 'positive INR amount required'; end if;
  if p_entry_type in ('user_usdt','merchant_usdt') and (coalesce(p_amount_usdt,0) <= 0 or coalesce(p_rate,0) <= 0) then raise exception 'positive USDT and rate required'; end if;
  if p_entry_type='collection' and actor_role<>'admin' then
    if p_upi_account_id is not null then
      if provider.funding_model='commission' and coalesce(account.configured_limit_inr,0)<=0 then raise exception 'Collection limit not configured'; end if;
      select * into a from public.accounting_for_upi(p_upi_account_id);
      if p_amount_inr > a.available_limit_inr then raise exception 'collection exceeds available account limit'; end if;
    else
      if provider.funding_model='commission' and coalesce(provider.commission_limit_inr,0)<=0 then raise exception 'Collection limit not configured'; end if;
      select * into a from public.accounting_for_provider(p_provider_id);
      if p_amount_inr > a.collection_capacity_inr then raise exception 'collection exceeds available limit'; end if;
    end if;
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

create or replace function public.admin_update_ledger_entry(p_actor_id uuid,p_entry_id uuid,p_provider_id uuid,p_upi_account_id uuid,p_amount_inr numeric,p_amount_usdt numeric,p_rate numeric,p_bank_name text,p_account_number text,p_transaction_date date,p_note text,p_status text,p_reason text)
returns public.ledger_entries language plpgsql security definer set search_path=public,private,pg_temp as $$
declare old public.ledger_entries; result public.ledger_entries; provider public.providers; new_status text;
begin
  perform private.require_staff(p_actor_id);
  if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  select * into old from public.ledger_entries where id=p_entry_id and provider_id=p_provider_id for update;
  if not found or old.is_voided then raise exception 'ledger entry unavailable'; end if;
  if old.entry_type not in ('collection','inr_received','frozen','user_usdt','merchant_usdt') then raise exception 'unsupported ledger type'; end if;
  select * into provider from public.providers where id=p_provider_id;
  if not found then raise exception 'provider not found'; end if;
  if p_upi_account_id is not null and not exists(select 1 from public.provider_upi_accounts where id=p_upi_account_id and provider_id=p_provider_id and status<>'deleted') then raise exception 'UPI account does not belong to provider'; end if;
  new_status:=coalesce(nullif(btrim(p_status),''),old.status);
  if old.entry_type in ('collection','inr_received','frozen') and coalesce(p_amount_inr,0)<=0 then raise exception 'positive INR amount required'; end if;
  if old.entry_type in ('user_usdt','merchant_usdt') and (coalesce(p_amount_usdt,0)<=0 or coalesce(p_rate,0)<=0) then raise exception 'positive USDT and rate required'; end if;
  update public.ledger_entries set amount_inr=p_amount_inr,amount_usdt=p_amount_usdt,rate=p_rate,bank_name=nullif(btrim(p_bank_name),''),account_number=nullif(btrim(p_account_number),''),transaction_date=coalesce(p_transaction_date,old.transaction_date),note=p_note,status=new_status,upi_account_id=p_upi_account_id,edited_at=now(),edited_by=p_actor_id,edit_reason=nullif(btrim(p_reason),''),updated_at=now()
  where id=p_entry_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,old_data,new_data) values(p_actor_id,'ledger_entry_edited','ledger_entry',p_entry_id::text,to_jsonb(old)-'id',jsonb_build_object('amount_inr',p_amount_inr,'amount_usdt',p_amount_usdt,'rate',p_rate,'upi_account_id',p_upi_account_id,'transaction_date',p_transaction_date,'status',new_status,'reason',p_reason));
  return result;
end; $$;
revoke all on function public.admin_update_ledger_entry(uuid,uuid,uuid,uuid,numeric,numeric,numeric,text,text,date,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_update_ledger_entry(uuid,uuid,uuid,uuid,numeric,numeric,numeric,text,text,date,text,text,text) to service_role;
