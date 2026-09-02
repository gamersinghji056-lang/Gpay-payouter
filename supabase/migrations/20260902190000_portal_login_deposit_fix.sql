create extension if not exists pgcrypto with schema extensions;

create table if not exists public.portal_accounts (
  id uuid primary key default gen_random_uuid(),
  role text not null check (role in ('merchant','user','agent')),
  provider_id uuid references public.providers(id) on delete cascade,
  login_id text not null unique,
  password_hash text not null,
  is_active boolean not null default true,
  last_login_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((role='user' and provider_id is not null) or (role in ('merchant','agent') and provider_id is null))
);

create table if not exists private.portal_sessions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.portal_accounts(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null default now() + interval '30 days',
  created_at timestamptz not null default now(),
  last_seen_at timestamptz
);

alter table public.portal_accounts enable row level security;
drop policy if exists portal_accounts_staff_all on public.portal_accounts;
create policy portal_accounts_staff_all on public.portal_accounts for all to authenticated
  using (private.current_role() in ('admin','operator'))
  with check (private.current_role() in ('admin','operator'));

alter table public.provider_upi_accounts add column if not exists bank_name text;
alter table public.provider_upi_accounts add column if not exists bank_account_number text;
alter table public.provider_upi_accounts add column if not exists account_holder_name text;
alter table public.provider_upi_accounts add column if not exists ifsc_code text;
alter table public.provider_upi_accounts add column if not exists bank_branch text;
alter table public.provider_upi_accounts add column if not exists account_note text;

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
  insert into public.deposit_requests(provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,created_by)
  values(p_provider_id,p_requested_usdt,p_requested_usdt,rate,round(p_requested_usdt*rate,2),address,null) returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('shared_deposit_created','deposit_request',result.id::text,jsonb_build_object('share_link_id',p_share_link_id,'provider_id',p_provider_id,'amount_usdt',p_requested_usdt));
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
  insert into public.deposit_requests(provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,created_by)
  values(provider.id,p_requested_usdt,p_requested_usdt,rate,round(p_requested_usdt*rate,2),address,null) returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('portal_deposit_created','deposit_request',result.id::text,jsonb_build_object('portal_account_id',p_account_id,'provider_id',provider.id,'amount_usdt',p_requested_usdt));
  return result;
end; $$;

create or replace function public.portal_create_session(p_role text,p_login_id text,p_password text)
returns table(token text, account_id uuid, role text, provider_id uuid)
language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
declare acct public.portal_accounts; raw text;
begin
  select * into acct from public.portal_accounts where login_id=p_login_id and role=p_role and is_active;
  if not found or acct.password_hash <> crypt(p_password, acct.password_hash) then raise exception 'invalid login credentials'; end if;
  raw := encode(gen_random_bytes(32),'hex');
  insert into private.portal_sessions(account_id,token_hash) values(acct.id,encode(digest(raw,'sha256'),'hex'));
  update public.portal_accounts set last_login_at=now(),updated_at=now() where id=acct.id;
  return query select raw,acct.id,acct.role,acct.provider_id;
end; $$;

create or replace function public.portal_account_from_token(p_token text)
returns public.portal_accounts language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
declare acct public.portal_accounts;
begin
  select a.* into acct from private.portal_sessions s join public.portal_accounts a on a.id=s.account_id
  where s.token_hash=encode(digest(p_token,'sha256'),'hex') and s.expires_at>now() and a.is_active;
  if not found then raise exception 'portal session is invalid or expired'; end if;
  update private.portal_sessions set last_seen_at=now() where token_hash=encode(digest(p_token,'sha256'),'hex');
  return acct;
end; $$;

create or replace function public.portal_logout(p_token text)
returns void language sql security definer set search_path=private,extensions,pg_temp as $$
  delete from private.portal_sessions where token_hash=encode(digest(p_token,'sha256'),'hex');
$$;

create or replace function public.admin_upsert_portal_account(p_actor_id uuid,p_role text,p_provider_id uuid default null,p_login_id text default null,p_password text default null)
returns table(id uuid,role text,provider_id uuid,login_id text,is_active boolean,last_login_at timestamptz,password text)
language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
declare acct public.portal_accounts; generated text; lid text; hashed text;
begin
  perform private.require_staff(p_actor_id);
  if p_role not in ('merchant','user','agent') then raise exception 'invalid portal role'; end if;
  if p_role='user' and p_provider_id is null then raise exception 'provider is required'; end if;
  if p_role<>'user' then p_provider_id := null; end if;
  if p_role='user' then select user_code into lid from public.providers where id=p_provider_id; else lid := p_role; end if;
  lid := coalesce(nullif(btrim(p_login_id),''),lid);
  generated := coalesce(nullif(p_password,''),substr(replace(encode(gen_random_bytes(18),'base64'),'/','9'),1,20));
  hashed := crypt(generated, gen_salt('bf', 12));
  select * into acct from public.portal_accounts where role=p_role and ((p_role='user' and provider_id=p_provider_id) or (p_role<>'user' and provider_id is null));
  if found then
    update public.portal_accounts set login_id=lid,password_hash=hashed,is_active=true,updated_at=now() where portal_accounts.id=acct.id returning * into acct;
  else
    insert into public.portal_accounts(role,provider_id,login_id,password_hash,created_by) values(p_role,p_provider_id,lid,hashed,p_actor_id) returning * into acct;
  end if;
  return query select acct.id,acct.role,acct.provider_id,acct.login_id,acct.is_active,acct.last_login_at,generated;
end; $$;

create or replace function public.admin_set_portal_account_status(p_actor_id uuid,p_account_id uuid,p_is_active boolean)
returns public.portal_accounts language plpgsql security definer set search_path=public,private,pg_temp as $$
declare acct public.portal_accounts;
begin
  perform private.require_staff(p_actor_id);
  update public.portal_accounts set is_active=p_is_active,updated_at=now() where id=p_account_id returning * into acct;
  if not found then raise exception 'portal account not found'; end if;
  return acct;
end; $$;

create or replace function public.request_usdt_withdrawal_by_portal(p_account_id uuid,p_amount_usdt numeric,p_destination_address text)
returns public.withdrawal_requests language plpgsql security definer set search_path=public,private,pg_temp as $$
declare acct public.portal_accounts; fake_share uuid; result public.withdrawal_requests; provider_id uuid; requester text;
begin
  select * into acct from public.portal_accounts where id=p_account_id and role in ('user','merchant') and is_active;
  if not found then raise exception 'portal authorization required'; end if;
  if acct.role='user' then
    provider_id := acct.provider_id; requester := 'provider';
    select id into fake_share from public.share_links where scope='user' and provider_id=provider_id and is_active and expires_at is null order by created_at desc limit 1;
    if fake_share is null then insert into public.share_links(scope,provider_id,token_hash,public_token) values('user',provider_id,encode(extensions.digest(extensions.gen_random_bytes(32),'sha256'),'hex'),encode(extensions.gen_random_bytes(24),'hex')) returning id into fake_share; end if;
  else
    requester := 'merchant';
    select id into fake_share from public.share_links where scope='merchant' and is_active and expires_at is null order by created_at desc limit 1;
    if fake_share is null then insert into public.share_links(scope,provider_id,token_hash,public_token) values('merchant',null,encode(extensions.digest(extensions.gen_random_bytes(32),'sha256'),'hex'),encode(extensions.gen_random_bytes(24),'hex')) returning id into fake_share; end if;
  end if;
  select * into result from public.request_usdt_withdrawal(fake_share,provider_id,requester,p_amount_usdt,p_destination_address);
  return result;
end; $$;

create or replace function public.set_upi_bank_fields(p_actor_id uuid,p_upi_account_id uuid,p_bank_name text,p_bank_account_number text,p_account_holder_name text,p_ifsc_code text default null,p_bank_branch text default null,p_account_note text default null)
returns public.provider_upi_accounts language plpgsql security definer set search_path=public,private,pg_temp as $$
declare result public.provider_upi_accounts;
begin
  perform private.require_staff(p_actor_id);
  update public.provider_upi_accounts set bank_name=nullif(btrim(p_bank_name),''),bank_account_number=nullif(btrim(p_bank_account_number),''),account_holder_name=nullif(btrim(p_account_holder_name),''),ifsc_code=nullif(btrim(p_ifsc_code),''),bank_branch=nullif(btrim(p_bank_branch),''),account_note=nullif(btrim(p_account_note),''),updated_at=now() where id=p_upi_account_id and status<>'deleted' returning * into result;
  if not found then raise exception 'UPI account not found'; end if;
  return result;
end; $$;

create or replace function public.set_upi_gpay_credentials_by_portal(p_account_id uuid,p_upi_account_id uuid,p_password text,p_encryption_key text)
returns void language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
declare acct public.portal_accounts;
begin
  select * into acct from public.portal_accounts where id=p_account_id and role='user' and is_active;
  if not found then raise exception 'user authorization required'; end if;
  if not exists(select 1 from public.provider_upi_accounts where id=p_upi_account_id and provider_id=acct.provider_id and status<>'deleted') then raise exception 'UPI account not found'; end if;
  insert into private.provider_upi_credentials(upi_account_id,gpay_password_ciphertext,updated_by)
  values(p_upi_account_id,encode(extensions.pgp_sym_encrypt(p_password,p_encryption_key,'cipher-algo=aes256'),'base64'),null)
  on conflict(upi_account_id) do update set gpay_password_ciphertext=excluded.gpay_password_ciphertext,updated_by=null,updated_at=now();
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('portal_user_upi_gpay_credentials_updated','provider_upi_account',p_upi_account_id::text,jsonb_build_object('portal_account_id',p_account_id));
end; $$;

create or replace function public.reveal_upi_gpay_password_by_portal(p_account_id uuid,p_upi_account_id uuid,p_encryption_key text)
returns text language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
declare acct public.portal_accounts; cipher text; plain text;
begin
  select * into acct from public.portal_accounts where id=p_account_id and role='merchant' and is_active;
  if not found then raise exception 'merchant authorization required'; end if;
  if not exists(select 1 from public.provider_upi_accounts a join public.providers p on p.id=a.provider_id where a.id=p_upi_account_id and a.status='active' and a.merchant_operational and p.status='active' and p.is_active) then raise exception 'UPI account is unavailable'; end if;
  select gpay_password_ciphertext into cipher from private.provider_upi_credentials where upi_account_id=p_upi_account_id;
  if cipher is null then raise exception 'credential not configured'; end if;
  plain:=extensions.pgp_sym_decrypt(decode(cipher,'base64'),p_encryption_key);
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('portal_merchant_upi_gpay_password_revealed','provider_upi_account',p_upi_account_id::text,jsonb_build_object('portal_account_id',p_account_id));
  return plain;
end; $$;
