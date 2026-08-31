create or replace function public.post_collection_by_share(
  p_share_link_id uuid, p_provider_id uuid, p_amount_inr numeric, p_bank_name text,
  p_account_number text, p_transaction_date date, p_note text default null, p_idempotency_key text default null
) returns public.ledger_entries
language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.ledger_entries; a record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_provider_id::text, 0));
  if not exists (select 1 from public.share_links where id=p_share_link_id and scope='merchant' and is_active and (expires_at is null or expires_at>now())) then raise exception 'merchant share link is invalid or revoked'; end if;
  if not exists (select 1 from public.providers where id=p_provider_id and is_active) then raise exception 'active provider not found'; end if;
  if p_amount_inr <= 0 then raise exception 'positive collection amount required'; end if;
  select * into a from public.accounting_for_provider(p_provider_id);
  if p_amount_inr > a.collection_capacity_inr then raise exception 'collection exceeds available capacity'; end if;
  insert into public.ledger_entries(provider_id,entry_type,amount_inr,bank_name,account_number,transaction_date,note,status,idempotency_key)
  values(p_provider_id,'collection',p_amount_inr,p_bank_name,p_account_number,p_transaction_date,p_note,'posted',p_idempotency_key)
  on conflict (idempotency_key) do update set updated_at=now() returning * into result;
  update public.share_links set last_accessed_at=now() where id=p_share_link_id;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('shared_collection_posted','ledger_entry',result.id::text,jsonb_build_object('share_link_id',p_share_link_id,'provider_id',p_provider_id,'amount_inr',p_amount_inr));
  return result;
end; $$;
revoke all on function public.post_collection_by_share(uuid,uuid,numeric,text,text,date,text,text) from public, anon, authenticated;
grant execute on function public.post_collection_by_share(uuid,uuid,numeric,text,text,date,text,text) to service_role;

create or replace function public.correct_collection_by_share(p_share_link_id uuid, p_entry_id uuid, p_amount_inr numeric, p_note text default null)
returns public.ledger_entries language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.ledger_entries; a record; old_amount numeric;
begin
  perform pg_advisory_xact_lock(hashtextextended((select provider_id::text from public.ledger_entries where id=p_entry_id), 0));
  if not exists (select 1 from public.share_links where id=p_share_link_id and scope='merchant' and is_active and (expires_at is null or expires_at>now())) then raise exception 'merchant share link is invalid or revoked'; end if;
  select amount_inr into old_amount from public.ledger_entries where id=p_entry_id and entry_type='collection' and status='posted';
  if old_amount is null or p_amount_inr < 0 then raise exception 'collection entry unavailable'; end if;
  select * into a from public.accounting_for_provider((select provider_id from public.ledger_entries where id=p_entry_id));
  if p_amount_inr > a.collection_capacity_inr + old_amount then raise exception 'corrected collection exceeds available capacity'; end if;
  update public.ledger_entries set amount_inr=p_amount_inr,note=coalesce(note,'')||case when p_note is null then '' else ' Correction: '||p_note end,updated_at=now() where id=p_entry_id returning * into result;
  update public.share_links set last_accessed_at=now() where id=p_share_link_id;
  insert into public.audit_logs(action,entity_type,entity_id,old_data,new_data) values('shared_collection_corrected','ledger_entry',result.id::text,jsonb_build_object('amount_inr',old_amount),jsonb_build_object('amount_inr',p_amount_inr,'share_link_id',p_share_link_id));
  return result;
end; $$;
revoke all on function public.correct_collection_by_share(uuid,uuid,numeric,text) from public, anon, authenticated;
grant execute on function public.correct_collection_by_share(uuid,uuid,numeric,text) to service_role;

create or replace function public.create_deposit_by_share(p_share_link_id uuid, p_provider_id uuid, p_requested_usdt numeric)
returns public.deposit_requests language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.deposit_requests; rate numeric; address text;
begin
  if not exists (select 1 from public.share_links where id=p_share_link_id and scope='user' and provider_id=p_provider_id and is_active and (expires_at is null or expires_at>now())) then raise exception 'user share link is invalid or revoked'; end if;
  select deposit_base_rate*(1+deposit_markup_pct/100), coalesce((select unique_deposit_address from public.providers where id=p_provider_id),(select admin_trc20_address from public.app_settings where id)) into rate,address from public.app_settings where id;
  if address is null or address='' or p_requested_usdt<=0 then raise exception 'deposit request is invalid or address is not configured'; end if;
  insert into public.deposit_requests(provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,created_by) values(p_provider_id,p_requested_usdt,p_requested_usdt,rate,round(p_requested_usdt*rate,2),address,null) returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('shared_deposit_created','deposit_request',result.id::text,jsonb_build_object('share_link_id',p_share_link_id,'provider_id',p_provider_id,'amount_usdt',p_requested_usdt));
  return result;
end; $$;
revoke all on function public.create_deposit_by_share(uuid,uuid,numeric) from public, anon, authenticated;
grant execute on function public.create_deposit_by_share(uuid,uuid,numeric) to service_role;
