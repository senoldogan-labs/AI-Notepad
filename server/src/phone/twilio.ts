import { SignJWT } from "jose";
import { base64Encode, constantTimeEqualText, utf8 } from "../crypto";
import { UpstreamError, isRetryableStatus } from "../errors";
import type { OutboundPlatform } from "../platform";
import { withRetries } from "../retry";
import { fetchUpstream, isRetryableUpstreamError } from "../upstream";
import { CallerIdAlreadyRegisteredError, type CallerIdVerificationStart, type VoiceProvider } from "./provider";

/**
 * Twilio Programmable Voice adapter (REST API 2010-04-01 over `platform.fetch`, no SDK):
 * - Access Tokens with a Voice grant for the iOS Voice SDK (outgoing only, through the TwiML App);
 * - Outgoing Caller IDs: verifying the user's own number by a call with a code, so calls show it as caller ID;
 * - Recordings: the dual-channel recording of a call, fetched once and deleted;
 * - webhook signatures (`X-Twilio-Signature`, HMAC-SHA1 with the account's auth token).
 * Secrets never reach logs; error bodies are read only for Twilio's numeric error code.
 */

/** Twilio secrets and ids (`TWILIO_*`, see `config.ts`). */
export interface TwilioCredentials {
  /** `AC…` */
  readonly accountSid: string;
  /** `SK…`: an API key (REST calls and token signing). */
  readonly apiKeySid: string;
  readonly apiKeySecret: string;
  /** The account's auth token: Twilio signs webhooks with it. */
  readonly authToken: string;
  /** `AP…`: the TwiML App whose Voice URL is `/v1/phone/webhooks/voice`. */
  readonly twimlAppSid: string;
}

const apiBase: string = "https://api.twilio.com/2010-04-01";
const service: string = "twilio";
const requestTimeoutMs: number = 15_000;
const recordingTimeoutMs: number = 60_000;
const attempts: number = 3;
/** Twilio error 21450: "Phone number already verified for your account". */
const alreadyVerifiedCode: number = 21450;

/** Basic auth header of the API key. Pure function. */
function basicAuth(credentials: TwilioCredentials): string {
  return `Basic ${base64Encode(utf8(`${credentials.apiKeySid}:${credentials.apiKeySecret}`))}`;
}

/**
 * The string Twilio signs for a webhook: the full URL, then every POST field name and value, sorted by name. Pure
 * function.
 */
export function twilioSignedPayload(url: string, fields: ReadonlyMap<string, string>): string {
  const names: string[] = [...fields.keys()].sort();
  return url + names.map((name: string): string => `${name}${fields.get(name) ?? ""}`).join("");
}

/** Base64 HMAC-SHA1 of the signed payload with the auth token (what `X-Twilio-Signature` carries). */
export async function twilioSignature(authToken: string, url: string, fields: ReadonlyMap<string, string>): Promise<string> {
  const key: CryptoKey = await crypto.subtle.importKey("raw", utf8(authToken), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const mac: ArrayBuffer = await crypto.subtle.sign("HMAC", key, utf8(twilioSignedPayload(url, fields)));
  return base64Encode(new Uint8Array(mac));
}

const validationResponse = (value: unknown): CallerIdVerificationStart | null => {
  if (typeof value !== "object" || value === null) {
    return null;
  }
  const code: unknown = Reflect.get(value, "validation_code");
  const callSid: unknown = Reflect.get(value, "call_sid");
  const codeText: string | null = typeof code === "string" ? code : typeof code === "number" ? String(code) : null;
  return codeText !== null && /^[0-9]{4,10}$/.test(codeText) && typeof callSid === "string" && /^CA[0-9a-f]{32}$/.test(callSid)
    ? { validationCode: codeText, callSid }
    : null;
};

/** Twilio's numeric error code in an error body; `null` when absent. */
async function errorCodeOf(response: Response): Promise<number | null> {
  try {
    const body: unknown = await response.json();
    const code: unknown = typeof body === "object" && body !== null ? Reflect.get(body, "code") : null;
    return typeof code === "number" ? code : null;
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      return null;
    }
    throw error;
  }
}

/** The Twilio adapter over the platform's outbound fetch. */
export function twilioProvider(platform: OutboundPlatform, credentials: TwilioCredentials): VoiceProvider {
  const account: string = `${apiBase}/Accounts/${credentials.accountSid}`;
  const authorization: string = basicAuth(credentials);

  /**
   * Placing a verification call is not repeatable (a retry would ring the user twice), so it is sent once; the user can
   * start again. Error 21450 becomes `CallerIdAlreadyRegisteredError`.
   */
  const startCallerIdVerification = async (e164: string, callbackUrl: string): Promise<CallerIdVerificationStart> => {
    const form: URLSearchParams = new URLSearchParams({ PhoneNumber: e164, FriendlyName: "Gistsmith user", StatusCallback: callbackUrl, StatusCallbackMethod: "POST" });
    const response: Response = await platform.fetch(`${account}/OutgoingCallerIds.json`, {
      method: "POST",
      headers: { authorization, "content-type": "application/x-www-form-urlencoded" },
      body: form.toString(),
      signal: AbortSignal.timeout(requestTimeoutMs),
    });
    if (!response.ok) {
      const code: number | null = await errorCodeOf(response);
      if (code === alreadyVerifiedCode) {
        throw new CallerIdAlreadyRegisteredError("The number is already a caller ID of the Twilio account.");
      }
      throw new UpstreamError(service, response.status, false, `caller ID verification refused, Twilio error ${code ?? "unknown"}`);
    }
    const started: CallerIdVerificationStart | null = validationResponse(await response.json());
    if (started === null) {
      throw new UpstreamError(service, response.status, false, "caller ID verification answer without a code or call id");
    }
    return started;
  };

  const callerIdSid = async (e164: string): Promise<string | null> => {
    const url: string = `${account}/OutgoingCallerIds.json?${new URLSearchParams({ PhoneNumber: e164 }).toString()}`;
    const response: Response = await fetchUpstream(platform, service, url, (): RequestInit => ({ headers: { authorization } }), attempts, requestTimeoutMs);
    const body: unknown = await response.json();
    const list: unknown = typeof body === "object" && body !== null ? Reflect.get(body, "outgoing_caller_ids") : null;
    if (!Array.isArray(list)) {
      throw new UpstreamError(service, response.status, false, "caller ID list without outgoing_caller_ids");
    }
    for (const entry of list as unknown[]) {
      const sid: unknown = typeof entry === "object" && entry !== null ? Reflect.get(entry, "sid") : null;
      const number: unknown = typeof entry === "object" && entry !== null ? Reflect.get(entry, "phone_number") : null;
      if (typeof sid === "string" && /^PN[0-9a-f]{32}$/.test(sid) && number === e164) {
        return sid;
      }
    }
    return null;
  };

  /** DELETE that treats 404 (already gone) as done; other failures are retried, then thrown. */
  const deleteResource = async (url: string): Promise<void> => {
    await withRetries(
      { service, attempts, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableUpstreamError, recordRetry: platform.recordRetry },
      async (): Promise<void> => {
        const response: Response = await platform.fetch(url, { method: "DELETE", headers: { authorization }, signal: AbortSignal.timeout(requestTimeoutMs) });
        await response.body?.cancel();
        if (!response.ok && response.status !== 404) {
          throw new UpstreamError(service, response.status, isRetryableStatus(response.status), "delete failed");
        }
      },
    );
  };

  const accessToken = async (identity: string, ttlSeconds: number, now: Date): Promise<string> => {
    const issuedAt: number = Math.floor(now.getTime() / 1000);
    return new SignJWT({ grants: { identity, voice: { outgoing: { application_sid: credentials.twimlAppSid } } } })
      .setProtectedHeader({ alg: "HS256", typ: "JWT", cty: "twilio-fpa;v=1" })
      .setJti(`${credentials.apiKeySid}-${issuedAt}`)
      .setIssuer(credentials.apiKeySid)
      .setSubject(credentials.accountSid)
      .setIssuedAt(issuedAt)
      .setNotBefore(issuedAt)
      .setExpirationTime(issuedAt + ttlSeconds)
      .sign(utf8(credentials.apiKeySecret));
  };

  const recording = async (sid: string): Promise<Response> =>
    fetchUpstream(
      platform,
      service,
      `${account}/Recordings/${sid}.mp3?RequestedChannels=2`,
      (): RequestInit => ({ headers: { authorization } }),
      attempts,
      recordingTimeoutMs,
    );

  const verifyWebhook = async (url: string, fields: ReadonlyMap<string, string>, signature: string | null): Promise<boolean> => {
    if (signature === null) {
      return false;
    }
    return constantTimeEqualText(await twilioSignature(credentials.authToken, url, fields), signature);
  };

  return {
    displayName: "Twilio",
    accountId: credentials.accountSid,
    startCallerIdVerification,
    callerIdSid,
    deleteCallerId: (sid: string): Promise<void> => deleteResource(`${account}/OutgoingCallerIds/${sid}.json`),
    accessToken,
    recording,
    deleteRecording: (sid: string): Promise<void> => deleteResource(`${account}/Recordings/${sid}.json`),
    verifyWebhook,
  };
}
