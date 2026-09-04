import { adminClient, json, requireStaff } from "../_shared/auth.ts";

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String((error as { message?: unknown }).message) : "request failed";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const { admin, user } = await requireStaff(req);
    const body = await req.json();
    if (body.action === "merchant_charge") {
      const { data, error } = await admin.rpc("add_merchant_charge", { p_actor_id: user.id, p_provider_id: body.provider_id, p_upi_account_id: body.upi_account_id ?? null, p_amount_inr: body.amount_inr, p_user_name: body.user_name, p_upi_id: body.upi_id ?? null, p_mobile: body.mobile ?? null, p_charge_date: body.charge_date ?? null, p_reference: body.reference ?? null, p_note: body.note ?? null, p_idempotency_key: body.idempotency_key ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "merchant_charge_reverse") {
      const { data, error } = await admin.rpc("reverse_merchant_charge", { p_actor_id: user.id, p_charge_id: body.charge_id, p_idempotency_key: body.idempotency_key ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "manual_user_payout") {
      const { data, error } = await admin.rpc("admin_manual_user_payout", { p_actor_id: user.id, p_provider_id: body.provider_id, p_amount_usdt: body.amount_usdt, p_destination_address: body.destination_address, p_proof_tx_hash: body.proof_tx_hash ?? null, p_proof_url: body.proof_url ?? null, p_proof_note: body.proof_note ?? null, p_idempotency_key: body.idempotency_key ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "manual_merchant_settlement") {
      const { data, error } = await admin.rpc("admin_manual_merchant_settlement", { p_actor_id: user.id, p_amount_usdt: body.amount_usdt, p_rate: body.rate ?? 107, p_proof_tx_hash: body.proof_tx_hash ?? null, p_proof_url: body.proof_url ?? null, p_proof_note: body.proof_note ?? null, p_idempotency_key: body.idempotency_key ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "mark_withdrawal_paid") {
      const { data, error } = await admin.rpc("mark_withdrawal_paid", { p_actor_id: user.id, p_request_id: body.request_id, p_proof_tx_hash: body.proof_tx_hash ?? null, p_proof_url: body.proof_url ?? null, p_proof_note: body.proof_note ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "admin_update_ledger") {
      const { data, error } = await admin.rpc("admin_update_ledger_entry", { p_actor_id: user.id, p_entry_id: body.entry_id, p_provider_id: body.provider_id, p_upi_account_id: body.upi_account_id ?? null, p_amount_inr: body.amount_inr ?? null, p_amount_usdt: body.amount_usdt ?? null, p_rate: body.rate ?? null, p_bank_name: body.bank_name ?? null, p_account_number: body.account_number ?? null, p_transaction_date: body.transaction_date ?? null, p_note: body.note ?? null, p_status: body.status ?? null, p_reason: body.reason ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "admin_void_ledger") {
      const { data, error } = await admin.rpc("admin_void_ledger_entry", { p_actor_id: user.id, p_entry_id: body.entry_id, p_reason: body.reason ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "admin_update_withdrawal") {
      const { data, error } = await admin.rpc("admin_update_withdrawal_request", { p_actor_id: user.id, p_request_id: body.request_id, p_upi_account_id: body.upi_account_id ?? null, p_amount_usdt: body.amount_usdt, p_rate: body.rate ?? 107, p_destination_address: body.destination_address, p_status: body.status, p_proof_tx_hash: body.proof_tx_hash ?? null, p_proof_url: body.proof_url ?? null, p_proof_note: body.proof_note ?? null, p_reason: body.reason ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "admin_void_withdrawal") {
      const { data, error } = await admin.rpc("admin_void_withdrawal_request", { p_actor_id: user.id, p_request_id: body.request_id, p_reason: body.reason ?? null });
      if (error) throw error;
      return json({ data });
    }
    const { data: provider } = await admin.from("providers").select("status,is_active,pause_reason").eq("id", body.provider_id).maybeSingle();
    if (!provider || !provider.is_active || provider.status === "deleted") return json({ error: "provider is unavailable" }, 409);
    if (provider.status === "paused") return json({ error: `Provider is paused: ${provider.pause_reason || "temporarily unavailable"}` }, 409);
    if (body.action === "update" || body.action === "release") {
      if (!body.entry_id || typeof body.entry_id !== "string") return json({ error: "entry_id required" }, 400);
      const changes = body.action === "release" ? { status: "released", updated_at: new Date().toISOString() } : {
        entry_type: body.entry_type, amount_inr: body.amount_inr ?? null, amount_usdt: body.amount_usdt ?? null,
        rate: body.rate ?? null, bank_name: body.bank_name ?? null, account_number: body.account_number ?? null,
        transaction_date: body.transaction_date, note: body.note ?? null, status: body.status ?? "posted", updated_at: new Date().toISOString(),
      };
      const { data, error } = await admin.from("ledger_entries").update(changes).eq("id", body.entry_id).eq("provider_id", body.provider_id).select().single();
      if (error) throw error;
      const { error: auditError } = await admin.from("audit_logs").insert({ actor_id: user.id, action: body.action === "release" ? "frozen_released" : "ledger_corrected", entity_type: "ledger_entry", entity_id: body.entry_id, new_data: changes });
      if (auditError) throw auditError;
      return json({ data });
    }
    const { data, error } = await admin.rpc("post_ledger_entry", {
      p_actor_id: user.id, p_provider_id: body.provider_id, p_entry_type: body.entry_type,
      p_amount_inr: body.amount_inr ?? null, p_amount_usdt: body.amount_usdt ?? null,
      p_rate: body.rate ?? null, p_bank_name: body.bank_name ?? null, p_account_number: body.account_number ?? null,
      p_transaction_date: body.transaction_date ?? new Date().toISOString().slice(0, 10),
      p_reference_no: body.reference_no ?? null, p_note: body.note ?? null,
      p_status: body.status ?? "posted", p_idempotency_key: body.idempotency_key ?? null,
    });
    if (error) throw error;
    let resultData = data;
    if (body.entry_type === "merchant_usdt") {
      const commissionRate = Number(body.merchant_commission_rate ?? 4.5);
      if (!Number.isFinite(commissionRate) || commissionRate < 0 || commissionRate > 100) return json({ error: "invalid merchant commission rate" }, 400);
      const commissionInr = Math.round(Number(body.amount_usdt || 0) * Number(body.rate || 0) * commissionRate) / 100;
      const { data: updated, error: commissionError } = await admin.from("ledger_entries").update({ merchant_commission_rate: commissionRate, merchant_commission_inr: commissionInr }).eq("id", data.id).select().single();
      if (commissionError) throw commissionError;
      resultData = updated;
    }
    return json({ data: resultData });
  } catch (error) { return json({ error: errorMessage(error) }, 400); }
});
