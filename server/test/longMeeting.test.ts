import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { base64UrlEncode } from "../src/crypto";
import { deepgramGrantLimit, deepgramGrantsPerMeeting, deepgramTrialGrantsPerMeeting } from "../src/deepgram";
import type { Env } from "../src/env";
import { meetingNoteReserveTokens } from "../src/reservations";
import { elevenLabsSpeechToTextUrl } from "../src/transcribe";
import { isLoopbackStubUrl, stubbedUpstreamUrl, upstreamStubBase } from "../src/upstreamStub";
import { chunkOverlapAllowance } from "../src/usage";
import { reprocessAudioCap, reprocessTokenBudget, reprocessTopUpTokens } from "../src/meetings";
import { parseConfig } from "../src/config";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  envWith,
  expectError,
  grantSubscription,
  refreshed,
  req,
  signIn,
  startMeeting,
  wavFile,
} from "./helpers";

const anthropicUrl: string = "https://api.anthropic.com/v1/messages";

/** Sahte Anthropic yanıtı: verilen kullanım. */
function stubAnthropic(harness: Harness, inputTokens: number, outputTokens: number): { calls: number } {
  const counter: { calls: number } = { calls: 0 };
  harness.stub(anthropicUrl, async (): Promise<Response> => {
    counter.calls += 1;
    return Response.json({
      id: "msg_long",
      type: "message",
      role: "assistant",
      model: "claude-haiku-5-5",
      content: [{ type: "text", text: "{}" }],
      stop_reason: "end_turn",
      stop_sequence: null,
      usage: { input_tokens: inputTokens, output_tokens: outputTokens, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    });
  });
  return counter;
}

function llm(harness: Harness, session: Session, meetingId: string, purpose: string): Promise<Response> {
  return harness.call(
    req("POST", "/v1/llm/messages", {
      token: session.accessToken,
      headers: { "x-meeting-id": meetingId, "x-llm-purpose": purpose },
      json: { effort: "low", max_tokens: 1000, messages: [{ role: "user", content: "Toplantı notunu yaz." }] },
    }),
  );
}

async function meetingRow(meetingId: string): Promise<{ tokens_used: number; token_budget: number; audio_seconds: number; reprocess_count: number }> {
  const row = await env.DB.prepare("SELECT tokens_used, token_budget, audio_seconds, reprocess_count FROM meeting_sessions WHERE id = ?")
    .bind(meetingId)
    .first<{ tokens_used: number; token_budget: number; audio_seconds: number; reprocess_count: number }>();
  if (row === null) {
    throw new Error("toplantı yok");
  }
  return row;
}

async function subscriberMeeting(harness: Harness): Promise<{ session: Session; meeting: StartedMeetingBody }> {
  const session: Session = await signIn(harness);
  await grantSubscription(session.userId, "active", harness.clock.nowMs + 40 * 86_400_000);
  const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
  return { session, meeting };
}

describe("uzun toplantı: bütçe ve not payı", () => {
  it("4 saatlik abonelik toplantısının bütçesi ölçülen canlı çeviri hızına ve nota yeter", () => {
    const config = parseConfig(env);
    const liveTokensPerHour: number = 662_000;
    const noteTokens4h: number = 300_000;
    const reserve: number = meetingNoteReserveTokens(config.subscriberMeetingTokenBudget);
    expect(reserve).toBeGreaterThanOrEqual(noteTokens4h);
    expect(config.subscriberMeetingTokenBudget - reserve).toBeGreaterThanOrEqual((liveTokensPerHour * config.subscriberMaxMeetingMinutes) / 60);
    const trialReserve: number = meetingNoteReserveTokens(config.trialMeetingTokenBudget);
    expect(trialReserve).toBeGreaterThanOrEqual(100_000);
    expect(config.trialMeetingTokenBudget - trialReserve).toBeGreaterThanOrEqual((liveTokensPerHour * config.trialMaxMeetingMinutes) / 60);
    // Günlük sınır en uzun toplantının bütçesini taşır.
    expect(config.dailyTokenCap).toBeGreaterThanOrEqual(config.subscriberMeetingTokenBudget);
    // Yeniden açılan uzun toplantının payı 4 saatlik notu taşır; deneme toplantısı en az payı alır.
    expect(reprocessTopUpTokens(config, "subscription")).toBe(reserve);
    expect(reprocessTopUpTokens(config, "subscription")).toBeGreaterThan(noteTokens4h);
    expect(reprocessTopUpTokens(config, "trial")).toBe(reprocessTokenBudget);
  });

  it("canlı çağrılar nota ayrılan payı kullanamaz; not aynı toplantıda yazılır ve kullanım tam sayılır", async () => {
    const harness: Harness = await defaultHarness();
    stubAnthropic(harness, 300, 100);
    const { session, meeting } = await subscriberMeeting(harness);
    const reserve: number = meetingNoteReserveTokens(meeting.tokenBudget);
    // Canlı çeviri bütçenin nota ayrılmamış kısmını neredeyse bitirdi.
    const spent: number = meeting.tokenBudget - reserve - 500;
    await env.DB.prepare("UPDATE meeting_sessions SET tokens_used = ? WHERE id = ?").bind(spent, meeting.meetingId).run();
    await expectError(await llm(harness, session, meeting.meetingId, "live_translation"), 429, "meeting_budget_exhausted");
    await expectError(await llm(harness, session, meeting.meetingId, "missed_summary"), 429, "meeting_budget_exhausted");
    expect((await meetingRow(meeting.meetingId)).tokens_used).toBe(spent);
    await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: session.accessToken }));
    // Not ve parçaları payı kullanır.
    expect((await llm(harness, session, meeting.meetingId, "note_chunk")).status).toBe(200);
    expect((await llm(harness, session, meeting.meetingId, "note_overview")).status).toBe(200);
    expect((await meetingRow(meeting.meetingId)).tokens_used).toBe(spent + 2 * 400);
    const open = await env.DB.prepare("SELECT COUNT(*) AS count FROM usage_reservations WHERE meeting_id = ?").bind(meeting.meetingId).first<{ count: number }>();
    expect(open?.count).toBe(0);
  });
});

describe("uzun toplantı: işleme süresi", () => {
  it("not 32 dakika sonra istense de (iPhone askıya alındı) yazılır; yeniden işleme hakkı harcanmaz, kullanım bir kez sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const anthropic: { calls: number } = stubAnthropic(harness, 1200, 800);
    const { session, meeting } = await subscriberMeeting(harness);
    harness.clock.nowMs += 31 * 60_000;
    let current: Session = await refreshed(harness, session);
    await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: current.accessToken }));
    await env.DB.prepare("UPDATE meeting_sessions SET audio_seconds = 1745, tokens_used = 339000 WHERE id = ?").bind(meeting.meetingId).run();
    harness.clock.nowMs += 32 * 60_000;
    current = await refreshed(harness, current);
    expect((await llm(harness, current, meeting.meetingId, "note")).status).toBe(200);
    expect(anthropic.calls).toBe(1);
    const row = await meetingRow(meeting.meetingId);
    expect(row).toEqual({ tokens_used: 339_000 + 2000, token_budget: meeting.tokenBudget, audio_seconds: 1745, reprocess_count: 0 });
    // Kullanıcının günlük ve aylık satırları da yalnızca bu çağrıyı sayar.
    const daily = await env.DB.prepare("SELECT tokens_used FROM daily_usage WHERE user_id = ?").bind(current.userId).first<{ tokens_used: number }>();
    expect(daily?.tokens_used).toBe(2000);
  });

  it("son geçiş sesi bitişten 2 saat sonra yüklenebilir; aynı anahtarla tekrar faturalanmaz", async () => {
    const harness: Harness = await defaultHarness();
    let scribeCalls: number = 0;
    harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      scribeCalls += 1;
      await request.formData();
      return Response.json({ language_code: "fin", language_probability: 0.9, text: "Hei", words: [], audio_duration_secs: 2 });
    });
    const { session, meeting } = await subscriberMeeting(harness);
    await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: session.accessToken }));
    harness.clock.nowMs += 2 * 3_600_000;
    const current: Session = await refreshed(harness, session);
    const audio: Uint8Array = wavFile(16_000, 1, 16, 64_000);
    const key: string = base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
    const send = (): Promise<Response> =>
      harness.call(
        req("POST", "/v1/transcribe", {
          token: current.accessToken,
          headers: { "x-meeting-id": meeting.meetingId, "content-type": "audio/wav", "content-length": String(audio.byteLength), "x-upload-key": key },
          body: audio,
        }),
      );
    expect((await send()).status).toBe(200);
    expect((await send()).status).toBe(200);
    await harness.drain();
    expect(scribeCalls).toBe(1);
    expect((await meetingRow(meeting.meetingId)).audio_seconds).toBe(2);
    expect((await meetingRow(meeting.meetingId)).reprocess_count).toBe(0);
  });

  it("canlı metin jetonu bitmiş toplantıya işleme süresinde de verilmez", async () => {
    const harness: Harness = await defaultHarness();
    const { session, meeting } = await subscriberMeeting(harness);
    await harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/end`, { token: session.accessToken }));
    const deepgramOn: Env = envWith({ DEEPGRAM_POLICY: "on", DEEPGRAM_API_KEY: "test-deepgram-key-000000000" } as Partial<Env>);
    await expectError(
      await harness.call(req("POST", "/v1/live/deepgram-token", { token: session.accessToken, headers: { "x-meeting-id": meeting.meetingId }, env: deepgramOn })),
      403,
      "meeting_not_active",
    );
  });
});

describe("uzun toplantı: ses ve canlı metin sınırları", () => {
  it("4 saatlik kaydın 60 dakikalık, bir dakika örtüşen beş parçası toplantının ses hakkına sığar", () => {
    const maxSeconds: number = 240 * 60;
    const chunkSeconds: number = 3600;
    const overlapSeconds: number = 60;
    const starts: number[] = [];
    for (let start: number = 0; start < maxSeconds; start += chunkSeconds - overlapSeconds) {
      starts.push(start);
    }
    const written: number = starts.reduce((total: number, start: number): number => total + Math.min(chunkSeconds, maxSeconds - start), 0);
    expect(starts).toHaveLength(5);
    expect(written).toBeLessThanOrEqual(maxSeconds + chunkOverlapAllowance(maxSeconds));
    // Yeniden işlemede kaydın tamamı bir kez daha yazılabilir.
    const cap: number | null = reprocessAudioCap(written, maxSeconds, 0);
    expect(cap).not.toBeNull();
    expect((cap ?? 0) - written).toBeGreaterThanOrEqual(written);
  });

  it("canlı metin jetonu sınırı toplantının süresiyle büyür", () => {
    expect(deepgramGrantLimit("subscription", 0)).toBe(deepgramGrantsPerMeeting);
    expect(deepgramGrantLimit("subscription", 59 * 60_000)).toBe(deepgramGrantsPerMeeting);
    expect(deepgramGrantLimit("subscription", 3 * 3_600_000 + 1)).toBe(deepgramGrantsPerMeeting + 45);
    expect(deepgramGrantLimit("trial", 89 * 60_000)).toBe(deepgramTrialGrantsPerMeeting + 6);
    expect(deepgramGrantLimit("trial", -1)).toBe(deepgramTrialGrantsPerMeeting);
  });
});

describe("yerel uçtan uca denemenin sahte üst servisleri", () => {
  it("yalnızca geliştirmede ve geri döngü adresinde etkindir; üretimde ayar reddedilir", () => {
    expect(isLoopbackStubUrl("http://127.0.0.1:8798")).toBe(true);
    expect(isLoopbackStubUrl("http://localhost:8798/")).toBe(true);
    expect(isLoopbackStubUrl("https://127.0.0.1:8798")).toBe(false);
    expect(isLoopbackStubUrl("http://example.com:8798")).toBe(false);
    expect(isLoopbackStubUrl("http://127.0.0.1:8798/v1")).toBe(false);
    expect(upstreamStubBase(envWith({ UPSTREAM_STUB_URL: "http://127.0.0.1:8798/" }))).toBe("http://127.0.0.1:8798");
    expect(upstreamStubBase(envWith({ UPSTREAM_STUB_URL: "http://127.0.0.1:8798", ENVIRONMENT: "production" }))).toBeNull();
    expect(upstreamStubBase(envWith({}))).toBeNull();
    expect(stubbedUpstreamUrl("https://api.anthropic.com/v1/messages?beta=true", "http://127.0.0.1:8798")).toBe("http://127.0.0.1:8798/v1/messages?beta=true");
    expect(stubbedUpstreamUrl("https://api.elevenlabs.io/v1/speech-to-text", "http://127.0.0.1:8798")).toBe("http://127.0.0.1:8798/v1/speech-to-text");
    expect(stubbedUpstreamUrl("https://api.deepgram.com/v1/auth/grant", "http://127.0.0.1:8798")).toBe("https://api.deepgram.com/v1/auth/grant");
    expect(stubbedUpstreamUrl("https://api.anthropic.com.evil.test/v1", "http://127.0.0.1:8798")).toBe("https://api.anthropic.com.evil.test/v1");
    expect(() => parseConfig(envWith({ UPSTREAM_STUB_URL: "http://203.0.113.5:8798" }))).toThrow();
    expect(parseConfig(envWith({ UPSTREAM_STUB_URL: "http://127.0.0.1:8798" })).environment).toBe("development");
  });
});
