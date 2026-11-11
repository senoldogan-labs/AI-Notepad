import { z } from "zod";
import { ApiError } from "./errors";
import { readJsonBody } from "./http";
import { log } from "./log";

/**
 * Consent to send personal data to third-party AI services (App Review 5.1.1(i) / 5.1.2(i)). Before the first AI request
 * the app shows a disclosure naming what is sent and to whom (Anthropic for notes, translation and Ask answers;
 * ElevenLabs and Deepgram for transcription) and asks "Agree" / "Not now". The answer lives on the device and is recorded
 * here (`users.ai_consent_version`, `users.ai_consent_at`): `PUT /v1/me/ai-consent`, read back in `GET /v1/me`
 * (`aiConsent`).
 *
 * Enforcement grace rule: the AI endpoints (meeting start and reprocess, `/v1/llm/messages`, `/v1/transcribe`,
 * `/v1/live/deepgram-token`) refuse with `ai_consent_required` only when the request's `x-app-version` is
 * `aiConsentEnforcedFromVersion` or newer. Those apps ask before any AI request and record the answer; older apps
 * (0.2.4 and earlier, in the wild) never send one and keep working, their consent being the earlier in-app disclosure.
 * Only a well-formed older version is exempt: a request without the header or with an unparsable one is enforced, since
 * every app version that sends AI requests sends it (`x-app-version` came with the client telemetry, Gistsmith 0.1.10).
 */

/** Version of the disclosure the app shows; raising it asks every user of a new app again. Same as the app's `hostedAIConsentVersion`. */
export const aiConsentVersion: number = 2;

/** First app version whose AI requests need a recorded consent (see the grace rule above). */
export const aiConsentEnforcedFromVersion: readonly number[] = [0, 2, 5];

/** The account's recorded answer, as `GET /v1/me` returns it. */
export interface AIConsentState {
  /** Disclosure version the user agreed to; null when they never agreed or withdrew. */
  readonly version: number | null;
  /** When the last answer was recorded (ISO 8601); null when the app never sent one. */
  readonly decidedAt: string | null;
}

const aiConsentBodySchema = z.strictObject({ granted: z.boolean(), version: z.number().int().positive() });

/** Body limit of `PUT /v1/me/ai-consent`. */
const aiConsentBodyMaxBytes: number = 256;

interface AIConsentRow {
  readonly ai_consent_version: number | null;
  readonly ai_consent_at: number | null;
}

/** The row's columns as the API returns them. Pure function. */
function aiConsentStateOf(row: AIConsentRow | null): AIConsentState {
  return {
    version: row?.ai_consent_version ?? null,
    decidedAt: row?.ai_consent_at === null || row?.ai_consent_at === undefined ? null : new Date(row.ai_consent_at).toISOString(),
  };
}

/** The account's recorded answer. */
export async function readAIConsent(db: D1Database, userId: string): Promise<AIConsentState> {
  const row: AIConsentRow | null = await db
    .prepare("SELECT ai_consent_version, ai_consent_at FROM users WHERE id = ?")
    .bind(userId)
    .first<AIConsentRow>();
  return aiConsentStateOf(row);
}

/**
 * `PUT /v1/me/ai-consent` (`{granted, version}`): records the user's answer. Agreeing must name the current disclosure
 * version (an app showing an older text is told to update); withdrawing clears the version. Returns the recorded state.
 */
export async function recordAIConsent(db: D1Database, request: Request, userId: string, now: Date): Promise<AIConsentState> {
  const body = await readJsonBody(request, aiConsentBodySchema, aiConsentBodyMaxBytes);
  if (body.granted && body.version !== aiConsentVersion) {
    throw new ApiError("bad_request", `The current AI disclosure version is ${aiConsentVersion}; update the app.`);
  }
  const version: number | null = body.granted ? body.version : null;
  await db.prepare("UPDATE users SET ai_consent_version = ?, ai_consent_at = ? WHERE id = ?").bind(version, now.getTime(), userId).run();
  log("info", body.granted ? "ai_consent_granted" : "ai_consent_withdrawn", { userId, version: body.version });
  return aiConsentStateOf({ ai_consent_version: version, ai_consent_at: now.getTime() });
}

/**
 * Whether a request is subject to enforcement: only a well-formed `x-app-version` ("0.2.4 (51)", the format
 * `clientVersions.ts` records) below `aiConsentEnforcedFromVersion` is exempt. A missing or unparsable header is
 * enforced: no Gistsmith app sends AI requests without it, so it is not an old app. Pure function.
 */
export function aiConsentEnforced(appVersionHeader: string | null): boolean {
  if (appVersionHeader === null) {
    return true;
  }
  const match: RegExpExecArray | null = /^([0-9]{1,4}(?:\.[0-9]{1,4}){1,3}) \([0-9]{1,9}\)$/.exec(appVersionHeader);
  if (match === null || match[1] === undefined) {
    return true;
  }
  const parts: number[] = match[1].split(".").map(Number);
  for (let index = 0; index < aiConsentEnforcedFromVersion.length; index += 1) {
    const part: number = parts[index] ?? 0;
    const floor: number = aiConsentEnforcedFromVersion[index] ?? 0;
    if (part !== floor) {
      return part > floor;
    }
  }
  return true;
}

/**
 * Before an AI endpoint: an app subject to enforcement (`aiConsentEnforced`) must have the current consent recorded,
 * otherwise `ai_consent_required` (nothing is sent to an AI provider). Older apps (a well-formed version below
 * `aiConsentEnforcedFromVersion`) pass without a read.
 */
export async function requireAIConsent(db: D1Database, request: Request, userId: string): Promise<void> {
  if (!aiConsentEnforced(request.headers.get("x-app-version"))) {
    return;
  }
  const state: AIConsentState = await readAIConsent(db, userId);
  if (state.version === null || state.version < aiConsentVersion) {
    throw new ApiError("ai_consent_required", "Agree to the AI processing disclosure in the app before using AI features.");
  }
}
