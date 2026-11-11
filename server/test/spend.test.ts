import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { type Config, parseConfig } from "../src/config";
import { ApiError } from "../src/errors";
import {
  type UsageReservation,
  audioReservation,
  expiredReservationStatements,
  llmReservation,
  meetingAudioLimit,
  meetingTokenLimit,
  reserveUsage,
  settleAudioStatements,
  settleLLMStatements,
  spendCeilingChecks,
} from "../src/reservations";
import {
  type Harness,
  type Session,
  type StartedMeetingBody,
  defaultHarness,
  expectError,
  grantSubscription,
  req,
  signIn,
  startMeeting,
} from "./helpers";
import { stubStripeApi } from "./stripeFake";

/** 1000 girdi + 1000 çıktı tokenlık (600 mikro dolar) Haiku yanıtı. */
function stubHaiku(harness: Harness): void {
  harness.stub("https://api.anthropic.com/v1/messages", async (): Promise<Response> =>
    Response.json({
      id: "msg_1",
      type: "message",
      role: "assistant",
      model: "claude-haiku-5-5",
      content: [{ type: "text", text: "ok" }],
      stop_reason: "end_turn",
      stop_sequence: null,
      usage: { input_tokens: 1000, output_tokens: 1000, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
    }),
  );
}

/** Yapay zekâ çağrısı; `meetingId` null ise toplantı dışı (hesap) çağrısıdır. */
function llmCall(harness: Harness, session: Session, meetingId: string | null): Promise<Response> {
  const headers: Record<string, string> = meetingId === null ? {} : { "x-meeting-id": meetingId };
  return harness.call(
    req("POST", "/v1/llm/messages", {
      token: session.accessToken,
      headers,
      json: { effort: "low", max_tokens: 2000, messages: [{ role: "user", content: "x" }] },
    }),
  );
}

// Bu dosyanın D1'i yalnızca kendine aittir: günlük harcama tablosu diğer testleri etkilemez.
describe("günlük harcama tavanı", () => {
  it("LLM kullanımı tahmini harcamaya eklenir; tavan aşılınca yeni toplantı 503 ile reddedilir ve alarm logu yazılır", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    stubHaiku(harness);
    expect((await llmCall(harness, session, meeting.meetingId)).status).toBe(200);
    const day: string = new Date(harness.clock.nowMs).toISOString().slice(0, 10);
    const spent = await env.DB.prepare("SELECT micro_usd FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number }>();
    // 1000 × 0,10 $/M + 1000 × 0,50 $/M = 600 mikro dolar.
    expect(spent?.micro_usd).toBe(600);

    // Tavan 25 $: günü tavana getir.
    await env.DB.prepare("UPDATE daily_spend SET micro_usd = ? WHERE day = ?").bind(25_000_000, day).run();
    const alerts = vi.spyOn(console, "error");
    const refused: Response = await startMeeting(harness, session);
    const body = await expectError(refused, 503, "spend_ceiling_reached");
    expect(body.error.message).toContain("try again later");
    expect(alerts.mock.calls.some((call: unknown[]): boolean => String(call[0]).includes('"event":"daily_spend_ceiling_reached"'))).toBe(true);
    alerts.mockRestore();

    // Tavan her vekil çağrısında da denetlenir: süren toplantı da durur.
    await expectError(await llmCall(harness, session, meeting.meetingId), 503, "spend_ceiling_reached");
    const audio: Uint8Array = new Uint8Array(1000);
    await expectError(
      await harness.call(
        req("POST", "/v1/transcribe", {
          token: session.accessToken,
          headers: { "x-meeting-id": meeting.meetingId, "content-type": "audio/mp4", "content-length": String(audio.byteLength) },
          body: audio,
        }),
      ),
      503,
      "spend_ceiling_reached",
    );

    // Ertesi gün tavan sıfırlanır.
    harness.clock.nowMs += 86_400_000;
    const fresh: Session = await signIn(harness);
    expect((await startMeeting(harness, fresh)).status).toBe(201);
  });
});

describe("günlük deneme harcaması tavanı", () => {
  it("deneme harcaması ayrı sayılır; tavanda deneme harcaması açan her yol 503 (yeni, açık ve yeniden işlenen deneme toplantısı, hesap çağrısı), aboneler sürer", async () => {
    const harness: Harness = await defaultHarness();
    // Üstteki test bugünün genel tavanını doldurdu: iki gün sonrası temizdir.
    harness.clock.nowMs += 2 * 86_400_000;
    stubHaiku(harness);
    const day: string = new Date(harness.clock.nowMs).toISOString().slice(0, 10);
    const spend = async (): Promise<{ micro_usd: number; trial_micro_usd: number } | null> =>
      env.DB.prepare("SELECT micro_usd, trial_micro_usd FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number; trial_micro_usd: number }>();

    const trial: Session = await signIn(harness);
    const trialMeeting: StartedMeetingBody = await (await startMeeting(harness, trial)).json<StartedMeetingBody>();
    expect((await llmCall(harness, trial, trialMeeting.meetingId)).status).toBe(200);
    expect((await llmCall(harness, trial, null)).status).toBe(200);
    expect(await spend()).toEqual({ micro_usd: 1200, trial_micro_usd: 1200 });

    const subscriber: Session = await signIn(harness);
    await grantSubscription(subscriber.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const paidMeeting: StartedMeetingBody = await (await startMeeting(harness, subscriber)).json<StartedMeetingBody>();
    expect((await llmCall(harness, subscriber, paidMeeting.meetingId)).status).toBe(200);
    expect(await spend()).toEqual({ micro_usd: 1800, trial_micro_usd: 1200 });

    // Deneme tavanı (10 $) doldu; genel tavan (25 $) dolmadı.
    await env.DB.prepare("UPDATE daily_spend SET trial_micro_usd = ? WHERE day = ?").bind(10_000_000, day).run();
    const alerts = vi.spyOn(console, "error");
    const alertCount = (): number =>
      alerts.mock.calls.filter((call: unknown[]): boolean => String(call[0]).includes('"event":"daily_trial_spend_ceiling_reached"')).length;
    const refused = await expectError(await startMeeting(harness, await signIn(harness)), 503, "trial_capacity_reached");
    expect(refused.error.message).toContain("subscribe");
    expect(alertCount()).toBe(1);
    await expectError(await llmCall(harness, trial, null), 503, "trial_capacity_reached");
    // Açık deneme toplantısı da tavandan sonra yeni deneme harcaması açamaz (yapay zekâ ve yazıya dökme).
    await expectError(await llmCall(harness, trial, trialMeeting.meetingId), 503, "trial_capacity_reached");
    const audio: Uint8Array = new Uint8Array(1000);
    await expectError(
      await harness.call(
        req("POST", "/v1/transcribe", {
          token: trial.accessToken,
          headers: { "x-meeting-id": trialMeeting.meetingId, "content-type": "audio/wav", "content-length": String(audio.byteLength) },
          body: audio,
        }),
      ),
      503,
      "trial_capacity_reached",
    );
    // İşleme süresi (24 saat) geçmiş deneme toplantısını yeniden işlemek de deneme harcaması açar: hak harcanmadan 503.
    await env.DB.prepare("UPDATE meeting_sessions SET ended_at = ?, end_reason = 'ended' WHERE id = ?")
      .bind(harness.clock.nowMs - 25 * 3_600_000, trialMeeting.meetingId)
      .run();
    await expectError(
      await harness.call(req("POST", `/v1/meetings/${trialMeeting.meetingId}/reprocess`, { token: trial.accessToken })),
      503,
      "trial_capacity_reached",
    );
    const reprocessed = await env.DB.prepare("SELECT reprocess_count FROM meeting_sessions WHERE id = ?").bind(trialMeeting.meetingId).first<{ reprocess_count: number }>();
    expect(reprocessed?.reprocess_count).toBe(0);
    // Alarm günde bir kez yazılır; retler "Sorunlar" sayacında ve toplantının son hatasında görünür.
    expect(alertCount()).toBe(1);
    alerts.mockRestore();
    await harness.drain();
    const counted = await env.DB.prepare("SELECT count FROM ops_events WHERE day = ? AND kind = 'refusal' AND detail = 'trial_capacity_reached'")
      .bind(day)
      .first<{ count: number }>();
    expect(counted?.count).toBe(5);
    const failure = await env.DB.prepare("SELECT failure_count, last_failure_code FROM meeting_sessions WHERE id = ?")
      .bind(trialMeeting.meetingId)
      .first<{ failure_count: number; last_failure_code: string }>();
    expect(failure).toEqual({ failure_count: 3, last_failure_code: "trial_capacity_reached" });
    // Aboneler yalnızca genel tavana tabidir.
    expect((await startMeeting(harness, subscriber)).status).toBe(201);
    expect((await llmCall(harness, subscriber, null)).status).toBe(200);
  });
});

describe("hesap silinirken süren çağrı", () => {
  it("kesinleştirme yabancı anahtar hatası almaz; harcama silmede tahminle bir kez yazılır", async () => {
    const harness: Harness = await defaultHarness();
    // Önceki testler bugünün harcama tavanını doldurdu: yeni gün.
    harness.clock.nowMs += 3 * 86_400_000;
    stubStripeApi(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const started: Response = await startMeeting(harness, session);
    expect(started.status).toBe(201);
    const meeting: StartedMeetingBody = await started.json<StartedMeetingBody>();
    const now: Date = new Date(harness.clock.nowMs);
    const llm: UsageReservation = llmReservation(
      { userId: session.userId, meetingId: meeting.meetingId, tokens: 100, trialAccountCall: false, subscriberAccountCall: false, estimatedMicroUsd: 700, trialSpend: false },
      now,
    );
    const audio: UsageReservation = audioReservation(session.userId, meeting.meetingId, 10, 300, false, now);
    await reserveUsage(env.DB, llm, [{ limit: meetingTokenLimit(meeting.meetingId, now), amount: 100 }]);
    await reserveUsage(env.DB, audio, [{ limit: meetingAudioLimit(meeting.meetingId), amount: 10 }]);
    const day: string = now.toISOString().slice(0, 10);
    const spend = async (): Promise<{ micro_usd: number; audio_seconds: number }> =>
      (await env.DB.prepare("SELECT micro_usd, audio_seconds FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number; audio_seconds: number }>()) ?? {
        micro_usd: 0,
        audio_seconds: 0,
      };
    const before = await spend();
    expect((await harness.call(req("DELETE", "/v1/me", { token: session.accessToken }))).status).toBe(200);
    // Silme, süren ayırmaların tahminini yazar.
    expect(await spend()).toEqual({ micro_usd: before.micro_usd + 1000, audio_seconds: before.audio_seconds + 10 });
    // Üst servis yanıtı sonra gelir: kesinleştirme hata vermez, ikinci kez yazmaz, silinmiş hesaba sayaç açmaz.
    await env.DB.batch(settleLLMStatements(env.DB, llm, { inputTokens: 50, outputTokens: 50, cacheWriteTokens: 0, cacheReadTokens: 0 }, 600, now));
    await env.DB.batch(settleAudioStatements(env.DB, audio, 10, false, 300, 10, now));
    expect(await spend()).toEqual({ micro_usd: before.micro_usd + 1000, audio_seconds: before.audio_seconds + 10 });
    const counters = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM monthly_usage WHERE user_id = ?1) + (SELECT COUNT(*) FROM daily_usage WHERE user_id = ?1) AS count",
    )
      .bind(session.userId)
      .first<{ count: number }>();
    expect(counters?.count).toBe(0);
  });
});

describe("harcama tavanı ve süren ayırmalar", () => {
  it("süren ayırmalar tavana sayılır; eşzamanlı ayırmalar tavanı birlikte geçemez", async () => {
    const harness: Harness = await defaultHarness();
    // Önceki testler kendi günlerinin harcamasını yazdı: yeni gün.
    harness.clock.nowMs += 4 * 86_400_000;
    const session: Session = await signIn(harness);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const config: Config = parseConfig(env);
    const now: Date = new Date(harness.clock.nowMs);
    const day: string = now.toISOString().slice(0, 10);
    // Tavana 1000 mikro dolar kaldı; her çağrı en kötü durumda 600 mikro dolar harcayabilir.
    await env.DB.prepare("INSERT INTO daily_spend (day, micro_usd) VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET micro_usd = excluded.micro_usd")
      .bind(day, config.dailySpendCeilingMicroUsd - 1000)
      .run();
    const reserve = async (): Promise<string> => {
      const reservation: UsageReservation = llmReservation(
        { userId: session.userId, meetingId: meeting.meetingId, tokens: 10, trialAccountCall: false, subscriberAccountCall: false, estimatedMicroUsd: 600, trialSpend: false },
        now,
      );
      try {
        await reserveUsage(env.DB, reservation, spendCeilingChecks(config, reservation, now));
        return "reserved";
      } catch (error: unknown) {
        if (error instanceof ApiError) {
          return error.code;
        }
        throw error;
      }
    };
    const outcomes: string[] = await Promise.all([reserve(), reserve(), reserve(), reserve(), reserve()]);
    // İlk ikisi tavanın altında başlar (1000, sonra 400 kaldı); ikincisinden sonra harcama tavanı geçti.
    expect(outcomes.filter((outcome: string): boolean => outcome === "reserved")).toHaveLength(2);
    expect(outcomes.filter((outcome: string): boolean => outcome === "spend_ceiling_reached")).toHaveLength(3);
    // Kesinleşmemiş ayırmalar ön denetime de sayılır: yeni toplantı ve vekil çağrısı reddedilir.
    await expectError(await startMeeting(harness, await signIn(harness)), 503, "spend_ceiling_reached");
    await expectError(await llmCall(harness, session, meeting.meetingId), 503, "spend_ceiling_reached");
    // Süresi dolan ayırma artık sayılmaz (temizlik tahminini harcamaya yazana dek).
    await env.DB.prepare("UPDATE usage_reservations SET expires_at = ? WHERE user_id = ?").bind(harness.clock.nowMs, session.userId).run();
    expect((await startMeeting(harness, await signIn(harness))).status).toBe(201);
  });
});

// State-machine hardening P20: what a settlement writes at the D1 boundary. Spend is guarded by the reservation row, so
// it is written once whether the reservation is settled, expired or settled after expiring; the user's and meeting's
// token counters are written by the settlement that reports actual usage (the proxy settles each reservation once).
describe("reservation settlement and expiry", () => {
  it("spend is written once across settlement, a repeated settlement and expiry; counters take the actual usage", async () => {
    const harness: Harness = await defaultHarness();
    // Earlier tests filled their own days' spend: a new day.
    harness.clock.nowMs += 5 * 86_400_000;
    stubStripeApi(harness);
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 20 * 86_400_000);
    const meeting: StartedMeetingBody = await (await startMeeting(harness, session)).json<StartedMeetingBody>();
    const now: Date = new Date(harness.clock.nowMs);
    const day: string = now.toISOString().slice(0, 10);
    const month: string = day.slice(0, 7);
    const spend = async (): Promise<number> =>
      (await env.DB.prepare("SELECT micro_usd FROM daily_spend WHERE day = ?").bind(day).first<{ micro_usd: number }>())?.micro_usd ?? 0;
    const counters = async (): Promise<{ monthly: number; daily: number; meeting: number }> => {
      const monthly = await env.DB.prepare("SELECT input_tokens + output_tokens AS total FROM monthly_usage WHERE user_id = ? AND month = ?")
        .bind(session.userId, month)
        .first<{ total: number }>();
      const daily = await env.DB.prepare("SELECT tokens_used FROM daily_usage WHERE user_id = ? AND day = ?").bind(session.userId, day).first<{ tokens_used: number }>();
      const used = await env.DB.prepare("SELECT tokens_used FROM meeting_sessions WHERE id = ?").bind(meeting.meetingId).first<{ tokens_used: number }>();
      return { monthly: monthly?.total ?? 0, daily: daily?.tokens_used ?? 0, meeting: used?.tokens_used ?? 0 };
    };
    const reserve = async (): Promise<UsageReservation> => {
      const reservation: UsageReservation = llmReservation(
        { userId: session.userId, meetingId: meeting.meetingId, tokens: 100, trialAccountCall: false, subscriberAccountCall: false, estimatedMicroUsd: 700, trialSpend: false },
        now,
      );
      await reserveUsage(env.DB, reservation, [{ limit: meetingTokenLimit(meeting.meetingId, now), amount: 100 }]);
      return reservation;
    };
    const usage = { inputTokens: 30, outputTokens: 20, cacheWriteTokens: 0, cacheReadTokens: 0 };
    const spendBefore: number = await spend();
    const countersBefore = await counters();

    // Settled: actual cost into spend, actual tokens into every counter, the reservation row is gone.
    const settled: UsageReservation = await reserve();
    await env.DB.batch(settleLLMStatements(env.DB, settled, usage, 600, now));
    expect(await spend()).toBe(spendBefore + 600);
    expect(await counters()).toEqual({ monthly: countersBefore.monthly + 50, daily: countersBefore.daily + 50, meeting: countersBefore.meeting + 50 });
    const rows = await env.DB.prepare("SELECT COUNT(*) AS count FROM usage_reservations WHERE id = ?").bind(settled.id).first<{ count: number }>();
    expect(rows?.count).toBe(0);
    // A repeated settlement of the same reservation finds no row: spend is not written again. The token counters are not
    // guarded by the row and take the usage again; no code path settles twice (see the P20 note in the plan), and this
    // assertion changes if they are ever guarded.
    await env.DB.batch(settleLLMStatements(env.DB, settled, usage, 600, now));
    expect(await spend()).toBe(spendBefore + 600);
    expect(await counters()).toEqual({ monthly: countersBefore.monthly + 100, daily: countersBefore.daily + 100, meeting: countersBefore.meeting + 100 });

    // Expired before its settlement: the cleanup writes the estimate once; the late settlement adds no spend, and its
    // actual tokens reach the counters (the response did reach the client).
    const late: UsageReservation = await reserve();
    const afterFirst = await counters();
    await env.DB.batch(expiredReservationStatements(env.DB, new Date(late.expiresAt)));
    expect(await spend()).toBe(spendBefore + 600 + 700);
    await env.DB.batch(settleLLMStatements(env.DB, late, usage, 600, now));
    expect(await spend()).toBe(spendBefore + 600 + 700);
    const afterLate = await counters();
    expect(afterLate).toEqual({ monthly: afterFirst.monthly + 50, daily: afterFirst.daily + 50, meeting: afterFirst.meeting + 50 });
  });
});
