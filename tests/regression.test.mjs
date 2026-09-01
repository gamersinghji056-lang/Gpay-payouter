import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const app = readFileSync("src/app.js", "utf8");
const backend = readFileSync("src/lib/backend.js", "utf8");
const providerWrite = readFileSync("supabase/functions/provider-write/index.ts", "utf8");
const financialWrite = readFileSync("supabase/functions/financial-write/index.ts", "utf8");
const shareAction = readFileSync("supabase/functions/share-action/index.ts", "utf8");
const shareResolve = readFileSync("supabase/functions/share-resolve/index.ts", "utf8");
const migration = readFileSync("supabase/migrations/20260901131107_production_consistency_pass.sql", "utf8");
const allMigrations = migration + "\n" + readFileSync("supabase/migrations/20260901100200_share_link_semantics.sql", "utf8");

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
