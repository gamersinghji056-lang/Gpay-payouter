import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

const app = readFileSync("src/app.js", "utf8");
const backend = readFileSync("src/lib/backend.js", "utf8");
const providerWrite = readFileSync("supabase/functions/provider-write/index.ts", "utf8");
const financialWrite = readFileSync("supabase/functions/financial-write/index.ts", "utf8");
const shareAction = readFileSync("supabase/functions/share-action/index.ts", "utf8");
const shareResolve = readFileSync("supabase/functions/share-resolve/index.ts", "utf8");
const portalResolve = readFileSync("supabase/functions/portal-resolve/index.ts", "utf8");
const portalAction = readFileSync("supabase/functions/portal-action/index.ts", "utf8");
const historyPage = readFileSync("supabase/functions/history-page/index.ts", "utf8");
const packageJson = readFileSync("package.json", "utf8");
const tronWatcher = readFileSync("server/tron-watcher.js", "utf8");
const serverApp = readFileSync("server/app.js", "utf8");
const adminEditVoid = readFileSync("supabase/migrations/20260904090000_admin_edit_void_controls.sql", "utf8");
const adminPerUpi = readFileSync("supabase/migrations/20260904123000_admin_per_upi_limit_override.sql", "utf8");
const upiLifecycle = readFileSync("supabase/migrations/20260904143000_upi_lifecycle_and_exact_attribution.sql", "utf8");
const depositHistoricalRate = readFileSync("supabase/migrations/20260905102000_deposit_user_usdt_historical_rate.sql", "utf8");
const depositExpiry = readFileSync("supabase/migrations/20260905113000_deposit_expiry_and_watcher_window.sql", "utf8");
const migration = readFileSync("supabase/migrations/20260901131107_production_consistency_pass.sql", "utf8");
const multiUpi = readFileSync("supabase/migrations/20260901170000_multi_upi_accounts.sql", "utf8");
const multiUpiOps = readFileSync("supabase/migrations/20260901180000_multi_upi_operations.sql", "utf8");
const chargesMigration = readFileSync("supabase/migrations/20260901200000_merchant_charges.sql", "utf8");
const allMigrations = migration + "\n" + readFileSync("supabase/migrations/20260901100200_share_link_semantics.sql", "utf8");
const finalUi = app.slice(app.lastIndexOf("function depositCreditRows"));
const latestPublicUserUi = app.slice(app.lastIndexOf("async function savePublicCredential"));

function test(name, fn) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    throw error;
  }
}

test("production does not initialize from demo seed users", () => {
  assert.match(app, /function load\(\)\{var d=backend\.configured\?emptyState\(\):seed\(\)/);
});

test("explicit portal pathnames are authoritative before admin fallback", () => {
  assert.match(app, /function getPortalRoute\(pathname\)/);
  assert.match(app, /return \/\^\(admin\|merchant\|user\|agent\)\$\/\.test\(p\)\?p:""/);
  const renderStart = app.indexOf("function render(){var explicitRoute=getPortalRoute()");
  const hashFallback = app.indexOf("var h=location.hash.slice(1)", renderStart);
  const adminFallback = app.indexOf("admin()}", hashFallback);
  assert.ok(renderStart > -1);
  assert.ok(hashFallback > renderStart);
  assert.ok(adminFallback > hashFallback);
});

test("wrong stored sessions cannot override explicit portal pathnames", () => {
  assert.match(app, /if\(explicitRoute==="merchant"\|\|explicitRoute==="user"\|\|explicitRoute==="agent"\)/);
  assert.match(app, /return loadPortal\(explicitRoute\)/);
  assert.match(app, /function routeRole\(\)\{return getPortalRoute\(\)\}/);
  assert.doesNotMatch(app, /routeRole\(\)\|\|"admin"/);
});

test("user portal resolves exact mapped provider and never silently stalls", () => {
  assert.match(portalResolve, /if \(acct\.role === "user"\) providerQuery = providerQuery\.eq\("id", acct\.provider_id\);/);
  assert.match(portalResolve, /else providerQuery = providerQuery\.in\("status", \["active", "paused"\]\);/);
  assert.match(app, /if\(role==="user"\)\{var u=db\.users\[0\];if\(u&&u\.status!=="deleted"&&u\.active!==false\)/);
  assert.match(app, /throw new Error\("User account is unavailable\."\)/);
});

test("explicit user portal route does not render legacy invalid-link screen for stale sessions", () => {
  const loadPortalSource = app.slice(app.indexOf("async function loadPortal"), app.indexOf("async function portalLogout"));
  assert.match(loadPortalSource, /portalLoginScreen\(role,err\.message\|\|"Access denied"\)/);
  assert.match(loadPortalSource, /u&&u\.status!=="deleted"&&u\.active!==false/);
  assert.match(loadPortalSource, /throw new Error\("User account is unavailable\."\)/);
});

test("portal click tracking tolerates non-element tap targets", () => {
  assert.match(app, /event\.target&&event\.target\.getAttribute\?event\.target\.getAttribute\("onclick"\)\|\|"":""/);
});

test("demo users remain isolated to seed only", () => {
  const afterLoad = app.slice(app.indexOf("function load"));
  assert.equal(afterLoad.includes("Aarav Traders"), false);
  assert.equal(afterLoad.includes("Nova Services"), false);
});

test("successful backend empty state is distinct from loading/error", () => {
  assert.match(app, /backendHadLoaded/);
  assert.match(app, /function loadingScreen/);
  assert.match(app, /function errorScreen/);
  assert.match(app, /Loading users/);
});

test("commission limit edit survives reload path by provider id", () => {
  assert.match(backend, /provider_id: provider\.remoteId/);
  assert.match(providerWrite, /body\.provider_id/);
  assert.match(providerWrite, /\.update\(changes\)\.eq\("id", body\.provider_id\)/);
});

test("lowering limit is verified from persisted row", () => {
  assert.match(providerWrite, /commission_limit_inr/);
  assert.match(providerWrite, /provider update was not persisted/);
  assert.match(app, /Limit was not persisted/);
});

test("merchant collection decreases available limit through server accounting", () => {
  assert.match(migration, /p_entry_type='collection'/);
  assert.match(migration, /accounting_for_provider\(p_provider_id\)/);
  assert.match(migration, /collection exceeds available limit/);
});

test("merchant user card shows total collection and available limit", () => {
  assert.match(app, /metric\("Total Collection",money\(c\.collection\)\)/);
  assert.match(app, /metric\("Available Limit",money\(c\.collectionCapacity\)\)/);
});

test("deposit based does not require admin max limit", () => {
  assert.match(migration, /provider\.funding_model='commission' and coalesce\(provider\.commission_limit_inr,0\)<=0/);
  assert.equal(migration.includes("provider.funding_model='deposit' and coalesce(provider.commission_limit_inr"), false);
});

test("deposit based INR withdrawal does not refill capacity", () => {
  assert.match(migration, /d\.deposit\+l\.manual_deposit-l\.collection/);
});

test("manual top-up uses 110.21 credit rate from settings", () => {
  assert.match(migration, /round\(deposit_base_rate\*\(1\+deposit_markup_pct\/100\),6\)/);
});

test("commission withdrawal earns configured 3.5 percent", () => {
  assert.match(migration, /commission_rate_pct\/100/);
  assert.match(app, /commissionRate:3\.5/);
});

test("merchant settlement company earning is 4.5 percent", () => {
  assert.match(migration, /commission numeric:=4\.5/);
  assert.match(migration, /round\(amount_inr\*commission\/100,2\)/);
});

test("manual merchant settlement persists", () => {
  assert.match(migration, /insert into public\.merchant_settlements/);
  assert.match(app, /Manual Merchant Settlement/);
});

test("duplicate settlement is rejected", () => {
  assert.match(migration, /duplicate merchant settlement request/);
  assert.match(financialWrite, /p_idempotency_key/);
});

test("pending withdrawal reservation prevents merchant overspend", () => {
  assert.match(migration, /withdrawal_requests where requester_type='merchant' and status in\('pending','paid'\)/);
  assert.match(shareResolve, /requester_type", "merchant"\)\.in\("status", \["pending", "paid"\]\)/);
});

test("user share regenerate returns immediately usable new url", () => {
  assert.match(app, /regenUser/);
  assert.match(app, /u\.token=result\.data&&result\.data\[0\]&&result\.data\[0\]\.token/);
  assert.match(backend, /public_token/);
});

test("current user share url is recoverable after reload", () => {
  assert.match(backend, /share_links.*public_token/is);
  assert.equal(backend.includes("localStorage.getItem"), false);
});

test("merchant and agent links are stable durable links", () => {
  assert.match(allMigrations, /select \* into existing from public\.share_links/);
  assert.match(backend, /next\.settings\.merchantToken = link\.public_token/);
  assert.match(backend, /next\.settings\.agentToken = link\.public_token/);
});

test("invalid public back never opens admin login", () => {
  assert.match(app, /function publicBack/);
  assert.equal(/function publicBack[\s\S]*Admin Login/.test(app), false);
});

test("no persistState or full-state rewrite exists", () => {
  assert.equal(app.includes("persistState("), false);
  assert.equal(backend.includes("persistState("), false);
});

test("no demo financial data can enter production database path", () => {
  assert.match(app, /Demo reset is disabled in production/);
  assert.match(app, /backend\.configured\?emptyState\(\):seed\(\)/);
});

test("merchant collection correction uses checked rpc", () => {
  assert.match(shareAction, /correct_collection_by_share/);
  assert.equal(shareAction.includes(".from(\"ledger_entries\").update({ amount_inr"), false);
});

test("public merchant settlement summary includes settlements and reservations", () => {
  assert.match(shareResolve, /merchant_settlements/);
  assert.match(shareResolve, /withdrawal_requests/);
  assert.match(shareResolve, /merchantSummary\.availableInr/);
});

test("multi-UPI child accounts preserve legacy providers", () => {
  assert.match(multiUpi, /create table if not exists public\.provider_upi_accounts/);
  assert.match(multiUpi, /where not exists \(select 1 from public\.provider_upi_accounts/);
  assert.match(multiUpi, /update public\.ledger_entries le set upi_account_id/);
  assert.match(backend, /provider_upi_accounts/);
});

test("UPI accounts have independent commission and deposit capacity", () => {
  assert.match(multiUpi, /configured_limit_inr numeric/);
  assert.match(multiUpi, /allocated_limit_inr numeric/);
  assert.match(multiUpi, /case when a\.funding_model='deposit'/);
  assert.match(multiUpi, /consumed allocation cannot be reassigned/);
});

test("commission provider capacity is sourced from child UPI limits", () => {
  assert.match(adminPerUpi, /sum\(configured_limit_inr\)/);
  assert.match(adminPerUpi, /nullif\(sum\(configured_limit_inr\),0\)/);
  assert.match(adminPerUpi, /else least\(u\.commission_limit,greatest\(0,u\.commission_limit-\(l\.collection-l\.withdrawal\)\)\)/);
  assert.match(app, /Total UPI Limit/);
});

test("commission UPI available is capped and over-limit is visible", () => {
  assert.match(adminPerUpi, /else least\(a\.configured_limit_inr,greatest\(0,a\.configured_limit_inr-\(l\.collection-l\.withdrawal\)\)\)/);
  assert.match(app, /overLimit=Math\.max\(0,exposure-limit\)/);
  assert.match(app, /metric\("Over Limit",money\(c\.overLimit\)\)/);
});

test("admin ledger collection can target UPI and bypass capacity checks", () => {
  assert.match(backend, /upi_account_id: entry\.accountId \|\| null/);
  assert.match(financialWrite, /p_upi_account_id: body\.upi_account_id \?\? null/);
  assert.match(adminPerUpi, /p_upi_account_id uuid default null/);
  assert.match(adminPerUpi, /p_entry_type='collection' and actor_role<>'admin'/);
  assert.doesNotMatch(adminPerUpi, /corrected collection exceeds/);
});

test("merchant collection remains server-side capacity restricted", () => {
  assert.match(multiUpiOps, /if p_amount_inr > coalesce\(available,0\) then raise exception 'collection exceeds available limit'/);
  assert.match(shareAction, /post_collection_by_share/);
  assert.match(portalResolve, /accounting_for_upi/);
});

test("admin shell has one authoritative runtime page renderer", () => {
  assert.match(app, /function adminShell\(\)/);
  assert.match(app, /function renderAdminPage\(key\)/);
  assert.match(app, /function admin\(\)\{if\(!isAdminLoggedIn\(\)\)return loginScreen\(\);currentSharedRole="";adminShell\(\);renderAdminPage/);
  assert.doesNotMatch(app, /s\.innerHTML='<div class="toolbar"><div><h2>'/);
});

test("UPI allocation is atomic and cannot exceed deposit pool", () => {
  assert.match(multiUpi, /pg_advisory|for update/);
  assert.match(multiUpi, /UPI allocations exceed deposit capacity/);
  assert.match(multiUpi, /allocate_upi_capacity/);
});

test("UPI status and navigation are visible in deployed UI", () => {
  assert.match(app, /merchantOperational/);
  assert.match(app, /expandReadonlyNav/);
  assert.match(app, /UPI Accounts/);
  assert.match(app, /User Commission/);
});

test("merchant collection can target an operational UPI account", () => {
  assert.match(multiUpiOps, /p_upi_account_id uuid/);
  assert.match(multiUpiOps, /merchant_operational/);
  assert.match(shareAction, /p_upi_account_id: body\.upi_account_id/);
});

test("admin financial edits and voids are audited and server authorized", () => {
  assert.match(adminEditVoid, /admin_update_ledger_entry/);
  assert.match(adminEditVoid, /admin_void_ledger_entry/);
  assert.match(adminEditVoid, /admin_update_withdrawal_request/);
  assert.match(adminEditVoid, /admin_void_withdrawal_request/);
  assert.match(adminEditVoid, /role='admin'/);
  assert.match(adminEditVoid, /ledger_entry_voided/);
  assert.match(adminEditVoid, /withdrawal_request_voided/);
  assert.match(financialWrite, /admin_update_ledger/);
  assert.match(financialWrite, /admin_void_withdrawal/);
  assert.match(backend, /adminUpdateLedger/);
  assert.match(app, /SF\.voidEntry/);
  assert.match(app, /SF\.editWithdrawal/);
});

test("admin users and UPI cards expose soft delete and restore controls", () => {
  assert.match(app, /Users & UPI/);
  assert.match(app, /adminUserFilter/);
  assert.match(app, /data-user-state/);
  assert.match(app, /adminStatusButtons\(u\)/);
  assert.match(app, /SF\.deleteUser/);
  assert.match(app, /SF\.resumeUser/);
});

test("admin recent user history exposes edit and void controls", () => {
  assert.match(app, /Recent User History/);
  assert.match(app, /userHistoryRows\(u,true\)/);
  assert.match(app, /function ledgerActions/);
  assert.match(app, /function withdrawalActions/);
  assert.match(app, /SF\.editEntry/);
  assert.match(app, /SF\.voidEntry/);
  assert.match(app, /SF\.editWithdrawal/);
  assert.match(app, /SF\.voidWithdrawal/);
});

test("admin transactions page exposes view edit and void actions", () => {
  assert.match(app, /key==="transactions"[\s\S]*adminHistoryRows\(true\)/);
  assert.match(app, /actions:adminMode\?ledgerActions\(e\):""/);
  assert.match(app, /actions:adminMode\?withdrawalActions\(w\):""/);
  assert.match(app, /Legacy \/ Unassigned/);
});

test("voided financial rows are excluded from authoritative accounting", () => {
  assert.match(adminEditVoid, /entry_type='collection' and status='posted' and not is_voided/);
  assert.match(adminEditVoid, /entry_type='inr_received' and status='posted' and not is_voided/);
  assert.match(adminEditVoid, /status in \('pending','paid'\) and not is_voided/);
  assert.match(adminEditVoid, /merchant_accounting_summary/);
});

test("UPI operational status is server persisted and audited", () => {
  assert.match(multiUpiOps, /set_upi_operational_status/);
  assert.match(multiUpiOps, /upi_operational_status_changed/);
  assert.match(providerWrite, /upi_operational_status/);
});

test("child-UPI credentials use private encrypted storage and reveal audit", () => {
  const credentials = readFileSync("supabase/migrations/20260901173000_multi_upi_credentials.sql", "utf8");
  assert.match(credentials, /private\.provider_upi_credentials/);
  assert.match(credentials, /pgp_sym_encrypt/);
  assert.match(credentials, /upi_gpay_password_revealed/);
});

test("merchant charges are immutable, idempotent, and balance-authoritative", () => {
  assert.match(chargesMigration, /create table if not exists public\.merchant_charges/);
  assert.match(chargesMigration, /status text not null default 'active'/);
  assert.match(chargesMigration, /merchant_available_balance_inr/);
  assert.match(chargesMigration, /duplicate merchant charge request/);
  assert.match(chargesMigration, /reverse_merchant_charge/);
  assert.match(chargesMigration, /merchant_charge_reversed/);
  assert.match(financialWrite, /merchant_charge/);
  assert.match(shareResolve, /merchant_charges/);
});

test("incomplete share URLs are guarded in the rendered UI", () => {
  assert.match(app, /sanitizeShareLinks/);
  assert.match(app, /Regeneration required/);
  assert.match(app, /button\.disabled=true/);
});

test("manual user payout carries idempotency to the database", () => {
  assert.match(financialWrite, /p_idempotency_key/);
  assert.match(backend, /idempotency_key: proof\?\.idempotencyKey/);
});

test("deposit user navigation omits withdraw tab and funds shows deposit metrics", () => {
  assert.match(app, /if\(u\.fundingMode==="commission"\)tabs\.push\(\["withdraw","Withdraw"\]\)/);
  assert.match(app, /Confirmed USDT/);
  assert.match(app, /Credit Rate/);
  assert.match(app, /110\.21/);
  assert.match(app, /Deposit Address/);
});

test("public user history includes ledger, withdrawals, and deposit sources", () => {
  assert.match(app, /function userHistoryRows/);
  assert.match(app, /db\.withdrawals\|\|\[\]/);
  assert.match(app, /Commission Withdrawal Request/);
  assert.match(app, /db\.deposits\|\|\[\]/);
  assert.match(app, /USDT Deposit/);
});

test("merchant history includes settlements, withdrawals, charges, and reversals", () => {
  assert.match(app, /function merchantHistoryRows/);
  assert.match(app, /Paid Merchant Withdrawal/);
  assert.match(app, /Manual Merchant Settlement/);
  assert.match(app, /Charge Reversal/);
});

test("admin transactions aggregate all major persisted sources", () => {
  assert.match(app, /function adminHistoryRows/);
  assert.match(app, /Merchant Settlement/);
  assert.match(app, /User Commission Withdrawal/);
  assert.match(app, /Manual USDT Top-up/);
  assert.match(app, /Merchant Charge/);
});

test("manual user payout opens payout modal instead of user detail", () => {
  assert.match(app, /onclick="SF\.userPayoutModal/);
  assert.doesNotMatch(app, /Manual Payout<\/button><\/div>'\}\)\.join\(""\),pending[\s\S]*SF\.openUser/);
});

test("merchant account UI exposes GPay, QR, status switch, and disables collection when stopped", () => {
  assert.match(app, /GPay Details/);
  assert.match(app, /SF\.openQR/);
  assert.match(app, /● '\+state\.label/);
  assert.match(app, /UPI account is blocked/);
  assert.match(app, /disabled/);
});

test("UPI lifecycle distinguishes user block, admin block, and archive", () => {
  assert.match(upiLifecycle, /blocked_by_user boolean/);
  assert.match(upiLifecycle, /blocked_by_admin boolean/);
  assert.match(upiLifecycle, /status in \('active','paused','archived','deleted'\)/);
  assert.match(providerWrite, /upi_admin_block/);
  assert.match(providerWrite, /upi_archive/);
  assert.match(app, /function upiState/);
  assert.match(app, /Blocked by Admin/);
  assert.match(app, /Turn OFF/);
  assert.match(app, /adminArchiveUpi/);
});

test("new collection and INR received require exact UPI attribution", () => {
  assert.match(app, /UPI Account \*/);
  assert.match(app, /Select a UPI account/);
  assert.match(app, /Add a UPI account before recording a new INR withdrawal received/);
  assert.match(upiLifecycle, /p_entry_type in \('collection','inr_received'\) and p_upi_account_id is null/);
  assert.match(upiLifecycle, /if p_upi_account_id is null then raise exception 'UPI account is required'/);
});

test("merchant collection blocks inactive or blocked UPI server side", () => {
  assert.match(upiLifecycle, /account\.status <> 'active'/);
  assert.match(upiLifecycle, /account\.blocked_by_user or account\.blocked_by_admin/);
  assert.match(upiLifecycle, /Collection exceeds available account limit/);
  assert.match(portalResolve, /blockedByUser/);
  assert.match(shareResolve, /blockedByAdmin/);
});

test("UPI edits preserve existing limits and bank fields", () => {
  assert.match(app, /configured_limit_inr:x&&x\.u\.fundingMode==="commission"\?x\.a\.configuredLimit:0/);
  assert.match(app, /bank_account_number:v\("upiBankAccount"\)/);
  assert.match(app, /bank_name:x\.a\.bankName/);
  assert.match(providerWrite, /UPI ID already exists for this user/);
});

test("QR manager renders legacy and child QR surfaces", () => {
  assert.match(app, /Primary \/ Legacy QR/);
  assert.match(app, /Upload QR/);
  assert.match(app, /qr_upload/);
});

test("deposit user primary dashboard does not show commission pending KPI", () => {
  const latestPublicUserPage = app.slice(app.lastIndexOf("function publicUserPage"));
  const depositKpis = latestPublicUserPage.match(/var depositKpis=([^;]+);/)?.[1] || "";
  assert.match(latestPublicUserPage, /Available Collection Capacity/);
  assert.match(latestPublicUserPage, /Collection Used/);
  assert.doesNotMatch(depositKpis, /Pending/);
});

test("portal user QR upload is session scoped and exact UPI attributed", () => {
  assert.match(app, /window\.SF\.uploadAccountQR=uploadAccountQR/);
  assert.match(app, /routeRole\(\)==="user"[\s\S]*portalAction\(\{action:"qr_upload",upi_account_id:aid/);
  assert.match(portalAction, /body\.action === "qr_upload"/);
  assert.match(portalAction, /\.eq\("provider_id", acct\.provider_id\)/);
  assert.match(portalAction, /provider_qr_codes"\)\.insert\(\{ provider_id: acct\.provider_id, upi_account_id: account\.id/);
});

test("legacy QR compatibility only maps null-UPI QR rows as provider QR", () => {
  assert.match(shareResolve, /row\.provider_id === provider\.id && !row\.upi_account_id/);
  assert.match(app, /legacyForPrimary/);
  assert.match(app, /Child Account/);
});

test("portal resolver preserves ledger and withdrawal correction metadata", () => {
  assert.match(portalResolve, /is_voided,voided_at,void_reason,edited_at,edit_reason/);
  assert.match(portalResolve, /isVoided: r\.is_voided === true/);
  assert.match(portalResolve, /accountId: r\.upi_account_id \|\| ""/);
});

test("mutation refresh keeps active public page", () => {
  assert.match(app, /window\.__publicPage=key/);
  assert.match(app, /publicUserPage\(window\.__publicPage\)/);
  assert.match(app, /window\.SF\.publicMerchantPage\(window\.__publicPage\|\|"dashboard"\)/);
});

test("admin user detail renders commission and deposit summaries separately", () => {
  assert.match(app, /function adminUserDetailSummary/);
  assert.match(app, /Commission Available/);
  assert.match(app, /Deposit Credit INR/);
  assert.match(app, /if\(u\.fundingMode==="deposit"\)return/);
});

test("admin user detail exposes user operations without merchant settlement action", () => {
  assert.match(app, /<h3>Operations<\/h3>/);
  assert.match(app, /\+ Collection/);
  assert.match(app, /\+ INR Withdrawal Received/);
  assert.match(app, /\+ USDT From User/);
  assert.match(app, /\+ Frozen/);
});

test("account QR modal shows legacy QR on primary account and child QR separately", () => {
  assert.match(app, /legacyForPrimary/);
  assert.match(app, /Legacy \/ Primary/);
  assert.match(app, /Child Account/);
  assert.match(app, /Upload \/ Replace Child QR/);
});

test("deposit funds has deposit request action and no operational QR block", () => {
  assert.match(latestPublicUserUi, /Deposit USDT/);
  assert.match(latestPublicUserUi, /Create Deposit Request/);
  assert.match(latestPublicUserUi, /depositCreditRows\(u\)/);
  assert.doesNotMatch(latestPublicUserUi, /Primary \/ Legacy QR<\/div><img/);
});

test("manual user usdt ledger credits are displayed in deposit history", () => {
  assert.match(app, /function depositCreditRows/);
  assert.match(app, /e\.type==="user_usdt"/);
  assert.match(app, /Ledger credit/);
});

test("GPay details modal shows account context for merchant, user, and admin", () => {
  assert.match(app, /UPI Label/);
  assert.match(app, /GPay Login ID/);
  assert.match(app, /Reveal Password/);
  assert.match(app, /Edit UPI Details/);
});

test("admin user detail operations reopen the same detail after mutation refresh", () => {
  assert.match(app, /window\.__adminOpenUserId=uid/);
  assert.match(app, /previousTargetedLedger/);
  assert.match(app, /userPage\(window\.__adminOpenUserId\)/);
});

test("deposit user share response includes authoritative resolved address", () => {
  assert.match(shareResolve, /const resolvedDepositAddress = provider\.unique_deposit_address \|\| appSettings\?\.admin_trc20_address \|\| ""/);
  assert.match(shareResolve, /user\.uniqueDepositAddress = provider\.unique_deposit_address \|\| ""/);
  assert.match(shareResolve, /user\.companyDepositAddress = appSettings\?\.admin_trc20_address \|\| ""/);
  assert.match(shareResolve, /user\.resolvedDepositAddress = resolvedDepositAddress/);
});

test("frontend deposit QR and request use one resolved address helper", () => {
  assert.match(app, /function resolvedDepositAddress\(u\)/);
  assert.match(app, /function depositQrUrl\(addr,amount\)/);
  assert.match(app, /var addr=resolvedDepositAddress\(u\)/);
  assert.match(app, /Network: TRON \(TRC20\)/);
  assert.match(app, /Deposit address not configured/);
  assert.doesNotMatch(app.slice(app.lastIndexOf("function createDepositPage")), /Admin has not configured a TRC20 address yet/);
});

test("backend state maps unique and company deposit addresses", () => {
  assert.match(backend, /uniqueDepositAddress: row\.unique_deposit_address \|\| ''/);
  assert.match(backend, /companyDepositAddress: settings\?\.admin_trc20_address \|\| ''/);
  assert.match(backend, /resolvedDepositAddress: row\.unique_deposit_address \|\| settings\?\.admin_trc20_address \|\| ''/);
});

test("initial backend load limits heavy histories and selects explicit columns", () => {
  assert.match(backend, /ledger_entries'\)\.select\('id,provider_id,upi_account_id,entry_type/);
  assert.match(backend, /deposit_requests'\)\.select\('id,provider_id,requested_usdt/);
  assert.match(backend, /withdrawal_requests'\)\.select\('id,requester_type,provider_id/);
  assert.match(backend, /\.limit\(500\)/);
});

test("QR signed URL generation is cached during backend hydration", () => {
  assert.match(backend, /const qrSignedUrlCache = new Map\(\)/);
  assert.match(backend, /async function signedQrUrl\(storagePath\)/);
  assert.match(backend, /qr\.data = await signedQrUrl\(qr\.storagePath\)/);
});

test("realtime refreshes are debounced", () => {
  assert.match(backend, /setTimeout\(onChange, 350\)/);
  assert.match(backend, /postgres_changes[\s\S]*debounced/);
});

test("admin logout only clears the current Supabase Auth session", () => {
  assert.match(backend, /supabase\.auth\.signOut\(\{ scope: 'local' \}\)/);
});

test("admin login is authorized by Supabase session role, not tab-local storage", () => {
  assert.match(app, /adminAuthChecked=!backend\.configured/);
  assert.match(app, /function isAdminLoggedIn\(\)\{return backend\.configured\?\(staffRole==="admin"\|\|staffRole==="operator"\):sessionStorage\.getItem\(AUTH_KEY\)==="1"\}/);
  assert.match(app, /if\(backend\.configured&&!adminAuthChecked\)return loadingScreen\("Checking Admin session\."\)/);
  assert.match(app, /if\(!isAdminLoggedIn\(\)\)throw new Error\("Admin authorization required"\)/);
  assert.match(backend, /supabase\.auth\.signInWithPassword\(\{ email, password \}\)/);
  assert.match(backend, /supabase\.auth\.getUser\(\)/);
});

test("portal action tokens follow explicit route role before stale in-memory role", () => {
  assert.match(app, /function activePortalToken\(r\)/);
  assert.match(app, /return s\.token\|\|\(\(portalRole===r&&portalToken\)\?portalToken:""\)/);
  assert.match(app, /function portalAction\(body\)\{var r=routeRole\(\)\|\|portalRole;return backend\.portalAction\(activePortalToken\(r\),body\)\}/);
  assert.match(app, /async function portalLogout\(\)\{var r=routeRole\(\)\|\|portalRole,t=activePortalToken\(r\)/);
  assert.match(app, /backend\.portalCredential\(activePortalToken\("merchant"\),"reveal",aid\)/);
  assert.match(app, /backend\.portalCredential\(activePortalToken\("user"\),"set",aid,v\("publicUpiPassword"\)\)/);
  assert.match(app, /var token=ctx==="admin"\?"":activePortalToken\(ctx\)/);
});

test("admin settings supports authenticated password reset without current password", () => {
  assert.match(backend, /async function updateAdminPassword\(password\)/);
  assert.match(backend, /supabase\.auth\.updateUser\(\{ password \}\)/);
  assert.match(app, /Security & Password/);
  assert.match(app, /SF\.resetAdminPassword/);
  assert.doesNotMatch(app, /Current Password/);
});

test("portal sessions are not replaced during normal login", () => {
  assert.match(readFileSync("supabase/migrations/20260903011000_fix_portal_session_rpc_ambiguity.sql", "utf8"), /insert into private\.portal_sessions\(account_id,token_hash\)/);
  assert.doesNotMatch(readFileSync("supabase/migrations/20260903011000_fix_portal_session_rpc_ambiguity.sql", "utf8"), /delete from private\.portal_sessions where account_id/);
});

test("deposit user USDT from user uses entered base rate plus markup and stores historical credit rate", () => {
  assert.match(app, /USDT Amount/);
  assert.match(app, /Base Rate/);
  assert.match(app, /Commission \/ Markup %/);
  assert.match(app, /Effective Rate/);
  assert.match(app, /INR Capacity Added/);
  assert.match(app, /effective=baseRate\*\(1\+markupPct\/100\)/);
  assert.match(app, /capacity=usdtAmount\*effective/);
  assert.match(app, /e\.rate=Number\(\(baseRate\*\(1\+markupPct\/100\)\)\.toFixed\(6\)\)/);
  assert.match(app, /e\.creditRate=e\.rate/);
  assert.match(depositHistoricalRate, /credit := p_rate/);
  assert.match(depositHistoricalRate, /credit_rate=excluded\.credit_rate|credit_rate,new_credit|credit_rate=new_credit/);
  assert.doesNotMatch(depositHistoricalRate.slice(depositHistoricalRate.indexOf("create or replace function public.post_ledger_entry")), /deposit_base_rate\*\(1\+deposit_markup_pct\/100\)/);
});

test("full history has server-side paginated access for admin and portals", () => {
  assert.match(historyPage, /clampLimit/);
  assert.match(historyPage, /range\(offset, offset \+ limit\)/);
  assert.match(historyPage, /portal_account_from_token/);
  assert.match(historyPage, /requireStaff\(req\)/);
  assert.match(historyPage, /source === "ledger"/);
  assert.match(historyPage, /source === "withdrawals"/);
  assert.match(historyPage, /source === "deposits"/);
  assert.match(historyPage, /source === "merchant_settlements"/);
  assert.match(historyPage, /source === "merchant_charges"/);
  assert.match(app, /Load More History/);
  assert.match(app, /function loadMoreHistory/);
  assert.match(backend, /portalHistoryPage/);
});

test("public share resolver removes sequential accounting and QR waterfalls", () => {
  assert.match(shareResolve, /const providerAccounting = new Map/);
  assert.match(shareResolve, /const upiAccountingRows = new Map/);
  assert.match(shareResolve, /const signedQrRows = new Map/);
  assert.match(shareResolve, /providerAccounting\.get\(provider\.id\)/);
  assert.match(shareResolve, /upiAccountingRows\.get\(account\.id\)/);
  assert.match(shareResolve, /signedQrRows\.get\(qr\.id\)/);
});

test("Railway start command serves SPA and starts existing TRON watcher", () => {
  assert.match(packageJson, /"start": "node server\/app\.js"/);
  assert.match(serverApp, /require\('\.\/tron-watcher'\)/);
  assert.match(serverApp, /startWatcher\(\)/);
  assert.match(serverApp, /path\.join\(root, 'index\.html'\)/);
  assert.match(serverApp, /TRON_WATCH_HEALTH = 'false'/);
});

test("TRON watcher uses mainnet USDT contract and 5 minute deposit window", () => {
  assert.match(tronWatcher, /TR7NHqjeKQxGTCi8qZY4pL8otSzgjLj6t/);
  assert.match(tronWatcher, /LEGACY_BAD_CONTRACT/);
  assert.match(tronWatcher, /process\.env\.TRC20_USDT_CONTRACT === LEGACY_BAD_CONTRACT \? DEFAULT_CONTRACT/);
  assert.match(tronWatcher, /LATE_RECONCILE_MS = 60 \* 60 \* 1000/);
  assert.match(tronWatcher, /timestamp <= expiresAt \+ FUTURE_SKEW_MS/);
  assert.match(tronWatcher, /\.in\('status', \['waiting', 'checking', 'expired'\]\)/);
  assert.match(tronWatcher, /status: 'expired'/);
  assert.match(tronWatcher, /confirm_deposit/);
});

test("deposit requests persist expiry and expose it through resolvers", () => {
  assert.match(depositExpiry, /add column if not exists expires_at timestamptz/);
  assert.match(depositExpiry, /now\(\)\+interval '5 minutes'|now\(\) \+ interval '5 minutes'/);
  assert.match(depositExpiry, /'expired'/);
  assert.match(backend, /created_at,expires_at,confirmed_at/);
  assert.match(portalResolve, /created_at,expires_at,confirmed_at/);
  assert.match(shareResolve, /created_at,expires_at,confirmed_at/);
  assert.match(historyPage, /created_at,expires_at,confirmed_at/);
});

test("deposit UI shows refresh-safe countdown and exact payment details", () => {
  assert.match(app, /function depositExpiresAt\(d\)/);
  assert.match(app, /start\+5\*60\*1000/);
  assert.match(app, /function countdownText/);
  assert.match(app, /Waiting for payment \/ Detecting payment/);
  assert.match(app, /Deposit Confirmed/);
  assert.match(app, /data-deposit-countdown/);
  assert.match(app, /Copy Address/);
  assert.match(app, /Copy Amount/);
  assert.match(app, /Address QR\. Send the exact amount shown\./);
});

test("TRON watcher only matches exact confirmed USDT transfers", () => {
  const watcher = require("../server/tron-watcher.js");
  const destination = "TVvSJ9TubYsFucUqDCmZKHJnPRf3XGvEDA";
  const response = { tokenInfo: { tokenDecimal: 6, tokenId: watcher.config.contract } };
  const tx = { to: destination, contract_address: watcher.config.contract, event_type: "Transfer", confirmed: 1, revert: 0, contract_ret: "SUCCESS", final_result: "SUCCESS", status: 0, amount: "100000000" };
  assert.equal(watcher.transferIsFinal(tx, destination), true);
  assert.equal(watcher.transferAmountMatches(tx, response, "100"), true);
  assert.equal(watcher.transferIsFinal({ ...tx, to: "TWrongAddress" }, destination), false);
  assert.equal(watcher.transferIsFinal({ ...tx, contract_address: "TWrongContract" }, destination), false);
  assert.equal(watcher.transferAmountMatches({ ...tx, amount: "99999999" }, response, "100"), false);
});
