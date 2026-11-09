import { env } from "cloudflare:workers";
import { decodeJwt, decodeProtectedHeader } from "jose";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import { phoneCleanup, phoneVerificationsPerDay } from "../src/phone/calls";
import { classifyNumber } from "../src/phone/numbers";
import { twilioSignature } from "../src/phone/twilio";
import { parseConfig } from "../src/config";
import { type Harness, type Session, defaultHarness, envWith, expectError, grantAppStoreSubscription, refreshed, req, signIn } from "./helpers";

/** Fake Twilio values: right format, not real. */
const accountSid: string = `AC${"0123456789abcdef".repeat(2)}`;
const authToken: string = "fedcba9876543210".repeat(2);
const appSid: string = `AP${"a1b2c3d4e5f60718".repeat(2)}`;
const twilioAccount: string = `https://api.twilio.com/2010-04-01/Accounts/${accountSid}`;

/** Every request allowed (the tests poll more than the per-user limit allows). */
const allowingLimiter: RateLimit = { limit: async (): Promise<RateLimitOutcome> => ({ success: true }) };

/** The dialer on for US and Canada with fake Twilio secrets. */
const phoneOn: Env = envWith({
  PHONE_CALLS_POLICY: "on",
  TWILIO_ACCOUNT_SID: accountSid,
  TWILIO_API_KEY_SID: `SK${"1234567890abcdef".repeat(2)}`,
  TWILIO_API_KEY_SECRET: "test-twilio-api-key-secret-000000000",
  TWILIO_AUTH_TOKEN: authToken,
  TWILIO_TWIML_APP_SID: appSid,
  PROXY_USER_LIMITER: allowingLimiter,
});

/** The tests share one database: each test runs on its own day and verifies its own number. */
const callerFor = (harness: Harness): string => `+1415555${1000 + new Date(harness.clock.nowMs).getUTCDate()}`;
const today = (harness: Harness): string => new Date(harness.clock.nowMs).toISOString().slice(0, 10);
const destination: string = "+12125550199";
const hex32 = (seed: string): string => seed.repeat(32).slice(0, 32);

/** A fake Twilio REST API: caller ID verification, caller ID lookups and deletions, recordings. */
interface FakeTwilio {
  /** Numbers that are already caller IDs of the account (sid by number). */
  readonly callerIds: Map<string, string>;
  readonly deleted: string[];
  verificationCalls: number;
}

function fakeTwilio(harness: Harness): FakeTwilio {
  const fake: FakeTwilio = { callerIds: new Map(), deleted: [], verificationCalls: 0 };
  harness.stub(`${twilioAccount}/`, async (request: Request): Promise<Response> => {
    expect(request.headers.get("authorization")).toMatch(/^Basic /);
    const url: URL = new URL(request.url);
    const path: string = url.pathname.slice(`/2010-04-01/Accounts/${accountSid}`.length);
    if (path === "/OutgoingCallerIds.json" && request.method === "POST") {
      const form: URLSearchParams = new URLSearchParams(await request.text());
      const number: string = form.get("PhoneNumber") ?? "";
      expect(form.get("StatusCallback")).toBe("https://api.test/v1/phone/webhooks/verification");
      if (fake.callerIds.has(number)) {
        return Response.json({ code: 21450, message: "Phone number is already verified." }, { status: 400 });
      }
      fake.verificationCalls += 1;
      return Response.json({ validation_code: "482913", call_sid: `CA${hex32(String(fake.verificationCalls))}`, phone_number: number }, { status: 201 });
    }
    if (path === "/OutgoingCallerIds.json" && request.method === "GET") {
      const number: string = url.searchParams.get("PhoneNumber") ?? "";
      const sid: string | undefined = fake.callerIds.get(number);
      return Response.json({ outgoing_caller_ids: sid === undefined ? [] : [{ sid, phone_number: number }] });
    }
    if (request.method === "DELETE") {
      fake.deleted.push(path);
      for (const [number, sid] of fake.callerIds) {
        if (path === `/OutgoingCallerIds/${sid}.json`) {
          fake.callerIds.delete(number);
        }
      }
      return new Response(null, { status: 204 });
    }
    if (path.startsWith("/Recordings/") && path.endsWith(".mp3") && request.method === "GET") {
      expect(url.searchParams.get("RequestedChannels")).toBe("2");
      return new Response(new Uint8Array([0x49, 0x44, 0x33, 4, 0]), { headers: { "content-type": "audio/mpeg" } });
    }
    return new Response("unexpected", { status: 500 });
  });
  return fake;
}

/** A webhook request signed like Twilio signs it. */
async function webhook(harness: Harness, path: string, fields: Record<string, string>, signedWith: string): Promise<Response> {
  const all: Map<string, string> = new Map(Object.entries({ AccountSid: accountSid, ...fields }));
  const signature: string = await twilioSignature(signedWith, `https://api.test${path}`, all);
  return harness.call(
    req("POST", path, {
      body: new URLSearchParams([...all.entries()]).toString(),
      headers: { "content-type": "application/x-www-form-urlencoded", "x-twilio-signature": signature },
      env: phoneOn,
    }),
  );
}

async function subscriber(harness: Harness): Promise<Session> {
  const session: Session = await signIn(harness);
  // An App Store subscriber (the iPhone app sells through the App Store; deleting the account needs no Stripe call).
  await grantAppStoreSubscription(session.userId, { status: "active", periodType: "NORMAL", environment: "PRODUCTION", expiresAtMs: harness.clock.nowMs + 30 * 86_400_000 });
  return session;
}

function call(harness: Harness, session: Session, method: string, path: string, json: object | null): Promise<Response> {
  return harness.call(req(method, path, { token: session.accessToken, json, env: phoneOn, country: "US" }));
}

/** Accepts the disclosure and verifies `callerFor(harness)` through the fake verification call. */
async function verifiedCaller(harness: Harness): Promise<Session> {
  const session: Session = await subscriber(harness);
  expect((await call(harness, session, "POST", "/v1/phone/consent", { version: 1 })).status).toBe(200);
  const started: Response = await call(harness, session, "POST", "/v1/phone/number", { number: callerFor(harness) });
  expect(started.status).toBe(200);
  expect(await started.json()).toMatchObject({ e164: callerFor(harness), status: "pending", validationCode: "482913" });
  const row: { validation_call_sid: string } | null = await env.DB.prepare("SELECT validation_call_sid FROM phone_numbers WHERE user_id = ?")
    .bind(session.userId)
    .first<{ validation_call_sid: string }>();
  const result: Response = await webhook(
    harness,
    "/v1/phone/webhooks/verification",
    { CallSid: row?.validation_call_sid ?? "", VerificationStatus: "success", OutgoingCallerIdSid: `PN${hex32("7")}` },
    authToken,
  );
  expect(result.status).toBe(200);
  return session;
}

interface Reserved {
  readonly callId: string;
  readonly accessToken: string;
  readonly maxSeconds: number;
}

async function reserve(harness: Harness, session: Session, to: string): Promise<Reserved> {
  const response: Response = await call(harness, session, "POST", "/v1/phone/calls", { to });
  expect(response.status).toBe(201);
  return response.json<Reserved>();
}

const voice = (harness: Harness, callId: string, callSid: string): Promise<Response> =>
  webhook(harness, "/v1/phone/webhooks/voice", { CallSid: callSid, From: `client:gs_${callId.replaceAll("-", "")}`, To: "", callId }, authToken);

describe("phone numbers", () => {
  it("classifies destinations: US, Canada, toll-free, premium, Caribbean, foreign, malformed", () => {
    expect(classifyNumber("+12125550199")).toEqual({ kind: "callable", e164: "+12125550199", country: "US" });
    expect(classifyNumber("+14165550199")).toEqual({ kind: "callable", e164: "+14165550199", country: "CA" });
    expect(classifyNumber("+18005550199")).toMatchObject({ kind: "callable", country: "US" });
    expect(classifyNumber("+19005550199")).toEqual({ kind: "blocked", reason: "premium" });
    expect(classifyNumber("+12129765555")).toEqual({ kind: "blocked", reason: "premium" });
    expect(classifyNumber("+18765550199")).toEqual({ kind: "blocked", reason: "unsupported" });
    expect(classifyNumber("+447700900123")).toEqual({ kind: "blocked", reason: "unsupported" });
    expect(classifyNumber("+905321234567")).toEqual({ kind: "callable", e164: "+905321234567", country: "TR" });
    expect(classifyNumber("+909001234567")).toEqual({ kind: "blocked", reason: "premium" });
    expect(classifyNumber("+358401234567")).toEqual({ kind: "callable", e164: "+358401234567", country: "FI" });
    expect(classifyNumber("+3586001234")).toEqual({ kind: "blocked", reason: "premium" });
    for (const malformed of ["911", "+1911", "+19115550199", "+12121115555", "2125550199", "+1212555019", "+0123456789"]) {
      expect(classifyNumber(malformed)).toEqual({ kind: "invalid" });
    }
  });
});

describe("phone configuration", () => {
  it("is off in development by default and needs every Twilio value when on", () => {
    expect(parseConfig(env).phoneCalls).toEqual({ policy: "off" });
    expect(parseConfig(phoneOn).phoneCalls).toMatchObject({ policy: "on", countries: ["US", "CA"], maxCallSeconds: 3600 });
    expect(() => parseConfig(envWith({ ...phoneOn, TWILIO_AUTH_TOKEN: "not-a-token" }))).toThrow(/TWILIO_AUTH_TOKEN/);
    expect(() => parseConfig(envWith({ ...phoneOn, PHONE_CALLS_COUNTRIES: "US,GB" }))).toThrow(/PHONE_CALLS_COUNTRIES/);
    expect(() => parseConfig(envWith({ ...phoneOn, PHONE_USD_PER_MINUTE: "US:0.025" }))).toThrow(/PHONE_USD_PER_MINUTE/);
    expect(() => parseConfig(envWith({ ...phoneOn, PHONE_DAILY_SPEND_CEILING_USD: "100" }))).toThrow(/PHONE_DAILY_SPEND_CEILING_USD/);
  });
});

describe("in-app dialer", () => {
  it("is hidden while the policy is off, and nothing reaches Twilio", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 16, 12);
    const session: Session = await subscriber(harness);
    const status: Response = await harness.call(req("GET", "/v1/phone", { token: session.accessToken, country: "US" }));
    expect(await status.json()).toMatchObject({ available: false, reason: "policy_off", provider: null });
    await expectError(await harness.call(req("POST", "/v1/phone/calls", { token: session.accessToken, json: { to: destination } })), 503, "phone_unavailable");
    await expectError(await harness.call(req("POST", "/v1/phone/webhooks/voice", { body: "a=b", headers: { "content-type": "application/x-www-form-urlencoded" } })), 503, "phone_unavailable");
    expect(harness.outbound.some((request: Request): boolean => request.url.startsWith("https://api.twilio.com"))).toBe(false);
  });

  it("shows the dialer only in an allowed country and to subscribers", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 17, 12);
    const free: Session = await signIn(harness);
    const status = async (session: Session, country: string | null): Promise<unknown> =>
      (await harness.call(req("GET", "/v1/phone", { token: session.accessToken, env: phoneOn, country }))).json();
    expect(await status(free, "FI")).toMatchObject({ available: false, reason: "country_not_allowed" });
    expect(await status(free, null)).toMatchObject({ available: false, reason: "country_not_allowed" });
    expect(await status(free, "US")).toMatchObject({ available: false, reason: "subscription_required" });
    const paid: Session = await subscriber(harness);
    expect(await status(paid, "CA")).toMatchObject({
      available: true,
      reason: null,
      countries: ["US", "CA"],
      provider: "Twilio",
      consentAccepted: false,
      number: null,
      maxCallMinutes: 60,
      monthlyMinutes: 120,
    });
  });

  it("verifies the user's own number by a call, once per account and number", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 18, 12);
    const twilio: FakeTwilio = fakeTwilio(harness);
    const first: Session = await subscriber(harness);
    await expectError(await call(harness, first, "POST", "/v1/phone/number", { number: callerFor(harness) }), 403, "phone_consent_required");
    const session: Session = await verifiedCaller(harness);
    expect(await (await call(harness, session, "GET", "/v1/phone/number", null)).json()).toEqual({ number: { e164: callerFor(harness), status: "verified" } });
    expect(await (await call(harness, session, "GET", "/v1/phone", null)).json()).toMatchObject({ consentAccepted: true, number: { status: "verified" } });
    // Verifying the same number again needs no call.
    expect(await (await call(harness, session, "POST", "/v1/phone/number", { number: callerFor(harness) })).json()).toEqual({ e164: callerFor(harness), status: "verified" });
    expect(twilio.verificationCalls).toBe(1);
    // Another account can't take a verified number.
    expect((await call(harness, first, "POST", "/v1/phone/consent", { version: 1 })).status).toBe(200);
    await expectError(await call(harness, first, "POST", "/v1/phone/number", { number: callerFor(harness) }), 409, "phone_number_in_use");
    // Premium, Caribbean, foreign and malformed numbers are refused before any call.
    await expectError(await call(harness, first, "POST", "/v1/phone/number", { number: "+19005550100" }), 403, "phone_number_blocked");
    await expectError(await call(harness, first, "POST", "/v1/phone/number", { number: "+905321234567" }), 403, "phone_number_blocked");
    await expectError(await call(harness, first, "POST", "/v1/phone/number", { number: "415 555 0100" }), 400, "phone_number_invalid");
    expect(twilio.verificationCalls).toBe(1);
  });

  it("limits verification calls per day, reclaims a leftover caller ID and rejects unsigned webhooks", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 19, 12);
    const twilio: FakeTwilio = fakeTwilio(harness);
    const session: Session = await subscriber(harness);
    expect((await call(harness, session, "POST", "/v1/phone/consent", { version: 1 })).status).toBe(200);
    // A caller ID left at Twilio by an account deleted earlier: removed, then verified again by a new call.
    twilio.callerIds.set("+14155550100", `PN${hex32("9")}`);
    expect((await call(harness, session, "POST", "/v1/phone/number", { number: "+14155550100" })).status).toBe(200);
    expect(twilio.deleted).toEqual([`/OutgoingCallerIds/PN${hex32("9")}.json`]);
    for (let attempt: number = 2; attempt <= phoneVerificationsPerDay; attempt += 1) {
      expect((await call(harness, session, "POST", "/v1/phone/number", { number: `+1415555010${attempt}` })).status).toBe(200);
    }
    await expectError(await call(harness, session, "POST", "/v1/phone/number", { number: "+14155550109" }), 429, "phone_verification_limit");
    // A forged result (wrong signing key) changes nothing.
    const row = await env.DB.prepare("SELECT validation_call_sid FROM phone_numbers WHERE user_id = ?").bind(session.userId).first<{ validation_call_sid: string }>();
    const forged: Response = await webhook(
      harness,
      "/v1/phone/webhooks/verification",
      { CallSid: row?.validation_call_sid ?? "", VerificationStatus: "success", OutgoingCallerIdSid: `PN${hex32("1")}` },
      "0000000000000000".repeat(2),
    );
    await expectError(forged, 403, "forbidden");
    expect(await (await call(harness, session, "GET", "/v1/phone/number", null)).json()).toMatchObject({ number: { status: "pending" } });
    // Past the window without a result, Twilio is asked once; the number isn't a caller ID, so it failed.
    harness.clock.nowMs += 11 * 60_000;
    expect(await (await call(harness, session, "GET", "/v1/phone/number", null)).json()).toMatchObject({ number: { status: "failed" } });
    // Removing the number does not reset the day's count of verification calls.
    expect((await call(harness, session, "DELETE", "/v1/phone/number", null)).status).toBe(200);
    await expectError(await call(harness, session, "POST", "/v1/phone/number", { number: "+14155550109" }), 429, "phone_verification_limit");
  });

  it("places a call: one-time TwiML with the notice, caller ID and limits; settles, then serves and deletes the recording", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 20, 12);
    const twilio: FakeTwilio = fakeTwilio(harness);
    const session: Session = await verifiedCaller(harness);
    await expectError(await call(harness, session, "POST", "/v1/phone/calls", { to: "+19005550100" }), 403, "phone_number_blocked");
    await expectError(await call(harness, session, "POST", "/v1/phone/calls", { to: callerFor(harness) }), 400, "phone_number_invalid");
    const reserved: Reserved = await reserve(harness, session, destination);
    expect(reserved.maxSeconds).toBe(3600);
    const header = decodeProtectedHeader(reserved.accessToken);
    expect(header).toMatchObject({ alg: "HS256", cty: "twilio-fpa;v=1" });
    const claims = decodeJwt(reserved.accessToken);
    expect(claims["grants"]).toEqual({ identity: `gs_${reserved.callId.replaceAll("-", "")}`, voice: { outgoing: { application_sid: appSid } } });
    expect((claims.exp ?? 0) - (claims.iat ?? 0)).toBe(120);
    // A second call while this one runs is refused.
    await expectError(await call(harness, session, "POST", "/v1/phone/calls", { to: "+12125550123" }), 409, "phone_call_active");

    const callSid: string = `CA${hex32("c")}`;
    // A webhook without Twilio's signature is refused.
    await expectError(
      await harness.call(req("POST", "/v1/phone/webhooks/voice", { body: `AccountSid=${accountSid}&callId=${reserved.callId}`, headers: { "content-type": "application/x-www-form-urlencoded" }, env: phoneOn })),
      403,
      "forbidden",
    );
    const twiml: string = await (await voice(harness, reserved.callId, callSid)).text();
    expect(twiml).toContain(`<Dial callerId="${callerFor(harness)}" timeLimit="3600" timeout="45" answerOnBridge="true"`);
    expect(twiml).toContain('record="record-from-answer-dual"');
    expect(twiml).toContain(`<Number url="https://api.test/v1/phone/webhooks/announcement?call=${reserved.callId}" method="POST">${destination}</Number>`);
    // The token is single-use: the same call can't be bridged twice.
    expect(await (await voice(harness, reserved.callId, `CA${hex32("d")}`)).text()).toContain("<Hangup/>");

    const announcement: string = await (await webhook(harness, `/v1/phone/webhooks/announcement?call=${reserved.callId}`, { CallSid: `CA${hex32("e")}` }, authToken)).text();
    expect(announcement).toContain('<Say language="en-US">Hello. This call is recorded and transcribed by Gistsmith');

    const done: Response = await webhook(harness, `/v1/phone/webhooks/dial-done?call=${reserved.callId}`, { CallSid: callSid, DialCallStatus: "completed", DialCallDuration: "125" }, authToken);
    expect(await done.text()).toContain("<Hangup/>");
    const settled = await env.DB.prepare("SELECT status, billed_seconds, cost_micro_usd, destination, caller_id FROM phone_calls WHERE id = ?").bind(reserved.callId).first();
    // 125 s → 3 talk minutes + 1 minute of ringing and notice at 0.025 $/min.
    expect(settled).toEqual({ status: "completed", billed_seconds: 125, cost_micro_usd: 100_000, destination: null, caller_id: null });
    const spend = await env.DB.prepare("SELECT micro_usd, phone_micro_usd FROM daily_spend WHERE day = ?").bind(today(harness)).first();
    // Plus the verification call earlier that day (`verificationCallMicroUsd`).
    expect(spend).toEqual({ micro_usd: 150_000, phone_micro_usd: 150_000 });
    // A late status callback doesn't charge twice.
    await webhook(harness, "/v1/phone/webhooks/call-status", { CallSid: callSid, CallStatus: "completed", CallDuration: "170" }, authToken);
    expect(await env.DB.prepare("SELECT micro_usd FROM daily_spend WHERE day = ?").bind(today(harness)).first()).toEqual({ micro_usd: 150_000 });

    const state = async (): Promise<unknown> => (await call(harness, session, "GET", `/v1/phone/calls/${reserved.callId}`, null)).json();
    expect(await state()).toEqual({ callId: reserved.callId, status: "completed", billedSeconds: 125, recording: "pending" });
    await expectError(await call(harness, session, "GET", `/v1/phone/calls/${reserved.callId}/recording`, null), 409, "phone_recording_unavailable");
    const recordingSid: string = `RE${hex32("f")}`;
    await webhook(harness, `/v1/phone/webhooks/recording?call=${reserved.callId}`, { CallSid: callSid, RecordingSid: recordingSid, RecordingStatus: "completed", RecordingDuration: "120" }, authToken);
    expect(await state()).toMatchObject({ recording: "ready" });
    // Another account can't see or fetch the call.
    const stranger: Session = await subscriber(harness);
    await expectError(await call(harness, stranger, "GET", `/v1/phone/calls/${reserved.callId}/recording`, null), 404, "not_found");
    const audio: Response = await call(harness, session, "GET", `/v1/phone/calls/${reserved.callId}/recording`, null);
    expect(audio.headers.get("content-type")).toBe("audio/mpeg");
    expect((await audio.arrayBuffer()).byteLength).toBe(5);
    expect((await call(harness, session, "DELETE", `/v1/phone/calls/${reserved.callId}/recording`, null)).status).toBe(200);
    expect(twilio.deleted).toContain(`/Recordings/${recordingSid}.json`);
    expect(await state()).toMatchObject({ recording: "deleted" });
    expect(await (await call(harness, session, "GET", "/v1/phone", null)).json()).toMatchObject({ usedMinutes: 3 });
  });

  it("counts a running call's worst case toward the daily ceilings and refuses calls past them", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 21, 12);
    fakeTwilio(harness);
    const session: Session = await verifiedCaller(harness);
    // The ceiling allows one 60-minute call's worst case (61 × 0.025 = 1.525 $) but not two.
    const tight: Env = envWith({ ...phoneOn, PHONE_DAILY_SPEND_CEILING_USD: "2" });
    const first: Response = await harness.call(req("POST", "/v1/phone/calls", { token: session.accessToken, json: { to: destination }, env: tight }));
    expect(first.status).toBe(201);
    const other: Session = await verifiedOther(harness);
    await expectError(await harness.call(req("POST", "/v1/phone/calls", { token: other.accessToken, json: { to: destination }, env: tight })), 503, "phone_capacity_reached");
    // The global ceiling counts the running call next to the day's other spend.
    await env.DB.prepare("UPDATE daily_spend SET micro_usd = micro_usd + ? WHERE day = ?").bind(1_500_000, today(harness)).run();
    const global: Env = envWith({ ...phoneOn, DAILY_SPEND_CEILING_USD: "3.2", PHONE_DAILY_SPEND_CEILING_USD: "3.2" });
    await expectError(await harness.call(req("POST", "/v1/phone/calls", { token: other.accessToken, json: { to: destination }, env: global })), 503, "spend_ceiling_reached");
    const llm: Response = await harness.call(
      req("POST", "/v1/llm/messages", { token: other.accessToken, json: {}, env: envWith({ ...phoneOn, DAILY_SPEND_CEILING_USD: "3", PHONE_DAILY_SPEND_CEILING_USD: "3" }) }),
    );
    await expectError(llm, 503, "spend_ceiling_reached");
  });

  it("caps the call at the plan's remaining monthly minutes", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 22, 12);
    fakeTwilio(harness);
    const session: Session = await verifiedCaller(harness);
    await env.DB.prepare("INSERT INTO monthly_usage (user_id, month, carried_seconds) VALUES (?, '2026-10', ?)").bind(session.userId, 10 * 3600 - 600).run();
    expect((await reserve(harness, session, destination)).maxSeconds).toBe(600);
  });

  it("tells the app an unanswered call, or one whose recording never came, has no recording", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 24, 12);
    fakeTwilio(harness);
    const session: Session = await verifiedCaller(harness);
    const state = async (callId: string): Promise<unknown> => (await call(harness, session, "GET", `/v1/phone/calls/${callId}`, null)).json();
    const unanswered: Reserved = await reserve(harness, session, destination);
    await voice(harness, unanswered.callId, `CA${hex32("1a")}`);
    await webhook(harness, `/v1/phone/webhooks/dial-done?call=${unanswered.callId}`, { CallSid: `CA${hex32("1a")}`, DialCallStatus: "no-answer", DialCallDuration: "0" }, authToken);
    expect(await state(unanswered.callId)).toMatchObject({ status: "failed", billedSeconds: 0, recording: "absent" });
    const answered: Reserved = await reserve(harness, session, destination);
    await voice(harness, answered.callId, `CA${hex32("2b")}`);
    await webhook(harness, `/v1/phone/webhooks/dial-done?call=${answered.callId}`, { CallSid: `CA${hex32("2b")}`, DialCallStatus: "completed", DialCallDuration: "30" }, authToken);
    expect(await state(answered.callId)).toMatchObject({ status: "completed", recording: "pending" });
    harness.clock.nowMs += 11 * 60_000;
    expect(await state(answered.callId)).toMatchObject({ recording: "absent" });
    const neverConnected: Reserved = await reserve(harness, session, destination);
    harness.clock.nowMs += 3 * 60_000;
    expect(await state(neverConnected.callId)).toMatchObject({ status: "reserved", recording: "absent" });
  });

  it("cleanup releases unconnected calls for free, charges lost ones their worst case and purges provider objects", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 23, 12);
    const twilio: FakeTwilio = fakeTwilio(harness);
    const session: Session = await verifiedCaller(harness);
    const unconnected: Reserved = await reserve(harness, session, destination);
    harness.clock.nowMs += 3 * 60_000;
    const lost: Reserved = await reserve(harness, session, destination);
    await voice(harness, lost.callId, `CA${hex32("b")}`);
    harness.clock.nowMs += 2 * 3_600_000;
    const config = parseConfig(phoneOn);
    const report = await phoneCleanup(env.DB, harness.platform, config, new Date(harness.clock.nowMs));
    // Earlier tests in this file leave running calls too (shared database).
    expect(report.expiredCalls).toBeGreaterThanOrEqual(2);
    const rows = await env.DB.prepare("SELECT id, status, cost_micro_usd FROM phone_calls WHERE user_id = ? ORDER BY created_at").bind(session.userId).all();
    expect(rows.results).toEqual([
      { id: unconnected.callId, status: "expired", cost_micro_usd: 0 },
      { id: lost.callId, status: "expired", cost_micro_usd: 61 * 25_000 },
    ]);
    expect(await env.DB.prepare("SELECT phone_micro_usd FROM daily_spend WHERE day = ?").bind(today(harness)).first()).toEqual({ phone_micro_usd: 61 * 25_000 + 50_000 });

    // Account deletion queues the caller ID for deletion at Twilio; the next cleanup deletes it.
    const fresh: Session = await refreshed(harness, session);
    expect((await harness.call(req("DELETE", "/v1/me", { token: fresh.accessToken, env: phoneOn }))).status).toBe(200);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM phone_calls WHERE user_id = ?").bind(session.userId).first()).toEqual({ n: 0 });
    await phoneCleanup(env.DB, harness.platform, config, new Date(harness.clock.nowMs));
    expect(twilio.deleted).toContain(`/OutgoingCallerIds/PN${hex32("7")}.json`);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM phone_provider_purges").first()).toEqual({ n: 0 });
  });

  it("keeps a known recording through repeated, late and out-of-order callbacks and deletes every recording at Twilio", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 25, 12);
    const twilio: FakeTwilio = fakeTwilio(harness);
    const session: Session = await verifiedCaller(harness);
    const recordingRow = (callId: string): Promise<unknown> =>
      env.DB.prepare("SELECT recording_status, recording_sid, recording_deleted_at FROM phone_calls WHERE id = ?").bind(callId).first();
    const queued = async (sid: string): Promise<number> =>
      (await env.DB.prepare("SELECT COUNT(*) AS n FROM phone_provider_purges WHERE provider_sid = ?").bind(sid).first<{ n: number }>())?.n ?? 0;
    const recording = (callId: string, callSid: string, fields: Record<string, string>): Promise<Response> =>
      webhook(harness, `/v1/phone/webhooks/recording?call=${callId}`, { CallSid: callSid, ...fields }, authToken);

    const reserved: Reserved = await reserve(harness, session, destination);
    const callSid: string = `CA${hex32("3c")}`;
    await voice(harness, reserved.callId, callSid);
    await webhook(harness, `/v1/phone/webhooks/dial-done?call=${reserved.callId}`, { CallSid: callSid, DialCallStatus: "completed", DialCallDuration: "90" }, authToken);
    const first: string = `RE${hex32("a1")}`;
    const second: string = `RE${hex32("b2")}`;
    expect((await recording(reserved.callId, callSid, { RecordingSid: first, RecordingStatus: "completed", RecordingDuration: "88" })).status).toBe(200);
    // Twilio retries the same callback: nothing changes, nothing is purged.
    await recording(reserved.callId, callSid, { RecordingSid: first, RecordingStatus: "completed", RecordingDuration: "88" });
    // A late "no recording" callback no longer clears the known sid (it used to, and the recording stayed at Twilio).
    await recording(reserved.callId, callSid, { RecordingStatus: "absent" });
    // A second recording of the same call is queued for deletion; the known one stays.
    await recording(reserved.callId, callSid, { RecordingSid: second, RecordingStatus: "completed", RecordingDuration: "10" });
    expect(await recordingRow(reserved.callId)).toEqual({ recording_status: "ready", recording_sid: first, recording_deleted_at: null });
    expect(await queued(first)).toBe(0);
    expect(await queued(second)).toBe(1);
    // A callback for another call sid of this call id changes nothing and its recording is purged.
    const stray: string = `RE${hex32("c3")}`;
    await recording(reserved.callId, `CA${hex32("4d")}`, { RecordingSid: stray, RecordingStatus: "completed" });
    expect(await queued(stray)).toBe(1);

    // "No recording" first, then the recording after all: it is stored.
    const late: Reserved = await reserve(harness, session, destination);
    const lateSid: string = `CA${hex32("5e")}`;
    await voice(harness, late.callId, lateSid);
    await webhook(harness, `/v1/phone/webhooks/dial-done?call=${late.callId}`, { CallSid: lateSid, DialCallStatus: "completed", DialCallDuration: "40" }, authToken);
    await recording(late.callId, lateSid, { RecordingStatus: "absent" });
    expect(await recordingRow(late.callId)).toEqual({ recording_status: "absent", recording_sid: null, recording_deleted_at: null });
    const lateRecording: string = `RE${hex32("d4")}`;
    await recording(late.callId, lateSid, { RecordingSid: lateRecording, RecordingStatus: "completed", RecordingDuration: "38" });
    expect(await recordingRow(late.callId)).toEqual({ recording_status: "ready", recording_sid: lateRecording, recording_deleted_at: null });

    // The app deletes the first recording; a retried callback afterwards neither restores nor purges it again.
    expect((await call(harness, session, "DELETE", `/v1/phone/calls/${reserved.callId}/recording`, null)).status).toBe(200);
    await recording(reserved.callId, callSid, { RecordingSid: first, RecordingStatus: "completed", RecordingDuration: "88" });
    expect(await recordingRow(reserved.callId)).toMatchObject({ recording_status: "ready", recording_sid: first });
    expect(await queued(first)).toBe(0);

    // A recording of a call that no longer exists is purged.
    const orphan: string = `RE${hex32("e5")}`;
    await webhook(harness, `/v1/phone/webhooks/recording?call=${crypto.randomUUID()}`, { CallSid: callSid, RecordingSid: orphan, RecordingStatus: "completed" }, authToken);
    expect(await queued(orphan)).toBe(1);

    // A late dial-done after the call settled doesn't settle or charge it again.
    const spend = async (): Promise<unknown> => env.DB.prepare("SELECT phone_micro_usd FROM daily_spend WHERE day = ?").bind(today(harness)).first();
    const before: unknown = await spend();
    await webhook(harness, `/v1/phone/webhooks/dial-done?call=${late.callId}`, { CallSid: lateSid, DialCallStatus: "no-answer", DialCallDuration: "0" }, authToken);
    expect(await spend()).toEqual(before);
    expect(await env.DB.prepare("SELECT status, billed_seconds FROM phone_calls WHERE id = ?").bind(late.callId).first()).toEqual({ status: "completed", billed_seconds: 40 });

    // A day later the cleanup deletes the unfetched recording and every queued one at Twilio.
    harness.clock.nowMs += 25 * 3_600_000;
    await phoneCleanup(env.DB, harness.platform, parseConfig(phoneOn), new Date(harness.clock.nowMs));
    for (const sid of [first, second, stray, lateRecording, orphan]) {
      expect(twilio.deleted).toContain(`/Recordings/${sid}.json`);
    }
    expect(await recordingRow(late.callId)).toMatchObject({ recording_sid: lateRecording, recording_deleted_at: harness.clock.nowMs });
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM phone_provider_purges").first()).toEqual({ n: 0 });
  });

  it("counts a connected call whose callbacks are late at its longest until it settles", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2026, 9, 26, 12);
    fakeTwilio(harness);
    const session: Session = await verifiedCaller(harness);
    const reserved: Reserved = await reserve(harness, session, destination);
    await voice(harness, reserved.callId, `CA${hex32("6f")}`);
    // Past the call's longest duration plus the callbacks' allowance, before the daily cleanup.
    harness.clock.nowMs += 2 * 3_600_000;
    const later: Session = await refreshed(harness, session);
    expect(await (await call(harness, later, "GET", "/v1/phone", null)).json()).toMatchObject({ usedMinutes: reserved.maxSeconds / 60 });
    // Its worst case still counts toward the dialer's daily ceiling: 61 × 0.025 $ plus the verification call leaves too little of 2 $.
    const tight: Env = envWith({ ...phoneOn, PHONE_DAILY_SPEND_CEILING_USD: "2" });
    await expectError(await harness.call(req("POST", "/v1/phone/calls", { token: later.accessToken, json: { to: destination }, env: tight })), 503, "phone_capacity_reached");
    // And toward the global daily ceiling (the day's other spend fills it; the dialer's own ceiling has room).
    await env.DB.prepare("UPDATE daily_spend SET micro_usd = micro_usd + ? WHERE day = ?").bind(1_000_000, today(harness)).run();
    const global: Env = envWith({ ...phoneOn, DAILY_SPEND_CEILING_USD: "4", PHONE_DAILY_SPEND_CEILING_USD: "4" });
    await expectError(await harness.call(req("POST", "/v1/phone/calls", { token: later.accessToken, json: { to: destination }, env: global })), 503, "spend_ceiling_reached");
  });
});

/** A second subscriber with its own verified number. */
async function verifiedOther(harness: Harness): Promise<Session> {
  const session: Session = await subscriber(harness);
  expect((await call(harness, session, "POST", "/v1/phone/consent", { version: 1 })).status).toBe(200);
  expect((await call(harness, session, "POST", "/v1/phone/number", { number: "+16045550123" })).status).toBe(200);
  const row = await env.DB.prepare("SELECT validation_call_sid FROM phone_numbers WHERE user_id = ?").bind(session.userId).first<{ validation_call_sid: string }>();
  await webhook(harness, "/v1/phone/webhooks/verification", { CallSid: row?.validation_call_sid ?? "", VerificationStatus: "success", OutgoingCallerIdSid: `PN${hex32("8")}` }, authToken);
  return session;
}
