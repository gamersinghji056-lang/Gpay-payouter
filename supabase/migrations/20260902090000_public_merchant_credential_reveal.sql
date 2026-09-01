create or replace function public.reveal_upi_gpay_password_by_share(p_token text,p_upi_account_id uuid,p_encryption_key text)
returns text language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
declare cipher text; result text;
begin
  if not exists(select 1 from public.share_links where scope='merchant' and is_active and expires_at is null and (public_token=p_token or token_hash=encode(extensions.digest(p_token,'sha256'),'hex'))) then raise exception 'merchant share link is invalid or revoked'; end if;
  if not exists(select 1 from public.provider_upi_accounts a join public.providers p on p.id=a.provider_id where a.id=p_upi_account_id and a.status='active' and a.merchant_operational and p.status='active' and p.is_active) then raise exception 'UPI account is unavailable'; end if;
  select gpay_password_ciphertext into cipher from private.provider_upi_credentials where upi_account_id=p_upi_account_id;
  if cipher is null then raise exception 'credential not configured'; end if;
  result:=extensions.pgp_sym_decrypt(decode(cipher,'base64'),p_encryption_key);
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('merchant_upi_gpay_password_revealed','provider_upi_account',p_upi_account_id::text,jsonb_build_object('scope','merchant'));
  return result;
end; $$;
revoke all on function public.reveal_upi_gpay_password_by_share(text,uuid,text) from public,anon,authenticated;
grant execute on function public.reveal_upi_gpay_password_by_share(text,uuid,text) to service_role;

create or replace function public.set_upi_gpay_credentials_by_share(p_token text,p_upi_account_id uuid,p_password text,p_encryption_key text)
returns void language plpgsql security definer set search_path=public,private,extensions,pg_temp as $$
begin
  if not exists(select 1 from public.share_links where scope='user' and is_active and expires_at is null and (public_token=p_token or token_hash=encode(extensions.digest(p_token,'sha256'),'hex')) and provider_id=(select provider_id from public.provider_upi_accounts where id=p_upi_account_id)) then raise exception 'user share link is invalid or revoked'; end if;
  if p_password is null or length(p_password)<1 or p_encryption_key is null or length(p_encryption_key)<16 then raise exception 'credential input is invalid'; end if;
  insert into private.provider_upi_credentials(upi_account_id,gpay_password_ciphertext,updated_by) values(p_upi_account_id,encode(extensions.pgp_sym_encrypt(p_password,p_encryption_key,'cipher-algo=aes256'),'base64'),null) on conflict(upi_account_id) do update set gpay_password_ciphertext=excluded.gpay_password_ciphertext,updated_by=null,updated_at=now();
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('user_upi_gpay_credentials_updated','provider_upi_account',p_upi_account_id::text,jsonb_build_object('scope','user'));
end; $$;
revoke all on function public.set_upi_gpay_credentials_by_share(text,uuid,text,text) from public,anon,authenticated;
grant execute on function public.set_upi_gpay_credentials_by_share(text,uuid,text,text) to service_role;
