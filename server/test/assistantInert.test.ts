import { createScheduledController } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { ConfigError, parseConfig } from "../src/config";
import type { Env } from "../src/env";
import worker from "../src/index";
import wranglerSource from "../wrangler.jsonc?raw";
import { stripJsonc } from "./jsonc";
import { type Harness, type Session, cronUpstreams, defaultHarness, expectError, req, signIn } from "./helpers";

/**
 * The API Worker's assistant code is inert while ASSISTANT_POLICY is "off" (no ASSISTANT_DB / ASSISTANT_BUCKET bindings,
 * nothing may touch them); when it is "on", production binds the EU assistant database and bucket with real ids.
 */

afterEach(() => {
  vi.restoreAllMocks();
});

/** The test environment without the assistant bindings (production before the owner enables the feature). */
function envWithoutAssistant(policy: "on" | "off"): Env {
  const { ASSISTANT_DB: _database, ASSISTANT_BUCKET: _bucket, ...rest } = env;
  return { ...rest, ASSISTANT_POLICY: policy };
}

const bindingList = z.array(z.object({ binding: z.string() }).passthrough());
const productionSchema = z.object({
  env: z.object({
    production: z.object({
      d1_databases: bindingList,
      r2_buckets: bindingList,
      vars: z.object({ ASSISTANT_POLICY: z.enum(["on", "off"]) }).passthrough(),
    }),
  }),
});

describe("API Worker test runtime", () => {
  it("has the API Worker's own compatibility flags, not the MCP Worker's", () => {
    expect(Cloudflare.compatibilityFlags["global_fetch_strictly_public"]).toBe(false);
  });
});

describe("assistant code in the API Worker before the EU database exists", () => {
  it("production binds the EU assistant database and bucket with real ids exactly when the policy is on", () => {
    const production = productionSchema.parse(JSON.parse(stripJsonc(wranglerSource))).env.production;
    const databases: readonly string[] = production.d1_databases.map((entry): string => entry.binding);
    const buckets: readonly string[] = production.r2_buckets.map((entry): string => entry.binding);
    if (production.vars.ASSISTANT_POLICY === "on") {
      expect(databases).toEqual(["DB", "ASSISTANT_DB"]);
      expect(buckets).toEqual(["SYNC_BUCKET", "ASSISTANT_BUCKET"]);
      const assistantDb = production.d1_databases.find((entry): boolean => entry.binding === "ASSISTANT_DB");
      expect(assistantDb?.["database_name"]).toBe("gistsmith-assistant");
      expect(String(assistantDb?.["database_id"])).not.toMatch(/^0{8}-/);
      const assistantBucket = production.r2_buckets.find((entry): boolean => entry.binding === "ASSISTANT_BUCKET");
      expect(assistantBucket?.["jurisdiction"]).toBe("eu");
    } else {
      expect(databases).toEqual(["DB"]);
      expect(buckets).toEqual(["SYNC_BUCKET"]);
    }
    expect(JSON.stringify(production)).not.toContain("TODO");
  });

  it("with the policy on, missing bindings fail the configuration, not a request", () => {
    expect(() => parseConfig(envWithoutAssistant("off"))).not.toThrow();
    let fields: readonly string[] = [];
    try {
      parseConfig(envWithoutAssistant("on"));
    } catch (error: unknown) {
      if (!(error instanceof ConfigError)) {
        throw error;
      }
      fields = error.fields;
    }
    expect(fields).toEqual(["ASSISTANT_DB", "ASSISTANT_BUCKET"]);
  });

  it("with the policy off, the routes refuse and account deletion skips the assistant step", async () => {
    const harness: Harness = await defaultHarness();
    const offEnv: Env = envWithoutAssistant("off");
    const session: Session = await signIn(harness);
    await expectError(await harness.call(req("GET", "/v1/assistant/settings", { token: session.accessToken, env: offEnv })), 503, "assistant_unavailable");
    await expectError(await harness.call(req("PUT", `/v1/assistant/meetings/${crypto.randomUUID()}`, { token: session.accessToken, json: {}, env: offEnv })), 503, "assistant_unavailable");
    const info = vi.spyOn(console, "log");
    const deleted: Response = await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env: offEnv }));
    expect(deleted.status).toBe(200);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM users WHERE id = ?").bind(session.userId).first()).toEqual({ count: 0 });
    const skipped: string | undefined = info.mock.calls.map((call: unknown[]): string => String(call[0])).find((line: string): boolean => line.includes('"event":"assistant_deletion_skipped"'));
    expect(JSON.parse(skipped ?? "{}")).toEqual({ level: "info", event: "assistant_deletion_skipped", userId: session.userId, reason: "assistant_policy_off" });
  });

  it("with the policy off, the daily cron skips the assistant cleanup and every other step still runs", async () => {
    // The cron also refreshes Apple's and Google's keys and the ElevenLabs credits: answered with fakes.
    vi.spyOn(globalThis, "fetch").mockImplementation(cronUpstreams);
    const info = vi.spyOn(console, "log");
    const controller: ScheduledController = createScheduledController({ scheduledTime: Date.UTC(2026, 9, 15, 3, 17), cron: "17 3 * * *" });
    await worker.scheduled(controller, envWithoutAssistant("off"));
    expect(info.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"assistant_cleanup_skipped"'))).toBe(true);
  });
});
