import { env } from "cloudflare:workers";
import { expect } from "vitest";
import { randomId } from "../src/crypto";
import type { Env } from "../src/env";
import { type Harness, type Session, envWith, grantSubscription, req } from "./helpers";

/** A limiter that lets everything through (tests send more than a device does in a minute). */
export const allowingLimiter: RateLimit = {
  limit: async (): Promise<RateLimitOutcome> => ({ success: true }),
};

/** API Worker environment for assistant tests (no per-user limiter). */
export const assistantEnv: Env = envWith({ ASSISTANT_USER_LIMITER: allowingLimiter });

export const dayMs: number = 86_400_000;

/** Upload body fields; the note's summary and title are recognisable in logs. */
export interface UploadFields {
  readonly epoch: number;
  readonly deviceId: string;
  readonly title: string;
  readonly summary: string;
  readonly startedAt: string;
  readonly folder: string | null;
}

/** A complete upload body. */
export function upload(fields: UploadFields): object {
  return {
    epoch: fields.epoch,
    deviceId: fields.deviceId,
    title: fields.title,
    startedAt: fields.startedAt,
    durationSec: 1800,
    folder: fields.folder,
    attendees: ["Ada Lovelace"],
    language: "en",
    note: {
      title: fields.title,
      summary: fields.summary,
      decisions: ["Ship the beta"],
      tasks: [
        { owner: "Sen", description: `Follow up on ${fields.title}`, dueDate: "Friday", isMine: true, done: false },
        { owner: "Sen", description: `Archive ${fields.title}`, dueDate: null, isMine: true, done: true },
        { owner: "Ada", description: "Review the draft", dueDate: null, isMine: false, done: false },
      ],
      outline: [{ startSec: 0, title: "Opening", summary: "Agenda." }],
      glossary: [],
    },
    myNotes: "Private aside",
  };
}

/** A subscriber session. */
export async function subscriber(harness: Harness, session: Session): Promise<Session> {
  await grantSubscription(session.userId, "active", harness.clock.nowMs + 60 * dayMs);
  return session;
}

/** Settings body. */
export interface SettingsBody {
  readonly enabled: boolean;
  readonly epoch: number;
  readonly meetings: number;
}

export async function setAssistant(harness: Harness, session: Session, enabled: boolean): Promise<SettingsBody> {
  const response: Response = await harness.call(req("PUT", "/v1/assistant/settings", { token: session.accessToken, json: { enabled }, env: assistantEnv }));
  expect(response.status).toBe(200);
  return response.json<SettingsBody>();
}

/** Uploads one meeting and expects 200. */
export async function putMeeting(harness: Harness, session: Session, meetingId: string, fields: UploadFields): Promise<void> {
  const response: Response = await harness.call(req("PUT", `/v1/assistant/meetings/${meetingId}`, { token: session.accessToken, json: upload(fields), env: assistantEnv }));
  expect(response.status).toBe(200);
}

/** Default fields for a meeting upload. */
export function fieldsFor(epoch: number, title: string): UploadFields {
  return { epoch, deviceId: randomId(), title, summary: `${title} summary text`, startedAt: "2026-10-14T09:00:00+02:00", folder: null };
}

/** R2 keys under a prefix. */
export async function objectKeys(prefix: string): Promise<string[]> {
  return (await env.ASSISTANT_BUCKET.list({ prefix })).objects.map((object: R2Object): string => object.key);
}

/** Count of a user's rows in an EU table. */
export async function assistantRows(table: string, userId: string): Promise<number> {
  const row: { count: number } | null = await env.ASSISTANT_DB.prepare(`SELECT COUNT(*) AS count FROM ${table} WHERE user_id = ?`).bind(userId).first<{ count: number }>();
  return row?.count ?? -1;
}
