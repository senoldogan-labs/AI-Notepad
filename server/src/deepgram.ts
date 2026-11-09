import { z } from "zod";
import type { Config, DeepgramConfig } from "./config";
import { crossedThreshold } from "./elevenLabsCapacity";
import { ApiError, UpstreamError } from "./errors";
import { log } from "./log";
import { meetingEndSql, meetingLiveSql, meetingTransition, meetingPhase } from "./meetingLifecycle";
import { endPauseForAudio } from "./meetingPause";
import type { MeetingRow } from "./meetings";
import type { Platform } from "./platform";
import { fetchUpstream } from "./upstream";

/**
 * Deepgram canlı metni (abonelik sürümü). Mac uygulaması sesi Deepgram'a doğrudan akıtır; sunucu yalnızca kısa ömürlü
 * jeton verir (`POST https://api.deepgram.com/v1/auth/grant`, anahtar yalnızca Worker'da). Jeton yalnızca bağlantı
 * kurulurken geçerli olmalıdır; kurulan akış jetonun süresi dolsa da sürer. Her bağlantı ve yeniden bağlanma yeni jeton
 * ister.
 *
 * Sunucu akışı göremez ve kesemez; kullanım jetonlarla sınırlanır:
 * - jeton yalnızca açık toplantıya verilir (bitmiş ya da en çok süresi geçmiş toplantıya verilmez) ve ömrü
 *   toplantının en çok süresinin sonunu geçmez (`grantTtlSeconds`): sonradan yeni bağlantı kurulamaz;
 * - toplantı başına toplam jeton türüne göre sınırlıdır (`deepgramGrantLimit`: deneme daha az);
 * - kısa pencerede (`deepgramGrantWindowMs`) en çok `deepgramGrantsPerWindow` jeton: yeniden bağlanmalar sürer ama
 *   aynı anda çok sayıda akış açılamaz.
 *
 * Bütçe: sahibin Deepgram ücretsiz kredisinin bir kısmı (`DEEPGRAM_BUDGET_USD`, ömür boyu). Sunucu akışı görmediği için
 * harcama tahminidir ve temkinlidir: toplantının ilk jetonunda toplantının kalan en çok süresi × akış sayısı
 * (ilk jetonda `x-live-streams` ile bildirilen, yoksa `deepgramStreamsPerMeeting`; a later grant that declares more
 * streams raises it and adds the extra streams for the remaining time, `liveStreamsAfterGrant`) peşin sayılır. The count
 * is the app's declaration, an estimate: a modified app can declare fewer streams than it opens; toplantı bitince (`settleDeepgramMeetings`) gerçek süreye (ilk jetondan
 * bitişe) indirilir. Tahmini harcama bütçeye ulaşınca yeni toplantıya jeton verilmez (`503 deepgram_unavailable`) ve
 * `/v1/me` canlı motoru `whisperkit` der; jeton almış toplantının yeniden bağlanmaları sürer (süresi zaten sayıldı).
 */

/** Jeton isteği adresi. */
export const deepgramGrantUrl: string = "https://api.deepgram.com/v1/auth/grant";

/** Jetonun ömrü (saniye): yalnızca bağlantı kurulurken gerekir, olabildiğince kısa. */
export const deepgramGrantTtlSeconds: number = 30;

/** Abonelik toplantısının ilk saatindeki en çok jeton: iki akışın ilk bağlantıları ve yeniden bağlanmaları. */
export const deepgramGrantsPerMeeting: number = 30;

/** Deneme toplantısının ilk saatindeki en çok jeton (toplantı daha kısa; kötüye kullanıma daha açık). */
export const deepgramTrialGrantsPerMeeting: number = 12;

/** Kısa süreli jeton penceresi: bu sürede bir toplantıya en çok `deepgramGrantsPerWindow` jeton. */
export const deepgramGrantWindowMs: number = 5 * 60_000;

/** Pencere başına en çok jeton: iki akışın ilk bağlantısı ve birkaç yeniden bağlanma (ağ kopması, dil değişimi). */
export const deepgramGrantsPerWindow: number = 8;

/** Toplantı başına en çok eşzamanlı akış ("Sen" ve "Diğerleri"); the estimate counts this many when the app declares none. */
export const deepgramStreamsPerMeeting: number = 2;

/**
 * The Deepgram streams the app declares at a meeting's first grant (`x-live-streams`, 1 or 2): with the on-device live
 * preview a Mac meeting streams only "Sen". Missing (older apps) counts `deepgramStreamsPerMeeting`; anything else is
 * `bad_request`. The meeting's row keeps the highest value declared so far (`liveStreamsAfterGrant`). Pure function.
 */
export function declaredLiveStreams(header: string | null): number {
  if (header === null) {
    return deepgramStreamsPerMeeting;
  }
  if (header !== "1" && header !== "2") {
    throw new ApiError("bad_request", "The x-live-streams header must be 1 or 2.");
  }
  return Number(header);
}

/** İstemcinin kullanacağı model (Nova-3; dil istemcide toplantı dilinden seçilir). */
export const deepgramLiveModel: string = "nova-3";

/** Yeniden deneme dahil en çok deneme (5xx, 429, ağ hatası, zaman aşımı). */
const grantAttempts: number = 3;

/** Deneme başına zaman aşımı. */
const grantTimeoutMs: number = 10_000;

/** İstemciye bildirilen canlı metin motoru. */
export type LiveEngine = "deepgram" | "whisperkit";

/** `POST /v1/live/deepgram-token` yanıtı. Jeton loglanmaz ve sunucuda saklanmaz. */
export interface DeepgramGrant {
  /** Deepgram JWT'si; istemci `Authorization: Bearer <jeton>` ile bağlanır. */
  readonly accessToken: string;
  /** Jetonun kalan ömrü (saniye). */
  readonly expiresIn: number;
  readonly model: string;
  /** İstemci akış adresine `mip_opt_out=true` ekler: Deepgram ses ve metni model geliştirmede kullanmaz, saklamaz. */
  readonly mipOptOut: true;
  /** Bu toplantıda kalan jeton. */
  readonly grantsLeft: number;
}

/** Yönetici istatistiğindeki Deepgram bütçe durumu. */
export interface DeepgramUsage {
  readonly policy: "on" | "off";
  readonly budgetUsd: number;
  /** Tahmini harcama (peşin sayılan açık toplantılar dahil). */
  readonly estimatedUsd: number;
  /** Tahmini harcamanın bütçeye oranı (yüzde, bir ondalık). */
  readonly percent: number;
  /** Bütçeye sayılan akış dakikası (tüm akışlar toplamı). */
  readonly streamMinutes: number;
  /** Deepgram jetonu almış toplantı sayısı ve henüz gerçek süreye indirilmemiş (süren) olanlar. */
  readonly meetings: number;
  readonly openMeetings: number;
  readonly usdPerMinute: number;
}

const grantResponseSchema = z.object({ access_token: z.string().min(1), expires_in: z.number().positive().optional() });

/**
 * Toplantının her tamamlanan saati için ek jeton (abonelik; deneme `deepgramTrialGrantsPerHour`): uzun toplantıda ağ
 * kopmaları, sessizlik sonrası yeniden bağlanmalar ve dil değişimleri birikir; sabit sınır 4 saatlik toplantının son
 * saatlerinde canlı metni kalıcı olarak cihaz içine düşürüyordu. Jeton ücretsizdir (süre ilk jetonda peşin sayılır);
 * sınır yalnızca kötüye kullanıma karşıdır ve pencere sınırı (`deepgramGrantsPerWindow`) aynı kalır.
 */
export const deepgramGrantsPerHour: number = 15;

/** Deneme toplantısının her tamamlanan saati için ek jeton. */
export const deepgramTrialGrantsPerHour: number = 6;

/**
 * Toplantının şimdiki toplam jeton sınırı: türün taban sınırı + başlangıçtan bu yana tamamlanan her saat için ek pay.
 * Saf fonksiyondur.
 */
export function deepgramGrantLimit(kind: MeetingRow["kind"], elapsedMs: number): number {
  const hours: number = Math.floor(Math.max(0, elapsedMs) / 3_600_000);
  return kind === "trial" ? deepgramTrialGrantsPerMeeting + hours * deepgramTrialGrantsPerHour : deepgramGrantsPerMeeting + hours * deepgramGrantsPerHour;
}

/**
 * İstenecek jeton ömrü (saniye): `deepgramGrantTtlSeconds`, toplantının en çok süresinin sonuna kalan süreyi geçmez
 * (en az 1). Saf fonksiyondur.
 */
export function grantTtlSeconds(meeting: MeetingRow, now: Date): number {
  return Math.max(1, Math.min(deepgramGrantTtlSeconds, Math.floor((meeting.max_ends_at - now.getTime()) / 1000)));
}

/** Toplantının jeton sayaçları. */
export interface GrantCounters {
  readonly grants: number;
  readonly window_started_at: number;
  readonly window_grants: number;
}

/**
 * Bir jeton daha verilebilir mi: toplam sınırın altında ve pencere bitmiş ya da pencerede yer var. Saf fonksiyondur.
 * SQL karşılığı `incrementGrant`'tadır.
 */
export function mayGrantMore(counters: GrantCounters, limit: number, nowMs: number): boolean {
  const windowOver: boolean = counters.window_started_at + deepgramGrantWindowMs <= nowMs;
  return counters.grants < limit && (windowOver || counters.window_grants < deepgramGrantsPerWindow);
}

/** Bütçenin akış saniyesi karşılığı. Saf fonksiyondur. */
export function deepgramBudgetSeconds(deepgram: DeepgramConfig): number {
  return Math.floor((deepgram.budgetMicroUsd * 60) / deepgram.microUsdPerMinute);
}

/** Toplantının kalan en çok süresinin `streams` akış için saniyesi (ilk jetondaki peşin tahmin). Saf fonksiyondur. */
export function upfrontChargeSeconds(meeting: MeetingRow, streams: number, now: Date): number {
  return Math.ceil(Math.max(0, meeting.max_ends_at - now.getTime()) / 1000) * streams;
}

/** A granted meeting's stream count and its upfront estimate after a later grant (see `liveStreamsAfterGrant`). */
export interface LiveStreamsEstimate {
  readonly streams: number;
  /** Seconds added to the meeting's upfront estimate (`charged_seconds`). */
  readonly topUpSeconds: number;
}

/**
 * The stream count only grows: a later grant that declares more streams than the meeting's row (e.g. a meeting that
 * started with only "Sen" and reconnects with both) raises it, and the extra streams are charged upfront for the
 * meeting's remaining maximum time (`remainingSecondsPerStream`, `upfrontChargeSeconds` for one stream). A grant that
 * declares fewer streams changes nothing: the count is the app's declaration, so it can only be raised, never lowered
 * by a later request. Settling (`settleDeepgramMeetings`) still cuts the estimate down to the real time. Pure; SQL twin
 * in `incrementGrant`.
 */
export function liveStreamsAfterGrant(stored: number, declared: number, remainingSecondsPerStream: number): LiveStreamsEstimate {
  return { streams: Math.max(stored, declared), topUpSeconds: Math.max(0, declared - stored) * remainingSecondsPerStream };
}

/** Akış saniyesinden bütçe durumu. Saf fonksiyondur. */
export function deepgramUsageOf(deepgram: DeepgramConfig, seconds: number, meetings: number, openMeetings: number): DeepgramUsage {
  const microUsd: number = (seconds * deepgram.microUsdPerMinute) / 60;
  return {
    policy: deepgram.access.policy,
    budgetUsd: deepgram.budgetMicroUsd / 1_000_000,
    estimatedUsd: Math.round(microUsd / 10_000) / 100,
    percent: Math.round((microUsd / deepgram.budgetMicroUsd) * 1000) / 10,
    streamMinutes: Math.round(seconds / 60),
    meetings,
    openMeetings,
    usdPerMinute: deepgram.microUsdPerMinute / 1_000_000,
  };
}

/**
 * Bütçe toplamının SQL'i: tek satırlık `deepgram_budget`; tetikleyiciler onu `SUM(deepgram_live_meetings.charged_seconds)`
 * ile aynı tutar (bkz. göç 0032). Tabloyu taramaz.
 */
const chargedSecondsSql: string = "(SELECT charged_seconds FROM deepgram_budget WHERE id = 1)";

/** Bütçe toplamı satırı. */
interface BudgetRow {
  readonly charged_seconds: number;
  readonly meetings: number;
  readonly open_meetings: number;
}

/** `deepgram_budget` satırı yok: göç 0032 uygulanmamış (bütçe sessizce sıfır sayılmaz). */
export class DeepgramBudgetMissingError extends Error {
  override readonly name: string = "DeepgramBudgetMissingError";

  constructor() {
    super("deepgram_budget satırı yok: göç 0032 uygulanmamış.");
  }
}

/** Bütçe toplamı satırı; yoksa `DeepgramBudgetMissingError`. */
async function budgetRow(db: D1Database): Promise<BudgetRow> {
  const row: BudgetRow | null = await db
    .prepare("SELECT charged_seconds, meetings, open_meetings FROM deepgram_budget WHERE id = 1")
    .first<BudgetRow>();
  if (row === null) {
    throw new DeepgramBudgetMissingError();
  }
  return row;
}

/** Bütçeye sayılan toplam akış saniyesi (tek satır okur). */
async function chargedSeconds(db: D1Database): Promise<number> {
  return (await budgetRow(db)).charged_seconds;
}

/** Yönetici istatistiği: bütçe, tahmini harcama ve toplantı sayıları (tek satır okur). */
export async function deepgramUsage(db: D1Database, config: Config): Promise<DeepgramUsage> {
  const row: BudgetRow = await budgetRow(db);
  return deepgramUsageOf(config.deepgram, row.charged_seconds, row.meetings, row.open_meetings);
}

/**
 * Yeni toplantının canlı metin motoru: politika açık ve tahmini harcama bütçenin altındaysa `deepgram`, değilse
 * `whisperkit` (`/v1/me`). Yalnızca okur.
 */
export async function liveEngine(db: D1Database, config: Config): Promise<LiveEngine> {
  if (config.deepgram.access.policy === "off") {
    return "whisperkit";
  }
  return (await chargedSeconds(db)) < deepgramBudgetSeconds(config.deepgram) ? "deepgram" : "whisperkit";
}

/**
 * Biten toplantıların peşin tahminini gerçek süreye indirir: toplantı bittiyse (kullanıcı bitirdi ya da yeni toplantı
 * başlayınca kapandı), en çok süresi geçtiyse ya da silindiyse (hesap silme, saklama süresi; tahmin olduğu gibi kalır).
 * Gerçek süre = toplantının bildirdiği en yüksek akış sayısı (`streams`) × (bitiş − ilk jeton); tahmin yalnızca küçülür. İndirilen satır sayısını döndürür.
 */
export async function settleDeepgramMeetings(db: D1Database, now: Date): Promise<number> {
  const result: D1Result = await db
    .prepare(
      `UPDATE deepgram_live_meetings
       SET charged_seconds = MIN(charged_seconds, COALESCE((
             SELECT deepgram_live_meetings.streams * MAX(0, CAST((${meetingEndSql("m.")} - deepgram_live_meetings.first_grant_at + 999) / 1000 AS INTEGER))
             FROM meeting_sessions m WHERE m.id = deepgram_live_meetings.meeting_id), charged_seconds)),
         settled_at = ?1
       WHERE settled_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM meeting_sessions m WHERE m.id = deepgram_live_meetings.meeting_id AND ${meetingLiveSql("m.", "?1")})`,
    )
    .bind(now.getTime())
    .run();
  return result.meta.changes;
}

/**
 * Deepgram satırının toplantı kimliğini rastgele yeni bir kimlikle değiştiren SQL (toplantı oturumu silinmeden önce,
 * aynı toplu işlemde). Satır kullanıcı tutmaz; kişiye tek bağı toplantı kimliğidir (sunucuda `meeting_sessions`,
 * cihazda uygulamanın toplantı bağları). Satırın kendisi silinmez: bütçe ömür boyudur ve silme, tetikleyiciyle
 * (göç 0032) harcanmış saniyeleri bütçeden düşerdi. Kimlik değişikliği bütçe tetikleyicilerini çalıştırmaz.
 */
const deepgramUnlinkSql: string = "UPDATE deepgram_live_meetings SET meeting_id = 'unlinked_' || lower(hex(randomblob(16)))";

/** Hesabın toplantılarının Deepgram satırlarını toplantıdan koparır (hesap silme; bkz. `deepgramUnlinkSql`). */
export function deepgramUnlinkUserStatement(db: D1Database, userId: string): D1PreparedStatement {
  return db.prepare(`${deepgramUnlinkSql} WHERE meeting_id IN (SELECT id FROM meeting_sessions WHERE user_id = ?)`).bind(userId);
}

/** `cutoff`'tan önce başlamış toplantıların Deepgram satırlarını koparır (saklama süresi; bkz. `deepgramUnlinkSql`). */
export function deepgramUnlinkStartedBeforeStatement(db: D1Database, cutoff: number): D1PreparedStatement {
  return db.prepare(`${deepgramUnlinkSql} WHERE meeting_id IN (SELECT id FROM meeting_sessions WHERE started_at < ?)`).bind(cutoff);
}

/** Toplantının jeton sayaçları; jeton almamışsa null. */
async function meetingGrantCounters(db: D1Database, meetingId: string): Promise<GrantCounters | null> {
  return db
    .prepare("SELECT grants, window_started_at, window_grants FROM deepgram_live_meetings WHERE meeting_id = ?")
    .bind(meetingId)
    .first<GrantCounters>();
}

/**
 * Jeton yazımının koşulu: toplantı hâlâ canlı (`meetingLiveSql`; eşzamanlı bitiş settle ettikten sonra jeton verilmez).
 * Bağlar: `meeting` toplantı kimliği, `now` şimdi.
 */
function liveMeetingExistsSql(meeting: string, now: string): string {
  return `EXISTS (SELECT 1 FROM meeting_sessions m WHERE m.id = ${meeting} AND ${meetingLiveSql("m.", now)})`;
}

/**
 * Jeton almış toplantının sayaçlarını `mayGrantMore` koşuluyla (tek koşullu ifade) artırır: pencere bittiyse yeni
 * pencere şimdi başlar. Satır indirilmişse (`settled_at`) ya da toplantı artık canlı değilse artmaz. The declared
 * `streams` raises the row's count and tops up its estimate (`liveStreamsAfterGrant`; SET expressions read the row's
 * values before the update). Yeni toplam sayıyı ya da (satır yok, sınırda, indirilmiş ya da toplantı bitmiş) null
 * döndürür.
 */
async function incrementGrant(db: D1Database, meeting: MeetingRow, streams: number, limit: number, now: Date): Promise<number | null> {
  const row: { grants: number } | null = await db
    .prepare(
      `UPDATE deepgram_live_meetings
       SET grants = grants + 1,
         window_grants = CASE WHEN window_started_at + ?1 <= ?2 THEN 1 ELSE window_grants + 1 END,
         window_started_at = CASE WHEN window_started_at + ?1 <= ?2 THEN ?2 ELSE window_started_at END,
         charged_seconds = charged_seconds + MAX(0, ?6 - streams) * ?7,
         streams = MAX(streams, ?6)
       WHERE meeting_id = ?3 AND grants < ?4 AND (window_started_at + ?1 <= ?2 OR window_grants < ?5)
         AND settled_at IS NULL AND ${liveMeetingExistsSql("?3", "?2")}
       RETURNING grants`,
    )
    .bind(deepgramGrantWindowMs, now.getTime(), meeting.id, limit, deepgramGrantsPerWindow, streams, upfrontChargeSeconds(meeting, 1, now))
    .first<{ grants: number }>();
  return row?.grants ?? null;
}

/**
 * Toplantının ilk jetonu: satır yalnızca tahmini harcama bütçenin altındaysa ve toplantı hâlâ canlıysa eklenir (tek
 * koşullu ifade); peşin tahmin `chargeSeconds`, akış sayısı `streams`, jeton penceresi şimdi başlar. Eklendiyse true.
 */
async function insertFirstGrant(db: D1Database, meetingId: string, chargeSeconds: number, streams: number, budgetSeconds: number, now: Date): Promise<boolean> {
  const row: { grants: number } | null = await db
    .prepare(
      `INSERT INTO deepgram_live_meetings (meeting_id, grants, first_grant_at, charged_seconds, settled_at, window_started_at, window_grants, streams)
       SELECT ?1, 1, ?2, ?3, NULL, ?2, 1, ?5 WHERE ${chargedSecondsSql} < ?4 AND ${liveMeetingExistsSql("?1", "?2")}
       ON CONFLICT(meeting_id) DO NOTHING RETURNING grants`,
    )
    .bind(meetingId, now.getTime(), chargeSeconds, budgetSeconds, streams)
    .first<{ grants: number }>();
  return row !== null;
}

/** Bütçe dolu hatası. */
function budgetExhausted(): ApiError {
  return new ApiError("deepgram_unavailable", "Cloud live transcript is unavailable right now; the live transcript is produced on the Mac.");
}

/** Toplantı canlı değil hatası (canlı metin yalnızca kayıt sırasında). */
function meetingNotLive(): ApiError {
  return new ApiError("meeting_not_active", "The meeting recording has ended; cloud live transcript is only available while recording.");
}

/** Toplantının jeton sınırı doldu hatası. */
function grantLimitReached(): ApiError {
  return new ApiError("deepgram_grant_limit", "Too many cloud live transcript reconnects in this meeting; the live transcript continues on the Mac.");
}

/**
 * Jeton hakkını ayırır: jeton almış toplantının sayaçları artar (toplam ya da pencere sınırında `deepgram_grant_limit`);
 * ilk jetonda bütçe koşuluyla satır eklenir (bütçe dolduysa `deepgram_unavailable`). Eşzamanlı ilk jetonlarda ekleme
 * yarışı kaybeden istek sayacı artırır. Bütçe eşiği (%80, %95) aşılınca `alert` yazar. Toplantının jeton sayısını
 * döndürür.
 */
async function reserveGrant(db: D1Database, deepgram: DeepgramConfig, meeting: MeetingRow, streams: number, limit: number, now: Date): Promise<number> {
  const incremented: number | null = await incrementGrant(db, meeting, streams, limit, now);
  if (incremented !== null) {
    return incremented;
  }
  const budgetSeconds: number = deepgramBudgetSeconds(deepgram);
  const before: number = await chargedSeconds(db);
  const charge: number = upfrontChargeSeconds(meeting, streams, now);
  if (await insertFirstGrant(db, meeting.id, charge, streams, budgetSeconds, now)) {
    // Eşikler ElevenLabs kapasitesiyle aynıdır (%80, %95).
    const threshold: number | null = crossedThreshold(before, before + charge, budgetSeconds);
    if (threshold !== null) {
      const usage: DeepgramUsage = deepgramUsageOf(deepgram, before + charge, 0, 0);
      log("alert", "deepgram_budget_threshold", { threshold, estimatedUsd: usage.estimatedUsd, budgetUsd: usage.budgetUsd, percent: usage.percent });
    }
    return 1;
  }
  const raced: number | null = await incrementGrant(db, meeting, streams, limit, now);
  if (raced !== null) {
    return raced;
  }
  // Toplantı arada bitti (eşzamanlı bitiş ya da yeni toplantı): jeton yazılmadı, alınan jeton atılır.
  const current: MeetingRow | null = await db.prepare("SELECT * FROM meeting_sessions WHERE id = ?").bind(meeting.id).first<MeetingRow>();
  if (current === null || meetingTransition(meetingPhase(current, now.getTime()), "liveGrant") !== "apply") {
    log("info", "deepgram_grant_meeting_closed", { userId: meeting.user_id, meetingId: meeting.id });
    throw meetingNotLive();
  }
  if ((await meetingGrantCounters(db, meeting.id)) !== null) {
    throw grantLimitReached();
  }
  const usage: DeepgramUsage = deepgramUsageOf(deepgram, before, 0, 0);
  log("warn", "deepgram_budget_exhausted", { meetingId: meeting.id, estimatedUsd: usage.estimatedUsd, budgetUsd: usage.budgetUsd, percent: usage.percent });
  throw budgetExhausted();
}

/**
 * Deepgram'dan `ttlSeconds` ömürlü jeton ister (`Authorization: Token <anahtar>`, `{"ttl_seconds": …}`). 5xx, 429, ağ
 * hatası ve zaman aşımı uyarıyla `grantAttempts` kez denenir, sonra `UpstreamError` (gövde okunmaz). Yanıt beklenen
 * biçimde değilse `UpstreamError` (yeniden denenmez). Jeton loglanmaz.
 */
async function requestDeepgramToken(platform: Platform, apiKey: string, ttlSeconds: number): Promise<{ accessToken: string; expiresIn: number }> {
  const response: Response = await fetchUpstream(
    platform,
    "deepgram",
    deepgramGrantUrl,
    (): RequestInit => ({
      method: "POST",
      headers: { authorization: `Token ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ ttl_seconds: ttlSeconds }),
    }),
    grantAttempts,
    grantTimeoutMs,
  );
  let json: unknown;
  try {
    json = await response.json();
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      throw new UpstreamError("deepgram", response.status, false, "jeton yanıtı JSON değil");
    }
    throw error;
  }
  const parsed = grantResponseSchema.safeParse(json);
  if (!parsed.success) {
    throw new UpstreamError("deepgram", response.status, false, "jeton yanıtı beklenen biçimde değil");
  }
  // `expires_in` Deepgram'da isteğe bağlıdır; yoksa jetonun ömrü istenen süredir. Uzun bildirilse de istenenden uzun sayılmaz.
  return { accessToken: parsed.data.access_token, expiresIn: Math.min(parsed.data.expires_in ?? ttlSeconds, ttlSeconds) };
}

/**
 * Açık toplantıya Deepgram jetonu verir. Politika kapalıysa ya da bütçe dolduysa `deepgram_unavailable`; toplantı
 * bitmişse ya da en çok süresi geçtiyse (ek süre dahil: canlı metin yalnızca kayıt sırasında) `meeting_not_active`;
 * toplam ya da pencere sınırı dolduysa (`mayGrantMore`) `deepgram_grant_limit`. Jetonun ömrü toplantının en çok
 * süresinin sonunu geçmez (`grantTtlSeconds`). Önce biten toplantıların tahmini indirilir ve hak okunur (boşuna
 * Deepgram çağrılmasın), sonra jeton alınır, sonra hak tek koşullu ifadeyle ayrılır (ayrılamazsa alınan jeton atılır;
 * kullanılmayan jeton ücretsizdir). `streams` (`declaredLiveStreams`) ilk jetonda saklanır; later grants can only raise it (`liveStreamsAfterGrant`). Toplantı duraklatılmışsa duraklatma şimdi kapanır (`endPauseForAudio`): duraklatılan
 * süreye canlı metin alınamaz.
 */
export async function issueDeepgramGrant(
  db: D1Database,
  platform: Platform,
  config: Config,
  requested: MeetingRow,
  streams: number,
  now: Date,
): Promise<DeepgramGrant> {
  const access: Config["deepgram"]["access"] = config.deepgram.access;
  if (access.policy === "off") {
    throw budgetExhausted();
  }
  if (meetingTransition(meetingPhase(requested, now.getTime()), "liveGrant") !== "apply") {
    throw meetingNotLive();
  }
  // Duraklatmada canlı metin bağlantısı duraklatmayı kapatır (bkz. `endPauseForAudio`); en çok bitiş güncellenir.
  const meeting: MeetingRow = await endPauseForAudio(db, requested, now);
  if (meetingTransition(meetingPhase(meeting, now.getTime()), "liveGrant") !== "apply") {
    throw meetingNotLive();
  }
  const limit: number = deepgramGrantLimit(meeting.kind, now.getTime() - meeting.started_at);
  await settleDeepgramMeetings(db, now);
  const counters: GrantCounters | null = await meetingGrantCounters(db, meeting.id);
  if (counters !== null && !mayGrantMore(counters, limit, now.getTime())) {
    log("warn", "deepgram_grant_refused", { userId: meeting.user_id, meetingId: meeting.id, grants: counters.grants, windowGrants: counters.window_grants });
    throw grantLimitReached();
  }
  if (counters === null && (await chargedSeconds(db)) >= deepgramBudgetSeconds(config.deepgram)) {
    throw budgetExhausted();
  }
  const token: { accessToken: string; expiresIn: number } = await requestDeepgramToken(platform, access.apiKey, grantTtlSeconds(meeting, now));
  const reserved: number = await reserveGrant(db, config.deepgram, meeting, streams, limit, now);
  log("info", "deepgram_grant_issued", { userId: meeting.user_id, meetingId: meeting.id, grants: reserved });
  return {
    accessToken: token.accessToken,
    expiresIn: token.expiresIn,
    model: deepgramLiveModel,
    mipOptOut: true,
    grantsLeft: limit - reserved,
  };
}
