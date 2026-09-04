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
    credit := p_rate;
  end if;
  insert into public.ledger_entries(provider_id,upi_account_id,entry_type,amount_inr,amount_usdt,rate,bank_name,account_number,transaction_date,reference_no,note,status,created_by,idempotency_key,credit_rate,accounting_source)
  values (p_provider_id,p_upi_account_id,p_entry_type,p_amount_inr,p_amount_usdt,p_rate,p_bank_name,p_account_number,p_transaction_date,p_reference_no,p_note,p_status,p_actor_id,p_idempotency_key,credit,case when credit is null then 'legacy' else 'manual_usdt_from_user' end)
  returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data)
  values (p_actor_id,'ledger_entry_posted','ledger_entry',result.id::text,jsonb_build_object('provider_id',p_provider_id,'upi_account_id',p_upi_account_id,'entry_type',p_entry_type,'amount_inr',p_amount_inr,'amount_usdt',p_amount_usdt,'rate',p_rate,'credit_rate',credit));
  return result;
end; $$;
revoke all on function public.post_ledger_entry(uuid,uuid,text,numeric,numeric,numeric,text,text,date,text,text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.post_ledger_entry(uuid,uuid,text,numeric,numeric,numeric,text,text,date,text,text,text,text,uuid) to service_role;

create or replace function public.admin_update_ledger_entry(p_actor_id uuid,p_entry_id uuid,p_provider_id uuid,p_upi_account_id uuid,p_amount_inr numeric,p_amount_usdt numeric,p_rate numeric,p_bank_name text,p_account_number text,p_transaction_date date,p_note text,p_status text,p_reason text)
returns public.ledger_entries language plpgsql security definer set search_path=public,private,pg_temp as $$
declare old public.ledger_entries; result public.ledger_entries; provider public.providers; new_status text; new_credit numeric;
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
  if old.entry_type='user_usdt' and provider.funding_model='deposit' then
    new_credit := p_rate;
  else
    new_credit := old.credit_rate;
  end if;
  update public.ledger_entries set amount_inr=p_amount_inr,amount_usdt=p_amount_usdt,rate=p_rate,credit_rate=new_credit,bank_name=nullif(btrim(p_bank_name),''),account_number=nullif(btrim(p_account_number),''),transaction_date=coalesce(p_transaction_date,old.transaction_date),note=p_note,status=new_status,upi_account_id=p_upi_account_id,edited_at=now(),edited_by=p_actor_id,edit_reason=nullif(btrim(p_reason),''),updated_at=now()
  where id=p_entry_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,old_data,new_data) values(p_actor_id,'ledger_entry_edited','ledger_entry',p_entry_id::text,to_jsonb(old)-'id',jsonb_build_object('amount_inr',p_amount_inr,'amount_usdt',p_amount_usdt,'rate',p_rate,'credit_rate',new_credit,'upi_account_id',p_upi_account_id,'transaction_date',p_transaction_date,'status',new_status,'reason',p_reason));
  return result;
end; $$;
revoke all on function public.admin_update_ledger_entry(uuid,uuid,uuid,uuid,numeric,numeric,numeric,text,text,date,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_update_ledger_entry(uuid,uuid,uuid,uuid,numeric,numeric,numeric,text,text,date,text,text,text) to service_role;
