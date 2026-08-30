import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "@supabase/supabase-js";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json" },
});

const telegram = async (token: string, chatId: number, text: string, callbackData?: string) => {
  const response = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, ...(callbackData ? { reply_markup: { inline_keyboard: [[{ text: "✅ Подтвердить занятие", callback_data: callbackData }]] } } : {}) }),
  });
  const result = await response.json();
  if (!response.ok || !result.ok) throw new Error(result.description || "Ошибка Telegram");
};

const moscow = (value: string, options: Intl.DateTimeFormatOptions) =>
  new Intl.DateTimeFormat("ru-RU", { timeZone: "Europe/Moscow", ...options }).format(new Date(value));

const ensureCallbackUpdates = async (token: string, supabaseUrl: string) => {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  const secret = [...new Uint8Array(bytes)].map(byte => byte.toString(16).padStart(2, "0")).join("");
  await fetch(`https://api.telegram.org/bot${token}/setWebhook`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: `${supabaseUrl}/functions/v1/telegram-webhook`, secret_token: secret, allowed_updates: ["message", "callback_query"], drop_pending_updates: false }) });
};

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return json({ error: "Метод не поддерживается" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN") || "";
  if (!botToken) return json({ error: "Telegram-бот не настроен" }, 500);
  await ensureCallbackUpdates(botToken, supabaseUrl);

  const service = createClient(supabaseUrl, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  let body: { action?: string } = {};
  try { body = await request.json(); } catch { /* empty body is acceptable */ }

  if (body.action === "test") {
    const authorization = request.headers.get("Authorization") || "";
    const caller = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } } });
    const user = await caller.auth.getUser();
    if (user.error || !user.data.user) return json({ error: "Нужно войти в приложение" }, 401);
    const target = await service.from("app_users").select("guardian_id,instructor_id,guardians(telegram_chat_id),instructors(telegram_chat_id)").eq("id", user.data.user.id).maybeSingle();
    const guardian = target.data?.guardians as unknown as { telegram_chat_id: number | null } | null;
    const instructor = target.data?.instructors as unknown as { telegram_chat_id: number | null } | null;
    const chatId = guardian?.telegram_chat_id || instructor?.telegram_chat_id;
    if (target.error || !chatId) return json({ error: "Telegram не подключён" }, 400);
    await telegram(botToken, chatId, "✅ Тестовое уведомление «АкваВнуково». Telegram подключён и готов получать уведомления о расписании.");
    return json({ ok: true });
  }

  const secret = request.headers.get("X-Reminder-Secret") || "";
  const verified = await service.rpc("verify_telegram_reminder_secret", { p_secret: secret });
  if (verified.error || verified.data !== true) return json({ error: "Недостаточно прав" }, 403);

  const claimed = await service.rpc("claim_telegram_lesson_reminders", { p_limit: 100 });
  if (claimed.error) return json({ error: claimed.error.message }, 500);

  let sent = 0;
  let failed = 0;
  for (const item of claimed.data || []) {
    const date = moscow(item.starts_at, { weekday: "long", day: "numeric", month: "long" });
    const start = moscow(item.starts_at, { hour: "2-digit", minute: "2-digit" });
    const end = moscow(item.ends_at, { hour: "2-digit", minute: "2-digit" });
    const text = item.recipient_type === "instructor"
      ? `🏊 Ваше занятие «АкваВнуково»\n\nЗавтра, ${date}, в ${start}.\nПловец: ${item.child_name}.\nВремя: ${start}–${end}.`
      : item.reminder_stage === "created"
        ? `🏊 АкваВнуково\n\nЗдравствуйте! Вы записаны на занятие.\nДата: ${date}.\nВремя: ${start}–${end}.\nРебёнок: ${item.child_name}.\nИнструктор: ${item.instructor_name}.`
      : `🏊 ${item.reminder_stage === "repeat" && item.confirmation_enabled ? "Занятие ещё не подтверждено" : "Напоминание"} «АкваВнуково»\n\nЗавтра, ${date}, у ${item.child_name} занятие в ${start}.\nИнструктор: ${item.instructor_name}.\nВремя: ${start}–${end}.`;
    try {
      const callback = item.confirmation_enabled ? (item.recipient_type === "instructor" ? `ic:${item.lesson_id}` : `pc:${item.notification_id}`) : undefined;
      await telegram(botToken, item.chat_id, text, callback);
      await service.rpc("finish_telegram_notification", { p_notification_id: item.notification_id, p_success: true, p_error: null });
      sent += 1;
    } catch (error) {
      await service.rpc("finish_telegram_notification", { p_notification_id: item.notification_id, p_success: false, p_error: error instanceof Error ? error.message : String(error) });
      failed += 1;
    }
  }

  return json({ ok: true, claimed: (claimed.data || []).length, sent, failed });
});
