import { z } from "zod";
import { dayKey } from "./usage";

/**
 * Uygulamanın ilk açılış hunisi (yönetim paneli "Büyüme"): Mac uygulaması (abonelik sürümü) Ayarlar'daki "Anonim
 * kullanım istatistiklerini paylaş" açıkken kurulumun ilk açılışını ve giriş penceresinin adımlarını
 * `POST /v1/funnel` ile jetonsuz bildirir; indirme ile hesap açılışı arasındaki boşluğu (uygulama hiç açılmadı mı,
 * giriş penceresi kapatıldı mı, giriş hata mı verdi) görünür kılar. Gövde yalnızca sabit listelerden adım ve ayrıntı
 * taşır; sayılar gün, adım, ayrıntı ve uygulama sürümü başına toplanır. IP yalnızca hız sınırının anahtarıdır, hesap ya
 * da başka bir tanımlayıcı saklanmaz.
 *
 * Listeler istemcinin enum'larıyla birebir aynıdır (Swift `ServerParityTests` bu dizileri okur).
 */

/** Huninin adımları: ilk açılış, giriş penceresinin açılması, kapatılması, başarısızlığı ve tamamlanan giriş. */
export const funnelSteps = ["first_launch", "sign_in_started", "sign_in_canceled", "sign_in_failed", "signed_in"] as const;

/** Girişin sağlayıcıları (`sign_in_started`, `sign_in_canceled`, `signed_in` ayrıntısı). */
export const funnelSignInProviders = ["apple", "google"] as const;

/**
 * Girişin başarısız olduğu aşama (`sign_in_failed` ayrıntısı): `window` giriş penceresi açılamadı, `callback` dönüş
 * reddedildi, `server` sunucudaki giriş çağrısı başarısız oldu, `network` giriş çağrısında ağ hatası.
 */
export const funnelFailureStages = ["window", "callback", "server", "network"] as const;

export type FunnelStepName = (typeof funnelSteps)[number];

/** `POST /v1/funnel` gövdesi: adım ve adıma göre izinli ayrıntı (ilk açılışta boş metin). */
export const funnelEventSchema = z.discriminatedUnion("step", [
  z.strictObject({ step: z.literal("first_launch"), detail: z.literal("") }),
  z.strictObject({ step: z.literal("sign_in_started"), detail: z.enum(funnelSignInProviders) }),
  z.strictObject({ step: z.literal("sign_in_canceled"), detail: z.enum(funnelSignInProviders) }),
  z.strictObject({ step: z.literal("sign_in_failed"), detail: z.enum(funnelFailureStages) }),
  z.strictObject({ step: z.literal("signed_in"), detail: z.enum(funnelSignInProviders) }),
]);

export type FunnelEvent = z.output<typeof funnelEventSchema>;

/**
 * Bir günde ayrı sayılan en çok uygulama sürümü. Uç jetonsuzdur ve biçime uyan her `x-app-version` yeni bir satır
 * açabilir; sınır günün (ve 400 günlük saklamanın) satır sayısını sabit tutar. Aynı anda kullanılan sürümler bunun çok
 * altındadır.
 */
export const funnelMaxVersionsPerDay: number = 20;

/** Günün sürüm sınırı dolduktan sonra gelen yeni sürümlerin ortak etiketi (sürüm biçimine uymaz, karışmaz). */
export const funnelOverflowVersion: string = "other";

/**
 * Adımı bugünün (UTC), ayrıntının ve uygulama sürümünün sayacına ekler. Sürüm bugün zaten sayılmışsa ya da günün ayrı
 * sürümleri `funnelMaxVersionsPerDay`'in altındaysa kendi adıyla, değilse `funnelOverflowVersion` olarak sayılır. Seçim
 * yazımla aynı ifadededir (birincil anahtarın `day` öneki kullanılır).
 */
export async function recordFunnelEvent(db: D1Database, event: FunnelEvent, appVersion: string, now: Date): Promise<void> {
  await db
    .prepare(
      `INSERT INTO app_funnel_daily (day, step, detail, app_version, count)
       SELECT ?1, ?2, ?3, CASE
           WHEN EXISTS (SELECT 1 FROM app_funnel_daily WHERE day = ?1 AND app_version = ?4)
             OR (SELECT COUNT(DISTINCT app_version) FROM app_funnel_daily WHERE day = ?1) < ?5 THEN ?4
           ELSE ?6 END, 1
       WHERE 1
       ON CONFLICT(day, step, detail, app_version) DO UPDATE SET count = count + 1`,
    )
    .bind(dayKey(now), event.step, event.detail, appVersion, funnelMaxVersionsPerDay, funnelOverflowVersion)
    .run();
}

/** Adım ve ayrıntının penceredeki sayısı. */
export interface FirstRunCount {
  readonly step: FunnelStepName;
  readonly detail: string;
  readonly count: number;
}

/** Bir günün ilk açılışları ve tamamlanan girişleri. */
export interface FirstRunDay {
  readonly day: string;
  readonly firstLaunches: number;
  readonly signedIn: number;
}

/**
 * Yönetim panelinin ilk açılış hunisi: her izinli adım ve ayrıntı sabit sırayla (`firstRunKeys`; sayısı yoksa 0) ve
 * pencerenin her günü için ilk açılış ve tamamlanan giriş sayısı (eski gün başta). Sayılar yalnızca paylaşımı açık
 * uygulamalardan gelir (alt sınırdır).
 */
export interface FirstRunFunnel {
  readonly days: number;
  readonly steps: readonly FirstRunCount[];
  readonly byDay: readonly FirstRunDay[];
}

/** Adım ve ayrıntı. */
interface FirstRunKey {
  readonly step: FunnelStepName;
  readonly detail: string;
}

/** Panelde gösterilen adım ve ayrıntıların sırası: huni adımları, her adımda listelerin sırasıyla ayrıntılar. */
const firstRunKeys: readonly FirstRunKey[] = [
  { step: "first_launch", detail: "" },
  ...funnelSignInProviders.map((detail: string): FirstRunKey => ({ step: "sign_in_started", detail })),
  ...funnelSignInProviders.map((detail: string): FirstRunKey => ({ step: "sign_in_canceled", detail })),
  ...funnelFailureStages.map((detail: string): FirstRunKey => ({ step: "sign_in_failed", detail })),
  ...funnelSignInProviders.map((detail: string): FirstRunKey => ({ step: "signed_in", detail })),
];

interface StepDetailRow {
  readonly step: string;
  readonly detail: string;
  readonly count: number;
}

interface DayStepRow {
  readonly day: string;
  readonly step: string;
  readonly count: number;
}

/** Satırlardan panelin hunisi: izinli her adım ve ayrıntı sırasıyla, pencerenin her günü. Saf fonksiyondur. */
export function firstRunFunnel(days: readonly string[], totals: readonly StepDetailRow[], daily: readonly DayStepRow[]): FirstRunFunnel {
  const countOf = (step: string, detail: string): number =>
    totals.find((row: StepDetailRow): boolean => row.step === step && row.detail === detail)?.count ?? 0;
  const dayCountOf = (day: string, step: FunnelStepName): number => daily.find((row: DayStepRow): boolean => row.day === day && row.step === step)?.count ?? 0;
  return {
    days: days.length,
    steps: firstRunKeys.map((key: FirstRunKey): FirstRunCount => ({ step: key.step, detail: key.detail, count: countOf(key.step, key.detail) })),
    byDay: days.map((day: string): FirstRunDay => ({ day, firstLaunches: dayCountOf(day, "first_launch"), signedIn: dayCountOf(day, "signed_in") })),
  };
}

/** Penceredeki (`days`, eski gün başta) ilk açılış hunisi: tüm sürümlerin toplamı. */
export async function adminFirstRun(db: D1Database, days: readonly string[]): Promise<FirstRunFunnel> {
  const firstDay: string | undefined = days[0];
  if (firstDay === undefined) {
    throw new RangeError("İlk açılış hunisinin penceresi boş.");
  }
  const [totals, daily] = await Promise.all([
    db.prepare("SELECT step, detail, SUM(count) AS count FROM app_funnel_daily WHERE day >= ? GROUP BY step, detail").bind(firstDay).all<StepDetailRow>(),
    db
      .prepare("SELECT day, step, SUM(count) AS count FROM app_funnel_daily WHERE day >= ? AND step IN ('first_launch', 'signed_in') GROUP BY day, step")
      .bind(firstDay)
      .all<DayStepRow>(),
  ]);
  return firstRunFunnel(days, totals.results, daily.results);
}
