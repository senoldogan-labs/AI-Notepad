import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { deepgramGrantUrl } from "../src/deepgram";
import type { Env } from "../src/env";
import {
  type MeetingPauseColumns,
  creditedPauseMs,
  maxPausesPerMeeting,
  meetingBaseMs,
  meetingPauseState,
  meetingRecordedMs,
  openPauseCreditMs,
} from "../src/meetingPause";
import { meetingAudioLimit } from "../src/reservations";
import { elevenLabsSpeechToTextUrl } from "../src/transcribe";
import { chunkOverlapAllowance, monthlyUsage } from "../src/usage";
import { type Harness, type Session, type StartedMeetingBody, defaultHarness, envWith, expectError, refreshed, req, signIn, wavFile } from "./helpers";

/** Deneme toplantısının en çok süresi (yapılandırma: 90 dakika). */
const baseMs: number = 90 * 60_000;

interface PauseBody {
  readonly meetingId: string;
  readonly paused: boolean;
  readonly expiresAt: string;
  readonly pausedSeconds: number;
}

interface PauseRow {
  readonly max_ends_at: number;
  readonly paused_ms: number;
  readonly paused_at: number | null;
  readonly pause_extension_ms: number;
  readonly pause_count: number;
  readonly minutes: number | null;
  readonly ended_at: number | null;
}

/** Oturum: saat ilerletildiği için her istekten önce yenilenir (erişim jetonu 15 dakikada dolar). */
interface User {
  session: Session;
}

async function signedIn(harness: Harness): Promise<User> {
  return { session: await signIn(harness) };
}

async function token(harness: Harness, user: User): Promise<string> {
  user.session = await refreshed(harness, user.session);
  return user.session.accessToken;
}

async function open(harness: Harness, user: User): Promise<StartedMeetingBody> {
  const response: Response = await harness.call(req("POST", "/v1/meetings/start", { token: await token(harness, user), json: {} }));
  expect(response.status).toBe(201);
  return response.json<StartedMeetingBody>();
}

async function call(harness: Harness, user: User, meetingId: string, action: "pause" | "resume" | "end", testEnv: Env): Promise<Response> {
  return harness.call(req("POST", `/v1/meetings/${meetingId}/${action}`, { token: await token(harness, user), env: testEnv }));
}

async function ok(response: Response): Promise<PauseBody> {
  expect(response.status).toBe(200);
  return response.json<PauseBody>();
}

async function row(meetingId: string): Promise<PauseRow | null> {
  return env.DB.prepare("SELECT max_ends_at, paused_ms, paused_at, pause_extension_ms, pause_count, minutes, ended_at FROM meeting_sessions WHERE id = ?")
    .bind(meetingId)
    .first<PauseRow>();
}

async function audioRemaining(meetingId: string): Promise<number> {
  const limit = meetingAudioLimit(meetingId);
  const result = await env.DB.prepare(`SELECT ${limit.remainingSql} AS remaining`)
    .bind(...limit.binds)
    .first<{ remaining: number }>();
  return result?.remaining ?? -1;
}

describe("toplantı duraklatma", () => {
  it("duraklatılan süre kadar bitişi uzatır; tekrar duraklatma ve sürdürme değişmez", async () => {
    const harness: Harness = await defaultHarness();
    const session: User = await signedIn(harness);
    const meeting: StartedMeetingBody = await open(harness, session);
    const startMs: number = harness.clock.nowMs;
    // Duraklatılmamış toplantıyı sürdürmek bir şey yapmaz.
    expect(await ok(await call(harness, session, meeting.meetingId, "resume", env))).toEqual({
      meetingId: meeting.meetingId,
      paused: false,
      expiresAt: meeting.expiresAt,
      pausedSeconds: 0,
    });
    harness.clock.nowMs += 10 * 60_000;
    const paused: PauseBody = await ok(await call(harness, session, meeting.meetingId, "pause", env));
    // Süren duraklatmada bitiş tüm hak kadar ileride: süre duraklatmada dolmaz.
    expect(paused).toEqual({ meetingId: meeting.meetingId, paused: true, expiresAt: new Date(startMs + 2 * baseMs).toISOString(), pausedSeconds: 0 });
    harness.clock.nowMs += 5 * 60_000;
    expect((await ok(await call(harness, session, meeting.meetingId, "pause", env))).pausedSeconds).toBe(300);
    const resumed: PauseBody = await ok(await call(harness, session, meeting.meetingId, "resume", env));
    expect(resumed).toEqual({ meetingId: meeting.meetingId, paused: false, expiresAt: new Date(startMs + baseMs + 5 * 60_000).toISOString(), pausedSeconds: 300 });
    expect(await row(meeting.meetingId)).toMatchObject({ paused_ms: 300_000, paused_at: null, pause_extension_ms: 300_000, pause_count: 1 });
    // Ses hakkı taban süreye göredir (uzatma büyütmez).
    expect(await audioRemaining(meeting.meetingId)).toBeCloseTo(baseMs / 1000 + chunkOverlapAllowance(baseMs / 1000), 3);

    // Bitiş: dakika kaydedilen süredir (10 + 3 dk; 5 dk duraklatma düşülür).
    harness.clock.nowMs += 3 * 60_000;
    expect((await call(harness, session, meeting.meetingId, "end", env)).status).toBe(200);
    expect(await row(meeting.meetingId)).toMatchObject({ minutes: 13 });
    // Bitmiş toplantı duraklatılamaz; sürdürme durumu döndürür.
    await expectError(await call(harness, session, meeting.meetingId, "pause", env), 403, "meeting_not_active");
    expect((await ok(await call(harness, session, meeting.meetingId, "resume", env))).paused).toBe(false);
  });

  it("sayılan duraklatma taban süreyi geçmez; duraklatılmışken bitirme duraklatmayı sayar", async () => {
    const harness: Harness = await defaultHarness();
    const session: User = await signedIn(harness);
    const meeting: StartedMeetingBody = await open(harness, session);
    const startMs: number = harness.clock.nowMs;
    harness.clock.nowMs += 20 * 60_000;
    await ok(await call(harness, session, meeting.meetingId, "pause", env));
    // Taban süreden uzun duraklatma: en çok 90 dakika sayılır; toplantı en çok 2 × 90 dakikada biter.
    harness.clock.nowMs += 200 * 60_000;
    const resumed: PauseBody = await ok(await call(harness, session, meeting.meetingId, "resume", env));
    expect(resumed).toEqual({ meetingId: meeting.meetingId, paused: false, expiresAt: new Date(startMs + 2 * baseMs).toISOString(), pausedSeconds: 90 * 60 });
    await expectError(await call(harness, session, meeting.meetingId, "pause", env), 403, "meeting_not_active");

    const second: StartedMeetingBody = await open(harness, session);
    harness.clock.nowMs += 30 * 60_000;
    await ok(await call(harness, session, second.meetingId, "pause", env));
    harness.clock.nowMs += 15 * 60_000;
    expect((await call(harness, session, second.meetingId, "end", env)).status).toBe(200);
    expect(await row(second.meetingId)).toMatchObject({ minutes: 30, paused_ms: 15 * 60_000, paused_at: null, pause_extension_ms: 15 * 60_000 });
  });

  it("yeni toplantı başlayınca kapanan toplantının süren duraklatması sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: User = await signedIn(harness);
    const first: StartedMeetingBody = await open(harness, session);
    harness.clock.nowMs += 10 * 60_000;
    await ok(await call(harness, session, first.meetingId, "pause", env));
    harness.clock.nowMs += 7 * 60_000;
    await open(harness, session);
    expect(await row(first.meetingId)).toMatchObject({ minutes: 10, paused_ms: 7 * 60_000, paused_at: null });
  });

  it("aylık süre kaydedilen süreyi sayar; yazılan ses yine sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: User = await signedIn(harness);
    const meeting: StartedMeetingBody = await open(harness, session);
    harness.clock.nowMs += 10 * 60_000;
    await ok(await call(harness, session, meeting.meetingId, "pause", env));
    harness.clock.nowMs += 40 * 60_000;
    // Süren duraklatma da sayılmaz.
    expect((await monthlyUsage(env.DB, session.session.userId, new Date(harness.clock.nowMs))).meetingSeconds).toBe(600);
    await ok(await call(harness, session, meeting.meetingId, "resume", env));
    harness.clock.nowMs += 5 * 60_000;
    await call(harness, session, meeting.meetingId, "end", env);
    const usage = await monthlyUsage(env.DB, session.session.userId, new Date(harness.clock.nowMs));
    expect(usage.meetingSeconds).toBe(900);
    expect(usage.usedSeconds).toBe(900);
    // Duraklatmada yazıya dökülmüş ses (dürüst olmayan istemci) yine sayılır: toplantı başına süre ile sesin büyüğü.
    await env.DB.prepare("UPDATE meeting_sessions SET audio_seconds = 2400 WHERE id = ?").bind(meeting.meetingId).run();
    expect((await monthlyUsage(env.DB, session.session.userId, new Date(harness.clock.nowMs))).usedSeconds).toBeGreaterThan(2000);
  });

  it("başkasının toplantısı bulunamaz; sonradan işlenen kayıt duraklatılamaz", async () => {
    const harness: Harness = await defaultHarness();
    const session: User = await signedIn(harness);
    const other: User = await signedIn(harness);
    const meeting: StartedMeetingBody = await open(harness, session);
    await expectError(await call(harness, other, meeting.meetingId, "pause", env), 404, "not_found");
    await expectError(await call(harness, other, meeting.meetingId, "resume", env), 404, "not_found");
    const deferred: Response = await harness.call(
      req("POST", "/v1/meetings/start", { token: await token(harness, session), json: { clientRef: "ertelenen-kayit", deferred: true } }),
    );
    expect(deferred.status).toBe(201);
    const deferredId: string = (await deferred.json<StartedMeetingBody>()).meetingId;
    await expectError(await call(harness, session, deferredId, "pause", env), 403, "meeting_not_active");
  });

  it("duraklatma sayısı sınırlıdır", async () => {
    const harness: Harness = await defaultHarness();
    const session: User = await signedIn(harness);
    const meeting: StartedMeetingBody = await open(harness, session);
    await env.DB.prepare("UPDATE meeting_sessions SET pause_count = ? WHERE id = ?").bind(maxPausesPerMeeting, meeting.meetingId).run();
    await expectError(await call(harness, session, meeting.meetingId, "pause", env), 409, "pause_limit_reached");
  });

  it("duraklatmada Deepgram jetonu ya da ses yüklemesi duraklatmayı o anda kapatır", async () => {
    const allowing: RateLimit = { limit: async (): Promise<RateLimitOutcome> => ({ success: true }) };
    const deepgramOn: Env = envWith({ DEEPGRAM_POLICY: "on", DEEPGRAM_API_KEY: "test-deepgram-key-000000", DEEPGRAM_USER_LIMITER: allowing });
    const harness: Harness = await defaultHarness();
    harness.stub(deepgramGrantUrl, async (): Promise<Response> => Response.json({ access_token: "eyJ.sahte.jwt", expires_in: 30 }));
    harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      await request.formData();
      return Response.json({ language_code: "tur", language_probability: 0.9, text: "", words: [], audio_duration_secs: 2 });
    });
    const session: User = await signedIn(harness);
    const meeting: StartedMeetingBody = await open(harness, session);
    harness.clock.nowMs += 60_000;
    await ok(await call(harness, session, meeting.meetingId, "pause", deepgramOn));
    harness.clock.nowMs += 2 * 60_000;
    const grant: Response = await harness.call(
      req("POST", "/v1/live/deepgram-token", { token: await token(harness, session), headers: { "x-meeting-id": meeting.meetingId }, env: deepgramOn }),
    );
    expect(grant.status).toBe(200);
    expect(await row(meeting.meetingId)).toMatchObject({ paused_ms: 120_000, paused_at: null, pause_extension_ms: 120_000 });

    harness.clock.nowMs += 60_000;
    await ok(await call(harness, session, meeting.meetingId, "pause", deepgramOn));
    harness.clock.nowMs += 60_000;
    const audio: Uint8Array = wavFile(16_000, 1, 16, 64_000);
    const uploaded: Response = await harness.call(
      req("POST", "/v1/transcribe", {
        token: await token(harness, session),
        headers: { "x-meeting-id": meeting.meetingId, "content-type": "audio/wav", "content-length": String(audio.byteLength) },
        body: audio,
      }),
    );
    expect(uploaded.status).toBe(200);
    expect(await row(meeting.meetingId)).toMatchObject({ paused_ms: 180_000, paused_at: null, pause_count: 2 });
  });
});

describe("duraklatma saf fonksiyonları", () => {
  const base: MeetingPauseColumns = { started_at: 0, max_ends_at: 60_000, ended_at: null, paused_ms: 0, paused_at: null, pause_extension_ms: 0 };

  it("süren duraklatmanın sayılan kısmı kalan hakla sınırlıdır", () => {
    // 10 sn'de duraklatıldı; hak 60 sn (taban süre) → bitiş 120 sn.
    const paused: MeetingPauseColumns = { ...base, paused_at: 10_000, max_ends_at: 120_000, pause_extension_ms: 60_000 };
    expect(openPauseCreditMs(paused, 30_000)).toBe(20_000);
    expect(openPauseCreditMs(paused, 500_000)).toBe(60_000);
    expect(creditedPauseMs(paused, 30_000)).toBe(20_000);
    expect(meetingRecordedMs(paused, 30_000)).toBe(10_000);
    expect(meetingBaseMs(paused)).toBe(60_000);
    expect(meetingPauseState({ ...paused, id: "m", deferred: 0 }, 30_000)).toEqual({ meetingId: "m", paused: true, expiresAt: new Date(120_000).toISOString(), pausedSeconds: 20 });
    // Süresi geçmiş toplantı duraklatılmış görünmez.
    expect(meetingPauseState({ ...paused, id: "m", deferred: 0 }, 120_000).paused).toBe(false);
  });

  it("kapanmış duraklatmalar düşülür; bitmiş toplantı bitişinde durur", () => {
    const resumed: MeetingPauseColumns = { ...base, max_ends_at: 75_000, paused_ms: 15_000, pause_extension_ms: 15_000, ended_at: 50_000 };
    expect(meetingRecordedMs(resumed, 1_000_000)).toBe(35_000);
    expect(meetingBaseMs(resumed)).toBe(60_000);
    expect(meetingRecordedMs(base, 30_000)).toBe(30_000);
  });
});
