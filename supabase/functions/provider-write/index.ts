import { adminClient, json, requireStaff } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const { admin, user, role } = await requireStaff(req);
    const body = await req.json();
    if (body.action === "archive" || body.action === "restore") {
      if (role !== "admin") return json({ error: "admin authorization required" }, 403);
      if (!body.provider_id || typeof body.provider_id !== "string") return json({ error: "provider_id required" }, 400);
      const { data: provider, error: readError } = await admin.from("providers").select("id,is_active").eq("id", body.provider_id).single();
      if (readError || !provider) return json({ error: "provider not found" }, 404);
      const nextActive = body.action === "restore";
      const { data, error } = await admin.from("providers").update({ is_active: nextActive, updated_at: new Date().toISOString() }).eq("id", provider.id).select().single();
      if (error) throw error;
      const { error: auditError } = await admin.from("audit_logs").insert({ actor_id: user.id, action: nextActive ? "provider_restored" : "provider_archived", entity_type: "provider", entity_id: provider.id, old_data: { is_active: provider.is_active }, new_data: { is_active: nextActive } });
      if (auditError) throw auditError;
      return json({ data });
    }
    if (body.action !== "upsert" || !body.user_code || !body.name || !["deposit", "commission"].includes(body.funding_model)) return json({ error: "invalid provider payload" }, 400);
    const { data, error } = await admin.from("providers").upsert({
      user_code: body.user_code, name: body.name, telegram_username: body.telegram_username ?? null, upi_id: body.upi_id ?? null,
      mobile: body.mobile ?? null, apk_mobile: body.apk_mobile ?? null, gpay_login_id: body.gpay_login_id ?? null,
      funding_model: body.funding_model, commission_limit_inr: body.commission_limit_inr ?? 0,
      unique_deposit_address: body.unique_deposit_address ?? null, is_active: body.is_active !== false, created_by: user.id,
    }, { onConflict: "user_code" }).select().single();
    if (error) throw error;
    await admin.from("audit_logs").insert({ actor_id: user.id, action: "provider_upserted", entity_type: "provider", entity_id: data.id, new_data: body });
    return json({ data });
  } catch (error) { return json({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
