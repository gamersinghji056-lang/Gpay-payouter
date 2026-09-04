alter table public.ledger_entries add column if not exists is_voided boolean not null default false;
alter table public.ledger_entries add column if not exists voided_at timestamptz;
alter table public.ledger_entries add column if not exists voided_by uuid references public.profiles(id);
alter table public.ledger_entries add column if not exists void_reason text;
alter table public.ledger_entries add column if not exists edited_at timestamptz;
alter table public.ledger_entries add column if not exists edited_by uuid references public.profiles(id);
alter table public.ledger_entries add column if not exists edit_reason text;

alter table public.withdrawal_requests add column if not exists upi_account_id uuid references public.provider_upi_accounts(id) on delete restrict;
alter table public.withdrawal_requests add column if not exists is_voided boolean not null default false;
alter table public.withdrawal_requests add column if not exists voided_at timestamptz;
alter table public.withdrawal_requests add column if not exists voided_by uuid references public.profiles(id);
alter table public.withdrawal_requests add column if not exists void_reason text;
alter table public.withdrawal_requests add column if not exists edited_at timestamptz;
alter table public.withdrawal_requests add column if not exists edited_by uuid references public.profiles(id);
alter table public.withdrawal_requests add column if not exists edit_reason text;

create index if not exists ledger_entries_voided_idx on public.ledger_entries(provider_id, is_voided, transaction_date desc);
create index if not exists withdrawal_requests_voided_idx on public.withdrawal_requests(requester_type, provider_id, is_voided, created_at desc);

create or replace function public.accounting_for_provider(p_provider_id uuid)
returns table (collection_inr numeric, successful_withdrawal_inr numeric, user_usdt_inr numeric, merchant_settled_inr numeric, frozen_inr numeric, confirmed_deposit_inr numeric, collection_capacity_inr numeric, commission_earned_inr numeric)
language sql stable security invoker set search_path = public, pg_temp as $$
  with p as (select * from public.providers where id=p_provider_id),
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
      else least(coalesce(p.commission_limit_inr,0),greatest(0,coalesce(p.commission_limit_inr,0)-(l.collection-l.withdrawal))) end,
    case when p.funding_model='commission' then greatest(0,l.withdrawal*(select commission_rate_pct/100 from public.app_settings where id)-w.paid_or_reserved) else 0 end
  from p,l,d,w;
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
         else greatest(0,a.configured_limit_inr-l.collection+l.withdrawal) end
  from a,l;
$$;
grant execute on function public.accounting_for_upi(uuid) to authenticated,service_role;

create or replace function public.merchant_available_balance_inr()
returns numeric language sql stable security definer set search_path=public,private,pg_temp as $$
  select greatest(0,
    coalesce((select sum(le.amount_inr) from public.ledger_entries le where le.entry_type='collection' and le.status='posted' and not le.is_voided),0)
    -coalesce((select sum(le.amount_inr) from public.ledger_entries le where le.entry_type='frozen' and le.status='active' and not le.is_voided),0)
    -coalesce((select sum(le.amount_usdt*le.rate) from public.ledger_entries le where le.entry_type='merchant_usdt' and le.status='posted' and not le.is_voided),0)
    -coalesce((select sum(ms.amount_inr) from public.merchant_settlements ms),0)
    -coalesce((select sum(wr.amount_inr) from public.withdrawal_requests wr where wr.requester_type='merchant' and wr.status in('pending','paid') and not wr.is_voided),0)
    -coalesce((select sum(mc.amount_inr) from public.merchant_charges mc where mc.status='active'),0));
$$;
grant execute on function public.merchant_available_balance_inr() to authenticated,service_role;

create or replace function public.merchant_accounting_summary()
returns table(total_collection_inr numeric,frozen_inr numeric,merchant_ledger_settled_inr numeric,manual_settled_inr numeric,manual_settled_usdt numeric,merchant_commission_inr numeric,charges_inr numeric,reserved_inr numeric,available_inr numeric)
language sql stable security definer set search_path=public,private,pg_temp as $$
  with v as (
    select
      coalesce((select sum(le.amount_inr) from public.ledger_entries le where le.entry_type='collection' and le.status='posted' and not le.is_voided),0) as total_collection_inr,
      coalesce((select sum(le.amount_inr) from public.ledger_entries le where le.entry_type='frozen' and le.status='active' and not le.is_voided),0) as frozen_inr,
      coalesce((select sum(le.amount_usdt*le.rate) from public.ledger_entries le where le.entry_type='merchant_usdt' and le.status='posted' and not le.is_voided),0) as merchant_ledger_settled_inr,
      coalesce((select sum(ms.amount_inr) from public.merchant_settlements ms),0) as manual_settled_inr,
      coalesce((select sum(ms.amount_usdt) from public.merchant_settlements ms),0) as manual_settled_usdt,
      coalesce((select sum(le.merchant_commission_inr) from public.ledger_entries le where le.entry_type='merchant_usdt' and le.status='posted' and not le.is_voided),0)
        + coalesce((select sum(ms.commission_inr) from public.merchant_settlements ms),0) as merchant_commission_inr,
      coalesce((select sum(mc.amount_inr) from public.merchant_charges mc where mc.status='active'),0) as charges_inr,
      coalesce((select sum(wr.amount_inr) from public.withdrawal_requests wr where wr.requester_type='merchant' and wr.status in('pending','paid') and not wr.is_voided),0) as reserved_inr)
  select total_collection_inr,frozen_inr,merchant_ledger_settled_inr,manual_settled_inr,manual_settled_usdt,merchant_commission_inr,charges_inr,reserved_inr,
    greatest(0,total_collection_inr-frozen_inr-merchant_ledger_settled_inr-manual_settled_inr-reserved_inr-charges_inr) as available_inr
  from v;
$$;
grant execute on function public.merchant_accounting_summary() to authenticated,service_role;

create or replace function public.admin_update_ledger_entry(p_actor_id uuid,p_entry_id uuid,p_provider_id uuid,p_upi_account_id uuid,p_amount_inr numeric,p_amount_usdt numeric,p_rate numeric,p_bank_name text,p_account_number text,p_transaction_date date,p_note text,p_status text,p_reason text)
returns public.ledger_entries language plpgsql security definer set search_path=public,private,pg_temp as $$
declare old public.ledger_entries; result public.ledger_entries; provider public.providers; a record; old_counted numeric:=0; account_old_counted numeric:=0; new_status text;
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
  if old.entry_type='collection' and new_status='posted' then
    old_counted:=case when old.status='posted' and not old.is_voided then old.amount_inr else 0 end;
    select * into a from public.accounting_for_provider(p_provider_id);
    if p_amount_inr > a.collection_capacity_inr + old_counted then raise exception 'corrected collection exceeds available limit'; end if;
    if p_upi_account_id is not null then
      account_old_counted:=case when old.upi_account_id=p_upi_account_id and old.status='posted' and not old.is_voided then old.amount_inr else 0 end;
      select * into a from public.accounting_for_upi(p_upi_account_id);
      if p_amount_inr > a.available_limit_inr + account_old_counted then raise exception 'corrected collection exceeds UPI available limit'; end if;
    end if;
  end if;
  update public.ledger_entries set amount_inr=p_amount_inr,amount_usdt=p_amount_usdt,rate=p_rate,bank_name=nullif(btrim(p_bank_name),''),account_number=nullif(btrim(p_account_number),''),transaction_date=coalesce(p_transaction_date,old.transaction_date),note=p_note,status=new_status,upi_account_id=p_upi_account_id,edited_at=now(),edited_by=p_actor_id,edit_reason=nullif(btrim(p_reason),''),updated_at=now()
  where id=p_entry_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,old_data,new_data) values(p_actor_id,'ledger_entry_edited','ledger_entry',p_entry_id::text,to_jsonb(old)-'id',jsonb_build_object('amount_inr',p_amount_inr,'amount_usdt',p_amount_usdt,'rate',p_rate,'upi_account_id',p_upi_account_id,'transaction_date',p_transaction_date,'status',new_status,'reason',p_reason));
  return result;
end; $$;
revoke all on function public.admin_update_ledger_entry(uuid,uuid,uuid,uuid,numeric,numeric,numeric,text,text,date,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_update_ledger_entry(uuid,uuid,uuid,uuid,numeric,numeric,numeric,text,text,date,text,text,text) to service_role;

create or replace function public.admin_void_ledger_entry(p_actor_id uuid,p_entry_id uuid,p_reason text)
returns public.ledger_entries language plpgsql security definer set search_path=public,private,pg_temp as $$
declare old public.ledger_entries; result public.ledger_entries;
begin
  perform private.require_staff(p_actor_id);
  if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  if coalesce(btrim(p_reason),'')='' then raise exception 'void reason required'; end if;
  select * into old from public.ledger_entries where id=p_entry_id for update;
  if not found or old.is_voided then raise exception 'ledger entry unavailable'; end if;
  update public.ledger_entries set is_voided=true,status=case when status='active' then 'released' else 'reversed' end,voided_at=now(),voided_by=p_actor_id,void_reason=btrim(p_reason),updated_at=now() where id=p_entry_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,old_data,new_data) values(p_actor_id,'ledger_entry_voided','ledger_entry',p_entry_id::text,to_jsonb(old)-'id',jsonb_build_object('reason',p_reason));
  return result;
end; $$;
revoke all on function public.admin_void_ledger_entry(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.admin_void_ledger_entry(uuid,uuid,text) to service_role;

create or replace function public.admin_update_withdrawal_request(p_actor_id uuid,p_request_id uuid,p_upi_account_id uuid,p_amount_usdt numeric,p_rate numeric,p_destination_address text,p_status text,p_proof_tx_hash text,p_proof_url text,p_proof_note text,p_reason text)
returns public.withdrawal_requests language plpgsql security definer set search_path=public,private,pg_temp as $$
declare old public.withdrawal_requests; result public.withdrawal_requests; new_amount_inr numeric; old_counted numeric:=0; available numeric:=0; new_status text;
begin
  perform private.require_staff(p_actor_id);
  if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  select * into old from public.withdrawal_requests where id=p_request_id for update;
  if not found or old.is_voided then raise exception 'withdrawal request unavailable'; end if;
  if p_amount_usdt is null or p_amount_usdt<=0 or p_rate is null or p_rate<=0 or coalesce(btrim(p_destination_address),'')='' then raise exception 'valid withdrawal details required'; end if;
  if p_upi_account_id is not null and (old.provider_id is null or not exists(select 1 from public.provider_upi_accounts where id=p_upi_account_id and provider_id=old.provider_id and status<>'deleted')) then raise exception 'UPI account does not belong to provider'; end if;
  new_status:=coalesce(nullif(btrim(p_status),''),old.status);
  if new_status not in ('pending','paid','rejected','cancelled') then raise exception 'invalid withdrawal status'; end if;
  new_amount_inr:=round(p_amount_usdt*p_rate,2);
  old_counted:=case when old.status in ('pending','paid') and not old.is_voided then old.amount_inr else 0 end;
  if new_status in ('pending','paid') then
    if old.requester_type='provider' then select commission_earned_inr into available from public.accounting_for_provider(old.provider_id);
    else available:=public.merchant_available_balance_inr(); end if;
    if new_amount_inr > available + old_counted then raise exception 'corrected withdrawal exceeds available balance'; end if;
  end if;
  update public.withdrawal_requests set upi_account_id=p_upi_account_id,amount_usdt=p_amount_usdt,rate=p_rate,amount_inr=new_amount_inr,destination_address=btrim(p_destination_address),status=new_status,proof_tx_hash=nullif(btrim(p_proof_tx_hash),''),proof_url=nullif(btrim(p_proof_url),''),proof_note=p_proof_note,paid_at=case when new_status='paid' then coalesce(old.paid_at,now()) else null end,paid_by=case when new_status='paid' then coalesce(old.paid_by,p_actor_id) else null end,edited_at=now(),edited_by=p_actor_id,edit_reason=nullif(btrim(p_reason),'' ) where id=p_request_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,old_data,new_data) values(p_actor_id,'withdrawal_request_edited','withdrawal_request',p_request_id::text,to_jsonb(old)-'id',jsonb_build_object('amount_usdt',p_amount_usdt,'rate',p_rate,'amount_inr',new_amount_inr,'status',new_status,'upi_account_id',p_upi_account_id,'reason',p_reason));
  return result;
end; $$;
revoke all on function public.admin_update_withdrawal_request(uuid,uuid,uuid,numeric,numeric,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.admin_update_withdrawal_request(uuid,uuid,uuid,numeric,numeric,text,text,text,text,text,text) to service_role;

create or replace function public.admin_void_withdrawal_request(p_actor_id uuid,p_request_id uuid,p_reason text)
returns public.withdrawal_requests language plpgsql security definer set search_path=public,private,pg_temp as $$
declare old public.withdrawal_requests; result public.withdrawal_requests;
begin
  perform private.require_staff(p_actor_id);
  if not exists(select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  if coalesce(btrim(p_reason),'')='' then raise exception 'void reason required'; end if;
  select * into old from public.withdrawal_requests where id=p_request_id for update;
  if not found or old.is_voided then raise exception 'withdrawal request unavailable'; end if;
  update public.withdrawal_requests set is_voided=true,status='cancelled',voided_at=now(),voided_by=p_actor_id,void_reason=btrim(p_reason) where id=p_request_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,old_data,new_data) values(p_actor_id,'withdrawal_request_voided','withdrawal_request',p_request_id::text,to_jsonb(old)-'id',jsonb_build_object('reason',p_reason));
  return result;
end; $$;
revoke all on function public.admin_void_withdrawal_request(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.admin_void_withdrawal_request(uuid,uuid,text) to service_role;
