import { adminClient, json, requireStaff } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const { admin, user } = await requireStaff(req);
    const body = await req.json();
    const { data, error } = await admin.from("app_settings").update({
      settlement_rate: body.settlement_rate, deposit_base_rate: body.deposit_base_rate,
      deposit_markup_pct: body.deposit_markup_pct, commission_rate_pct: body.commission_rate_pct,
      admin_trc20_address: body.admin_trc20_address ?? null, trc20_usdt_contract: body.trc20_usdt_contract ?? null,
      updated_by: user.id, updated_at: new Date().toISOString(),
    }).eq("id", true).select().single();
    if (error) throw error;
    await admin.from("audit_logs").insert({ actor_id: user.id, action: "settings_updated", entity_type: "app_settings", new_data: body });
    return json({ data });
  } catch (error) { return json({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
