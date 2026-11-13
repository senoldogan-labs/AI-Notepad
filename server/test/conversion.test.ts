import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { type AdminConversion, type ConversionRow, adminConversionOf, conversionPlatformOf } from "../src/conversion";
import type { Env } from "../src/env";
import { type Harness, type Session, defaultHarness, envWith, expectError, req, signIn, signInWithGoogle } from "./helpers";
import { stubStripeApi } from "./stripeFake";

const adminSubject: string = "conversion-admin";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });
const iPhone: Readonly<Record<string, string>> = { "x-app-version": "0.3.0 (60)", "x-os-version": "iOS 27.2" };
const mac: Readonly<Record<string, string>> = { "x-app-version": "0.3.0 (60)", "x-os-version": "macOS 26.1" };

function post(harness: Harness, session: Session, events: readonly object[], headers: Readonly<Record<string, string>>): Promise<Response> {
  return harness.call(req("POST", "/v1/telemetry", { token: session.accessToken, json: { events }, headers }));
}

interface StoredRow {
  readonly kind: string;
  readonly platform: string;
  readonly surface: string;
  readonly trigger: string;
  readonly tiers: string;
  readonly tier: string;
  readonly plan: string;
  readonly reason: string;
  readonly count: number;
}

async function stored(): Promise<StoredRow[]> {
  const result = await env.DB.prepare(
    "SELECT kind, platform, surface, trigger, tiers, tier, plan, reason, SUM(count) AS count FROM conversion_events_daily GROUP BY kind, platform, surface, trigger, tiers, tier, plan, reason ORDER BY kind, platform, surface",
  ).all<StoredRow>();
  return result.results;
}

describe("conversion telemetry", () => {
  it("stores summed funnel events per platform with fixed-list dimensions only", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const shown = { kind: "paywall_shown", surface: "paywall", trigger: "trial_ended", tiersOffered: "personal_pro", count: 1 };
    const response: Response = await post(
      harness,
      session,
      [
        shown,
        shown,
        { kind: "plan_selected", surface: "paywall", trigger: "trial_ended", tier: "pro", plan: "yearly", count: 1 },
        { kind: "purchase_failed", surface: "paywall", trigger: "trial_ended", reason: "network", count: 1 },
        { kind: "purchase_restored", surface: "settings", result: "nothing_found", count: 1 },
        { kind: "trial_reminder_opt_in", count: 1 },
        { kind: "final_pass_give_up", count: 1 },
      ],
      iPhone,
    );
    expect(response.status).toBe(202);
    expect((await post(harness, session, [{ kind: "trial_reminder_shown", channel: "notification", count: 3 }], mac)).status).toBe(202);
    expect(await stored()).toEqual([
      { kind: "paywall_shown", platform: "ios", surface: "paywall", trigger: "trial_ended", tiers: "personal_pro", tier: "", plan: "", reason: "", count: 2 },
      { kind: "plan_selected", platform: "ios", surface: "paywall", trigger: "trial_ended", tiers: "", tier: "pro", plan: "yearly", reason: "", count: 1 },
      { kind: "purchase_failed", platform: "ios", surface: "paywall", trigger: "trial_ended", tiers: "", tier: "", plan: "", reason: "network", count: 1 },
      { kind: "purchase_restored", platform: "ios", surface: "settings", trigger: "", tiers: "", tier: "", plan: "", reason: "nothing_found", count: 1 },
      { kind: "trial_reminder_opt_in", platform: "ios", surface: "", trigger: "", tiers: "", tier: "", plan: "", reason: "", count: 1 },
      { kind: "trial_reminder_shown", platform: "macos", surface: "", trigger: "", tiers: "", tier: "", plan: "", reason: "notification", count: 3 },
    ]);
    // The reliability event still goes to its own table.
    const reliability = await env.DB.prepare("SELECT SUM(count) AS count FROM client_event_counts WHERE kind = 'final_pass_give_up'").first<{ count: number }>();
    expect(reliability?.count).toBe(1);
  });

  it("rejects free text, unknown values and fields a kind does not carry", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    for (const event of [
      { kind: "paywall_shown", surface: "paywall", trigger: "trial_ended", tiersOffered: "personal", count: 1, userId: "x" },
      { kind: "purchase_failed", surface: "paywall", trigger: "trial_ended", reason: "Card declined for jane@example.com", count: 1 },
      { kind: "plan_selected", surface: "paywall", trigger: "trial_ended", tier: "enterprise", plan: "yearly", count: 1 },
      { kind: "upsell_shown", trigger: "monthly_full", tier: "pro", count: 1 },
    ]) {
      await expectError(await post(harness, session, [event], iPhone), 400, "invalid_body");
    }
  });

  it("counts opened checkouts by source, tier and plan, and the admin view sums the window", async () => {
    const harness: Harness = await defaultHarness();
    stubStripeApi(harness);
    const web: Session = await signIn(harness);
    expect((await harness.call(req("POST", "/v1/billing/checkout", { token: web.accessToken, json: { plan: "yearly", tier: "pro" } }))).status).toBe(200);
    const app: Session = await signIn(harness);
    expect((await harness.call(req("POST", "/v1/billing/checkout", { token: app.accessToken, json: { plan: "monthly" }, headers: mac }))).status).toBe(200);
    await post(harness, app, [{ kind: "purchase_started", surface: "sheet", trigger: "trial_ended", tier: "personal", plan: "monthly", count: 1 }], mac);

    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const response: Response = await harness.call(req("GET", "/v1/admin/telemetry", { token: admin.accessToken, env: adminEnv }));
    expect(response.status).toBe(200);
    const body = await response.json<{ conversion: AdminConversion }>();
    expect(body.conversion.checkouts).toEqual([
      { source: "app", tier: "personal", plan: "monthly", count: 1, completed: 0, expired: 0 },
      { source: "web", tier: "pro", plan: "yearly", count: 1, completed: 0, expired: 0 },
    ]);
    expect(body.conversion.planMix).toContainEqual({ platform: "macos", tier: "personal", plan: "monthly", started: 1, completed: 0 });
  });

  it("counts the onboarding's 'Where did you hear about us?' answer from a fixed list", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect((await post(harness, session, [{ kind: "heard_about", source: "ai_assistant", count: 1 }], mac)).status).toBe(202);
    expect((await post(harness, session, [{ kind: "heard_about", source: "ai_assistant", count: 1 }], mac)).status).toBe(202);
    expect((await stored()).filter((row: StoredRow): boolean => row.kind === "heard_about")).toEqual([
      { kind: "heard_about", platform: "macos", surface: "", trigger: "", tiers: "", tier: "", plan: "", reason: "ai_assistant", count: 2 },
    ]);
    for (const event of [
      { kind: "heard_about", source: "my cousin Jane", count: 1 },
      { kind: "heard_about", source: "search", trigger: "trial_ended", count: 1 },
    ]) {
      await expectError(await post(harness, session, [event], mac), 400, "invalid_body");
    }
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const body = await (await harness.call(req("GET", "/v1/admin/telemetry", { token: admin.accessToken, env: adminEnv }))).json<{ conversion: AdminConversion }>();
    expect(body.conversion.heardAbout).toEqual([{ platform: "macos", source: "ai_assistant", count: 2 }]);
  });
});

describe("conversion telemetry: pure functions", () => {
  it("derives the platform from x-os-version", () => {
    expect(conversionPlatformOf("iOS 27.2")).toBe("ios");
    expect(conversionPlatformOf("macOS 26.1")).toBe("macos");
    expect(conversionPlatformOf(null)).toBe("unknown");
  });

  it("builds the funnel per platform and trigger", () => {
    const row = (kind: string, trigger: string, count: number): ConversionRow => ({
      kind,
      platform: "ios",
      surface: "paywall",
      trigger,
      tiers: "",
      tier: kind === "paywall_shown" ? "" : "personal",
      plan: kind === "paywall_shown" ? "" : "yearly",
      reason: "",
      count,
    });
    const summary: AdminConversion = adminConversionOf([
      row("paywall_shown", "trial_ended", 10),
      row("plan_selected", "trial_ended", 4),
      row("purchase_started", "trial_ended", 3),
      row("purchase_completed", "trial_ended", 2),
      { kind: "upsell_shown", platform: "macos", surface: "", trigger: "monthly_full", tiers: "", tier: "", plan: "", reason: "", count: 5 },
      { kind: "upsell_tapped", platform: "macos", surface: "", trigger: "monthly_full", tiers: "", tier: "", plan: "", reason: "", count: 1 },
    ]);
    expect(summary.funnel).toEqual([{ platform: "ios", trigger: "trial_ended", shown: 10, selected: 4, started: 3, completed: 2, cancelled: 0, failed: 0 }]);
    expect(summary.upsells).toEqual([{ trigger: "monthly_full", shown: 5, tapped: 1 }]);
    expect(summary.planMix).toEqual([{ platform: "ios", tier: "personal", plan: "yearly", started: 3, completed: 2 }]);
  });
});
