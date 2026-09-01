import { adminClient, json, requireStaff } from "../_shared/auth.ts";

const corsHeaders = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type", "access-control-allow-methods": "POST, OPTIONS" };
function corsJson(body: unknown, status = 200) { const response = json(body, status); Object.entries(corsHeaders).forEach(([key, value]) => response.headers.set(key, value)); return response; }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return corsJson({ ok: true });
  if (req.method !== "POST") return corsJson({ error: "method not allowed" }, 405);
  try {
    const { admin, user } = await requireStaff(req);
    const body = await req.json();
    if (body.admin_trc20_address && !/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(String(body.admin_trc20_address).trim())) return corsJson({ error: "Enter a valid TRON address" }, 400);
    const { data, error } = await admin.from("app_settings").update({
      settlement_rate: body.settlement_rate, deposit_base_rate: body.deposit_base_rate,
      deposit_markup_pct: body.deposit_markup_pct, commission_rate_pct: body.commission_rate_pct,
      admin_trc20_address: body.admin_trc20_address ?? null, trc20_usdt_contract: body.trc20_usdt_contract ?? null,
      updated_by: user.id, updated_at: new Date().toISOString(),
    }).eq("id", true).select().single();
    if (error) throw error;
    await admin.from("audit_logs").insert({ actor_id: user.id, action: "settings_updated", entity_type: "app_settings", new_data: body });
    return corsJson({ data });
  } catch (error) { return corsJson({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
