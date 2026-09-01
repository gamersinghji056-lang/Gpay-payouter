create or replace function public.request_usdt_withdrawal(p_share_link_id uuid, p_provider_id uuid, p_requester_type text, p_amount_usdt numeric, p_destination_address text)
returns public.withdrawal_requests language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.withdrawal_requests; rate numeric := 107; request_amount_inr numeric; available_inr numeric;
begin
  if p_amount_usdt is null or p_amount_usdt <= 0 or p_destination_address is null or btrim(p_destination_address)='' then raise exception 'valid withdrawal amount and TRC20 address required'; end if;
  if not exists (select 1 from public.share_links sl where sl.id=p_share_link_id and sl.is_active and sl.expires_at is null and ((p_requester_type='provider' and sl.scope='user' and sl.provider_id=p_provider_id) or (p_requester_type='merchant' and sl.scope='merchant'))) then raise exception 'share link is invalid or revoked'; end if;
  if p_requester_type='provider' then
    perform pg_advisory_xact_lock(hashtextextended('provider-withdrawal:'||p_provider_id::text,0));
    select a.commission_earned_inr into available_inr from public.accounting_for_provider(p_provider_id) a;
    if not exists (select 1 from public.providers p where p.id=p_provider_id and p.status='active' and p.is_active and p.funding_model='commission') then raise exception 'withdrawal is not allowed for this provider'; end if;
  elsif p_requester_type='merchant' then
    perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0));
    select coalesce(sum(le.amount_inr) filter(where le.entry_type='collection' and le.status='posted'),0)
      - coalesce(sum(le.amount_inr) filter(where le.entry_type='frozen' and le.status='active'),0)
      - coalesce(sum(le.amount_usdt*le.rate) filter(where le.entry_type='merchant_usdt' and le.status='posted'),0)
      - coalesce((select sum(ms.amount_inr) from public.merchant_settlements ms),0)
      - coalesce((select sum(wr.amount_inr) from public.withdrawal_requests wr where wr.requester_type='merchant' and wr.status in('pending','paid')),0)
      into available_inr
    from public.ledger_entries le;
  else raise exception 'invalid withdrawal requester'; end if;
  request_amount_inr := round(p_amount_usdt * rate,2);
  if request_amount_inr > greatest(0,available_inr) then raise exception 'withdrawal exceeds available balance'; end if;
  insert into public.withdrawal_requests(requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,created_by)
  values(p_requester_type,case when p_requester_type='provider' then p_provider_id else null end,p_amount_usdt,rate,request_amount_inr,btrim(p_destination_address),null) returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('withdrawal_requested','withdrawal_request',result.id::text,jsonb_build_object('requester_type',p_requester_type,'amount_usdt',p_amount_usdt,'amount_inr',request_amount_inr));
  return result;
end; $$;

create or replace function public.admin_manual_merchant_settlement(p_actor_id uuid,p_amount_usdt numeric,p_rate numeric default 107,p_proof_tx_hash text default null,p_proof_url text default null,p_proof_note text default null,p_idempotency_key text default null)
returns public.merchant_settlements language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.merchant_settlements; available numeric; settlement_amount_inr numeric; commission numeric:=4.5;
begin
  perform private.require_staff(p_actor_id); if not exists(select 1 from public.profiles pr where pr.id=p_actor_id and pr.role='admin') then raise exception 'admin authorization required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0));
  if p_idempotency_key is not null then
    select * into result from public.merchant_settlements ms where ms.idempotency_key=p_idempotency_key;
    if found then raise exception 'duplicate merchant settlement request'; end if;
  end if;
  settlement_amount_inr:=round(p_amount_usdt*p_rate,2);
  select coalesce(sum(le.amount_inr) filter(where le.entry_type='collection' and le.status='posted'),0)
    - coalesce(sum(le.amount_inr) filter(where le.entry_type='frozen' and le.status='active'),0)
    - coalesce(sum(le.amount_usdt*le.rate) filter(where le.entry_type='merchant_usdt' and le.status='posted'),0)
    - coalesce((select sum(ms.amount_inr) from public.merchant_settlements ms),0)
    - coalesce((select sum(wr.amount_inr) from public.withdrawal_requests wr where wr.requester_type='merchant' and wr.status in('pending','paid')),0)
    into available
  from public.ledger_entries le;
  if p_amount_usdt is null or p_amount_usdt<=0 or p_rate<=0 then raise exception 'valid settlement amount and rate required'; end if; if settlement_amount_inr>greatest(0,available) then raise exception 'settlement exceeds merchant balance'; end if;
  insert into public.merchant_settlements(amount_usdt,rate,amount_inr,commission_rate,commission_inr,proof_tx_hash,proof_url,proof_note,created_by,idempotency_key)
  values(p_amount_usdt,p_rate,settlement_amount_inr,commission,round(settlement_amount_inr*commission/100,2),nullif(btrim(p_proof_tx_hash),''),nullif(btrim(p_proof_url),''),p_proof_note,p_actor_id,p_idempotency_key) returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'manual_merchant_settlement','merchant_settlement',result.id::text,jsonb_build_object('amount_usdt',p_amount_usdt,'amount_inr',settlement_amount_inr,'proof_tx_hash',p_proof_tx_hash,'proof_url',p_proof_url)); return result;
end; $$;

revoke all on function public.request_usdt_withdrawal(uuid,uuid,text,numeric,text) from public, anon, authenticated;
revoke all on function public.admin_manual_merchant_settlement(uuid,numeric,numeric,text,text,text,text) from public, anon, authenticated;
grant execute on function public.request_usdt_withdrawal(uuid,uuid,text,numeric,text) to service_role;
grant execute on function public.admin_manual_merchant_settlement(uuid,numeric,numeric,text,text,text,text) to service_role;
