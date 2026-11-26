import { env } from "cloudflare:workers";
import { type CryptoKey as JoseKey, exportPKCS8, generateKeyPair } from "jose";
import { describe, expect, it } from "vitest";
import { isFreePlanClient } from "../src/clientVersions";
import { cleanupExpiredRows } from "../src/cleanup";
import { type FreePlanVar, parseConfig } from "../src/config";
import { randomId } from "../src/crypto";
import { deviceCheckUrl } from "../src/deviceCheck";
import type { Env } from "../src/env";
import type { TrialState } from "../src/entitlements";
import { freeAllowance, freeNoteRefusal, freePlanPricing, isFreePlanAccount } from "../src/freePlan";
import { userGate } from "../src/mcp/gate";
import { allowingLimiter } from "./assistantHelpers";
import { type Harness, type Session, defaultHarness, envWith, expectError, grantSubscription, refreshed, req, signIn, signInWithGoogle } from "./helpers";

/** The `FREE_PLAN` var of the test configuration with some fields changed. */
function freePlanWith(overrides: Partial<FreePlanVar>): Pick<Env, "FREE_PLAN"> {
  return { FREE_PLAN: { ...env.FREE_PLAN, ...overrides } };
}

/**
 * The permanent free plan (src/freePlan.ts; spec docs/superpowers/specs/2026-11-23-free-plan.md). The development
 * configuration has it on, with FREE_PLAN.minBuild 1; the tests switch the policy, allowlist and build gate per request.
 */

const anthropicUrl: string = "https://api.anthropic.com/v1/messages";
const dayMs: number = 86_400_000;
/** Headers of a free-aware app (any build passes the development gate of 1). */
const freeApp: Readonly<Record<string, string>> = { "x-app-version": "0.2.18 (70)", "x-os-version": "iOS 26.1" };
/** Limiters that never block (the tests make many grant and AI calls in a minute). */
const freeEnv: Env = envWith({ START_USER_LIMITER: allowingLimiter, PROXY_USER_LIMITER: allowingLimiter, API_IP_LIMITER: allowingLimiter });

interface FreeErrorBody {
  readonly error: { readonly code: string; readonly message: string; readonly reason?: string };
}

interface FreeNoteBody {
  readonly noteId: string;
  readonly tokenBudget: number;
  readonly tokensUsed: number;
  readonly created: boolean;
  readonly freeNotesLeft: number;
  readonly freeNotesTotal: number;
  readonly freeAsksLeft: number;
  readonly freeAsksTotal: number;
  readonly freeMaxMeetingMinutes: number;
  readonly freeResetsAt: string;
}

interface MeBody {
  readonly plan: string;
  readonly accountTokensCap: number;
  readonly accountTokensPeriod: string;
  readonly freeNotesLeft?: number;
  readonly freeNotesTotal?: number;
  readonly freeAsksLeft?: number;
  readonly freeAsksTotal?: number;
  readonly freeMaxMeetingMinutes?: number;
  readonly freeResetsAt?: string;
}

/** Asserts a free plan refusal: status, the existing error code and the reason. */
async function expectFreeError(response: Response, status: number, code: string, reason: string): Promise<void> {
  const body: FreeErrorBody = await response.json<FreeErrorBody>();
  expect({ status: response.status, code: body.error.code, reason: body.error.reason }).toEqual({ status, code, reason });
}

/** Ends the account's trial: started 8 days ago (TRIAL_DAYS is 7), so it is over. */
async function endTrial(harness: Harness, userId: string): Promise<void> {
  await env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(harness.clock.nowMs - 8 * dayMs, userId).run();
}

/** A new account whose trial is over (on the free plan for a free-aware app). */
async function freeSession(harness: Harness): Promise<Session> {
  const session: Session = await signIn(harness);
  await endTrial(harness, session.userId);
  return session;
}

function me(harness: Harness, session: Session, headers: Readonly<Record<string, string>>, environment: Env): Promise<Response> {
  return harness.call(req("GET", "/v1/me", { token: session.accessToken, headers, env: environment }));
}

async function meBody(harness: Harness, session: Session, headers: Readonly<Record<string, string>>, environment: Env): Promise<MeBody> {
  const response: Response = await me(harness, session, headers, environment);
  expect(response.status).toBe(200);
  return response.json<MeBody>();
}

function requestNote(harness: Harness, session: Session, json: object, headers: Readonly<Record<string, string>>, environment: Env, clientIp: string | null): Promise<Response> {
  return harness.call(req("POST", "/v1/free/notes", { token: session.accessToken, json, headers, env: environment, clientIp }));
}

async function grantNote(harness: Harness, session: Session, clientRef: string): Promise<FreeNoteBody> {
  const response: Response = await requestNote(harness, session, { clientRef, meetingMinutes: 30 }, freeApp, freeEnv, null);
  expect(response.status).toBe(201);
  return response.json<FreeNoteBody>();
}

function llm(harness: Harness, session: Session, headers: Readonly<Record<string, string>>, json: object, environment: Env): Promise<Response> {
  return harness.call(req("POST", "/v1/llm/messages", { token: session.accessToken, headers, json, env: environment }));
}

function message(inputTokens: number, outputTokens: number): object {
  return {
    id: "msg_free",
    type: "message",
    role: "assistant",
    model: "claude-haiku-5-5",
    content: [{ type: "text", text: "Notes" }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: inputTokens, output_tokens: outputTokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
  };
}

/** Answers every Anthropic call with the given usage; returns the bodies sent upstream. */
function answerUpstream(harness: Harness, inputTokens: number, outputTokens: number): object[] {
  const sent: object[] = [];
  harness.stub(anthropicUrl, async (request: Request): Promise<Response> => {
    sent.push(await request.json<object>());
    return Response.json(message(inputTokens, outputTokens));
  });
  return sent;
}

const noteBody = { effort: "medium", max_tokens: 2000, messages: [{ role: "user", content: "Write the meeting note." }] };
const askBody = { effort: "low", max_tokens: 1000, messages: [{ role: "user", content: "What did we decide?" }] };

async function grantRow(noteId: string): Promise<{ tokens_used: number; first_settled_at: number | null; refunded_at: number | null } | null> {
  return env.DB.prepare("SELECT tokens_used, first_settled_at, refunded_at FROM free_note_grants WHERE id = ?")
    .bind(noteId)
    .first<{ tokens_used: number; first_settled_at: number | null; refunded_at: number | null }>();
}

describe("FREE_PLAN var", () => {
  it("refuses numbers written as text and user IDs with spaces", () => {
    // A hand-edited wrangler.jsonc can hold a string where a number belongs; the cast builds that bad input.
    expect(() => parseConfig(envWith(freePlanWith({ notesPerMonth: "4" as unknown as number })))).toThrow();
    expect(() => parseConfig(envWith(freePlanWith({ users: [" apple:1"] })))).toThrow();
    expect(parseConfig(envWith(freePlanWith({ users: ["apple:1"] }))).freePlan.allowedUserIds).toEqual(["apple:1"]);
  });
});

describe("free plan decisions (pure)", () => {
  const config = parseConfig(env);
  const nowMs: number = Date.UTC(2026, 9, 15, 12);
  const now: Date = new Date(nowMs);
  const over: TrialState = { used: 3, startedAt: nowMs - dayMs, deviceVerifiedAt: nowMs - dayMs };
  const expired: TrialState = { used: 1, startedAt: nowMs - 8 * dayMs, deviceVerifiedAt: nowMs - 8 * dayMs };
  const running: TrialState = { used: 1, startedAt: nowMs - dayMs, deviceVerifiedAt: nowMs - dayMs };
  const notStarted: TrialState = { used: 0, startedAt: null, deviceVerifiedAt: null };

  it("is free only after the trial, without paid access, for an app that knows it, while the plan applies", () => {
    expect(isFreePlanAccount(config, "u1", true, "none", over, now)).toBe(true);
    expect(isFreePlanAccount(config, "u1", true, "none", expired, now)).toBe(true);
    expect(isFreePlanAccount(config, "u1", true, "none", running, now)).toBe(false);
    expect(isFreePlanAccount(config, "u1", true, "none", notStarted, now)).toBe(false);
    expect(isFreePlanAccount(config, "u1", true, "active", over, now)).toBe(false);
    expect(isFreePlanAccount(config, "u1", true, "grace", over, now)).toBe(false);
    expect(isFreePlanAccount(config, "u1", false, "none", over, now)).toBe(false);
    const off = parseConfig(envWith(freePlanWith({ policy: "off", users: ["tester-1", "tester-2"] })));
    expect(isFreePlanAccount(off, "u1", true, "none", over, now)).toBe(false);
    expect(isFreePlanAccount(off, "tester-2", true, "none", over, now)).toBe(true);
  });

  it("gates on the app build (FREE_PLAN.minBuild); the site and apps without headers never see it", () => {
    expect(isFreePlanClient({ appVersion: "0.2.18 (70)", osVersion: "iOS 26.1" }, 70)).toBe(true);
    expect(isFreePlanClient({ appVersion: "0.2.17 (68)", osVersion: "macOS 15.4.1" }, 70)).toBe(false);
    expect(isFreePlanClient(null, 1)).toBe(false);
  });

  it("counts the allowance per UTC month and names the refusal", () => {
    expect(freeAllowance(config.freePlan, { notesUsed: 1, asksUsed: 7 }, now)).toEqual({
      freeNotesLeft: 3,
      freeNotesTotal: 4,
      freeAsksLeft: 0,
      freeAsksTotal: 5,
      freeMaxMeetingMinutes: 45,
      freeResetsAt: "2026-11-01T00:00:00.000Z",
    });
    expect(freeNoteRefusal(4, 4)).toBe("free_notes_used");
    expect(freeNoteRefusal(0, 4)).toBe("free_ip_limit");
  });

  it("shows the plan on the pricing page only while the policy is on", () => {
    expect(freePlanPricing(config.freePlan)).toEqual({ notesPerMonth: 4, maxMeetingMinutes: 45, asksPerMonth: 5 });
    expect(freePlanPricing(parseConfig(envWith(freePlanWith({ policy: "off", users: ["someone"] }))).freePlan)).toBeNull();
  });
});

describe("GET /v1/me and GET /v1/pricing", () => {
  it("reports plan free with the allowance to a free-aware app; older apps keep the ended trial", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const free: MeBody = await meBody(harness, session, freeApp, freeEnv);
    expect(free).toMatchObject({
      plan: "free",
      freeNotesLeft: 4,
      freeNotesTotal: 4,
      freeAsksLeft: 5,
      freeAsksTotal: 5,
      freeMaxMeetingMinutes: 45,
      freeResetsAt: "2026-11-01T00:00:00.000Z",
      accountTokensCap: 150_000,
      accountTokensPeriod: "month",
    });
    // No version headers (the site, old apps) or a build below FREE_PLAN.minBuild: nothing new.
    const old: MeBody = await meBody(harness, session, {}, freeEnv);
    expect(old.plan).toBe("trial");
    expect(old.freeNotesLeft).toBeUndefined();
    const gated: MeBody = await meBody(harness, session, { "x-app-version": "0.2.17 (68)", "x-os-version": "iOS 26.1" }, envWith(freePlanWith({ minBuild: 70 })));
    expect(gated.plan).toBe("trial");
    expect(gated.freeResetsAt).toBeUndefined();
    // Policy off: only the allowlist.
    expect((await meBody(harness, session, freeApp, envWith(freePlanWith({ policy: "off" })))).plan).toBe("trial");
    expect((await meBody(harness, session, freeApp, envWith(freePlanWith({ policy: "off", users: [session.userId] })))).plan).toBe("free");
  });

  it("keeps a running trial and a subscription on their plans, with the free allowance shown to the trial", async () => {
    const harness: Harness = await defaultHarness();
    const trial: Session = await signIn(harness);
    const trialMe: MeBody = await meBody(harness, trial, freeApp, freeEnv);
    expect(trialMe.plan).toBe("trial");
    expect(trialMe.freeNotesLeft).toBe(4);
    const paid: Session = await freeSession(harness);
    await grantSubscription(paid.userId, "active", harness.clock.nowMs + 30 * dayMs);
    expect((await meBody(harness, paid, freeApp, freeEnv)).plan).toBe("subscription");
  });

  it("adds the free plan's limits to the public pricing only while the policy is on", async () => {
    const harness: Harness = await defaultHarness();
    const on = await (await harness.call(req("GET", "/v1/pricing", {}))).json<{ free?: object }>();
    expect(on.free).toEqual({ notesPerMonth: 4, maxMeetingMinutes: 45, asksPerMonth: 5 });
    const off = await (await harness.call(req("GET", "/v1/pricing", { env: envWith(freePlanWith({ policy: "off" })) }))).json<{ free?: object }>();
    expect(off.free).toBeUndefined();
  });
});

describe("POST /v1/free/notes", () => {
  it("grants a note per recording, idempotent on clientRef, and counts the month", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const first: FreeNoteBody = await grantNote(harness, session, "rec-1");
    expect(first).toMatchObject({ tokenBudget: 90_000, tokensUsed: 0, created: true, freeNotesLeft: 3, freeNotesTotal: 4 });
    const repeated: Response = await requestNote(harness, session, { clientRef: "rec-1", meetingMinutes: 30 }, freeApp, freeEnv, null);
    expect(repeated.status).toBe(200);
    expect(await repeated.json<FreeNoteBody>()).toMatchObject({ noteId: first.noteId, created: false, freeNotesLeft: 3 });
    await grantNote(harness, session, "rec-2");
    await grantNote(harness, session, "rec-3");
    expect((await grantNote(harness, session, "rec-4")).freeNotesLeft).toBe(0);
    await expectFreeError(
      await requestNote(harness, session, { clientRef: "rec-5", meetingMinutes: 10 }, freeApp, freeEnv, null),
      403,
      "monthly_cap_reached",
      "free_notes_used",
    );
    expect((await meBody(harness, session, freeApp, freeEnv)).freeNotesLeft).toBe(0);
    // A new UTC month starts over.
    harness.clock.nowMs = Date.UTC(2026, 10, 1, 0, 0, 1);
    expect((await grantNote(harness, await refreshed(harness, session), "rec-5")).freeNotesLeft).toBe(3);
  });

  it("refuses a meeting longer than a free note covers, without counting it", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    await expectFreeError(
      await requestNote(harness, session, { clientRef: "long", meetingMinutes: 46 }, freeApp, freeEnv, null),
      402,
      "subscription_required",
      "free_meeting_too_long",
    );
    expect((await grantNote(harness, session, "short")).freeNotesLeft).toBe(3);
  });

  it("is only for accounts on the free plan, from apps that know it", async () => {
    const harness: Harness = await defaultHarness();
    const trial: Session = await signIn(harness);
    const body = { clientRef: "rec", meetingMinutes: 30 };
    await expectFreeError(await requestNote(harness, trial, body, freeApp, freeEnv, null), 402, "subscription_required", "free_plan_unavailable");
    const free: Session = await freeSession(harness);
    await expectFreeError(await requestNote(harness, free, body, {}, freeEnv, null), 402, "subscription_required", "free_plan_unavailable");
    await expectFreeError(
      await requestNote(harness, free, body, freeApp, envWith({ ...freePlanWith({ policy: "off" }), START_USER_LIMITER: allowingLimiter }), null),
      402,
      "subscription_required",
      "free_plan_unavailable",
    );
    const paid: Session = await freeSession(harness);
    await grantSubscription(paid.userId, "active", harness.clock.nowMs + 30 * dayMs);
    await expectFreeError(await requestNote(harness, paid, body, freeApp, freeEnv, null), 402, "subscription_required", "free_plan_unavailable");
    await expectError(await requestNote(harness, free, { clientRef: "bad ref", meetingMinutes: 30 }, freeApp, freeEnv, null), 400, "invalid_body");
  });

  it("lets FREE_PLAN.accountsPerIpPerDay new free accounts per IP per day; an account's later notes don't count", async () => {
    const harness: Harness = await defaultHarness();
    const ip: string = `203.0.113.${Math.floor(Math.random() * 250)}-${randomId()}`;
    const body = { clientRef: "rec", meetingMinutes: 20 };
    const sessions: Session[] = [await freeSession(harness), await freeSession(harness), await freeSession(harness), await freeSession(harness)];
    for (const session of sessions.slice(0, 3)) {
      expect((await requestNote(harness, session, body, freeApp, freeEnv, ip)).status).toBe(201);
    }
    await expectFreeError(await requestNote(harness, sessions[3] as Session, body, freeApp, freeEnv, ip), 429, "trial_ip_limit", "free_ip_limit");
    // A started free account isn't a new one: its second note from the same IP passes.
    expect((await requestNote(harness, sessions[0] as Session, { clientRef: "rec-2", meetingMinutes: 20 }, freeApp, freeEnv, ip)).status).toBe(201);
    // The next day the IP has room again.
    harness.clock.nowMs += dayMs;
    expect((await requestNote(harness, await refreshed(harness, sessions[3] as Session), body, freeApp, freeEnv, ip)).status).toBe(201);
  });

  it("pauses at the daily and monthly free spend ceilings, apart from the total", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2027, 2, 10, 12);
    const session: Session = await freeSession(harness);
    const body = { clientRef: "rec", meetingMinutes: 20 };
    await env.DB.prepare("INSERT INTO daily_spend (day, micro_usd, free_micro_usd) VALUES ('2027-03-10', 1000000, 1000000)").run();
    await expectFreeError(await requestNote(harness, session, body, freeApp, freeEnv, null), 503, "trial_capacity_reached", "free_capacity_reached");
    await env.DB.prepare("UPDATE daily_spend SET micro_usd = 0, free_micro_usd = 0 WHERE day = '2027-03-10'").run();
    await env.DB.prepare("INSERT INTO daily_spend (day, micro_usd, free_micro_usd) VALUES ('2027-03-02', 30000000, 30000000)").run();
    await expectFreeError(await requestNote(harness, session, body, freeApp, freeEnv, null), 503, "trial_capacity_reached", "free_capacity_reached");
    // Paid and trial use is not paused by free spend.
    const trial: Session = await signIn(harness);
    expect((await harness.call(req("POST", "/v1/meetings/start", { token: trial.accessToken, json: {}, env: freeEnv }))).status).toBe(201);
    await env.DB.prepare("DELETE FROM daily_spend WHERE day IN ('2027-03-02', '2027-03-10')").run();
    expect((await requestNote(harness, session, body, freeApp, freeEnv, null)).status).toBe(201);
  });
});

describe("x-free-note on /v1/llm/messages", () => {
  it("spends the grant's budget on note calls and marks it used", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const note: FreeNoteBody = await grantNote(harness, session, "rec");
    const sent: object[] = answerUpstream(harness, 1200, 300);
    const headers = { ...freeApp, "x-free-note": note.noteId, "x-llm-purpose": "note_chunk" };
    const response: Response = await llm(harness, session, headers, noteBody, freeEnv);
    expect(response.status).toBe(200);
    expect(sent).toHaveLength(1);
    expect(await grantRow(note.noteId)).toEqual({ tokens_used: 1500, first_settled_at: harness.clock.nowMs, refunded_at: null });
    const spend = await env.DB.prepare("SELECT free_micro_usd, trial_micro_usd FROM daily_spend WHERE day = '2026-10-15'").first<{ free_micro_usd: number; trial_micro_usd: number }>();
    expect(spend?.free_micro_usd).toBeGreaterThan(0);
    // "Write the note again" reuses the grant: no new note is counted.
    expect((await llm(harness, session, { ...headers, "x-llm-purpose": "note_overview" }, noteBody, freeEnv)).status).toBe(200);
    expect((await meBody(harness, session, freeApp, freeEnv)).freeNotesLeft).toBe(3);
  });

  it("refuses other purposes, other users' grants, both budgets at once, images and over-long input", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const other: Session = await freeSession(harness);
    const note: FreeNoteBody = await grantNote(harness, session, "rec");
    answerUpstream(harness, 100, 10);
    const headers = { ...freeApp, "x-free-note": note.noteId, "x-llm-purpose": "note" };
    await expectFreeError(await llm(harness, session, { ...headers, "x-llm-purpose": "live_translation" }, noteBody, freeEnv), 402, "subscription_required", "plan_required");
    await expectFreeError(await llm(harness, other, headers, noteBody, freeEnv), 404, "not_found", "free_note_invalid");
    await expectError(await llm(harness, session, { ...headers, "x-meeting-id": randomId() }, noteBody, freeEnv), 400, "bad_request");
    await expectError(await llm(harness, session, { ...headers, "x-free-note": "not-a-uuid" }, noteBody, freeEnv), 400, "bad_request");
    const image = { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "/9j/4AAQ" } };
    const withImage = { ...noteBody, messages: [{ role: "user", content: [{ type: "text", text: "Note" }, image] }] };
    await expectError(await llm(harness, session, headers, withImage, freeEnv), 400, "invalid_body");
    // FREE_PLAN.maxInputTokens: 30 000 estimated tokens (UTF-8 bytes / 3).
    const long = { ...noteBody, messages: [{ role: "user", content: "x".repeat(91_000) }] };
    await expectError(await llm(harness, session, headers, long, freeEnv), 413, "payload_too_large");
    // The kill switch: with the policy off the grant can't be used.
    await expectFreeError(await llm(harness, session, headers, noteBody, envWith(freePlanWith({ policy: "off" }))), 402, "subscription_required", "free_plan_unavailable");
  });

  it("stops at the grant's token budget", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const budgetEnv: Env = envWith({ ...freePlanWith({ noteTokenBudget: 2500 }), START_USER_LIMITER: allowingLimiter, PROXY_USER_LIMITER: allowingLimiter });
    const response: Response = await requestNote(harness, session, { clientRef: "rec", meetingMinutes: 10 }, freeApp, budgetEnv, null);
    const note: FreeNoteBody = await response.json<FreeNoteBody>();
    expect(note.tokenBudget).toBe(2500);
    answerUpstream(harness, 1800, 600);
    const headers = { ...freeApp, "x-free-note": note.noteId, "x-llm-purpose": "note" };
    expect((await llm(harness, session, headers, noteBody, budgetEnv)).status).toBe(200);
    await expectFreeError(await llm(harness, session, headers, noteBody, budgetEnv), 429, "meeting_budget_exhausted", "free_note_budget_exhausted");
  });
});

describe("free account calls", () => {
  it("answers FREE_PLAN.asksPerMonth questions; search terms don't count; web search is off", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const sent: object[] = answerUpstream(harness, 500, 100);
    const ask = { ...freeApp, "x-llm-purpose": "ask_answer" };
    expect((await llm(harness, session, { ...freeApp, "x-llm-purpose": "ask_search_terms" }, askBody, freeEnv)).status).toBe(200);
    const withSearch = { ...askBody, tools: [{ type: "web_search_20260209", name: "web_search", max_uses: 3 }] };
    const searched: Response = await llm(harness, session, ask, withSearch, freeEnv);
    expect(searched.status).toBe(200);
    expect(searched.headers.get("x-web-search")).toBe("unavailable");
    expect(sent.at(-1)).not.toHaveProperty("tools");
    for (let index = 0; index < 4; index += 1) {
      expect((await llm(harness, session, ask, askBody, freeEnv)).status).toBe(200);
    }
    expect((await meBody(harness, session, freeApp, freeEnv)).freeAsksLeft).toBe(0);
    await expectFreeError(await llm(harness, session, ask, askBody, freeEnv), 403, "monthly_cap_reached", "free_asks_used");
    // Note editing is still open (it isn't a question), within the monthly free tokens.
    expect((await llm(harness, session, { ...freeApp, "x-llm-purpose": "note_edit" }, askBody, freeEnv)).status).toBe(200);
  });

  it("refuses purposes the free plan doesn't cover, and old apps as today", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    answerUpstream(harness, 100, 10);
    for (const purpose of ["task_agent", "shared_note_translation", "connection_test", "transcript_translation"]) {
      await expectFreeError(await llm(harness, session, { ...freeApp, "x-llm-purpose": purpose }, askBody, freeEnv), 402, "subscription_required", "plan_required");
    }
    await expectError(await llm(harness, session, { "x-llm-purpose": "ask_answer" }, askBody, freeEnv), 402, "subscription_required");
  });

  it("stops at FREE_PLAN.monthlyAccountTokenCap", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const capEnv: Env = envWith({ ...freePlanWith({ monthlyAccountTokenCap: 1500 }), PROXY_USER_LIMITER: allowingLimiter });
    answerUpstream(harness, 1000, 400);
    const edit = { ...freeApp, "x-llm-purpose": "note_edit" };
    expect((await llm(harness, session, edit, askBody, capEnv)).status).toBe(200);
    await expectFreeError(await llm(harness, session, edit, askBody, capEnv), 403, "monthly_cap_reached", "free_account_cap_reached");
  });
});

describe("keyboard Ask on the free plan", () => {
  const keyboardMeeting = {
    title: "Weekly sync",
    date: "2026-10-14T09:00:00+02:00",
    summary: "We moved the launch to Friday.",
    decisions: [],
    openQuestions: [],
    myTasks: [],
    actionItems: [],
  };

  async function keyboardToken(harness: Harness, session: Session, headers: Readonly<Record<string, string>>): Promise<string> {
    const response: Response = await harness.call(req("POST", "/v1/keyboard/token", { token: session.accessToken, headers, env: freeEnv }));
    expect(response.status).toBe(200);
    return (await response.json<{ token: string }>()).token;
  }

  it("answers with a token minted by a free-aware app and counts the question; an older app's token is refused", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    answerUpstream(harness, 300, 30);
    const json = { question: "When is the launch?", meetings: [keyboardMeeting] };
    const token: string = await keyboardToken(harness, session, freeApp);
    const answered: Response = await harness.call(req("POST", "/v1/keyboard/ask", { token, json, env: freeEnv }));
    expect(answered.status).toBe(200);
    expect((await meBody(harness, session, freeApp, freeEnv)).freeAsksLeft).toBe(4);
    const oldToken: string = await keyboardToken(harness, session, {});
    await expectError(await harness.call(req("POST", "/v1/keyboard/ask", { token: oldToken, json, env: freeEnv })), 402, "subscription_required");
  });
});

describe("DeviceCheck bit1: one free plan per device", () => {
  interface DeviceCheckCall {
    readonly endpoint: string;
    readonly bit0: boolean | undefined;
    readonly bit1: boolean | undefined;
  }

  async function fakeDeviceCheck(harness: Harness): Promise<{ readonly env: Env; readonly bits: Map<string, { bit0: boolean; bit1: boolean }>; readonly calls: DeviceCheckCall[] }> {
    const { privateKey }: { privateKey: JoseKey } = await generateKeyPair("ES256", { extractable: true });
    const bits: Map<string, { bit0: boolean; bit1: boolean }> = new Map();
    const calls: DeviceCheckCall[] = [];
    harness.stub(deviceCheckUrl("development", "query_two_bits").replace("query_two_bits", ""), async (request: Request): Promise<Response> => {
      const body = await request.json<{ device_token: string; bit0?: boolean; bit1?: boolean }>();
      const endpoint: string = new URL(request.url).pathname.split("/").at(-1) ?? "";
      calls.push({ endpoint, bit0: body.bit0, bit1: body.bit1 });
      if (endpoint === "query_two_bits") {
        const stored = bits.get(body.device_token);
        return stored === undefined ? new Response("Failed to find bit state") : Response.json({ ...stored, last_update_time: "2026-10" });
      }
      bits.set(body.device_token, { bit0: body.bit0 ?? false, bit1: body.bit1 ?? false });
      return new Response("");
    });
    const environment: Env = envWith({
      DEVICECHECK_POLICY: "required",
      DEVICECHECK_KEY_ID: "KEY1234567",
      DEVICECHECK_TEAM_ID: "TEAM123456",
      DEVICECHECK_PRIVATE_KEY: await exportPKCS8(privateKey),
      START_USER_LIMITER: allowingLimiter,
    });
    return { env: environment, bits, calls };
  }

  it("binds the device at the account's first grant, keeps bit0, and refuses another account on it", async () => {
    const harness: Harness = await defaultHarness();
    const fake = await fakeDeviceCheck(harness);
    const first: Session = await freeSession(harness);
    await env.DB.prepare("UPDATE users SET trial_device_verified_at = trial_started_at WHERE id = ?").bind(first.userId).run();
    const device: string = btoa("iphone-of-ada");
    fake.bits.set(device, { bit0: true, bit1: false });
    await expectError(await requestNote(harness, first, { clientRef: "rec", meetingMinutes: 20 }, freeApp, fake.env, null), 400, "device_check_required");
    expect((await requestNote(harness, first, { clientRef: "rec", meetingMinutes: 20, deviceCheckToken: device }, freeApp, fake.env, null)).status).toBe(201);
    expect(fake.calls).toEqual([
      { endpoint: "query_two_bits", bit0: undefined, bit1: undefined },
      { endpoint: "update_two_bits", bit0: true, bit1: true },
    ]);
    // Bound: later grants don't ask Apple again.
    expect((await requestNote(harness, first, { clientRef: "rec-2", meetingMinutes: 20 }, freeApp, fake.env, null)).status).toBe(201);
    expect(fake.calls).toHaveLength(2);
    const second: Session = await freeSession(harness);
    await env.DB.prepare("UPDATE users SET trial_device_verified_at = trial_started_at WHERE id = ?").bind(second.userId).run();
    await expectFreeError(
      await requestNote(harness, second, { clientRef: "rec", meetingMinutes: 20, deviceCheckToken: device }, freeApp, fake.env, null),
      403,
      "trial_device_used",
      "free_device_used",
    );
  });
});

describe("DeviceCheck and the IP limit", () => {
  it("doesn't bind the device of a new account the IP limit refuses", async () => {
    const harness: Harness = await defaultHarness();
    const { privateKey }: { privateKey: JoseKey } = await generateKeyPair("ES256", { extractable: true });
    const updated: string[] = [];
    harness.stub(deviceCheckUrl("development", "query_two_bits").replace("query_two_bits", ""), async (request: Request): Promise<Response> => {
      const body = await request.json<{ device_token: string }>();
      if (new URL(request.url).pathname.endsWith("update_two_bits")) {
        updated.push(body.device_token);
        return new Response("");
      }
      return new Response("Failed to find bit state");
    });
    const environment: Env = envWith({
      DEVICECHECK_POLICY: "required",
      DEVICECHECK_KEY_ID: "KEY1234567",
      DEVICECHECK_TEAM_ID: "TEAM123456",
      DEVICECHECK_PRIVATE_KEY: await exportPKCS8(privateKey),
      START_USER_LIMITER: allowingLimiter,
      API_IP_LIMITER: allowingLimiter,
    });
    const ip: string = `198.51.100.7-${randomId()}`;
    for (const name of ["a", "b", "c", "d"]) {
      const session: Session = await freeSession(harness);
      const response: Response = await requestNote(harness, session, { clientRef: "rec", meetingMinutes: 20, deviceCheckToken: btoa(`device-${name}`) }, freeApp, environment, ip);
      if (name === "d") {
        await expectFreeError(response, 429, "trial_ip_limit", "free_ip_limit");
      } else {
        expect(response.status).toBe(201);
      }
    }
    expect(updated).toEqual([btoa("device-a"), btoa("device-b"), btoa("device-c")]);
  });
});

describe("identity ledger, cleanup and account deletion", () => {
  it("carries the month's free notes, questions and device binding across account deletion", async () => {
    const harness: Harness = await defaultHarness();
    const subject: string = `google-free-${randomId()}`;
    const session: Session = await signInWithGoogle(harness, subject);
    await endTrial(harness, session.userId);
    await env.DB.prepare("UPDATE users SET free_device_verified_at = ? WHERE id = ?").bind(harness.clock.nowMs, session.userId).run();
    await grantNote(harness, session, "rec-1");
    await grantNote(harness, session, "rec-2");
    answerUpstream(harness, 200, 20);
    expect((await llm(harness, session, { ...freeApp, "x-llm-purpose": "ask_answer" }, askBody, freeEnv)).status).toBe(200);
    const deleted: Response = await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env: freeEnv }));
    expect(deleted.status).toBe(200);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM free_note_grants WHERE user_id = ?").bind(session.userId).first<{ count: number }>()).toEqual({ count: 0 });
    const again: Session = await signInWithGoogle(harness, subject);
    expect(again.userId).not.toBe(session.userId);
    expect(await meBody(harness, again, freeApp, freeEnv)).toMatchObject({ plan: "free", freeNotesLeft: 2, freeAsksLeft: 4 });
    const user = await env.DB.prepare("SELECT free_device_verified_at FROM users WHERE id = ?").bind(again.userId).first<{ free_device_verified_at: number | null }>();
    expect(user?.free_device_verified_at).toBe(harness.clock.nowMs);
    // Another month starts over.
    harness.clock.nowMs = Date.UTC(2026, 10, 2, 12);
    const fresh: Session = await signInWithGoogle(harness, subject);
    expect((await meBody(harness, fresh, freeApp, freeEnv)).freeNotesLeft).toBe(4);
  });

  it("refunds a grant no call settled on within 24 hours, and removes grants after 400 days", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const unused: FreeNoteBody = await grantNote(harness, session, "unused");
    const used: FreeNoteBody = await grantNote(harness, session, "used");
    answerUpstream(harness, 100, 10);
    expect((await llm(harness, session, { ...freeApp, "x-free-note": used.noteId, "x-llm-purpose": "note" }, noteBody, freeEnv)).status).toBe(200);
    await env.DB.prepare("INSERT INTO free_note_grants (id, user_id, month, client_ref, token_budget, created_at, ip_hash) VALUES (?, ?, '2025-09', 'old', 90000, ?, 'ip')")
      .bind(randomId(), session.userId, harness.clock.nowMs - 401 * dayMs)
      .run();
    const now: Date = new Date(harness.clock.nowMs + dayMs + 1);
    const report = await cleanupExpiredRows(env.DB, now, { batchSize: 100, maxBatchesPerTable: 2 });
    expect(report["free_note_refunds"]).toBeGreaterThanOrEqual(1);
    expect(report["free_note_grants"]).toBeGreaterThanOrEqual(1);
    expect((await grantRow(unused.noteId))?.refunded_at).toBe(now.getTime());
    expect((await grantRow(used.noteId))?.refunded_at).toBeNull();
    harness.clock.nowMs = now.getTime();
    const later: Session = await refreshed(harness, session);
    // The refunded note no longer counts and can't be used; the same recording may ask again.
    expect((await meBody(harness, later, freeApp, freeEnv)).freeNotesLeft).toBe(3);
    await expectFreeError(
      await llm(harness, later, { ...freeApp, "x-free-note": unused.noteId, "x-llm-purpose": "note" }, noteBody, freeEnv),
      404,
      "not_found",
      "free_note_invalid",
    );
    const again: FreeNoteBody = await grantNote(harness, later, "unused");
    expect(again.noteId).not.toBe(unused.noteId);
  });
});

describe("what the free plan never gets", () => {
  it("no meeting session, transcription, Deepgram, sync, shares or AI assistant (MCP included)", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    expect((await meBody(harness, session, freeApp, freeEnv)).plan).toBe("free");
    const token: string = session.accessToken;
    await expectError(await harness.call(req("POST", "/v1/meetings/start", { token, json: {}, headers: freeApp, env: freeEnv })), 402, "trial_exhausted");
    const meetingHeaders = { ...freeApp, "x-meeting-id": randomId() };
    await expectError(
      await harness.call(req("POST", "/v1/transcribe", { token, headers: { ...meetingHeaders, "content-type": "audio/flac" }, body: new Uint8Array(16), env: freeEnv })),
      403,
      "meeting_not_active",
    );
    await expectError(await harness.call(req("POST", "/v1/live/deepgram-token", { token, headers: meetingHeaders, env: freeEnv })), 403, "meeting_not_active");
    const syncEnv: Env = envWith({ SYNC_USER_LIMITER: allowingLimiter });
    await expectError(
      await harness.call(req("POST", "/v1/sync/account", { token, headers: freeApp, json: { keyId: "0".repeat(32) }, env: syncEnv })),
      402,
      "subscription_required",
    );
    const share = new Uint8Array(64);
    share.set(new TextEncoder().encode("GSS1"), 0);
    await expectError(
      await harness.call(
        req("POST", "/v1/shares", {
          token,
          headers: { ...freeApp, "content-type": "application/octet-stream", "x-share-id": "AAAAAAAAAAAAAAAAAAAAAA", "x-share-expires-days": "30" },
          body: share,
          env: envWith({ START_USER_LIMITER: allowingLimiter }),
        }),
      ),
      402,
      "subscription_required",
    );
    await expectError(
      await harness.call(req("PUT", "/v1/assistant/settings", { token, headers: freeApp, json: { enabled: true }, env: envWith({ ASSISTANT_USER_LIMITER: allowingLimiter }) })),
      402,
      "subscription_required",
    );
    // The MCP connector's gate: assistant data turned on earlier (e.g. as a subscriber) is closed for a free account.
    await env.ASSISTANT_DB.prepare("INSERT INTO assistant_settings (user_id, enabled, epoch, updated_at, access_checked_at) VALUES (?, 1, 1, ?, ?)")
      .bind(session.userId, harness.clock.nowMs, harness.clock.nowMs)
      .run();
    expect(await userGate(env.DB, env.ASSISTANT_DB, parseConfig(env), session.userId, new Date(harness.clock.nowMs))).toEqual({ kind: "no_access" });
  });
});

describe("free plan telemetry", () => {
  it("accepts the free plan's counters and conversion triggers ahead of the apps", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await freeSession(harness);
    const events = [
      { kind: "free_note_written", count: 1 },
      { kind: "free_unavailable_language", count: 2 },
      { kind: "upsell_shown", trigger: "free_notes_used", count: 1 },
      { kind: "paywall_shown", surface: "sheet", trigger: "free_needs_sync", tiersOffered: "personal", count: 1 },
    ];
    const response: Response = await harness.call(
      req("POST", "/v1/telemetry", { token: session.accessToken, headers: freeApp, json: { events }, env: envWith({ TELEMETRY_USER_LIMITER: allowingLimiter }) }),
    );
    expect(response.status).toBeLessThan(300);
    const counts = await env.DB.prepare("SELECT kind, SUM(count) AS count FROM client_event_counts WHERE kind LIKE 'free_%' GROUP BY kind ORDER BY kind").all<{ kind: string; count: number }>();
    expect(counts.results).toEqual([
      { kind: "free_note_written", count: 1 },
      { kind: "free_unavailable_language", count: 2 },
    ]);
  });
});

describe("admin view of the free plan", () => {
  interface FreeConversion {
    readonly freeUsers: number;
    readonly freeActive30d: number;
    readonly freeToPaid: number;
    readonly freeToPaid30d: number;
  }

  it("counts free accounts, the active ones and those that paid", async () => {
    const harness: Harness = await defaultHarness();
    const adminSubject: string = `free-admin-${randomId()}`;
    const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const stats = async (): Promise<FreeConversion> => {
      const response: Response = await harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken, env: adminEnv }));
      expect(response.status).toBe(200);
      return (await response.json<{ conversion: FreeConversion }>()).conversion;
    };
    const before: FreeConversion = await stats();
    const stays: Session = await freeSession(harness);
    const pays: Session = await freeSession(harness);
    await grantNote(harness, stays, "rec");
    await grantNote(harness, pays, "rec");
    await grantSubscription(pays.userId, "active", harness.clock.nowMs + 30 * dayMs);
    const after: FreeConversion = await stats();
    expect({
      freeUsers: after.freeUsers - before.freeUsers,
      freeActive30d: after.freeActive30d - before.freeActive30d,
      freeToPaid: after.freeToPaid - before.freeToPaid,
      freeToPaid30d: after.freeToPaid30d - before.freeToPaid30d,
    }).toEqual({ freeUsers: 2, freeActive30d: 2, freeToPaid: 1, freeToPaid30d: 1 });
  });
});
