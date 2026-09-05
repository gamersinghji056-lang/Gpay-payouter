alter table public.deposit_requests add column if not exists expires_at timestamptz;
update public.deposit_requests set expires_at = created_at + interval '5 minutes' where expires_at is null;
alter table public.deposit_requests alter column expires_at set default now() + interval '5 minutes';
alter table public.deposit_requests alter column expires_at set not null;
alter table public.deposit_requests drop constraint if exists deposit_requests_status_check;

do $$
declare constraint_name text;
begin
  for constraint_name in
    select conname
    from pg_constraint
    where conrelid='public.deposit_requests'::regclass
      and contype='c'
      and pg_get_constraintdef(oid) like '%status%'
      and pg_get_constraintdef(oid) like '%waiting%'
      and pg_get_constraintdef(oid) like '%confirmed%'
  loop
    execute format('alter table public.deposit_requests drop constraint %I', constraint_name);
  end loop;
end $$;

alter table public.deposit_requests add constraint deposit_requests_status_check
check (status in ('waiting','checking','confirmed','failed','expired'));

create index if not exists deposit_requests_watch_idx
on public.deposit_requests (status, destination_address, created_at, expires_at);

create or replace function public.create_deposit_by_share(p_share_link_id uuid, p_provider_id uuid, p_requested_usdt numeric)
returns public.deposit_requests language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.deposit_requests; rate numeric; address text; provider_status text; provider_active boolean; provider_mode text; pause_reason text;
begin
  if not exists (select 1 from public.share_links where id=p_share_link_id and scope='user' and provider_id=p_provider_id and is_active and (expires_at is null or expires_at>now())) then raise exception 'user share link is invalid or revoked'; end if;
  select p.status,p.is_active,p.funding_model,p.pause_reason,
    coalesce(nullif(btrim(p.unique_deposit_address),''),nullif(btrim(s.admin_trc20_address),''))
  into provider_status,provider_active,provider_mode,pause_reason,address
  from public.providers p cross join public.app_settings s
  where p.id=p_provider_id and s.id;
  if not found or not provider_active or provider_status='deleted' then raise exception 'provider is unavailable'; end if;
  if provider_status='paused' then raise exception 'Provider is paused: %', coalesce(pause_reason,'temporarily unavailable'); end if;
  if provider_mode <> 'deposit' then raise exception 'deposit not allowed for this provider'; end if;
  if p_requested_usdt is null or p_requested_usdt <= 0 then raise exception 'invalid deposit amount'; end if;
  if address is null then raise exception 'Deposit address is not configured'; end if;
  select round(s.deposit_base_rate*(1+s.deposit_markup_pct/100),6) into rate from public.app_settings s where s.id;
  insert into public.deposit_requests(provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,created_by,expires_at)
  values(p_provider_id,p_requested_usdt,p_requested_usdt,rate,round(p_requested_usdt*rate,2),address,null,now()+interval '5 minutes') returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('shared_deposit_created','deposit_request',result.id::text,jsonb_build_object('share_link_id',p_share_link_id,'provider_id',p_provider_id,'amount_usdt',p_requested_usdt,'expires_at',result.expires_at));
  return result;
end; $$;

create or replace function public.create_deposit_by_portal(p_account_id uuid, p_requested_usdt numeric)
returns public.deposit_requests language plpgsql security definer set search_path=public,private,pg_temp as $$
declare acct public.portal_accounts; result public.deposit_requests; rate numeric; address text; provider public.providers;
begin
  select * into acct from public.portal_accounts where id=p_account_id and role='user' and is_active;
  if not found then raise exception 'user authorization required'; end if;
  select * into provider from public.providers where id=acct.provider_id and is_active and status='active';
  if not found then raise exception 'provider is unavailable'; end if;
  if provider.funding_model <> 'deposit' then raise exception 'deposit not allowed for this provider'; end if;
  if p_requested_usdt is null or p_requested_usdt <= 0 then raise exception 'invalid deposit amount'; end if;
  select round(s.deposit_base_rate*(1+s.deposit_markup_pct/100),6),
    coalesce(nullif(btrim(provider.unique_deposit_address),''),nullif(btrim(s.admin_trc20_address),''))
  into rate,address from public.app_settings s where s.id;
  if address is null then raise exception 'Deposit address is not configured'; end if;
  insert into public.deposit_requests(provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,created_by,expires_at)
  values(provider.id,p_requested_usdt,p_requested_usdt,rate,round(p_requested_usdt*rate,2),address,null,now()+interval '5 minutes') returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('portal_deposit_created','deposit_request',result.id::text,jsonb_build_object('portal_account_id',p_account_id,'provider_id',provider.id,'amount_usdt',p_requested_usdt,'expires_at',result.expires_at));
  return result;
end; $$;
