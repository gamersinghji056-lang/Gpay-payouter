create or replace function public.confirm_deposit(p_actor_id uuid, p_deposit_id uuid, p_tx_hash text, p_source text default 'blockchain')
returns public.deposit_requests language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.deposit_requests; duplicate_id uuid;
begin
  if current_setting('request.jwt.claim.role', true) is distinct from 'service_role' then
    perform private.require_staff(p_actor_id);
  end if;
  if p_tx_hash is null or length(trim(p_tx_hash)) < 10 then raise exception 'valid transaction hash required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(trim(p_tx_hash), 0));
  select * into result from public.deposit_requests where id=p_deposit_id for update;
  if not found then raise exception 'deposit not found'; end if;
  if result.status='confirmed' then
    if result.tx_hash=trim(p_tx_hash) then return result; end if;
    raise exception 'deposit already confirmed with another transaction';
  end if;
  select id into duplicate_id from public.deposit_requests where tx_hash=trim(p_tx_hash) and id<>p_deposit_id limit 1;
  if duplicate_id is not null then raise exception 'transaction already credited'; end if;
  update public.deposit_requests set status='confirmed',tx_hash=trim(p_tx_hash),confirmed_at=now(),source=p_source where id=p_deposit_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data)
  values(p_actor_id,'deposit_confirmed','deposit_request',result.id::text,jsonb_build_object('tx_hash',result.tx_hash,'source',p_source));
  return result;
end; $$;
revoke all on function public.confirm_deposit(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.confirm_deposit(uuid,uuid,text,text) to service_role;
