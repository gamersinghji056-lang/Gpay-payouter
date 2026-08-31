import { adminClient, json } from "../_shared/auth.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const body = await req.json();
    const token = String(body.token || "");
    const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
    const tokenHash = [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join("");
    const admin = adminClient();
    const { data: link } = await admin.from("share_links").select("id,scope,provider_id,is_active,expires_at").eq("token_hash", tokenHash).maybeSingle();
    if (!link || !link.is_active || (link.expires_at && new Date(link.expires_at) <= new Date())) return json({ error: "share link is invalid or revoked" }, 401);
    let data; let error;
    if (body.action === "deposit" && link.scope === "user") ({ data, error } = await admin.rpc("create_deposit_by_share", { p_share_link_id: link.id, p_provider_id: link.provider_id, p_requested_usdt: body.amount_usdt }));
    else if (body.action === "collection" && link.scope === "merchant") ({ data, error } = await admin.rpc("post_collection_by_share", { p_share_link_id: link.id, p_provider_id: body.provider_id, p_amount_inr: body.amount_inr, p_bank_name: body.bank_name, p_account_number: body.account_number, p_transaction_date: body.transaction_date, p_note: body.note, p_idempotency_key: body.idempotency_key }));
    else return json({ error: "action is not permitted for this share" }, 403);
    if (error) throw error;
    return json({ data });
  } catch (error) { return json({ error: error instanceof Error ? error.message : "request failed" }, 400); }
});
