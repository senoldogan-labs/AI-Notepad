import type { PhoneCountry } from "./numbers";

/**
 * TwiML documents the voice provider runs for a dialer call (pure functions; the routes are in `calls.ts`).
 *
 * The caller's leg comes from the app (Voice SDK); `dialTwiml` bridges it to the destination with the user's verified
 * number as caller ID, the call's time limit, dual-channel recording from answer, and the recording notice: the
 * `<Number url>` document (`announcementTwiml`) plays to the person called after they answer and before the two sides
 * are connected, so nobody is recorded without hearing the notice first.
 */

/** Spoken recording notice per destination country, with its text-to-speech language. */
interface Announcement {
  readonly language: string;
  readonly text: string;
}

const announcements: Readonly<Record<PhoneCountry, Announcement>> = {
  US: { language: "en-US", text: "Hello. This call is recorded and transcribed by Gistsmith for the caller's notes." },
  CA: { language: "en-US", text: "Hello. This call is recorded and transcribed by Gistsmith for the caller's notes." },
  FI: { language: "fi-FI", text: "Hei. Tämä puhelu tallennetaan ja litteroidaan Gistsmithillä soittajan muistiinpanoja varten." },
  TR: { language: "tr-TR", text: "Merhaba. Bu görüşme, arayan kişinin notları için Gistsmith tarafından kaydediliyor ve yazıya dökülüyor." },
};

/** Escapes text for an XML attribute or element. Pure function. */
export function xmlEscape(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

const declaration: string = '<?xml version="1.0" encoding="UTF-8"?>';

/** The fields of a bridged call. */
export interface DialFields {
  readonly destination: string;
  readonly destinationCountry: PhoneCountry;
  readonly callerId: string;
  readonly timeLimitSeconds: number;
  /** Absolute URLs of this server's webhooks for this call. */
  readonly announcementUrl: string;
  readonly recordingCallbackUrl: string;
  readonly dialActionUrl: string;
}

/** Seconds the destination may ring before the call gives up. */
export const ringTimeoutSeconds: number = 45;

/**
 * Bridges the app's leg to the destination: `answerOnBridge` keeps the caller hearing ringback until the callee has
 * answered and heard the notice; `record-from-answer-dual` records the two sides on two channels. Pure function.
 */
export function dialTwiml(fields: DialFields): string {
  return [
    declaration,
    "<Response>",
    `<Dial callerId="${xmlEscape(fields.callerId)}" timeLimit="${fields.timeLimitSeconds}" timeout="${ringTimeoutSeconds}" answerOnBridge="true"`,
    ` record="record-from-answer-dual" recordingStatusCallback="${xmlEscape(fields.recordingCallbackUrl)}" recordingStatusCallbackEvent="completed"`,
    ` action="${xmlEscape(fields.dialActionUrl)}" method="POST">`,
    `<Number url="${xmlEscape(fields.announcementUrl)}" method="POST">${xmlEscape(fields.destination)}</Number>`,
    "</Dial>",
    "</Response>",
  ].join("");
}

/** The recording notice the callee hears before the call connects. Pure function. */
export function announcementTwiml(country: PhoneCountry): string {
  const announcement: Announcement = announcements[country];
  return `${declaration}<Response><Say language="${announcement.language}">${xmlEscape(announcement.text)}</Say></Response>`;
}

/** Ends the call (refused or finished). Pure function. */
export function hangupTwiml(): string {
  return `${declaration}<Response><Hangup/></Response>`;
}

/** An empty document (status callbacks expect a 2xx; Twilio ignores the body). Pure function. */
export function emptyTwiml(): string {
  return `${declaration}<Response/>`;
}

/** TwiML response. */
export function twimlResponse(body: string): Response {
  return new Response(body, { status: 200, headers: { "content-type": "text/xml; charset=utf-8" } });
}
