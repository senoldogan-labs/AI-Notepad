import { describe, expect, it } from "vitest";
import { parseConfig } from "../src/config";
import type { Env } from "../src/env";
import { liveOnDevice, onDeviceLiveBucket } from "../src/onDevice";
import { type Harness, type Session, defaultHarness, envWith, req, signIn } from "./helpers";

async function liveOnDeviceOf(harness: Harness, session: Session, testEnv: Env): Promise<boolean> {
  const response: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken, env: testEnv }));
  expect(response.status).toBe(200);
  return (await response.json<{ liveOnDevice: boolean }>()).liveOnDevice;
}

describe("On-device live preview rollout", () => {
  it("puts a user in a stable bucket and spreads users across buckets", () => {
    expect(onDeviceLiveBucket("user_a")).toBe(onDeviceLiveBucket("user_a"));
    const buckets: number[] = Array.from({ length: 2000 }, (_: unknown, index: number): number => onDeviceLiveBucket(`usr_${index.toString(36)}_x`));
    expect(Math.min(...buckets)).toBeGreaterThanOrEqual(0);
    expect(Math.max(...buckets)).toBeLessThanOrEqual(99);
    // Roughly a quarter of users fall under 25 (the production pilot share).
    const share: number = buckets.filter((bucket: number): boolean => bucket < 25).length / buckets.length;
    expect(share).toBeGreaterThan(0.2);
    expect(share).toBeLessThan(0.3);
  });

  it("0 includes nobody, 100 everybody, and raising the percent never drops a user", () => {
    const ids: string[] = Array.from({ length: 300 }, (_: unknown, index: number): string => `usr_${index}`);
    expect(ids.some((id: string): boolean => liveOnDevice(id, 0))).toBe(false);
    expect(ids.every((id: string): boolean => liveOnDevice(id, 100))).toBe(true);
    expect(ids.filter((id: string): boolean => liveOnDevice(id, 25)).every((id: string): boolean => liveOnDevice(id, 50))).toBe(true);
  });

  it("rejects a percent outside 0–100", () => {
    expect(() => parseConfig(envWith({ ON_DEVICE_LIVE_PERCENT: "101" }))).toThrow();
    expect(() => parseConfig(envWith({ ON_DEVICE_LIVE_PERCENT: "-1" }))).toThrow();
    expect(() => parseConfig(envWith({ ON_DEVICE_LIVE_PERCENT: "12.5" }))).toThrow();
  });

  it("/v1/me reports the user's rollout answer from the flag", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    expect(await liveOnDeviceOf(harness, session, envWith({ ON_DEVICE_LIVE_PERCENT: "100" }))).toBe(true);
    expect(await liveOnDeviceOf(harness, session, envWith({ ON_DEVICE_LIVE_PERCENT: "0" }))).toBe(false);
    const inBucket: boolean = liveOnDevice(session.userId, 25);
    expect(await liveOnDeviceOf(harness, session, envWith({ ON_DEVICE_LIVE_PERCENT: "25" }))).toBe(inBucket);
  });
});
