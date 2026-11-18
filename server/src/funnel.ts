import { z } from "zod";
import { dayKey } from "./usage";

/**
 * Uygulamanın ilk açılış hunisi (yönetim paneli "Büyüme"): Mac ve iPhone uygulaması (abonelik sürümü) Ayarlar'daki
 * "Anonim kullanım istatistiklerini paylaş" açıkken kurulumun ilk açılışını, giriş penceresinin adımlarını ve girişten
 * sonraki karşılamanın adımlarını `POST /v1/funnel` ile jetonsuz bildirir; indirme ile ilk toplantı arasındaki boşluğu
 * (uygulama hiç açılmadı mı, giriş penceresi kapatıldı mı, giriş hata mı verdi, karşılama hangi adımda bırakıldı)
 * görünür kılar. Gövde yalnızca sabit listelerden adım ve ayrıntı
 * taşır; sayılar gün, adım, ayrıntı ve uygulama sürümü başına toplanır. IP yalnızca hız sınırının anahtarıdır, hesap ya
 * da başka bir tanımlayıcı saklanmaz.
 *
 * Listeler istemcinin enum'larıyla birebir aynıdır (Swift `ServerParityTests` bu dizileri okur).
 */

/**
 * Huninin adımları: ilk açılış, giriş penceresinin açılması, kapatılması, başarısızlığı, tamamlanan giriş, girişten
 * sonraki karşılamanın ilk kez gösterilen her adımı ve karşılamanın kapanışı (0.2.12+).
 */
export const funnelSteps = [
  "first_launch",
  "sign_in_started",
  "sign_in_canceled",
  "sign_in_failed",
  "signed_in",
  "onboarding_step",
  "onboarding_closed",
] as const;

/** Girişin sağlayıcıları (`sign_in_started`, `sign_in_canceled`, `signed_in` ayrıntısı). */
export const funnelSignInProviders = ["apple", "google"] as const;

/**
 * Girişin başarısız olduğu aşama (`sign_in_failed` ayrıntısı): `window` giriş penceresi açılamadı, `callback` dönüş
 * reddedildi, `server` sunucudaki giriş çağrısı başarısız oldu, `network` giriş çağrısında ağ hatası.
 */
export const funnelFailureStages = ["window", "callback", "server", "network"] as const;

/** Abonelik sürümünün karşılama adımları, gösterilme sırasıyla (`onboarding_step` ayrıntısı). */
export const funnelOnboardingSteps = ["welcome", "calendar", "permissions", "sample", "ready"] as const;

/** Karşılamanın kapanışı (`onboarding_closed` ayrıntısı): son adımda bitirildi ya da "Kurulumu atla" ile atlandı. */
export const funnelOnboardingEndings = ["finished", "skipped"] as const;

export type FunnelStepName = (typeof funnelSteps)[number];

/** `POST /v1/funnel` gövdesi: adım ve adıma göre izinli ayrıntı (ilk açılışta boş metin). */
export const funnelEventSchema = z.discriminatedUnion("step", [
  z.strictObject({ step: z.literal("first_launch"), detail: z.literal("") }),
  z.strictObject({ step: z.literal("sign_in_started"), detail: z.enum(funnelSignInProviders) }),
  z.strictObject({ step: z.literal("sign_in_canceled"), detail: z.enum(funnelSignInProviders) }),
  z.strictObject({ step: z.literal("sign_in_failed"), detail: z.enum(funnelFailureStages) }),
  z.strictObject({ step: z.literal("signed_in"), detail: z.enum(funnelSignInProviders) }),
  z.strictObject({ step: z.literal("onboarding_step"), detail: z.enum(funnelOnboardingSteps) }),
  z.strictObject({ step: z.literal("onboarding_closed"), detail: z.enum(funnelOnboardingEndings) }),
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

/**
 * İç test derlemesi eşiği: bir günde tek bir uygulama sürümü bu kadar giriş penceresi kapatması üretmişse ve
 * kapatmalar başlatmaların bu oranındaysa, o gün+sürüm kullanıcı değil derleme denemesidir. Gerçek kullanıcı bir günde
 * birkaç kez pencereyi kapatır (temiz günlerde 30 günün en yükseği 1); her yeni derlemenin ilk açılışında ise onlarca
 * başlatma/kapatma çifti üretilir (7.11: 99/99, 13.11: 98/98, 16.11: 16/16). Mac sürümü Developer ID ile dağıtıldığı
 * için kurulumun kendisi ayırt edilemez; ayırt eden tek iz bu fırtınadır.
 */
export const buildTestMinCancels: number = 8;

/** Fırtına sayılması için kapatmaların başlatmalara oranı (en az). */
export const buildTestCancelRatio: number = 0.9;

/** Adım ve ayrıntının penceredeki sayısı. */
export interface FirstRunCount {
  readonly step: FunnelStepName;
  readonly detail: string;
  readonly count: number;
}

/** Bir gün, sürüm, adım ve ayrıntının sayısı (ham huni satırı). */
export interface FunnelCellRow {
  readonly day: string;
  readonly app_version: string;
  readonly step: string;
  readonly detail: string;
  readonly count: number;
}

/** Ayıklanan iç test derlemeleri: kaç gün+sürüm hücresi ve bu hücrelerden kaç giriş penceresi olayı sayılmadı. */
export interface FirstRunBuildTest {
  readonly cells: number;
  readonly events: number;
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
  /** Ayıklanan iç test derlemeleri (0 ise sayılar olduğu gibi kullanıcı trafiğidir). */
  readonly buildTest: FirstRunBuildTest;
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
  ...funnelOnboardingSteps.map((detail: string): FirstRunKey => ({ step: "onboarding_step", detail })),
  ...funnelOnboardingEndings.map((detail: string): FirstRunKey => ({ step: "onboarding_closed", detail })),
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

/** Hücre anahtarı: bir gün ve bir uygulama sürümü. */
function cellKey(day: string, appVersion: string): string {
  return `${day}\u0000${appVersion}`;
}

/**
 * İç test derlemesi hücreleri (`cellKey`): aynı gün ve sürümde giriş penceresi kapatmaları `buildTestMinCancels`'ı
 * aşıyor ve başlatmaların en az `buildTestCancelRatio` kadarıysa, o hücre kullanıcı değil derleme denemesidir. Saf
 * fonksiyondur.
 */
export function buildTestCells(rows: readonly FunnelCellRow[]): ReadonlySet<string> {
  const started: Map<string, number> = new Map();
  const canceled: Map<string, number> = new Map();
  for (const row of rows) {
    const key: string = cellKey(row.day, row.app_version);
    if (row.step === "sign_in_started") {
      started.set(key, (started.get(key) ?? 0) + row.count);
    } else if (row.step === "sign_in_canceled") {
      canceled.set(key, (canceled.get(key) ?? 0) + row.count);
    }
  }
  const cells: Set<string> = new Set();
  for (const [key, closed] of canceled) {
    if (closed < buildTestMinCancels) {
      continue;
    }
    if (closed >= (started.get(key) ?? 0) * buildTestCancelRatio) {
      cells.add(key);
    }
  }
  return cells;
}

/**
 * Satırlardan panelin hunisi: iç test derlemesi hücreleri (bkz. `buildTestCells`) düşülür, izinli her adım ve ayrıntı
 * sırasıyla, pencerenin her günü. Saf fonksiyondur.
 */
export function firstRunFunnel(days: readonly string[], rows: readonly FunnelCellRow[]): FirstRunFunnel {
  const cells: ReadonlySet<string> = buildTestCells(rows);
  const totals: Map<string, StepDetailRow> = new Map();
  const daily: Map<string, DayStepRow> = new Map();
  let excluded: number = 0;
  for (const row of rows) {
    // İç test derlemesinde yalnız giriş penceresinin olayları düşülür: indirme/ilk açılış ve gerçek giriş aynı gün ve
    // sürümde gerçek kullanıcıdan da gelebilir (derleme sürümü halka açık sürümle aynı numarayı taşır).
    if (row.step.startsWith("sign_in_") && cells.has(cellKey(row.day, row.app_version))) {
      excluded += row.count;
      continue;
    }
    const totalKey: string = `${row.step}\u0000${row.detail}`;
    const total: StepDetailRow | undefined = totals.get(totalKey);
    if (total === undefined) {
      totals.set(totalKey, { step: row.step, detail: row.detail, count: row.count });
    } else {
      totals.set(totalKey, { step: total.step, detail: total.detail, count: total.count + row.count });
    }
    const dayKeyString: string = `${row.day}\u0000${row.step}`;
    const day: DayStepRow | undefined = daily.get(dayKeyString);
    if (day === undefined) {
      daily.set(dayKeyString, { day: row.day, step: row.step, count: row.count });
    } else {
      daily.set(dayKeyString, { day: day.day, step: day.step, count: day.count + row.count });
    }
  }
  const totalRows: readonly StepDetailRow[] = [...totals.values()];
  const dayRows: readonly DayStepRow[] = [...daily.values()];
  const countOf = (step: string, detail: string): number =>
    totalRows.find((row: StepDetailRow): boolean => row.step === step && row.detail === detail)?.count ?? 0;
  const dayCountOf = (day: string, step: FunnelStepName): number =>
    dayRows.find((row: DayStepRow): boolean => row.day === day && row.step === step)?.count ?? 0;
  return {
    days: days.length,
    steps: firstRunKeys.map((key: FirstRunKey): FirstRunCount => ({ step: key.step, detail: key.detail, count: countOf(key.step, key.detail) })),
    byDay: days.map((day: string): FirstRunDay => ({ day, firstLaunches: dayCountOf(day, "first_launch"), signedIn: dayCountOf(day, "signed_in") })),
    buildTest: { cells: cells.size, events: excluded },
  };
}

/**
 * Penceredeki (`days`, eski gün başta) ilk açılış hunisi: tüm sürümlerin toplamı, iç test derlemeleri ayıklanmış.
 */
export async function adminFirstRun(db: D1Database, days: readonly string[]): Promise<FirstRunFunnel> {
  const firstDay: string | undefined = days[0];
  if (firstDay === undefined) {
    throw new RangeError("İlk açılış hunisinin penceresi boş.");
  }
  const rows = await db
    .prepare("SELECT day, app_version, step, detail, SUM(count) AS count FROM app_funnel_daily WHERE day >= ? GROUP BY day, app_version, step, detail")
    .bind(firstDay)
    .all<FunnelCellRow>();
  return firstRunFunnel(days, rows.results);
}
