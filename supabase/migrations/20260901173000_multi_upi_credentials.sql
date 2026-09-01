create table if not exists private.provider_upi_credentials (
  upi_account_id uuid primary key references public.provider_upi_accounts(id) on delete cascade,
  gpay_password_ciphertext text not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
revoke all on private.provider_upi_credentials from public,anon,authenticated;

create or replace function public.set_upi_gpay_credentials(p_actor_id uuid,p_upi_account_id uuid,p_password text,p_encryption_key text)
returns void language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
  perform private.require_staff(p_actor_id);
  if p_password is null or length(p_password)<1 or p_encryption_key is null or length(p_encryption_key)<16 then raise exception 'credential encryption input is invalid'; end if;
  if not exists(select 1 from public.provider_upi_accounts where id=p_upi_account_id and status<>'deleted') then raise exception 'UPI account not found'; end if;
  insert into private.provider_upi_credentials(upi_account_id,gpay_password_ciphertext,updated_by)
  values(p_upi_account_id,encode(pgp_sym_encrypt(p_password,p_encryption_key,'cipher-algo=aes256'),'base64'),p_actor_id)
  on conflict(upi_account_id) do update set gpay_password_ciphertext=excluded.gpay_password_ciphertext,updated_by=excluded.updated_by,updated_at=now();
  insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(p_actor_id,'upi_gpay_credentials_updated','provider_upi_account',p_upi_account_id::text);
end; $$;
revoke all on function public.set_upi_gpay_credentials(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.set_upi_gpay_credentials(uuid,uuid,text,text) to service_role;

create or replace function public.reveal_upi_gpay_password(p_actor_id uuid,p_upi_account_id uuid,p_encryption_key text)
returns text language plpgsql security definer set search_path=public,private,pg_temp as $$
declare cipher text; result text;
begin
  perform private.require_staff(p_actor_id);
  select gpay_password_ciphertext into cipher from private.provider_upi_credentials where upi_account_id=p_upi_account_id;
  if cipher is null then raise exception 'credential not configured'; end if;
  result:=pgp_sym_decrypt(decode(cipher,'base64'),p_encryption_key);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(p_actor_id,'upi_gpay_password_revealed','provider_upi_account',p_upi_account_id::text);
  return result;
end; $$;
revoke all on function public.reveal_upi_gpay_password(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.reveal_upi_gpay_password(uuid,uuid,text) to service_role;
