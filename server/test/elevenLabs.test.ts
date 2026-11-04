import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { parseConfig } from "../src/config";
import { billingCycleStart, crossedThreshold, dailyElevenLabsCapacityCheck, elevenLabsUsage, requireElevenLabsHeadroom } from "../src/elevenLabsCapacity";
import type { Env } from "../src/env";
import { elevenLabsSpeechToTextUrl } from "../src/transcribe";
import { type Harness, type Session, type StartedMeetingBody, defaultHarness, envWith, grantSubscription, req, signIn, wavFile } from "./helpers";

const dayMs: number = 86_400_000;

describe("ElevenLabs faturalama dönemi", () => {
  it("dönem ayın faturalama gününde başlar; o günden önce önceki ayın günüdür", () => {
    expect(billingCycleStart(new Date(Date.UTC(2026, 9, 15, 12)), 11)).toBe("2026-10-11");
    expect(billingCycleStart(new Date(Date.UTC(2026, 9, 11, 0)), 11)).toBe("2026-10-11");
    expect(billingCycleStart(new Date(Date.UTC(2026, 9, 10, 23)), 11)).toBe("2026-09-11");
    expect(billingCycleStart(new Date(Date.UTC(2027, 0, 5)), 11)).toBe("2026-12-11");
  });

  it("eşik yalnızca aşıldığı kesinleştirmede döner (en yüksek aşılan)", () => {
    expect(crossedThreshold(70, 79, 100)).toBeNull();
    expect(crossedThreshold(79, 80, 100)).toBe(0.8);
    expect(crossedThreshold(80, 90, 100)).toBeNull();
    expect(crossedThreshold(90, 96, 100)).toBe(0.95);
    expect(crossedThreshold(70, 99, 100)).toBe(0.95);
  });
});

describe("ElevenLabs kapasite sayacı", () => {
  it("ElevenLabs'e giden ses günlük sayaca yazılır; %80 ve %95 aşılınca alarm, günlük denetim eşik üstündeyken alarm yazar", async () => {
    const harness: Harness = await defaultHarness();
    // Dosyanın diğer günlerinden ayrı bir dönem: 2027-03-20, dönem 2027-03-11'de başlar.
    harness.clock.nowMs = Date.UTC(2027, 2, 20, 12);
    const now: Date = new Date(harness.clock.nowMs);
    // Plan 0,05 saat = 180 saniye.
    const small: Env = envWith({ ELEVENLABS_MONTHLY_AUDIO_HOURS: "0.05" });
    const config = parseConfig(small);
    await env.DB.prepare("INSERT INTO daily_spend (day, audio_seconds) VALUES (?, 140), (?, 1000)")
      .bind("2027-03-12", "2027-03-10")
      .run();
    expect(await elevenLabsUsage(env.DB, config, now)).toEqual({ cycleStart: "2027-03-11", usedHours: 0, capHours: 0.05, percent: 77.8 });

    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * dayMs);
    const meeting: StartedMeetingBody = await (await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: small }))).json<StartedMeetingBody>();
    harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      await request.arrayBuffer();
      return Response.json({ language_code: "tur", language_probability: 1, text: "", words: [], audio_duration_secs: null });
    });
    const transcribe = async (seconds: number): Promise<number> => {
      const audio: Uint8Array = wavFile(8000, 1, 8, 8000 * seconds);
      const response: Response = await harness.call(
        req("POST", "/v1/transcribe", {
          token: session.accessToken,
          headers: { "x-meeting-id": meeting.meetingId, "content-type": "audio/wav", "content-length": String(audio.byteLength) },
          body: audio,
          env: small,
        }),
      );
      return response.status;
    };
    const alerts = vi.spyOn(console, "error");
    const crossings = (): string[] =>
      alerts.mock.calls.map((call: unknown[]): string => String(call[0])).filter((line: string): boolean => line.includes('"event":"elevenlabs_capacity_threshold"'));
    try {
      expect(await transcribe(10)).toBe(200);
      expect(crossings()).toHaveLength(1);
      expect(crossings()[0]).toContain('"threshold":0.8');
      expect(await transcribe(5)).toBe(200);
      expect(crossings()).toHaveLength(1);
      expect(await transcribe(19)).toBe(200);
      expect(crossings()).toHaveLength(2);
      expect(crossings()[1]).toContain('"threshold":0.95');
      // %97'yi aşacak istek ElevenLabs'e gitmeden anlaşılır 503 ile durur (kredi bitip sağlayıcıda düşmesin).
      expect(await transcribe(5)).toBe(503);
      expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"elevenlabs_capacity_exhausted"'))).toBe(true);

      const counted = await env.DB.prepare("SELECT audio_seconds FROM daily_spend WHERE day = '2027-03-20'").first<{ audio_seconds: number }>();
      expect(counted?.audio_seconds).toBe(34);
      expect((await dailyElevenLabsCapacityCheck(env.DB, config, now)).percent).toBe(96.7);
      expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"elevenlabs_capacity_high","threshold":0.95'))).toBe(true);
    } finally {
      alerts.mockRestore();
    }
  });

  it("deneme toplantısının yeniden işlenmesi ElevenLabs deneme durağında hak harcanmadan 503 alır", async () => {
    const harness: Harness = await defaultHarness();
    // Dosyanın diğer günlerinden ayrı bir dönem: 2027-08-20, dönem 2027-08-11'de başlar.
    harness.clock.nowMs = Date.UTC(2027, 7, 20, 12);
    // Plan 0,05 saat = 180 saniye; deneme durağı %85 = 153 saniye.
    const small: Env = envWith({ ELEVENLABS_MONTHLY_AUDIO_HOURS: "0.05" });
    const session: Session = await signIn(harness);
    const started: Response = await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: small }));
    expect(started.status).toBe(201);
    const meeting: StartedMeetingBody = await started.json<StartedMeetingBody>();
    expect(meeting.kind).toBe("trial");
    // Toplantı bitti ve sesi yazıldı; sonra dönemin kullanımı deneme durağını geçti.
    await env.DB.batch([
      env.DB.prepare("UPDATE meeting_sessions SET ended_at = ?, end_reason = 'ended', audio_seconds = 60 WHERE id = ?").bind(
        harness.clock.nowMs - 2 * 3_600_000,
        meeting.meetingId,
      ),
      env.DB.prepare("INSERT INTO daily_spend (day, audio_seconds) VALUES ('2027-08-15', 160)"),
    ]);
    const reprocess = (target: Env): Promise<Response> =>
      harness.call(req("POST", `/v1/meetings/${meeting.meetingId}/reprocess`, { token: session.accessToken, env: target }));
    const refused: Response = await reprocess(small);
    expect(refused.status).toBe(503);
    expect((await refused.json<{ error: { code: string } }>()).error.code).toBe("trial_capacity_reached");
    const row = await env.DB.prepare("SELECT reprocess_count FROM meeting_sessions WHERE id = ?").bind(meeting.meetingId).first<{ reprocess_count: number }>();
    expect(row?.reprocess_count).toBe(0);
    // Plan büyükken (durağın altında) aynı istek geçer.
    expect((await reprocess(env)).status).toBe(200);
  });

  it("sert durak süren ses ayırmalarını da sayar: eşzamanlı yüklemeler aynı kalanı birlikte harcayamaz", async () => {
    // Dosyanın diğer günlerinden ayrı bir dönem: 2029-02-20, dönem 2029-02-11'de başlar. Plan 0,05 saat = 180 saniye;
    // sert durak %97 = 174,6 saniye.
    const config = parseConfig(envWith({ ELEVENLABS_MONTHLY_AUDIO_HOURS: "0.05" }));
    const nowMs: number = Date.UTC(2029, 1, 20, 12);
    const now: Date = new Date(nowMs);
    const reservation = (id: string, seconds: number, expiresAt: number): D1PreparedStatement =>
      env.DB.prepare(
        `INSERT INTO usage_reservations (id, user_id, meeting_id, kind, month, day, tokens, trial_account_tokens, account_tokens,
           audio_seconds, estimated_micro_usd, trial_spend, created_at, expires_at)
         VALUES (?, 'u_inflight', 'm_inflight', 'audio', '2029-02', '2029-02-20', 0, 0, 0, ?, 0, 0, ?, ?)`,
      ).bind(id, seconds, nowMs - 60_000, expiresAt);
    await env.DB.batch([
      env.DB.prepare("INSERT INTO daily_spend (day, audio_seconds) VALUES ('2029-02-15', 100)"),
      // Süresi dolmuş ayırma (Worker kesinleştiremeden durdu) sayılmaz.
      reservation("r_expired", 1000, nowMs),
    ]);
    try {
      await requireElevenLabsHeadroom(env.DB, config, 60, now);
      await reservation("r_inflight", 30, nowMs + 600_000).run();
      await expect(requireElevenLabsHeadroom(env.DB, config, 60, now)).rejects.toMatchObject({ code: "spend_ceiling_reached" });
      await requireElevenLabsHeadroom(env.DB, config, 40, now);
    } finally {
      await env.DB.prepare("DELETE FROM usage_reservations WHERE user_id = 'u_inflight'").run();
    }
  });

  it("eşiğin altındayken günlük denetim alarm yazmaz", async () => {
    const config = parseConfig(envWith({}));
    const alerts = vi.spyOn(console, "error");
    try {
      expect((await dailyElevenLabsCapacityCheck(env.DB, config, new Date(Date.UTC(2028, 5, 20)))).percent).toBe(0);
      expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes("elevenlabs_capacity"))).toBe(false);
    } finally {
      alerts.mockRestore();
    }
  });
});
