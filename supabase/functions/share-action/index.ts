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
    const { data: link } = await admin.from("share_links").select("id,scope,provider_id,created_by,is_active,expires_at").or(`public_token.eq.${token},token_hash.eq.${tokenHash}`).maybeSingle();
    if (!link || !link.is_active || (link.expires_at && new Date(link.expires_at) <= new Date())) return publicJson({ error: "share link is invalid or revoked" }, 401);
    if (body.action === "withdrawal_request") {
      if (!["user", "merchant"].includes(link.scope)) return publicJson({ error: "action is not permitted for this share" }, 403);
      if (link.scope === "user") {
        const { data: provider } = await admin.from("providers").select("status,is_active,pause_reason").eq("id", link.provider_id).maybeSingle();
        if (!provider || !provider.is_active || !["active", "paused"].includes(provider.status)) return publicJson({ error: "provider is unavailable" }, 409);
        if (provider.status === "paused") return publicJson({ error: `Provider is paused: ${provider.pause_reason || "temporarily unavailable"}` }, 409);
      }
      const requesterType = link.scope === "user" ? "provider" : "merchant";
      const { data, error } = await admin.rpc("request_usdt_withdrawal", { p_share_link_id: link.id, p_provider_id: link.scope === "user" ? link.provider_id : null, p_requester_type: requesterType, p_amount_usdt: body.amount_usdt, p_destination_address: body.destination_address });
      if (error) throw error;
      return publicJson({ data });
    }
    const providerId = link.scope === "user" ? link.provider_id : body.provider_id;
    if (!providerId) return publicJson({ error: "provider is required" }, 400);
    if (link.scope === "merchant" && body.provider_id !== link.provider_id && link.provider_id !== null) return publicJson({ error: "provider is not permitted for this share" }, 403);
    const { data: provider } = await admin.from("providers").select("status,is_active,pause_reason").eq("id", providerId).maybeSingle();
    if (!provider || !["active", "paused"].includes(provider.status)) return publicJson({ error: "provider is unavailable" }, 409);
    if (provider.status === "paused") return publicJson({ error: `Provider is paused: ${provider.pause_reason || "temporarily unavailable"}` }, 409);
    if (link.scope === "user" && body.action === "upi_create") { if (!body.label || !String(body.label).trim()) return publicJson({ error: "UPI label is required" }, 400); const { data, error } = await admin.from("provider_upi_accounts").insert({ provider_id: link.provider_id, label: String(body.label).trim(), upi_id: body.upi_id || null, mobile: body.mobile || null, apk_mobile: body.apk_mobile || null, gpay_login_id: body.gpay_login_id || null, status: "active", merchant_operational: true, configured_limit_inr: 0, allocated_limit_inr: 0 }).select("id,provider_id,label,upi_id,mobile,apk_mobile,gpay_login_id,qr_data,status,merchant_operational,configured_limit_inr,allocated_limit_inr").single(); if (error) throw error; await admin.from("audit_logs").insert({ action: "user_upi_account_created", entity_type: "provider_upi_account", entity_id: data.id, new_data: { scope: "user" } }); return publicJson({ data }); }
    if (link.scope === "user" && body.action === "upi_update") { const { data: account } = await admin.from("provider_upi_accounts").select("id").eq("id", body.upi_account_id).eq("provider_id", link.provider_id).neq("status", "deleted").maybeSingle(); if (!account) return publicJson({ error: "UPI account is unavailable" }, 404); const { data, error } = await admin.from("provider_upi_accounts").update({ label: String(body.label || "").trim(), upi_id: body.upi_id || null, mobile: body.mobile || null, apk_mobile: body.apk_mobile || null, gpay_login_id: body.gpay_login_id || null, updated_at: new Date().toISOString() }).eq("id", account.id).select("id,provider_id,label,upi_id,mobile,apk_mobile,gpay_login_id,qr_data,status,merchant_operational,configured_limit_inr,allocated_limit_inr").single(); if (error) throw error; await admin.from("audit_logs").insert({ action: "user_upi_account_updated", entity_type: "provider_upi_account", entity_id: data.id, new_data: { scope: "user" } }); return publicJson({ data }); }
    if (body.action === "upi_status" && link.scope === "merchant") { const { data: account } = await admin.from("provider_upi_accounts").select("id,provider_id,status").eq("id", body.upi_account_id).eq("provider_id", providerId).eq("status", "active").maybeSingle(); if (!account) return publicJson({ error: "UPI account is unavailable" }, 409); const { data, error } = await admin.from("provider_upi_accounts").update({ merchant_operational: body.merchant_operational === true, updated_at: new Date().toISOString() }).eq("id", account.id).select().single(); if (error) throw error; await admin.from("audit_logs").insert({ action: "merchant_upi_operational_status_changed", entity_type: "provider_upi_account", entity_id: account.id, new_data: { merchant_operational: data.merchant_operational } }); return publicJson({ data }); }
    if (body.action === "collection_update" && link.scope === "merchant") {
      if (!body.entry_id || body.provider_id !== providerId) return publicJson({ error: "collection entry is required" }, 400);
      const { data, error } = await admin.rpc("correct_collection_by_share", { p_share_link_id: link.id, p_entry_id: body.entry_id, p_amount_inr: body.amount_inr, p_note: body.note ?? null });
      if (error) throw error;
      return publicJson({ data });
    }
    let data; let error;
    if (body.action === "deposit" && link.scope === "user") ({ data, error } = await admin.rpc("create_deposit_by_share", { p_share_link_id: link.id, p_provider_id: link.provider_id, p_requested_usdt: body.amount_usdt }));
    else if (body.action === "collection" && link.scope === "merchant") ({ data, error } = await admin.rpc("post_collection_by_share", { p_share_link_id: link.id, p_provider_id: body.provider_id, p_amount_inr: body.amount_inr, p_bank_name: body.bank_name, p_account_number: body.account_number, p_transaction_date: body.transaction_date, p_note: body.note, p_idempotency_key: body.idempotency_key, p_upi_account_id: body.upi_account_id || null }));
    else return publicJson({ error: "action is not permitted for this share" }, 403);
    if (error) throw error;
    return publicJson({ data });
  } catch (error) { const message = error && typeof error === "object" && "message" in error ? String((error as { message?: unknown }).message) : error instanceof Error ? error.message : "request failed"; return publicJson({ error: message }, 400); }
});
