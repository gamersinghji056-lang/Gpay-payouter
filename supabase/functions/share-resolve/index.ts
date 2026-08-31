import { adminClient, json } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const body = await req.json();
    const token = String(body.token || "");
    if (token.length < 32) return json({ error: "invalid share token" }, 401);
    const admin = adminClient();
    const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
    const tokenHash = [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join("");
    const { data: link, error: linkError } = await admin.from("share_links").select("id,scope,provider_id,is_active,expires_at").eq("token_hash", tokenHash).maybeSingle();
    if (linkError || !link || !link.is_active || (link.expires_at && new Date(link.expires_at) <= new Date())) return json({ error: "share link is invalid or revoked" }, 401);
    await admin.from("share_links").update({ last_accessed_at: new Date().toISOString() }).eq("id", link.id);
    let query = admin.from("providers").select("id,user_code,name,telegram_username,upi_id,mobile,apk_mobile,gpay_login_id,funding_model,commission_limit_inr,unique_deposit_address,is_active").eq("is_active", true);
    if (link.scope === "user") query = query.eq("id", link.provider_id);
    const { data: providers, error } = await query;
    if (error) throw error;
    const state = { settings: { settlementRate: 107, depositBaseRate: 107, depositMarkupPct: 3, commissionRate: 3.5, adminTrc20Address: "", usdtContract: "" }, users: [], entries: [], deposits: [], audit: [] } as any;
    for (const provider of providers || []) {
      const { data: account } = await admin.rpc("accounting_for_provider", { p_provider_id: provider.id });
      state.users.push({ id: provider.user_code, remoteId: provider.id, name: provider.name, telegram: provider.telegram_username || "", upi: provider.upi_id || "", mobile: provider.mobile || "", apk: provider.apk_mobile || "", gpayLogin: provider.gpay_login_id || "", qrs: [], fundingMode: provider.funding_model, limit: Number(provider.commission_limit_inr || 0), depositAddress: provider.unique_deposit_address || "", token: link.scope === "user" ? token : "", active: provider.is_active });
    }
    const ids = (providers || []).map(provider => provider.id);
    const [ledger, deposits] = await Promise.all([
      admin.from("ledger_entries").select("*").in("provider_id", ids),
      admin.from("deposit_requests").select("*").in("provider_id", ids),
    ]);
    for (const row of ledger.data || []) { if (link.scope === "user" || row.entry_type === "collection") state.entries.push({ id: row.id, userId: (providers || []).find(provider => provider.id === row.provider_id)?.user_code, type: row.entry_type, amount: row.amount_inr, usdt: row.amount_usdt, rate: row.rate, bank: row.bank_name, account: row.account_number, date: row.transaction_date, note: row.note, status: row.status }); }
    if (link.scope === "user") for (const row of deposits.data || []) state.deposits.push({ id: row.id, userId: (providers || []).find(provider => provider.id === row.provider_id)?.user_code, requestedUsdt: row.requested_usdt, expectedUsdt: row.expected_usdt, rate: row.rate, inrValue: row.inr_value, address: row.destination_address, status: row.status, txHash: row.tx_hash, createdAt: row.created_at, confirmedAt: row.confirmed_at, source: row.source });
    return json({ scope: link.scope, state });
  } catch (error) { return json({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
