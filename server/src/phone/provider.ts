/**
 * The voice provider behind the in-app dialer, as the dialer uses it. Twilio Programmable Voice implements it
 * (`twilio.ts`); the provider comparison and the reasons for Twilio are in the spec
 * (docs/superpowers/specs/2026-11-08-iphone-call-recording.md). Tests drive the Twilio adapter against a fake Twilio
 * REST API (`test/phone.test.ts`), so no account or paid call is needed.
 */
export interface VoiceProvider {
  /** Name shown in the app's disclosure (the third party that carries and records the call). */
  readonly displayName: string;
  /**
   * Starts verifying that the user owns `e164`: the provider calls the number and the user types `validationCode` on
   * the keypad. The provider reports the result to `callbackUrl`. Throws `CallerIdAlreadyRegisteredError` when the
   * number is already a caller ID of the provider account.
   */
  readonly startCallerIdVerification: (e164: string, callbackUrl: string) => Promise<CallerIdVerificationStart>;
  /** The provider's id of `e164` as a verified caller ID; `null` when it is not one. */
  readonly callerIdSid: (e164: string) => Promise<string | null>;
  /** Removes a caller ID from the provider account (repeating it is harmless). */
  readonly deleteCallerId: (sid: string) => Promise<void>;
  /** A short-lived token the app's Voice SDK connects with; it can only place outgoing calls through our webhook. */
  readonly accessToken: (identity: string, ttlSeconds: number, now: Date) => Promise<string>;
  /** The call's dual-channel recording (audio body). */
  readonly recording: (sid: string) => Promise<Response>;
  /** Deletes a recording at the provider (repeating it is harmless). */
  readonly deleteRecording: (sid: string) => Promise<void>;
  /** Whether a webhook request really comes from the provider (signature over the URL and form fields). */
  readonly verifyWebhook: (url: string, fields: ReadonlyMap<string, string>, signature: string | null) => Promise<boolean>;
  /** The provider account id webhooks carry (checked against every webhook). */
  readonly accountId: string;
}

/** A verification call the provider is placing. */
export interface CallerIdVerificationStart {
  /** The code the user types on the keypad when the provider calls (6 digits). */
  readonly validationCode: string;
  /** The provider's id of the verification call (the result webhook carries it). */
  readonly callSid: string;
}

/** The number is already a caller ID of the provider account (verified earlier, maybe by an account since deleted). */
export class CallerIdAlreadyRegisteredError extends Error {
  override readonly name: string = "CallerIdAlreadyRegisteredError";
}
