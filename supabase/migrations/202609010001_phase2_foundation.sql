create extension if not exists pgcrypto;

create schema if not exists private;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','operator','merchant','agent','user')),
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.app_settings (
  id boolean primary key default true check (id),
  settlement_rate numeric(18,6) not null default 107 check (settlement_rate > 0),
  deposit_base_rate numeric(18,6) not null default 107 check (deposit_base_rate > 0),
  deposit_markup_pct numeric(9,4) not null default 3 check (deposit_markup_pct >= 0),
  commission_rate_pct numeric(9,4) not null default 3.5 check (commission_rate_pct >= 0),
  admin_trc20_address text,
  trc20_usdt_contract text,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
insert into public.app_settings (id) values (true) on conflict (id) do nothing;

create table if not exists public.providers (
  id uuid primary key default gen_random_uuid(),
  user_code text unique not null,
  name text not null,
  telegram_username text,
  upi_id text,
  mobile text,
  apk_mobile text,
  gpay_login_id text,
  gpay_password_ciphertext text,
  funding_model text not null check (funding_model in ('deposit','commission')),
  commission_limit_inr numeric(18,2) not null default 0 check (commission_limit_inr >= 0),
  unique_deposit_address text,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.providers add column if not exists funding_model text;
alter table public.providers add column if not exists commission_limit_inr numeric(18,2) default 0;
alter table public.providers add column if not exists unique_deposit_address text;
update public.providers set funding_model='commission' where funding_model is null;
alter table public.providers alter column funding_model set default 'commission';
alter table public.providers alter column funding_model set not null;

create table if not exists public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.providers(id) on delete restrict,
  entry_type text not null check (entry_type in ('collection','inr_received','user_usdt','merchant_usdt','frozen')),
  amount_inr numeric(18,2), amount_usdt numeric(18,6), rate numeric(18,6),
  bank_name text, account_number text, transaction_date date not null,
  reference_no text, note text,
  status text not null default 'posted' check (status in ('posted','active','released','reversed')),
  created_by uuid references public.profiles(id), created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), reversed_at timestamptz, reversal_reason text,
  idempotency_key text unique,
  check ((entry_type in ('collection','inr_received','frozen') and amount_inr is not null and amount_inr > 0)
      or (entry_type in ('user_usdt','merchant_usdt') and amount_usdt is not null and amount_usdt > 0 and rate is not null and rate > 0))
);
alter table public.ledger_entries add column if not exists idempotency_key text;
create unique index if not exists ledger_entries_idempotency_idx on public.ledger_entries (idempotency_key) where idempotency_key is not null;

create table if not exists public.deposit_requests (
  id uuid primary key default gen_random_uuid(), provider_id uuid not null references public.providers(id) on delete restrict,
  requested_usdt numeric(18,6) not null check (requested_usdt > 0), expected_usdt numeric(18,6) not null check (expected_usdt > 0),
  rate numeric(18,6) not null check (rate > 0), inr_value numeric(18,2) not null check (inr_value > 0),
  destination_address text not null, status text not null default 'waiting' check (status in ('waiting','checking','confirmed','failed')),
  tx_hash text unique, source text not null default 'user' check (source in ('user','blockchain','admin','demo')),
  created_by uuid references public.profiles(id), created_at timestamptz not null default now(), confirmed_at timestamptz
);

create table if not exists public.provider_qr_codes (
  id uuid primary key default gen_random_uuid(), provider_id uuid not null references public.providers(id) on delete cascade,
  storage_path text unique not null, display_name text, created_by uuid references public.profiles(id), created_at timestamptz not null default now()
);

create table if not exists public.share_links (
  id uuid primary key default gen_random_uuid(), scope text not null check (scope in ('merchant','agent','user')),
  provider_id uuid references public.providers(id) on delete cascade, token_hash text unique not null,
  is_active boolean not null default true, created_by uuid references public.profiles(id), created_at timestamptz not null default now(),
  revoked_at timestamptz, expires_at timestamptz, last_accessed_at timestamptz,
  check ((scope = 'user' and provider_id is not null) or (scope in ('merchant','agent') and provider_id is null))
);
alter table public.share_links add column if not exists created_by uuid references public.profiles(id);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key, actor_id uuid references public.profiles(id), action text not null,
  entity_type text not null, entity_id text, old_data jsonb, new_data jsonb, created_at timestamptz not null default now()
);

create index if not exists ledger_entries_provider_date_idx on public.ledger_entries (provider_id, transaction_date desc);
create index if not exists deposits_provider_status_idx on public.deposit_requests (provider_id, status);
create index if not exists share_links_active_idx on public.share_links (scope, is_active) where is_active;
create index if not exists audit_logs_entity_idx on public.audit_logs (entity_type, entity_id, created_at desc);

alter table public.profiles enable row level security;
alter table public.app_settings enable row level security;
alter table public.providers enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.deposit_requests enable row level security;
alter table public.provider_qr_codes enable row level security;
alter table public.share_links enable row level security;
alter table public.audit_logs enable row level security;

create or replace function private.current_role() returns text language sql stable security definer set search_path = public, pg_temp as $$
  select role from public.profiles where id = (select auth.uid())
$$;
revoke all on function private.current_role() from public;
grant execute on function private.current_role() to authenticated, service_role;

create policy profiles_self_select on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy profiles_staff_select on public.profiles for select to authenticated using (private.current_role() in ('admin','operator'));
create policy settings_staff_select on public.app_settings for select to authenticated using (private.current_role() in ('admin','operator'));
create policy providers_staff_all on public.providers for all to authenticated using (private.current_role() in ('admin','operator')) with check (private.current_role() in ('admin','operator'));
create policy providers_owner_select on public.providers for select to authenticated using (created_by = (select auth.uid()));
create policy ledger_staff_select on public.ledger_entries for select to authenticated using (private.current_role() in ('admin','operator'));
create policy ledger_owner_select on public.ledger_entries for select to authenticated using (provider_id in (select id from public.providers where created_by = (select auth.uid())));
create policy deposits_staff_select on public.deposit_requests for select to authenticated using (private.current_role() in ('admin','operator'));
create policy deposits_owner_select on public.deposit_requests for select to authenticated using (provider_id in (select id from public.providers where created_by = (select auth.uid())));
create policy qr_staff_all on public.provider_qr_codes for all to authenticated using (private.current_role() in ('admin','operator')) with check (private.current_role() in ('admin','operator'));
create policy qr_owner_select on public.provider_qr_codes for select to authenticated using (provider_id in (select id from public.providers where created_by = (select auth.uid())));
create policy shares_staff_all on public.share_links for all to authenticated using (private.current_role() in ('admin','operator')) with check (private.current_role() in ('admin','operator'));
create policy audit_staff_select on public.audit_logs for select to authenticated using (private.current_role() in ('admin','operator'));

create or replace function public.accounting_for_provider(p_provider_id uuid)
returns table (collection_inr numeric, successful_withdrawal_inr numeric, user_usdt_inr numeric, merchant_settled_inr numeric, frozen_inr numeric, confirmed_deposit_inr numeric, collection_capacity_inr numeric, commission_earned_inr numeric)
language sql stable security invoker set search_path = public, pg_temp as $$
  with p as (select * from public.providers where id = p_provider_id),
  l as (select coalesce(sum(amount_inr) filter (where entry_type='collection' and status='posted'),0) collection,
               coalesce(sum(amount_inr) filter (where entry_type='inr_received' and status='posted'),0) withdrawal,
               coalesce(sum(amount_usdt * rate) filter (where entry_type='user_usdt' and status='posted'),0) user_usdt,
               coalesce(sum(amount_usdt * rate) filter (where entry_type='merchant_usdt' and status='posted'),0) merchant,
               coalesce(sum(amount_inr) filter (where entry_type='frozen' and status='active'),0) frozen
        from public.ledger_entries where provider_id=p_provider_id),
  d as (select coalesce(sum(inr_value) filter (where status='confirmed'),0) deposit from public.deposit_requests where provider_id=p_provider_id)
  select l.collection,l.withdrawal,l.user_usdt,l.merchant,l.frozen,d.deposit,
    case when p.funding_model='deposit' then greatest(0,d.deposit-l.collection)
      else least(p.commission_limit_inr,greatest(0,p.commission_limit_inr-(l.collection-l.withdrawal))) end,
    case when p.funding_model='commission' then l.withdrawal*(select commission_rate_pct/100 from public.app_settings where id) else 0 end
  from p,l,d;
$$;
grant execute on function public.accounting_for_provider(uuid) to authenticated, service_role;
