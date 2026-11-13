// Yönetim panelinin telemetri verisi (`/v1/admin/telemetry`, son 30 gün; öğeleri kullanım, güvenilirlik ve maliyet
// görünümlerindedir): sürüm benimsenmesi (Mac uygulamasının ve
// macOS'un sürümüne göre etkin hesaplar), amaca göre yapay zekâ tokenları, istemci güvenilirlik olayları (uygulama
// sürümüne ve güne göre), son geçiş ve not süresinin dağılımı, günlük özellik raporları ve abonelik hunisi (Conversion:
// platform ve an başına plan ekranı adımları, hatalar, geri yükleme, plan karışımı, deneme hatırlatması, yükseltme
// bildirimleri ve sunucunun saydığı Stripe ödeme sayfaları; gelir görünümünde). Sürümler hesap başına son değerdir;
// diğer her şey hesaba bağlı olmayan günlük toplamdır. Yanıt sınırda katı biçimde doğrulanır; `conversion` alanı olmayan
// eski sunucu "bildirilmedi" olarak gösterilir.
import {
  ApiResponseError,
  type JsonObject,
  type JsonValue,
  type RawResponse,
  numberField,
  objectArrayField,
  objectField,
  parseObject,
  stringField,
} from "./api";
import { fillTable, formatCompact, formatCount, formatDay, formatRate, node, tableRow } from "./admin-format";
import {
  type AcquisitionSource,
  type AdminTelemetryCopy,
  type CheckoutSource,
  type ConversionChannel,
  type ConversionPlan,
  type ConversionPlatform,
  type ConversionReason,
  type ConversionReminderKind,
  type ConversionRestoreResult,
  type ConversionTier,
  type ConversionTrigger,
  type CountEventKind,
  type DurationEventKind,
  type FeatureName,
  type FlagFeature,
  type LlmPurpose,
  acquisitionSources,
  adminTelemetryCopy,
  checkoutSources,
  conversionChannels,
  checkoutPlans,
  checkoutTiers,
  type CheckoutPlan,
  type CheckoutTier,
  conversionPlans,
  conversionPlatforms,
  conversionReasons,
  conversionReminderKinds,
  conversionRestoreResults,
  conversionTiers,
  conversionTriggers,
  countEventKinds,
  durationEventKinds,
  featureNames,
  flagFeatures,
  llmPurposes,
} from "./admin-telemetry-copy";
import { fill } from "./copy";
import { createViewLoader } from "../lib/admin-load";
import { element } from "./dom";
import { authorizedSend } from "./session";
import { siteLocale } from "../config";

const telemetryText: AdminTelemetryCopy = adminTelemetryCopy;

const telemetryPath: string = "/v1/admin/telemetry";

/** Sürüm başına hesap sayısı. */
export interface VersionUsers {
  readonly version: string;
  readonly users: number;
}

/** Amacın token toplamı. */
export interface PurposeTotal {
  readonly purpose: LlmPurpose;
  readonly inputTokens: number;
  readonly outputTokens: number;
  readonly calls: number;
  /** Web aramaları (yalnız Sor cevabı). */
  readonly webSearches: number;
}

/** Amacın bir günlük token toplamı. */
export interface PurposeDay extends PurposeTotal {
  readonly day: string;
}

/** Sayılan olayın uygulama sürümüne göre toplamı. */
export interface EventCount {
  readonly kind: CountEventKind;
  readonly appVersion: string;
  readonly count: number;
}

/** Sayılan olayın bir günlük toplamı. */
export interface EventDay {
  readonly day: string;
  readonly kind: CountEventKind;
  readonly count: number;
}

/** Süre dilimi: ölçüm sayısı ve süreler toplamı (saniye). */
export interface DurationBucket {
  readonly kind: DurationEventKind;
  readonly bucket: string;
  readonly count: number;
  readonly secondsSum: number;
}

/** Özelliğin (ve varsa değerinin) kullanıcı-günü ve kullanım toplamı. */
export interface FeatureRow {
  readonly feature: FeatureName;
  readonly value: string;
  readonly users: number;
  readonly total: number;
}

/** Hunide bir platform ve an: plan ekranı adımlarının toplamları. */
export interface ConversionFunnelRow {
  readonly platform: ConversionPlatform;
  readonly trigger: ConversionTrigger;
  readonly shown: number;
  readonly selected: number;
  readonly started: number;
  readonly completed: number;
  readonly cancelled: number;
  readonly failed: number;
}

/** Abonelik hunisi (`server/src/conversion.ts` `AdminConversion`; pencerenin toplamları, kimlik yok). */
export interface AdminConversion {
  readonly funnel: readonly ConversionFunnelRow[];
  readonly failures: readonly { readonly platform: ConversionPlatform; readonly reason: ConversionReason; readonly count: number }[];
  readonly restores: readonly { readonly platform: ConversionPlatform; readonly result: ConversionRestoreResult; readonly count: number }[];
  readonly planMix: readonly {
    readonly platform: ConversionPlatform;
    readonly tier: ConversionTier;
    readonly plan: ConversionPlan;
    readonly started: number;
    readonly completed: number;
  }[];
  readonly reminders: readonly { readonly kind: ConversionReminderKind; readonly channel: ConversionChannel; readonly count: number }[];
  readonly upsells: readonly { readonly trigger: ConversionTrigger; readonly shown: number; readonly tapped: number }[];
  /** `completed` and `expired` are 0 from a server that predates the webhook counts. */
  readonly checkouts: readonly {
    readonly source: CheckoutSource;
    readonly tier: CheckoutTier;
    readonly plan: CheckoutPlan;
    readonly count: number;
    readonly completed: number;
    readonly expired: number;
  }[];
  /** "Where did you hear about us?" answers; empty from an older server. */
  readonly heardAbout: readonly { readonly platform: ConversionPlatform; readonly source: AcquisitionSource; readonly count: number }[];
}

/** `GET /v1/admin/telemetry` yanıtı. */
export interface AdminTelemetry {
  readonly windowDays: number;
  readonly versions: { readonly activeUsers: number; readonly apps: readonly VersionUsers[]; readonly os: readonly VersionUsers[] };
  readonly purposes: { readonly totals: readonly PurposeTotal[]; readonly daily: readonly PurposeDay[] };
  readonly events: {
    readonly counts: readonly EventCount[];
    readonly daily: readonly EventDay[];
    readonly durations: readonly DurationBucket[];
    readonly durationBuckets: readonly string[];
  };
  readonly features: { readonly reports: number; readonly rows: readonly FeatureRow[] };
  /** Abonelik hunisi; alanı göndermeyen eski sunucuda null ("bildirilmedi"). */
  readonly conversion: AdminConversion | null;
}

/** Telemetri görünümünün dışarıya açtığı işlemler. */
export interface TelemetryView {
  /** Görünümü (yeniden) yükler. */
  readonly refresh: () => Promise<void>;
  /** Görünüm açılınca: yüklenmediyse yükler, yükleme sürüyorsa onu bekler, yüklendiyse bir şey yapmaz. */
  readonly ensureLoaded: () => Promise<void>;
}

const dayPattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;
/** Süre dilimi etiketi: `le_<saniye>` (en çok) ya da `gt_<saniye>` (üstü). */
const bucketPattern: RegExp = /^(le|gt)_(\d{1,6})$/;

// ---------- Okuma ----------

/** Değeri izinli metinlerden biri olan alan; değilse `ApiResponseError`. */
function literalField<Literal extends string>(object: JsonObject, key: string, allowed: readonly Literal[], response: RawResponse, path: string): Literal {
  const value: string = stringField(object, key, response, path);
  const match: Literal | undefined = allowed.find((candidate: Literal): boolean => candidate === value);
  if (match === undefined) {
    throw new ApiResponseError(path, response.status, `"${key}" bilinmeyen değer "${value}"`, response.text);
  }
  return match;
}

/** Negatif olmayan sayı alanı; değilse `ApiResponseError`. */
function countField(object: JsonObject, key: string, response: RawResponse, path: string): number {
  const value: number = numberField(object, key, response, path);
  if (value < 0) {
    throw new ApiResponseError(path, response.status, `"${key}" negatif`, response.text);
  }
  return value;
}

/** `YYYY-MM-DD` gün alanı. */
function dayField(object: JsonObject, response: RawResponse, path: string): string {
  const day: string = stringField(object, "day", response, path);
  if (!dayPattern.test(day)) {
    throw new ApiResponseError(path, response.status, `"day" YYYY-MM-DD değil: ${day}`, response.text);
  }
  return day;
}

/** Süre dilimi etiketini doğrular. */
function requireBucket(bucket: string, response: RawResponse, path: string): string {
  if (!bucketPattern.test(bucket)) {
    throw new ApiResponseError(path, response.status, `süre dilimi bilinmeyen biçimde: ${bucket}`, response.text);
  }
  return bucket;
}

/** Süre dilimi etiketleri dizisi (sıralı). */
function bucketListField(object: JsonObject, key: string, response: RawResponse, path: string): string[] {
  const value: JsonValue | undefined = object[key];
  if (!Array.isArray(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" dizi değil`, response.text);
  }
  return value.map((item: JsonValue): string => {
    if (typeof item !== "string") {
      throw new ApiResponseError(path, response.status, `"${key}" öğesi metin değil`, response.text);
    }
    return requireBucket(item, response, path);
  });
}

/** Sürüm dizisini okur. */
function versionList(owner: JsonObject, key: string, response: RawResponse, path: string): VersionUsers[] {
  return objectArrayField(owner, key, response, path).map(
    (item: JsonObject): VersionUsers => ({ version: stringField(item, "version", response, path), users: countField(item, "users", response, path) }),
  );
}

/** Amacın token alanlarını okur. */
function purposeTotal(item: JsonObject, response: RawResponse, path: string): PurposeTotal {
  return {
    purpose: literalField(item, "purpose", llmPurposes, response, path),
    inputTokens: countField(item, "inputTokens", response, path),
    outputTokens: countField(item, "outputTokens", response, path),
    calls: countField(item, "calls", response, path),
    webSearches: countField(item, "webSearches", response, path),
  };
}

/**
 * Abonelik hunisini okur: her değer sunucunun listelerinden biri, her sayı negatif olmayan. Alan yoksa (eski sunucu)
 * null; varsa bozuk değer `ApiResponseError`'dır.
 */
export function parseConversion(body: JsonObject, response: RawResponse, path: string): AdminConversion | null {
  if (body["conversion"] === undefined) {
    return null;
  }
  const conversion: JsonObject = objectField(body, "conversion", response, path);
  const platform = (item: JsonObject): ConversionPlatform => literalField(item, "platform", conversionPlatforms, response, path);
  const count = (item: JsonObject, key: string): number => countField(item, key, response, path);
  return {
    funnel: objectArrayField(conversion, "funnel", response, path).map(
      (item: JsonObject): ConversionFunnelRow => ({
        platform: platform(item),
        trigger: literalField(item, "trigger", conversionTriggers, response, path),
        shown: count(item, "shown"),
        selected: count(item, "selected"),
        started: count(item, "started"),
        completed: count(item, "completed"),
        cancelled: count(item, "cancelled"),
        failed: count(item, "failed"),
      }),
    ),
    failures: objectArrayField(conversion, "failures", response, path).map((item: JsonObject) => ({
      platform: platform(item),
      reason: literalField(item, "reason", conversionReasons, response, path),
      count: count(item, "count"),
    })),
    restores: objectArrayField(conversion, "restores", response, path).map((item: JsonObject) => ({
      platform: platform(item),
      result: literalField(item, "result", conversionRestoreResults, response, path),
      count: count(item, "count"),
    })),
    planMix: objectArrayField(conversion, "planMix", response, path).map((item: JsonObject) => ({
      platform: platform(item),
      tier: literalField(item, "tier", conversionTiers, response, path),
      plan: literalField(item, "plan", conversionPlans, response, path),
      started: count(item, "started"),
      completed: count(item, "completed"),
    })),
    reminders: objectArrayField(conversion, "reminders", response, path).map((item: JsonObject) => ({
      kind: literalField(item, "kind", conversionReminderKinds, response, path),
      channel: literalField(item, "channel", conversionChannels, response, path),
      count: count(item, "count"),
    })),
    upsells: objectArrayField(conversion, "upsells", response, path).map((item: JsonObject) => ({
      trigger: literalField(item, "trigger", conversionTriggers, response, path),
      shown: count(item, "shown"),
      tapped: count(item, "tapped"),
    })),
    checkouts: objectArrayField(conversion, "checkouts", response, path).map((item: JsonObject) => ({
      source: literalField(item, "source", checkoutSources, response, path),
      tier: literalField(item, "tier", checkoutTiers, response, path),
      plan: literalField(item, "plan", checkoutPlans, response, path),
      count: count(item, "count"),
      completed: item["completed"] === undefined ? 0 : count(item, "completed"),
      expired: item["expired"] === undefined ? 0 : count(item, "expired"),
    })),
    heardAbout:
      conversion["heardAbout"] === undefined
        ? []
        : objectArrayField(conversion, "heardAbout", response, path).map((item: JsonObject) => ({
            platform: platform(item),
            source: literalField(item, "source", acquisitionSources, response, path),
            count: count(item, "count"),
          })),
  };
}

/** `GET /v1/admin/telemetry` yanıtını okur. */
export function parseAdminTelemetry(response: RawResponse, path: string): AdminTelemetry {
  const body: JsonObject = parseObject(response, path);
  const versions: JsonObject = objectField(body, "versions", response, path);
  const purposes: JsonObject = objectField(body, "purposes", response, path);
  const events: JsonObject = objectField(body, "events", response, path);
  const features: JsonObject = objectField(body, "features", response, path);
  return {
    windowDays: countField(body, "windowDays", response, path),
    versions: {
      activeUsers: countField(versions, "activeUsers", response, path),
      apps: versionList(versions, "apps", response, path),
      os: versionList(versions, "os", response, path),
    },
    purposes: {
      totals: objectArrayField(purposes, "totals", response, path).map((item: JsonObject): PurposeTotal => purposeTotal(item, response, path)),
      daily: objectArrayField(purposes, "daily", response, path).map(
        (item: JsonObject): PurposeDay => ({ day: dayField(item, response, path), ...purposeTotal(item, response, path) }),
      ),
    },
    events: {
      counts: objectArrayField(events, "counts", response, path).map(
        (item: JsonObject): EventCount => ({
          kind: literalField(item, "kind", countEventKinds, response, path),
          appVersion: stringField(item, "appVersion", response, path),
          count: countField(item, "count", response, path),
        }),
      ),
      daily: objectArrayField(events, "daily", response, path).map(
        (item: JsonObject): EventDay => ({
          day: dayField(item, response, path),
          kind: literalField(item, "kind", countEventKinds, response, path),
          count: countField(item, "count", response, path),
        }),
      ),
      durations: objectArrayField(events, "durations", response, path).map(
        (item: JsonObject): DurationBucket => ({
          kind: literalField(item, "kind", durationEventKinds, response, path),
          bucket: requireBucket(stringField(item, "bucket", response, path), response, path),
          count: countField(item, "count", response, path),
          secondsSum: countField(item, "secondsSum", response, path),
        }),
      ),
      durationBuckets: bucketListField(events, "durationBuckets", response, path),
    },
    features: {
      reports: countField(features, "reports", response, path),
      rows: objectArrayField(features, "rows", response, path).map(
        (item: JsonObject): FeatureRow => ({
          feature: literalField(item, "feature", featureNames, response, path),
          value: stringField(item, "value", response, path),
          users: countField(item, "users", response, path),
          total: countField(item, "total", response, path),
        }),
      ),
    },
    conversion: parseConversion(body, response, path),
  };
}

/** Telemetri özetini getirir. */
export async function fetchTelemetry(): Promise<AdminTelemetry> {
  return parseAdminTelemetry(await authorizedSend({ method: "GET", path: telemetryPath, body: null, attempts: 3 }), telemetryPath);
}

// ---------- Biçimlendirme (saf) ----------

/** Saniyeyi kısa yazar ("45 s", "2 min", "1.5 min"). Saf fonksiyondur. */
export function formatSeconds(seconds: number): string {
  return seconds < 60
    ? fill(telemetryText.seconds, { value: formatCount(Math.round(seconds)) })
    : fill(telemetryText.minutes, { value: formatCount(Math.round((seconds / 60) * 10) / 10) });
}

/** Süre dilimi etiketinin metni ("≤10 s", ">60 min"); biçim okunurken doğrulanmıştır. Saf fonksiyondur. */
export function bucketLabel(bucket: string): string {
  const match: RegExpExecArray | null = bucketPattern.exec(bucket);
  const seconds: number = Number(match?.[2] ?? "0");
  return fill(match?.[1] === "gt" ? telemetryText.bucketOver : telemetryText.bucketAtMost, { value: formatSeconds(seconds) });
}

/** Dil kodunun İngilizce adı ("Turkish (tr)"); tanınmazsa yalnızca kod. Saf fonksiyondur. */
export function languageLabel(code: string): string {
  const names: Intl.DisplayNames = new Intl.DisplayNames([siteLocale], { type: "language" });
  const name: string | undefined = names.of(code);
  return name === undefined || name === code ? code : `${name} (${code})`;
}

/** Değer etiketi: bilinen kodun adı, bilinmeyen (sunucuya yeni eklenmiş) kod olduğu gibi. Saf fonksiyondur. */
function knownLabel(labels: Readonly<Record<string, string>>, value: string): string {
  return labels[value] ?? value;
}

// ---------- DOM ----------

/** Pay hücresi: ince ölçer ve yüzde. */
function shareCell(part: number, whole: number): HTMLElement {
  const cell: HTMLElement = node("span", "telemetry-share", "");
  const meter: HTMLProgressElement = node("progress", "meter telemetry-share__meter", "");
  meter.max = 1;
  meter.value = whole === 0 ? 0 : part / whole;
  meter.setAttribute("aria-hidden", "true");
  cell.append(meter, node("span", "tabular", formatRate(part, whole)));
  return cell;
}

/** Tabloyu doldurur ve boş satırını gösterir ya da gizler. */
function fillWithEmpty(id: string, rows: readonly HTMLTableRowElement[]): void {
  fillTable(element(`${id}-rows`, HTMLTableSectionElement), rows);
  element(`${id}-empty`, HTMLElement).classList.toggle("hidden", rows.length > 0);
}

/** Sürüm tablosu satırları (çoktan aza). */
function versionRows(versions: readonly VersionUsers[], activeUsers: number): HTMLTableRowElement[] {
  return [...versions]
    .sort((left: VersionUsers, right: VersionUsers): number => right.users - left.users)
    .map((entry: VersionUsers): HTMLTableRowElement => tableRow([node("span", "mono", entry.version), formatCount(entry.users), shareCell(entry.users, activeUsers)]));
}

/** Toplam token. Saf fonksiyondur. */
function tokensOf(total: PurposeTotal): number {
  return total.inputTokens + total.outputTokens;
}

/** Amaç tablosunu ve günlük token tablosunu çizer. */
function renderPurposes(purposes: AdminTelemetry["purposes"]): void {
  const totals: PurposeTotal[] = [...purposes.totals].sort((left: PurposeTotal, right: PurposeTotal): number => tokensOf(right) - tokensOf(left));
  const allTokens: number = totals.reduce((sum: number, total: PurposeTotal): number => sum + tokensOf(total), 0);
  fillWithEmpty(
    "telemetry-purposes",
    totals.map((total: PurposeTotal): HTMLTableRowElement =>
      tableRow([
        telemetryText.purposes[total.purpose],
        formatCount(total.calls),
        formatCompact(total.inputTokens),
        formatCompact(total.outputTokens),
        formatCount(total.webSearches),
        shareCell(tokensOf(total), allTokens),
      ]),
    ),
  );
  // Gün başına toplam: amaçlar birleştirilir, satırın ipucu amaçların dökümüdür (yeniden eskiye).
  const days: string[] = [...new Set(purposes.daily.map((entry: PurposeDay): string => entry.day))].sort().reverse();
  const dayTotals: { readonly day: string; readonly calls: number; readonly tokens: number; readonly detail: string }[] = days.map((day: string) => {
    const entries: PurposeDay[] = purposes.daily.filter((entry: PurposeDay): boolean => entry.day === day).sort((left: PurposeDay, right: PurposeDay): number => tokensOf(right) - tokensOf(left));
    return {
      day,
      calls: entries.reduce((sum: number, entry: PurposeDay): number => sum + entry.calls, 0),
      tokens: entries.reduce((sum: number, entry: PurposeDay): number => sum + tokensOf(entry), 0),
      detail: entries.map((entry: PurposeDay): string => `${telemetryText.purposes[entry.purpose]}: ${formatCompact(tokensOf(entry))}`).join(" · "),
    };
  });
  const peak: number = Math.max(0, ...dayTotals.map((entry): number => entry.tokens));
  fillWithEmpty(
    "telemetry-tokens-daily",
    dayTotals.map((entry): HTMLTableRowElement => {
      const row: HTMLTableRowElement = tableRow([formatDay(entry.day), formatCount(entry.calls), formatCompact(entry.tokens), shareCell(entry.tokens, peak)]);
      row.title = entry.detail;
      return row;
    }),
  );
}

/** Güvenilirlik olaylarını (türe ve sürüme göre, güne göre) çizer. */
function renderEvents(events: AdminTelemetry["events"]): void {
  const kindRows: HTMLTableRowElement[] = countEventKinds
    .map((kind: CountEventKind): { readonly kind: CountEventKind; readonly entries: EventCount[] } => ({
      kind,
      entries: events.counts.filter((entry: EventCount): boolean => entry.kind === kind).sort((left: EventCount, right: EventCount): number => right.count - left.count),
    }))
    .filter((group): boolean => group.entries.length > 0)
    .map((group): HTMLTableRowElement =>
      tableRow([
        telemetryText.countKinds[group.kind],
        formatCount(group.entries.reduce((sum: number, entry: EventCount): number => sum + entry.count, 0)),
        node("span", "small", group.entries.map((entry: EventCount): string => `${entry.appVersion}: ${formatCount(entry.count)}`).join(" · ")),
      ]),
    );
  fillWithEmpty("telemetry-events", kindRows);
  const days: string[] = [...new Set(events.daily.map((entry: EventDay): string => entry.day))].sort().reverse();
  fillWithEmpty(
    "telemetry-events-daily",
    days.map((day: string): HTMLTableRowElement =>
      tableRow([
        formatDay(day),
        ...countEventKinds.map((kind: CountEventKind): string =>
          formatCount(events.daily.filter((entry: EventDay): boolean => entry.day === day && entry.kind === kind).reduce((sum: number, entry: EventDay): number => sum + entry.count, 0)),
        ),
      ]),
    ),
  );
  for (const kind of durationEventKinds) {
    renderDuration(kind, events.durations.filter((entry: DurationBucket): boolean => entry.kind === kind), events.durationBuckets);
  }
}

/** Bir sürenin dağılımını (sunucunun dilim sırasıyla) ve ortalamasını çizer. */
function renderDuration(kind: DurationEventKind, entries: readonly DurationBucket[], buckets: readonly string[]): void {
  const runs: number = entries.reduce((sum: number, entry: DurationBucket): number => sum + entry.count, 0);
  const seconds: number = entries.reduce((sum: number, entry: DurationBucket): number => sum + entry.secondsSum, 0);
  const rows: HTMLTableRowElement[] =
    runs === 0
      ? []
      : buckets.map((bucket: string): HTMLTableRowElement => {
          const count: number = entries.filter((entry: DurationBucket): boolean => entry.bucket === bucket).reduce((sum: number, entry: DurationBucket): number => sum + entry.count, 0);
          return tableRow([bucketLabel(bucket), formatCount(count), shareCell(count, runs)]);
        });
  fillWithEmpty(`telemetry-duration-${kind}`, rows);
  element(`telemetry-duration-${kind}-summary`, HTMLElement).textContent =
    runs === 0 ? "" : fill(telemetryText.durationSummary, { runs: formatCount(runs), mean: formatSeconds(seconds / runs) });
}

/** Bir özelliğin değerli satırları (çoktan aza). Saf fonksiyondur. */
function featureValues(rows: readonly FeatureRow[], feature: FeatureName): FeatureRow[] {
  return rows.filter((row: FeatureRow): boolean => row.feature === feature).sort((left: FeatureRow, right: FeatureRow): number => right.users - left.users);
}

/** Değerli özellik tablosu satırları: değer, kullanıcı-günü, rapora oranı, kullanım. */
function valueRows(rows: readonly FeatureRow[], reports: number, label: (value: string) => string): HTMLTableRowElement[] {
  return rows.map((row: FeatureRow): HTMLTableRowElement => tableRow([label(row.value), formatCount(row.users), shareCell(row.users, reports), formatCount(row.total)]));
}

/** Özellik kullanımını çizer; oranların paydası raporların (kullanıcı-günü) sayısıdır. */
function renderFeatures(features: AdminTelemetry["features"], windowDays: number): void {
  const reports: number = features.reports;
  element("telemetry-features-summary", HTMLElement).textContent = fill(telemetryText.featureReports, { reports: formatCount(reports), days: formatCount(windowDays) });
  const flagRows: HTMLTableRowElement[] =
    reports === 0
      ? []
      : flagFeatures.map((feature: FlagFeature): HTMLTableRowElement => {
          const rows: FeatureRow[] = featureValues(features.rows, feature);
          const users: number = rows.reduce((sum: number, row: FeatureRow): number => sum + row.users, 0);
          const total: number = rows.reduce((sum: number, row: FeatureRow): number => sum + row.total, 0);
          return tableRow([telemetryText.flagFeatures[feature], formatCount(users), shareCell(users, reports), formatCount(total)]);
        });
  fillWithEmpty("telemetry-features", flagRows);
  fillWithEmpty("telemetry-languages", valueRows(featureValues(features.rows, "translation_language"), reports, languageLabel));
  fillWithEmpty(
    "telemetry-integrations",
    valueRows(featureValues(features.rows, "integration"), reports, (value: string): string => knownLabel(telemetryText.integrations, value)),
  );
  fillWithEmpty("telemetry-exports", valueRows(featureValues(features.rows, "export"), reports, (value: string): string => knownLabel(telemetryText.exports, value)));
}

/** Sayı ve oranı tek hücrede ("12 · 40%"); payda 0 ise yalnızca sayı. Saf fonksiyondur. */
function countWithRate(part: number, whole: number): string {
  return whole === 0 ? formatCount(part) : `${formatCount(part)} · ${formatRate(part, whole)}`;
}

/** Abonelik hunisinin tablolarını çizer; sunucu bildirmediyse tablolar boş, not "bildirilmedi" der. */
function renderConversion(conversion: AdminConversion | null): void {
  const text: AdminTelemetryCopy["conversion"] = telemetryText.conversion;
  element("telemetry-conversion-lead", HTMLElement).textContent = conversion === null ? text.notReported : text.lowerBound;
  const data: AdminConversion = conversion ?? { funnel: [], failures: [], restores: [], planMix: [], reminders: [], upsells: [], checkouts: [], heardAbout: [] };
  fillWithEmpty(
    "telemetry-conversion-funnel",
    [...data.funnel]
      .sort((left: ConversionFunnelRow, right: ConversionFunnelRow): number => right.shown - left.shown)
      .map((row: ConversionFunnelRow): HTMLTableRowElement =>
        tableRow([
          text.platforms[row.platform],
          text.triggers[row.trigger],
          formatCount(row.shown),
          formatCount(row.selected),
          formatCount(row.started),
          formatCount(row.completed),
          formatCount(row.cancelled),
          formatCount(row.failed),
          shareCell(row.started, row.shown),
          shareCell(row.completed, row.started),
        ]),
      ),
  );
  fillWithEmpty(
    "telemetry-conversion-failures",
    data.failures.map((row): HTMLTableRowElement => tableRow([text.platforms[row.platform], text.reasons[row.reason], formatCount(row.count)])),
  );
  fillWithEmpty(
    "telemetry-conversion-restores",
    data.restores.map((row): HTMLTableRowElement => tableRow([text.platforms[row.platform], text.restoreResults[row.result], formatCount(row.count)])),
  );
  fillWithEmpty(
    "telemetry-conversion-plans",
    data.planMix.map((row): HTMLTableRowElement =>
      tableRow([text.platforms[row.platform], text.tiers[row.tier], text.plans[row.plan], formatCount(row.started), countWithRate(row.completed, row.started)]),
    ),
  );
  fillWithEmpty(
    "telemetry-conversion-reminders",
    data.reminders.map((row): HTMLTableRowElement => tableRow([text.reminderKinds[row.kind], text.channels[row.channel], formatCount(row.count)])),
  );
  fillWithEmpty(
    "telemetry-conversion-upsells",
    data.upsells.map((row): HTMLTableRowElement => tableRow([text.triggers[row.trigger], formatCount(row.shown), formatCount(row.tapped), shareCell(row.tapped, row.shown)])),
  );
  fillWithEmpty(
    "telemetry-conversion-checkouts",
    data.checkouts.map((row): HTMLTableRowElement => tableRow([
        text.sources[row.source],
        text.tiers[row.tier],
        text.plans[row.plan],
        formatCount(row.count),
        countWithRate(row.completed, row.count),
        countWithRate(row.expired, row.count),
      ])),
  );
  fillWithEmpty(
    "telemetry-conversion-heard-about",
    [...data.heardAbout]
      .sort((left, right): number => right.count - left.count)
      .map((row): HTMLTableRowElement => tableRow([text.platforms[row.platform], text.heardAbout[row.source], formatCount(row.count)])),
  );
}

/** Telemetri görünümünü çizer. */
function renderTelemetry(telemetry: AdminTelemetry): void {
  const days: string = formatCount(telemetry.windowDays);
  element("telemetry-window", HTMLElement).textContent = fill(telemetryText.windowNote, { days });
  const active: number = telemetry.versions.activeUsers;
  element("telemetry-active", HTMLElement).textContent = fill(telemetryText.activeUsers, { users: formatCount(active), days });
  fillWithEmpty("telemetry-apps", versionRows(telemetry.versions.apps, active));
  fillWithEmpty("telemetry-os", versionRows(telemetry.versions.os, active));
  renderPurposes(telemetry.purposes);
  renderEvents(telemetry.events);
  renderFeatures(telemetry.features, telemetry.windowDays);
  renderConversion(telemetry.conversion);
}

/** Telemetri görünümünü bağlar. */
export function createTelemetryView(): TelemetryView {
  return createViewLoader(fetchTelemetry, renderTelemetry);
}
