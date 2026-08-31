# CLINE START HERE — Gpay Payouter

Read this file and inspect `index.html` completely before editing.

## NON-NEGOTIABLE
The current UI is approved. Preserve its dark premium theme, cards, modals, calculations, buttons and share views. Do not replace it with a generic template and do not delete working features.

## Required roles and permissions

### Admin / Operator
- Must authenticate before dashboard access.
- Create a user card initially with ONLY:
  - User Name
  - Telegram Username
- After creation, open the card and add/edit:
  - UPI ID
  - APK/mobile number
  - GPay Login ID
  - GPay Password
  - Holding limit
  - QR codes
  - Collection
  - INR received
  - USDT received from user
  - Merchant USDT settlement
  - Frozen/released funds
- Admin/Operator must be able to correct mistaken entries/details.
- Financial corrections must be auditable in production.

### User
From the user's authorized individual link, user can manage/correct:
- UPI ID
- APK/mobile number
- GPay Login ID
- GPay Password
- QR codes

User must not control admin settlement/frozen/holding accounting.

### Merchant
Merchant can:
- View permitted user cards
- View GPay details and QR codes
- ADD collection entries
- EDIT/CORRECT collection amount

Merchant cannot edit:
- GPay credentials
- UPI/APK/profile
- QR codes
- holding limit
- INR recovery
- USDT recovery
- merchant settlement
- frozen funds

### Agent
Read-only unless owner later explicitly changes this rule.
Can view permitted GPay details and QR codes.
Cannot edit financial/admin data.

## Accounting — keep separate

Merchant Available INR =
Total Collection
- Active Frozen INR
- INR equivalent of Merchant USDT already settled

Merchant Available USDT =
Merchant Available INR / applicable current rate

IMPORTANT:
INR recovered from the user/provider does NOT reduce merchant settlement entitlement.

Provider Pending INR =
Total Collection
- INR Received
- INR equivalent of USDT Received From User
- Active Frozen INR

Every USDT transaction stores its historical rate.

## Production migration
1. Replace localStorage with Supabase Postgres.
2. Replace demo frontend admin lock with Supabase Auth.
3. Add Admin/Operator roles.
4. Enforce permissions using RLS/backend, not only hidden buttons.
5. Store GPay passwords encrypted at rest; never plaintext in production DB.
6. Never expose encryption key or Supabase service-role key in browser.
7. Put QR images in private Supabase Storage.
8. Support multiple/unlimited QR records per user.
9. Use secure random share tokens and store hashes.
10. Merchant/Agent/User links must be revocable/regeneratable.
11. Existing share links must show latest database data live.
12. Use Supabase Realtime or short polling.
13. Add audit logs for financial corrections and sensitive credential access.
14. Avoid destructive deletion of financial history; use correction/reversal records.

## Before changing code
First report:
1. What files/features you found.
2. What is prototype-only.
3. Files you will create/change.
4. Database/Auth/RLS/Storage plan.
5. How you will preserve the current UI.
Then implement in phases and test each phase.
