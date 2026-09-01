create or replace function public.create_deposit_by_share(p_share_link_id uuid, p_provider_id uuid, p_requested_usdt numeric)
returns public.deposit_requests language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.deposit_requests; rate numeric; provider_address text; provider_status text; provider_active boolean; provider_mode text; pause_reason text;
begin
  if not exists (select 1 from public.share_links where id=p_share_link_id and scope='user' and provider_id=p_provider_id and is_active and (expires_at is null or expires_at>now())) then raise exception 'user share link is invalid or revoked'; end if;
  select p.status,p.is_active,p.funding_model,p.pause_reason,p.unique_deposit_address into provider_status,provider_active,provider_mode,pause_reason,provider_address from public.providers p where p.id=p_provider_id;
  if not found or not provider_active or provider_status='deleted' then raise exception 'provider is unavailable'; end if;
  if provider_status='paused' then raise exception 'Provider is paused: %', coalesce(pause_reason,'temporarily unavailable'); end if;
  if provider_mode <> 'deposit' then raise exception 'deposit not allowed for this provider'; end if;
  if p_requested_usdt is null or p_requested_usdt <= 0 then raise exception 'invalid deposit amount'; end if;
  select s.deposit_base_rate*(1+s.deposit_markup_pct/100), coalesce(provider_address,s.admin_trc20_address) into rate,provider_address from public.app_settings s where s.id;
  if provider_address is null or btrim(provider_address)='' then raise exception 'TRC20 address is not configured'; end if;
  insert into public.deposit_requests(provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,created_by)
  values(p_provider_id,p_requested_usdt,p_requested_usdt,rate,round(p_requested_usdt*rate,2),provider_address,null) returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('shared_deposit_created','deposit_request',result.id::text,jsonb_build_object('share_link_id',p_share_link_id,'provider_id',p_provider_id,'amount_usdt',p_requested_usdt));
  return result;
end; $$;
revoke all on function public.create_deposit_by_share(uuid,uuid,numeric) from public, anon, authenticated;
grant execute on function public.create_deposit_by_share(uuid,uuid,numeric) to service_role;
