alter table public.share_links add column if not exists public_token text;
create unique index if not exists share_links_public_token_idx on public.share_links(public_token) where public_token is not null;

create or replace function public.create_share_link(p_actor_id uuid,p_scope text,p_provider_id uuid default null,p_expires_at timestamptz default null)
returns table(id uuid,token text) language plpgsql security definer set search_path=public,private,pg_temp as $$
declare raw_token text; link_id uuid;
begin
  perform private.require_staff(p_actor_id);
  if p_scope not in('merchant','agent','user') then raise exception 'invalid share scope'; end if;
  raw_token:=replace(replace(replace(encode(extensions.gen_random_bytes(32),'base64'),'+','-'),'/','_'),'=','');
  insert into public.share_links(scope,provider_id,token_hash,public_token,created_by,expires_at) values(p_scope,p_provider_id,encode(extensions.digest(raw_token,'sha256'),'hex'),raw_token,p_actor_id,p_expires_at) returning share_links.id into link_id;
  return query select link_id,raw_token;
end; $$;
revoke all on function public.create_share_link(uuid,text,uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.create_share_link(uuid,text,uuid,timestamptz) to service_role;
