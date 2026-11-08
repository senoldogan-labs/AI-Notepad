import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { deepgramGrantUrl } from "../src/deepgram";
import type { Env } from "../src/env";
import {
  type MeetingEvent,
  type MeetingPhase,
  type MeetingPhaseColumns,
  type MeetingTransition,
  MeetingStateError,
  meetingPhase,
  meetingPhaseSql,
  meetingTransition,
  meetingTransitions,
} from "../src/meetingLifecycle";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  envWith,
  expectError,
  refreshed,
  req,
  signIn,
  startMeeting,
} from "./helpers";

const allowingLimiter: RateLimit = {
  limit: async (): Promise<RateLimitOutcome> => ({ success: true }),
};

/** Deepgram açık; sahte anahtar. */
const deepgramOn: Env = envWith({ DEEPGRAM_POLICY: "on", DEEPGRAM_API_KEY: "test-deepgram-key-000000", DEEPGRAM_USER_LIMITER: allowingLimiter });

const nowMs: number = 1_800_000_000_000;

function columns(fields: Partial<MeetingPhaseColumns>): MeetingPhaseColumns {
  return { max_ends_at: nowMs + 60_000, ended_at: null, deferred: 0, paused_at: null, ...fields };
}

const phaseCases: readonly { readonly row: MeetingPhaseColumns; readonly phase: MeetingPhase }[] = [
  { row: columns({}), phase: "recording" },
  { row: columns({ paused_at: nowMs - 1000 }), phase: "paused" },
  { row: columns({ max_ends_at: nowMs }), phase: "expired" },
  { row: columns({ max_ends_at: nowMs - 1, paused_at: nowMs - 1000 }), phase: "expired" },
  { row: columns({ ended_at: nowMs - 1000 }), phase: "ended" },
  { row: columns({ ended_at: nowMs - 1000, deferred: 1 }), phase: "ended" },
];

interface MeetingSnapshot {
  readonly reprocess_count: number;
  readonly token_budget: number;
  readonly reprocess_until: number | null;
}

async function snapshot(meetingId: string): Promise<MeetingSnapshot | null> {
  return env.DB.prepare("SELECT reprocess_count, token_budget, reprocess_until FROM meeting_sessions WHERE id = ?")
    .bind(meetingId)
    .first<MeetingSnapshot>();
}

async function openMeeting(harness: Harness, session: Session): Promise<string> {
  const response: Response = await startMeeting(harness, session);
  expect(response.status).toBe(201);
  return (await response.json<StartedMeetingBody>()).meetingId;
}

function call(harness: Harness, session: Session, path: string, testEnv: Env | null): Promise<Response> {
  return harness.call(req("POST", path, { token: session.accessToken, env: testEnv }));
}

function tokenRequest(harness: Harness, session: Session, meetingId: string): Promise<Response> {
  return harness.call(req("POST", "/v1/live/deepgram-token", { token: session.accessToken, headers: { "x-meeting-id": meetingId }, env: deepgramOn }));
}

describe("meeting lifecycle (pure)", () => {
  it.each(phaseCases)("derives $phase in TS and SQL", async ({ row, phase }) => {
    expect(meetingPhase(row, nowMs)).toBe(phase);
    const sql: { phase: string } | null = await env.DB.prepare(
      `WITH m(max_ends_at, ended_at, deferred, paused_at) AS (VALUES (?1, ?2, ?3, ?4)) SELECT ${meetingPhaseSql("m.", "?5")} AS phase FROM m`,
    )
      .bind(row.max_ends_at, row.ended_at, row.deferred, row.paused_at, nowMs)
      .first<{ phase: string }>();
    expect(sql?.phase).toBe(phase);
  });

  it("refuses contradictory rows", () => {
    expect(() => meetingPhase(columns({ ended_at: nowMs - 1000, paused_at: nowMs - 2000 }), nowMs)).toThrow(MeetingStateError);
    expect(() => meetingPhase(columns({ deferred: 1 }), nowMs)).toThrow(MeetingStateError);
  });

  it("pins the outcome of every event in every phase", () => {
    const expected: Readonly<Record<MeetingEvent, Readonly<Record<MeetingPhase, MeetingTransition>>>> = {
      pause: { recording: "apply", paused: "noop", expired: "refuse", ended: "refuse" },
      resume: { recording: "noop", paused: "apply", expired: "noop", ended: "noop" },
      closePauseForAudio: { recording: "noop", paused: "apply", expired: "noop", ended: "noop" },
      end: { recording: "apply", paused: "apply", expired: "apply", ended: "noop" },
      supersede: { recording: "apply", paused: "apply", expired: "apply", ended: "noop" },
      reprocess: { recording: "refuse", paused: "refuse", expired: "apply", ended: "apply" },
      liveGrant: { recording: "apply", paused: "apply", expired: "refuse", ended: "refuse" },
    };
    for (const event of Object.keys(meetingTransitions) as MeetingEvent[]) {
      for (const phase of Object.keys(expected[event]) as MeetingPhase[]) {
        expect([event, phase, meetingTransition(phase, event)]).toEqual([event, phase, expected[event][phase]]);
      }
    }
  });
});

describe("meeting lifecycle (bad orderings)", () => {
  it("reprocess on a live meeting is refused without spending a right or lowering its budget", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    await expectError(await call(harness, session, `/v1/meetings/${meetingId}/reprocess`, null), 409, "meeting_in_progress");
    // Long meetings upload audio while recording: the live meeting already has written audio.
    await env.DB.prepare("UPDATE meeting_sessions SET audio_seconds = 120, tokens_used = 5000 WHERE id = ?").bind(meetingId).run();
    const before: MeetingSnapshot | null = await snapshot(meetingId);
    await expectError(await call(harness, session, `/v1/meetings/${meetingId}/reprocess`, null), 409, "meeting_in_progress");
    harness.clock.nowMs += 60_000;
    await call(harness, session, `/v1/meetings/${meetingId}/pause`, null);
    await expectError(await call(harness, session, `/v1/meetings/${meetingId}/reprocess`, null), 409, "meeting_in_progress");
    expect(await snapshot(meetingId)).toEqual(before);

    // Once ended it can be reprocessed.
    expect((await call(harness, session, `/v1/meetings/${meetingId}/end`, null)).status).toBe(200);
    harness.clock.nowMs += 2 * 86_400_000;
    const later: Session = await refreshed(harness, session);
    expect((await call(harness, later, `/v1/meetings/${meetingId}/reprocess`, null)).status).toBe(200);
    expect((await snapshot(meetingId))?.reprocess_count).toBe(1);
  });

  it("reprocess on a meeting whose audio was closed keeps the right", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    expect((await call(harness, session, `/v1/meetings/${meetingId}/end`, null)).status).toBe(200);
    await env.DB.prepare("UPDATE meeting_sessions SET audio_seconds = 120, transcription_closed = 1 WHERE id = ?").bind(meetingId).run();
    harness.clock.nowMs += 2 * 86_400_000;
    const later: Session = await refreshed(harness, session);
    await expectError(await call(harness, later, `/v1/meetings/${meetingId}/reprocess`, null), 403, "transcription_closed");
    expect((await snapshot(meetingId))?.reprocess_count).toBe(0);
  });

  it("ending twice keeps the first end; a paused meeting past its limit does not look paused and cannot be paused", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    harness.clock.nowMs += 60_000;
    expect((await call(harness, session, `/v1/meetings/${meetingId}/pause`, null)).status).toBe(200);
    // The pause outlives its whole allowance: the meeting is expired, not paused.
    harness.clock.nowMs += 30 * 86_400_000;
    const later: Session = await refreshed(harness, session);
    const resumed: Response = await call(harness, later, `/v1/meetings/${meetingId}/resume`, null);
    expect(resumed.status).toBe(200);
    expect((await resumed.json<{ paused: boolean }>()).paused).toBe(false);
    await expectError(await call(harness, later, `/v1/meetings/${meetingId}/pause`, null), 403, "meeting_not_active");

    const first: Response = await call(harness, later, `/v1/meetings/${meetingId}/end`, null);
    const endedAt: { ended_at: number; paused_at: number | null } | null = await env.DB.prepare("SELECT ended_at, paused_at FROM meeting_sessions WHERE id = ?")
      .bind(meetingId)
      .first<{ ended_at: number; paused_at: number | null }>();
    expect(endedAt?.paused_at).toBeNull();
    harness.clock.nowMs += 60_000;
    const second: Response = await call(harness, later, `/v1/meetings/${meetingId}/end`, null);
    expect(await second.json()).toEqual(await first.json());
    const after: { ended_at: number } | null = await env.DB.prepare("SELECT ended_at FROM meeting_sessions WHERE id = ?").bind(meetingId).first<{ ended_at: number }>();
    expect(after?.ended_at).toBe(endedAt?.ended_at);
  });

  it("a Deepgram grant raced by the meeting's end is not written (first grant)", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    // The user ends the meeting while the server is fetching the Deepgram token.
    harness.stub(deepgramGrantUrl, async (): Promise<Response> => {
      expect((await call(harness, session, `/v1/meetings/${meetingId}/end`, null)).status).toBe(200);
      return Response.json({ access_token: "eyJ.sahte.jwt", expires_in: 30 });
    });
    await expectError(await tokenRequest(harness, session, meetingId), 403, "meeting_not_active");
    const row: { grants: number } | null = await env.DB.prepare("SELECT grants FROM deepgram_live_meetings WHERE meeting_id = ?").bind(meetingId).first<{ grants: number }>();
    expect(row).toBeNull();
  });

  it("a Deepgram grant raced by the meeting's end does not count on the settled estimate (later grant)", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meetingId: string = await openMeeting(harness, session);
    let endDuringFetch: boolean = false;
    harness.stub(deepgramGrantUrl, async (): Promise<Response> => {
      if (endDuringFetch) {
        expect((await call(harness, session, `/v1/meetings/${meetingId}/end`, null)).status).toBe(200);
      }
      return Response.json({ access_token: "eyJ.sahte.jwt", expires_in: 30 });
    });
    expect((await tokenRequest(harness, session, meetingId)).status).toBe(200);
    harness.clock.nowMs += 60_000;
    endDuringFetch = true;
    await expectError(await tokenRequest(harness, session, meetingId), 403, "meeting_not_active");
    const row: { grants: number; settled_at: number | null } | null = await env.DB.prepare(
      "SELECT grants, settled_at FROM deepgram_live_meetings WHERE meeting_id = ?",
    )
      .bind(meetingId)
      .first<{ grants: number; settled_at: number | null }>();
    expect(row?.grants).toBe(1);
    expect(row?.settled_at).not.toBeNull();
  });

  it("the database refuses reopening an ended meeting, pausing it, ending without a reason and granting after settle", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const open: string = await openMeeting(harness, session);
    await expect(env.DB.prepare("UPDATE meeting_sessions SET ended_at = ? WHERE id = ?").bind(harness.clock.nowMs, open).run()).rejects.toThrow(
      /end_reason/,
    );
    expect((await call(harness, session, `/v1/meetings/${open}/end`, null)).status).toBe(200);
    await expect(env.DB.prepare("UPDATE meeting_sessions SET ended_at = NULL, end_reason = NULL WHERE id = ?").bind(open).run()).rejects.toThrow(
      /reopened/,
    );
    await expect(env.DB.prepare("UPDATE meeting_sessions SET paused_at = ? WHERE id = ?").bind(harness.clock.nowMs, open).run()).rejects.toThrow(
      /cannot be paused/,
    );
    await env.DB.prepare(
      "INSERT INTO deepgram_live_meetings (meeting_id, grants, first_grant_at, charged_seconds, settled_at, window_started_at, window_grants) VALUES (?1, 1, ?2, 0, ?2, ?2, 1)",
    )
      .bind(open, harness.clock.nowMs)
      .run();
    await expect(env.DB.prepare("UPDATE deepgram_live_meetings SET grants = grants + 1 WHERE meeting_id = ?").bind(open).run()).rejects.toThrow(
      /settled/,
    );
  });
});
