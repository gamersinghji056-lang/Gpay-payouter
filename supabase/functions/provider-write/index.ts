import { adminClient, json, requireStaff } from "../_shared/auth.ts";

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String((error as { message?: unknown }).message) : "request failed";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const { admin, user, role } = await requireStaff(req);
    const body = await req.json();
    if (body.action === "upi_upsert") {
      if (!body.provider_id || !body.label || body.configured_limit_inr < 0 || body.allocated_limit_inr < 0) return json({ error: "invalid UPI account payload" }, 400);
      const { data, error } = await admin.from("provider_upi_accounts").upsert({ id: body.id || undefined, provider_id: body.provider_id, label: body.label.trim(), upi_id: body.upi_id ?? null, mobile: body.mobile ?? null, apk_mobile: body.apk_mobile ?? null, gpay_login_id: body.gpay_login_id ?? null, qr_data: body.qr_data ?? null, status: body.status || "active", merchant_operational: body.merchant_operational !== false, configured_limit_inr: Number(body.configured_limit_inr || 0), allocated_limit_inr: Number(body.allocated_limit_inr || 0), bank_name: body.bank_name || null, bank_account_number: body.bank_account_number || null, account_holder_name: body.account_holder_name || null, ifsc_code: body.ifsc_code || null, bank_branch: body.bank_branch || null, account_note: body.account_note || null, updated_at: new Date().toISOString() }, { onConflict: "provider_id,label" }).select().single();
      if (error) throw error;
      if (body.funding_model === "deposit" && body.allocated_limit_inr != null) { const { error: allocationError } = await admin.rpc("allocate_upi_capacity", { p_actor_id: user.id, p_upi_account_id: data.id, p_allocated_limit_inr: Number(body.allocated_limit_inr || 0) }); if (allocationError) throw allocationError; }
      await admin.from("audit_logs").insert({ actor_id: user.id, action: "upi_account_updated", entity_type: "provider_upi_account", entity_id: data.id, new_data: { ...body, gpay_password: undefined } });
      const { data: persisted, error: verifyError } = await admin.from("provider_upi_accounts").select("id,provider_id,label,upi_id,mobile,apk_mobile,gpay_login_id,qr_data,status,merchant_operational,configured_limit_inr,allocated_limit_inr,bank_name,bank_account_number,account_holder_name,ifsc_code,bank_branch,account_note").eq("id", data.id).single();
      if (verifyError) throw verifyError;
      return json({ data: persisted });
    }
    if (body.action === "upi_allocate") {
      if (!body.upi_account_id || body.allocated_limit_inr < 0) return json({ error: "invalid allocation payload" }, 400);
      const { data, error } = await admin.rpc("allocate_upi_capacity", { p_actor_id: user.id, p_upi_account_id: body.upi_account_id, p_allocated_limit_inr: Number(body.allocated_limit_inr) });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "upi_operational_status") {
      const { data, error } = await admin.rpc("set_upi_operational_status", { p_actor_id: user.id, p_upi_account_id: body.upi_account_id, p_operational: body.merchant_operational === true });
      if (error) throw error;
      return json({ data });
    }
    if (["pause", "resume", "delete", "restore"].includes(body.action)) {
      if (role !== "admin") return json({ error: "admin authorization required" }, 403);
      if (!body.provider_id || typeof body.provider_id !== "string") return json({ error: "provider_id required" }, 400);
      const { data: provider, error: readError } = await admin.from("providers").select("id,is_active,status,pause_reason").eq("id", body.provider_id).single();
      if (readError || !provider) return json({ error: "provider not found" }, 404);
      const nextStatus = body.action === "pause" ? "paused" : body.action === "delete" ? "deleted" : "active";
      if (body.action === "pause" && (!body.pause_reason || typeof body.pause_reason !== "string" || !body.pause_reason.trim())) return json({ error: "pause reason required" }, 400);
      const nextActive = nextStatus !== "deleted";
      const changes = { status: nextStatus, is_active: nextActive, pause_reason: nextStatus === "paused" ? body.pause_reason.trim() : null, paused_at: nextStatus === "paused" ? new Date().toISOString() : null, paused_by: nextStatus === "paused" ? user.id : null, updated_at: new Date().toISOString() };
      const { data, error } = await admin.from("providers").update(changes).eq("id", provider.id).select().single();
      if (error) throw error;
      const action = body.action === "pause" ? "provider_paused" : body.action === "delete" ? "provider_deleted" : "provider_resumed";
      const { error: auditError } = await admin.from("audit_logs").insert({ actor_id: user.id, action, entity_type: "provider", entity_id: provider.id, old_data: { status: provider.status, is_active: provider.is_active, pause_reason: provider.pause_reason }, new_data: { status: nextStatus, is_active: nextActive, pause_reason: changes.pause_reason } });
      if (auditError) throw auditError;
      return json({ data });
    }
    if (body.action !== "upsert" || !body.user_code || !body.name || !["deposit", "commission"].includes(body.funding_model)) return json({ error: "invalid provider payload" }, 400);
    const changes = {
      user_code: body.user_code, name: body.name, telegram_username: body.telegram_username ?? null, upi_id: body.upi_id ?? null,
      mobile: body.mobile ?? null, apk_mobile: body.apk_mobile ?? null, gpay_login_id: body.gpay_login_id ?? null,
      funding_model: body.funding_model, commission_limit_inr: Number(body.commission_limit_inr ?? 0),
      unique_deposit_address: String(body.unique_deposit_address || "").trim() || null, is_active: body.is_active !== false, updated_at: new Date().toISOString(),
    };
    let data;
    let error;
    if (body.provider_id) {
      ({ data, error } = await admin.from("providers").update(changes).eq("id", body.provider_id).select().single());
    } else {
      ({ data, error } = await admin.from("providers").upsert({ ...changes, created_by: user.id }, { onConflict: "user_code" }).select().single());
    }
    if (error) throw error;
    const { data: persisted, error: verifyError } = await admin.from("providers").select("*").eq("id", data.id).single();
    if (verifyError) throw verifyError;
    if (Number(persisted.commission_limit_inr || 0) !== changes.commission_limit_inr || persisted.funding_model !== changes.funding_model || persisted.name !== changes.name) throw new Error("provider update was not persisted");
    await admin.from("audit_logs").insert({ actor_id: user.id, action: "provider_upserted", entity_type: "provider", entity_id: persisted.id, new_data: body });
    return json({ data: persisted });
  } catch (error) { return json({ error: errorMessage(error) }, 400); }
});
