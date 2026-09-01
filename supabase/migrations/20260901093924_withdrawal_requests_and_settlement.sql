create table if not exists public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(), requester_type text not null check (requester_type in ('provider','merchant')),
  provider_id uuid references public.providers(id) on delete restrict, amount_usdt numeric(18,6) not null check (amount_usdt > 0),
  rate numeric(18,6) not null default 107 check (rate > 0), amount_inr numeric(18,2) not null check (amount_inr > 0),
  destination_address text not null, status text not null default 'pending' check (status in ('pending','paid','rejected','cancelled')),
  proof_tx_hash text, proof_url text, proof_note text, created_by uuid references public.profiles(id),
  paid_by uuid references public.profiles(id), created_at timestamptz not null default now(), paid_at timestamptz,
  check ((requester_type='provider' and provider_id is not null) or (requester_type='merchant' and provider_id is null))
);
create index if not exists withdrawal_requests_status_idx on public.withdrawal_requests(status, created_at desc);
alter table public.withdrawal_requests enable row level security;
create policy withdrawal_staff_select on public.withdrawal_requests for select to authenticated using (private.current_role() in ('admin','operator'));

create or replace function public.request_usdt_withdrawal(p_share_link_id uuid, p_provider_id uuid, p_requester_type text, p_amount_usdt numeric, p_destination_address text)
returns public.withdrawal_requests language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.withdrawal_requests; rate numeric := 107; amount_inr numeric; available_inr numeric; reserved_inr numeric;
begin
  if p_amount_usdt is null or p_amount_usdt <= 0 or p_destination_address is null or btrim(p_destination_address)='' then raise exception 'valid withdrawal amount and TRC20 address required'; end if;
  if not exists (select 1 from public.share_links where id=p_share_link_id and is_active and expires_at is null and ((p_requester_type='provider' and scope='user' and provider_id=p_provider_id) or (p_requester_type='merchant' and scope='merchant'))) then raise exception 'share link is invalid or revoked'; end if;
  if p_requester_type='provider' then
    select commission_earned_inr into available_inr from public.accounting_for_provider(p_provider_id);
    if not exists (select 1 from public.providers where id=p_provider_id and status='active' and is_active and funding_model='commission') then raise exception 'withdrawal is not allowed for this provider'; end if;
    select coalesce(sum(amount_inr),0) into reserved_inr from public.withdrawal_requests where provider_id=p_provider_id and status='pending';
  elsif p_requester_type='merchant' then
    select coalesce(sum(amount_inr) filter (where entry_type='collection' and status='posted'),0)-coalesce(sum(amount_inr) filter (where entry_type='frozen' and status='active'),0)-coalesce(sum(amount_usdt*rate) filter (where entry_type='merchant_usdt' and status='posted'),0) into available_inr from public.ledger_entries;
    select coalesce(sum(amount_inr),0) into reserved_inr from public.withdrawal_requests where requester_type='merchant' and status='pending';
  else raise exception 'invalid withdrawal requester'; end if;
  if p_amount_usdt * rate > greatest(0,available_inr-coalesce(reserved_inr,0)) then raise exception 'withdrawal exceeds available balance'; end if;
  amount_inr := round(p_amount_usdt * rate,2);
  insert into public.withdrawal_requests(requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,created_by)
  values(p_requester_type,case when p_requester_type='provider' then p_provider_id else null end,p_amount_usdt,rate,amount_inr,btrim(p_destination_address),null) returning * into result;
  insert into public.audit_logs(action,entity_type,entity_id,new_data) values('withdrawal_requested','withdrawal_request',result.id::text,jsonb_build_object('requester_type',p_requester_type,'amount_usdt',p_amount_usdt,'amount_inr',amount_inr));
  return result;
end; $$;
revoke all on function public.request_usdt_withdrawal(uuid,uuid,text,numeric,text) from public, anon, authenticated;
grant execute on function public.request_usdt_withdrawal(uuid,uuid,text,numeric,text) to service_role;

create or replace function public.mark_withdrawal_paid(p_actor_id uuid, p_request_id uuid, p_proof_tx_hash text default null, p_proof_url text default null, p_proof_note text default null)
returns public.withdrawal_requests language plpgsql security definer set search_path = public, private, pg_temp as $$
declare result public.withdrawal_requests;
begin
  perform private.require_staff(p_actor_id);
  if not exists (select 1 from public.profiles where id=p_actor_id and role='admin') then raise exception 'admin authorization required'; end if;
  select * into result from public.withdrawal_requests where id=p_request_id for update;
  if not found then raise exception 'withdrawal request not found'; end if;
  if result.status <> 'pending' then raise exception 'withdrawal is already processed'; end if;
  update public.withdrawal_requests set status='paid',proof_tx_hash=nullif(btrim(p_proof_tx_hash),''),proof_url=nullif(btrim(p_proof_url),''),proof_note=p_proof_note,paid_by=p_actor_id,paid_at=now() where id=p_request_id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'withdrawal_paid','withdrawal_request',result.id::text,jsonb_build_object('proof_tx_hash',result.proof_tx_hash,'proof_url',result.proof_url));
  return result;
end; $$;
revoke all on function public.mark_withdrawal_paid(uuid,uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.mark_withdrawal_paid(uuid,uuid,text,text,text) to service_role;
