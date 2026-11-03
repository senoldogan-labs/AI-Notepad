import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/env";
import { funnelMaxVersionsPerDay, funnelOverflowVersion } from "../src/funnel";
import { type Harness, type Session, blockingLimiter, defaultHarness, envWith, expectError, req, signInWithGoogle } from "./helpers";

const dayMs: number = 86_400_000;
const adminSubject: string = "huni-yonetici";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });
const appHeaders: Readonly<Record<string, string>> = { "x-app-version": "0.1.11 (20)" };

function dayOf(nowMs: number, offsetDays: number): string {
  return new Date(nowMs + offsetDays * dayMs).toISOString().slice(0, 10);
}

/** Adımı gönderir; testler farklı IP kullanır (gerçek hız sınırı dakikada 20). */
function postStep(harness: Harness, json: object, headers: Readonly<Record<string, string>>, environment: Env | null, clientIp: string): Promise<Response> {
  return harness.call(req("POST", "/v1/funnel", { json, headers, env: environment, clientIp }));
}

/** Günün sayaç satırları (adım ve ayrıntıya göre sıralı). */
async function rows(day: string): Promise<Array<{ step: string; detail: string; app_version: string; count: number }>> {
  return (
    await env.DB.prepare("SELECT step, detail, app_version, count FROM app_funnel_daily WHERE day = ? ORDER BY step, detail, app_version")
      .bind(day)
      .all<{ step: string; detail: string; app_version: string; count: number }>()
  ).results;
}

/** `GET /v1/admin/insights` yanıtının ilk açılış hunisi. */
interface FirstRunBody {
  readonly days: number;
  readonly steps: Array<{ step: string; detail: string; count: number }>;
  readonly byDay: Array<{ day: string; firstLaunches: number; signedIn: number }>;
}

describe("POST /v1/funnel", () => {
  it("jetonsuz izinli adımları 202 ile gün, adım, ayrıntı ve sürüm başına sayar; tanımlayıcı saklamaz", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs += 900 * dayMs;
    const today: string = dayOf(harness.clock.nowMs, 0);
    const steps: object[] = [
      { step: "first_launch", detail: "" },
      { step: "first_launch", detail: "" },
      { step: "sign_in_started", detail: "apple" },
      { step: "sign_in_canceled", detail: "apple" },
      { step: "sign_in_started", detail: "google" },
      { step: "sign_in_failed", detail: "network" },
      { step: "signed_in", detail: "google" },
    ];
    for (const step of steps) {
      const response: Response = await postStep(harness, step, appHeaders, null, "198.51.100.1");
      expect(response.status).toBe(202);
      expect(await response.json()).toEqual({});
    }
    expect((await postStep(harness, { step: "first_launch", detail: "" }, { "x-app-version": "0.1.12 (21)" }, null, "198.51.100.1")).status).toBe(202);
    expect(await rows(today)).toEqual([
      { step: "first_launch", detail: "", app_version: "0.1.11 (20)", count: 2 },
      { step: "first_launch", detail: "", app_version: "0.1.12 (21)", count: 1 },
      { step: "sign_in_canceled", detail: "apple", app_version: "0.1.11 (20)", count: 1 },
      { step: "sign_in_failed", detail: "network", app_version: "0.1.11 (20)", count: 1 },
      { step: "sign_in_started", detail: "apple", app_version: "0.1.11 (20)", count: 1 },
      { step: "sign_in_started", detail: "google", app_version: "0.1.11 (20)", count: 1 },
      { step: "signed_in", detail: "google", app_version: "0.1.11 (20)", count: 1 },
    ]);
    const columns = await env.DB.prepare("SELECT name FROM pragma_table_info('app_funnel_daily') ORDER BY cid").all<{ name: string }>();
    expect(columns.results.map((column: { name: string }): string => column.name)).toEqual(["day", "step", "detail", "app_version", "count"]);
  });

  it.each([
    ["bilinmeyen adım", { step: "opened_settings", detail: "" }],
    ["adıma uymayan ayrıntı", { step: "sign_in_started", detail: "network" }],
    ["bilinmeyen sağlayıcı", { step: "signed_in", detail: "github" }],
    ["ilk açılışta ayrıntı", { step: "first_launch", detail: "apple" }],
    ["bilinmeyen aşama", { step: "sign_in_failed", detail: "timeout" }],
    ["fazla alan", { step: "first_launch", detail: "", installId: "abc" }],
    ["eksik ayrıntı", { step: "first_launch" }],
  ])("%s: 400 invalid_body, satır yazılmaz", async (_: string, json: object) => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs += 901 * dayMs;
    await expectError(await postStep(harness, json, appHeaders, null, "198.51.100.2"), 400, "invalid_body");
    expect(await rows(dayOf(harness.clock.nowMs, 0))).toEqual([]);
  });

  it("günde en çok funnelMaxVersionsPerDay sürüm ayrı sayılır; sonraki yeni sürümler 'other' olur, bilinen sürüm yine kendi adıyla", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs += 902 * dayMs;
    const today: string = dayOf(harness.clock.nowMs, 0);
    const json: object = { step: "first_launch", detail: "" };
    const versions: string[] = Array.from({ length: funnelMaxVersionsPerDay + 3 }, (_: unknown, index: number): string => `9.${index}.0 (${index})`);
    // Her istek ayrı IP'den (gerçek hız sınırı IP başına dakikada 20).
    for (const [index, version] of versions.entries()) {
      expect((await postStep(harness, json, { "x-app-version": version }, null, `198.51.101.${index}`)).status).toBe(202);
    }
    // Günün ilk sürümü sınır dolduktan sonra da kendi satırına sayılır.
    expect((await postStep(harness, { step: "signed_in", detail: "apple" }, { "x-app-version": "9.0.0 (0)" }, null, "198.51.100.4")).status).toBe(202);
    const written = await rows(today);
    const firstLaunches: Array<{ app_version: string; count: number }> = written
      .filter((row: { step: string }): boolean => row.step === "first_launch")
      .map((row: { app_version: string; count: number }): { app_version: string; count: number } => ({ app_version: row.app_version, count: row.count }));
    expect(firstLaunches).toHaveLength(funnelMaxVersionsPerDay + 1);
    expect(firstLaunches).toContainEqual({ app_version: funnelOverflowVersion, count: 3 });
    expect(firstLaunches.map((row: { app_version: string }): string => row.app_version)).not.toContain(versions[funnelMaxVersionsPerDay]);
    expect(written).toContainEqual({ step: "signed_in", detail: "apple", app_version: "9.0.0 (0)", count: 1 });
    // Ertesi gün sınır yeniden başlar.
    harness.clock.nowMs += dayMs;
    expect((await postStep(harness, json, { "x-app-version": versions[funnelMaxVersionsPerDay + 2] ?? "" }, null, "198.51.100.4")).status).toBe(202);
    expect(await rows(dayOf(harness.clock.nowMs, 0))).toEqual([{ step: "first_launch", detail: "", app_version: versions[funnelMaxVersionsPerDay + 2], count: 1 }]);
  });

  it("x-app-version eksik ya da geçersizse 400 bad_request; IP hız sınırı 429 rate_limited", async () => {
    const harness: Harness = await defaultHarness();
    const json: object = { step: "first_launch", detail: "" };
    await expectError(await postStep(harness, json, {}, null, "198.51.100.3"), 400, "bad_request");
    await expectError(await postStep(harness, json, { "x-app-version": "dev" }, null, "198.51.100.3"), 400, "bad_request");
    await expectError(await postStep(harness, json, appHeaders, envWith({ FUNNEL_IP_LIMITER: blockingLimiter }), "198.51.100.3"), 429, "rate_limited");
  });

  it("yönetim içgörüleri son 30 günün adımlarını sabit sırayla ve günlük ilk açılış ile girişleri döner", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs += 1200 * dayMs;
    const nowMs: number = harness.clock.nowMs;
    await env.DB.prepare(
      `INSERT INTO app_funnel_daily (day, step, detail, app_version, count) VALUES
         (?1, 'first_launch', '', '0.1.11 (20)', 4), (?1, 'first_launch', '', '0.1.12 (21)', 1), (?1, 'sign_in_started', 'apple', '0.1.11 (20)', 3),
         (?1, 'sign_in_canceled', 'apple', '0.1.11 (20)', 2), (?1, 'sign_in_failed', 'server', '0.1.11 (20)', 1),
         (?2, 'first_launch', '', '0.1.11 (20)', 2), (?2, 'signed_in', 'google', '0.1.11 (20)', 1),
         (?3, 'first_launch', '', '0.1.11 (20)', 50)`,
    )
      .bind(dayOf(nowMs, 0), dayOf(nowMs, -29), dayOf(nowMs, -30))
      .run();
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const response: Response = await harness.call(req("GET", "/v1/admin/insights", { token: admin.accessToken, env: adminEnv }));
    expect(response.status).toBe(200);
    const firstRun: FirstRunBody = (await response.json<{ firstRun: FirstRunBody }>()).firstRun;
    expect(firstRun.days).toBe(30);
    expect(firstRun.steps).toEqual([
      { step: "first_launch", detail: "", count: 7 },
      { step: "sign_in_started", detail: "apple", count: 3 },
      { step: "sign_in_started", detail: "google", count: 0 },
      { step: "sign_in_canceled", detail: "apple", count: 2 },
      { step: "sign_in_canceled", detail: "google", count: 0 },
      { step: "sign_in_failed", detail: "window", count: 0 },
      { step: "sign_in_failed", detail: "callback", count: 0 },
      { step: "sign_in_failed", detail: "server", count: 1 },
      { step: "sign_in_failed", detail: "network", count: 0 },
      { step: "signed_in", detail: "apple", count: 0 },
      { step: "signed_in", detail: "google", count: 1 },
    ]);
    expect(firstRun.byDay).toHaveLength(30);
    expect(firstRun.byDay[0]).toEqual({ day: dayOf(nowMs, -29), firstLaunches: 2, signedIn: 1 });
    expect(firstRun.byDay[1]).toEqual({ day: dayOf(nowMs, -28), firstLaunches: 0, signedIn: 0 });
    expect(firstRun.byDay[29]).toEqual({ day: dayOf(nowMs, 0), firstLaunches: 5, signedIn: 0 });
  });
});
