import { createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ConfigError, type EmailConfig, parseConfig } from "../src/config";
import { normalizedEmailAddress } from "../src/email/address";
import { emailLocaleOf, emailLocales } from "../src/email/copy";
import { type AccountEmailFacts, dueLifecycleEmail, lifecycleEmailCron, lifecycleFinished } from "../src/email/lifecycle";
import {
  type ComposedEmail,
  type EmailFacts,
  activationEmail,
  confirmationEmail,
  freePlanEmail,
  trialEndingEmail,
  welcomeEmail,
} from "../src/email/messages";
import { emailCapRefusal, takeEmailUnit } from "../src/email/quota";
import { emailConsentVersion } from "../src/email/subscriptions";
import type { Env } from "../src/env";
import worker from "../src/index";
import { type Harness, type Session, defaultHarness, expectError, req, signIn } from "./helpers";

/** A stand-in for the `send_email` binding: records every message; `failures` makes the next sends throw those codes. */
interface FakeSender {
  readonly binding: SendEmail;
  readonly sent: EmailMessageBuilder[];
  readonly failures: string[];
}

function fakeSender(): FakeSender {
  const sent: EmailMessageBuilder[] = [];
  const failures: string[] = [];
  const binding: SendEmail = {
    send: async (message: EmailMessage | EmailMessageBuilder): Promise<EmailSendResult> => {
      if (!("subject" in message)) {
        throw new Error("Only composed messages are sent");
      }
      const code: string | undefined = failures.shift();
      if (code !== undefined) {
        throw Object.assign(new Error(`Email Service: ${code}`), { code });
      }
      sent.push(message);
      return { messageId: `message-${sent.length}` };
    },
  };
  return { binding, sent, failures };
}

function emailEnv(sender: FakeSender, overrides: Partial<Env["EMAIL_SENDING"]>): Env {
  return { ...env, EMAIL: sender.binding, EMAIL_SENDING: { ...env.EMAIL_SENDING, ...overrides } };
}

function uniqueAddress(): string {
  return `Someone.${crypto.randomUUID().slice(0, 8)}@Example.com`;
}

function headersOf(message: EmailMessageBuilder): Readonly<Record<string, string>> {
  return message.headers ?? {};
}

/** The token in a confirmation email's confirm link. */
function confirmTokenOf(message: EmailMessageBuilder): string {
  const match: RegExpExecArray | null = /\/email\/confirm#([A-Za-z0-9_-]{43})/.exec(message.text ?? "");
  if (match === null || match[1] === undefined) {
    throw new Error("No confirm link in the email");
  }
  return match[1];
}

interface StateBody {
  readonly available: boolean;
  readonly status: string;
  readonly address: string | null;
  readonly pendingAddress: string | null;
  readonly locale: string | null;
}

async function optIn(harness: Harness, session: Session, testEnv: Env, address: string, locale: string): Promise<Response> {
  return harness.call(req("PUT", "/v1/me/email", { token: session.accessToken, env: testEnv, json: { address, locale, consentVersion: emailConsentVersion } }));
}

async function stateOf(harness: Harness, session: Session, testEnv: Env): Promise<StateBody> {
  return (await harness.call(req("GET", "/v1/me/email", { token: session.accessToken, env: testEnv }))).json<StateBody>();
}

async function runHourly(nowMs: number, testEnv: Env): Promise<void> {
  await worker.scheduled(createScheduledController({ scheduledTime: nowMs, cron: lifecycleEmailCron }), testEnv);
}

const facts: EmailFacts = {
  siteOrigin: "https://gistsmith.com",
  privacyContact: "privacy@gistsmith.com",
  trial: { meetings: 3, days: 7 },
  free: { notesPerMonth: 4, maxMeetingMinutes: 45, asksPerMonth: 5 },
};
const links = { oneClickUrl: "https://api.gistsmith.com/v1/email/unsubscribe?s=x", pageUrl: "https://gistsmith.com/email/unsubscribe#x" };

afterEach(() => {
  vi.restoreAllMocks();
});

describe("email helpers", () => {
  it("maps app language tags to email languages, English otherwise", () => {
    expect(emailLocaleOf("tr")).toBe("tr");
    expect(emailLocaleOf("pt-BR")).toBe("pt-BR");
    expect(emailLocaleOf("pt-PT")).toBe("pt-BR");
    expect(emailLocaleOf("zh-Hans")).toBe("zh-Hans");
    expect(emailLocaleOf("zh_CN")).toBe("zh-Hans");
    expect(emailLocaleOf("en-GB")).toBe("en");
    expect(emailLocaleOf("sv")).toBe("en");
    expect(emailLocaleOf("")).toBe("en");
  });

  it("accepts plain addresses and lower-cases the domain only", () => {
    expect(normalizedEmailAddress("  Jane.Doe+tips@Example.COM ")).toBe("Jane.Doe+tips@example.com");
    expect(normalizedEmailAddress("a@b.co")).toBe("a@b.co");
    expect(normalizedEmailAddress("a@xn--bcher-kva.example")).toBe("a@xn--bcher-kva.example");
    for (const bad of ["", "plain", "a@b", "a@@b.com", "a b@c.com", "a@b.c", ".a@b.com", "a..b@c.com", "a@-b.com", "<a@b.com>", "ä@b.com", `${"a".repeat(65)}@b.com`]) {
      expect(normalizedEmailAddress(bad)).toBeNull();
    }
  });

  it("refuses a monthly cap above the plan's 3,000 emails and confirmation shares above the totals", () => {
    expect(() => parseConfig({ ...env, EMAIL_SENDING: { ...env.EMAIL_SENDING, monthlyCap: 3001 } })).toThrow(ConfigError);
    expect(() => parseConfig({ ...env, EMAIL_SENDING: { ...env.EMAIL_SENDING, confirmDailyCap: 151 } })).toThrow(ConfigError);
    expect(() => parseConfig({ ...env, EMAIL_SENDING: { ...env.EMAIL_SENDING, dailyCap: 2501 } })).toThrow(ConfigError);
  });
});

describe("email templates", () => {
  const all = (locale: (typeof emailLocales)[number]): ComposedEmail[] => [
    confirmationEmail(locale, facts, "T".repeat(43)),
    welcomeEmail(locale, facts, links),
    activationEmail(locale, facts, links),
    trialEndingEmail(locale, facts, links, { reason: "one_meeting_left", next: "free" }),
    trialEndingEmail(locale, facts, links, { reason: "ends_within_day", next: "subscribe" }),
    freePlanEmail(locale, facts, links),
  ];

  it("renders every email in every language: subject, both parts, links, footer, small enough for Gmail", () => {
    for (const locale of emailLocales) {
      for (const email of all(locale)) {
        expect(email.subject.length).toBeGreaterThan(5);
        expect(email.html.length).toBeLessThan(60_000);
        expect(email.html).toContain(`lang="${locale}"`);
        expect(email.html).toContain('name="color-scheme" content="light dark"');
        expect(email.html).toContain('alt="Gistsmith logo"');
        expect(email.html).toContain("Gistsmith · Oulu, ");
        expect(email.html).toContain('href="https://gistsmith.com/privacy"');
        expect(email.html).not.toMatch(/Aslan|Sarvivälkkeentie|3346878/);
        expect(email.text).toContain("privacy@gistsmith.com");
        expect(email.html).not.toMatch(/\$\{|undefined|NaN/);
        expect(email.text).not.toMatch(/\$\{|undefined|NaN/);
      }
    }
  });

  it("puts the configured numbers in, and one-click headers only on lifecycle emails", () => {
    const freePlan: ComposedEmail = freePlanEmail("en", facts, links);
    expect(freePlan.text).toContain("4 AI notes a month, for meetings up to 45 minutes");
    expect(freePlan.headers).toEqual({
      "List-Id": "Gistsmith tips <tips.gistsmith.com>",
      Precedence: "bulk",
      "List-Unsubscribe": `<${links.oneClickUrl}>`,
      "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
    });
    expect(freePlan.html).toContain(links.pageUrl);
    expect(activationEmail("tr", facts, links).text).toContain("(3 toplantı ya da 7 gün)");
    expect(activationEmail("tr", facts, links).text).toContain("Gistsmith · Oulu, Finlandiya");
    expect(freePlanEmail("fi", facts, links).text).toContain("Gistsmith · Oulu, Suomi");
    const confirm: ComposedEmail = confirmationEmail("en", facts, "T".repeat(43));
    expect(confirm.headers).toEqual({ "Auto-Submitted": "auto-generated" });
    expect(confirm.text).toContain(`https://gistsmith.com/email/not-me#${"T".repeat(43)}`);
    // An http one-click target (local development) is not a valid List-Unsubscribe.
    expect(welcomeEmail("en", facts, { ...links, oneClickUrl: "http://localhost:8787/v1/email/unsubscribe?s=x" }).headers).toEqual({
      "List-Id": "Gistsmith tips <tips.gistsmith.com>",
      Precedence: "bulk",
    });
  });
});

describe("dueLifecycleEmail", () => {
  const hour: number = 3_600_000;
  const now: number = Date.UTC(2026, 10, 20, 12);
  const base: AccountEmailFacts = {
    sent: new Map([["welcome", now - 100 * hour]]),
    confirmedAtMs: now - 100 * hour,
    paid: false,
    trialStartedAtMs: null,
    trialMeetingsLeft: 3,
    hasMeeting: false,
    freePlanAccount: false,
    freePlanNext: true,
  };
  const trialMs: number = 7 * 24 * hour;

  it("sends the welcome first, even to a paying account, then nothing more to it", () => {
    expect(dueLifecycleEmail({ ...base, sent: new Map(), paid: true }, now, trialMs)).toEqual({ kind: "welcome" });
    expect(dueLifecycleEmail({ ...base, paid: true }, now, trialMs)).toBeNull();
    expect(lifecycleFinished({ ...base, paid: true })).toBe(true);
    expect(lifecycleFinished({ ...base, sent: new Map([["welcome", null]]), paid: true })).toBe(false);
  });

  it("reminds an account without meetings once, 48 hours to 7 days after confirming", () => {
    expect(dueLifecycleEmail({ ...base, confirmedAtMs: now - 47 * hour }, now, trialMs)).toBeNull();
    expect(dueLifecycleEmail(base, now, trialMs)).toEqual({ kind: "activation" });
    expect(dueLifecycleEmail({ ...base, confirmedAtMs: now - 8 * 24 * hour }, now, trialMs)).toBeNull();
    expect(dueLifecycleEmail({ ...base, hasMeeting: true }, now, trialMs)).toBeNull();
    expect(dueLifecycleEmail({ ...base, sent: new Map([["welcome", 1], ["activation", 2]]) }, now, trialMs)).toBeNull();
  });

  it("warns before the trial ends, by meetings or by time, with what follows", () => {
    const running: AccountEmailFacts = { ...base, hasMeeting: true, trialStartedAtMs: now - 24 * hour, trialMeetingsLeft: 2 };
    expect(dueLifecycleEmail(running, now, trialMs)).toBeNull();
    expect(dueLifecycleEmail({ ...running, trialMeetingsLeft: 1 }, now, trialMs)).toEqual({
      kind: "trial_ending",
      variant: { reason: "one_meeting_left", next: "free" },
    });
    expect(dueLifecycleEmail({ ...running, trialStartedAtMs: now - 6.5 * 24 * hour, freePlanNext: false }, now, trialMs)).toEqual({
      kind: "trial_ending",
      variant: { reason: "ends_within_day", next: "subscribe" },
    });
    // The moment passed: no late warning once the trial is over.
    expect(dueLifecycleEmail({ ...running, trialMeetingsLeft: 0 }, now, trialMs)).toBeNull();
  });

  it("sends the free plan email once, not within a day of the trial warning", () => {
    const free: AccountEmailFacts = { ...base, hasMeeting: true, trialStartedAtMs: now - 8 * 24 * hour, trialMeetingsLeft: 0, freePlanAccount: true };
    expect(dueLifecycleEmail(free, now, trialMs)).toEqual({ kind: "free_plan" });
    expect(dueLifecycleEmail({ ...free, sent: new Map([["welcome", 1], ["trial_ending", now - 2 * hour]]) }, now, trialMs)).toBeNull();
    expect(dueLifecycleEmail({ ...free, sent: new Map([["welcome", 1], ["trial_ending", now - 25 * hour]]) }, now, trialMs)).toEqual({ kind: "free_plan" });
    const done: AccountEmailFacts = { ...free, sent: new Map([["welcome", 1], ["free_plan", 2]]) };
    expect(dueLifecycleEmail(done, now, trialMs)).toBeNull();
    expect(lifecycleFinished(done)).toBe(true);
  });
});

describe("sending cap", () => {
  const config: EmailConfig = parseConfig({
    ...env,
    EMAIL_SENDING: { ...env.EMAIL_SENDING, monthlyCap: 5, dailyCap: 3, confirmMonthlyCap: 2, confirmDailyCap: 2, perRunCap: 3 },
  }).email;

  it("decides the refusing cap from the stored counts", () => {
    const row = { sent: 2, confirm_sent: 2, day: "2026-11-26", day_sent: 2, day_confirm_sent: 2 };
    expect(emailCapRefusal(config, row, "lifecycle", "2026-11-26")).toBeNull();
    expect(emailCapRefusal(config, row, "confirm", "2026-11-26")).toBe("month");
    expect(emailCapRefusal(config, { ...row, confirm_sent: 1, day_confirm_sent: 2 }, "confirm", "2026-11-26")).toBe("day");
    expect(emailCapRefusal(config, { ...row, sent: 5 }, "lifecycle", "2026-11-27")).toBe("month");
    expect(emailCapRefusal(config, { ...row, day_sent: 3 }, "lifecycle", "2026-11-27")).toBeNull();
  });

  it("takes units up to the daily and monthly caps, alerts once each, and resumes the next day", async () => {
    const alerts = vi.spyOn(console, "error");
    const day1: Date = new Date(Date.UTC(2031, 0, 1, 9));
    const results: (string | null)[] = [];
    for (let index: number = 0; index < 5; index += 1) {
      results.push(await takeEmailUnit(env.DB, config, "lifecycle", day1));
    }
    expect(results).toEqual([null, null, null, "day", "day"]);
    const day2: Date = new Date(Date.UTC(2031, 0, 2, 9));
    expect(await takeEmailUnit(env.DB, config, "confirm", day2)).toBeNull();
    expect(await takeEmailUnit(env.DB, config, "confirm", day2)).toBeNull();
    // The month has 5: three yesterday, two today.
    expect(await takeEmailUnit(env.DB, config, "lifecycle", day2)).toBe("month");
    expect(await takeEmailUnit(env.DB, config, "lifecycle", new Date(Date.UTC(2031, 0, 3, 9)))).toBe("month");
    expect(await takeEmailUnit(env.DB, config, "lifecycle", new Date(Date.UTC(2031, 1, 1, 9)))).toBeNull();
    const capAlerts: string[] = alerts.mock.calls.map((call: unknown[]): string => String(call[0])).filter((line: string): boolean => line.includes('"event":"email_cap_reached"'));
    expect(capAlerts.length).toBe(2);
    expect(capAlerts[0]).toContain('"cap":"day"');
    expect(capAlerts[1]).toContain('"cap":"month"');
  });

  it("keeps confirmations to their share so they can't use up the lifecycle emails", async () => {
    const day: Date = new Date(Date.UTC(2032, 0, 1, 9));
    expect(await takeEmailUnit(env.DB, config, "confirm", day)).toBeNull();
    expect(await takeEmailUnit(env.DB, config, "confirm", day)).toBeNull();
    expect(await takeEmailUnit(env.DB, config, "confirm", day)).toBe("month");
    expect(await takeEmailUnit(env.DB, config, "lifecycle", day)).toBeNull();
  });

  it("tells the app to try later when the cap refuses a confirmation, and keeps nothing", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2033, 4, 1, 9);
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, { dailyCap: 1, confirmDailyCap: 1, perRunCap: 1 });
    const first: Session = await signIn(harness);
    expect((await optIn(harness, first, testEnv, uniqueAddress(), "en")).status).toBe(200);
    const second: Session = await signIn(harness);
    await expectError(await optIn(harness, second, testEnv, uniqueAddress(), "en"), 503, "email_quota_reached");
    expect(sender.sent.length).toBe(1);
    expect((await stateOf(harness, second, testEnv)).status).toBe("off");
  });
});

describe("opt-in, confirmation and unsubscribe", () => {
  it("stores nothing until asked, confirms with one click, sends the welcome with one-click unsubscribe", async () => {
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, { apiOrigin: "https://api.gistsmith.com" });
    const session: Session = await signIn(harness);
    expect(await stateOf(harness, session, testEnv)).toEqual({
      available: true,
      status: "off",
      address: null,
      pendingAddress: null,
      locale: null,
      consentVersion: emailConsentVersion,
    });
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM email_subscriptions WHERE user_id = ?").bind(session.userId).first<{ n: number }>()).toEqual({ n: 0 });

    const address: string = uniqueAddress();
    const opted: Response = await optIn(harness, session, testEnv, address, "de-DE");
    expect(opted.status).toBe(200);
    const normalized: string = normalizedEmailAddress(address) ?? "";
    expect(await opted.json()).toMatchObject({ status: "pending", address: null, pendingAddress: normalized, locale: "de" });
    expect(sender.sent.length).toBe(1);
    const confirmation: EmailMessageBuilder = sender.sent[0] as EmailMessageBuilder;
    expect(confirmation.to).toBe(normalized);
    expect(confirmation.from).toEqual({ name: "Gistsmith", email: "hello@gistsmith.com" });
    expect(confirmation.replyTo).toBe("support@gistsmith.com");
    expect(confirmation.subject).toBe("Bestätige deine E-Mail-Adresse für Gistsmith");
    expect(headersOf(confirmation)).toEqual({ "Auto-Submitted": "auto-generated" });

    // A link scanner's GET changes nothing; an unknown token is refused like an expired one.
    expect((await harness.call(req("GET", "/v1/email/confirm", { env: testEnv }))).status).toBe(404);
    await expectError(await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token: "x".repeat(43) } })), 404, "not_found");

    const token: string = confirmTokenOf(confirmation);
    const confirmed: Response = await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token }, headers: { origin: "http://localhost:8788" } }));
    expect(confirmed.status).toBe(200);
    expect(confirmed.headers.get("access-control-allow-origin")).toBe("http://localhost:8788");
    await harness.drain();
    expect(sender.sent.length).toBe(2);
    const welcome: EmailMessageBuilder = sender.sent[1] as EmailMessageBuilder;
    expect(welcome.subject).toBe("Dein erstes Meeting mit Gistsmith");
    const welcomeHeaders: Readonly<Record<string, string>> = headersOf(welcome);
    expect(welcomeHeaders["List-Unsubscribe-Post"]).toBe("List-Unsubscribe=One-Click");
    // The token is used up.
    await expectError(await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token } })), 404, "not_found");
    expect(await stateOf(harness, session, testEnv)).toMatchObject({ status: "confirmed", address: normalized, pendingAddress: null });

    // RFC 8058 one-click: the provider POSTs to the header's URL with a form body and no Origin.
    const oneClick: string = /^<(.+)>$/.exec(welcomeHeaders["List-Unsubscribe"] ?? "")?.[1] ?? "";
    const path: string = new URL(oneClick).pathname + new URL(oneClick).search;
    await expectError(await harness.call(req("POST", path.replace(/s=([^.]+)\.(.)/, "s=$1.A$2").slice(0, -1), { env: testEnv })), 404, "not_found");
    const unsubscribed: Response = await harness.call(
      req("POST", path, { env: testEnv, body: "List-Unsubscribe=One-Click", headers: { "content-type": "application/x-www-form-urlencoded" } }),
    );
    expect(unsubscribed.status).toBe(200);
    expect(await stateOf(harness, session, testEnv)).toMatchObject({ status: "off", address: null });
    expect((await harness.call(req("POST", path, { env: testEnv }))).status).toBe(200);
    // A mail client without one-click opens the header's URL with GET: it lands on the site's page, nothing changes.
    const opened: Response = await harness.call(req("GET", path, { env: testEnv }));
    expect(opened.status).toBe(303);
    expect(opened.headers.get("location")).toBe(`http://localhost:8788/email/unsubscribe#${new URL(oneClick).searchParams.get("s")}`);
    expect((await harness.call(req("GET", "/v1/email/unsubscribe?s=<script>", { env: testEnv }))).headers.get("location")).toBe("http://localhost:8788/email/unsubscribe");
    expect(await env.DB.prepare("SELECT kind FROM email_sends WHERE user_id = ?").bind(session.userId).all()).toMatchObject({ results: [{ kind: "welcome" }] });
  });

  it("keeps a confirmed address until a new one is confirmed, and the same address again sends nothing", async () => {
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, {});
    const session: Session = await signIn(harness);
    const first: string = normalizedEmailAddress(uniqueAddress()) ?? "";
    await optIn(harness, session, testEnv, first, "en");
    await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token: confirmTokenOf(sender.sent[0] as EmailMessageBuilder) } }));
    await harness.drain();
    const second: string = normalizedEmailAddress(uniqueAddress()) ?? "";
    expect(await (await optIn(harness, session, testEnv, second, "fr")).json()).toMatchObject({ status: "confirmed", address: first, pendingAddress: second });
    expect(await (await optIn(harness, session, testEnv, first.toUpperCase(), "fr")).json()).toMatchObject({
      status: "confirmed",
      address: first,
      pendingAddress: null,
      locale: "fr",
    });
    expect(sender.sent.length).toBe(3);
  });

  it("limits confirmation emails per recipient across accounts, and 'This wasn't me' blocks the recipient", async () => {
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, {});
    const victim: string = uniqueAddress();
    const first: Session = await signIn(harness);
    expect((await optIn(harness, first, testEnv, victim, "en")).status).toBe(200);
    await expectError(await optIn(harness, first, testEnv, victim, "en"), 429, "rate_limited");
    const second: Session = await signIn(harness);
    await expectError(await optIn(harness, second, testEnv, victim, "en"), 429, "rate_limited");

    const token: string = confirmTokenOf(sender.sent[0] as EmailMessageBuilder);
    expect((await harness.call(req("POST", "/v1/email/not-me", { env: testEnv, json: { token } }))).status).toBe(200);
    expect((await stateOf(harness, first, testEnv)).status).toBe("off");
    await expectError(await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token } })), 404, "not_found");
    // Blocked before any limit: no account can send it a confirmation again.
    await expectError(await optIn(harness, second, testEnv, victim.toLowerCase(), "en"), 403, "email_blocked");
    // The block is kept by address HMAC only.
    const stored = await env.DB.prepare("SELECT key_hash FROM email_recipient_limits WHERE blocked_at IS NOT NULL").all<{ key_hash: string }>();
    expect(stored.results.every((row: { key_hash: string }): boolean => /^[0-9a-f]{64}$/.test(row.key_hash))).toBe(true);
    expect(sender.sent.length).toBe(1);
  });

  it("keeps an earlier pending link when a new confirmation email can't go out", async () => {
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, {});
    const session: Session = await signIn(harness);
    const first: string = normalizedEmailAddress(uniqueAddress()) ?? "";
    await optIn(harness, session, testEnv, first, "en");
    sender.failures.push("E_RECIPIENT_SUPPRESSED");
    await expectError(await optIn(harness, session, testEnv, uniqueAddress(), "en"), 422, "email_undeliverable");
    expect(await stateOf(harness, session, testEnv)).toMatchObject({ status: "pending", pendingAddress: first });
    const confirmed: Response = await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token: confirmTokenOf(sender.sent[0] as EmailMessageBuilder) } }));
    expect(confirmed.status).toBe(200);
    await harness.drain();
  });

  it("drops the address the provider can't deliver to and says so", async () => {
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, {});
    const session: Session = await signIn(harness);
    sender.failures.push("E_RECIPIENT_SUPPRESSED");
    await expectError(await optIn(harness, session, testEnv, uniqueAddress(), "en"), 422, "email_undeliverable");
    expect((await stateOf(harness, session, testEnv)).status).toBe("off");
    sender.failures.push("E_RATE_LIMIT_EXCEEDED", "E_RATE_LIMIT_EXCEEDED", "E_RATE_LIMIT_EXCEEDED");
    await expectError(await optIn(harness, session, testEnv, uniqueAddress(), "en"), 502, "upstream_unavailable");
    expect((await stateOf(harness, session, testEnv)).status).toBe("off");
  });

  it("is off for accounts outside the allowlist while the switch is off; switching off and retention still work", async () => {
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const onEnv: Env = emailEnv(sender, {});
    const session: Session = await signIn(harness);
    await optIn(harness, session, onEnv, uniqueAddress(), "en");
    const offEnv: Env = emailEnv(sender, { policy: "off", users: [] });
    expect((await stateOf(harness, session, offEnv)).available).toBe(false);
    const other: Session = await signIn(harness);
    await expectError(await optIn(harness, other, offEnv, uniqueAddress(), "en"), 403, "email_unavailable");
    const allowEnv: Env = emailEnv(sender, { policy: "off", users: [other.userId] });
    expect((await stateOf(harness, other, allowEnv)).available).toBe(true);

    // The pending address is deleted 7 days later by the hourly run, even with the switch off.
    await runHourly(harness.clock.nowMs + 7 * 86_400_000 + 1, offEnv);
    expect((await stateOf(harness, session, offEnv)).status).toBe("off");
    const deleted: Response = await harness.call(req("DELETE", "/v1/me/email", { token: other.accessToken, env: offEnv }));
    expect(await deleted.json()).toMatchObject({ status: "off", available: false });
  });

  it("deletes the address and the email history with the account", async () => {
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, {});
    const session: Session = await signIn(harness);
    await optIn(harness, session, testEnv, uniqueAddress(), "en");
    await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token: confirmTokenOf(sender.sent[0] as EmailMessageBuilder) } }));
    await harness.drain();
    expect((await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env: testEnv }))).status).toBe(200);
    const left = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM email_subscriptions WHERE user_id = ?1) + (SELECT COUNT(*) FROM email_sends WHERE user_id = ?1) AS n",
    )
      .bind(session.userId)
      .first<{ n: number }>();
    expect(left).toEqual({ n: 0 });
  });

  it("never logs an address or a token", async () => {
    const lines: string[] = [];
    for (const method of ["log", "warn", "error"] as const) {
      vi.spyOn(console, method).mockImplementation((line: unknown): void => {
        lines.push(String(line));
      });
    }
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, {});
    const session: Session = await signIn(harness);
    const address: string = uniqueAddress();
    await optIn(harness, session, testEnv, address, "en");
    const token: string = confirmTokenOf(sender.sent[0] as EmailMessageBuilder);
    await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token } }));
    await harness.drain();
    const local: string = address.split("@")[0] ?? "";
    expect(lines.length).toBeGreaterThan(0);
    expect(lines.some((line: string): boolean => line.toLowerCase().includes(local.toLowerCase()) || line.includes(token))).toBe(false);
  });
});

describe("hourly lifecycle run", () => {
  // Each test starts without the other tests' subscriptions (one D1 per test file).
  beforeEach(async () => {
    await env.DB.prepare("DELETE FROM email_subscriptions").run();
  });

  async function confirmedAccount(harness: Harness, testEnv: Env, sender: FakeSender): Promise<Session> {
    const session: Session = await signIn(harness);
    await optIn(harness, session, testEnv, uniqueAddress(), "en");
    const token: string = confirmTokenOf(sender.sent[sender.sent.length - 1] as EmailMessageBuilder);
    await harness.call(req("POST", "/v1/email/confirm", { env: testEnv, json: { token } }));
    await harness.drain();
    return session;
  }

  it("sends the activation reminder after 48 hours, the trial warning, and the free plan email, each once", async () => {
    const harness: Harness = await defaultHarness();
    const sender: FakeSender = fakeSender();
    const testEnv: Env = emailEnv(sender, {});
    const idle: Session = await confirmedAccount(harness, testEnv, sender);
    const trial: Session = await confirmedAccount(harness, testEnv, sender);
    const free: Session = await confirmedAccount(harness, testEnv, sender);
    const t0: number = harness.clock.nowMs;
    // One trial meeting left (two carried from an earlier account), and a trial that is over on a free-aware app.
    await env.DB.prepare("UPDATE users SET carried_trial_meetings = 2, trial_started_at = ? WHERE id = ?").bind(t0, trial.userId).run();
    await env.DB.prepare("UPDATE users SET carried_trial_meetings = 3, trial_started_at = ?, last_app_version = '0.2.18 (70)', last_os_version = 'macOS 26.1' WHERE id = ?")
      .bind(t0 - 8 * 86_400_000, free.userId)
      .run();
    const before: number = sender.sent.length;
    await runHourly(t0 + 3_600_000, testEnv);
    const firstRun: string[] = sender.sent.slice(before).map((message: EmailMessageBuilder): string => message.subject);
    expect(firstRun.sort()).toEqual(["You're on the Gistsmith Free plan", "Your Gistsmith trial ends soon"]);
    await runHourly(t0 + 49 * 3_600_000, testEnv);
    expect(sender.sent.slice(before + 2).map((message: EmailMessageBuilder): string => message.subject)).toEqual(["Ready for your first meeting?"]);
    await runHourly(t0 + 50 * 3_600_000, testEnv);
    expect(sender.sent.length).toBe(before + 3);
    // Nothing more can go to the free account: its address is gone.
    expect((await stateOf(harness, free, testEnv)).status).toBe("off");
    expect((await stateOf(harness, idle, testEnv)).status).toBe("confirmed");
    // 60 days after confirmation every address is gone.
    await runHourly(t0 + 61 * 86_400_000, testEnv);
    expect((await stateOf(harness, idle, testEnv)).status).toBe("off");
    expect((await stateOf(harness, trial, testEnv)).status).toBe("off");
  });

  it("stops the run at the cap and sends the rest later", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2034, 2, 1, 9);
    const sender: FakeSender = fakeSender();
    const setupEnv: Env = emailEnv(sender, {});
    const first: Session = await confirmedAccount(harness, setupEnv, sender);
    const second: Session = await confirmedAccount(harness, setupEnv, sender);
    for (const session of [first, second]) {
      await env.DB.prepare("UPDATE users SET carried_trial_meetings = 2, trial_started_at = ? WHERE id = ?").bind(harness.clock.nowMs, session.userId).run();
    }
    // Four emails so far this day (two confirmations, two welcomes); a daily cap of 5 leaves one.
    const cappedEnv: Env = emailEnv(sender, { dailyCap: 5, confirmDailyCap: 5, perRunCap: 5 });
    const before: number = sender.sent.length;
    await runHourly(harness.clock.nowMs + 3_600_000, cappedEnv);
    expect(sender.sent.length).toBe(before + 1);
    await runHourly(harness.clock.nowMs + 86_400_000, cappedEnv);
    expect(sender.sent.length).toBe(before + 2);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM email_sends WHERE kind = 'trial_ending' AND sent_at IS NULL").first<{ n: number }>()).toEqual({ n: 0 });
  });
});
