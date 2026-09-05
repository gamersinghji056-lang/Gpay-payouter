const http = require('node:http');
const { createClient } = require('@supabase/supabase-js');

const DEFAULT_BASE_URL = 'https://apilist.tronscanapi.com';
const DEFAULT_CONTRACT = 'TR7NHqjeKQxGTCi8qZY4pL8otSzgjLj6t';
const DEFAULT_INTERVAL_MS = 20000;
const LOOKBACK_MS = 30 * 1000;
const FUTURE_SKEW_MS = 2 * 60 * 1000;
const LATE_RECONCILE_MS = 60 * 60 * 1000;
const MAX_RETRIES = 3;

const config = {
  enabled: process.env.TRON_WATCH_ENABLED === 'true',
  intervalMs: Math.max(15000, Number(process.env.TRON_WATCH_INTERVAL_MS || DEFAULT_INTERVAL_MS)),
  baseUrl: (process.env.TRONSCAN_BASE_URL || DEFAULT_BASE_URL).replace(/\/$/, ''),
  network: process.env.TRON_NETWORK || 'mainnet',
  contract: process.env.TRC20_USDT_CONTRACT || DEFAULT_CONTRACT,
  apiKey: process.env.TRONSCAN_API_KEY || '',
  supabaseUrl: process.env.SUPABASE_URL || '',
  serviceRoleKey: process.env.SUPABASE_SERVICE_ROLE_KEY || '',
};

const status = { last_poll_at: null, last_success_at: null, pending_count: 0, last_error: null };

function log(event, details = {}) {
  console.log(JSON.stringify({ at: new Date().toISOString(), event, ...details }));
}

function assertConfiguration() {
  if (config.network !== 'mainnet') throw new Error('TRON_NETWORK must be mainnet');
  if (!config.apiKey || !config.supabaseUrl || !config.serviceRoleKey) throw new Error('watcher server configuration is incomplete');
  if (config.contract !== DEFAULT_CONTRACT) throw new Error('TRC20_USDT_CONTRACT must be the TRON mainnet USDT contract');
}

function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

async function fetchWithRetry(url) {
  let lastError;
  for (let attempt = 0; attempt < MAX_RETRIES; attempt += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await fetch(url, { headers: { accept: 'application/json', 'TRON-PRO-API-KEY': config.apiKey }, signal: controller.signal });
      if (!response.ok) throw new Error(`TRONSCAN HTTP ${response.status}`);
      return await response.json();
    } catch (error) {
      lastError = error;
      if (attempt < MAX_RETRIES - 1) await sleep(500 * (2 ** attempt));
    } finally { clearTimeout(timeout); }
  }
  throw lastError;
}

function decimalUnits(value, decimals) {
  const text = String(value).trim();
  if (!/^\d+(\.\d+)?$/.test(text)) throw new Error(`invalid decimal value: ${text}`);
  const [whole, fraction = ''] = text.split('.');
  if (fraction.length > decimals) return null;
  return BigInt(whole) * (10n ** BigInt(decimals)) + BigInt((fraction + '0'.repeat(decimals)).slice(0, decimals) || '0');
}

function transferIsFinal(tx, destination) {
  return tx && tx.to === destination && tx.contract_address === config.contract &&
    (tx.event_type || 'Transfer') === 'Transfer' && tx.confirmed === 1 && tx.revert === 0 &&
    tx.contract_ret === 'SUCCESS' && tx.final_result === 'SUCCESS' &&
    (tx.status === 0 || tx.status === '0' || tx.status === 'SUCCESS');
}

function transferAmountMatches(tx, response, expected) {
  const decimals = Number(tx.decimals ?? response.tokenInfo?.tokenDecimal);
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 18 || !response.tokenInfo || response.tokenInfo.tokenId !== config.contract) return false;
  const expectedUnits = decimalUnits(expected, decimals);
  if (expectedUnits === null || !/^\d+$/.test(String(tx.amount || ''))) return false;
  return BigInt(tx.amount) === expectedUnits;
}

async function expireRequest(supabase, request) {
  if (request.status === 'expired') return;
  const { error } = await supabase.from('deposit_requests').update({ status: 'expired' }).eq('id', request.id).in('status', ['waiting', 'checking']);
  if (error) throw error;
  log('deposit_expired', { deposit_id: request.id });
}

async function inspectRequest(supabase, request, usedHashes) {
  const createdAt = new Date(request.created_at).getTime();
  const expiresAt = new Date(request.expires_at || (createdAt + 5 * 60 * 1000)).getTime();
  if (!request.destination_address || !request.expected_usdt || !Number.isFinite(createdAt)) {
    log('malformed_deposit_request', { deposit_id: request.id });
    return;
  }
  if (Number.isFinite(expiresAt) && Date.now() > expiresAt + LATE_RECONCILE_MS) {
    await expireRequest(supabase, request);
    return;
  }
  const query = new URL(`${config.baseUrl}/api/token_trc20/transfers-with-status`);
  query.search = new URLSearchParams({ limit: '50', start: '0', trc20Id: config.contract, address: request.destination_address, direction: '2', reverse: 'true', start_timestamp: String(Math.max(0, createdAt - LOOKBACK_MS)) }).toString();
  let response;
  try { response = await fetchWithRetry(query); } catch (error) { log('api_request_failure', { deposit_id: request.id, message: error.message }); throw error; }
  if (!response || !Array.isArray(response.data) || !response.tokenInfo) {
    log('malformed_api_response', { deposit_id: request.id });
    return;
  }
  let matched;
  for (const tx of response.data) {
    const timestamp = Number(tx.block_timestamp);
    const candidate = transferIsFinal(tx, request.destination_address) && Number.isFinite(timestamp) &&
      timestamp >= createdAt - LOOKBACK_MS && timestamp <= expiresAt + FUTURE_SKEW_MS &&
      transferAmountMatches(tx, response, request.expected_usdt);
    if (!candidate) { log('unmatched_transaction', { deposit_id: request.id, tx_hash: tx.hash || null }); continue; }
    if (usedHashes.has(tx.hash)) { log('duplicate_tx_skipped', { deposit_id: request.id, tx_hash: tx.hash }); continue; }
    matched = tx;
    break;
  }
  if (!matched) {
    if (Number.isFinite(expiresAt) && Date.now() > expiresAt) await expireRequest(supabase, request);
    return;
  }
  log('matched_transaction', { deposit_id: request.id, provider_id: request.provider_id, tx_hash: matched.hash });
  const { data, error } = await supabase.rpc('confirm_deposit', { p_actor_id: null, p_deposit_id: request.id, p_tx_hash: matched.hash, p_source: 'blockchain' });
  if (error) {
    if (/already credited|already confirmed/i.test(error.message)) { log('duplicate_tx_skipped', { deposit_id: request.id, tx_hash: matched.hash }); return; }
    throw error;
  }
  usedHashes.add(matched.hash);
  log('confirmation_success', { deposit_id: request.id, tx_hash: matched.hash, confirmed_id: data?.id || request.id });
}

async function pollOnce(supabase) {
  status.last_poll_at = new Date().toISOString();
  const cutoff = new Date(Date.now() - LATE_RECONCILE_MS).toISOString();
  const { data: requests, error } = await supabase.from('deposit_requests').select('id,provider_id,destination_address,expected_usdt,created_at,expires_at,status').in('status', ['waiting', 'checking', 'expired']).gte('expires_at', cutoff).order('created_at', { ascending: true });
  if (error) throw error;
  status.pending_count = requests.length;
  log('pending_requests', { count: requests.length });
  const { data: existing, error: existingError } = await supabase.from('deposit_requests').select('tx_hash').not('tx_hash', 'is', null);
  if (existingError) throw existingError;
  const usedHashes = new Set(existing.map(row => row.tx_hash));
  let requestFailures = false;
  for (const request of requests) {
    try { await inspectRequest(supabase, request, usedHashes); }
    catch (error) { requestFailures = true; status.last_error = error.message; log('request_processing_failure', { deposit_id: request.id, message: error.message }); }
  }
  if (!requestFailures) { status.last_success_at = new Date().toISOString(); status.last_error = null; }
}

function healthServer() {
  const port = Number(process.env.TRON_WATCH_HEALTH_PORT || process.env.PORT || 8080);
  const server = http.createServer((req, res) => {
    if (req.url !== '/health' && req.url !== '/status') { res.writeHead(404); return res.end('not found'); }
    res.writeHead(config.enabled && !status.last_error ? 200 : 503, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ enabled: config.enabled, ...status }));
  });
  server.listen(port, () => log('health_server_started', { port }));
  return server;
}

async function startWatcher() {
  if (process.env.TRON_WATCH_HEALTH !== 'false') healthServer();
  if (!config.enabled) { log('watcher_disabled'); return; }
  assertConfiguration();
  const supabase = createClient(config.supabaseUrl, config.serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  log('watcher_started', { interval_ms: config.intervalMs, network: config.network, contract: config.contract });
  let running = false;
  const run = async () => { if (running) { log('poll_skipped_overlap'); return; } running = true; try { await pollOnce(supabase); } catch (error) { status.last_error = error.message; log('poll_failure', { message: error.message }); } finally { running = false; } };
  await run();
  setInterval(run, config.intervalMs);
}

if (require.main === module) startWatcher().catch(error => { status.last_error = error.message; log('watcher_start_failure', { message: error.message }); process.exitCode = 1; });

module.exports = { config, status, decimalUnits, transferIsFinal, transferAmountMatches, pollOnce, startWatcher };
