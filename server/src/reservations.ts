import type { Config } from "./config";
import { randomId } from "./crypto";
import { ApiError } from "./errors";
import { meetingBaseMsSql, meetingRecordedMsSql } from "./meetingPause";
import {
  type SpendCeilingKind,
  chunkOverlapAllowanceSql,
  chunkOverlapSeconds,
  chunkStepSeconds,
  dayKey,
  monthKey,
  monthStartMs,
  monthlyUsedSecondsSql,
  overlapFreeSecondsSql,
  spendCeilingError,
  todaySpendBinds,
  todaySpendSql,
  trialCapacityError,
} from "./usage";

/**
 * Önceden ayırma (`usage_reservations`): üst servise giden her çağrı (LLM ya da ses) için tek satır. Satır, çağrının
 * en kötü durumda harcayabileceği miktarı (token ya da saniye) ve tahmini maliyeti taşır; sınır hesapları kesinleşmiş
 * kullanım + süresi dolmamış ayırmaların toplamıdır. Kesinleştirme satırı siler ve gerçek kullanımı yazar.
 *
 * Satırın bir son kullanma anı vardır: istemci koptuğunda ya da Worker kesinleştirmeden önce durduğunda satır sonsuza
 * dek sınır yemez; süresi dolunca sınır hesapları onu yok sayar, günlük temizlik tahmini maliyetini günlük harcamaya
 * ekleyip siler (`expiredReservationStatements`).
 */

/** SQL bağ değeri. */
type SqlValue = string | number | null;

/**
 * LLM ayırmasının ömrü: en uzun çağrı bundan kısadır (akışsız: 3 deneme × 120 sn; akışlı: `llmStreamDeadlineMs`).
 * Süresi dolan ayırma kullanıcının sınırlarına artık sayılmaz; kesinleşmemiş çağrı bu ömrü aşarsa sonraki çağrılar
 * onun tokenları sayılmadan kabul edilirdi.
 */
export const llmReservationTtlMs: number = 15 * 60_000;
/**
 * Akışlı LLM çağrısının ayırmadan itibaren en uzun süresi: `llmReservationTtlMs`'den (15 dk) kısa olmalı ki akış,
 * ayırmanın süresi dolmadan biter ya da kesilip kesinleşir. Akış istemcinin okuma hızıyla ilerler (okumayan istemci
 * akışı bekletir); süre dolunca üst akış iptal edilir ve ayrılan üst sınırla kesinleşir. Aradaki 3 dakika
 * kesinleştirmenin D1 yazımına yeter.
 */
export const llmStreamDeadlineMs: number = 12 * 60_000;
/** Ses ayırmasının ömrü: ElevenLabs zaman aşımından (15 dk) ve 95 MB yüklemeden uzundur. */
export const audioReservationTtlMs: number = 20 * 60_000;

/** Ayırma türü. */
export type ReservationKind = "llm" | "audio";

/** Tek çağrının ayırması (`usage_reservations` satırı). */
export interface UsageReservation {
  readonly id: string;
  readonly userId: string;
  /** Toplantıya bağlı çağrıda toplantı; hesap çağrısında null. */
  readonly meetingId: string | null;
  readonly kind: ReservationKind;
  /** Ayırmanın ve kesinleştirmenin yazdığı ay ve gün (UTC; ayırma anının). */
  readonly month: string;
  readonly day: string;
  /** Kullanıcının aylık ve günlük token sınırına (ve toplantı bütçesine) sayılan token. */
  readonly tokens: number;
  /** Denemedeki hesap çağrısında `tokens`; değilse 0 (`TRIAL_ACCOUNT_DAILY_TOKENS`). */
  readonly trialAccountTokens: number;
  /** Abonenin hesap çağrısında `tokens`; değilse 0 (`MONTHLY_ACCOUNT_TOKEN_CAP`). */
  readonly accountTokens: number;
  readonly audioSeconds: number;
  /** En kötü durumun tahmini maliyeti (mikro dolar); süresi dolarsa harcamaya bu yazılır. */
  readonly estimatedMicroUsd: number;
  /** Harcama deneme tavanına da sayılır mı (deneme toplantısı ya da denemedeki hesap çağrısı). */
  readonly trialSpend: boolean;
  readonly createdAt: number;
  readonly expiresAt: number;
}

/** Yeni LLM ayırmasının alanları. */
export interface LLMReservationInput {
  readonly userId: string;
  readonly meetingId: string | null;
  readonly tokens: number;
  readonly trialAccountCall: boolean;
  readonly subscriberAccountCall: boolean;
  readonly estimatedMicroUsd: number;
  readonly trialSpend: boolean;
}

/** LLM ayırması. Saf fonksiyondur (kimlik rastgeledir). */
export function llmReservation(input: LLMReservationInput, now: Date): UsageReservation {
  return {
    id: randomId(),
    userId: input.userId,
    meetingId: input.meetingId,
    kind: "llm",
    month: monthKey(now),
    day: dayKey(now),
    tokens: input.tokens,
    trialAccountTokens: input.trialAccountCall ? input.tokens : 0,
    accountTokens: input.subscriberAccountCall ? input.tokens : 0,
    audioSeconds: 0,
    estimatedMicroUsd: input.estimatedMicroUsd,
    trialSpend: input.trialSpend,
    createdAt: now.getTime(),
    expiresAt: now.getTime() + llmReservationTtlMs,
  };
}

/** Ses ayırması. Saf fonksiyondur (kimlik rastgeledir). */
export function audioReservation(userId: string, meetingId: string, seconds: number, estimatedMicroUsd: number, trialSpend: boolean, now: Date): UsageReservation {
  return {
    id: randomId(),
    userId,
    meetingId,
    kind: "audio",
    month: monthKey(now),
    day: dayKey(now),
    tokens: 0,
    trialAccountTokens: 0,
    accountTokens: 0,
    audioSeconds: seconds,
    estimatedMicroUsd,
    trialSpend,
    createdAt: now.getTime(),
    expiresAt: now.getTime() + audioReservationTtlMs,
  };
}

/**
 * Bir sınır: kalan miktarın SQL ifadesi (kesinleşmiş kullanım ve süresi dolmamış ayırmalar düşülmüş) ve aşılınca
 * fırlatılacak hata. İfade bağımsız bir `SELECT` içinde de, ayırma ifadesinin koşulunda da kullanılır.
 */
export interface ReservationLimit {
  readonly remainingSql: string;
  readonly binds: readonly SqlValue[];
  readonly error: ApiError;
}

/** Sınır ve ona karşı ayrılacak miktar. */
export interface ReservationCheck {
  readonly limit: ReservationLimit;
  readonly amount: number;
}

/** Süresi dolmamış ayırmaların bir sütununun toplamı (SQL). */
function activeSum(column: string, scope: string): string {
  return `(SELECT COALESCE(SUM(${column}), 0) FROM usage_reservations WHERE ${scope} AND expires_at > ?)`;
}

/** Toplantının token bütçesinden kalan. */
export function meetingTokenLimit(meetingId: string, now: Date): ReservationLimit {
  return {
    remainingSql: `(SELECT token_budget - tokens_used FROM meeting_sessions WHERE id = ?) - ${activeSum("tokens", "meeting_id = ? AND kind = 'llm'")}`,
    binds: [meetingId, meetingId, now.getTime()],
    error: new ApiError("meeting_budget_exhausted", "This meeting's AI budget is used up."),
  };
}

/**
 * Toplantı bütçesinin nota ayrılan payı: kayıt sırasındaki canlı çağrılar (çeviri, "Ne kaçırdım?", toplantı sorusu)
 * bütçenin bu kadarını kullanamaz. Uzun ve çok konuşulan toplantıda canlı çeviri bütçeyi bitirse not yazılamazdı
 * (ölçülen canlı çeviri ~0,66 M token/saat; 4 saatlik notun parçaları ve birleştirmesi ~0,3 M).
 */
export const meetingNoteReserveShare: number = 0.15;

/** Bütçenin nota ayrılan payı (token; aşağı yuvarlanır). Saf fonksiyondur. */
export function meetingNoteReserveTokens(tokenBudget: number): number {
  return Math.floor(tokenBudget * meetingNoteReserveShare);
}

/** Toplantının token bütçesinden canlı çağrılara kalan: bütçe − nota ayrılan pay − kullanılan − süren ayırmalar. */
export function meetingLiveTokenLimit(meetingId: string, now: Date): ReservationLimit {
  return {
    remainingSql: `(SELECT token_budget - CAST(token_budget * ${meetingNoteReserveShare} AS INTEGER) - tokens_used FROM meeting_sessions WHERE id = ?) - ${activeSum("tokens", "meeting_id = ? AND kind = 'llm'")}`,
    binds: [meetingId, meetingId, now.getTime()],
    error: new ApiError("meeting_budget_exhausted", "This meeting's live AI budget is used up; the rest is kept for the meeting note."),
  };
}

/** Kullanıcının aylık token sınırından kalan (tüm çağrılar; sınır kullanıcının katmanınındır, `UsageLimits`). */
export function monthlyTokenLimit(monthlyTokenCap: number, userId: string, now: Date): ReservationLimit {
  const month: string = monthKey(now);
  return {
    remainingSql: `? - COALESCE((SELECT input_tokens + output_tokens FROM monthly_usage WHERE user_id = ? AND month = ?), 0) - ${activeSum("tokens", "user_id = ? AND month = ?")}`,
    binds: [monthlyTokenCap, userId, month, userId, month, now.getTime()],
    error: new ApiError("monthly_cap_reached", "You have reached this month's AI usage limit; it resets at the start of the month."),
  };
}

/** Kullanıcının günlük token sınırından kalan (tüm çağrılar; sınır kullanıcının katmanınındır). */
export function dailyTokenLimit(dailyTokenCap: number, userId: string, now: Date): ReservationLimit {
  const day: string = dayKey(now);
  return {
    remainingSql: `? - COALESCE((SELECT tokens_used FROM daily_usage WHERE user_id = ? AND day = ?), 0) - ${activeSum("tokens", "user_id = ? AND day = ?")}`,
    binds: [dailyTokenCap, userId, day, userId, day, now.getTime()],
    error: new ApiError("daily_cap_reached", "You have reached today's AI usage limit; try again tomorrow."),
  };
}

/** Denemedeki kullanıcının toplantı dışı çağrılarının günlük sınırından kalan. */
export function trialAccountTokenLimit(config: Config, userId: string, now: Date): ReservationLimit {
  const day: string = dayKey(now);
  return {
    remainingSql: `? - COALESCE((SELECT trial_account_tokens_used FROM daily_usage WHERE user_id = ? AND day = ?), 0) - ${activeSum("trial_account_tokens", "user_id = ? AND day = ?")}`,
    binds: [config.trialAccountDailyTokens, userId, day, userId, day, now.getTime()],
    error: new ApiError("daily_cap_reached", "You have reached today's trial limit for AI use outside meetings; try again tomorrow or subscribe."),
  };
}

/** Abonenin toplantı dışı çağrılarının aylık sınırından kalan (katmanın `MONTHLY_ACCOUNT_TOKEN_CAP`'i). */
export function subscriberAccountTokenLimit(monthlyAccountTokenCap: number, userId: string, now: Date): ReservationLimit {
  const month: string = monthKey(now);
  return {
    remainingSql: `? - COALESCE((SELECT account_tokens FROM monthly_usage WHERE user_id = ? AND month = ?), 0) - ${activeSum("account_tokens", "user_id = ? AND month = ?")}`,
    binds: [monthlyAccountTokenCap, userId, month, userId, month, now.getTime()],
    error: new ApiError(
      "monthly_cap_reached",
      "You have reached this month's limit for AI use outside meetings (Ask, note editing); meetings continue, and the limit resets at the start of the month.",
    ),
  };
}

/**
 * Toplantının ses süresinden kalan: ilk geçişte taban en uzun süresi (duraklatma uzatması sayılmaz, `meetingBaseMsSql`) + parça örtüşme payı − yazılmış ses; yeniden işlemede
 * `reprocess_audio_cap` − yazılmış ses (sınır toplam yerine geçer: ikinci geçiş kaydın tamamını yeniden yazabilmeli);
 * ses hakkı kapandıysa 0. Toplantıda aynı anda tek ses isteği olabildiği için
 * (`meetingAudioIdleLimit`) süren ayırma düşülmez.
 */
export function meetingAudioLimit(meetingId: string): ReservationLimit {
  // Taban süre: duraklatma uzatması ses hakkını büyütmez (duraklatılan ses kaydedilmez).
  const base: string = `${meetingBaseMsSql("")} / 1000.0`;
  const total: string = `${base} + ${chunkOverlapAllowanceSql(base)}`;
  return {
    remainingSql: `(SELECT CASE WHEN transcription_closed = 0 THEN COALESCE(reprocess_audio_cap, ${total}) - audio_seconds ELSE 0 END FROM meeting_sessions WHERE id = ?)`,
    binds: [meetingId],
    error: new ApiError("audio_too_long", "The audio exceeds this meeting's remaining audio time."),
  };
}

/** Toplantıda süren (süresi dolmamış) ses isteği yoksa 1, varsa 0: toplantı başına aynı anda tek ses isteği. */
export function meetingAudioIdleLimit(meetingId: string, now: Date): ReservationLimit {
  return {
    remainingSql: "CASE WHEN EXISTS (SELECT 1 FROM usage_reservations WHERE meeting_id = ? AND kind = 'audio' AND expires_at > ?) THEN 0 ELSE 1 END",
    binds: [meetingId, now.getTime()],
    error: new ApiError("transcription_in_progress", "An audio file for this meeting is still being processed; try again when it finishes."),
  };
}

/**
 * Kullanıcının süren (süresi dolmamış) ses isteği yoksa 1, varsa 0: kullanıcı başına (tüm toplantılarında) aynı anda
 * tek ses isteği. Ses süresi istemcinin bildirdiği başlıktan ayrılır; FLAC STREAMINFO'su eksik bildirilmiş (iyi
 * sıkışan, ör. sessiz) dosyanın gerçek süresi ancak ElevenLabs yanıtında görülür ve o toplantının ses hakkını kapatır.
 * Ayrı toplantılara eşzamanlı yüklemeler her biri bir kez aşabilirdi; tek istekle aşım en çok bir dosyayla sınırlanır
 * ve kesinleşen gerçek süre sonraki isteğin aylık sınırına sayılır.
 */
export function userAudioIdleLimit(userId: string, now: Date): ReservationLimit {
  return {
    remainingSql: "CASE WHEN EXISTS (SELECT 1 FROM usage_reservations WHERE user_id = ? AND kind = 'audio' AND expires_at > ?) THEN 0 ELSE 1 END",
    binds: [userId, now.getTime()],
    error: new ApiError("transcription_in_progress", "Another audio file on this account is still being processed; try again when it finishes."),
  };
}

/**
 * Kullanıcının aylık süre sınırından bu toplantıya yazılabilecek ses (deneme toplantılarında da; silinmiş hesaptan
 * devralınan süre dahil): sınır − sayılan süre (`monthlyUsedSecondsSql`) + toplantının sesinin (örtüşmesiz) henüz
 * süresine ulaşmamış kısmı (toplantının süresi zaten sayıldı) + toplantıya en az bir tam parça yazıldıysa bir parça
 * örtüşmesi (sonraki parça öncekinin son dakikasıyla başlar; o dakika aylık süreye sayılmaz).
 */
export function monthlyAudioLimit(monthlyCapSeconds: number, userId: string, meetingId: string, now: Date): ReservationLimit {
  const used: string = monthlyUsedSecondsSql({ user: "p.user_id", month: "p.month", now: "p.now", monthStart: "p.month_start" });
  const written: string = `(s.audio_seconds + COALESCE((SELECT SUM(r.audio_seconds) FROM usage_reservations r WHERE r.meeting_id = s.id AND r.kind = 'audio' AND r.expires_at > p.now), 0))`;
  const headroom: string = `COALESCE((SELECT MAX(0, ${meetingRecordedMsSql("s.", "p.now")} / 1000.0 - ${overlapFreeSecondsSql(written)})
    FROM meeting_sessions s WHERE s.id = p.meeting_id AND s.started_at >= p.month_start), 0)`;
  const overlap: string = `COALESCE((SELECT CASE WHEN s.audio_seconds >= ${chunkStepSeconds} THEN ${chunkOverlapSeconds} ELSE 0 END FROM meeting_sessions s WHERE s.id = p.meeting_id), 0)`;
  return {
    remainingSql: `(SELECT p.cap - ${used} + ${headroom} + ${overlap}
      FROM (SELECT ? AS cap, ? AS user_id, ? AS month, ? AS now, ? AS month_start, ? AS meeting_id) p)`,
    binds: [monthlyCapSeconds, userId, monthKey(now), now.getTime(), monthStartMs(now), meetingId],
    error: new ApiError("monthly_cap_reached", "This month's remaining usage limit isn't enough to process this recording; it resets at the start of the month."),
  };
}

/** Günlük harcama tavanından kalan (mikro dolar): tavan − bugünkü harcama (süren ayırmalar dahil, `todaySpendSql`). */
export function dailySpendLimit(config: Config, kind: SpendCeilingKind, now: Date): ReservationLimit {
  const ceiling: number = kind === "total" ? config.dailySpendCeilingMicroUsd : config.dailyTrialSpendCeilingMicroUsd;
  return {
    remainingSql: `? - (${todaySpendSql(kind)})`,
    binds: [ceiling, ...todaySpendBinds(kind, now)],
    error: kind === "total" ? spendCeilingError() : trialCapacityError(),
  };
}

/**
 * Ayırmanın harcama tavanı denetimleri: genel tavan, deneme harcamasında deneme tavanı da. Kural ön denetimle
 * (`requireSpendHeadroom`) aynıdır, harcama tavanın altındaysa çağrı kabul edilir (1 mikro dolar kalmalı); ayırma
 * ifadesinin içinde çalıştığı için eşzamanlı çağrılar birbirinin ayırmasını görür ve tavanı en çok bir çağrının
 * tahmini kadar aşabilir. Saf fonksiyondur.
 */
export function spendCeilingChecks(config: Config, reservation: UsageReservation, now: Date): readonly ReservationCheck[] {
  const total: ReservationCheck = { limit: dailySpendLimit(config, "total", now), amount: 1 };
  return reservation.trialSpend ? [total, { limit: dailySpendLimit(config, "trial", now), amount: 1 }] : [total];
}

/** Sınırların kalanlarını tek sorguda okur (sırayla). */
export async function remainingOf(db: D1Database, limits: readonly ReservationLimit[]): Promise<number[]> {
  const columns: string = limits.map((limit: ReservationLimit, index: number): string => `(${limit.remainingSql}) AS r${index}`).join(", ");
  const row: Record<string, number | null> | null = await db
    .prepare(`SELECT ${columns}`)
    .bind(...limits.flatMap((limit: ReservationLimit): readonly SqlValue[] => limit.binds))
    .first<Record<string, number | null>>();
  return limits.map((_: ReservationLimit, index: number): number => row?.[`r${index}`] ?? 0);
}

/** En dar sınır: kalanı ve hatası. Saf fonksiyondur. */
export function tightestLimit(limits: readonly ReservationLimit[], remaining: readonly number[]): { readonly remaining: number; readonly error: ApiError } {
  const first: ReservationLimit | undefined = limits[0];
  if (first === undefined) {
    throw new Error("En az bir sınır gerekir.");
  }
  return limits.reduce(
    (tightest: { remaining: number; error: ApiError }, limit: ReservationLimit, index: number): { remaining: number; error: ApiError } => {
      const value: number = remaining[index] ?? 0;
      return value < tightest.remaining ? { remaining: value, error: limit.error } : tightest;
    },
    { remaining: remaining[0] ?? 0, error: first.error },
  );
}

/**
 * Ayırma satırını yalnızca tüm sınırlar yetiyorsa ekler (tek koşullu ifade: eşzamanlı istekler sınırı aşamaz).
 * Eklenmezse kalanlar yeniden okunur ve yetmeyen ilk sınırın hatası fırlatılır (arada yer açıldıysa ilk sınırınki).
 */
export async function reserveUsage(db: D1Database, reservation: UsageReservation, checks: readonly ReservationCheck[]): Promise<void> {
  const conditions: string = checks.map((check: ReservationCheck): string => `(${check.limit.remainingSql}) >= ?`).join(" AND ");
  const conditionBinds: SqlValue[] = checks.flatMap((check: ReservationCheck): SqlValue[] => [...check.limit.binds, check.amount]);
  const inserted: D1Result = await db
    .prepare(
      `INSERT INTO usage_reservations (id, user_id, meeting_id, kind, month, day, tokens, trial_account_tokens, account_tokens,
         audio_seconds, estimated_micro_usd, trial_spend, created_at, expires_at)
       SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE ${conditions}`,
    )
    .bind(
      reservation.id,
      reservation.userId,
      reservation.meetingId,
      reservation.kind,
      reservation.month,
      reservation.day,
      reservation.tokens,
      reservation.trialAccountTokens,
      reservation.accountTokens,
      reservation.audioSeconds,
      reservation.estimatedMicroUsd,
      reservation.trialSpend ? 1 : 0,
      reservation.createdAt,
      reservation.expiresAt,
      ...conditionBinds,
    )
    .run();
  if (inserted.meta.changes === 1) {
    return;
  }
  const limits: ReservationLimit[] = checks.map((check: ReservationCheck): ReservationLimit => check.limit);
  const remaining: number[] = await remainingOf(db, limits);
  const failed: ReservationCheck | undefined = checks.find((check: ReservationCheck, index: number): boolean => (remaining[index] ?? 0) < check.amount);
  throw (failed ?? checks[0])?.limit.error ?? new Error("Ayırma sınırı olmadan çağrıldı.");
}

/**
 * Harcama ifadesi: deneme harcamasıysa deneme toplamına, LLM çağrısıysa Anthropic payına (`llm_micro_usd`) da yazılır. Yalnızca ayırma satırı hâlâ duruyorsa yazılır:
 * satırı kaldıran (süre dolumu temizliği ya da hesap silme) tahmini maliyeti zaten yazmıştır; gerçek maliyet ikinci kez
 * eklenmez. Bu yüzden kesinleştirmede ayırmayı silen ifade en sonda çalışır.
 */
function spendStatement(db: D1Database, reservation: UsageReservation, microUsd: number, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO daily_spend (day, micro_usd, trial_micro_usd, llm_micro_usd)
       SELECT ?1, ?2, CASE WHEN ?3 = 1 THEN ?2 ELSE 0 END, CASE WHEN ?5 = 'llm' THEN ?2 ELSE 0 END
       WHERE EXISTS (SELECT 1 FROM usage_reservations WHERE id = ?4)
       ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd, trial_micro_usd = trial_micro_usd + excluded.trial_micro_usd,
         llm_micro_usd = llm_micro_usd + excluded.llm_micro_usd`,
    )
    .bind(dayKey(now), microUsd, reservation.trialSpend ? 1 : 0, reservation.id, reservation.kind);
}

/** Kesinleştirmenin son ifadesi: ayırma satırını siler (önceki ifadeler satırın varlığına bakar). */
function deleteReservationStatement(db: D1Database, reservation: UsageReservation): D1PreparedStatement {
  return db.prepare("DELETE FROM usage_reservations WHERE id = ?").bind(reservation.id);
}

/**
 * Gerçekleşen token kullanımı. `inputTokens` is the whole prompt (uncached, cache write and cache read together): the
 * budgets count every prompt token alike. `cacheWriteTokens` and `cacheReadTokens` are its cached parts, which only the
 * cost prices differently (`llmUsageCostMicroUsd`).
 */
export interface TokenUsage {
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly cacheWriteTokens: number;
  readonly cacheReadTokens: number;
}

/**
 * LLM ayırmasını kesinleştiren ifadeler: gerçek kullanım toplantıya (varsa), kullanıcının ayına ve gününe (denemedeki
 * ya da abonenin hesap çağrısında ayrıca kendi sayacına) ve `spendMicroUsd` günlük harcamaya yazılır, en sonda ayırma
 * satırı silinir. Ay ve gün ayırmanınkidir (gece yarısını aşan çağrı ayırdığı satırı kesinleştirir). Hesap çağrı
 * sürerken silindiyse kullanıcı sayaçları yazılmaz (yabancı anahtar hatası toplu işlemi düşürmez); harcama, ayırmayı
 * silen hesap silme işleminde tahminle yazılmıştır (`reservationSpendOnRemovalStatement`).
 */
export function settleLLMStatements(db: D1Database, reservation: UsageReservation, usage: TokenUsage, spendMicroUsd: number, now: Date): D1PreparedStatement[] {
  const actual: number = usage.inputTokens + usage.outputTokens;
  const meeting: D1PreparedStatement[] =
    reservation.meetingId === null
      ? []
      : [db.prepare("UPDATE meeting_sessions SET tokens_used = tokens_used + ? WHERE id = ?").bind(actual, reservation.meetingId)];
  return [
    ...meeting,
    db
      .prepare(
        `INSERT INTO monthly_usage (user_id, month, input_tokens, output_tokens, account_tokens)
         SELECT ?1, ?2, ?3, ?4, ?5 WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)
         ON CONFLICT(user_id, month) DO UPDATE SET input_tokens = input_tokens + excluded.input_tokens,
           output_tokens = output_tokens + excluded.output_tokens, account_tokens = account_tokens + excluded.account_tokens`,
      )
      .bind(reservation.userId, reservation.month, usage.inputTokens, usage.outputTokens, reservation.accountTokens > 0 ? actual : 0),
    db
      .prepare(
        `INSERT INTO daily_usage (user_id, day, tokens_used, trial_account_tokens_used)
         SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)
         ON CONFLICT(user_id, day) DO UPDATE SET tokens_used = tokens_used + excluded.tokens_used,
           trial_account_tokens_used = trial_account_tokens_used + excluded.trial_account_tokens_used`,
      )
      .bind(reservation.userId, reservation.day, actual, reservation.trialAccountTokens > 0 ? actual : 0),
    spendStatement(db, reservation, spendMicroUsd, now),
    deleteReservationStatement(db, reservation),
  ];
}

/**
 * Ses ayırmasını kesinleştiren ifadeler: ayırma satırı silinir (toplantının ses isteği serbest kalır); gerçek süre
 * toplantıya ve kullanıcının ayına, `spendMicroUsd` günlük harcamaya, `providerSeconds` (ElevenLabs'in kredisinden
 * düştüğü kabul edilen saniye) günlük ElevenLabs sayacına (`daily_spend.audio_seconds`) yazılır. Gerçek süre ayrılanı
 * aştıysa toplantının ses hakkı kapanır (`closeTranscription`). Ayırma satırı en sonda silinir; harcama yalnızca satır
 * hâlâ duruyorsa yazılır, kullanıcı sayacı yalnızca hesap duruyorsa (bkz. `settleLLMStatements`).
 */
export function settleAudioStatements(
  db: D1Database,
  reservation: UsageReservation,
  actualSeconds: number,
  closeTranscription: boolean,
  spendMicroUsd: number,
  providerSeconds: number,
  now: Date,
): D1PreparedStatement[] {
  return [
    db
      .prepare("UPDATE meeting_sessions SET audio_seconds = audio_seconds + ?, transcription_closed = MAX(transcription_closed, ?) WHERE id = ?")
      .bind(actualSeconds, closeTranscription ? 1 : 0, reservation.meetingId),
    db
      .prepare(
        `INSERT INTO monthly_usage (user_id, month, audio_seconds)
         SELECT ?1, ?2, ?3 WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1)
         ON CONFLICT(user_id, month) DO UPDATE SET audio_seconds = audio_seconds + excluded.audio_seconds`,
      )
      .bind(reservation.userId, reservation.month, actualSeconds),
    spendStatement(db, reservation, spendMicroUsd, now),
    db
      .prepare(
        `INSERT INTO daily_spend (day, audio_seconds)
         SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM usage_reservations WHERE id = ?3)
         ON CONFLICT(day) DO UPDATE SET audio_seconds = audio_seconds + excluded.audio_seconds`,
      )
      .bind(dayKey(now), providerSeconds, reservation.id),
    deleteReservationStatement(db, reservation),
  ];
}

/**
 * Süresi dolmuş (kesinleşmemiş) ayırmaları kapatan ifadeler; aynı toplu işlemde, aynı anla çalışmalıdır. Çağrının gerçek
 * kullanımı bilinmez: en kötü durum tahmini maliyeti (seste ayrıca saniyesi ElevenLabs sayacına) ayırmanın gününün
 * harcamasına eklenir (deneme payı ayrıca), satırlar
 * silinir. Kullanıcının token ve süre sayaçlarına yazılmaz (istemci yanıt almadı).
 */
export function expiredReservationStatements(db: D1Database, now: Date): D1PreparedStatement[] {
  return removedReservationStatements(db, "expires_at <= ?", [now.getTime()]);
}

/**
 * Hesap silinirken süren ayırmalarını kaldıran ifadeler (hesabın satırları silinmeden, aynı toplu işlemde): çağrılar
 * üst serviste sürüyor olabilir; tahmini maliyetleri günlük harcamaya yazılır (sonraki kesinleştirme satırı bulamaz ve
 * ikinci kez yazmaz), satırlar silinir.
 */
export function userReservationRemovalStatements(db: D1Database, userId: string): D1PreparedStatement[] {
  return removedReservationStatements(db, "user_id = ?", [userId]);
}

/** Koşula uyan ayırmaların tahmini maliyetini ayırmanın gününe yazıp satırları silen ifadeler. */
function removedReservationStatements(db: D1Database, condition: string, binds: readonly SqlValue[]): D1PreparedStatement[] {
  return [
    db
      .prepare(
        `INSERT INTO daily_spend (day, micro_usd, trial_micro_usd, audio_seconds, llm_micro_usd)
         SELECT day, SUM(estimated_micro_usd), SUM(CASE WHEN trial_spend = 1 THEN estimated_micro_usd ELSE 0 END),
           SUM(CASE WHEN kind = 'audio' THEN audio_seconds ELSE 0 END), SUM(CASE WHEN kind = 'llm' THEN estimated_micro_usd ELSE 0 END)
         FROM usage_reservations WHERE ${condition} GROUP BY day
         ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd, trial_micro_usd = trial_micro_usd + excluded.trial_micro_usd,
           audio_seconds = audio_seconds + excluded.audio_seconds, llm_micro_usd = llm_micro_usd + excluded.llm_micro_usd`,
      )
      .bind(...binds),
    db.prepare(`DELETE FROM usage_reservations WHERE ${condition}`).bind(...binds),
  ];
}
