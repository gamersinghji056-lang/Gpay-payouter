import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";

export function adminClient() {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
}

export async function requireStaff(req: Request) {
  const token = req.headers.get("Authorization")?.replace("Bearer ", "");
  if (!token) throw new Error("authentication required");
  const admin = adminClient();
  const { data: { user }, error } = await admin.auth.getUser(token);
  if (error || !user) throw new Error("authentication required");
  const { data: profile } = await admin.from("profiles").select("role").eq("id", user.id).single();
  if (!profile || !["admin", "operator"].includes(profile.role)) throw new Error("staff authorization required");
  return { admin, user, role: profile.role };
}

export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: {
    "content-type": "application/json",
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
    "access-control-allow-methods": "POST, OPTIONS",
  } });
}
