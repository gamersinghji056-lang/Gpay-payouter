import { adminClient, json, requireStaff } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const { admin, user } = await requireStaff(req);
    const body = await req.json();
    if (body.action === "create") {
      const { data, error } = await admin.rpc("create_share_link", { p_actor_id: user.id, p_scope: body.scope, p_provider_id: body.provider_id ?? null, p_expires_at: body.expires_at ?? null });
      if (error) throw error;
      return json({ data });
    }
    if (body.action === "revoke") {
      const { error } = await admin.rpc("revoke_share_link", { p_actor_id: user.id, p_link_id: body.link_id });
      if (error) throw error;
      return json({ ok: true });
    }
    return json({ error: "invalid action" }, 400);
  } catch (error) { return json({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
