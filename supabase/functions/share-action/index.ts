import { adminClient, json } from "../_shared/auth.ts";

const corsHeaders = { "access-control-allow-origin": "*", "access-control-allow-headers": "authorization, x-client-info, apikey, content-type", "access-control-allow-methods": "POST, OPTIONS" };
function publicJson(body: unknown, status = 200) { const response = json(body, status); corsHeaders && Object.entries(corsHeaders).forEach(([key, value]) => response.headers.set(key, value)); return response; }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return publicJson({ ok: true });
  if (req.method !== "POST") return publicJson({ error: "method not allowed" }, 405);
  try {
    const body = await req.json();
    const token = String(body.token || "");
    const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
    const tokenHash = [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join("");
    const admin = adminClient();
    const { data: link } = await admin.from("share_links").select("id,scope,provider_id,created_by,is_active,expires_at").eq("token_hash", tokenHash).maybeSingle();
    if (!link || !link.is_active || (link.expires_at && new Date(link.expires_at) <= new Date())) return publicJson({ error: "share link is invalid or revoked" }, 401);
    const providerId = link.scope === "user" ? link.provider_id : body.provider_id;
    if (!providerId) return publicJson({ error: "provider is required" }, 400);
    if (link.scope === "merchant" && body.provider_id !== link.provider_id && link.provider_id !== null) return publicJson({ error: "provider is not permitted for this share" }, 403);
    const { data: provider } = await admin.from("providers").select("status,is_active,pause_reason").eq("id", providerId).maybeSingle();
    if (!provider || !["active", "paused"].includes(provider.status)) return publicJson({ error: "provider is unavailable" }, 409);
    if (provider.status === "paused") return publicJson({ error: `Provider is paused: ${provider.pause_reason || "temporarily unavailable"}` }, 409);
    if (body.action === "collection_update" && link.scope === "merchant") {
      if (!body.entry_id || body.provider_id !== providerId) return publicJson({ error: "collection entry is required" }, 400);
      const { data, error } = await admin.from("ledger_entries").update({ amount_inr: body.amount_inr, note: body.note ?? null, updated_at: new Date().toISOString() }).eq("id", body.entry_id).eq("provider_id", providerId).eq("entry_type", "collection").select().single();
      if (error) throw error;
      const { error: auditError } = await admin.from("audit_logs").insert({ actor_id: link.created_by, action: "collection_corrected", entity_type: "ledger_entry", entity_id: body.entry_id, new_data: { amount_inr: body.amount_inr, note: body.note ?? null, source: "merchant_share" } });
      if (auditError) throw auditError;
      return publicJson({ data });
    }
    let data; let error;
    if (body.action === "deposit" && link.scope === "user") ({ data, error } = await admin.rpc("create_deposit_by_share", { p_share_link_id: link.id, p_provider_id: link.provider_id, p_requested_usdt: body.amount_usdt }));
    else if (body.action === "collection" && link.scope === "merchant") ({ data, error } = await admin.rpc("post_collection_by_share", { p_share_link_id: link.id, p_provider_id: body.provider_id, p_amount_inr: body.amount_inr, p_bank_name: body.bank_name, p_account_number: body.account_number, p_transaction_date: body.transaction_date, p_note: body.note, p_idempotency_key: body.idempotency_key }));
    else return publicJson({ error: "action is not permitted for this share" }, 403);
    if (error) throw error;
    return publicJson({ data });
  } catch (error) { const message = error && typeof error === "object" && "message" in error ? String((error as { message?: unknown }).message) : error instanceof Error ? error.message : "request failed"; return publicJson({ error: message }, 400); }
});
