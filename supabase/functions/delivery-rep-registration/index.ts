import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE_URL = "https://pizza-king-moran.pages.dev";
const publicAuth = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const allowedBranches = [
  "عباس العقاد","الشمس","روكسي","مصر حلوان","المعادي","زهراء المعادي",
  "شبرا","باب اللوق","المقطم","العبور","الشروق","التجمع الخامس",
  "جولدن سكوير","الرحاب","المنيل","الخزان","الهرم","زايد",
];
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
function validUsername(value: unknown): value is string {
  return typeof value === "string" && /^[a-z0-9._-]{3,40}$/.test(value);
}
async function managerFromRequest(req: Request) {
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) throw new Error("يجب تسجيل دخول المدير أولاً.");
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) throw new Error("جلسة المدير غير صالحة.");
  const { data: profile, error: profileError } = await admin
    .from("profiles").select("role,branch").eq("user_id", data.user.id).maybeSingle();
  if (profileError || !profile || !["admin", "branch_manager"].includes(profile.role)) {
    throw new Error("ليس لديك صلاحية مراجعة طلبات المندوبين.");
  }
  return { user: data.user, profile };
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);
  try {
    const body = await req.json();
    const action = String(body?.action || "");

    if (action === "submit") {
      const full_name = String(body?.full_name || "").trim();
      const phone = String(body?.phone || "").trim();
      const username = String(body?.username || "").trim().toLowerCase();
      const email = String(body?.email || "").trim().toLowerCase();
      const branch = String(body?.branch || "").trim();
      const password = String(body?.password || "");
      if (full_name.length < 3 || full_name.length > 100 ||
          phone.length < 5 || phone.length > 20 ||
          !validUsername(username) || !allowedBranches.includes(branch) ||
          !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254 ||
          password.length < 8 || password.length > 128) {
        return reply({ error: "راجع البيانات، واكتب بريدًا إلكترونيًا صحيحًا وكلمة مرور لا تقل عن 8 أحرف." }, 400);
      }
      const { data: existing, error: existingError } = await admin
        .from("delivery_rep_profiles").select("id").ilike("username", username).maybeSingle();
      if (existingError) throw existingError;
      if (existing) return reply({ error: "اسم المستخدم مستخدم بالفعل. اختر اسمًا آخر." }, 409);
      const { data: emailExisting, error: emailCheckError } = await admin
        .from("delivery_rep_profiles").select("id").ilike("email", email).maybeSingle();
      if (emailCheckError) throw emailCheckError;
      if (emailExisting) return reply({ error: "هذا البريد الإلكتروني مسجل بالفعل." }, 409);

      const { data: created, error: createError } = await publicAuth.auth.signUp({
        email,
        password,
        options: {
          emailRedirectTo: SITE_URL,
          data: { display_name: full_name, account_type: "delivery_rep_pending" },
        },
      });
      if (createError || !created.user) {
        return reply({ error: createError?.message || "تعذر إنشاء طلب التسجيل." }, 400);
      }
      if (created.user.identities && created.user.identities.length === 0) {
        return reply({ error: "هذا البريد الإلكتروني مستخدم بالفعل." }, 409);
      }

      const userId = created.user.id;
      const { error: profileError } = await admin.from("profiles").insert({
        user_id: userId, role: "delivery_rep", username,
      });
      if (profileError) {
        await admin.auth.admin.deleteUser(userId);
        if (profileError.code === "23505") return reply({ error: "اسم المستخدم مستخدم بالفعل." }, 409);
        throw profileError;
      }
      const { error: repError } = await admin.from("delivery_rep_profiles").insert({
        user_id: userId, full_name, phone, email, username, branch,
        is_active: false, availability_status: "unavailable",
        approval_status: "pending", created_by: null,
      });
      if (repError) {
        await admin.auth.admin.deleteUser(userId);
        if (repError.code === "23505") return reply({ error: "اسم المستخدم أو البريد الإلكتروني مستخدم بالفعل." }, 409);
        throw repError;
      }
      return reply({ message: "تم استلام طلبك. أرسلنا رسالة تأكيد إلى بريدك الإلكتروني؛ افتحها لتأكيد البريد، ثم انتظر موافقة المدير قبل تسجيل الدخول." });
    }

    const { user, profile } = await managerFromRequest(req);
    const isAdmin = profile.role === "admin";
    const branch = String(profile.branch || "");

    if (action === "list") {
      let query = admin.from("delivery_rep_profiles")
        .select("user_id,full_name,phone,email,username,branch,approval_status,created_at")
        .eq("approval_status", "pending").order("created_at", { ascending: false });
      if (!isAdmin) query = query.eq("branch", branch);
      const { data, error } = await query;
      if (error) throw error;
      const requests = await Promise.all((data || []).map(async (item) => {
        const { data: authResult } = await admin.auth.admin.getUserById(item.user_id);
        return { ...item, email_confirmed: !!authResult?.user?.email_confirmed_at };
      }));
      return reply({ requests });
    }

    if (action === "review") {
      const user_id = String(body?.user_id || "");
      const decision = String(body?.decision || "");
      const reason = String(body?.reason || "").trim().slice(0, 300);
      if (!user_id || !["approved", "rejected"].includes(decision)) {
        return reply({ error: "بيانات المراجعة غير مكتملة." }, 400);
      }
      let query = admin.from("delivery_rep_profiles")
        .select("user_id,branch,approval_status").eq("user_id", user_id)
        .eq("approval_status", "pending");
      if (!isAdmin) query = query.eq("branch", branch);
      const { data: requestRow, error: requestError } = await query.maybeSingle();
      if (requestError) throw requestError;
      if (!requestRow) return reply({ error: "الطلب غير موجود أو خارج نطاق فرعك." }, 404);

      if (decision === "approved") {
        const { data: authResult, error: authLookupError } = await admin.auth.admin.getUserById(user_id);
        if (authLookupError || !authResult?.user?.email_confirmed_at) {
          return reply({ error: "لا يمكن تفعيل الحساب قبل أن يؤكد المندوب بريده الإلكتروني من الرسالة المرسلة إليه." }, 400);
        }
      }

      const { error: updateError } = await admin.from("delivery_rep_profiles").update({
        approval_status: decision, is_active: decision === "approved",
        availability_status: "unavailable", reviewed_by: user.id,
        reviewed_at: new Date().toISOString(),
        rejection_reason: decision === "rejected" ? (reason || "لم تتم الموافقة") : null,
      }).eq("user_id", user_id).eq("approval_status", "pending");
      if (updateError) throw updateError;
      return reply({ message: decision === "approved" ? "تمت الموافقة وتفعيل حساب المندوب." : "تم رفض طلب التسجيل." });
    }
    return reply({ error: "Unknown action" }, 400);
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "حدث خطأ غير متوقع." }, 400);
  }
});
