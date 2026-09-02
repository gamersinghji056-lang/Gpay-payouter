import { adminClient, json } from "../_shared/auth.ts";

function msg(error: unknown) { return error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String((error as { message?: unknown }).message) : "request failed"; }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const body = await req.json();
    const admin = adminClient();
    const { data: acct, error: acctError } = await admin.rpc("portal_account_from_token", { p_token: body.session_token });
    if (acctError || !acct || acct.role !== body.role) throw acctError || new Error("access denied");
    let providerQuery = admin.from("providers").select("id,user_code,name,telegram_username,upi_id,mobile,apk_mobile,gpay_login_id,funding_model,commission_limit_inr,unique_deposit_address,is_active,status,pause_reason").in("status", ["active", "paused"]);
    if (acct.role === "user") providerQuery = providerQuery.eq("id", acct.provider_id);
    const { data: providers, error } = await providerQuery;
    if (error) throw error;
    const ids = (providers || []).map((p) => p.id);
    const [settings, ledger, deposits, qrs, settlements, withdrawals, upiAccounts, charges, portalAccounts] = await Promise.all([
      admin.from("app_settings").select("settlement_rate,deposit_base_rate,deposit_markup_pct,commission_rate_pct,admin_trc20_address,trc20_usdt_contract").eq("id", true).maybeSingle(),
      ids.length ? admin.from("ledger_entries").select("id,provider_id,upi_account_id,entry_type,credit_rate,amount_inr,amount_usdt,rate,merchant_commission_rate,merchant_commission_inr,bank_name,account_number,transaction_date,note,status,created_at,updated_at,idempotency_key").in("provider_id", ids).order("transaction_date", { ascending: false }).limit(acct.role === "user" ? 250 : 500) : Promise.resolve({ data: [], error: null }),
      acct.role === "user" && ids.length ? admin.from("deposit_requests").select("id,provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,status,tx_hash,created_at,confirmed_at,source").in("provider_id", ids).order("created_at", { ascending: false }).limit(250) : Promise.resolve({ data: [], error: null }),
      ids.length ? admin.from("provider_qr_codes").select("id,provider_id,upi_account_id,storage_path,display_name").in("provider_id", ids) : Promise.resolve({ data: [], error: null }),
      acct.role === "merchant" ? admin.from("merchant_settlements").select("id,amount_usdt,rate,amount_inr,commission_inr,proof_tx_hash,proof_url,proof_note,created_at").order("created_at", { ascending: false }).limit(500) : Promise.resolve({ data: [], error: null }),
      acct.role === "merchant" ? admin.from("withdrawal_requests").select("id,requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,status,proof_tx_hash,proof_url,proof_note,created_at,paid_at").eq("requester_type", "merchant").in("status", ["pending", "paid"]).order("created_at", { ascending: false }).limit(500) : acct.role === "user" ? admin.from("withdrawal_requests").select("id,requester_type,provider_id,amount_usdt,rate,amount_inr,destination_address,status,proof_tx_hash,proof_url,proof_note,created_at,paid_at").eq("requester_type", "provider").eq("provider_id", acct.provider_id).in("status", ["pending", "paid"]).order("created_at", { ascending: false }).limit(250) : Promise.resolve({ data: [], error: null }),
      ids.length ? admin.from("provider_upi_accounts").select("id,provider_id,label,upi_id,mobile,apk_mobile,gpay_login_id,qr_data,status,merchant_operational,configured_limit_inr,allocated_limit_inr,bank_name,bank_account_number,account_holder_name,ifsc_code,bank_branch,account_note").in("provider_id", ids) : Promise.resolve({ data: [], error: null }),
      acct.role === "merchant" ? admin.from("merchant_charges").select("id,provider_id,upi_account_id,amount_inr,user_name,upi_id,mobile,charge_date,reference,note,status,created_at").eq("status", "active").order("charge_date", { ascending: false }).limit(500) : Promise.resolve({ data: [], error: null }),
      admin.from("portal_accounts").select("id,role,provider_id,login_id,is_active,last_login_at,created_at").order("role").order("login_id"),
    ]);
    const anyError = [settings, ledger, deposits, qrs, settlements, withdrawals, upiAccounts, charges, portalAccounts].find((x: any) => x.error)?.error;
    if (anyError) throw anyError;
    const pa = new Map(await Promise.all((providers || []).map(async (p) => [p.id, (await admin.rpc("accounting_for_provider", { p_provider_id: p.id })).data?.[0] || {}] as const)));
    const ua = new Map(await Promise.all((upiAccounts.data || []).map(async (a) => [a.id, (await admin.rpc("accounting_for_upi", { p_upi_account_id: a.id })).data?.[0] || {}] as const)));
    const sq = new Map(await Promise.all((qrs.data || []).map(async (q) => [q.id, (await admin.storage.from("provider-qr").createSignedUrl(q.storage_path, 300)).data?.signedUrl || ""] as const)));
    const idsByProvider = new Map((providers || []).map((p) => [p.id, p.user_code]));
    const state: any = { settings: { settlementRate: Number(settings.data?.settlement_rate || 107), depositBaseRate: Number(settings.data?.deposit_base_rate || 107), depositMarkupPct: Number(settings.data?.deposit_markup_pct ?? 3), commissionRate: Number(settings.data?.commission_rate_pct || 3.5), adminTrc20Address: settings.data?.admin_trc20_address || "", usdtContract: settings.data?.trc20_usdt_contract || "" }, users: [], entries: [], deposits: [], withdrawals: [], merchantSettlements: settlements.data || [], merchantCharges: (charges.data || []).map((r) => ({ id: r.id, providerId: r.provider_id, upiAccountId: r.upi_account_id, amountInr: Number(r.amount_inr), userName: r.user_name, upiId: r.upi_id || "", mobile: r.mobile || "", date: r.charge_date, reference: r.reference || "", note: r.note || "", status: r.status, createdAt: r.created_at })), portalAccounts: portalAccounts.data || [], audit: [] };
    for (const p of providers || []) {
      const user: any = { id: p.user_code, remoteId: p.id, name: p.name, telegram: p.telegram_username || "", upi: p.upi_id || "", mobile: p.mobile || "", apk: p.apk_mobile || "", gpayLogin: p.gpay_login_id || "", qrs: [], token: "", active: p.is_active, status: p.status, pauseReason: p.pause_reason || "", fundingMode: p.funding_model, limit: Number(p.commission_limit_inr || 0), depositAddress: p.unique_deposit_address || "", uniqueDepositAddress: p.unique_deposit_address || "", companyDepositAddress: settings.data?.admin_trc20_address || "", resolvedDepositAddress: p.unique_deposit_address || settings.data?.admin_trc20_address || "", accounting: pa.get(p.id) || {}, upiAccounts: [] };
      user.qrs = (qrs.data || []).filter((q) => q.provider_id === p.id && !q.upi_account_id).map((q) => ({ id: q.id, name: q.display_name || "QR", storagePath: q.storage_path, data: sq.get(q.id) || "" }));
      user.upiAccounts = (upiAccounts.data || []).filter((a) => a.provider_id === p.id).map((a) => { const v: any = ua.get(a.id) || {}; return { id: a.id, label: a.label, upi: a.upi_id || "", mobile: a.mobile || "", apk: a.apk_mobile || "", gpayLogin: a.gpay_login_id || "", qrData: a.qr_data || "", status: a.status, merchantOperational: a.merchant_operational, configuredLimit: Number(a.configured_limit_inr || 0), allocatedLimit: Number(a.allocated_limit_inr || 0), bankName: a.bank_name || "", bankAccountNumber: a.bank_account_number || "", accountHolderName: a.account_holder_name || "", ifscCode: a.ifsc_code || "", bankBranch: a.bank_branch || "", accountNote: a.account_note || "", accounting: v, collection: Number(v.total_collection_inr || 0), availableLimit: Number(v.available_limit_inr || 0), qrs: (qrs.data || []).filter((q) => q.upi_account_id === a.id).map((q) => ({ id: q.id, name: q.display_name || "QR", storagePath: q.storage_path, data: sq.get(q.id) || "" })) }; });
      state.users.push(user);
    }
    state.entries = (ledger.data || []).filter((r) => acct.role !== "agent" || r.entry_type === "collection").map((r) => ({ id: r.id, userId: idsByProvider.get(r.provider_id) || r.provider_id, accountId: r.upi_account_id || "", type: r.entry_type, creditRate: r.credit_rate, amount: r.amount_inr == null ? undefined : Number(r.amount_inr), usdt: r.amount_usdt == null ? undefined : Number(r.amount_usdt), rate: r.rate == null ? undefined : Number(r.rate), merchantCommissionRate: r.merchant_commission_rate, merchantCommissionInr: r.merchant_commission_inr, bank: r.bank_name || "", account: r.account_number || "", date: r.transaction_date, note: r.note || "", status: r.status, createdAt: r.created_at, updatedAt: r.updated_at, idempotencyKey: r.idempotency_key || r.id }));
    state.deposits = (deposits.data || []).map((r) => ({ id: r.id, userId: idsByProvider.get(r.provider_id) || r.provider_id, requestedUsdt: r.requested_usdt, expectedUsdt: r.expected_usdt, rate: r.rate, inrValue: r.inr_value, address: r.destination_address, status: r.status, txHash: r.tx_hash || "", createdAt: r.created_at, confirmedAt: r.confirmed_at || "", source: r.source }));
    state.withdrawals = (withdrawals.data || []).map((r) => ({ id: r.id, requesterType: r.requester_type, userId: idsByProvider.get(r.provider_id) || r.provider_id, amountUsdt: Number(r.amount_usdt), rate: Number(r.rate), amountInr: Number(r.amount_inr), address: r.destination_address, status: r.status, proofTxHash: r.proof_tx_hash || "", proofUrl: r.proof_url || "", proofNote: r.proof_note || "", createdAt: r.created_at, paidAt: r.paid_at || "" }));
    if (acct.role === "merchant") {
      const [{ data: available }, { data: summaryRows }] = await Promise.all([admin.rpc("merchant_available_balance_inr"), admin.rpc("merchant_accounting_summary")]);
      const summary = Array.isArray(summaryRows) ? summaryRows[0] : summaryRows;
      const availableInr = Number(summary?.available_inr ?? available ?? 0);
      state.merchantSettlement = {
        totalCollectionInr: Number(summary?.total_collection_inr ?? 0),
        frozenInr: Number(summary?.frozen_inr ?? 0),
        settledInr: Number(summary ? Number(summary.merchant_ledger_settled_inr || 0) + Number(summary.manual_settled_inr || 0) : 0),
        settledUsdt: Number(summary?.manual_settled_usdt ?? 0),
        commissionEarnedInr: Number(summary?.merchant_commission_inr ?? 0),
        chargesInr: Number(summary?.charges_inr ?? 0),
        reservedInr: Number(summary?.reserved_inr ?? 0),
        availableInr,
        availableUsdt: availableInr / Number(settings.data?.settlement_rate || 107),
      };
    }
    return json({ role: acct.role, provider_id: acct.provider_id, state });
  } catch (error) { return json({ error: msg(error) }, 400); }
});
