import { supabase } from './supabase.js';

const configured = Boolean(supabase);
const functionsUrl = configured ? `${import.meta.env.VITE_SUPABASE_URL}/functions/v1` : '';
const SHARE_TOKEN_KEY = 'settleflow_share_tokens_v1';
function shareTokens() { try { return JSON.parse(localStorage.getItem(SHARE_TOKEN_KEY) || '{}'); } catch { return {}; } }
function rememberShareToken(scope, providerId, token) { const current = shareTokens(); if (scope === 'user') current.users = { ...(current.users || {}), [providerId]: token }; else current[scope] = token; localStorage.setItem(SHARE_TOKEN_KEY, JSON.stringify(current)); }

function stateFromRows(fallback, settings, providers, entries, deposits, qrs, withdrawals, merchantSettlements) {
  const next = { settings: { ...fallback.settings }, users: [], entries: [], deposits: [], withdrawals: [], merchantSettlements: merchantSettlements || [], audit: [] };
  const tokens = shareTokens();
  next.settings.merchantToken = tokens.merchant || '';
  next.settings.agentToken = tokens.agent || '';
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
      fundingMode: row.funding_model, limit: Number(row.commission_limit_inr || 0), depositAddress: row.unique_deposit_address || '',
      token: tokens.users?.[row.id] || '', active: row.is_active, status: row.status || (row.is_active ? 'active' : 'deleted'), pauseReason: row.pause_reason || '', remoteId: row.id });
  }
  next.entries = (entries || []).map(row => ({ id: row.id, userId: ids.get(row.provider_id) || row.provider_id, type: row.entry_type, creditRate: row.credit_rate,
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
  for (const row of qrs || []) { const user = next.users.find(u => u.remoteId === row.provider_id); if (user) user.qrs.push({ id: row.id, name: row.display_name || 'QR', storagePath: row.storage_path }); }
  return next;
}

async function loadState(fallback) {
  if (!configured) return fallback;
  const [settings, providers, entries, deposits, qrs, withdrawals, merchantSettlements] = await Promise.all([
    supabase.from('app_settings').select('*').eq('id', true).maybeSingle(),
    supabase.from('providers').select('id,user_code,name,telegram_username,upi_id,mobile,apk_mobile,gpay_login_id,funding_model,commission_limit_inr,unique_deposit_address,is_active,status,pause_reason'),
    supabase.from('ledger_entries').select('*').order('transaction_date', { ascending: false }),
    supabase.from('deposit_requests').select('*').order('created_at', { ascending: false }),
    supabase.from('provider_qr_codes').select('*'),
    supabase.from('withdrawal_requests').select('*').order('created_at', { ascending: false }),
    supabase.from('merchant_settlements').select('*').order('created_at', { ascending: false }),
  ]);
  const error = [settings, providers, entries, deposits, qrs, withdrawals, merchantSettlements].find(x => x.error)?.error;
  if (error) throw error;
  const state = stateFromRows(fallback, settings.data, providers.data, entries.data, deposits.data, qrs.data, withdrawals.data, merchantSettlements.data);
  const accounting = await Promise.all((providers.data || []).map(row => supabase.rpc('accounting_for_provider', { p_provider_id: row.id })));
  accounting.forEach((result, index) => { if (!result.error && result.data?.[0]) {
    const user = state.users.find(item => item.remoteId === providers.data[index].id);
    if (user) user.accounting = result.data[0];
  }});
  await Promise.all(state.users.flatMap(user => user.qrs.map(async qr => {
    const { data } = await supabase.storage.from('provider-qr').createSignedUrl(qr.storagePath, 300);
    qr.data = data?.signedUrl || '';
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
  return callFunction('provider-write', { action: 'upsert', user_code: provider.id, name: provider.name, telegram_username: provider.telegram,
    upi_id: provider.upi, mobile: provider.mobile, apk_mobile: provider.apk, gpay_login_id: provider.gpayLogin,
    funding_model: provider.fundingMode, commission_limit_inr: provider.limit, unique_deposit_address: provider.depositAddress, is_active: provider.active });
}

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
  const channel = supabase.channel('settleflow-live').on('postgres_changes', { event: '*', schema: 'public', table: 'providers' }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'ledger_entries' }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'deposit_requests' }, onChange).subscribe();
  return () => supabase.removeChannel(channel);
}

async function login(email, password) { if (!configured) return false; const { error } = await supabase.auth.signInWithPassword({ email, password }); if (error) throw error; return true; }
async function logout() { if (configured) await supabase.auth.signOut(); }
async function authenticated() { if (!configured) return false; const { data: { user } } = await supabase.auth.getUser(); if (!user) return false; const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).maybeSingle(); return profile?.role || ''; }
async function updateProviderStatus(providerId, action, pauseReason) { return callFunction('provider-write', { action, provider_id: providerId, pause_reason: pauseReason }); }
async function uploadQR(providerId, file, displayName) {
  const path = `${providerId}/${crypto.randomUUID()}-${displayName.replace(/[^a-zA-Z0-9._-]/g, '_')}`;
  const { error: uploadError } = await supabase.storage.from('provider-qr').upload(path, file, { contentType: file.type, upsert: false });
  if (uploadError) throw uploadError;
  const { error } = await supabase.from('provider_qr_codes').insert({ provider_id: providerId, storage_path: path, display_name: displayName });
  if (error) { await supabase.storage.from('provider-qr').remove([path]); throw error; }
}
async function deleteQR(qr) {
  const { error } = await supabase.from('provider_qr_codes').delete().eq('id', qr.id);
  if (error) throw error;
  await supabase.storage.from('provider-qr').remove([qr.storagePath]);
}
async function saveCredential(providerId, password) { return callFunction('credential-reveal', { action: 'set', provider_id: providerId, password }); }
async function revealCredential(providerId) { const result = await callFunction('credential-reveal', { action: 'reveal', provider_id: providerId }); return result.password; }
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
async function manualUserPayout(providerId, amountUsdt, address, proof) { return callFunction('financial-write', { action: 'manual_user_payout', provider_id: providerId, amount_usdt: amountUsdt, destination_address: address, proof_tx_hash: proof?.txHash, proof_url: proof?.url, proof_note: proof?.note }); }
async function manualMerchantSettlement(amountUsdt, rate, proof) { return callFunction('financial-write', { action: 'manual_merchant_settlement', amount_usdt: amountUsdt, rate, proof_tx_hash: proof?.txHash, proof_url: proof?.url, proof_note: proof?.note }); }
export const backend = { configured, loadState, upsertProvider, writeSettings, postLedger, updateLedger, releaseLedger, callFunction, callPublicFunction, subscribe, login, logout, authenticated, updateProviderStatus, uploadQR, deleteQR, saveCredential, revealCredential, resolveShare, shareAction, rememberShareToken, markWithdrawalPaid, requestWithdrawal, manualUserPayout, manualMerchantSettlement };
if (typeof window !== 'undefined') window.SettleFlow = { ...(window.SettleFlow || {}), backend };
