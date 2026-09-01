create or replace function public.create_share_link(p_actor_id uuid, p_scope text, p_provider_id uuid default null, p_expires_at timestamptz default null)
returns table (id uuid, token text) language plpgsql security definer set search_path = public, pg_temp as $$
declare raw_token text; link_id uuid;
begin
  perform private.require_staff(p_actor_id);
  if p_scope not in ('merchant','agent','user') then raise exception 'invalid share scope'; end if;
  update public.share_links set is_active=false,revoked_at=coalesce(revoked_at,now()) where is_active and scope=p_scope and ((p_scope='user' and provider_id=p_provider_id) or (p_scope in ('merchant','agent') and provider_id is null));
  raw_token := replace(replace(replace(encode(extensions.gen_random_bytes(32),'base64'),'+','-'),'/','_'),'=','');
  insert into public.share_links(scope,provider_id,token_hash,created_by,expires_at) values(p_scope,p_provider_id,encode(extensions.digest(raw_token,'sha256'),'hex'),p_actor_id,p_expires_at) returning share_links.id into link_id;
  return query select link_id,raw_token;
end; $$;
revoke all on function public.create_share_link(uuid,text,uuid,timestamptz) from public, anon, authenticated;
grant execute on function public.create_share_link(uuid,text,uuid,timestamptz) to service_role;
