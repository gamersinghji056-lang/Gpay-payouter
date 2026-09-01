import { adminClient, json, requireStaff } from "../_shared/auth.ts";

const corsHeaders = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type", "access-control-allow-methods": "POST, OPTIONS" };
function corsJson(body: unknown, status = 200) { const response = json(body, status); Object.entries(corsHeaders).forEach(([key, value]) => response.headers.set(key, value)); return response; }
function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String((error as { message?: unknown }).message) : "request failed";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return corsJson({ ok: true });
  if (req.method !== "POST") return corsJson({ error: "method not allowed" }, 405);
  try {
    const { admin, user } = await requireStaff(req);
    const body = await req.json();
    if (body.action === "create" || body.action === "regenerate") {
      const rpc = body.action === "regenerate" ? "regenerate_share_link" : "create_share_link";
      const args = { p_actor_id: user.id, p_scope: body.scope, p_provider_id: body.provider_id ?? null } as Record<string, unknown>;
      if (body.action === "create") args.p_expires_at = null;
      const { data, error } = await admin.rpc(rpc, args);
      if (error) throw error;
      return corsJson({ data });
    }
    if (body.action === "get") {
      let query = admin.from("share_links").select("id,scope,provider_id,public_token,expires_at").eq("scope", body.scope).eq("is_active", true).is("expires_at", null);
      query = body.scope === "user" ? query.eq("provider_id", body.provider_id) : query.is("provider_id", null);
      const { data, error } = await query.order("created_at", { ascending: false });
      if (error) throw error;
      const current = (data || []).find(row => row.public_token);
      if (current) return corsJson({ data: current });
      const { data: repaired, error: repairError } = await admin.rpc("create_share_link", { p_actor_id: user.id, p_scope: body.scope, p_provider_id: body.provider_id ?? null, p_expires_at: null });
      if (repairError) throw repairError;
      return corsJson({ data: repaired?.[0] ? { id: repaired[0].id, scope: body.scope, provider_id: body.provider_id ?? null, public_token: repaired[0].token, expires_at: null } : null });
    }
    if (body.action === "revoke") {
      const { error } = await admin.rpc("revoke_share_link", { p_actor_id: user.id, p_link_id: body.link_id });
      if (error) throw error;
      return corsJson({ ok: true });
    }
    return corsJson({ error: "invalid action" }, 400);
  } catch (error) { return corsJson({ error: errorMessage(error) }, 400); }
});
