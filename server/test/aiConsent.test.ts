import { describe, expect, it } from "vitest";
import { aiConsentEnforced, aiConsentVersion } from "../src/aiConsent";
import { type Harness, type Session, defaultHarness, expectError, req, signIn } from "./helpers";

/** An app that asks for consent before AI requests (0.2.5 and later) and one in the wild before it. */
const newApp: Readonly<Record<string, string>> = { "x-app-version": "0.2.5 (52)", "x-os-version": "iOS 26.1.0" };
const oldApp: Readonly<Record<string, string>> = { "x-app-version": "0.2.4 (51)", "x-os-version": "iOS 26.1.0" };

interface MeBody {
  readonly aiConsent: { readonly version: number | null; readonly decidedAt: string | null };
}

async function putConsent(harness: Harness, session: Session, granted: boolean, version: number): Promise<Response> {
  return harness.call(req("PUT", "/v1/me/ai-consent", { token: session.accessToken, headers: newApp, json: { granted, version } }));
}

async function startWith(harness: Harness, session: Session, headers: Readonly<Record<string, string>>): Promise<Response> {
  return harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, headers, json: {} }));
}

describe("aiConsentEnforced", () => {
  it("enforces from 0.2.5 on and never for older or missing versions", () => {
    expect(aiConsentEnforced("0.2.5 (52)")).toBe(true);
    expect(aiConsentEnforced("0.2.10 (60)")).toBe(true);
    expect(aiConsentEnforced("0.3 (61)")).toBe(true);
    expect(aiConsentEnforced("1.0.0 (70)")).toBe(true);
    expect(aiConsentEnforced("0.2.4 (51)")).toBe(false);
    expect(aiConsentEnforced("0.1.99 (40)")).toBe(false);
    expect(aiConsentEnforced(null)).toBe(false);
    expect(aiConsentEnforced("garbage")).toBe(false);
  });
});

describe("AI consent", () => {
  it("records agreeing and withdrawing, and /v1/me returns it", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const before: MeBody = await (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
    expect(before.aiConsent).toEqual({ version: null, decidedAt: null });

    const granted: Response = await putConsent(harness, session, true, aiConsentVersion);
    expect(granted.status).toBe(200);
    expect(await granted.json()).toEqual({ version: aiConsentVersion, decidedAt: new Date(harness.clock.nowMs).toISOString() });
    const after: MeBody = await (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
    expect(after.aiConsent.version).toBe(aiConsentVersion);

    const withdrawn: Response = await putConsent(harness, session, false, aiConsentVersion);
    expect(((await withdrawn.json()) as MeBody["aiConsent"]).version).toBeNull();
    const last: MeBody = await (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
    expect(last.aiConsent.version).toBeNull();
    expect(last.aiConsent.decidedAt).not.toBeNull();
  });

  it("refuses agreeing to an older disclosure version", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await putConsent(harness, session, true, aiConsentVersion - 1), 400, "bad_request");
  });

  it("an app from 0.2.5 on needs consent for AI endpoints; older apps keep working", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await startWith(harness, session, newApp), 403, "ai_consent_required");
    await expectError(
      await harness.call(req("POST", "/v1/llm/messages", { token: session.accessToken, headers: newApp, json: {} })),
      403,
      "ai_consent_required",
    );
    await expectError(
      await harness.call(
        req("POST", "/v1/live/deepgram-token", { token: session.accessToken, headers: { ...newApp, "x-meeting-id": crypto.randomUUID() } }),
      ),
      403,
      "ai_consent_required",
    );
    await expectError(
      await harness.call(
        req("POST", "/v1/transcribe", { token: session.accessToken, headers: { ...newApp, "x-meeting-id": crypto.randomUUID() }, body: new Uint8Array(8) }),
      ),
      403,
      "ai_consent_required",
    );
    // Grace rule: 0.2.4 and earlier never ask, so they are not refused.
    expect((await startWith(harness, session, oldApp)).status).toBe(201);

    const other: Session = await signIn(harness);
    expect((await putConsent(harness, other, true, aiConsentVersion)).status).toBe(200);
    expect((await startWith(harness, other, newApp)).status).toBe(201);
    // Withdrawing stops AI processing for the new app again.
    expect((await putConsent(harness, other, false, aiConsentVersion)).status).toBe(200);
    await expectError(await startWith(harness, other, newApp), 403, "ai_consent_required");
  });
});
