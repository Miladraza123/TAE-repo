// admin-user-ops: privileged user management for OHT Accounting System.
//
// The app is a static HTML/JS client with only the Supabase anon key — it
// can never safely create another person's login or reset someone else's
// password (that needs the service-role key, which must never reach the
// browser). This function is the one place that key is used: it verifies
// the CALLER is a signed-in, active app_users.is_admin, then performs the
// privileged action with a service-role client.
//
// Actions (POST body: { action, ...params }):
//   create_user  { email, password, username, is_admin, is_active, perms }
//     -> creates the Supabase Auth user (email confirmed, no invite email)
//        and its app_users row in one call.
//   set_password { user_id, new_password }
//     -> resets an EXISTING user's password. No current-password check:
//        the caller's own admin privilege is the authorization.

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// The browser client calling this function runs on a different origin than
// *.supabase.co, and the request carries an Authorization header, so the
// browser sends a CORS preflight (OPTIONS) before the real POST. Every
// response — the preflight's and the real one's — needs these headers, or
// the browser blocks the request client-side before it ever reaches here
// ("Failed to send a request to the Edge Function", with no server-side
// error to show for it since the real request never went out).
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const authHeader = req.headers.get("Authorization") || "";

  // Identify the caller against their OWN token (never trust a client-sent
  // user id) via an anon-key client that forwards their Authorization header.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
  if (callerErr || !callerData?.user) return json({ error: "Not signed in" }, 401);
  const callerId = callerData.user.id;

  // Service-role client for the privileged app_users check and the actual
  // privileged action — this key is only ever read server-side here.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: callerProfile } = await admin
    .from("app_users")
    .select("is_admin, is_active")
    .eq("id", callerId)
    .maybeSingle();
  if (!callerProfile?.is_admin || !callerProfile?.is_active) {
    return json({ error: "Admins only" }, 403);
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  if (body.action === "create_user") {
    const { email, password, username, is_admin, is_active, perms } = body;
    if (!email || !password || !username) {
      return json({ error: "email, password and username are required" }, 400);
    }
    if (String(password).length < 8) {
      return json({ error: "Password must be at least 8 characters" }, 400);
    }

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true, // no invite-email flow — admin hands the password to the person directly
    });
    if (createErr || !created?.user) {
      return json({ error: createErr?.message || "Could not create the sign-in account" }, 400);
    }

    const { data: profile, error: profileErr } = await admin
      .from("app_users")
      .insert({
        id: created.user.id,
        username,
        is_admin: !!is_admin,
        is_active: is_active !== false,
        perms: perms || {},
      })
      .select()
      .single();

    if (profileErr) {
      // Roll back the orphaned auth account (e.g. the 15-active-user limit
      // trigger rejected the insert) so a failed create doesn't leave a
      // login nobody can see or manage from the app.
      await admin.auth.admin.deleteUser(created.user.id).catch(() => {});
      return json({ error: profileErr.message }, 400);
    }

    return json({ status: "ok", profile });
  }

  if (body.action === "set_password") {
    const { user_id, new_password } = body;
    if (!user_id || !new_password) {
      return json({ error: "user_id and new_password are required" }, 400);
    }
    if (String(new_password).length < 8) {
      return json({ error: "Password must be at least 8 characters" }, 400);
    }
    const { error: pwErr } = await admin.auth.admin.updateUserById(user_id, { password: new_password });
    if (pwErr) return json({ error: pwErr.message }, 400);
    return json({ status: "ok" });
  }

  return json({ error: "Unknown action" }, 400);
});
