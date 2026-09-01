-- Forward-only multi-UPI model. Legacy provider columns remain for compatibility.
create table if not exists public.provider_upi_accounts (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.providers(id) on delete cascade,
  label text not null default 'Primary UPI',
  upi_id text,
  mobile text,
  apk_mobile text,
  gpay_login_id text,
  qr_data text,
  status text not null default 'active' check (status in ('active','paused','deleted')),
  merchant_operational boolean not null default true,
  configured_limit_inr numeric(18,2) not null default 0 check (configured_limit_inr >= 0),
  allocated_limit_inr numeric(18,2) not null default 0 check (allocated_limit_inr >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(provider_id, label)
);
alter table public.ledger_entries add column if not exists upi_account_id uuid references public.provider_upi_accounts(id) on delete restrict;
alter table public.provider_qr_codes add column if not exists upi_account_id uuid references public.provider_upi_accounts(id) on delete cascade;
create index if not exists provider_upi_accounts_provider_idx on public.provider_upi_accounts(provider_id, status);
create index if not exists ledger_entries_upi_account_idx on public.ledger_entries(upi_account_id, transaction_date desc);

insert into public.provider_upi_accounts(provider_id,label,upi_id,mobile,apk_mobile,gpay_login_id,status,configured_limit_inr,allocated_limit_inr)
select p.id,'Primary UPI',p.upi_id,p.mobile,p.apk_mobile,p.gpay_login_id,case when p.status='deleted' then 'deleted' else 'active' end,
  case when p.funding_model='commission' then coalesce(p.commission_limit_inr,0) else 0 end,
  case when p.funding_model='deposit' then 0 else coalesce(p.commission_limit_inr,0) end
from public.providers p
where not exists (select 1 from public.provider_upi_accounts a where a.provider_id=p.id);
update public.ledger_entries le set upi_account_id=a.id
from public.provider_upi_accounts a where a.provider_id=le.provider_id and a.label='Primary UPI' and le.upi_account_id is null;

alter table public.provider_upi_accounts enable row level security;
create policy provider_upi_staff_all on public.provider_upi_accounts for all to authenticated
  using (private.current_role() in ('admin','operator')) with check (private.current_role() in ('admin','operator'));
create policy provider_upi_owner_all on public.provider_upi_accounts for all to authenticated
  using (provider_id in (select id from public.providers where created_by=(select auth.uid())))
  with check (provider_id in (select id from public.providers where created_by=(select auth.uid())));

create or replace function public.accounting_for_upi(p_upi_account_id uuid)
returns table(provider_id uuid, funding_model text, total_collection_inr numeric, successful_withdrawal_inr numeric,
  configured_limit_inr numeric, allocated_limit_inr numeric, available_limit_inr numeric)
language sql stable security invoker set search_path=public,pg_temp as $$
  with a as (select ua.*, p.funding_model from public.provider_upi_accounts ua join public.providers p on p.id=ua.provider_id where ua.id=p_upi_account_id),
  l as (select coalesce(sum(le.amount_inr) filter(where le.entry_type='collection' and le.status='posted'),0) collection,
               coalesce(sum(le.amount_inr) filter(where le.entry_type='inr_received' and le.status='posted'),0) withdrawal
        from public.ledger_entries le where le.upi_account_id=p_upi_account_id)
  select a.provider_id,a.funding_model,l.collection,l.withdrawal,a.configured_limit_inr,a.allocated_limit_inr,
    case when a.funding_model='deposit' then greatest(0,a.allocated_limit_inr-l.collection)
         else greatest(0,a.configured_limit_inr-l.collection+l.withdrawal) end
  from a,l;
$$;
grant execute on function public.accounting_for_upi(uuid) to authenticated,service_role;

create or replace function public.allocate_upi_capacity(p_actor_id uuid,p_upi_account_id uuid,p_allocated_limit_inr numeric)
returns public.provider_upi_accounts
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare a public.provider_upi_accounts; p public.providers; used numeric; pool numeric; result public.provider_upi_accounts;
begin
  if p_allocated_limit_inr is null or p_allocated_limit_inr < 0 then raise exception 'allocation must be non-negative'; end if;
  select * into a from public.provider_upi_accounts where id=p_upi_account_id for update;
  if not found then raise exception 'UPI account not found'; end if;
  select * into p from public.providers where id=a.provider_id for update;
  if p.funding_model <> 'deposit' then raise exception 'allocation applies only to Deposit Based users'; end if;
  if not (private.current_role() in ('admin','operator') or p.created_by=p_actor_id) then raise exception 'not authorized'; end if;
  select coalesce(sum(le.amount_inr),0) into used from public.ledger_entries le where le.upi_account_id=a.id and le.entry_type='collection' and le.status='posted';
  if p_allocated_limit_inr < used then raise exception 'consumed allocation cannot be reassigned'; end if;
  select coalesce((select sum(dr.inr_value) from public.deposit_requests dr where dr.provider_id=p.id and dr.status='confirmed'),0)+coalesce((select sum(le.amount_usdt*coalesce(le.credit_rate,le.rate)) from public.ledger_entries le where le.provider_id=p.id and le.entry_type='user_usdt' and le.status='posted'),0)
    into pool;
  if p_allocated_limit_inr + coalesce((select sum(x.allocated_limit_inr) from public.provider_upi_accounts x where x.provider_id=p.id and x.id<>a.id),0) > pool then raise exception 'UPI allocations exceed deposit capacity'; end if;
  update public.provider_upi_accounts set allocated_limit_inr=p_allocated_limit_inr,updated_at=now() where id=a.id returning * into result;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,new_data) values(p_actor_id,'upi_capacity_allocated','provider_upi_account',a.id::text,jsonb_build_object('allocated_limit_inr',p_allocated_limit_inr));
  return result;
end; $$;
revoke all on function public.allocate_upi_capacity(uuid,uuid,numeric) from public,anon,authenticated;
grant execute on function public.allocate_upi_capacity(uuid,uuid,numeric) to service_role;
