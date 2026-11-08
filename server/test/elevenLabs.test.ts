import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { parseConfig } from "../src/config";
import {
  type ElevenLabsSnapshot,
  billingCycleStart,
  crossedThreshold,
  dailyElevenLabsCapacityCheck,
  elevenLabsCapacityFreshMs,
  elevenLabsCapacityStaleMs,
  elevenLabsErrorCode,
  elevenLabsStaticLimit,
  elevenLabsSubscriptionUrl,
  elevenLabsUsage,
  liveRemainingSeconds,
} from "../src/elevenLabsCapacity";
import type { Env } from "../src/env";
import { remainingOf } from "../src/reservations";
import { elevenLabsSpeechToTextUrl, isElevenLabsQuotaRejection } from "../src/transcribe";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  elevenLabsSubscriptionBody,
  envWith,
  expectError,
  grantSubscription,
  req,
  signIn,
  wavFile,
} from "./helpers";

const dayMs: number = 86_400_000;

/** `console.error` satırlarında (alert ve error) bu olayı taşıyanlar. */
function events(spy: { mock: { calls: unknown[][] } }, event: string): string[] {
  return spy.mock.calls.map((call: unknown[]): string => String(call[0])).filter((line: string): boolean => line.includes(`"event":"${event}"`));
}

/** Saklı canlı okumayı `ms` kadar eskitir (saati ilerletmek erişim jetonunu da eskitirdi). */
async function ageSnapshot(ms: number): Promise<void> {
  await env.DB.prepare("UPDATE elevenlabs_capacity SET fetched_at = fetched_at - ?").bind(ms).run();
}

/** Abone, açık toplantı ve `seconds` saniyelik WAV gönderen yardımcı. */
async function subscriberMeeting(harness: Harness, target: Env): Promise<(seconds: number) => Promise<Response>> {
  const session: Session = await signIn(harness);
  await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * dayMs);
  const started: Response = await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: target }));
  expect(started.status).toBe(201);
  const meeting: StartedMeetingBody = await started.json<StartedMeetingBody>();
  return async (seconds: number): Promise<Response> => {
    const audio: Uint8Array = wavFile(8000, 1, 8, 8000 * seconds);
    return harness.call(
      req("POST", "/v1/transcribe", {
        token: session.accessToken,
        headers: { "x-meeting-id": meeting.meetingId, "content-type": "audio/wav", "content-length": String(audio.byteLength) },
        body: audio,
        env: target,
      }),
    );
  };
}

/** Başarılı ElevenLabs yanıtı veren sahte konuşma tanıma; çağrı sayısını döndürür. */
function stubSpeechToText(harness: Harness): { calls: number } {
  const counter: { calls: number } = { calls: 0 };
  harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
    counter.calls += 1;
    await request.arrayBuffer();
    return Response.json({ language_code: "tur", language_probability: 1, text: "", words: [], audio_duration_secs: null });
  });
  return counter;
}

/** Sahte abonelik ucu: yanıtı değiştirilebilir, çağrı sayısı tutulur. */
function stubSubscription(harness: Harness, initial: () => Response): { calls: number; respond: () => Response } {
  const state: { calls: number; respond: () => Response } = { calls: 0, respond: initial };
  harness.stub(elevenLabsSubscriptionUrl, async (): Promise<Response> => {
    state.calls += 1;
    return state.respond();
  });
  return state;
}

describe("ElevenLabs faturalama dönemi ve saf hesaplar", () => {
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

  it("canlı kalan: kalan kredi saate çevrilir, okumadan sonra yazılan ses düşülür, eksiye inmez", () => {
    const snapshot: ElevenLabsSnapshot = {
      creditsUsed: 14_443,
      creditsLimit: 258_500,
      resetsAtMs: null,
      status: "active",
      fetchedAtMs: 0,
      fetchDay: "2026-11-08",
      localSecondsAtFetch: 500,
    };
    // 244 057 kredi / 1080 kredi/saat ≈ 225,98 saat.
    expect(liveRemainingSeconds(snapshot, 500, 1080) / 3600).toBeCloseTo(225.98, 2);
    expect(liveRemainingSeconds(snapshot, 500 + 3600, 1080) / 3600).toBeCloseTo(224.98, 2);
    expect(liveRemainingSeconds({ ...snapshot, creditsUsed: 300_000 }, 500, 1080)).toBe(0);
  });

  it("kredi yokluğu reddi: 402 her zaman, 401 yalnızca quota_exceeded; hata kodu gövdeden okunur", () => {
    expect(isElevenLabsQuotaRejection(402, null)).toBe(true);
    expect(isElevenLabsQuotaRejection(401, "quota_exceeded")).toBe(true);
    expect(isElevenLabsQuotaRejection(401, "invalid_api_key")).toBe(false);
    expect(isElevenLabsQuotaRejection(429, null)).toBe(false);
    expect(elevenLabsErrorCode('{"detail":{"type":"payment_required","code":"insufficient_credits","message":"x"}}')).toBe("insufficient_credits");
    expect(elevenLabsErrorCode('{"detail":{"status":"quota_exceeded","message":"x"}}')).toBe("quota_exceeded");
    expect(elevenLabsErrorCode("<html>")).toBeNull();
    expect(elevenLabsErrorCode('{"detail":"Not found"}')).toBeNull();
  });
});

describe("ElevenLabs güvenlik üst sınırı", () => {
  it("ElevenLabs'e giden ses günlük sayaca yazılır; %80 ve %95 aşılınca alarm, günlük denetim eşik üstündeyken alarm yazar", async () => {
    const harness: Harness = await defaultHarness();
    // Dosyanın diğer günlerinden ayrı bir dönem: 2027-03-20, dönem 2027-03-11'de başlar.
    harness.clock.nowMs = Date.UTC(2027, 2, 20, 12);
    const now: Date = new Date(harness.clock.nowMs);
    // Plan 0,05 saat = 180 saniye; canlı kredi bol (varsayılan sahte abonelik): üst sınır geçerlidir.
    const small: Env = envWith({ ELEVENLABS_MONTHLY_AUDIO_HOURS: "0.05" });
    const config = parseConfig(small);
    await env.DB.prepare("INSERT INTO daily_spend (day, audio_seconds) VALUES (?, 140), (?, 1000)")
      .bind("2027-03-12", "2027-03-10")
      .run();
    expect(await elevenLabsUsage(env.DB, config, now)).toMatchObject({ cycleStart: "2027-03-11", usedHours: 0, capHours: 0.05, percent: 77.8 });

    const transcribe = await subscriberMeeting(harness, small);
    stubSpeechToText(harness);
    const alerts = vi.spyOn(console, "error");
    try {
      expect((await transcribe(10)).status).toBe(200);
      expect(events(alerts, "elevenlabs_capacity_threshold")).toHaveLength(1);
      expect(events(alerts, "elevenlabs_capacity_threshold")[0]).toContain('"threshold":0.8');
      expect((await transcribe(5)).status).toBe(200);
      expect(events(alerts, "elevenlabs_capacity_threshold")).toHaveLength(1);
      expect((await transcribe(19)).status).toBe(200);
      expect(events(alerts, "elevenlabs_capacity_threshold")).toHaveLength(2);
      expect(events(alerts, "elevenlabs_capacity_threshold")[1]).toContain('"threshold":0.95');
      // %97'yi aşacak istek ElevenLabs'e gitmeden anlaşılır 503 ile durur (kredi bitip sağlayıcıda düşmesin).
      await expectError(await transcribe(5), 503, "spend_ceiling_reached");
      expect(events(alerts, "elevenlabs_capacity_exhausted")).toHaveLength(1);

      const counted = await env.DB.prepare("SELECT audio_seconds FROM daily_spend WHERE day = '2027-03-20'").first<{ audio_seconds: number }>();
      expect(counted?.audio_seconds).toBe(34);
      expect((await dailyElevenLabsCapacityCheck(env.DB, harness.platform, config, now)).percent).toBe(96.7);
      expect(events(alerts, "elevenlabs_capacity_high")[0]).toContain('"threshold":0.95');
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
    await expectError(await reprocess(small), 503, "trial_capacity_reached");
    const row = await env.DB.prepare("SELECT reprocess_count FROM meeting_sessions WHERE id = ?").bind(meeting.meetingId).first<{ reprocess_count: number }>();
    expect(row?.reprocess_count).toBe(0);
    // Plan büyükken (durağın altında) aynı istek geçer.
    expect((await reprocess(env)).status).toBe(200);
  });

  it("üst sınır süren ses ayırmalarını da sayar: eşzamanlı yüklemeler aynı kalanı birlikte harcayamaz", async () => {
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
      const [before] = await remainingOf(env.DB, [elevenLabsStaticLimit(config, now)]);
      expect(before).toBeCloseTo(74.6, 5);
      await reservation("r_inflight", 30, nowMs + 600_000).run();
      const [after] = await remainingOf(env.DB, [elevenLabsStaticLimit(config, now)]);
      expect(after).toBeCloseTo(44.6, 5);
    } finally {
      await env.DB.prepare("DELETE FROM usage_reservations WHERE user_id = 'u_inflight'").run();
    }
  });
});

describe("ElevenLabs canlı kapasitesi", () => {
  it("canlı kalan kredi üst sınırdan darsa o geçerlidir; okumadan sonra yazılan ses düşülür ve istek ElevenLabs'e gitmeden durur", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2030, 2, 20, 12);
    await env.DB.prepare("DELETE FROM elevenlabs_capacity").run();
    // 1221 kredi / (1080 × 1,1) = 3700 sn; 3600 sn yedek düşülünce 100 sn kalır. Üst sınır (110 saat) çok geniş.
    const subscription = stubSubscription(harness, (): Response => Response.json(elevenLabsSubscriptionBody(100_000 - 1221, 100_000)));
    const transcribe = await subscriberMeeting(harness, env);
    const speech = stubSpeechToText(harness);
    const alerts = vi.spyOn(console, "error");
    try {
      expect((await transcribe(60)).status).toBe(200);
      expect(subscription.calls).toBe(1);
      // Okuma taze: yeniden okunmaz; 60 sn yazıldı, 40 sn kaldı.
      await expectError(await transcribe(60), 503, "spend_ceiling_reached");
      expect(subscription.calls).toBe(1);
      expect(speech.calls).toBe(1);
      expect(events(alerts, "elevenlabs_capacity_exhausted")[0]).toContain('"liveRemainingHours":');
      expect((await transcribe(30)).status).toBe(200);

      // Paket yüklendi: taze olmayan okuma yenilenir, istek geçer.
      subscription.respond = (): Response => Response.json(elevenLabsSubscriptionBody(0, 258_500));
      await ageSnapshot(elevenLabsCapacityFreshMs);
      expect((await transcribe(60)).status).toBe(200);
      expect(subscription.calls).toBe(2);
      const usage = await elevenLabsUsage(env.DB, parseConfig(env), new Date(harness.clock.nowMs));
      expect(usage.live).toMatchObject({ creditsUsed: 0, creditsLimit: 258_500, status: "active" });
      expect(usage.live?.remainingHours).toBeCloseTo(239.3, 1);
    } finally {
      alerts.mockRestore();
    }
  });

  it("okuma başarısızsa saklı değer 6 saate dek kullanılır (yeniden denemeli, alarmlı); daha eskiyse yeni ses ayırmaları durur", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2030, 5, 20, 12);
    await env.DB.prepare("DELETE FROM elevenlabs_capacity").run();
    const subscription = stubSubscription(harness, (): Response => Response.json(elevenLabsSubscriptionBody(0, 258_500)));
    const transcribe = await subscriberMeeting(harness, env);
    stubSpeechToText(harness);
    expect((await transcribe(10)).status).toBe(200);

    subscription.respond = (): Response => Response.json({ detail: { type: "internal_error", code: "internal_error" } }, { status: 500 });
    const alerts = vi.spyOn(console, "error");
    const warnings = vi.spyOn(console, "warn");
    try {
      await ageSnapshot(elevenLabsCapacityStaleMs - 60_000);
      const callsBefore: number = subscription.calls;
      expect((await transcribe(10)).status).toBe(200);
      // 3 deneme, her başarısız denemede uyarı.
      expect(subscription.calls - callsBefore).toBe(3);
      expect(events(warnings, "upstream_retry").filter((line: string): boolean => line.includes('"service":"elevenlabs_subscription"'))).toHaveLength(2);
      expect(events(alerts, "elevenlabs_capacity_refresh_failed")[0]).toContain('"status":500');

      await ageSnapshot(2 * 60_000);
      await expectError(await transcribe(10), 503, "spend_ceiling_reached");
      expect(events(alerts, "elevenlabs_capacity_unknown")[0]).toContain('"code":"internal_error"');
    } finally {
      alerts.mockRestore();
      warnings.mockRestore();
    }
  });

  it("hiç okunamamışsa (anahtarın izni eksik) ses ElevenLabs'e gitmez; alarm ElevenLabs'in hata kodunu taşır", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2030, 8, 20, 12);
    await env.DB.prepare("DELETE FROM elevenlabs_capacity").run();
    const transcribe = await subscriberMeeting(harness, env);
    const subscription = stubSubscription(harness, (): Response =>
      Response.json({ detail: { type: "authorization_error", code: "insufficient_permissions", message: "missing user_read" } }, { status: 403 }),
    );
    const speech = stubSpeechToText(harness);
    const alerts = vi.spyOn(console, "error");
    try {
      await expectError(await transcribe(10), 503, "spend_ceiling_reached");
      // 403 kalıcıdır: yeniden denenmez.
      expect(subscription.calls).toBe(1);
      expect(speech.calls).toBe(0);
      expect(events(alerts, "elevenlabs_capacity_unknown")[0]).toContain('"code":"insufficient_permissions"');
    } finally {
      alerts.mockRestore();
    }
  });

  it("ElevenLabs 402 verirse istemci 503 spend_ceiling_reached alır, alarm yazılır, kapasite tükenmiş işaretlenir ve ses sayılmaz", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2030, 10, 20, 12);
    await env.DB.prepare("DELETE FROM elevenlabs_capacity").run();
    // Hesap kredi bildiriyor ama ElevenLabs isteği yine de reddediyor (ör. anahtara konmuş kredi kotası).
    const subscription = stubSubscription(harness, (): Response => Response.json(elevenLabsSubscriptionBody(0, 258_500)));
    const transcribe = await subscriberMeeting(harness, env);
    let speechCalls: number = 0;
    harness.stub(elevenLabsSpeechToTextUrl, async (request: Request): Promise<Response> => {
      speechCalls += 1;
      await request.arrayBuffer();
      return Response.json({ detail: { type: "payment_required", code: "insufficient_credits", message: "Not enough credits." } }, { status: 402 });
    });
    const alerts = vi.spyOn(console, "error");
    try {
      const refused: Response = await transcribe(20);
      const body = await expectError(refused, 503, "spend_ceiling_reached");
      expect(body.error.message).toContain("recording is kept");
      expect(events(alerts, "elevenlabs_quota_exhausted")[0]).toContain('"code":"insufficient_credits"');
      const provider = await env.DB.prepare("SELECT count FROM ops_events WHERE kind = 'provider_error' AND detail = 'elevenlabs'").first<{ count: number }>();
      expect(provider?.count).toBe(1);
      const spend = await env.DB.prepare("SELECT audio_seconds FROM daily_spend WHERE day = '2030-11-20'").first<{ audio_seconds: number }>();
      expect(spend?.audio_seconds ?? 0).toBe(0);

      // Sonraki istek ElevenLabs'e gitmeden durur (okuma tükenmiş ve taze).
      await expectError(await transcribe(20), 503, "spend_ceiling_reached");
      expect(speechCalls).toBe(1);
      expect(subscription.calls).toBe(1);

      // Okuma bayatlayınca gerçek durum yeniden okunur.
      await ageSnapshot(elevenLabsCapacityFreshMs);
      await expectError(await transcribe(20), 503, "spend_ceiling_reached");
      expect(subscription.calls).toBe(2);
      expect(speechCalls).toBe(2);
    } finally {
      alerts.mockRestore();
    }
  });

  it("deneme toplantısı canlı kullanım %85'i geçince açılmaz; günlük denetim canlı okumayı tazeler ve eşik alarmı yazar", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2031, 2, 20, 12);
    await env.DB.prepare("DELETE FROM elevenlabs_capacity").run();
    // Dönemde 22 saat yazılmış, ElevenLabs 2160 kredi (2 saat) kaldığını bildiriyor: sınır min(110, 22 + 2) = 24 saat.
    await env.DB.prepare("INSERT INTO daily_spend (day, audio_seconds) VALUES ('2031-03-12', ?)").bind(22 * 3600).run();
    const subscription = stubSubscription(harness, (): Response => Response.json(elevenLabsSubscriptionBody(258_500 - 2160, 258_500)));
    const session: Session = await signIn(harness);
    await expectError(await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {} })), 503, "trial_capacity_reached");

    const alerts = vi.spyOn(console, "error");
    try {
      const usage = await dailyElevenLabsCapacityCheck(env.DB, harness.platform, parseConfig(env), new Date(harness.clock.nowMs));
      expect(subscription.calls).toBe(2);
      // 22 saat / (22 + 2 saat) ≈ %91,7.
      expect(usage.percent).toBe(91.7);
      expect(events(alerts, "elevenlabs_capacity_high")[0]).toContain('"threshold":0.8');
    } finally {
      alerts.mockRestore();
    }
  });

  it("günlük denetim ElevenLabs okunamazsa hata fırlatır (Cron adımı alarm yazar)", async () => {
    const harness: Harness = await defaultHarness();
    harness.clock.nowMs = Date.UTC(2031, 5, 20, 12);
    stubSubscription(harness, (): Response => new Response("bad gateway", { status: 502 }));
    await expect(dailyElevenLabsCapacityCheck(env.DB, harness.platform, parseConfig(env), new Date(harness.clock.nowMs))).rejects.toMatchObject({
      name: "ElevenLabsSubscriptionError",
      status: 502,
    });
  });

  it("eşiğin altındayken günlük denetim alarm yazmaz", async () => {
    const harness: Harness = await defaultHarness();
    const alerts = vi.spyOn(console, "error");
    try {
      expect((await dailyElevenLabsCapacityCheck(env.DB, harness.platform, parseConfig(envWith({})), new Date(Date.UTC(2032, 5, 20)))).percent).toBe(0);
      expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes("elevenlabs_capacity"))).toBe(false);
    } finally {
      alerts.mockRestore();
    }
  });
});
