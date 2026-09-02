import { adminClient, json, requireStaff } from "../_shared/auth.ts";

function publicJson(body: unknown, status = 200) { return json(body, status); }
function message(error: unknown) { return error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String((error as { message?: unknown }).message) : "request failed"; }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return publicJson({ ok: true });
  if (req.method !== "POST") return publicJson({ error: "method not allowed" }, 405);
  try {
    const body = await req.json();
    const admin = adminClient();
    if (body.action === "login") {
      const role = String(body.role || "").trim().toLowerCase();
      const loginId = role === "user" ? String(body.login_id || "").trim().toUpperCase() : String(body.login_id || "").trim();
      const { data, error } = await admin.rpc("portal_create_session", { p_role: role, p_login_id: loginId, p_password: body.password });
      if (error) throw error;
      return publicJson({ data: data?.[0] || null });
    }
    if (body.action === "logout") {
      const { error } = await admin.rpc("portal_logout", { p_token: body.session_token });
      if (error) throw error;
      return publicJson({ ok: true });
    }
    const { user } = await requireStaff(req);
    if (body.action === "generate" || body.action === "reset") {
      const { data, error } = await admin.rpc("admin_upsert_portal_account", { p_actor_id: user.id, p_role: body.role, p_provider_id: body.provider_id ?? null, p_login_id: body.login_id ?? null, p_password: null });
      if (error) throw error;
      return publicJson({ data: data?.[0] || null });
    }
    if (body.action === "status") {
      const { data, error } = await admin.rpc("admin_set_portal_account_status", { p_actor_id: user.id, p_account_id: body.account_id, p_is_active: body.is_active === true });
      if (error) throw error;
      return publicJson({ data });
    }
    return publicJson({ error: "invalid action" }, 400);
  } catch (error) { return publicJson({ error: message(error) }, 400); }
});
