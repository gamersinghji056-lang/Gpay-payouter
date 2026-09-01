create table if not exists public.merchant_charges (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.providers(id) on delete restrict,
  upi_account_id uuid references public.provider_upi_accounts(id) on delete restrict,
  amount_inr numeric(18,2) not null check (amount_inr > 0),
  user_name text not null,
  upi_id text,
  mobile text,
  charge_date date not null default current_date,
  reference text,
  note text,
  status text not null default 'active' check (status in ('active','reversed')),
  reversed_at timestamptz,
  reversed_by uuid references public.profiles(id),
  idempotency_key text unique,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists merchant_charges_status_date_idx on public.merchant_charges(status,charge_date desc);
alter table public.merchant_charges enable row level security;
create policy merchant_charges_staff_all on public.merchant_charges for all to authenticated using(private.current_role() in ('admin','operator')) with check(private.current_role() in ('admin','operator'));

create or replace function public.merchant_available_balance_inr()
returns numeric language sql stable security definer set search_path=public,private,pg_temp as $$
  select greatest(0,
    coalesce((select sum(le.amount_inr) from public.ledger_entries le where le.entry_type='collection' and le.status='posted'),0)
    -coalesce((select sum(le.amount_inr) from public.ledger_entries le where le.entry_type='frozen' and le.status='active'),0)
    -coalesce((select sum(le.amount_usdt*le.rate) from public.ledger_entries le where le.entry_type='merchant_usdt' and le.status='posted'),0)
    -coalesce((select sum(ms.amount_inr) from public.merchant_settlements ms),0)
    -coalesce((select sum(wr.amount_inr) from public.withdrawal_requests wr where wr.requester_type='merchant' and wr.status in('pending','paid')),0)
    -coalesce((select sum(mc.amount_inr) from public.merchant_charges mc where mc.status='active'),0));
$$;
grant execute on function public.merchant_available_balance_inr() to authenticated,service_role;

create or replace function public.add_merchant_charge(p_actor_id uuid,p_provider_id uuid,p_upi_account_id uuid,p_amount_inr numeric,p_user_name text,p_upi_id text,p_mobile text,p_charge_date date default current_date,p_reference text default null,p_note text default null,p_idempotency_key text default null)
returns public.merchant_charges language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.merchant_charges; available numeric;
begin
  perform private.require_staff(p_actor_id); perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0));
  if p_amount_inr is null or p_amount_inr<=0 or p_provider_id is null or coalesce(btrim(p_user_name),'')='' then raise exception 'valid charge details required'; end if;
  if p_upi_account_id is not null and not exists(select 1 from public.provider_upi_accounts where id=p_upi_account_id and provider_id=p_provider_id and status<>'deleted') then raise exception 'UPI account does not belong to provider'; end if;
  if p_idempotency_key is not null and exists(select 1 from public.merchant_charges where idempotency_key=p_idempotency_key) then raise exception 'duplicate merchant charge request'; end if;
  available:=public.merchant_available_balance_inr(); if p_amount_inr>available then raise exception 'charge exceeds merchant balance'; end if;
  insert into public.merchant_charges(provider_id,upi_account_id,amount_inr,user_name,upi_id,mobile,charge_date,reference,note,idempotency_key,created_by)
  values(p_provider_id,p_upi_account_id,p_amount_inr,btrim(p_user_name),nullif(btrim(p_upi_id),''),nullif(btrim(p_mobile),''),coalesce(p_charge_date,current_date),nullif(btrim(p_reference),''),p_note,p_idempotency_key,p_actor_id) returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'merchant_charge_added','merchant_charge',result.id::text,jsonb_build_object('amount_inr',p_amount_inr,'provider_id',p_provider_id,'upi_account_id',p_upi_account_id));
  return result;
end; $$;
revoke all on function public.add_merchant_charge(uuid,uuid,uuid,numeric,text,text,text,date,text,text,text) from public,anon,authenticated;
grant execute on function public.add_merchant_charge(uuid,uuid,uuid,numeric,text,text,text,date,text,text,text) to service_role;

create or replace function public.reverse_merchant_charge(p_actor_id uuid,p_charge_id uuid,p_idempotency_key text default null)
returns public.merchant_charges language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.merchant_charges;
begin
  perform private.require_staff(p_actor_id); perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0));
  select * into result from public.merchant_charges where id=p_charge_id for update;
  if not found then raise exception 'charge not found'; end if;
  if result.status<>'active' then raise exception 'charge is already reversed'; end if;
  update public.merchant_charges set status='reversed',reversed_at=now(),reversed_by=p_actor_id where id=p_charge_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'merchant_charge_reversed','merchant_charge',p_charge_id::text,jsonb_build_object('amount_inr',result.amount_inr,'idempotency_key',p_idempotency_key));
  return result;
end; $$;
revoke all on function public.reverse_merchant_charge(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.reverse_merchant_charge(uuid,uuid,text) to service_role;

create or replace function public.request_usdt_withdrawal(p_share_link_id uuid,p_provider_id uuid,p_requester_type text,p_amount_usdt numeric,p_destination_address text)
returns public.withdrawal_requests language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.withdrawal_requests; request_amount_inr numeric; available_inr numeric;
begin
  if p_amount_usdt is null or p_amount_usdt<=0 or p_destination_address is null or btrim(p_destination_address)='' then raise exception 'valid withdrawal amount and TRC20 address required'; end if;
  if not exists(select 1 from public.share_links sl where sl.id=p_share_link_id and sl.is_active and sl.expires_at is null and ((p_requester_type='provider' and sl.scope='user' and sl.provider_id=p_provider_id) or (p_requester_type='merchant' and sl.scope='merchant'))) then raise exception 'share link is invalid or revoked'; end if;
  if p_requester_type='provider' then if not exists(select 1 from public.providers p where p.id=p_provider_id and p.status='active' and p.is_active and p.funding_model='commission') then raise exception 'withdrawal is not allowed for this provider'; end if; select a.commission_earned_inr into available_inr from public.accounting_for_provider(p_provider_id) a; else if p_requester_type='merchant' then perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0)); available_inr:=public.merchant_available_balance_inr(); else raise exception 'invalid withdrawal requester'; end if; end if;
  request_amount_inr:=round(p_amount_usdt*107,2); if request_amount_inr>greatest(0,available_inr) then raise exception 'withdrawal exceeds available balance'; end if;
  insert into public.withdrawal_requests(requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,created_by) values(p_requester_type,case when p_requester_type='provider' then p_provider_id else null end,p_amount_usdt,107,request_amount_inr,btrim(p_destination_address),null) returning * into result;
  return result;
end; $$;

create or replace function public.admin_manual_merchant_settlement(p_actor_id uuid,p_amount_usdt numeric,p_rate numeric default 107,p_proof_tx_hash text default null,p_proof_url text default null,p_proof_note text default null,p_idempotency_key text default null)
returns public.merchant_settlements language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.merchant_settlements; amount_inr numeric; available numeric;
begin
  perform private.require_staff(p_actor_id); if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('merchant-settlement',0));
  if p_amount_usdt is null or p_amount_usdt<=0 or p_rate is null or p_rate<=0 then raise exception 'valid settlement amount and rate required'; end if;
  if p_idempotency_key is not null and exists(select 1 from public.merchant_settlements where idempotency_key=p_idempotency_key) then raise exception 'duplicate merchant settlement request'; end if;
  amount_inr:=round(p_amount_usdt*p_rate,2); available:=public.merchant_available_balance_inr(); if amount_inr>available then raise exception 'settlement exceeds merchant balance'; end if;
  insert into public.merchant_settlements(amount_usdt,rate,amount_inr,commission_rate,commission_inr,proof_tx_hash,proof_url,proof_note,created_by,idempotency_key) values(p_amount_usdt,p_rate,amount_inr,4.5,round(amount_inr*4.5/100,2),nullif(btrim(p_proof_tx_hash),''),nullif(btrim(p_proof_url),''),p_proof_note,p_actor_id,p_idempotency_key) returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'manual_merchant_settlement','merchant_settlement',result.id::text,jsonb_build_object('amount_usdt',p_amount_usdt,'amount_inr',amount_inr)); return result;
end; $$;
