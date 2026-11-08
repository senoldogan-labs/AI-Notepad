import { describe, expect, it } from "vitest";
import { z } from "zod";
import apiSource from "../wrangler.jsonc?raw";
import mcpSource from "../wrangler.mcp.jsonc?raw";
import { stripJsonc } from "./jsonc";

/**
 * Rate limiter `namespace_id`s are account-wide: two bindings with the same id share one counter, even across Workers.
 * The API Worker and the MCP Worker live in the same account, so no id may repeat between them or between environments.
 */

const ratelimits = z.array(z.object({ name: z.string(), namespace_id: z.string() }).passthrough());
const workerConfig = z.object({
  ratelimits,
  env: z.object({ production: z.object({ ratelimits }).passthrough() }).passthrough(),
});

type Environment = "development" | "production";
type Limiter = { readonly binding: string; readonly namespaceId: string };

/** Each limiter of one environment (top level = development) labelled with its Worker. Pure. */
function limiters(worker: string, source: string, environment: Environment): readonly Limiter[] {
  const config = workerConfig.parse(JSON.parse(stripJsonc(source)));
  const list = environment === "development" ? config.ratelimits : config.env.production.ratelimits;
  return list.map((limiter) => ({ binding: `${worker}/${environment}/${limiter.name}`, namespaceId: limiter.namespace_id }));
}

/** Namespace ids used by more than one binding, each with the bindings that share it. Pure. */
function sharedIds(all: readonly Limiter[]): readonly string[] {
  const byId: Map<string, readonly string[]> = new Map();
  for (const limiter of all) {
    byId.set(limiter.namespaceId, [...(byId.get(limiter.namespaceId) ?? []), limiter.binding]);
  }
  return [...byId.entries()].filter(([, bindings]) => bindings.length > 1).map(([id, bindings]) => `${id}: ${bindings.join(", ")}`);
}

describe("rate limiter namespaces", () => {
  it("are unique across both Workers and both environments", () => {
    const environments: readonly Environment[] = ["development", "production"];
    const all: readonly Limiter[] = environments.flatMap((environment) => [
      ...limiters("api", apiSource, environment),
      ...limiters("mcp", mcpSource, environment),
    ]);
    expect(all.length).toBeGreaterThan(20);
    expect(sharedIds(all)).toEqual([]);
  });
});

const phoneVars = z.object({ PHONE_CALLS_POLICY: z.string(), PHONE_CALLS_COUNTRIES: z.string() });
const phoneConfig = z.object({ vars: phoneVars, env: z.object({ production: z.object({ vars: phoneVars }).passthrough() }).passthrough() });

describe("in-app dialer switch", () => {
  // The dialer pilot reaches a paid voice provider: production stays off until the owner turns it on in a reviewed
  // change (spec: docs/superpowers/specs/2026-11-08-iphone-call-recording.md › "Turning it on"), which updates this test.
  it("is off in production and development, for US and Canada only", () => {
    const config = phoneConfig.parse(JSON.parse(stripJsonc(apiSource)));
    expect(config.env.production.vars).toEqual({ PHONE_CALLS_POLICY: "off", PHONE_CALLS_COUNTRIES: "US,CA" });
    expect(config.vars).toEqual({ PHONE_CALLS_POLICY: "off", PHONE_CALLS_COUNTRIES: "US,CA" });
  });
});

const routeConfig = z.object({
  env: z.object({
    production: z
      .object({
        routes: z.array(z.object({ pattern: z.string() }).passthrough()),
        vars: z.object({ SITE_ORIGIN: z.string(), CF_ACCESS_TEAM_DOMAIN: z.string() }).passthrough(),
      })
      .passthrough(),
  }),
});

describe("admin API behind Cloudflare Access", () => {
  // The admin panel (web/src/config.ts → adminApiBase) calls the admin API on the site's own origin, so the Access
  // application that protects /admin also covers the API and its cookie reaches every admin request
  // (src/auth/access.ts). The route must stay on the site's host.
  it("runs on the site's origin under /v1/admin/ in production", () => {
    const production = routeConfig.parse(JSON.parse(stripJsonc(apiSource))).env.production;
    const siteHost: string = new URL(production.vars.SITE_ORIGIN).host;
    expect(production.routes.map((route) => route.pattern)).toEqual(["api.gistsmith.com", `${siteHost}/v1/admin/*`]);
    expect(production.vars.CF_ACCESS_TEAM_DOMAIN).toBe("dry-heart-1ee2.cloudflareaccess.com");
  });
});

const proVars = z.object({ PRO_TIER_POLICY: z.string() });
const proConfig = z.object({ vars: proVars, env: z.object({ production: z.object({ vars: proVars }).passthrough() }).passthrough() });

describe("Pro tier switch", () => {
  // Pro is dark-launched: production stays off until the owner launches it (and makes RevenueCat's `pro_preview`
  // offering current) in a reviewed change that updates this test. Development and tests sell it.
  it("is off in production and on in development", () => {
    const config = proConfig.parse(JSON.parse(stripJsonc(apiSource)));
    expect(config.env.production.vars).toEqual({ PRO_TIER_POLICY: "off" });
    expect(config.vars).toEqual({ PRO_TIER_POLICY: "on" });
  });
});
