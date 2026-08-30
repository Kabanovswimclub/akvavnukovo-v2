import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const text = (body: string, status = 200) => new Response(body, {
  status,
  headers: { ...cors, "Content-Type": "text/plain; charset=utf-8" },
});

const clean = (value: unknown) => String(value ?? "").trim();

function valueOf(payload: Record<string, string>, aliases: string[]): string {
  for (const alias of aliases) {
    const direct = clean(payload[alias]);
    if (direct) return direct;
  }
  const lower = new Map(Object.entries(payload).map(([key, value]) => [key.toLowerCase(), value]));
  for (const alias of aliases) {
    const found = clean(lower.get(alias.toLowerCase()));
    if (found) return found;
  }
  return "";
}

function parseDate(value: string): string | null {
  const source = clean(value);
  if (!source) return null;
  let match = source.match(/^(\d{4})[-./](\d{1,2})[-./](\d{1,2})$/);
  if (match) return `${match[1]}-${match[2].padStart(2, "0")}-${match[3].padStart(2, "0")}`;
  match = source.match(/^(\d{1,2})[-./](\d{1,2})[-./](\d{4})$/);
  if (!match) return null;
  return `${match[3]}-${match[2].padStart(2, "0")}-${match[1].padStart(2, "0")}`;
}

async function readPayload(request: Request): Promise<Record<string, string>> {
  const contentType = request.headers.get("content-type")?.toLowerCase() || "";
  if (contentType.includes("application/json")) {
    const body = await request.json();
    return Object.fromEntries(Object.entries(body || {}).map(([key, value]) => [key, clean(value)]));
  }
  const form = await request.formData();
  const payload: Record<string, string> = {};
  for (const [key, value] of form.entries()) {
    if (typeof value !== "string") continue;
    payload[key] = payload[key] ? `${payload[key]}, ${value}` : value;
  }
  return payload;
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return text("OK");
  if (request.method !== "POST") return text("Method Not Allowed", 405);

  let payload: Record<string, string>;
  try {
    payload = await readPayload(request);
  } catch (error) {
    console.error("Tilda payload parse failed", error);
    return text("Invalid payload", 400);
  }

  // Tilda sends this request while the webhook is being connected.
  if (clean(payload.test).toLowerCase() === "test") return text("OK");

  const expectedSecret = Deno.env.get("TILDA_WEBHOOK_SECRET") || "";
  const url = new URL(request.url);
  const suppliedSecret = valueOf(payload, ["form", "secret"])
    || clean(url.searchParams.get("form"))
    || clean(url.searchParams.get("secret"));

  // Respond silently so the endpoint does not reveal whether the secret was valid.
  if (!expectedSecret || suppliedSecret !== expectedSecret) {
    console.warn("Rejected Tilda webhook: invalid secret");
    return text("OK");
  }

  const childName = valueOf(payload, ["имя_ребенка", "имя_ребёнка", "child_name", "child", "name", "Name"]);
  if (!childName) return text("Child name is required", 400);

  const communication = valueOf(payload, ["Как_держать_связь", "как_держать_связь", "communication", "messenger"])
    .toLocaleLowerCase("ru-RU");
  const tranid = valueOf(payload, ["tranid"]);
  const formId = valueOf(payload, ["formid"]);

  const row = {
    child_name: childName,
    birth_date: parseDate(valueOf(payload, ["Дата_рождения", "дата_рождения", "birth_date", "birthday", "Date"])),
    parent_name: valueOf(payload, ["имя_родителя", "ФИО_родителя", "parent_name", "parent"] ) || null,
    phone: valueOf(payload, ["телефон", "phone", "Phone"] ) || null,
    telegram: communication.includes("telegram") || communication.includes("телеграм"),
    max_messenger: communication.includes("max") || communication.includes("макс"),
    preferred_days: valueOf(payload, ["когда_хотят_прийти_день", "желаемые_дни", "preferred_days", "days"] ) || null,
    preferred_time: valueOf(payload, ["удобное_время", "желаемое_время", "preferred_time", "time", "Time"] ) || null,
    email: valueOf(payload, ["почта", "email", "Email"] ).toLowerCase() || null,
    comment: valueOf(payload, ["Ваш_комментарий", "ваш_комментарий", "comment", "comments", "Comments"] ) || null,
    status: "new" as const,
    source: "tilda",
    tilda_tranid: tranid || null,
    tilda_form_id: formId || null,
    source_url: valueOf(payload, ["source_url", "page_url", "url", "Url"] ) || request.headers.get("referer") || null,
  };

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const endpoint = `${supabaseUrl}/rest/v1/requests${tranid ? "?on_conflict=tilda_tranid" : ""}`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      Prefer: tranid ? "return=minimal,resolution=ignore-duplicates" : "return=minimal",
    },
    body: JSON.stringify(row),
  });
  if (!response.ok) {
    console.error("Tilda request insert failed", {
      tranid,
      status: response.status,
      message: await response.text(),
    });
    return text("Temporary error", 500);
  }

  try {
    await fetch(`${supabaseUrl}/functions/v1/staff-notifications`, {
      method: "POST",
      headers: { Authorization: `Bearer ${serviceKey}` },
    });
  } catch (error) {
    console.error("New request push dispatch failed", error);
  }

  return text("OK");
});
