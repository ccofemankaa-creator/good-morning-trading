import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigin = "https://ccofemankaa-creator.github.io";

Deno.serve(async request => {
  const origin = request.headers.get("origin");
  const corsHeaders = {
    "Access-Control-Allow-Origin": origin === allowedOrigin ? allowedOrigin : "null",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin"
  };
  const jsonResponse = (body: Record<string, unknown>, status = 200) =>
    Response.json(body, { status, headers: corsHeaders });

  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);
  if (origin !== allowedOrigin) return jsonResponse({ error: "Origin not allowed" }, 403);

  const authorization = request.headers.get("authorization");
  if (!authorization) return jsonResponse({ error: "Authentication required" }, 401);

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Invalid request body" }, 400);
  }
  if (!body || typeof body !== "object") {
    return jsonResponse({ error: "Invalid request body" }, 400);
  }

  const userId = "userId" in body && typeof body.userId === "string" ? body.userId : "";
  const newPassword = "newPassword" in body && typeof body.newPassword === "string"
    ? body.newPassword
    : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) {
    return jsonResponse({ error: "Invalid user ID" }, 400);
  }
  if (newPassword.length < 8 || newPassword.length > 128) {
    return jsonResponse({ error: "Password must be 8-128 characters long" }, 400);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const publishableKeysJson = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  const secretKeysJson = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!supabaseUrl || !publishableKeysJson || !secretKeysJson) {
    return jsonResponse({ error: "Server authentication is not configured" }, 500);
  }

  let publishableKey: string;
  let secretKey: string;
  try {
    publishableKey = JSON.parse(publishableKeysJson).default;
    secretKey = JSON.parse(secretKeysJson).default;
  } catch {
    return jsonResponse({ error: "Server authentication is not configured" }, 500);
  }
  if (!publishableKey || !secretKey) {
    return jsonResponse({ error: "Server authentication is not configured" }, 500);
  }

  const userClient = createClient(supabaseUrl, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: authorization } }
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return jsonResponse({ error: "Invalid session" }, 401);

  const { data: adminRecord, error: adminCheckError } = await userClient
    .from("admin_users")
    .select("user_id")
    .eq("user_id", userData.user.id)
    .maybeSingle();
  if (adminCheckError) return jsonResponse({ error: "Could not verify administrator" }, 500);
  if (!adminRecord) return jsonResponse({ error: "Administrator access required" }, 403);

  const adminClient = createClient(supabaseUrl, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false }
  });
  const { data: targetAdmin, error: targetAdminError } = await adminClient
    .from("admin_users")
    .select("user_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (targetAdminError) return jsonResponse({ error: "Could not verify target account" }, 500);
  if (targetAdmin) return jsonResponse({ error: "Administrator passwords cannot be reset here" }, 403);

  const { error: updateError } = await adminClient.auth.admin.updateUserById(userId, {
    password: newPassword
  });
  if (updateError) return jsonResponse({ error: "Could not reset the password" }, 400);

  return jsonResponse({ ok: true });
});
