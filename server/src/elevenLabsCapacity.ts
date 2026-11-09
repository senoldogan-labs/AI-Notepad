import { z } from "zod";
import type { Config } from "./config";
import { ApiError, isRetryableStatus } from "./errors";
import { errorName, log } from "./log";
import type { OutboundPlatform } from "./platform";
import type { ReservationCheck, ReservationLimit } from "./reservations";
import { withRetries } from "./retry";
import { isRetryableUpstreamError } from "./upstream";
import { dayKey } from "./usage";

/**
 * ElevenLabs kapasitesi. Kredi bitince her konuşma tanıma isteği 402 ile düşer ve sağlayıcı önceden uyarmaz; bu yüzden
 * ses ElevenLabs'e gitmeden iki sınıra karşı ayrılır, dar olan geçerlidir:
 *
 * - Canlı sınır: hesabın ElevenLabs'in kendi bildirdiği kalan kredisi (`GET /v1/user/subscription` →
 *   `character_limit − character_count`; plan, yükleme paketleri ve dönem yenilemesi dahil). Yanıt D1'de tek satırda
 *   saklanır (`elevenlabs_capacity`) ve okunduğu andaki dönem ses sayacıyla (`daily_spend.audio_seconds`) birlikte
 *   tutulur: o zamandan beri ElevenLabs'e giden ses kalan krediden düşülür. Ses ayırmadan önce satır
 *   `elevenLabsCapacityFreshMs`'den eskiyse tazelenir (geçici hatalar uyarıyla yeniden denenir); okunamazsa satır
 *   `elevenLabsCapacityStaleMs`'den yeni olduğu sürece kullanılır (`elevenlabs_capacity_refresh_failed` alarmı), daha
 *   eskiyse ya da hiç yoksa yeni ayırmalar durur (`elevenlabs_capacity_unknown` alarmı, `503 spend_ceiling_reached`).
 * - Güvenlik üst sınırı: elle konan `ELEVENLABS_MONTHLY_AUDIO_HOURS`'ın `elevenLabsHardStopRatio`'su; dönem
 *   `ELEVENLABS_BILLING_DAY`'de başlar, kullanım hesaptan bağımsız toplamdan okunur (`daily_spend.audio_seconds`;
 *   hesap silinince toplantılar silinse de kalır).
 *
 * İki sınır da süren ses ayırmalarını düşer ve ayırma satırının koşullu `INSERT`'üne girer (`reserveUsage`): eşzamanlı
 * yüklemeler aynı kalanı birlikte harcayamaz.
 */

/** Uyarı eşikleri (kullanım oranı). */
export const elevenLabsAlertThresholds: readonly number[] = [0.8, 0.95];
/** Güvenlik üst sınırında bu orandan sonra yeni ses işleme isteği kabul edilmez. */
export const elevenLabsHardStopRatio: number = 0.97;
/** Bu orandan sonra yeni deneme toplantısı açılmaz: kalan kapasite abonelere kalır. */
export const elevenLabsTrialStopRatio: number = 0.85;

/** ElevenLabs aboneliğinin kredi durumu. */
export const elevenLabsSubscriptionUrl: string = "https://api.elevenlabs.io/v1/user/subscription";
/** Canlı okuma bundan yeniyse ses ayırmadan önce yeniden okunmaz. */
export const elevenLabsCapacityFreshMs: number = 10 * 60_000;
/** Canlı okuma başarısızken saklı değer bu yaşa dek kullanılır; daha eskiyse yeni ses ayırmaları durur. */
export const elevenLabsCapacityStaleMs: number = 6 * 3_600_000;
/**
 * Kalan krediyi saate çevirirken kredi/saat oranının payı: gerçek tüketim ölçülenden (`ELEVENLABS_CREDITS_PER_AUDIO_HOUR`)
 * %10 fazla olsa da kredi canlı sınırdan önce bitmez.
 */
export const elevenLabsCreditRateMargin: number = 1.1;
/** Canlı sınırın kenarda bıraktığı ses: en uzun tek yükleme (60 dakikalık FLAC parçası) kredisiz kalmasın. */
export const elevenLabsLiveReserveSeconds: number = 3600;

const subscriptionAttempts: number = 3;
const subscriptionTimeoutMs: number = 8000;

/** ElevenLabs aboneliğinin kullanılan alanları (bkz. `elevenLabsSubscriptionUrl`). */
const subscriptionSchema = z.object({
  character_count: z.number().int().nonnegative(),
  character_limit: z.number().int().nonnegative(),
  next_character_count_reset_unix: z.number().int().nullable().optional(),
  status: z.string(),
});

/** ElevenLabs hata gövdesinin okunan alanları (`{detail: {code, status, type}}`); yalnızca loga kod yazılır. */
const errorDetailSchema = z.object({
  detail: z.object({ code: z.string().optional(), status: z.string().optional(), type: z.string().optional() }),
});

/** Aboneliğin kredi durumu. */
export interface ElevenLabsSubscription {
  readonly creditsUsed: number;
  readonly creditsLimit: number;
  /** Kredinin sonraki yenilenmesi (ms); bilinmiyorsa null. */
  readonly resetsAtMs: number | null;
  /** `trialing`, `active`, `incomplete`, `past_due`, `free`, `free_disabled`. */
  readonly status: string;
}

/** Saklı canlı okuma (`elevenlabs_capacity` satırı). */
export interface ElevenLabsSnapshot extends ElevenLabsSubscription {
  readonly fetchedAtMs: number;
  /** Okumanın günü (UTC); sonraki ses bu günden itibaren sayılır. */
  readonly fetchDay: string;
  /** Okuma anında `fetchDay`'den bu yana ElevenLabs'e giden ses saniyesi. */
  readonly localSecondsAtFetch: number;
}

/** Canlı sınırın özeti (yönetici istatistiği). */
export interface ElevenLabsLiveUsage {
  readonly creditsUsed: number;
  readonly creditsLimit: number;
  /** Okumadan bu yana yazılan ses düşülmüş, paysız kalan ses saati (bir ondalık). */
  readonly remainingHours: number;
  readonly status: string;
  /** ISO 8601. */
  readonly fetchedAt: string;
  readonly resetsAt: string | null;
}

/** Bu dönemin ElevenLabs kullanımı. */
export interface ElevenLabsUsage {
  /** Dönemin ilk günü (UTC, `YYYY-MM-DD`). */
  readonly cycleStart: string;
  readonly usedHours: number;
  /** Geçerli sınır: güvenlik üst sınırı ile kullanılan + canlı kalan saatten küçüğü. */
  readonly capHours: number;
  /** Kullanım yüzdesi (bir ondalık). */
  readonly percent: number;
  /** Saklı canlı okuma; hiç okunmadıysa null. */
  readonly live: ElevenLabsLiveUsage | null;
}

/** ElevenLabs'e ulaşılamadığında (ağ hatası, zaman aşımı) `ElevenLabsSubscriptionError.status`. */
const unreachableStatus: number = 0;

/** Canlı okuma yapılamadı: durum kodu (ulaşılamadıysa 0) ve ElevenLabs'in hata kodu (varsa) taşınır. */
export class ElevenLabsSubscriptionError extends Error {
  override readonly name: string = "ElevenLabsSubscriptionError";
  readonly status: number;
  readonly code: string | null;

  constructor(status: number, code: string | null, detail: string) {
    super(`ElevenLabs aboneliği okunamadı (durum ${status}, kod ${code ?? "yok"}): ${detail}`);
    this.status = status;
    this.code = code;
  }
}

/** Kapasite dolu ya da bilinmiyor: istemciye anlaşılır 503 (uygulamalar bu kodu yerelleştirilmiş metinle gösterir). */
export function elevenLabsCapacityError(): ApiError {
  return new ApiError("spend_ceiling_reached", "Speech recognition capacity is used up for now; your recording is kept, try processing it again later.");
}

/**
 * Faturalama döneminin ilk günü (UTC): bugün ayın `billingDay`'inden önceyse geçen ayın, değilse bu ayın o günü.
 * `billingDay` 1–28'dir (yapılandırmada doğrulanır). Saf fonksiyondur.
 */
export function billingCycleStart(now: Date, billingDay: number): string {
  const year: number = now.getUTCFullYear();
  const month: number = now.getUTCMonth();
  const start: number = now.getUTCDate() >= billingDay ? Date.UTC(year, month, billingDay) : Date.UTC(year, month - 1, billingDay);
  return dayKey(new Date(start));
}

/**
 * Canlı okumadan kalan ses saniyesi, paysız: kalan kredi / kredi-saat oranı − okumadan bu yana yazılan ses. Saf
 * fonksiyondur.
 */
export function liveRemainingSeconds(snapshot: ElevenLabsSnapshot, localSecondsNow: number, creditsPerAudioHour: number): number {
  const credits: number = Math.max(0, snapshot.creditsLimit - snapshot.creditsUsed);
  return Math.max(0, (credits * 3600) / creditsPerAudioHour - Math.max(0, localSecondsNow - snapshot.localSecondsAtFetch));
}

/**
 * Dönem kullanımı: güvenlik üst sınırı ile (canlı okuma varsa) kullanılan + canlı kalan saatten küçüğü sınırdır. Saf
 * fonksiyondur.
 */
export function elevenLabsUsageOf(usedSeconds: number, capHours: number, cycleStart: string, live: { readonly snapshot: ElevenLabsSnapshot; readonly remainingSeconds: number } | null): ElevenLabsUsage {
  const usedHours: number = usedSeconds / 3600;
  const effectiveCap: number = effectiveCapHours(capHours, usedSeconds, live?.remainingSeconds ?? null);
  return {
    cycleStart,
    usedHours: Math.round(usedHours * 10) / 10,
    capHours: Math.round(effectiveCap * 100) / 100,
    percent: effectiveCap > 0 ? Math.round((usedHours / effectiveCap) * 1000) / 10 : 100,
    live:
      live === null
        ? null
        : {
            creditsUsed: live.snapshot.creditsUsed,
            creditsLimit: live.snapshot.creditsLimit,
            remainingHours: Math.round((live.remainingSeconds / 3600) * 10) / 10,
            status: live.snapshot.status,
            fetchedAt: new Date(live.snapshot.fetchedAtMs).toISOString(),
            resetsAt: live.snapshot.resetsAtMs === null ? null : new Date(live.snapshot.resetsAtMs).toISOString(),
          },
  };
}

/**
 * Geçerli sınır (saat): güvenlik üst sınırı ile (canlı okuma varsa) kullanılan + canlı kalan saatten küçüğü. Saf
 * fonksiyondur.
 */
export function effectiveCapHours(capHours: number, usedSeconds: number, remainingSeconds: number | null): number {
  return remainingSeconds === null ? capHours : Math.min(capHours, (usedSeconds + remainingSeconds) / 3600);
}

/** Kullanım `before`'dan `after`'a çıkarken aşılan en yüksek eşik; aşılan yoksa null. Saf fonksiyondur. */
export function crossedThreshold(beforeSeconds: number, afterSeconds: number, capSeconds: number): number | null {
  const crossed: number[] = elevenLabsAlertThresholds.filter(
    (threshold: number): boolean => beforeSeconds < threshold * capSeconds && afterSeconds >= threshold * capSeconds,
  );
  return crossed.at(-1) ?? null;
}

/**
 * Saklı okuma taze mi: `elevenLabsCapacityFreshMs`'den yeni ve saat geri gitmemiş (okuma "gelecekte" görünmüyor). Saf
 * fonksiyondur.
 */
export function isFresh(snapshot: ElevenLabsSnapshot, nowMs: number): boolean {
  const age: number = nowMs - snapshot.fetchedAtMs;
  return age >= 0 && age < elevenLabsCapacityFreshMs;
}

/** Okuma başarısızken saklı değer hâlâ kullanılabilir mi (`elevenLabsCapacityStaleMs`'den yeni). Saf fonksiyondur. */
export function usableWhileRefreshFails(snapshot: ElevenLabsSnapshot | null, nowMs: number): snapshot is ElevenLabsSnapshot {
  if (snapshot === null) {
    return false;
  }
  const age: number = nowMs - snapshot.fetchedAtMs;
  return age >= 0 && age <= elevenLabsCapacityStaleMs;
}

/**
 * What an audio reservation does with the stored read:
 * - `fresh`: use it as is;
 * - `stale`: read ElevenLabs again; if that fails, keep using it (`elevenlabs_capacity_refresh_failed`);
 * - `expired` / `missing`: read ElevenLabs again; if that fails, no audio is sent (`elevenlabs_capacity_unknown`).
 */
export type SnapshotPhase =
  | { readonly kind: "fresh"; readonly snapshot: ElevenLabsSnapshot }
  | { readonly kind: "stale"; readonly snapshot: ElevenLabsSnapshot }
  | { readonly kind: "expired"; readonly snapshot: ElevenLabsSnapshot }
  | { readonly kind: "missing" };

/** The stored read's phase at `nowMs` (`isFresh`, `usableWhileRefreshFails`). Pure. */
export function snapshotPhase(snapshot: ElevenLabsSnapshot | null, nowMs: number): SnapshotPhase {
  if (snapshot === null) {
    return { kind: "missing" };
  }
  if (isFresh(snapshot, nowMs)) {
    return { kind: "fresh", snapshot };
  }
  return usableWhileRefreshFails(snapshot, nowMs) ? { kind: "stale", snapshot } : { kind: "expired", snapshot };
}

/**
 * Subscription statuses in which ElevenLabs serves speech-to-text. Any other (`past_due`, `incomplete`, `free_disabled`,
 * …) stops new audio before it is sent, whatever credits the read reports.
 */
export const elevenLabsServingStatuses: readonly string[] = ["active", "trialing"];

/** The read's subscription status lets audio go to ElevenLabs. Pure; SQL twin in `elevenLabsLiveLimit`. */
export function subscriptionServes(status: string): boolean {
  return elevenLabsServingStatuses.includes(status);
}

/** The stored row reports no credits left: a 402 mark (`markElevenLabsExhausted`) or a read that said so. Pure. */
export function snapshotExhausted(snapshot: Pick<ElevenLabsSnapshot, "creditsUsed" | "creditsLimit">): boolean {
  return snapshot.creditsUsed >= snapshot.creditsLimit;
}

/**
 * The stored row is the newest observation of ElevenLabs' credits. A read started at `readStartedAtMs` replaces it only
 * when it started later than the stored observation, or at the same instant over a row that is not exhausted: a read
 * that began before a 402 cannot overwrite the 402's "exhausted" mark (the mark wins ties). Pure; SQL twin in
 * `storeSnapshot`.
 */
export function readSupersedes(stored: Pick<ElevenLabsSnapshot, "fetchedAtMs" | "creditsUsed" | "creditsLimit"> | null, readStartedAtMs: number): boolean {
  if (stored === null) {
    return true;
  }
  return readStartedAtMs > stored.fetchedAtMs || (readStartedAtMs === stored.fetchedAtMs && !snapshotExhausted(stored));
}

/**
 * A 402 observed at `observedAtMs` marks the stored row exhausted unless a read that started after the 402 already
 * replaced it. Pure; SQL twin in `markElevenLabsExhausted`.
 */
export function exhaustionSupersedes(stored: Pick<ElevenLabsSnapshot, "fetchedAtMs"> | null, observedAtMs: number): boolean {
  return stored !== null && observedAtMs >= stored.fetchedAtMs;
}

/** SQL: `day`'den bu yana ElevenLabs'e giden ses saniyesi. */
const localSecondsSinceSql: string = "(SELECT COALESCE(SUM(audio_seconds), 0) FROM daily_spend WHERE day >= ?)";
/** SQL: süren (kesinleşmemiş, süresi dolmamış) ses ayırmalarının saniyesi: ElevenLabs'e şu an giden ses. */
const inFlightSecondsSql: string = "(SELECT COALESCE(SUM(audio_seconds), 0) FROM usage_reservations WHERE kind = 'audio' AND expires_at > ?)";

/** `day`'den bu yana ElevenLabs'e giden ses saniyesi. */
async function localSecondsSince(db: D1Database, day: string): Promise<number> {
  const row: { seconds: number } | null = await db.prepare(`SELECT ${localSecondsSinceSql} AS seconds`).bind(day).first<{ seconds: number }>();
  if (row === null) {
    throw new Error("SUM over daily_spend returned no row.");
  }
  return row.seconds;
}

interface SnapshotRow {
  readonly credits_used: number;
  readonly credits_limit: number;
  readonly resets_at: number | null;
  readonly status: string;
  readonly fetched_at: number;
  readonly fetch_day: string;
  readonly local_seconds_at_fetch: number;
}

/** Saklı canlı okuma; hiç okunmadıysa null. */
export async function readElevenLabsSnapshot(db: D1Database): Promise<ElevenLabsSnapshot | null> {
  const row: SnapshotRow | null = await db
    .prepare("SELECT credits_used, credits_limit, resets_at, status, fetched_at, fetch_day, local_seconds_at_fetch FROM elevenlabs_capacity WHERE id = 1")
    .first<SnapshotRow>();
  return row === null
    ? null
    : {
        creditsUsed: row.credits_used,
        creditsLimit: row.credits_limit,
        resetsAtMs: row.resets_at,
        status: row.status,
        fetchedAtMs: row.fetched_at,
        fetchDay: row.fetch_day,
        localSecondsAtFetch: row.local_seconds_at_fetch,
      };
}

/** ElevenLabs hata gövdesinden kod (`detail.code`, eski `detail.status`); okunamazsa null. Saf fonksiyondur. */
export function elevenLabsErrorCode(body: string): string | null {
  let json: unknown;
  try {
    json = JSON.parse(body);
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      return null;
    }
    throw error;
  }
  const parsed = errorDetailSchema.safeParse(json);
  return parsed.success ? (parsed.data.detail.code ?? parsed.data.detail.status ?? null) : null;
}

/**
 * ElevenLabs aboneliğinin kredi durumunu okur (`xi-api-key`; anahtarın "User: Read" izni olmalı). Geçici hatalar ve
 * zaman aşımı uyarıyla (`upstream_retry`) yeniden denenir; sonra son hata fırlatılır. 2xx dışı yanıtta hata gövdesinden
 * yalnızca ElevenLabs'in hata kodu okunur (ör. `insufficient_permissions`: anahtarın izni eksik).
 */
export async function fetchElevenLabsSubscription(platform: OutboundPlatform, apiKey: string): Promise<ElevenLabsSubscription> {
  return withRetries(
    {
      service: "elevenlabs_subscription",
      attempts: subscriptionAttempts,
      baseDelayMs: platform.retryBaseDelayMs,
      isRetryable: (error: unknown): boolean =>
        error instanceof ElevenLabsSubscriptionError && (error.status === unreachableStatus || isRetryableStatus(error.status)),
      recordRetry: platform.recordRetry,
    },
    async (): Promise<ElevenLabsSubscription> => {
      const response: Response = await overNetwork(
        (): Promise<Response> =>
          platform.fetch(elevenLabsSubscriptionUrl, {
            method: "GET",
            headers: { "xi-api-key": apiKey, accept: "application/json" },
            signal: AbortSignal.timeout(subscriptionTimeoutMs),
          }),
      );
      const text: string = await overNetwork((): Promise<string> => response.text());
      if (!response.ok) {
        throw new ElevenLabsSubscriptionError(response.status, elevenLabsErrorCode(text), "yanıt başarısız");
      }
      let json: unknown;
      try {
        json = JSON.parse(text);
      } catch (error: unknown) {
        if (error instanceof SyntaxError) {
          throw new ElevenLabsSubscriptionError(response.status, null, "yanıt JSON değil");
        }
        throw error;
      }
      const parsed = subscriptionSchema.safeParse(json);
      if (!parsed.success) {
        throw new ElevenLabsSubscriptionError(response.status, null, `beklenmeyen yanıt: ${parsed.error.issues.map((issue) => issue.path.join(".")).join(", ")}`);
      }
      const reset: number | null | undefined = parsed.data.next_character_count_reset_unix;
      return {
        creditsUsed: parsed.data.character_count,
        creditsLimit: parsed.data.character_limit,
        resetsAtMs: reset === null || reset === undefined ? null : reset * 1000,
        status: parsed.data.status,
      };
    },
  );
}

/**
 * Ağ adımı (istek ya da gövde okuması): ağ hatası (TypeError) ve zaman aşımı yeniden denenebilir okuma hatasına
 * (`unreachableStatus`) çevrilir; başka hata olduğu gibi fırlatılır.
 */
async function overNetwork<T>(step: () => Promise<T>): Promise<T> {
  try {
    return await step();
  } catch (error: unknown) {
    if (isRetryableUpstreamError(error)) {
      throw new ElevenLabsSubscriptionError(unreachableStatus, null, `ulaşılamadı (${errorName(error)})`);
    }
    throw error;
  }
}

/** Canlı okuma hatası mı (ağ, zaman aşımı, ElevenLabs yanıtı); D1 ve programlama hataları değildir. Saf fonksiyondur. */
function isSubscriptionReadFailure(error: unknown): error is ElevenLabsSubscriptionError {
  return error instanceof ElevenLabsSubscriptionError;
}

/** Hata koduyla loglanabilir ayrıntı. Saf fonksiyondur. */
function readFailureFields(error: ElevenLabsSubscriptionError): { readonly error: string; readonly status: number; readonly code: string | null } {
  return { error: error.name, status: error.status, code: error.code };
}

/**
 * Stores a read started at `now` with the audio counter at that moment and returns the row that holds afterwards. The
 * write is conditional (`readSupersedes`): a read that started before the stored observation (e.g. a 402's "exhausted"
 * mark written while this read was in flight) leaves the row alone and the stored, newer row is returned.
 */
async function storeSnapshot(db: D1Database, subscription: ElevenLabsSubscription, now: Date): Promise<ElevenLabsSnapshot> {
  const fetchDay: string = dayKey(now);
  const row: { local_seconds_at_fetch: number } | null = await db
    .prepare(
      `INSERT INTO elevenlabs_capacity (id, credits_used, credits_limit, resets_at, status, fetched_at, fetch_day, local_seconds_at_fetch)
       SELECT 1, ?1, ?2, ?3, ?4, ?5, ?6, (SELECT COALESCE(SUM(audio_seconds), 0) FROM daily_spend WHERE day >= ?6)
       ON CONFLICT(id) DO UPDATE SET credits_used = excluded.credits_used, credits_limit = excluded.credits_limit,
         resets_at = excluded.resets_at, status = excluded.status, fetched_at = excluded.fetched_at, fetch_day = excluded.fetch_day,
         local_seconds_at_fetch = excluded.local_seconds_at_fetch
       WHERE excluded.fetched_at > elevenlabs_capacity.fetched_at
         OR (excluded.fetched_at = elevenlabs_capacity.fetched_at AND elevenlabs_capacity.credits_used < elevenlabs_capacity.credits_limit)
       RETURNING local_seconds_at_fetch`,
    )
    .bind(subscription.creditsUsed, subscription.creditsLimit, subscription.resetsAtMs, subscription.status, now.getTime(), fetchDay)
    .first<{ local_seconds_at_fetch: number }>();
  if (row !== null) {
    return { ...subscription, fetchedAtMs: now.getTime(), fetchDay, localSecondsAtFetch: row.local_seconds_at_fetch };
  }
  const stored: ElevenLabsSnapshot | null = await readElevenLabsSnapshot(db);
  if (stored === null) {
    throw new Error("elevenlabs_capacity upsert wrote no row and none is stored.");
  }
  log("info", "elevenlabs_capacity_read_superseded", { readStartedAt: now.getTime(), storedAt: stored.fetchedAtMs, storedExhausted: snapshotExhausted(stored) });
  return stored;
}

/** Error for a read whose subscription status does not serve speech-to-text (`subscriptionServes`); writes an alert. */
function inactiveSubscription(snapshot: ElevenLabsSnapshot): ApiError {
  log("alert", "elevenlabs_subscription_inactive", { status: snapshot.status, creditsUsed: snapshot.creditsUsed, creditsLimit: snapshot.creditsLimit });
  return elevenLabsCapacityError();
}

/** Abonelik ödenmiyor ya da kapalıysa alarm yazar (krediler kalsa da istekler reddedilebilir). */
function alertOnSubscriptionStatus(subscription: ElevenLabsSubscription): void {
  if (subscription.status !== "active" && subscription.status !== "trialing") {
    log("alert", "elevenlabs_subscription_status", { status: subscription.status, creditsUsed: subscription.creditsUsed, creditsLimit: subscription.creditsLimit });
  }
}

/** Canlı okumayı ElevenLabs'ten tazeler ve saklar (günlük Cron ve yönetici; hata olduğu gibi fırlatılır). */
export async function refreshElevenLabsSnapshot(db: D1Database, platform: OutboundPlatform, config: Config, now: Date): Promise<ElevenLabsSnapshot> {
  const subscription: ElevenLabsSubscription = await fetchElevenLabsSubscription(platform, config.secrets.elevenLabs);
  alertOnSubscriptionStatus(subscription);
  return storeSnapshot(db, subscription, now);
}

/**
 * Ses ayırmadan (ya da deneme toplantısı açmadan) önceki canlı okuma: saklı değer tazeyse o, değilse ElevenLabs'ten
 * yeniden okunur. Okuma başarısızsa saklı değer `elevenLabsCapacityStaleMs`'den yeniyse `elevenlabs_capacity_refresh_failed`
 * alarmıyla kullanılır; daha eskiyse ya da hiç yoksa `elevenlabs_capacity_unknown` alarmı ve `503 spend_ceiling_reached`
 * (kapasite bilinmeden ses gönderilmez).
 */
export async function currentElevenLabsSnapshot(db: D1Database, platform: OutboundPlatform, config: Config, now: Date): Promise<ElevenLabsSnapshot> {
  const phase: SnapshotPhase = snapshotPhase(await readElevenLabsSnapshot(db), now.getTime());
  if (phase.kind === "fresh") {
    return phase.snapshot;
  }
  try {
    return await refreshElevenLabsSnapshot(db, platform, config, now);
  } catch (error: unknown) {
    if (!isSubscriptionReadFailure(error)) {
      throw error;
    }
    const ageMinutes: number | null = phase.kind === "missing" ? null : Math.round((now.getTime() - phase.snapshot.fetchedAtMs) / 60_000);
    if (phase.kind === "stale") {
      log("alert", "elevenlabs_capacity_refresh_failed", { ageMinutes, ...readFailureFields(error) });
      return phase.snapshot;
    }
    log("alert", "elevenlabs_capacity_unknown", { ageMinutes, staleAfterMinutes: elevenLabsCapacityStaleMs / 60_000, ...readFailureFields(error) });
    throw elevenLabsCapacityError();
  }
}

/**
 * `currentElevenLabsSnapshot` for sending audio: a read whose subscription does not serve speech-to-text
 * (`subscriptionServes`) stops here with `elevenlabs_subscription_inactive` and `503 spend_ceiling_reached`.
 */
async function servingElevenLabsSnapshot(db: D1Database, platform: OutboundPlatform, config: Config, now: Date): Promise<ElevenLabsSnapshot> {
  const snapshot: ElevenLabsSnapshot = await currentElevenLabsSnapshot(db, platform, config, now);
  if (!subscriptionServes(snapshot.status)) {
    throw inactiveSubscription(snapshot);
  }
  return snapshot;
}

/** Bu dönem ElevenLabs'e giden ses saniyesi. */
async function cycleAudioSeconds(db: D1Database, config: Config, now: Date): Promise<{ cycleStart: string; seconds: number }> {
  const cycleStart: string = billingCycleStart(now, config.elevenLabs.billingDay);
  return { cycleStart, seconds: await localSecondsSince(db, cycleStart) };
}

/** Dönem kullanımı, verilen canlı okumayla (yoksa yalnızca güvenlik üst sınırı). */
async function usageWith(db: D1Database, config: Config, snapshot: ElevenLabsSnapshot | null, now: Date): Promise<ElevenLabsUsage> {
  const state: CapacityState = await capacityState(db, config, snapshot, now);
  return elevenLabsUsageOf(state.usedSeconds, config.elevenLabs.monthlyAudioHours, state.cycleStart, state.live);
}

/** Dönem kullanımı (saniye, yuvarlanmamış) ve canlı kalan. */
interface CapacityState {
  readonly cycleStart: string;
  readonly usedSeconds: number;
  readonly live: { readonly snapshot: ElevenLabsSnapshot; readonly remainingSeconds: number } | null;
}

async function capacityState(db: D1Database, config: Config, snapshot: ElevenLabsSnapshot | null, now: Date): Promise<CapacityState> {
  const { cycleStart, seconds } = await cycleAudioSeconds(db, config, now);
  if (snapshot === null) {
    return { cycleStart, usedSeconds: seconds, live: null };
  }
  const remainingSeconds: number = liveRemainingSeconds(snapshot, await localSecondsSince(db, snapshot.fetchDay), config.elevenLabs.creditsPerAudioHour);
  return { cycleStart, usedSeconds: seconds, live: { snapshot, remainingSeconds } };
}

/**
 * Bu dönemin ElevenLabs kullanımı (yönetici istatistiği): saklı canlı okumayla, ElevenLabs'e gitmeden. Hiç canlı okuma
 * yoksa `live` null'dır ve sınır güvenlik üst sınırıdır (panel bunu gösterir; ses ayırma o durumda zaten durur).
 */
export async function elevenLabsUsage(db: D1Database, config: Config, now: Date): Promise<ElevenLabsUsage> {
  return usageWith(db, config, await readElevenLabsSnapshot(db), now);
}

/**
 * Yeni yazılan `addedSeconds` kullanımı geçerli sınırın bir eşiğini (%80, %95) aştırdıysa hemen `alert` yazar (dönem
 * başına eşik başına bir kez: aşım yalnızca bir kesinleştirmede olur). `snapshot` ayırmadan önce okunan canlı okumadır.
 */
export async function alertOnElevenLabsCrossing(db: D1Database, config: Config, snapshot: ElevenLabsSnapshot, addedSeconds: number, now: Date): Promise<void> {
  const state: CapacityState = await capacityState(db, config, snapshot, now);
  const capSeconds: number = effectiveCapHours(config.elevenLabs.monthlyAudioHours, state.usedSeconds, state.live?.remainingSeconds ?? null) * 3600;
  const threshold: number | null = crossedThreshold(state.usedSeconds - addedSeconds, state.usedSeconds, capSeconds);
  if (threshold !== null) {
    const usage: ElevenLabsUsage = elevenLabsUsageOf(state.usedSeconds, config.elevenLabs.monthlyAudioHours, state.cycleStart, state.live);
    log("alert", "elevenlabs_capacity_threshold", { threshold, ...usageFields(usage) });
  }
}

/** Kullanımın log alanları (iç içe nesne yok). Saf fonksiyondur. */
function usageFields(usage: ElevenLabsUsage): Readonly<Record<string, string | number | null>> {
  return {
    cycleStart: usage.cycleStart,
    usedHours: usage.usedHours,
    capHours: usage.capHours,
    percent: usage.percent,
    liveRemainingHours: usage.live?.remainingHours ?? null,
    liveFetchedAt: usage.live?.fetchedAt ?? null,
  };
}

/** Güvenlik üst sınırından kalan ses (SQL): üst sınırın `elevenLabsHardStopRatio`'su − dönem sesi − süren ayırmalar. */
export function elevenLabsStaticLimit(config: Config, now: Date): ReservationLimit {
  return {
    remainingSql: `? - ${localSecondsSinceSql} - ${inFlightSecondsSql}`,
    binds: [elevenLabsHardStopRatio * config.elevenLabs.monthlyAudioHours * 3600, billingCycleStart(now, config.elevenLabs.billingDay), now.getTime()],
    error: elevenLabsCapacityError(),
  };
}

/**
 * Canlı sınırdan kalan ses (SQL): saklı okumanın kalan kredisi / (kredi-saat oranı × `elevenLabsCreditRateMargin`) −
 * `elevenLabsLiveReserveSeconds` − okumadan bu yana yazılan ses − süren ayırmalar. Satır yoksa NULL (koşul geçmez).
 */
export function elevenLabsLiveLimit(config: Config, now: Date): ReservationLimit {
  return {
    remainingSql: `(SELECT MAX(0, c.credits_limit - c.credits_used) * 3600.0 / ? - ?
        - MAX(0, (SELECT COALESCE(SUM(d.audio_seconds), 0) FROM daily_spend d WHERE d.day >= c.fetch_day) - c.local_seconds_at_fetch)
      FROM elevenlabs_capacity c WHERE c.id = 1 AND c.status IN (${elevenLabsServingStatuses.map((status: string): string => `'${status}'`).join(", ")})) - ${inFlightSecondsSql}`,
    binds: [config.elevenLabs.creditsPerAudioHour * elevenLabsCreditRateMargin, elevenLabsLiveReserveSeconds, now.getTime()],
    error: elevenLabsCapacityError(),
  };
}

/** Ses ayırmasının ElevenLabs denetimleri ve ikisinin ortak (reddi tanımak için) hatası. */
export interface ElevenLabsHeadroom {
  readonly snapshot: ElevenLabsSnapshot;
  readonly checks: readonly ReservationCheck[];
  readonly errors: readonly ApiError[];
}

/**
 * Ses ayırmasından önce: canlı okuma (gerekirse tazelenir; bilinmiyorsa 503, bkz. `currentElevenLabsSnapshot`) ve
 * ayırmanın koşullu `INSERT`'üne girecek iki sınır (güvenlik üst sınırı, canlı kalan).
 */
export async function elevenLabsHeadroom(db: D1Database, platform: OutboundPlatform, config: Config, addedSeconds: number, now: Date): Promise<ElevenLabsHeadroom> {
  const snapshot: ElevenLabsSnapshot = await servingElevenLabsSnapshot(db, platform, config, now);
  const limits: readonly ReservationLimit[] = [elevenLabsStaticLimit(config, now), elevenLabsLiveLimit(config, now)];
  return {
    snapshot,
    checks: limits.map((limit: ReservationLimit): ReservationCheck => ({ limit, amount: addedSeconds })),
    errors: limits.map((limit: ReservationLimit): ApiError => limit.error),
  };
}

/** Ayırma ElevenLabs sınırına takıldığında: alarm (kullanım ve canlı kalan ile). */
export async function alertOnElevenLabsRefusal(db: D1Database, config: Config, snapshot: ElevenLabsSnapshot, addedSeconds: number, now: Date): Promise<void> {
  const usage: ElevenLabsUsage = await usageWith(db, config, snapshot, now);
  log("alert", "elevenlabs_capacity_exhausted", { addedSeconds, ...usageFields(usage) });
}

/**
 * ElevenLabs konuşma tanıma isteği kredi yokluğuyla reddedildi (402): saklı okuma tükenmiş işaretlenir (kullanılan =
 * sınır, okuma anı şimdi). Böylece sonraki ayırmalar ElevenLabs'e gitmeden durur; `elevenLabsCapacityFreshMs` sonra
 * canlı okuma gerçek durumu yeniden yazar (kredi yüklendiyse istekler kendiliğinden sürer).
 *
 * `observedAt` is when the 402 arrived (not when the upload started): a read that started before it cannot overwrite the
 * mark (`readSupersedes`), and the mark does not overwrite a read that started after it (`exhaustionSupersedes`).
 */
export async function markElevenLabsExhausted(db: D1Database, observedAt: Date): Promise<void> {
  await db
    .prepare(
      `UPDATE elevenlabs_capacity SET credits_used = MAX(credits_used, credits_limit), fetched_at = ?1, fetch_day = ?2,
         local_seconds_at_fetch = (SELECT COALESCE(SUM(audio_seconds), 0) FROM daily_spend WHERE day >= ?2) WHERE id = 1 AND fetched_at <= ?1`,
    )
    .bind(observedAt.getTime(), dayKey(observedAt))
    .run();
}

/**
 * Yeni deneme toplantısından önce: geçerli sınırın (canlı okumayla) kullanımı `elevenLabsTrialStopRatio`'yu geçtiyse
 * `trial_capacity_reached`. Canlı okuma bilinmiyorsa `currentElevenLabsSnapshot` 503 verir.
 */
export async function requireElevenLabsTrialHeadroom(db: D1Database, platform: OutboundPlatform, config: Config, now: Date): Promise<void> {
  const usage: ElevenLabsUsage = await usageWith(db, config, await servingElevenLabsSnapshot(db, platform, config, now), now);
  if (usage.percent < elevenLabsTrialStopRatio * 100) {
    return;
  }
  log("warn", "elevenlabs_trial_stop", usageFields(usage));
  throw new ApiError("trial_capacity_reached", "Free trials are at capacity right now; try again tomorrow or subscribe.");
}

/**
 * Günlük denetim (Cron): canlı okumayı ElevenLabs'ten tazeler (başarısızsa hata fırlatılır, Cron adımı `alert` yazar)
 * ve kullanım bir eşiğin üstündeyse `alert` yazar. Kullanımı döndürür.
 */
export async function dailyElevenLabsCapacityCheck(db: D1Database, platform: OutboundPlatform, config: Config, now: Date): Promise<ElevenLabsUsage> {
  const usage: ElevenLabsUsage = await usageWith(db, config, await refreshElevenLabsSnapshot(db, platform, config, now), now);
  const reached: number | undefined = elevenLabsAlertThresholds.filter((threshold: number): boolean => usage.percent >= threshold * 100).at(-1);
  if (reached !== undefined) {
    log("alert", "elevenlabs_capacity_high", { threshold: reached, ...usageFields(usage) });
  }
  return usage;
}
