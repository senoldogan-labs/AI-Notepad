import { deepgramUnlinkStartedBeforeStatement } from "./deepgram";
import { errorName, log } from "./log";
import { expiredReservationStatements } from "./reservations";
import { syncTombstoneRetentionDays } from "./sync";
import { dayKey, monthKey } from "./usage";

/** SQL bağ değeri. */
type SqlValue = string | number | null;

/** Temizlik sınırları: her turda en çok `batchSize` satır, tablo başına en çok `maxBatchesPerTable` tur. */
export interface CleanupLimits {
  readonly batchSize: number;
  readonly maxBatchesPerTable: number;
}

/** Adım adı → silinen (ya da kapatılan) satır sayısı. */
export type CleanupReport = Readonly<Record<string, number>>;

/** Bir ya da daha çok temizlik adımı başarısız oldu; diğer adımlar yine çalıştı. Yalnızca adım adlarını taşır. */
export class CleanupFailedError extends Error {
  override readonly name: string = "CleanupFailedError";
  readonly steps: readonly string[];
  /** Başarılı adımların raporu. */
  readonly report: CleanupReport;

  constructor(steps: readonly string[], report: CleanupReport) {
    super(`Temizlik adımları başarısız: ${steps.join(", ")}`);
    this.steps = steps;
    this.report = report;
  }
}

/** Sınırlı turlarla silinecek satırların tablosu ve koşulu. */
interface CleanupTarget {
  /** Rapordaki ad (aynı tabloda birden çok koşul olabilir). */
  readonly name: string;
  readonly table: string;
  readonly where: string;
  readonly binds: readonly SqlValue[];
}

/** Tek toplu işlemde (D1 işlemi) çalışan temizlik adımı; sayı `countIndex`'teki ifadenin değiştirdiği satırdır. */
interface CleanupBatch {
  readonly name: string;
  readonly statements: readonly D1PreparedStatement[];
  readonly countIndex: number;
}

const dayMs: number = 86_400_000;
/** İşlenmiş Stripe olayları 90 gün tutulur (Stripe en çok 3 gün yeniden dener). */
const stripeEventRetentionMs: number = 90 * dayMs;
/** Kopya abonelik kaydının saklama süresi: geç ödenen faturası bu süre içinde iade edilir. */
const duplicateSubscriptionRetentionMs: number = 400 * dayMs;
/** Günlük harcama 90 gün tutulur (maliyet incelemesi için; tavan yalnızca bugüne bakar). */
const dailySpendRetentionMs: number = 90 * dayMs;
/** Kullanıcı başına günlük kullanım 2 gün tutulur (gece yarısını aşan çağrının kesinleştirmesi dünün satırını yazar). */
const dailyUsageRetentionMs: number = 2 * dayMs;
/** Raporlar (geri bildirim, çökme, iletişim; durumundan bağımsız) 180 gün tutulur. */
const reportRetentionMs: number = 180 * dayMs;
/** Kimlik deneme defteri son güncellemeden 730 gün (24 ay) tutulur (bkz. `trialLedger.ts`). */
const trialLedgerRetentionMs: number = 730 * dayMs;
/** Toplantılar, aylık kullanım ve kullanılmayan cihazlar 13 ay (~395 gün) tutulur (yıllık karşılaştırma + bir ay). */
const usageRetentionMs: number = 395 * dayMs;

/**
 * İndirme kaynakları, "Sorunlar" sayaçları ve telemetri toplamları (amaç başına tokenlar, istemci olayları ve süreleri,
 * özellik kullanımı) 400 gün tutulur (yıllık karşılaştırma).
 */
const aggregateCounterRetentionMs: number = 400 * dayMs;
/** Abonelik iptal nedenleri (serbest yorum içerebilir) raporlar gibi 180 gün tutulur. */
const cancellationRetentionMs: number = 180 * dayMs;
/** Günlük anlık görüntü (yalnızca toplamlar; eğilimler için) 5 yıl tutulur. */
const dailyMetricsRetentionMs: number = 1826 * dayMs;
/** Eşitlemede silinen nesnelerin işareti (tombstone) 90 gün tutulur: diğer cihazlar silmeyi bu sürede öğrenir. */
const syncTombstoneRetentionMs: number = syncTombstoneRetentionDays * dayMs;
/** Gelir kayıtları (fatura ve iade tutarları) muhasebe kaydı olarak 10 yıl tutulur (Finlandiya muhasebe yasası). */
const revenueRetentionMs: number = 3653 * dayMs;

/**
 * Zamanlanmış temizliğin sınırları: tablo başına günde en çok 3 × 1000 satır. En kötü durumda 35 tablo koşulu × 3 tur
 * = 105 silme sorgusu + 4 toplu işlemin 9 ifadesi = 114 D1 sorgusu (Cron çağrısının diğer adımları, eşitleme temizliği
 * dahil (`syncCleanup`: en çok ~50 hesap denetimi + 20 önek; asistan temizliği en çok ~500), birkaç yüz sorgu daha ekler). Workers Paid planının çağrı başına 1000 sorgu sınırının çok altındadır; ücretsiz plana (50) dönülürse
 * `maxBatchesPerTable` 2'ye indirilmelidir. Kalan satırlar ertesi gün silinir. Koşul eklerken bu sayıyı güncelle.
 */
export const scheduledCleanupLimits: CleanupLimits = { batchSize: 1000, maxBatchesPerTable: 3 };

/**
 * Sınırlı turlarla silinecek satırlar. Saf fonksiyondur. Denetimlerin baktığı satırlar korunur:
 * - yenileme jetonları yalnızca süresi dolunca ya da ailesi düşürülünce silinir: kullanılmış jetonlar ve yeniden
 *   denemede geçersiz yazılmış halef (`supersededMarker`, bkz. `auth/tokens.ts`) yeniden kullanım ve çalınma algılaması
 *   için kalır (ailenin satır sayısı jeton ömrü içindeki dönüş sayısıyla sınırlıdır); jetonu kalmayan aile silinir
 *   (erişim jetonu aile bulunamayınca zaten geçersizdir);
 * - deneme başlangıçları yalnızca bugün sayılır (IP başına günlük sınır), daha eskileri silinir; indirme ziyaretçi
 *   özetleri de yalnızca bugünün tekilleştirmesi içindir;
 * - aylık kullanım 13 ay tutulur (sınırlar yalnızca bu aya bakar).
 * Bilinçli olarak hiç silinmeyenler (gizlilik politikası, bölüm 10): günlük indirme toplamı (`downloads`: gün ve sayı)
 * ve reddedilen deneme başlatmaları (`trial_refusals`: gün, neden ve sayı) kişisel veri içermeyen iş istatistikleridir;
 * Deepgram canlı metin satırları (`deepgram_live_meetings`) ömür boyu bütçeye sayılır ve toplantı silinirken kopar.
 */
function cleanupTargets(now: Date): CleanupTarget[] {
  const nowMs: number = now.getTime();
  const today: string = dayKey(now);
  return [
    { name: "used_nonces", table: "used_nonces", where: "expires_at <= ?", binds: [nowMs] },
    // Hesaba bağlanmamış Apple jetonu (uygulama adına giriş kod takasından sonra yarıda kaldı): bir gün sonra silinir.
    {
      name: "apple_sign_in_tokens",
      table: "apple_sign_in_tokens",
      where: "stored_at < ? AND NOT EXISTS (SELECT 1 FROM auth_identities a WHERE a.provider = 'apple' AND a.subject = apple_sign_in_tokens.subject)",
      binds: [nowMs - dayMs],
    },
    { name: "transcription_results", table: "transcription_results", where: "expires_at <= ?", binds: [nowMs] },
    // Bağlantıyla paylaşılan notların süresi dolmuş şifreli kopyaları (okuma uçları zaten 404 döner; bkz. `shares.ts`).
    { name: "note_shares", table: "note_shares", where: "expires_at <= ?", binds: [nowMs] },
    // Eşitlemede "cihaz ekle" mesajları 10 dakikada dolar (kurtarma zarfının süresi yoktur).
    { name: "sync_key_envelopes", table: "sync_key_envelopes", where: "expires_at IS NOT NULL AND expires_at <= ?", binds: [nowMs] },
    { name: "device_challenges", table: "device_challenges", where: "expires_at <= ? OR used_at IS NOT NULL", binds: [nowMs] },
    {
      name: "refresh_tokens",
      table: "refresh_tokens",
      where: "expires_at <= ? OR family_id IN (SELECT id FROM refresh_families WHERE revoked_at IS NOT NULL)",
      binds: [nowMs],
    },
    {
      name: "refresh_families",
      table: "refresh_families",
      where: "NOT EXISTS (SELECT 1 FROM refresh_tokens WHERE refresh_tokens.family_id = refresh_families.id)",
      binds: [],
    },
    { name: "stripe_events", table: "stripe_events", where: "processed_at < ?", binds: [nowMs - stripeEventRetentionMs] },
    // RevenueCat olayları Stripe olaylarıyla aynı süre (RevenueCat en geç ~1,5 saat içinde yeniden dener).
    { name: "revenuecat_events", table: "revenuecat_events", where: "processed_at < ?", binds: [nowMs - stripeEventRetentionMs] },
    { name: "duplicate_subscriptions", table: "duplicate_subscriptions", where: "created_at < ?", binds: [nowMs - duplicateSubscriptionRetentionMs] },
    { name: "trial_starts", table: "trial_starts", where: "day < ?", binds: [today] },
    { name: "deleted_trial_starts", table: "deleted_trial_starts", where: "day < ?", binds: [today] },
    { name: "daily_spend", table: "daily_spend", where: "day < ?", binds: [dayKey(new Date(nowMs - dailySpendRetentionMs))] },
    { name: "daily_usage", table: "daily_usage", where: "day < ?", binds: [dayKey(new Date(nowMs - dailyUsageRetentionMs))] },
    { name: "monthly_usage", table: "monthly_usage", where: "month < ?", binds: [monthKey(new Date(nowMs - usageRetentionMs))] },
    { name: "reports", table: "reports", where: "created_at < ?", binds: [nowMs - reportRetentionMs] },
    { name: "trial_identity_ledger", table: "trial_identity_ledger", where: "updated_at < ?", binds: [nowMs - trialLedgerRetentionMs] },
    { name: "download_visitors", table: "download_visitors", where: "day < ?", binds: [today] },
    { name: "download_sources", table: "download_sources", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "ops_events", table: "ops_events", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "llm_purpose_usage", table: "llm_purpose_usage", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "client_event_counts", table: "client_event_counts", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "client_event_durations", table: "client_event_durations", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "conversion_events_daily", table: "conversion_events_daily", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "feature_usage_daily", table: "feature_usage_daily", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "subscription_cancellations", table: "subscription_cancellations", where: "created_at < ?", binds: [nowMs - cancellationRetentionMs] },
    // Günlük toplamlar (token kovaları, konuşma tanıma dilleri, indirme kampanyaları, ilk açılış hunisi) sayaçlar gibi 400 gün.
    { name: "llm_usage_daily", table: "llm_usage_daily", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    {
      name: "transcription_languages_daily",
      table: "transcription_languages_daily",
      where: "day < ?",
      binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))],
    },
    { name: "download_campaigns", table: "download_campaigns", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "app_funnel_daily", table: "app_funnel_daily", where: "day < ?", binds: [dayKey(new Date(nowMs - aggregateCounterRetentionMs))] },
    { name: "daily_metrics", table: "daily_metrics", where: "day < ?", binds: [dayKey(new Date(nowMs - dailyMetricsRetentionMs))] },
    { name: "daily_revenue_metrics", table: "daily_revenue_metrics", where: "day < ?", binds: [dayKey(new Date(nowMs - dailyMetricsRetentionMs))] },
    // Gelir: önce eski faturaların iadeleri (yabancı anahtar), sonra iadesi kalmamış eski faturalar.
    {
      name: "revenue_refunds",
      table: "revenue_refunds",
      where: "invoice_id IN (SELECT invoice_id FROM revenue_invoices WHERE paid_at < ?)",
      binds: [nowMs - revenueRetentionMs],
    },
    {
      name: "revenue_invoices",
      table: "revenue_invoices",
      where: "paid_at < ? AND NOT EXISTS (SELECT 1 FROM revenue_refunds r WHERE r.invoice_id = revenue_invoices.invoice_id)",
      binds: [nowMs - revenueRetentionMs],
    },
    // Hesabı silinmiş davet edilenin satırı (kimlik özeti ve zamanlar) deneme defteri gibi 730 gün tutulur.
    {
      name: "referral_redemptions",
      table: "referral_redemptions",
      where: "referred_user_id IS NULL AND updated_at < ?",
      binds: [nowMs - trialLedgerRetentionMs],
    },
  ];
}

/**
 * Tek toplu işlemli adımlar (birlikte değişmesi gereken satırlar):
 * - süresi dolmuş ayırmalar: tahmini maliyet harcamaya yazılır, satırlar silinir (`expiredReservationStatements`);
 * - 13 aydan eski toplantılar: silinmeden önce kullanıcının deneme toplantıları `users.carried_trial_meetings`'e
 *   eklenir ve deneme başlangıcı korunur (deneme hakkı geri gelmez); Deepgram canlı metin satırları silinmez, rastgele
 *   kimlikle toplantıdan koparılır (`deepgramUnlinkStartedBeforeStatement`);
 * - 13 aydır kullanılmayan cihazlar: önce toplantıların cihaz bağı kaldırılır;
 * - eşitlemede 90 günden eski silme işaretleri (tombstone): önce hesabın `purged_through_rev`'i silinecek en yüksek
 *   revizyona çekilir (daha eski imleçle gelen cihaz baştan eşitler, silmeyi kaçırmaz), sonra en çok 1000 işaret silinir.
 * Saf fonksiyondur.
 */
function cleanupBatches(db: D1Database, now: Date): CleanupBatch[] {
  const cutoff: number = now.getTime() - usageRetentionMs;
  const tombstoneCutoff: number = now.getTime() - syncTombstoneRetentionMs;
  return [
    { name: "usage_reservations", statements: expiredReservationStatements(db, now), countIndex: 1 },
    {
      name: "meeting_sessions",
      statements: [
        db
          .prepare(
            `UPDATE users SET
               carried_trial_meetings = carried_trial_meetings
                 + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = users.id AND m.kind = 'trial' AND m.started_at < ?1),
               trial_started_at = COALESCE(trial_started_at,
                 (SELECT MIN(started_at) FROM meeting_sessions m WHERE m.user_id = users.id AND m.kind = 'trial'))
             WHERE id IN (SELECT user_id FROM meeting_sessions WHERE kind = 'trial' AND started_at < ?1)`,
          )
          .bind(cutoff),
        deepgramUnlinkStartedBeforeStatement(db, cutoff),
        db.prepare("DELETE FROM meeting_sessions WHERE started_at < ?").bind(cutoff),
      ],
      countIndex: 2,
    },
    {
      name: "devices",
      statements: [
        db.prepare("UPDATE meeting_sessions SET device_id = NULL WHERE device_id IN (SELECT id FROM devices WHERE last_used_at < ?)").bind(cutoff),
        db.prepare("DELETE FROM devices WHERE last_used_at < ?").bind(cutoff),
      ],
      countIndex: 1,
    },
    {
      name: "sync_tombstones",
      statements: [
        db
          .prepare(
            `UPDATE sync_accounts SET purged_through_rev = MAX(purged_through_rev,
               (SELECT MAX(o.rev) FROM sync_objects o WHERE o.user_id = sync_accounts.user_id AND o.deleted = 1 AND o.updated_at < ?1))
             WHERE user_id IN (SELECT user_id FROM sync_objects WHERE deleted = 1 AND updated_at < ?1)`,
          )
          .bind(tombstoneCutoff),
        db
          .prepare("DELETE FROM sync_objects WHERE rowid IN (SELECT rowid FROM sync_objects WHERE deleted = 1 AND updated_at < ? LIMIT 1000)")
          .bind(tombstoneCutoff),
      ],
      countIndex: 1,
    },
  ];
}

/** Bir tablodan sınırlı turlarla siler; tur sınırına gelinip satır kaldıysa uyarı loglar. Silinen sayıyı döndürür. */
async function deleteInBatches(db: D1Database, target: CleanupTarget, limits: CleanupLimits): Promise<number> {
  const statement: D1PreparedStatement = db
    .prepare(`DELETE FROM ${target.table} WHERE rowid IN (SELECT rowid FROM ${target.table} WHERE ${target.where} LIMIT ?)`)
    .bind(...target.binds, limits.batchSize);
  let deleted: number = 0;
  for (let batch: number = 1; batch <= limits.maxBatchesPerTable; batch += 1) {
    const changes: number = (await statement.run()).meta.changes;
    deleted += changes;
    if (changes < limits.batchSize) {
      return deleted;
    }
  }
  log("warn", "cleanup_incomplete", { table: target.table, step: target.name, deleted });
  return deleted;
}

/** Toplu işlem adımını çalıştırır; sayılan ifadenin değiştirdiği satır sayısını döndürür. */
async function runBatch(db: D1Database, batch: CleanupBatch): Promise<number> {
  const results: D1Result[] = await db.batch([...batch.statements]);
  return results[batch.countIndex]?.meta.changes ?? 0;
}

/**
 * Süresi dolmuş ya da işi bitmiş satırları siler (`cleanupBatches`, `cleanupTargets`). Günlük Cron Trigger'ı
 * (`wrangler.jsonc` → `triggers.crons`) çağırır. Her adım ayrı denenir: biri başarısız olursa `cleanup_failed` alarmı
 * yazılır ve diğerleri yine çalışır; sonunda başarısız adımların adlarıyla `CleanupFailedError` fırlatılır (Cron
 * çalıştırması başarısız görünür). Hepsi başarılıysa silinen sayıları loglar ve döndürür.
 */
export async function cleanupExpiredRows(db: D1Database, now: Date, limits: CleanupLimits): Promise<CleanupReport> {
  const steps: ReadonlyArray<readonly [string, () => Promise<number>]> = [
    ...cleanupBatches(db, now).map((batch: CleanupBatch): readonly [string, () => Promise<number>] => [batch.name, (): Promise<number> => runBatch(db, batch)]),
    ...cleanupTargets(now).map((target: CleanupTarget): readonly [string, () => Promise<number>] => [
      target.name,
      (): Promise<number> => deleteInBatches(db, target, limits),
    ]),
  ];
  const report: Record<string, number> = {};
  const failed: string[] = [];
  for (const [name, run] of steps) {
    try {
      report[name] = await run();
    } catch (error: unknown) {
      // Bir tablonun hatası diğerlerinin temizliğini durdurmasın; hepsi bitince toplu hata fırlatılır.
      log("alert", "cleanup_failed", { step: name, error: errorName(error) });
      failed.push(name);
    }
  }
  if ((report["usage_reservations"] ?? 0) > 0) {
    log("warn", "usage_reservations_expired", { count: report["usage_reservations"] ?? 0 });
  }
  log("info", "cleanup_done", report);
  if (failed.length > 0) {
    throw new CleanupFailedError(failed, report);
  }
  return report;
}
