import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const publicAuth = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
function validUsername(value: unknown): value is string {
  return typeof value === "string" && /^[a-z0-9._-]{3,40}$/.test(value);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return response({ error: "Method not allowed" }, 405);
  try {
    const body = await req.json();
    const action = String(body?.action || "");
    if (action === "forgot") {
      return response({ message: "لإعادة تعيين كلمة المرور، تواصل مع المدير الرئيسي أو مدير الفرع." });
    }
    if (action !== "login") return response({ error: "Unknown action" }, 400);

    const username = String(body?.username || "").trim().toLowerCase();
    const password = String(body?.password || "");
    if (!validUsername(username) || password.length < 1 || password.length > 128) {
      return response({ error: "Invalid login" }, 401);
    }

    const { data: rep, error: repError } = await admin
      .from("delivery_rep_profiles")
      .select("user_id,username,is_active,approval_status")
      .ilike("username", username)
      .maybeSingle();
    if (repError || !rep?.user_id || !rep.is_active ||
        rep.approval_status !== "approved" ||
        String(rep.username || "").toLowerCase() !== username) {
      return response({ error: "Invalid login" }, 401);
    }

    const { data: profile, error: profileError } = await admin
      .from("profiles").select("role,username").eq("user_id", rep.user_id).maybeSingle();
    if (profileError || profile?.role !== "delivery_rep" ||
        String(profile.username || "").toLowerCase() !== username) {
      return response({ error: "Invalid login" }, 401);
    }

    const { data: authData, error: authUserError } = await admin.auth.admin.getUserById(rep.user_id);
    if (authUserError || !authData?.user) return response({ error: "Invalid login" }, 401);
    const authEmail = authData.user.email || (username + "@delivery-login.internal");

    const { data: signInData, error: signInError } = await publicAuth.auth.signInWithPassword({
      email: authEmail,
      password,
    });
    if (signInError || !signInData.session) return response({ error: "Invalid login" }, 401);
    return response({ session: signInData.session });
  } catch (_error) {
    return response({ error: "حدث خطأ غير متوقع. حاول مرة أخرى." }, 500);
  }
});
