alter table public.withdrawal_requests add column if not exists idempotency_key text;
create unique index if not exists withdrawal_requests_idempotency_idx on public.withdrawal_requests(idempotency_key) where idempotency_key is not null;

create or replace function public.admin_manual_user_payout(p_actor_id uuid,p_provider_id uuid,p_amount_usdt numeric,p_destination_address text,p_proof_tx_hash text default null,p_proof_url text default null,p_proof_note text default null,p_idempotency_key text default null)
returns public.withdrawal_requests language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.withdrawal_requests; available numeric; amount_inr numeric;
begin
  perform private.require_staff(p_actor_id); if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('user-payout:'||p_provider_id::text,0));
  if p_idempotency_key is not null and exists(select 1 from public.withdrawal_requests where idempotency_key=p_idempotency_key) then raise exception 'duplicate user payout request'; end if;
  if not exists(select 1 from public.providers where id=p_provider_id and is_active and status='active' and funding_model='commission') then raise exception 'commission provider unavailable'; end if;
  amount_inr:=round(p_amount_usdt*107,2); select commission_earned_inr into available from public.accounting_for_provider(p_provider_id);
  if p_amount_usdt is null or p_amount_usdt<=0 or p_destination_address is null or btrim(p_destination_address)='' then raise exception 'valid payout amount and TRC20 address required'; end if;
  if amount_inr>greatest(0,available) then raise exception 'payout exceeds available commission'; end if;
  insert into public.withdrawal_requests(requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,status,proof_tx_hash,proof_url,proof_note,created_by,paid_by,paid_at,idempotency_key) values('provider',p_provider_id,p_amount_usdt,107,amount_inr,btrim(p_destination_address),'paid',nullif(btrim(p_proof_tx_hash),''),nullif(btrim(p_proof_url),''),p_proof_note,p_actor_id,p_actor_id,now(),p_idempotency_key) returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'manual_user_payout','withdrawal_request',result.id::text,jsonb_build_object('provider_id',p_provider_id,'amount_usdt',p_amount_usdt,'amount_inr',amount_inr,'idempotency_key',p_idempotency_key)); return result;
end; $$;
revoke all on function public.admin_manual_user_payout(uuid,uuid,numeric,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_manual_user_payout(uuid,uuid,numeric,text,text,text,text,text) to service_role;
