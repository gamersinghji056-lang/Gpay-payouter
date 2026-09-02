create or replace function public.portal_create_session(p_role text,p_login_id text,p_password text)
returns table(token text, account_id uuid, role text, provider_id uuid)
language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
declare acct public.portal_accounts; raw text;
begin
  select pa.* into acct from public.portal_accounts pa where pa.login_id=p_login_id and pa.role=p_role and pa.is_active;
  if not found or acct.password_hash <> crypt(p_password, acct.password_hash) then raise exception 'invalid login credentials'; end if;
  raw := encode(gen_random_bytes(32),'hex');
  insert into private.portal_sessions(account_id,token_hash) values(acct.id,encode(digest(raw,'sha256'),'hex'));
  update public.portal_accounts pa set last_login_at=now(),updated_at=now() where pa.id=acct.id;
  return query select raw,acct.id,acct.role,acct.provider_id;
end; $$;
