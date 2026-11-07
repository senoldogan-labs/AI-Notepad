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
