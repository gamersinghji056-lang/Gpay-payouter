alter table public.ledger_entries add column if not exists accounting_source text not null default 'legacy';
alter table public.ledger_entries add column if not exists credit_rate numeric(18,6);

update public.ledger_entries l
set accounting_source='manual_usdt_from_user',
    credit_rate=round(s.deposit_base_rate*(1+s.deposit_markup_pct/100),6)
from public.providers p, public.app_settings s
where l.provider_id=p.id and s.id and l.entry_type='user_usdt'
  and p.funding_model='deposit' and l.accounting_source='legacy';

create table if not exists public.merchant_settlements (
  id uuid primary key default gen_random_uuid(), amount_usdt numeric(18,6) not null check(amount_usdt>0),
  rate numeric(18,6) not null check(rate>0), amount_inr numeric(18,2) not null check(amount_inr>0),
  commission_rate numeric(8,4) not null default 4.5, commission_inr numeric(18,2) not null default 0,
  proof_tx_hash text, proof_url text, proof_note text, settlement_date date not null default current_date,
  created_by uuid references public.profiles(id), created_at timestamptz not null default now(), idempotency_key text unique
);
alter table public.merchant_settlements enable row level security;
create policy merchant_settlements_staff_select on public.merchant_settlements for select to authenticated using (private.current_role() in ('admin','operator'));

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
  w as (select coalesce(sum(amount_inr) filter (where requester_type='provider' and provider_id=p_provider_id and status in ('pending','paid')),0) paid_or_reserved)
  select l.collection,l.withdrawal,l.user_usdt,l.merchant,l.frozen,d.deposit+l.manual_deposit,
    case when p.funding_model='deposit' then greatest(0,d.deposit+l.manual_deposit-l.collection)
      else least(p.commission_limit_inr,greatest(0,p.commission_limit_inr-(l.collection-l.withdrawal))) end,
    case when p.funding_model='commission' then greatest(0,l.withdrawal*(select commission_rate_pct/100 from public.app_settings where id)-w.paid_or_reserved) else 0 end
  from p,l,d,w;
$$;

create or replace function public.admin_manual_user_payout(p_actor_id uuid,p_provider_id uuid,p_amount_usdt numeric,p_destination_address text,p_proof_tx_hash text default null,p_proof_url text default null,p_proof_note text default null)
returns public.withdrawal_requests language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.withdrawal_requests; available numeric; amount_inr numeric;
begin
  perform private.require_staff(p_actor_id); if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('user-payout:'||p_provider_id::text,0));
  if not exists(select 1 from public.providers where id=p_provider_id and is_active and status='active' and funding_model='commission') then raise exception 'commission provider unavailable'; end if;
  amount_inr:=round(p_amount_usdt*107,2); select commission_earned_inr into available from public.accounting_for_provider(p_provider_id);
  if p_amount_usdt is null or p_amount_usdt<=0 or p_destination_address is null or btrim(p_destination_address)='' then raise exception 'valid payout amount and TRC20 address required'; end if;
  if amount_inr>greatest(0,available) then raise exception 'payout exceeds available commission'; end if;
  insert into public.withdrawal_requests(requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,status,proof_tx_hash,proof_url,proof_note,created_by,paid_by,paid_at) values('provider',p_provider_id,p_amount_usdt,107,amount_inr,btrim(p_destination_address),'paid',nullif(btrim(p_proof_tx_hash),''),nullif(btrim(p_proof_url),''),p_proof_note,p_actor_id,p_actor_id,now()) returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'manual_user_payout','withdrawal_request',result.id::text,jsonb_build_object('provider_id',p_provider_id,'amount_usdt',p_amount_usdt,'amount_inr',amount_inr)); return result;
end; $$;

create or replace function public.admin_manual_merchant_settlement(p_actor_id uuid,p_amount_usdt numeric,p_rate numeric default 107,p_proof_tx_hash text default null,p_proof_url text default null,p_proof_note text default null)
returns public.merchant_settlements language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.merchant_settlements; available numeric; amount_inr numeric; commission numeric:=4.5;
begin
  perform private.require_staff(p_actor_id); if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0)); amount_inr:=round(p_amount_usdt*p_rate,2);
  select coalesce(sum(amount_inr) filter(where entry_type='collection' and status='posted'),0)-coalesce(sum(amount_inr) filter(where entry_type='frozen' and status='active'),0)-coalesce(sum(amount_usdt*rate) filter(where entry_type='merchant_usdt' and status='posted'),0)-coalesce((select sum(amount_inr) from public.merchant_settlements),0)-coalesce((select sum(amount_inr) from public.withdrawal_requests where requester_type='merchant' and status in('pending','paid')),0) into available from public.ledger_entries;
  if p_amount_usdt is null or p_amount_usdt<=0 or p_rate<=0 then raise exception 'valid settlement amount and rate required'; end if; if amount_inr>greatest(0,available) then raise exception 'settlement exceeds merchant balance'; end if;
  insert into public.merchant_settlements(amount_usdt,rate,amount_inr,commission_rate,commission_inr,proof_tx_hash,proof_url,proof_note,created_by) values(p_amount_usdt,p_rate,amount_inr,commission,round(amount_inr*commission/100,2),nullif(btrim(p_proof_tx_hash),''),nullif(btrim(p_proof_url),''),p_proof_note,p_actor_id) returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'manual_merchant_settlement','merchant_settlement',result.id::text,jsonb_build_object('amount_usdt',p_amount_usdt,'amount_inr',amount_inr,'proof_tx_hash',p_proof_tx_hash,'proof_url',p_proof_url)); return result;
end; $$;

revoke all on function public.admin_manual_user_payout(uuid,uuid,numeric,text,text,text,text) from public,anon,authenticated;
revoke all on function public.admin_manual_merchant_settlement(uuid,numeric,numeric,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_manual_user_payout(uuid,uuid,numeric,text,text,text,text) to service_role;
grant execute on function public.admin_manual_merchant_settlement(uuid,numeric,numeric,text,text,text) to service_role;
