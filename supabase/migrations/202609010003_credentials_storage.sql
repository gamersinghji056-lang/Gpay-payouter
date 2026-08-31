create table if not exists private.provider_credentials (
  provider_id uuid primary key references public.providers(id) on delete cascade,
  gpay_password_ciphertext text not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
revoke all on private.provider_credentials from public, anon, authenticated;

revoke select (gpay_password_ciphertext) on public.providers from anon, authenticated;

create or replace function public.set_gpay_credentials(p_actor_id uuid, p_provider_id uuid, p_password text, p_encryption_key text)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  perform private.require_staff(p_actor_id);
  if p_password is null or length(p_password) < 1 or p_encryption_key is null or length(p_encryption_key) < 16 then raise exception 'credential encryption input is invalid'; end if;
  insert into private.provider_credentials(provider_id,gpay_password_ciphertext,updated_by)
  values(p_provider_id,encode(pgp_sym_encrypt(p_password,p_encryption_key,'cipher-algo=aes256'),'base64'),p_actor_id)
  on conflict (provider_id) do update set gpay_password_ciphertext=excluded.gpay_password_ciphertext,updated_by=excluded.updated_by,updated_at=now();
  insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(p_actor_id,'gpay_credentials_updated','provider',p_provider_id::text);
end; $$;
revoke all on function public.set_gpay_credentials(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.set_gpay_credentials(uuid,uuid,text,text) to service_role;

create or replace function public.reveal_gpay_password(p_actor_id uuid, p_provider_id uuid, p_encryption_key text)
returns text language plpgsql security definer set search_path = public, private, pg_temp as $$
declare ciphertext text; password text;
begin
  perform private.require_staff(p_actor_id);
  select gpay_password_ciphertext into ciphertext from private.provider_credentials where provider_id=p_provider_id;
  if ciphertext is null then raise exception 'credential not configured'; end if;
  password := pgp_sym_decrypt(decode(ciphertext,'base64'),p_encryption_key);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(p_actor_id,'gpay_password_revealed','provider',p_provider_id::text);
  return password;
end; $$;
revoke all on function public.reveal_gpay_password(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.reveal_gpay_password(uuid,uuid,text) to service_role;
