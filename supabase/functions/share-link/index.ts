import { adminClient, json, requireStaff } from "../_shared/auth.ts";

const corsHeaders = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type", "access-control-allow-methods": "POST, OPTIONS" };
function corsJson(body: unknown, status = 200) { const response = json(body, status); Object.entries(corsHeaders).forEach(([key, value]) => response.headers.set(key, value)); return response; }

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
      const { data, error } = await query.order("created_at", { ascending: false }).limit(1);
      if (error) throw error;
      return corsJson({ data: data?.[0] || null });
    }
    if (body.action === "revoke") {
      const { error } = await admin.rpc("revoke_share_link", { p_actor_id: user.id, p_link_id: body.link_id });
      if (error) throw error;
      return corsJson({ ok: true });
    }
    return corsJson({ error: "invalid action" }, 400);
  } catch (error) { return corsJson({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
