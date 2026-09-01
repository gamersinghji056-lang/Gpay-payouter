create or replace function public.accounting_for_provider(p_provider_id uuid)
returns table (collection_inr numeric, successful_withdrawal_inr numeric, user_usdt_inr numeric, merchant_settled_inr numeric, frozen_inr numeric, confirmed_deposit_inr numeric, collection_capacity_inr numeric, commission_earned_inr numeric)
language sql stable security invoker set search_path = public, pg_temp as $$
  with p as (select * from public.providers where id=p_provider_id),
  l as (select coalesce(sum(amount_inr) filter (where entry_type='collection' and status='posted'),0) collection,
               coalesce(sum(amount_inr) filter (where entry_type='inr_received' and status='posted'),0) withdrawal,
               coalesce(sum(amount_usdt * coalesce(credit_rate,rate)) filter (where entry_type='user_usdt' and status='posted' and (select funding_model from p)='deposit'),0) manual_deposit,
               coalesce(sum(amount_usdt * rate) filter (where entry_type='user_usdt' and status='posted' and (select funding_model from p)='commission'),0) user_usdt,
               coalesce(sum(amount_usdt * rate) filter (where entry_type='merchant_usdt' and status='posted'),0) merchant,
               coalesce(sum(amount_inr) filter (where entry_type='frozen' and status='active'),0) frozen
        from public.ledger_entries where provider_id=p_provider_id),
  d as (select coalesce(sum(inr_value) filter (where status='confirmed'),0) deposit from public.deposit_requests where provider_id=p_provider_id),
  w as (select coalesce(sum(amount_inr) filter (where requester_type='provider' and provider_id=p_provider_id and status in ('pending','paid')),0) paid_or_reserved from public.withdrawal_requests)
  select l.collection,l.withdrawal,l.user_usdt,l.merchant,l.frozen,d.deposit+l.manual_deposit,
    case when p.funding_model='deposit' then greatest(0,d.deposit+l.manual_deposit-l.collection)
      else least(coalesce(p.commission_limit_inr,0),greatest(0,coalesce(p.commission_limit_inr,0)-(l.collection-l.withdrawal))) end,
    case when p.funding_model='commission' then greatest(0,l.withdrawal*(select commission_rate_pct/100 from public.app_settings where id)-w.paid_or_reserved) else 0 end
  from p,l,d,w;
$$;
grant execute on function public.accounting_for_provider(uuid) to authenticated, service_role;

create or replace function public.post_ledger_entry(
  p_actor_id uuid, p_provider_id uuid, p_entry_type text, p_amount_inr numeric default null,
  p_amount_usdt numeric default null, p_rate numeric default null, p_bank_name text default null,
  p_account_number text default null, p_transaction_date date default current_date, p_reference_no text default null,
  p_note text default null, p_status text default 'posted', p_idempotency_key text default null
) returns public.ledger_entries
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.ledger_entries; a record; provider public.providers; effective_amount numeric; credit numeric;
begin
  perform private.require_staff(p_actor_id);
  perform pg_advisory_xact_lock(hashtextextended(p_provider_id::text, 0));
  if p_idempotency_key is not null then
    select * into result from public.ledger_entries where idempotency_key=p_idempotency_key;
    if found then return result; end if;
  end if;
  select * into provider from public.providers where id=p_provider_id and is_active and status='active';
  if not found then raise exception 'active provider not found'; end if;
  if p_entry_type not in ('collection','inr_received','user_usdt','merchant_usdt','frozen') then raise exception 'invalid ledger type'; end if;
  if p_entry_type in ('collection','inr_received','frozen') and coalesce(p_amount_inr,0) <= 0 then raise exception 'positive INR amount required'; end if;
  if p_entry_type in ('user_usdt','merchant_usdt') and (coalesce(p_amount_usdt,0) <= 0 or coalesce(p_rate,0) <= 0) then raise exception 'positive USDT and rate required'; end if;
  if p_entry_type='collection' then
    if provider.funding_model='commission' and coalesce(provider.commission_limit_inr,0)<=0 then raise exception 'Collection limit not configured'; end if;
    select * into a from public.accounting_for_provider(p_provider_id);
    effective_amount := a.collection_capacity_inr;
    if p_amount_inr > effective_amount then raise exception 'collection exceeds available limit'; end if;
  end if;
  if p_entry_type='user_usdt' and provider.funding_model='deposit' then
    select round(deposit_base_rate*(1+deposit_markup_pct/100),6) into credit from public.app_settings where id;
  end if;
  insert into public.ledger_entries(provider_id,entry_type,amount_inr,amount_usdt,rate,bank_name,account_number,transaction_date,reference_no,note,status,created_by,idempotency_key,credit_rate,accounting_source)
  values (p_provider_id,p_entry_type,p_amount_inr,p_amount_usdt,p_rate,p_bank_name,p_account_number,p_transaction_date,p_reference_no,p_note,p_status,p_actor_id,p_idempotency_key,credit,case when credit is null then 'legacy' else 'manual_usdt_from_user' end)
  returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data)
  values (p_actor_id,'ledger_entry_posted','ledger_entry',result.id::text,jsonb_build_object('provider_id',p_provider_id,'entry_type',p_entry_type,'amount_inr',p_amount_inr,'amount_usdt',p_amount_usdt));
  return result;
end; $$;
revoke all on function public.post_ledger_entry(uuid,uuid,text,numeric,numeric,numeric,text,text,date,text,text,text,text) from public, anon, authenticated;
grant execute on function public.post_ledger_entry(uuid,uuid,text,numeric,numeric,numeric,text,text,date,text,text,text,text) to service_role;

create or replace function public.post_collection_by_share(
  p_share_link_id uuid, p_provider_id uuid, p_amount_inr numeric, p_bank_name text,
  p_account_number text, p_transaction_date date, p_note text default null, p_idempotency_key text default null
) returns public.ledger_entries
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.ledger_entries; a record; provider public.providers;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_provider_id::text, 0));
  if not exists (select 1 from public.share_links where id=p_share_link_id and scope='merchant' and is_active and (expires_at is null or expires_at>now())) then raise exception 'merchant share link is invalid or revoked'; end if;
  if p_idempotency_key is not null then
    select * into result from public.ledger_entries where idempotency_key=p_idempotency_key;
    if found then return result; end if;
  end if;
  select * into provider from public.providers where id=p_provider_id and is_active and status='active';
  if not found then raise exception 'active provider not found'; end if;
  if p_amount_inr <= 0 then raise exception 'positive collection amount required'; end if;
  if provider.funding_model='commission' and coalesce(provider.commission_limit_inr,0)<=0 then raise exception 'Collection limit not configured'; end if;
  select * into a from public.accounting_for_provider(p_provider_id);
  if p_amount_inr > a.collection_capacity_inr then raise exception 'collection exceeds available limit'; end if;
  insert into public.ledger_entries(provider_id,entry_type,amount_inr,bank_name,account_number,transaction_date,note,status,idempotency_key)
  values(p_provider_id,'collection',p_amount_inr,p_bank_name,p_account_number,p_transaction_date,p_note,'posted',p_idempotency_key)
  returning * into result;
  update public.share_links set last_accessed_at=now() where id=p_share_link_id;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('shared_collection_posted','ledger_entry',result.id::text,jsonb_build_object('share_link_id',p_share_link_id,'provider_id',p_provider_id,'amount_inr',p_amount_inr));
  return result;
end; $$;
revoke all on function public.post_collection_by_share(uuid,uuid,numeric,text,text,date,text,text) from public, anon, authenticated;
grant execute on function public.post_collection_by_share(uuid,uuid,numeric,text,text,date,text,text) to service_role;

create or replace function public.correct_collection_by_share(p_share_link_id uuid, p_entry_id uuid, p_amount_inr numeric, p_note text default null)
returns public.ledger_entries language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.ledger_entries; a record; old_amount numeric; provider_id uuid;
begin
  select l.provider_id,l.amount_inr into provider_id,old_amount from public.ledger_entries l where l.id=p_entry_id and l.entry_type='collection' and l.status='posted';
  if provider_id is null or old_amount is null or p_amount_inr < 0 then raise exception 'collection entry unavailable'; end if;
  perform pg_advisory_xact_lock(hashtextextended(provider_id::text, 0));
  if not exists (select 1 from public.share_links where id=p_share_link_id and scope='merchant' and is_active and (expires_at is null or expires_at>now())) then raise exception 'merchant share link is invalid or revoked'; end if;
  if not exists (select 1 from public.providers where id=provider_id and status='active' and is_active) then raise exception 'active provider not found'; end if;
  select * into a from public.accounting_for_provider(provider_id);
  if p_amount_inr > a.collection_capacity_inr + old_amount then raise exception 'corrected collection exceeds available limit'; end if;
  update public.ledger_entries set amount_inr=p_amount_inr,note=case when p_note is null or btrim(p_note)='' then note else concat_ws(' ',nullif(note,''),'Correction:',p_note) end,updated_at=now() where id=p_entry_id returning * into result;
  update public.share_links set last_accessed_at=now() where id=p_share_link_id;
  insert into public.audit_logs(action,entity_type,entity_id,old_data,new_data) values('shared_collection_corrected','ledger_entry',result.id::text,jsonb_build_object('amount_inr',old_amount),jsonb_build_object('amount_inr',p_amount_inr,'share_link_id',p_share_link_id));
  return result;
end; $$;
revoke all on function public.correct_collection_by_share(uuid,uuid,numeric,text) from public, anon, authenticated;
grant execute on function public.correct_collection_by_share(uuid,uuid,numeric,text) to service_role;

create or replace function public.request_usdt_withdrawal(p_share_link_id uuid, p_provider_id uuid, p_requester_type text, p_amount_usdt numeric, p_destination_address text)
returns public.withdrawal_requests language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.withdrawal_requests; rate numeric := 107; amount_inr numeric; available_inr numeric; reserved_inr numeric;
begin
  if p_amount_usdt is null or p_amount_usdt <= 0 or p_destination_address is null or btrim(p_destination_address)='' then raise exception 'valid withdrawal amount and TRC20 address required'; end if;
  if not exists (select 1 from public.share_links where id=p_share_link_id and is_active and expires_at is null and ((p_requester_type='provider' and scope='user' and provider_id=p_provider_id) or (p_requester_type='merchant' and scope='merchant'))) then raise exception 'share link is invalid or revoked'; end if;
  if p_requester_type='provider' then
    perform pg_advisory_xact_lock(hashtextextended('provider-withdrawal:'||p_provider_id::text,0));
    select commission_earned_inr into available_inr from public.accounting_for_provider(p_provider_id);
    if not exists (select 1 from public.providers where id=p_provider_id and status='active' and is_active and funding_model='commission') then raise exception 'withdrawal is not allowed for this provider'; end if;
    reserved_inr := 0;
  elsif p_requester_type='merchant' then
    perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0));
    select coalesce(sum(amount_inr) filter (where entry_type='collection' and status='posted'),0)-coalesce(sum(amount_inr) filter (where entry_type='frozen' and status='active'),0)-coalesce(sum(amount_usdt*rate) filter (where entry_type='merchant_usdt' and status='posted'),0)-coalesce((select sum(amount_inr) from public.merchant_settlements),0)-coalesce((select sum(amount_inr) from public.withdrawal_requests where requester_type='merchant' and status in('pending','paid')),0) into available_inr from public.ledger_entries;
    reserved_inr := 0;
  else raise exception 'invalid withdrawal requester'; end if;
  amount_inr := round(p_amount_usdt * rate,2);
  if amount_inr > greatest(0,coalesce(available_inr,0)-coalesce(reserved_inr,0)) then raise exception 'withdrawal exceeds available balance'; end if;
  insert into public.withdrawal_requests(requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,created_by)
  values(p_requester_type,case when p_requester_type='provider' then p_provider_id else null end,p_amount_usdt,rate,amount_inr,btrim(p_destination_address),null) returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('withdrawal_requested','withdrawal_request',result.id::text,jsonb_build_object('requester_type',p_requester_type,'amount_usdt',p_amount_usdt,'amount_inr',amount_inr));
  return result;
end; $$;
revoke all on function public.request_usdt_withdrawal(uuid,uuid,text,numeric,text) from public, anon, authenticated;
grant execute on function public.request_usdt_withdrawal(uuid,uuid,text,numeric,text) to service_role;

create or replace function public.admin_manual_merchant_settlement(p_actor_id uuid,p_amount_usdt numeric,p_rate numeric default 107,p_proof_tx_hash text default null,p_proof_url text default null,p_proof_note text default null,p_idempotency_key text default null)
returns public.merchant_settlements language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.merchant_settlements; available numeric; amount_inr numeric; commission numeric:=4.5;
begin
  perform private.require_staff(p_actor_id); if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0));
  if p_idempotency_key is not null then
    select * into result from public.merchant_settlements where idempotency_key=p_idempotency_key;
    if found then raise exception 'duplicate merchant settlement request'; end if;
  end if;
  if p_amount_usdt is null or p_amount_usdt<=0 or p_rate<=0 then raise exception 'valid settlement amount and rate required'; end if;
  amount_inr:=round(p_amount_usdt*p_rate,2);
  select coalesce(sum(amount_inr) filter(where entry_type='collection' and status='posted'),0)-coalesce(sum(amount_inr) filter(where entry_type='frozen' and status='active'),0)-coalesce(sum(amount_usdt*rate) filter(where entry_type='merchant_usdt' and status='posted'),0)-coalesce((select sum(amount_inr) from public.merchant_settlements),0)-coalesce((select sum(amount_inr) from public.withdrawal_requests where requester_type='merchant' and status in('pending','paid')),0) into available from public.ledger_entries;
  if amount_inr>greatest(0,available) then raise exception 'settlement exceeds merchant balance'; end if;
  insert into public.merchant_settlements(amount_usdt,rate,amount_inr,commission_rate,commission_inr,proof_tx_hash,proof_url,proof_note,created_by,idempotency_key)
  values(p_amount_usdt,p_rate,amount_inr,commission,round(amount_inr*commission/100,2),nullif(btrim(p_proof_tx_hash),''),nullif(btrim(p_proof_url),''),p_proof_note,p_actor_id,p_idempotency_key) returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'manual_merchant_settlement','merchant_settlement',result.id::text,jsonb_build_object('amount_usdt',p_amount_usdt,'amount_inr',amount_inr,'proof_tx_hash',p_proof_tx_hash,'proof_url',p_proof_url)); return result;
end; $$;
revoke all on function public.admin_manual_merchant_settlement(uuid,numeric,numeric,text,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_manual_merchant_settlement(uuid,numeric,numeric,text,text,text,text) to service_role;
