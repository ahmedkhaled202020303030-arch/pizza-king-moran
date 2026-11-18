import { createClient } from "npm:@supabase/supabase-js@2";
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from "npm:@simplewebauthn/server@13.1.2";

const ORIGIN = "https://pizza-king-moran.pages.dev";
const RP_ID = "pizza-king-moran.pages.dev";
const RP_NAME = "Pizza King & Morin";
const corsHeaders = {
  "Access-Control-Allow-Origin": ORIGIN,
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json" },
});
const encode = (bytes: Uint8Array) => {
  let binary = "";
  bytes.forEach((byte) => binary += String.fromCharCode(byte));
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
};
const decode = (value: string) => {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
};
const isKind = (value: unknown): value is "check_in" | "check_out" =>
  value === "check_in" || value === "check_out";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    const origin = req.headers.get("origin");
    if (origin !== ORIGIN) return new Response("Forbidden", { status: 403 });
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  if (req.headers.get("origin") !== ORIGIN) return json({ error: "مصدر الطلب غير مسموح." }, 403);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "إعدادات الخادم غير مكتملة." }, 500);

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "سجل الدخول أولاً." }, 401);
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  if (authError || !authData.user) return json({ error: "جلسة الدخول غير صالحة. سجل الدخول مرة أخرى." }, 401);
  const user = authData.user;
  const { data: profile, error: profileError } = await admin.from("profiles")
    .select("role,username").eq("user_id", user.id).maybeSingle();
  if (profileError || profile?.role !== "branch_manager") {
    return json({ error: "خدمة البصمة متاحة لمديري الفروع فقط." }, 403);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "طلب غير صالح." }, 400); }
  const action = String(body.action ?? "");

  if (action === "status") {
    const { data, error } = await admin.from("branch_manager_webauthn_credentials")
      .select("credential_id,created_at").eq("user_id", user.id);
    if (error) return json({ error: "تعذر قراءة حالة البصمة. تأكد من تنفيذ تحديث قاعدة البيانات." }, 500);
    return json({ enrolled: !!data?.length, devices: data?.length ?? 0 });
  }

  if (action === "registration-options") {
    const { data: existing, error } = await admin.from("branch_manager_webauthn_credentials")
      .select("credential_id,transports").eq("user_id", user.id);
    if (error) return json({ error: "تعذر تجهيز تسجيل البصمة." }, 500);
    const options = await generateRegistrationOptions({
      rpName: RP_NAME,
      rpID: RP_ID,
      userID: new TextEncoder().encode(user.id),
      userName: String(profile.username || user.email || user.id),
      userDisplayName: String(user.user_metadata?.display_name || profile.username || "Branch Manager"),
      attestationType: "none",
      authenticatorSelection: {
        authenticatorAttachment: "platform",
        residentKey: "preferred",
        userVerification: "required",
      },
      excludeCredentials: (existing ?? []).map((item) => ({
        id: item.credential_id,
        transports: item.transports ?? [],
      })),
    });
    const { data: challenge, error: saveError } = await admin.from("branch_manager_webauthn_challenges")
      .insert({ user_id: user.id, challenge: options.challenge, purpose: "registration",
        expires_at: new Date(Date.now() + 5 * 60 * 1000).toISOString() })
      .select("id").single();
    if (saveError) return json({ error: "تعذر حفظ طلب تسجيل البصمة." }, 500);
    return json({ options, challenge_id: challenge.id });
  }

  if (action === "registration-verify") {
    const challengeId = String(body.challenge_id ?? "");
    const response = body.response as Parameters<typeof verifyRegistrationResponse>[0]["response"];
    if (!challengeId || !response) return json({ error: "بيانات تسجيل البصمة غير مكتملة." }, 400);
    const { data: challenge, error } = await admin.from("branch_manager_webauthn_challenges")
      .select("*").eq("id", challengeId).eq("user_id", user.id)
      .eq("purpose", "registration").is("used_at", null).gt("expires_at", new Date().toISOString()).maybeSingle();
    if (error || !challenge) return json({ error: "انتهت صلاحية طلب التسجيل. ابدأ من جديد." }, 400);
    let verification;
    try {
      verification = await verifyRegistrationResponse({
        response, expectedChallenge: challenge.challenge, expectedOrigin: ORIGIN,
        expectedRPID: RP_ID, requireUserVerification: true,
      });
    } catch (_error) {
      return json({ error: "تعذر التحقق من البصمة على هذا الهاتف. حاول مرة أخرى." }, 400);
    }
    if (!verification.verified || !verification.registrationInfo) {
      return json({ error: "لم يكتمل التحقق من البصمة." }, 400);
    }
    const { data: consumed } = await admin.from("branch_manager_webauthn_challenges")
      .update({ used_at: new Date().toISOString() }).eq("id", challengeId).is("used_at", null)
      .select("id").maybeSingle();
    if (!consumed) return json({ error: "تم استخدام طلب التسجيل بالفعل. ابدأ من جديد." }, 409);

    const info = verification.registrationInfo;
    const credential = info.credential;
    const { error: saveCredentialError } = await admin.from("branch_manager_webauthn_credentials").upsert({
      credential_id: credential.id,
      user_id: user.id,
      public_key: encode(credential.publicKey),
      counter: credential.counter,
      transports: credential.transports ?? [],
      device_type: info.credentialDeviceType,
      backed_up: info.credentialBackedUp,
    }, { onConflict: "credential_id" });
    if (saveCredentialError) return json({ error: "تم التحقق لكن تعذر حفظ البصمة. حاول مرة أخرى." }, 500);
    return json({ success: true });
  }

  if (action === "authentication-options") {
    const kind = body.kind;
    if (!isKind(kind)) return json({ error: "نوع الحركة غير صحيح." }, 400);
    const { data: credentials, error } = await admin.from("branch_manager_webauthn_credentials")
      .select("credential_id,transports").eq("user_id", user.id);
    if (error) return json({ error: "تعذر تجهيز التحقق بالبصمة." }, 500);
    if (!credentials?.length) return json({ error: "سجّل بصمة هذا الهاتف أولاً." }, 409);
    const options = await generateAuthenticationOptions({
      rpID: RP_ID,
      allowCredentials: credentials.map((item) => ({
        id: item.credential_id,
        transports: item.transports ?? [],
      })),
      userVerification: "required",
    });
    const { data: challenge, error: saveError } = await admin.from("branch_manager_webauthn_challenges")
      .insert({ user_id: user.id, challenge: options.challenge, purpose: "authentication",
        attendance_kind: kind, expires_at: new Date(Date.now() + 3 * 60 * 1000).toISOString() })
      .select("id").single();
    if (saveError) return json({ error: "تعذر بدء التحقق بالبصمة." }, 500);
    return json({ options, challenge_id: challenge.id });
  }

  if (action === "authentication-verify") {
    const challengeId = String(body.challenge_id ?? "");
    const response = body.response as Parameters<typeof verifyAuthenticationResponse>[0]["response"];
    if (!challengeId || !response) return json({ error: "بيانات التحقق غير مكتملة." }, 400);
    const { data: challenge, error } = await admin.from("branch_manager_webauthn_challenges")
      .select("*").eq("id", challengeId).eq("user_id", user.id)
      .eq("purpose", "authentication").is("used_at", null).gt("expires_at", new Date().toISOString()).maybeSingle();
    if (error || !challenge || !isKind(challenge.attendance_kind)) {
      return json({ error: "انتهت صلاحية طلب البصمة. أعد المحاولة." }, 400);
    }
    const { data: credential, error: credentialError } = await admin.from("branch_manager_webauthn_credentials")
      .select("*").eq("credential_id", String(response.id ?? "")).eq("user_id", user.id).maybeSingle();
    if (credentialError || !credential) return json({ error: "البصمة غير مسجلة لهذا الحساب." }, 403);
    let verification;
    try {
      verification = await verifyAuthenticationResponse({
        response, expectedChallenge: challenge.challenge, expectedOrigin: ORIGIN,
        expectedRPID: RP_ID, requireUserVerification: true,
        credential: {
          id: credential.credential_id,
          publicKey: decode(credential.public_key),
          counter: Number(credential.counter),
          transports: credential.transports ?? [],
        },
      });
    } catch (_error) {
      return json({ error: "فشل التحقق من بصمة الهاتف." }, 401);
    }
    if (!verification.verified) return json({ error: "فشل التحقق من بصمة الهاتف." }, 401);
    const { data: consumed } = await admin.from("branch_manager_webauthn_challenges")
      .update({ used_at: new Date().toISOString() }).eq("id", challengeId).is("used_at", null)
      .select("id").maybeSingle();
    if (!consumed) return json({ error: "تم استخدام طلب البصمة بالفعل. أعد المحاولة." }, 409);

    const { error: counterError } = await admin.from("branch_manager_webauthn_credentials")
      .update({ counter: verification.authenticationInfo.newCounter, last_used_at: new Date().toISOString() })
      .eq("credential_id", credential.credential_id).eq("user_id", user.id);
    if (counterError) return json({ error: "تم التحقق لكن تعذر تحديث سجل البصمة." }, 500);
    const { data: ticket, error: ticketError } = await admin.from("branch_attendance_biometric_tickets")
      .insert({ user_id: user.id, attendance_kind: challenge.attendance_kind,
        expires_at: new Date(Date.now() + 90 * 1000).toISOString() })
      .select("id").single();
    if (ticketError) return json({ error: "تم التحقق لكن تعذر تجهيز تصريح تسجيل الحركة." }, 500);
    return json({ success: true, biometric_ticket: ticket.id });
  }

  return json({ error: "عملية غير معروفة." }, 400);
});
