create or replace function public.admin_upsert_portal_account(p_actor_id uuid,p_role text,p_provider_id uuid default null,p_login_id text default null,p_password text default null)
returns table(id uuid,role text,provider_id uuid,login_id text,is_active boolean,last_login_at timestamptz,password text)
language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
declare acct public.portal_accounts; generated text; lid text; hashed text;
begin
  perform private.require_staff(p_actor_id);
  if p_role not in ('merchant','user','agent') then raise exception 'invalid portal role'; end if;
  if p_role='user' and p_provider_id is null then raise exception 'provider is required'; end if;
  if p_role<>'user' then p_provider_id := null; end if;
  if p_role='user' then select p.user_code into lid from public.providers p where p.id=p_provider_id; else lid := p_role; end if;
  lid := coalesce(nullif(btrim(p_login_id),''),lid);
  generated := coalesce(nullif(p_password,''),substr(replace(encode(gen_random_bytes(18),'base64'),'/','9'),1,20));
  hashed := crypt(generated, gen_salt('bf', 12));
  select pa.* into acct from public.portal_accounts pa where pa.role=p_role and ((p_role='user' and pa.provider_id=p_provider_id) or (p_role<>'user' and pa.provider_id is null));
  if found then
    update public.portal_accounts pa set login_id=lid,password_hash=hashed,is_active=true,updated_at=now() where pa.id=acct.id returning pa.* into acct;
  else
    insert into public.portal_accounts(role,provider_id,login_id,password_hash,created_by) values(p_role,p_provider_id,lid,hashed,p_actor_id) returning * into acct;
  end if;
  return query select acct.id,acct.role,acct.provider_id,acct.login_id,acct.is_active,acct.last_login_at,generated;
end; $$;
