import { adminClient, json, requireStaff } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const { admin } = await requireStaff(req);
    const body = await req.json();
    if (!body.storage_path || !body.provider_id) return json({ error: "provider_id and storage_path are required" }, 400);
    const { data, error } = await admin.storage.from("provider-qr").createSignedUrl(body.storage_path, body.expires_in ?? 300);
    if (error) throw error;
    return json({ signed_url: data.signedUrl });
  } catch (error) { return json({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
