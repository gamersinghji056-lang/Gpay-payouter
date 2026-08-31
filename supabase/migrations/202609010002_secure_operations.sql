create or replace function private.require_staff(p_actor_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.profiles where id=p_actor_id and role in ('admin','operator')) then
    raise exception 'staff authorization required';
  end if;
end; $$;
revoke all on function private.require_staff(uuid) from public;
grant execute on function private.require_staff(uuid) to service_role;

create or replace function public.post_ledger_entry(
  p_actor_id uuid, p_provider_id uuid, p_entry_type text, p_amount_inr numeric default null,
  p_amount_usdt numeric default null, p_rate numeric default null, p_bank_name text default null,
  p_account_number text default null, p_transaction_date date default current_date, p_reference_no text default null,
  p_note text default null, p_status text default 'posted', p_idempotency_key text default null
) returns public.ledger_entries
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.ledger_entries; a record; effective_amount numeric;
begin
  perform private.require_staff(p_actor_id);
  perform pg_advisory_xact_lock(hashtextextended(p_provider_id::text, 0));
  if p_idempotency_key is not null then
    select * into result from public.ledger_entries where idempotency_key=p_idempotency_key;
    if found then return result; end if;
  end if;
  if not exists (select 1 from public.providers where id=p_provider_id and is_active) then raise exception 'active provider not found'; end if;
  if p_entry_type not in ('collection','inr_received','user_usdt','merchant_usdt','frozen') then raise exception 'invalid ledger type'; end if;
  if p_entry_type in ('collection','inr_received','frozen') and coalesce(p_amount_inr,0) <= 0 then raise exception 'positive INR amount required'; end if;
  if p_entry_type in ('user_usdt','merchant_usdt') and (coalesce(p_amount_usdt,0) <= 0 or coalesce(p_rate,0) <= 0) then raise exception 'positive USDT and rate required'; end if;
  if p_entry_type='collection' then
    select * into a from public.accounting_for_provider(p_provider_id);
    effective_amount := a.collection_capacity_inr;
    if p_amount_inr > effective_amount then raise exception 'collection exceeds available capacity'; end if;
  end if;
  insert into public.ledger_entries(provider_id,entry_type,amount_inr,amount_usdt,rate,bank_name,account_number,transaction_date,reference_no,note,status,created_by,idempotency_key)
  values (p_provider_id,p_entry_type,p_amount_inr,p_amount_usdt,p_rate,p_bank_name,p_account_number,p_transaction_date,p_reference_no,p_note,p_status,p_actor_id,p_idempotency_key)
  returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data)
  values (p_actor_id,'ledger_entry_posted','ledger_entry',result.id::text,jsonb_build_object('provider_id',p_provider_id,'entry_type',p_entry_type,'amount_inr',p_amount_inr,'amount_usdt',p_amount_usdt));
  return result;
end; $$;
revoke all on function public.post_ledger_entry(uuid,uuid,text,numeric,numeric,numeric,text,text,date,text,text,text,text) from public, anon, authenticated;
grant execute on function public.post_ledger_entry(uuid,uuid,text,numeric,numeric,numeric,text,text,date,text,text,text,text) to service_role;

create or replace function public.create_deposit_request(p_actor_id uuid, p_provider_id uuid, p_requested_usdt numeric)
returns public.deposit_requests language plpgsql security definer set search_path = public, pg_temp as $$
declare result public.deposit_requests; rate numeric; address text;
begin
  if not exists (select 1 from public.providers where id=p_provider_id and created_by=p_actor_id and is_active and funding_model='deposit') then raise exception 'deposit provider access denied'; end if;
  select deposit_base_rate*(1+deposit_markup_pct/100), coalesce((select unique_deposit_address from public.providers where id=p_provider_id),(select admin_trc20_address from public.app_settings where id)) into rate,address from public.app_settings where id;
  if address is null or address='' then raise exception 'TRC20 address is not configured'; end if;
  insert into public.deposit_requests(provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,created_by)
  values(p_provider_id,p_requested_usdt,p_requested_usdt,rate,round(p_requested_usdt*rate,2),address,p_actor_id) returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'deposit_created','deposit_request',result.id::text,jsonb_build_object('provider_id',p_provider_id,'amount_usdt',p_requested_usdt));
  return result;
end; $$;
revoke all on function public.create_deposit_request(uuid,uuid,numeric) from public, anon, authenticated;
grant execute on function public.create_deposit_request(uuid,uuid,numeric) to service_role;

create or replace function public.confirm_deposit(p_actor_id uuid, p_deposit_id uuid, p_tx_hash text, p_source text default 'blockchain')
returns public.deposit_requests language plpgsql security definer set search_path = public, pg_temp as $$
declare result public.deposit_requests;
begin
  perform private.require_staff(p_actor_id);
  if p_tx_hash is null or length(trim(p_tx_hash)) < 10 then raise exception 'valid transaction hash required'; end if;
  update public.deposit_requests set status='confirmed',tx_hash=trim(p_tx_hash),confirmed_at=now(),source=p_source where id=p_deposit_id and status <> 'confirmed' returning * into result;
  if not found then raise exception 'deposit unavailable or already confirmed'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'deposit_confirmed','deposit_request',result.id::text,jsonb_build_object('tx_hash',result.tx_hash,'source',p_source));
  return result;
end; $$;
revoke all on function public.confirm_deposit(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.confirm_deposit(uuid,uuid,text,text) to service_role;

create or replace function public.create_share_link(p_actor_id uuid, p_scope text, p_provider_id uuid default null, p_expires_at timestamptz default null)
returns table (id uuid, token text) language plpgsql security definer set search_path = public, pg_temp as $$
declare raw_token text; link_id uuid;
begin
  perform private.require_staff(p_actor_id);
  if p_scope not in ('merchant','agent','user') then raise exception 'invalid share scope'; end if;
  update public.share_links set is_active=false,revoked_at=coalesce(revoked_at,now()) where is_active and scope=p_scope and ((p_scope='user' and provider_id=p_provider_id) or (p_scope in ('merchant','agent') and provider_id is null));
  raw_token := encode(gen_random_bytes(32),'base64url');
  insert into public.share_links(scope,provider_id,token_hash,created_by,expires_at) values(p_scope,p_provider_id,encode(digest(raw_token,'sha256'),'hex'),p_actor_id,p_expires_at) returning share_links.id into link_id;
  return query select link_id,raw_token;
end; $$;
revoke all on function public.create_share_link(uuid,text,uuid,timestamptz) from public, anon, authenticated;
grant execute on function public.create_share_link(uuid,text,uuid,timestamptz) to service_role;

create or replace function public.revoke_share_link(p_actor_id uuid, p_link_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform private.require_staff(p_actor_id);
  update public.share_links set is_active=false,revoked_at=coalesce(revoked_at,now()) where id=p_link_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(p_actor_id,'share_revoked','share_link',p_link_id::text);
end; $$;
revoke all on function public.revoke_share_link(uuid,uuid) from public, anon, authenticated;
grant execute on function public.revoke_share_link(uuid,uuid) to service_role;
