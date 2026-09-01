create or replace function public.post_collection_by_share(
  p_share_link_id uuid,p_provider_id uuid,p_amount_inr numeric,p_bank_name text,
  p_account_number text,p_transaction_date date,p_note text default null,
  p_idempotency_key text default null,p_upi_account_id uuid default null
) returns public.ledger_entries
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.ledger_entries; a record; provider public.providers; account public.provider_upi_accounts; available numeric;
begin
  perform pg_advisory_xact_lock(hashtextextended(coalesce(p_upi_account_id,p_provider_id)::text,0));
  if not exists(select 1 from public.share_links where id=p_share_link_id and scope='merchant' and is_active and (expires_at is null or expires_at>now())) then raise exception 'merchant share link is invalid or revoked'; end if;
  if p_idempotency_key is not null then select * into result from public.ledger_entries where idempotency_key=p_idempotency_key; if found then return result; end if; end if;
  select * into provider from public.providers where id=p_provider_id and is_active and status='active';
  if not found then raise exception 'active provider not found'; end if;
  if p_upi_account_id is not null then
    select * into account from public.provider_upi_accounts where id=p_upi_account_id and provider_id=p_provider_id and status='active' and merchant_operational for update;
    if not found then raise exception 'UPI account is paused or unavailable'; end if;
    select * into a from public.accounting_for_upi(p_upi_account_id); available:=a.available_limit_inr;
  else
    select * into a from public.accounting_for_provider(p_provider_id); available:=a.collection_capacity_inr;
  end if;
  if p_amount_inr is null or p_amount_inr<=0 then raise exception 'positive collection amount required'; end if;
  if provider.funding_model='commission' and coalesce(provider.commission_limit_inr,0)<=0 and p_upi_account_id is null then raise exception 'Collection limit not configured'; end if;
  if p_amount_inr > coalesce(available,0) then raise exception 'collection exceeds available limit'; end if;
  insert into public.ledger_entries(provider_id,upi_account_id,entry_type,amount_inr,bank_name,account_number,transaction_date,note,status,idempotency_key)
  values(p_provider_id,p_upi_account_id,'collection',p_amount_inr,p_bank_name,p_account_number,p_transaction_date,p_note,'posted',p_idempotency_key) returning * into result;
  update public.share_links set last_accessed_at=now() where id=p_share_link_id;
  return result;
end; $$;
revoke all on function public.post_collection_by_share(uuid,uuid,numeric,text,text,date,text,text,uuid) from public,anon,authenticated;
grant execute on function public.post_collection_by_share(uuid,uuid,numeric,text,text,date,text,text,uuid) to service_role;

create or replace function public.set_upi_operational_status(p_actor_id uuid,p_upi_account_id uuid,p_operational boolean)
returns public.provider_upi_accounts language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.provider_upi_accounts;
begin
  perform private.require_staff(p_actor_id);
  update public.provider_upi_accounts set merchant_operational=p_operational,updated_at=now() where id=p_upi_account_id and status<>'deleted' returning * into result;
  if not found then raise exception 'UPI account not found'; end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'upi_operational_status_changed','provider_upi_account',p_upi_account_id::text,jsonb_build_object('merchant_operational',p_operational));
  return result;
end; $$;
revoke all on function public.set_upi_operational_status(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.set_upi_operational_status(uuid,uuid,boolean) to service_role;
