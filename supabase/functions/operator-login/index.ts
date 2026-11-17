import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const expectedCode = Deno.env.get("OPERATOR_ACCESS_CODE") ?? "";
  const operatorEmail = Deno.env.get("OPERATOR_AUTH_EMAIL") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!/^\d{6}$/.test(expectedCode) || !operatorEmail || !supabaseUrl || !serviceRoleKey) {
    return json({ error: "إعدادات دخول مدير التشغيل غير مكتملة على الخادم." }, 500);
  }

  let body: { code?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "طلب غير صالح." }, 400);
  }
  const suppliedCode = String(body.code ?? "");
  if (!/^\d{6}$/.test(suppliedCode)) return json({ error: "الكود يجب أن يتكون من 6 أرقام." }, 400);

  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  const ipHash = await sha256(forwarded + ":" + supabaseUrl);
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const since = new Date(Date.now() - 15 * 60 * 1000).toISOString();
  const { count, error: countError } = await admin
    .from("operations_login_attempts")
    .select("id", { count: "exact", head: true })
    .eq("ip_hash", ipHash)
    .gte("attempted_at", since);
  if (countError) return json({ error: "تعذر التحقق من المحاولات. تأكد من تنفيذ تحديث قاعدة البيانات." }, 500);
  if ((count ?? 0) >= 5) return json({ error: "تم إيقاف المحاولات مؤقتًا. حاول بعد 15 دقيقة." }, 429);

  if (suppliedCode !== expectedCode) {
    await admin.from("operations_login_attempts").insert({ ip_hash: ipHash });
    return json({ error: "الكود غير صحيح." }, 401);
  }

  await admin.from("operations_login_attempts").delete().eq("ip_hash", ipHash);

  const { data: usersData, error: usersError } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (usersError) return json({ error: "تعذر تجهيز حساب مدير التشغيل." }, 500);
  let operator = usersData.users.find((user) => user.email?.toLowerCase() === operatorEmail.toLowerCase());

  if (!operator) {
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email: operatorEmail,
      password: crypto.randomUUID() + crypto.randomUUID(),
      email_confirm: true,
      user_metadata: { account_type: "operations_manager" },
    });
    if (createError || !created.user) return json({ error: "تعذر إنشاء حساب مدير التشغيل." }, 500);
    operator = created.user;
  }

  const { error: profileError } = await admin.from("profiles").upsert(
    { user_id: operator.id, role: "operations_manager" },
    { onConflict: "user_id" },
  );
  if (profileError) return json({ error: "تعذر تفعيل صلاحية مدير التشغيل. تأكد من تنفيذ تحديث قاعدة البيانات." }, 500);

  const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email: operatorEmail,
  });
  const tokenHash = linkData?.properties?.hashed_token;
  if (linkError || !tokenHash) return json({ error: "تعذر إنشاء جلسة آمنة لمدير التشغيل." }, 500);

  return json({ token_hash: tokenHash });
});
