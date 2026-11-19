import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE_URL = "https://pizza-king-moran.pages.dev";

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
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
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

    if (action === "login" || action === "forgot") {
      const username = String(body?.username || "").trim().toLowerCase();
      if (!validUsername(username)) return response({ error: "Invalid request" }, 400);

      const { data: rep, error: repError } = await admin
        .from("delivery_rep_profiles")
        .select("user_id, username, is_active")
        .ilike("username", username)
        .maybeSingle();

      if (repError || !rep?.user_id || !rep.is_active ||
          String(rep.username || "").toLowerCase() !== username) {
        return action === "forgot"
          ? response({ message: "If the account has a confirmed recovery email, a message will be sent." })
          : response({ error: "Invalid login" }, 401);
      }

      const { data: profile, error: profileError } = await admin
        .from("profiles")
        .select("role, username")
        .eq("user_id", rep.user_id)
        .maybeSingle();

      if (profileError || profile?.role !== "delivery_rep" ||
          String(profile.username || "").toLowerCase() !== username) {
        return action === "forgot"
          ? response({ message: "If the account has a confirmed recovery email, a message will be sent." })
          : response({ error: "Invalid login" }, 401);
      }

      const { data: authData, error: authUserError } =
        await admin.auth.admin.getUserById(rep.user_id);
      if (authUserError || !authData?.user) {
        return action === "forgot"
          ? response({ message: "If the account has a confirmed recovery email, a message will be sent." })
          : response({ error: "Invalid login" }, 401);
      }

      const authEmail = authData.user.email || `${username}@delivery-login.internal`;

      if (action === "forgot") {
        if (authEmail.endsWith("@delivery-login.internal")) {
          return response({ message: "If the account has a confirmed recovery email, a message will be sent." });
        }
        await publicAuth.auth.resetPasswordForEmail(authEmail, {
          redirectTo: SITE_URL,
        });
        return response({ message: "If the account has a confirmed recovery email, a message will be sent." });
      }

      const { data: signInData, error: signInError } =
        await publicAuth.auth.signInWithPassword({
          email: authEmail,
          password: String(body?.password || ""),
        });

      if (signInError || !signInData.session) {
        return response({ error: "Invalid login" }, 401);
      }

      if (!authEmail.endsWith("@delivery-login.internal")) {
        await admin.from("delivery_rep_profiles")
          .update({ email: authEmail })
          .eq("user_id", rep.user_id);
      }

      return response({ session: signInData.session });
    }

    if (action === "set-email") {
      const authorization = req.headers.get("Authorization") || "";
      const token = authorization.replace(/^Bearer\s+/i, "").trim();
      if (!token) return response({ error: "Authentication required" }, 401);

      const { data: userData, error: userError } = await admin.auth.getUser(token);
      const user = userData?.user;
      if (userError || !user) return response({ error: "Authentication required" }, 401);

      const [{ data: profile }, { data: rep }] = await Promise.all([
        admin.from("profiles").select("role").eq("user_id", user.id).maybeSingle(),
        admin.from("delivery_rep_profiles")
          .select("user_id, is_active")
          .eq("user_id", user.id).maybeSingle(),
      ]);

      if (profile?.role !== "delivery_rep" || !rep?.is_active) {
        return response({ error: "Not authorized" }, 403);
      }

      const email = String(body?.email || "").trim().toLowerCase();
      if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        return response({ error: "اكتب بريدًا إلكترونيًا صحيحًا." }, 400);
      }

      const { data: duplicate } = await admin.from("delivery_rep_profiles")
        .select("user_id")
        .ilike("email", email)
        .neq("user_id", user.id)
        .maybeSingle();

      if (duplicate) return response({ error: "هذا البريد مسجل لحساب مندوب آخر." }, 409);

      const emailUpdateResponse = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
        method: "PUT",
        headers: {
          "apikey": SUPABASE_ANON_KEY,
          "Authorization": `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ email }),
      });
      if (!emailUpdateResponse.ok) {
        return response({ error: "تعذر تحديث البريد. تأكد أنه غير مستخدم في حساب آخر." }, 400);
      }

      const { error: updateProfileError } = await admin.from("delivery_rep_profiles")
        .update({ email })
        .eq("user_id", user.id);

      if (updateProfileError) {
        return response({ error: "تم إرسال طلب تحديث البريد، لكن تعذر حفظه في الملف الشخصي." }, 500);
      }

      return response({
        message: "تم إرسال رسالة تأكيد إلى البريد الجديد. افتح الرسالة واضغط رابط التأكيد قبل تسجيل الخروج.",
      });
    }

    return response({ error: "Unknown action" }, 400);
  } catch (_error) {
    return response({ error: "حدث خطأ غير متوقع. حاول مرة أخرى." }, 500);
  }
});
