import { adminClient, json, requireStaff } from "../_shared/auth.ts";

function msg(error: unknown) {
  return error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String((error as { message?: unknown }).message) : "request failed";
}

function clampLimit(value: unknown) {
  const n = Number(value || 50);
  return Math.max(1, Math.min(100, Number.isFinite(n) ? n : 50));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const body = await req.json();
    const admin = adminClient();
    const source = String(body.source || "ledger");
    const limit = clampLimit(body.limit);
    const offset = Math.max(0, Number(body.offset || 0));
    let role = "admin";
    let providerId = "";

    if (body.session_token) {
      const { data: acct, error } = await admin.rpc("portal_account_from_token", { p_token: body.session_token });
      if (error || !acct || acct.role !== body.role) throw error || new Error("access denied");
      role = acct.role;
      providerId = acct.provider_id || "";
    } else {
      await requireStaff(req);
    }

    const providerRows = role === "user" && providerId
      ? await admin.from("providers").select("id,user_code").eq("id", providerId)
      : await admin.from("providers").select("id,user_code");
    if (providerRows.error) throw providerRows.error;
    const idsByProvider = new Map((providerRows.data || []).map((p) => [p.id, p.user_code]));

    let query: any;
    if (source === "ledger") {
      query = admin.from("ledger_entries")
        .select("id,provider_id,upi_account_id,entry_type,credit_rate,amount_inr,amount_usdt,rate,merchant_commission_rate,merchant_commission_inr,bank_name,account_number,transaction_date,note,status,created_at,updated_at,idempotency_key,is_voided,voided_at,void_reason,edited_at,edit_reason")
        .order("transaction_date", { ascending: false }).order("created_at", { ascending: false }).order("id", { ascending: false });
      if (role === "user") query = query.eq("provider_id", providerId);
      if (role === "merchant") query = query.eq("entry_type", "collection");
    } else if (source === "deposits") {
      if (role === "merchant") return json({ source, records: [], has_more: false });
      query = admin.from("deposit_requests")
        .select("id,provider_id,requested_usdt,expected_usdt,rate,inr_value,destination_address,status,tx_hash,created_at,confirmed_at,source")
        .order("created_at", { ascending: false }).order("id", { ascending: false });
      if (role === "user") query = query.eq("provider_id", providerId);
    } else if (source === "withdrawals") {
      query = admin.from("withdrawal_requests")
        .select("id,requester_type,provider_id,upi_account_id,amount_usdt,rate,amount_inr,destination_address,status,proof_tx_hash,proof_url,proof_note,created_at,paid_at,is_voided,voided_at,void_reason,edited_at,edit_reason")
        .order("created_at", { ascending: false }).order("id", { ascending: false });
      if (role === "user") query = query.eq("requester_type", "provider").eq("provider_id", providerId);
      if (role === "merchant") query = query.eq("requester_type", "merchant");
    } else if (source === "merchant_settlements") {
      if (role === "user") return json({ source, records: [], has_more: false });
      query = admin.from("merchant_settlements")
        .select("id,amount_usdt,rate,amount_inr,commission_inr,proof_tx_hash,proof_url,proof_note,created_at")
        .order("created_at", { ascending: false }).order("id", { ascending: false });
    } else if (source === "merchant_charges") {
      if (role === "user") return json({ source, records: [], has_more: false });
      query = admin.from("merchant_charges")
        .select("id,provider_id,upi_account_id,amount_inr,user_name,upi_id,mobile,charge_date,reference,note,status,created_at")
        .order("charge_date", { ascending: false }).order("created_at", { ascending: false }).order("id", { ascending: false });
    } else {
      return json({ error: "invalid history source" }, 400);
    }

    const { data, error } = await query.range(offset, offset + limit);
    if (error) throw error;
    const rows = data || [];
    const page = rows.slice(0, limit);
    const records = page.map((r: any) => {
      if (source === "ledger") return { id: r.id, userId: idsByProvider.get(r.provider_id) || r.provider_id, accountId: r.upi_account_id || "", type: r.entry_type, creditRate: r.credit_rate, amount: r.amount_inr == null ? undefined : Number(r.amount_inr), usdt: r.amount_usdt == null ? undefined : Number(r.amount_usdt), rate: r.rate == null ? undefined : Number(r.rate), merchantCommissionRate: r.merchant_commission_rate, merchantCommissionInr: r.merchant_commission_inr, bank: r.bank_name || "", account: r.account_number || "", date: r.transaction_date, note: r.note || "", status: r.status, createdAt: r.created_at, updatedAt: r.updated_at, idempotencyKey: r.idempotency_key || r.id, isVoided: r.is_voided === true, voidedAt: r.voided_at || "", voidReason: r.void_reason || "", editedAt: r.edited_at || "", editReason: r.edit_reason || "" };
      if (source === "deposits") return { id: r.id, userId: idsByProvider.get(r.provider_id) || r.provider_id, requestedUsdt: Number(r.requested_usdt), expectedUsdt: Number(r.expected_usdt), rate: Number(r.rate), inrValue: Number(r.inr_value), address: r.destination_address, status: r.status, txHash: r.tx_hash || "", createdAt: r.created_at, confirmedAt: r.confirmed_at || "", source: r.source };
      if (source === "withdrawals") return { id: r.id, requesterType: r.requester_type, userId: idsByProvider.get(r.provider_id) || r.provider_id, accountId: r.upi_account_id || "", amountUsdt: Number(r.amount_usdt), rate: Number(r.rate), amountInr: Number(r.amount_inr), address: r.destination_address, status: r.status, proofTxHash: r.proof_tx_hash || "", proofUrl: r.proof_url || "", proofNote: r.proof_note || "", createdAt: r.created_at, paidAt: r.paid_at || "", isVoided: r.is_voided === true, voidedAt: r.voided_at || "", voidReason: r.void_reason || "", editedAt: r.edited_at || "", editReason: r.edit_reason || "" };
      if (source === "merchant_settlements") return { id: r.id, amountUsdt: Number(r.amount_usdt), rate: Number(r.rate), amountInr: Number(r.amount_inr), commissionInr: Number(r.commission_inr || 0), proofTxHash: r.proof_tx_hash || "", proofUrl: r.proof_url || "", proofNote: r.proof_note || "", createdAt: r.created_at };
      return { id: r.id, providerId: r.provider_id, upiAccountId: r.upi_account_id, amountInr: Number(r.amount_inr), userName: r.user_name, upiId: r.upi_id || "", mobile: r.mobile || "", date: r.charge_date, reference: r.reference || "", note: r.note || "", status: r.status, createdAt: r.created_at };
    });
    return json({ source, records, has_more: rows.length > limit });
  } catch (error) {
    return json({ error: msg(error) }, 400);
  }
});
