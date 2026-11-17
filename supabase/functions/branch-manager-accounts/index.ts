import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json" },
});
const branches = [
  "عباس العقاد","الشمس","روكسي","مصر حلوان","المعادي","زهراء المعادي",
  "شبرا","باب اللوق","المقطم","العبور","الشروق","التجمع الخامس",
  "جولدن سكوير","الرحاب","المنيل","الخزان","الهرم","زايد",
];
const validUsername = (value: string) => /^[a-z0-9._-]{3,40}$/.test(value);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!url || !serviceKey) return json({ error: "إعدادات الخادم غير مكتملة." }, 500);
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "طلب غير صالح." }, 400); }
  const action = String(body.action ?? "");

  if (action === "register") {
    const full_name = String(body.full_name ?? "").trim();
    const phone = String(body.phone ?? "").trim();
    const branch = String(body.branch ?? "");
    const username = String(body.username ?? "").trim().toLowerCase();
    const password = String(body.password ?? "");
    if (full_name.length < 3 || full_name.length > 100 || phone.length < 5 || phone.length > 20 ||
        !branches.includes(branch) || !validUsername(username) || password.length < 8 || password.length > 72) {
      return json({ error: "راجع البيانات المدخلة وتأكد من صحة اسم المستخدم وكلمة المرور والفرع." }, 400);
    }

    const { data: existingProfile, error: profileCheckError } = await admin
      .from("profiles").select("user_id").ilike("username", username).maybeSingle();
    if (profileCheckError) return json({ error: "تعذر التحقق من اسم المستخدم." }, 500);
    if (existingProfile) return json({ error: "اسم المستخدم مستخدم بالفعل. اختر اسماً آخر." }, 409);

    const { data: existingRequest, error: requestCheckError } = await admin
      .from("branch_manager_requests").select("id").ilike("username", username).maybeSingle();
    if (requestCheckError) return json({ error: "تعذر التحقق من طلبات التسجيل." }, 500);
    if (existingRequest) return json({ error: "اسم المستخدم مسجل من قبل. تواصل مع المدير الرئيسي." }, 409);

    const email = username + "@branch-login.internal";
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { account_type: "branch_manager_pending", display_name: full_name },
    });
    if (createError || !created.user) {
      return json({ error: createError?.message?.includes("already") ? "اسم المستخدم مستخدم بالفعل." : "تعذر إنشاء الحساب. راجع البيانات وحاول مرة أخرى." }, 400);
    }

    const { error: insertError } = await admin.from("branch_manager_requests").insert({
      auth_user_id: created.user.id, full_name, phone, username, requested_branch: branch,
    });
    if (insertError) {
      await admin.auth.admin.deleteUser(created.user.id);
      return json({ error: "تعذر حفظ طلب التسجيل. حاول مرة أخرى." }, 500);
    }
    return json({ success: true, message: "تم إرسال طلب التسجيل للمراجعة." });
  }

  const authorization = req.headers.get("authorization") ?? "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "يلزم تسجيل دخول المدير الرئيسي." }, 401);
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  if (authError || !authData.user) return json({ error: "جلسة الدخول غير صالحة. سجل الدخول مرة أخرى." }, 401);
  const { data: profile, error: roleError } = await admin.from("profiles")
    .select("role").eq("user_id", authData.user.id).maybeSingle();
  if (roleError || profile?.role !== "admin") return json({ error: "هذه العملية متاحة للمدير الرئيسي فقط." }, 403);

  if (action === "list") {
    const { data, error } = await admin.from("branch_manager_requests")
      .select("id,full_name,phone,username,requested_branch,status,created_at")
      .eq("status", "pending").order("created_at", { ascending: false });
    if (error) return json({ error: "تعذر تحميل طلبات التسجيل." }, 500);
    return json({ requests: data ?? [] });
  }

  const requestId = String(body.request_id ?? "");
  if (!requestId) return json({ error: "رقم الطلب غير موجود." }, 400);
  const { data: request, error: findError } = await admin.from("branch_manager_requests")
    .select("*").eq("id", requestId).eq("status", "pending").maybeSingle();
  if (findError || !request) return json({ error: "الطلب غير موجود أو تمت مراجعته بالفعل." }, 404);

  if (action === "approve") {
    const branch = String(body.branch ?? "");
    if (!branches.includes(branch)) return json({ error: "اختر فرعاً صحيحاً قبل الاعتماد." }, 400);
    const { error: profileError } = await admin.from("profiles").upsert({
      user_id: request.auth_user_id, role: "branch_manager", branch, username: request.username,
    }, { onConflict: "user_id" });
    if (profileError) return json({ error: "تعذر تفعيل الحساب. تأكد من تحديث قاعدة البيانات وصلاحيات profiles." }, 500);
    const { error: updateError } = await admin.from("branch_manager_requests").update({
      status: "approved", assigned_branch: branch, reviewed_at: new Date().toISOString(), reviewed_by: authData.user.id,
    }).eq("id", request.id).eq("status", "pending");
    if (updateError) {
      await admin.from("profiles").delete().eq("user_id", request.auth_user_id);
      return json({ error: "تعذر إنهاء اعتماد الطلب." }, 500);
    }
    return json({ success: true });
  }

  if (action === "reject") {
    const { error: banError } = await admin.auth.admin.updateUserById(request.auth_user_id, { ban_duration: "876000h" });
    if (banError) return json({ error: "تعذر إيقاف الحساب المرتبط بالطلب." }, 500);
    const { error: updateError } = await admin.from("branch_manager_requests").update({
      status: "rejected", reviewed_at: new Date().toISOString(), reviewed_by: authData.user.id,
    }).eq("id", request.id).eq("status", "pending");
    if (updateError) return json({ error: "تعذر حفظ قرار الرفض." }, 500);
    return json({ success: true });
  }

  return json({ error: "عملية غير معروفة." }, 400);
});
