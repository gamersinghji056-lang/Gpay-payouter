# CODEX START HERE — Gpay-payouter

## First rule
Inspect the COMPLETE repository and `index.html` before changing anything.
The current HTML is the approved functional prototype and is the source of truth for UI/UX and business behavior.

DO NOT remove, rename away, simplify, or silently replace working features.
DO NOT redesign the approved dark premium UI unless a change is required for functionality.
DO NOT start by rewriting everything from scratch.

Before coding, report:
1. What currently works.
2. Current data model and calculations.
3. Security/production gaps.
4. Exact files you will create/modify.
5. Database/RLS/backend plan.
Then implement in safe phases and test after each phase.

## Core user models — KEEP COMPLETELY SEPARATE

### A. Deposit Based User
- Selected when Admin creates the card.
- User can create TRC20 USDT deposit requests from their individual user dashboard.
- Admin configures global TRC20 address and may configure a unique user address.
- Production preference: unique deposit address per user/deposit-capable account.
- Deposit request shows exact USDT amount, address, copy action and QR.
- Blockchain watcher auto-detects TRC20 USDT and confirms only once.
- `tx_hash` must be unique/idempotent.
- Current deposit credit rate is `107 + 3% = 110.21 INR per USDT`.
- Confirmed deposit creates collection capacity.
- Merchant collection consumes/decreases this capacity.
- NEW confirmed deposit replenishes this capacity.
- INR withdrawal is allowed for Deposit Based users, but withdrawal MUST NOT refill deposit collection capacity.
- User may see deposit/available/collected/withdrawal information appropriate to their own dashboard.

Deposit capacity formula:
`available_deposit_capacity = confirmed_deposit_inr_credit - total_collection`
Clamp at zero for new collection validation.

### B. Commission Based User
- Selected when Admin creates the card.
- Admin must be able to Set / Change Maximum Collection Limit.
- Raw Admin configured limit must NOT be visible to User, Merchant or Agent.
- Merchant collection decreases available collection capacity.
- Successful INR withdrawal entered by Admin increases available collection capacity again, capped at Admin maximum limit.
- User earns commission only on successful INR withdrawals.
- Default commission rate: 3.5%.

Commission capacity formula:
`available_commission_capacity = admin_max_limit - total_collection + successful_inr_withdrawal`
Clamp between `0` and `admin_max_limit`.

Commission formula:
`earned_commission = successful_inr_withdrawal * commission_rate / 100`

## Create User Card
Admin creation form MUST ask:
- User Name
- Telegram Username
- Funding Model: Deposit Based OR Commission Based

The funding model must be selected during creation.
Remaining profile/GPay details are edited inside the card afterwards.

## Visibility rules

### Admin / Operator
Can see and manage internal operational/accounting information allowed by role, including funding model, commission-user limit, deposits, withdrawals, frozen entries, settlements, GPay details and QR.

### Merchant
Merchant must NOT see:
- Deposit Based / Commission Based label
- Admin configured maximum limit
- User deposit amount/history
- Deposit rate/markup details
- Commission rate/earned commission
- Internal withdrawals
- Frozen funds
- Internal settlement/recovery accounting

Merchant should see normal operational details only:
- User Name
- Available Collection
- UPI ID
- APK / Mobile Number
- GPay Login ID
- GPay Password where authorized
- GPay QR codes
- Collection history

Merchant permissions:
- Can ADD Collection.
- Can EDIT/CORRECT Collection Amount only.
- Cannot edit profile, credentials, QR, limits, deposits, withdrawals, frozen funds or settlement entries.
- Backend must reject collection above current available capacity.

### Agent
- Read-only.
- Same private internal funding/accounting details must stay hidden.
- Can view allowed GPay operational details and QR.

### Individual User
Can edit own operational profile only where allowed:
- UPI ID
- Mobile / APK number
- Telegram username
- GPay Login ID
- GPay Password
- own QR codes

User must not control Admin-only financial accounting.

## Existing financial ledgers
Preserve current working concepts:
- Collection
- Successful INR Withdrawal / INR Received
- USDT From User
- Merchant USDT Settlement
- Frozen Fund + Release
- Deposit requests/history
- Audit history

Do not merge conceptually different ledgers just because they use INR/USDT.

## Existing merchant settlement / provider recovery calculations
Preserve the accounting behavior already present unless a verified bug exists.
In particular, successful INR withdrawal from provider does NOT reduce merchant settlement entitlement in the merchant-settlement ledger.

Merchant Available INR:
`total_collection - active_frozen_inr - merchant_usdt_settled_inr_equivalent`

Provider Pending INR:
`total_collection - successful_inr_withdrawal - user_usdt_received_inr_equivalent - active_frozen_inr`

Historical USDT transaction rates must be stored per transaction.

## Capacity enforcement
Available Collection must be computed centrally based on funding model.
Admin and Merchant must not be able to add a new collection above current capacity.
Do not enforce this only in frontend JavaScript; production backend/database transaction must enforce it too.

## Production migration goals
The current prototype uses browser localStorage and demo admin auth. Replace these safely with:
- Supabase Postgres
- Supabase Auth for staff accounts
- RLS/backend authorization
- private Supabase Storage for QR images
- server-side encryption for GPay passwords
- secure share/session tokens
- realtime/polling updates
- audit logs
- server-side TRON watcher

## Share links
Support live links for:
- Merchant common dashboard
- Agent common dashboard
- Individual User dashboard

Requirements:
- cryptographically strong random tokens
- preferably hash tokens at rest
- revoke/regenerate
- old token stops working
- optional expiration
- latest DB data appears without regenerating the link

Do NOT make anonymous financial tables publicly writable via broad RLS policies.
Merchant collection writes must go through a secure validated server/Edge Function/session architecture.

## GPay credential security
Production GPay password must not be plaintext in DB or localStorage.
Encryption/decryption secret must never be exposed to frontend.
Use server/Edge Function/backend to encrypt/decrypt and audit credential reveal.

## QR storage
Do not store production QR images as base64 in database/localStorage.
Use a private Supabase Storage bucket and signed/authorized delivery.

## TRC20 deposit watcher
Move blockchain watching out of browser in production.
Use server worker / Railway worker / Edge-compatible server process.
Watcher requirements:
- TRC20 USDT only
- correct network/contract
- destination address matching
- expected amount validation
- transaction hash uniqueness
- confirmation status
- idempotent crediting
- retry-safe processing
- logs/errors
- never double-credit

## Corrections / audit
Financial mistakes must be correctable without silently destroying history.
Record old value, new value, actor, timestamp and optional reason.
Avoid hard-delete of financial history.

## UI preservation
Preserve the approved visual system and interaction model including:
- dark premium dashboard
- sidebar/navigation
- KPI cards
- user cards
- card detail modal
- GPay Details section
- password Show/Hide + Copy
- QR gallery
- ledger/history surfaces
- share links
- responsive layout
- current actions/buttons unless functionality requires an improvement

## Recommended production structure
You may migrate the single HTML prototype into maintainable modules, but visual behavior must remain equivalent.
Suggested organization:
- `src/components/`
- `src/pages/`
- `src/services/`
- `src/lib/`
- `src/calculations/`
- `src/auth/`
- `src/types/`
- `supabase/migrations/`
- `workers/tron/`

## Definition of done
Do not claim complete until:
- both funding models are separate and tested
- commission limit can be set by Admin
- deposit user withdrawals work without refilling deposit capacity
- Merchant cannot see private funding/accounting model details
- Merchant collection add/edit respects capacity server-side
- Agent is read-only
- user self-service is limited to allowed fields
- TRC20 confirmation is idempotent
- GPay credentials are server-encrypted
- share tokens are revocable
- audit trail exists
- tests/typecheck/build pass
