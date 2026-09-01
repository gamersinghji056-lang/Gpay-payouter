import { adminClient, json, requireStaff } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const { admin, user } = await requireStaff(req);
    const body = await req.json();
    const key = Deno.env.get("GPAY_CREDENTIAL_ENCRYPTION_KEY");
    if (!key) throw new Error("credential encryption is not configured");
    if (body.action === "set") {
      const { error } = body.upi_account_id
        ? await admin.rpc("set_upi_gpay_credentials", { p_actor_id: user.id, p_upi_account_id: body.upi_account_id, p_password: body.password, p_encryption_key: key })
        : await admin.rpc("set_gpay_credentials", { p_actor_id: user.id, p_provider_id: body.provider_id, p_password: body.password, p_encryption_key: key });
      if (error) throw error;
      return json({ ok: true });
    }
    if (body.action === "reveal") {
      const { data, error } = body.upi_account_id
        ? await admin.rpc("reveal_upi_gpay_password", { p_actor_id: user.id, p_upi_account_id: body.upi_account_id, p_encryption_key: key })
        : await admin.rpc("reveal_gpay_password", { p_actor_id: user.id, p_provider_id: body.provider_id, p_encryption_key: key });
      if (error) throw error;
      return json({ password: data });
    }
    return json({ error: "invalid action" }, 400);
  } catch (error) { return json({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
