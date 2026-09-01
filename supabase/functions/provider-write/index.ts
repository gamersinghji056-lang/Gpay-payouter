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
      unique_deposit_address: body.unique_deposit_address ?? null, is_active: body.is_active !== false, updated_at: new Date().toISOString(),
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
