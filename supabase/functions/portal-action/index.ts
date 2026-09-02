import { adminClient, json } from "../_shared/auth.ts";

function message(error: unknown) { return error instanceof Error ? error.message : typeof error === "object" && error && "message" in error ? String((error as { message?: unknown }).message) : "request failed"; }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  try {
    const body = await req.json();
    const admin = adminClient();
    const { data: acct, error: acctError } = await admin.rpc("portal_account_from_token", { p_token: body.session_token });
    if (acctError || !acct) throw acctError || new Error("portal session is invalid or expired");
    if (acct.role === "agent") return json({ error: "agent is read-only" }, 403);
    if (acct.role === "user") {
      if (body.action === "deposit") {
        const { data, error } = await admin.rpc("create_deposit_by_portal", { p_account_id: acct.id, p_requested_usdt: body.amount_usdt });
        if (error) throw error; return json({ data });
      }
      if (body.action === "withdrawal_request") {
        const { data, error } = await admin.rpc("request_usdt_withdrawal_by_portal", { p_account_id: acct.id, p_amount_usdt: body.amount_usdt, p_destination_address: body.destination_address });
        if (error) throw error; return json({ data });
      }
      if (body.action === "upi_create") {
        const { data, error } = await admin.from("provider_upi_accounts").insert({ provider_id: acct.provider_id, label: String(body.label || "").trim(), upi_id: body.upi_id || null, mobile: body.mobile || null, apk_mobile: body.apk_mobile || null, gpay_login_id: body.gpay_login_id || null, bank_name: body.bank_name || null, bank_account_number: body.bank_account_number || null, account_holder_name: body.account_holder_name || null, ifsc_code: body.ifsc_code || null, bank_branch: body.bank_branch || null, account_note: body.account_note || null, status: "active", merchant_operational: true, configured_limit_inr: 0, allocated_limit_inr: 0 }).select().single();
        if (error) throw error; return json({ data });
      }
      if (body.action === "upi_update") {
        const { data, error } = await admin.from("provider_upi_accounts").update({ label: String(body.label || "").trim(), upi_id: body.upi_id || null, mobile: body.mobile || null, apk_mobile: body.apk_mobile || null, gpay_login_id: body.gpay_login_id || null, bank_name: body.bank_name || null, bank_account_number: body.bank_account_number || null, account_holder_name: body.account_holder_name || null, ifsc_code: body.ifsc_code || null, bank_branch: body.bank_branch || null, account_note: body.account_note || null, updated_at: new Date().toISOString() }).eq("id", body.upi_account_id).eq("provider_id", acct.provider_id).neq("status", "deleted").select().single();
        if (error) throw error; return json({ data });
      }
    }
    if (acct.role === "merchant") {
      if (body.action === "collection") {
        const { data: link } = await admin.from("share_links").select("id").eq("scope", "merchant").eq("is_active", true).is("expires_at", null).order("created_at", { ascending: false }).limit(1).maybeSingle();
        if (!link) throw new Error("merchant access is not configured");
        const { data, error } = await admin.rpc("post_collection_by_share", { p_share_link_id: link.id, p_provider_id: body.provider_id, p_amount_inr: body.amount_inr, p_bank_name: body.bank_name, p_account_number: body.account_number, p_transaction_date: body.transaction_date, p_note: body.note, p_idempotency_key: body.idempotency_key, p_upi_account_id: body.upi_account_id || null });
        if (error) throw error; return json({ data });
      }
      if (body.action === "upi_status") {
        const { data, error } = await admin.from("provider_upi_accounts").update({ merchant_operational: body.merchant_operational === true, updated_at: new Date().toISOString() }).eq("id", body.upi_account_id).eq("provider_id", body.provider_id).select().single();
        if (error) throw error; return json({ data });
      }
      if (body.action === "withdrawal_request") {
        const { data, error } = await admin.rpc("request_usdt_withdrawal_by_portal", { p_account_id: acct.id, p_amount_usdt: body.amount_usdt, p_destination_address: body.destination_address });
        if (error) throw error; return json({ data });
      }
    }
    return json({ error: "action is not permitted" }, 403);
  } catch (error) { return json({ error: message(error) }, 400); }
});
