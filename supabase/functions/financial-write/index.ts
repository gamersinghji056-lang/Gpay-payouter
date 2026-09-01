import { adminClient, json, requireStaff } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const { admin, user } = await requireStaff(req);
    const body = await req.json();
    const { data: provider } = await admin.from("providers").select("status,is_active,pause_reason").eq("id", body.provider_id).maybeSingle();
    if (!provider || !provider.is_active || provider.status === "deleted") return json({ error: "provider is unavailable" }, 409);
    if (provider.status === "paused") return json({ error: `Provider is paused: ${provider.pause_reason || "temporarily unavailable"}` }, 409);
    const { data, error } = await admin.rpc("post_ledger_entry", {
      p_actor_id: user.id, p_provider_id: body.provider_id, p_entry_type: body.entry_type,
      p_amount_inr: body.amount_inr ?? null, p_amount_usdt: body.amount_usdt ?? null,
      p_rate: body.rate ?? null, p_bank_name: body.bank_name ?? null, p_account_number: body.account_number ?? null,
      p_transaction_date: body.transaction_date ?? new Date().toISOString().slice(0, 10),
      p_reference_no: body.reference_no ?? null, p_note: body.note ?? null,
      p_status: body.status ?? "posted", p_idempotency_key: body.idempotency_key ?? null,
    });
    if (error) throw error;
    return json({ data });
  } catch (error) { return json({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
