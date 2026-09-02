import { supabase } from './supabase.js';

const configured = Boolean(supabase);
const functionsUrl = configured ? `${import.meta.env.VITE_SUPABASE_URL}/functions/v1` : '';
function rememberShareToken() {}
const qrSignedUrlCache = new Map();

async function signedQrUrl(storagePath) {
  if (!storagePath) return '';
  const cached = qrSignedUrlCache.get(storagePath);
  if (cached && cached.expiresAt > Date.now()) return cached.url;
  const { data } = await supabase.storage.from('provider-qr').createSignedUrl(storagePath, 300);
  const url = data?.signedUrl || '';
  if (url) qrSignedUrlCache.set(storagePath, { url, expiresAt: Date.now() + 240000 });
  return url;
}

function stateFromRows(fallback, settings, providers, entries, deposits, qrs, withdrawals, merchantSettlements, shareLinks, upiAccounts = [], charges = []) {
  const next = { settings: { ...fallback.settings }, users: [], entries: [], deposits: [], withdrawals: [], merchantSettlements: merchantSettlements || [], merchantCharges: (charges || []).map(row => ({ id: row.id, providerId: row.provider_id, upiAccountId: row.upi_account_id, amountInr: Number(row.amount_inr), userName: row.user_name, upiId: row.upi_id || '', mobile: row.mobile || '', date: row.charge_date, reference: row.reference || '', note: row.note || '', status: row.status, createdAt: row.created_at })), audit: [] };
  for (const link of shareLinks || []) if (link.public_token && link.is_active && (!link.expires_at || new Date(link.expires_at) > new Date())) { if (link.scope === 'merchant') next.settings.merchantToken = link.public_token; if (link.scope === 'agent') next.settings.agentToken = link.public_token; }
  if (settings) Object.assign(next.settings, {
    settlementRate: Number(settings.settlement_rate), depositBaseRate: Number(settings.deposit_base_rate),
    depositMarkupPct: Number(settings.deposit_markup_pct), commissionRate: Number(settings.commission_rate_pct),
    adminTrc20Address: settings.admin_trc20_address || '', usdtContract: settings.trc20_usdt_contract || fallback.settings.usdtContract,
  });
  const ids = new Map();
  for (const row of providers || []) {
    ids.set(row.id, row.user_code);
    next.users.push({ id: row.user_code, name: row.name, telegram: row.telegram_username || '', upi: row.upi_id || '',
      mobile: row.mobile || '', apk: row.apk_mobile || '', gpayLogin: row.gpay_login_id || '', qrs: [],
      fundingMode: row.funding_model, limit: Number(row.commission_limit_inr || 0), depositAddress: row.unique_deposit_address || '', uniqueDepositAddress: row.unique_deposit_address || '', companyDepositAddress: settings?.admin_trc20_address || '', resolvedDepositAddress: row.unique_deposit_address || settings?.admin_trc20_address || '',
      token: (shareLinks || []).find(link => link.scope === 'user' && link.provider_id === row.id && link.public_token && link.is_active)?.public_token || '', active: row.is_active, status: row.status || (row.is_active ? 'active' : 'deleted'), pauseReason: row.pause_reason || '', remoteId: row.id,
      upiAccounts: (upiAccounts || []).filter(account => account.provider_id === row.id).map(account => ({ id: account.id, label: account.label, upi: account.upi_id || '', mobile: account.mobile || '', apk: account.apk_mobile || '', gpayLogin: account.gpay_login_id || '', qrData: account.qr_data || '', qrs: [], status: account.status, merchantOperational: account.merchant_operational, configuredLimit: Number(account.configured_limit_inr || 0), allocatedLimit: Number(account.allocated_limit_inr || 0) })) });
  }
  next.entries = (entries || []).map(row => ({ id: row.id, userId: ids.get(row.provider_id) || row.provider_id, accountId: row.upi_account_id || '', type: row.entry_type, creditRate: row.credit_rate,
    amount: row.amount_inr == null ? undefined : Number(row.amount_inr), usdt: row.amount_usdt == null ? undefined : Number(row.amount_usdt),
    rate: row.rate == null ? undefined : Number(row.rate), merchantCommissionRate: row.merchant_commission_rate == null ? undefined : Number(row.merchant_commission_rate), merchantCommissionInr: row.merchant_commission_inr == null ? undefined : Number(row.merchant_commission_inr), bank: row.bank_name || '', account: row.account_number || '', date: row.transaction_date,
    note: row.note || '', status: row.status, createdAt: row.created_at, updatedAt: row.updated_at, enteredBy: row.created_by || 'backend',
    idempotencyKey: row.idempotency_key || row.id }));
  next.deposits = (deposits || []).map(row => ({ id: row.id, userId: ids.get(row.provider_id) || row.provider_id,
    requestedUsdt: Number(row.requested_usdt), expectedUsdt: Number(row.expected_usdt), rate: Number(row.rate), inrValue: Number(row.inr_value),
    address: row.destination_address, status: row.status, txHash: row.tx_hash || '', createdAt: row.created_at, confirmedAt: row.confirmed_at || '', source: row.source }));
  next.withdrawals = (withdrawals || []).map(row => ({ id: row.id, requesterType: row.requester_type, userId: ids.get(row.provider_id) || row.provider_id,
    amountUsdt: Number(row.amount_usdt), rate: Number(row.rate), amountInr: Number(row.amount_inr), address: row.destination_address,
    status: row.status, proofTxHash: row.proof_tx_hash || '', proofUrl: row.proof_url || '', proofNote: row.proof_note || '', createdAt: row.created_at, paidAt: row.paid_at || '' }));
  for (const row of qrs || []) { const user = next.users.find(u => u.remoteId === row.provider_id); if (user) { const qr = { id: row.id, name: row.display_name || 'QR', storagePath: row.storage_path }; const account = user.upiAccounts.find(item => item.id === row.upi_account_id); if (account) account.qrs.push(qr); else user.qrs.push(qr); } }
  return next;
}

async function loadState(fallback) {
  if (!configured) return fallback;
  const [settings, providers, entries, deposits, qrs, withdrawals, merchantSettlements, shareLinks, upiAccounts, charges] = await Promise.all([
    supabase.from('app_settings').select('settlement_rate,deposit_base_rate,deposit_markup_pct,commission_rate_pct,admin_trc20_address,trc20_usdt_contract').eq('id', true).maybeSingle(),
    supabase.from('providers').select('id,user_code,name,telegram_username,upi_id,mobile,apk_mobile,gpay_login_id,funding_model,commission_limit_inr,unique_deposit_address,is_active,status,pause_reason'),
    supabase.from('ledger_entries').select('id,provider_id,upi_account_id,entry_type,credit_rate,amount_inr,amount_usdt,rate,merchant_commission_rate,merchant_commission_inr,bank_name,account_number,transaction_date,note,status,created_at,updated_at,created_by,idempotency_key').order('transaction_date', { ascending: false }).limit(500),
    supabase.from('deposit_requests').select('id,provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,status,tx_hash,created_at,confirmed_at,source').order('created_at', { ascending: false }).limit(500),
    supabase.from('provider_qr_codes').select('id,provider_id,upi_account_id,storage_path,display_name'),
    supabase.from('withdrawal_requests').select('id,requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,status,proof_tx_hash,proof_url,proof_note,created_at,paid_at').order('created_at', { ascending: false }).limit(500),
    supabase.from('merchant_settlements').select('id,amount_usdt,rate,amount_inr,commission_inr,proof_tx_hash,proof_url,proof_note,created_at').order('created_at', { ascending: false }).limit(500),
    supabase.from('share_links').select('scope,provider_id,public_token,is_active,expires_at').eq('is_active', true),
    supabase.from('provider_upi_accounts').select('id,provider_id,label,upi_id,mobile,apk_mobile,gpay_login_id,qr_data,status,merchant_operational,configured_limit_inr,allocated_limit_inr'),
    supabase.from('merchant_charges').select('id,provider_id,upi_account_id,amount_inr,user_name,upi_id,mobile,charge_date,reference,note,status,created_at').order('charge_date', { ascending: false }).limit(500),
  ]);
  const error = [settings, providers, entries, deposits, qrs, withdrawals, merchantSettlements, shareLinks, upiAccounts, charges].find(x => x.error)?.error;
  if (error) throw error;
  for (const link of shareLinks.data || []) if (!link.public_token) { const repaired = await callFunction('share-link', { action: 'get', scope: link.scope, provider_id: link.provider_id }); if (repaired.data?.public_token) link.public_token = repaired.data.public_token; }
  const state = stateFromRows(fallback, settings.data, providers.data, entries.data, deposits.data, qrs.data, withdrawals.data, merchantSettlements.data, shareLinks.data, upiAccounts.data, charges.data);
  const { data: merchantAvailable } = await supabase.rpc('merchant_available_balance_inr');
  state.merchantSettlement = { ...(state.merchantSettlement || {}), availableInr: Number(merchantAvailable || 0), availableUsdt: Number(merchantAvailable || 0) / Number(state.settings.settlementRate || 107) };
  await Promise.all(state.users.flatMap(user => user.upiAccounts.map(async account => { const { data } = await supabase.rpc('accounting_for_upi', { p_upi_account_id: account.id }); const value = data?.[0]; if (value) { account.accounting = value; account.collection = Number(value.total_collection_inr || 0); account.availableLimit = Number(value.available_limit_inr || 0); } })));
  const accounting = await Promise.all((providers.data || []).map(row => supabase.rpc('accounting_for_provider', { p_provider_id: row.id })));
  accounting.forEach((result, index) => { if (!result.error && result.data?.[0]) {
    const user = state.users.find(item => item.remoteId === providers.data[index].id);
    if (user) user.accounting = result.data[0];
  }});
  await Promise.all(state.users.flatMap(user => [...user.qrs, ...user.upiAccounts.flatMap(account => account.qrs || [])].map(async qr => {
    qr.data = await signedQrUrl(qr.storagePath);
  })));
  return state;
}

async function callFunction(name, body) {
  if (!configured) throw new Error('Supabase is not configured');
  const { data: { session } } = await supabase.auth.getSession();
  const response = await fetch(`${functionsUrl}/${name}`, { method: 'POST', headers: { apikey: import.meta.env.VITE_SUPABASE_ANON_KEY, Authorization: `Bearer ${session?.access_token || ''}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || 'backend request failed');
  return result;
}

async function callPublicFunction(name, body) {
  if (!configured) throw new Error('Supabase is not configured');
  const response = await fetch(`${functionsUrl}/${name}`, { method: 'POST', headers: { apikey: import.meta.env.VITE_SUPABASE_ANON_KEY, Authorization: `Bearer ${import.meta.env.VITE_SUPABASE_ANON_KEY}`, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'public share request failed');
  return result;
}

async function upsertProvider(provider) {
  return callFunction('provider-write', { action: 'upsert', provider_id: provider.remoteId || null, user_code: provider.id, name: provider.name, telegram_username: provider.telegram,
    upi_id: provider.upi, mobile: provider.mobile, apk_mobile: provider.apk, gpay_login_id: provider.gpayLogin,
    funding_model: provider.fundingMode, commission_limit_inr: provider.limit, unique_deposit_address: provider.depositAddress, is_active: provider.active });
}
async function upsertUpiAccount(account) { return callFunction('provider-write', { action: 'upi_upsert', ...account }); }
async function allocateUpiCapacity(accountId, amount) { return callFunction('provider-write', { action: 'upi_allocate', upi_account_id: accountId, allocated_limit_inr: amount }); }

async function writeSettings(settings) {
  return callFunction('settings-write', { settlement_rate: settings.settlementRate, deposit_base_rate: settings.depositBaseRate,
    deposit_markup_pct: settings.depositMarkupPct, commission_rate_pct: settings.commissionRate,
    admin_trc20_address: settings.adminTrc20Address, trc20_usdt_contract: settings.usdtContract });
}

async function postLedger(entry, providerId) {
  return callFunction('financial-write', { provider_id: providerId, entry_type: entry.type, amount_inr: entry.amount,
    amount_usdt: entry.usdt, rate: entry.rate, bank_name: entry.bank, account_number: entry.account, transaction_date: entry.date,
    note: entry.note, status: entry.status, idempotency_key: entry.idempotencyKey || entry.id, merchant_commission_rate: entry.merchantCommissionRate });
}

async function updateLedger(entry, providerId) {
  return callFunction('financial-write', { action: 'update', entry_id: entry.id, provider_id: providerId, entry_type: entry.type,
    amount_inr: entry.amount, amount_usdt: entry.usdt, rate: entry.rate, bank_name: entry.bank, account_number: entry.account,
    transaction_date: entry.date, note: entry.note, status: entry.status, merchant_commission_rate: entry.merchantCommissionRate });
}

async function releaseLedger(entryId, providerId) {
  return callFunction('financial-write', { action: 'release', entry_id: entryId, provider_id: providerId });
}

function subscribe(onChange) {
  if (!configured) return () => {};
  let refreshTimer = 0;
  const debounced = () => {
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(onChange, 350);
  };
  const channel = supabase.channel('settleflow-live').on('postgres_changes', { event: '*', schema: 'public', table: 'providers' }, debounced)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'ledger_entries' }, debounced)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'deposit_requests' }, debounced).subscribe();
  return () => { clearTimeout(refreshTimer); supabase.removeChannel(channel); };
}

async function login(email, password) { if (!configured) return false; const { error } = await supabase.auth.signInWithPassword({ email, password }); if (error) throw error; return true; }
async function logout() { if (configured) await supabase.auth.signOut(); }
async function authenticated() { if (!configured) return false; const { data: { user } } = await supabase.auth.getUser(); if (!user) return false; const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).maybeSingle(); return profile?.role || ''; }
async function updateProviderStatus(providerId, action, pauseReason) { return callFunction('provider-write', { action, provider_id: providerId, pause_reason: pauseReason }); }
async function uploadQR(providerId, file, displayName, upiAccountId) {
  const path = `${providerId}/${crypto.randomUUID()}-${displayName.replace(/[^a-zA-Z0-9._-]/g, '_')}`;
  const { error: uploadError } = await supabase.storage.from('provider-qr').upload(path, file, { contentType: file.type, upsert: false });
  if (uploadError) throw uploadError;
  const { error } = await supabase.from('provider_qr_codes').insert({ provider_id: providerId, upi_account_id: upiAccountId || null, storage_path: path, display_name: displayName });
  if (error) { await supabase.storage.from('provider-qr').remove([path]); throw error; }
}
async function deleteQR(qr) {
  const { error } = await supabase.from('provider_qr_codes').delete().eq('id', qr.id);
  if (error) throw error;
  await supabase.storage.from('provider-qr').remove([qr.storagePath]);
}
async function saveCredential(providerId, password, upiAccountId) { return callFunction('credential-reveal', { action: 'set', provider_id: providerId, upi_account_id: upiAccountId, password }); }
async function revealCredential(providerId, upiAccountId) { const result = await callFunction('credential-reveal', { action: 'reveal', provider_id: providerId, upi_account_id: upiAccountId }); return result.password; }
async function revealPublicCredential(token, upiAccountId) { const result = await callPublicFunction('credential-reveal', { action: 'reveal', public_token: token, upi_account_id: upiAccountId }); return result.password; }
async function savePublicCredential(token, upiAccountId, password) { return callPublicFunction('credential-reveal', { action: 'set', public_token: token, upi_account_id: upiAccountId, password }); }
async function userUpiAction(token, body) { return callPublicFunction('share-action', { token, ...body }); }
async function resolveShare(token) {
  const result = await callPublicFunction('share-resolve', { token });
  if (result.state) {
    if (result.scope === 'merchant') result.state.settings.merchantToken = token;
    if (result.scope === 'agent') result.state.settings.agentToken = token;
  }
  return result;
}

async function shareAction(token, body) { return callPublicFunction('share-action', { token, ...body }); }
async function markWithdrawalPaid(requestId, proof) { return callFunction('financial-write', { action: 'mark_withdrawal_paid', request_id: requestId, proof_tx_hash: proof?.txHash, proof_url: proof?.url, proof_note: proof?.note }); }
async function requestWithdrawal(token, amountUsdt, address) { return shareAction(token, { action: 'withdrawal_request', amount_usdt: amountUsdt, destination_address: address }); }
async function manualUserPayout(providerId, amountUsdt, address, proof) { return callFunction('financial-write', { action: 'manual_user_payout', provider_id: providerId, amount_usdt: amountUsdt, destination_address: address, proof_tx_hash: proof?.txHash, proof_url: proof?.url, proof_note: proof?.note, idempotency_key: proof?.idempotencyKey || crypto.randomUUID() }); }
async function manualMerchantSettlement(amountUsdt, rate, proof) { return callFunction('financial-write', { action: 'manual_merchant_settlement', amount_usdt: amountUsdt, rate, proof_tx_hash: proof?.txHash, proof_url: proof?.url, proof_note: proof?.note, idempotency_key: proof?.idempotencyKey }); }
async function addMerchantCharge(charge) { return callFunction('financial-write', { action: 'merchant_charge', ...charge }); }
async function reverseMerchantCharge(chargeId, idempotencyKey) { return callFunction('financial-write', { action: 'merchant_charge_reverse', charge_id: chargeId, idempotency_key: idempotencyKey }); }
export const backend = { configured, loadState, upsertProvider, upsertUpiAccount, allocateUpiCapacity, writeSettings, postLedger, updateLedger, releaseLedger, callFunction, callPublicFunction, subscribe, login, logout, authenticated, updateProviderStatus, uploadQR, deleteQR, saveCredential, revealCredential, revealPublicCredential, savePublicCredential, userUpiAction, resolveShare, shareAction, rememberShareToken, markWithdrawalPaid, requestWithdrawal, manualUserPayout, manualMerchantSettlement, addMerchantCharge, reverseMerchantCharge };
if (typeof window !== 'undefined') window.SettleFlow = { ...(window.SettleFlow || {}), backend };
