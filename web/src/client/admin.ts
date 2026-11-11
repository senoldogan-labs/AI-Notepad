// Yönetim paneli kabuğu: gruplu menü ve on görünüm (admin-layout-copy.ts). Analiz görünümleri (genel bakış, gelir,
// büyüme, kullanım, güvenilirlik, maliyet) birden çok veri kaynağını birlikte gösterir; her kaynağın modülü kendi
// öğelerini hangi görünümde olursa olsun doldurur (admin-insights.ts, admin-product.ts, admin-trends.ts,
// admin-telemetry.ts, admin-ops.ts). Bir görünüm açılınca yalnızca onun kaynakları (`viewSources`) ilk kez yüklenir;
// "Yenile" açık görünümün kaynaklarını ve özet istatistikleri yeniler. Özet istatistikler (`/v1/admin/stats`) bu
// dosyada çizilir: özet şeritleri, döküm kartları, günlük grafikler ve genel bakıştaki "dikkat" listesi (istatistikler,
// içgörüler ve işletim verisinden). Bildirim kutusu (geri bildirim, çökme, iletişim; açık/bitti süzgeci, ayrıntı,
// "bitti" işaretleme, çökme raporunun özeti ve kopyalama düğmeleri — admin-crash.ts) da buradadır. Panel yalnızca
// `/v1/admin/stats` başarılı olunca şablondan eklenir; oturum yoksa ya da sunucu 403 (veya yenilemesi başarısız 401)
// dönerse standart "sayfa bulunamadı" görünümü gösterilir, girişe yönlendirilmez (panelin varlığı belli olmaz).
import { ApiRequestError } from "./api";
import {
  type AdminStats,
  type DayCount,
  type DayMeetings,
  type Insights,
  type Operations,
  type ProTierPolicy,
  type ReportDetail,
  type ReportKind,
  type ReportPage,
  type ReportStatus,
  type ReportSummary,
  type TierSubscriptions,
  fetchReport,
  fetchReports,
  fetchStats,
  setReportStatus,
} from "./admin-api";
import { type BlogView, createBlogView } from "./admin-blog";
import { type ParsedPayload, diagnosticSummaryLine, metricKitDiagnostics, parsePayload } from "./admin-crash";
import { type ChartPoint, renderDailyBars, renderSparkline } from "./admin-chart";
import { fillCounts, formatCount, formatCompact, formatRate, formatTime, formatUsd } from "./admin-format";
import { type InsightsView, createInsightsView } from "./admin-insights";
import { type AdminLayoutCopy, type AdminView, adminLayoutCopy, adminViews } from "./admin-layout-copy";
import { type OperationsView, createOperationsView } from "./admin-ops";
import { type ProductView, createProductView } from "./admin-product";
import { type AdminTrends, type TrendDay, type TrendsView, createTrendsView } from "./admin-trends";
import { type TelemetryView, createTelemetryView } from "./admin-telemetry";
import { type UsersView, createUsersView } from "./admin-users";
import { type AdminClientCopy, type ClientCopy, clientCopy, fill } from "./copy";
import { MissingElementError, dataValue, element, errorText, hideNotice, showNotice } from "./dom";
import { SignedOutError, claimTabSession, hasSession } from "./session";
import { testimonialSnippet } from "../testimonials";
import { type ListRequestKind, admitsListRequest } from "../lib/admin-load";
import {
  type SelectionEvent,
  type SelectionState,
  type SelectionTransition,
  initialSelection,
  requestedDetail,
  selectionTransition,
  shouldRender,
} from "../lib/admin-selection-state";

const text: ClientCopy = clientCopy;
const adminText: AdminClientCopy = clientCopy.admin;
const layout: AdminLayoutCopy = adminLayoutCopy;

/** Bir günün milisaniyesi. */
const dayMs: number = 86_400_000;
/** Kapasite uyarısının eşiği (kullanımın sınıra oranı). */
const capacityWarnRatio: number = 0.8;

/** Görünümlerin yüklediği veri kaynakları (özet istatistikler her zaman yüklüdür). */
type DataSource = "insights" | "product" | "trends" | "telemetry" | "operations" | "users" | "blog";

/** Görünüm başına kaynaklar. */
const viewSources: Readonly<Record<AdminView, readonly DataSource[]>> = {
  overview: ["insights", "operations", "trends"],
  revenue: ["insights", "product", "trends", "telemetry"],
  growth: ["insights", "product", "trends"],
  engagement: ["product", "telemetry", "trends"],
  reliability: ["product", "telemetry", "insights"],
  costs: ["product", "trends", "telemetry"],
  users: ["users"],
  inbox: [],
  operations: ["operations"],
  blog: ["blog"],
};

/** Yüklenebilen kaynak: ilk açılışta yükle ve yenile. */
interface Loadable {
  readonly ensureLoaded: () => Promise<void>;
  readonly refresh: () => Promise<void>;
}

/**
 * Bildirim kutusunun durumu. `listRequest` her liste isteğinde artar: sekme ya da süzgeç değiştikten sonra gelen eski
 * sayfa çizilmez.
 */
interface InboxState {
  kind: ReportKind;
  status: ReportStatus;
  items: ReportSummary[];
  nextBefore: number | null;
  /** The report shown in the detail pane and the generation of its latest detail request. */
  selection: SelectionState;
  listRequest: number;
  /** The kind of the latest list request while it runs (null when none runs). */
  listInFlight: ListRequestKind | null;
  /** Yalnızca alıntı izinli geri bildirimler. */
  quotableOnly: boolean;
}

/** "Dikkat" satırının önemi (sıralama da buna göredir). */
type AttentionTone = "danger" | "warn" | "info";

/** "Dikkat" listesinin satırı: önem, ne olduğu, değeri ve tıklanınca açılan görünüm. */
interface AttentionItem {
  readonly tone: AttentionTone;
  readonly label: string;
  readonly value: string;
  readonly view: AdminView;
}

/** "Dikkat" listesinin kaynakları (henüz yüklenmeyen null). */
interface AttentionSources {
  stats: AdminStats;
  insights: Insights | null;
  operations: Operations | null;
}

/** Son `count` günün toplamı (seri eskiden yeniye). Saf fonksiyondur. */
function lastDaysTotal(days: readonly DayCount[], count: number): number {
  return days.slice(-count).reduce((total: number, day: DayCount): number => total + day.count, 0);
}

/** Oran yüzde olarak ("82%"; payda 0 ise "—"). Saf fonksiyondur. */
function percent(part: number, whole: number): string {
  return formatRate(part, whole);
}

/** Tek değerli günler grafiğe. Saf fonksiyondur. */
function countPoints(days: readonly DayCount[]): ChartPoint[] {
  return days.map((day: DayCount): ChartPoint => ({ day: day.day, parts: [{ value: day.count, tone: "main", label: "" }] }));
}

/** Toplantı günleri grafiğe (abonelik altta, deneme üstte). Saf fonksiyondur. */
function meetingPoints(days: readonly DayMeetings[]): ChartPoint[] {
  return days.map(
    (day: DayMeetings): ChartPoint => ({
      day: day.day,
      parts: [
        { value: day.subscription, tone: "main", label: layout.charts.subscription },
        { value: day.trial, tone: "accent", label: layout.charts.trial },
      ],
    }),
  );
}

/** Özet ölçüsünün değerini ve alt satırını yazar; uyarıda ölçü vurgulanır. */
function setKpi(id: string, value: string, sub: string, warn: boolean): void {
  element(`kpi-${id}`, HTMLElement).textContent = value;
  element(`kpi-${id}-sub`, HTMLElement).textContent = sub;
  element(`kpi-${id}-card`, HTMLElement).classList.toggle("kpi--warn", warn);
}

/** Ölçerli özet ölçüsünü doldurur (`max` en az 0,01: boş ölçer); uyarıda ölçer de uyarı rengindedir. */
function setMeter(id: string, value: number, max: number, warn: boolean): void {
  const meter: HTMLProgressElement = element(`kpi-${id}-meter`, HTMLProgressElement);
  meter.max = Math.max(max, 0.01);
  meter.value = Math.min(value, meter.max);
  meter.classList.toggle("meter--warn", warn);
}

/** Döküm kartının satırını yazar; uyarıda satır vurgulanır. */
function setFact(panel: string, row: string, value: string, warn: boolean): void {
  element(`${panel}-${row}`, HTMLElement).textContent = value;
  element(`${panel}-${row}-row`, HTMLElement).classList.toggle("is-warn", warn);
}

/** Kullanımın sınıra oranı eşiği aştı mı. Saf fonksiyondur. */
function nearLimit(used: number, limit: number): boolean {
  return limit > 0 && used >= limit * capacityWarnRatio;
}

/** Deneme reddi sayılarının toplamı. Saf fonksiyondur. */
function refusalTotal(counts: AdminStats["trialRefusals"]["today"]): number {
  return counts.deviceUsed + counts.exhausted + counts.expired + counts.ipDailyLimit;
}

/** Genel bakış: özet şeridi, grafikler ve kapasite kartı. */
function renderOverview(stats: AdminStats): void {
  const meetings30: number = stats.meetings.last30Days.reduce((sum: number, day: DayMeetings): number => sum + day.subscription + day.trial, 0);
  setKpi("ov-mrr", formatUsd(stats.subscriptions.mrrUsd), stats.stripe.mode === "live" ? adminText.stripeLive : adminText.stripeTest, stats.stripe.mode !== "live");
  setKpi("ov-subscribers", formatCount(stats.subscriptions.active), fillCounts(layout.subs.plans, { monthly: stats.subscriptions.monthly, yearly: stats.subscriptions.yearly }), false);
  setKpi("ov-users", formatCount(lastDaysTotal(stats.users.newLast30Days, stats.users.newLast30Days.length)), fillCounts(layout.subs.accountsTotal, { count: stats.users.total }), false);
  setKpi("ov-meetings", formatCount(meetings30), fillCounts(layout.subs.liveNow, { count: stats.usage.openMeetings }), false);
  renderSparkline("ov-users", stats.users.newLast30Days.map((day: DayCount): number => day.count));
  renderSparkline("ov-meetings", stats.meetings.last30Days.map((day: DayMeetings): number => day.subscription + day.trial));

  renderDailyBars("ov-meetings", meetingPoints(stats.meetings.last30Days), formatCount);
  renderDailyBars("ov-users", countPoints(stats.users.newLast30Days), formatCount);
  renderDailyBars("ov-downloads", countPoints(stats.downloads.last30Days), formatCount);

  setFact("ov-capacity", "spend", `${formatUsd(stats.spend.todayUsd)} / ${formatUsd(stats.spend.ceilingUsd)}`, nearLimit(stats.spend.todayUsd, stats.spend.ceilingUsd));
  setFact(
    "ov-capacity",
    "elevenlabs",
    `${formatCount(stats.elevenLabs.usedHours)} / ${formatCount(stats.elevenLabs.capHours)} h · ${Math.round(stats.elevenLabs.percent)}%`,
    stats.elevenLabs.percent >= capacityWarnRatio * 100,
  );
  setFact(
    "ov-capacity",
    "deepgram",
    `${formatUsd(stats.deepgram.estimatedUsd)} / ${formatUsd(stats.deepgram.budgetUsd)} · ${Math.round(stats.deepgram.percent)}%`,
    stats.deepgram.percent >= capacityWarnRatio * 100,
  );
  setFact("ov-capacity", "near", formatCount(stats.usage.usersNearTokenCap), stats.usage.usersNearTokenCap > 0);
  renderTiers(stats.subscriptions.byTier, stats.subscriptions.proTierPolicy);
}

/** Genel bakışın katman kartı: Personal ve Pro aboneleri plana göre ve Pro'nun satış durumu (eski sunucuda bilinmiyor). */
function renderTiers(byTier: TierSubscriptions | null, policy: ProTierPolicy | null): void {
  const tiers: AdminLayoutCopy["facts"]["tiers"] = layout.facts.tiers;
  setFact("ov-tiers", "personal", byTier === null ? tiers.unknown : fillCounts(layout.subs.plans, { monthly: byTier.personal.monthly, yearly: byTier.personal.yearly }), false);
  setFact("ov-tiers", "pro", byTier === null ? tiers.unknown : fillCounts(layout.subs.plans, { monthly: byTier.pro.monthly, yearly: byTier.pro.yearly }), false);
  setFact("ov-tiers", "policy", policy === null ? tiers.unknown : { on: tiers.policyOn, off: tiers.policyOff }[policy], false);
}

/** Genel bakışın gelir eğrileri (günlük anlık görüntülerden; görüntüsüz gün boşluk). */
function renderOverviewTrends(trends: AdminTrends): void {
  renderSparkline("ov-mrr", trends.daily.map((day: TrendDay): number | null => (day.snapshot === null ? null : day.snapshot.mrrListUsd + day.snapshot.appStoreMrrNetUsd)));
  renderSparkline(
    "ov-subscribers",
    trends.daily.map((day: TrendDay): number | null =>
      day.snapshot === null
        ? null
        : day.snapshot.subscriptionsMonthly + day.snapshot.subscriptionsYearly + day.snapshot.appStoreMonthly + day.snapshot.appStoreYearly,
    ),
  );
}

/** Gelir görünümü: özet şeridi, abonelik ve fatura dökümleri. */
function renderRevenue(stats: AdminStats): void {
  const subscriptions: AdminStats["subscriptions"] = stats.subscriptions;
  const conversion: AdminStats["conversion"] = stats.conversion;
  setKpi("mrr", formatUsd(subscriptions.mrrUsd), stats.stripe.mode === "live" ? adminText.stripeLive : adminText.stripeTest, stats.stripe.mode !== "live");
  setKpi("subscribers", formatCount(subscriptions.active), fillCounts(layout.subs.plans, { monthly: subscriptions.monthly, yearly: subscriptions.yearly }), false);
  setKpi(
    "conversion",
    percent(conversion.converted, conversion.trialStarted),
    fill(layout.subs.converted, {
      converted: formatCount(conversion.converted),
      started: formatCount(conversion.trialStarted),
      recent: percent(conversion.convertedLast30Days, conversion.startedLast30Days),
    }),
    false,
  );
  setKpi("churn", formatCount(stats.churn.canceledLast30Days), fillCounts(layout.subs.ending, { count: subscriptions.ending }), false);

  setFact("rev-subscriptions", "monthly", formatCount(subscriptions.monthly), false);
  setFact("rev-subscriptions", "yearly", formatCount(subscriptions.yearly), false);
  setFact("rev-subscriptions", "invite", formatCount(subscriptions.freeInviteMonth), false);
  setFact("rev-subscriptions", "grace", formatCount(subscriptions.grace), subscriptions.grace > 0);
  setFact("rev-subscriptions", "ending", formatCount(subscriptions.ending), false);
  setFact("rev-subscriptions", "canceled", formatCount(subscriptions.canceledTotal), false);
  setFact("rev-subscriptions", "free", formatCount(subscriptions.complimentary), false);
  const stripe: AdminStats["subscriptions"]["bySource"]["stripe"] = subscriptions.bySource.stripe;
  const appStore: AdminStats["subscriptions"]["bySource"]["appStore"] = subscriptions.bySource.appStore;
  setFact("rev-subscriptions", "stripe", fill(layout.facts.subscriptions.sourceValue, { active: formatCount(stripe.active), mrr: formatUsd(stripe.mrrUsd) }), false);
  setFact(
    "rev-subscriptions",
    "app-store",
    fill(layout.facts.subscriptions.appStoreValue, {
      active: formatCount(appStore.active),
      mrr: formatUsd(appStore.mrrUsd),
      gross: formatUsd(appStore.grossMrrUsd),
      fee: formatCount(Math.round(appStore.commissionRate * 100)),
    }),
    false,
  );
  setFact("rev-subscriptions", "app-store-sandbox", formatCount(appStore.sandbox), false);

  const billing: AdminStats["billing"] = stats.billing;
  setFact("rev-billing", "refunds", formatCount(billing.refundsLast30Days), false);
  // İtiraz her zaman uyarıdır (Stripe ücreti ve hesap riski); iade ve başarısız ödeme yalnızca bilgi.
  setFact("rev-billing", "disputes", formatCount(billing.disputesLast30Days), billing.disputesLast30Days > 0);
  setFact("rev-billing", "failed", formatCount(billing.paymentFailuresLast30Days), false);
  setFact("rev-billing", "duplicates", formatCount(stats.churn.duplicateSubscriptions), false);
  setFact("rev-billing", "past-due", formatCount(stats.churn.pastDue), stats.churn.pastDue > 0);
  setFact("rev-billing", "unpaid", formatCount(stats.churn.unpaid), stats.churn.unpaid > 0);
}

/** Büyüme görünümü: özet şeridi, grafikler, kayıt, deneme reddi ve davet dökümleri. */
function renderGrowth(stats: AdminStats): void {
  const newUsers: readonly DayCount[] = stats.users.newLast30Days;
  const refusals: AdminStats["trialRefusals"] = stats.trialRefusals;
  setKpi("downloads", formatCount(stats.downloads.total), fillCounts(layout.subs.inLast30, { count: lastDaysTotal(stats.downloads.last30Days, stats.downloads.last30Days.length) }), false);
  setKpi("users", formatCount(stats.users.total), fillCounts(layout.subs.newRecent, { month: lastDaysTotal(newUsers, newUsers.length), today: lastDaysTotal(newUsers, 1) }), false);
  setKpi("trials", formatCount(stats.trials.activeTrialUsers), fillCounts(layout.subs.usedUp, { count: stats.trials.exhaustedTrialUsers }), false);
  setKpi("refusals", formatCount(refusalTotal(refusals.last30Days)), fillCounts(layout.subs.today, { count: refusalTotal(refusals.today) }), false);
  renderDailyBars("downloads", countPoints(stats.downloads.last30Days), formatCount);
  renderDailyBars("users", countPoints(newUsers), formatCount);

  setFact("growth-signups", "today", formatCount(lastDaysTotal(newUsers, 1)), false);
  setFact("growth-signups", "week", formatCount(lastDaysTotal(newUsers, 7)), false);
  setFact("growth-signups", "month", formatCount(lastDaysTotal(newUsers, newUsers.length)), false);
  setFact("growth-signups", "apple", formatCount(stats.users.byProvider.apple), false);
  setFact("growth-signups", "google", formatCount(stats.users.byProvider.google), false);

  setFact("growth-refusals", "device", formatCount(refusals.last30Days.deviceUsed), false);
  setFact("growth-refusals", "ip", formatCount(refusals.last30Days.ipDailyLimit), false);
  setFact("growth-refusals", "exhausted", formatCount(refusals.last30Days.exhausted), false);
  setFact("growth-refusals", "expired", formatCount(refusals.last30Days.expired), false);
  setFact("growth-refusals", "today", formatCount(refusalTotal(refusals.today)), false);

  setFact("growth-referrals", "joined", formatCount(stats.referrals.joined), false);
  setFact("growth-referrals", "pending", formatCount(stats.referrals.pending), false);
  setFact("growth-referrals", "granted", formatCount(stats.referrals.granted), false);
  setFact("growth-referrals", "voided", formatCount(stats.referrals.voided), false);
}

/** Kullanım görünümü: bu ayın toplantıları ve grafiği. */
function renderEngagement(stats: AdminStats): void {
  const usage: AdminStats["usage"] = stats.usage;
  setKpi("meetings", formatCount(usage.meetingsThisMonth), fillCounts(layout.subs.meetingHours, { hours: stats.meetings.hoursThisMonth }), false);
  renderDailyBars("meetings", meetingPoints(stats.meetings.last30Days), formatCount);
  setFact("eng-month", "meetings", formatCount(usage.meetingsThisMonth), false);
  setFact("eng-month", "open", formatCount(usage.openMeetings), false);
  setFact("eng-month", "deferred", formatCount(usage.deferredThisMonth), false);
  setFact("eng-month", "reprocessed", formatCount(usage.reprocessedThisMonth), false);
  setFact("eng-month", "hours", fill(adminText.hours, { hours: formatCount(stats.meetings.hoursThisMonth) }), false);
  setFact("eng-month", "audio", fill(adminText.hours, { hours: formatCount(usage.audioHoursThisMonth) }), false);
  setFact("eng-month", "stream", formatCount(stats.deepgram.streamMinutes), false);
}

/** Maliyet görünümü: harcama ve kapasite ölçerleri, token dökümü. */
function renderCosts(stats: AdminStats): void {
  const spendWarn: boolean = nearLimit(stats.spend.todayUsd, stats.spend.ceilingUsd);
  setKpi("spend", formatUsd(stats.spend.todayUsd), fill(layout.subs.ofCeiling, { ceiling: formatUsd(stats.spend.ceilingUsd) }), spendWarn);
  setMeter("spend", stats.spend.todayUsd, stats.spend.ceilingUsd, spendWarn);
  const elevenWarn: boolean = stats.elevenLabs.percent >= capacityWarnRatio * 100;
  setKpi(
    "elevenlabs",
    `${Math.round(stats.elevenLabs.percent)}%`,
    fill(layout.subs.ofHours, { used: formatCount(stats.elevenLabs.usedHours), cap: formatCount(stats.elevenLabs.capHours) }),
    elevenWarn,
  );
  setMeter("elevenlabs", stats.elevenLabs.usedHours, stats.elevenLabs.capHours, elevenWarn);
  const deepgramWarn: boolean = stats.deepgram.percent >= capacityWarnRatio * 100;
  setKpi(
    "deepgram",
    `${Math.round(stats.deepgram.percent)}%`,
    fill(layout.subs.ofCredit, { used: formatUsd(stats.deepgram.estimatedUsd), budget: formatUsd(stats.deepgram.budgetUsd) }),
    deepgramWarn,
  );
  setMeter("deepgram", stats.deepgram.estimatedUsd, stats.deepgram.budgetUsd, deepgramWarn);
  const usage: AdminStats["usage"] = stats.usage;
  setKpi("tokens", formatCompact(stats.tokens.thisMonth), fillCounts(layout.subs.nearCap, { count: usage.usersNearTokenCap }), usage.usersNearTokenCap > 0);

  setFact("costs-tokens", "total", formatCompact(stats.tokens.thisMonth), false);
  setFact("costs-tokens", "account", formatCompact(usage.accountTokensThisMonth), false);
  setFact("costs-tokens", "cap", formatCompact(usage.monthlyTokenCapPerUser), false);
  setFact("costs-tokens", "account-cap", formatCompact(usage.monthlyAccountTokenCapPerUser), false);
  setFact("costs-tokens", "near", formatCount(usage.usersNearTokenCap), usage.usersNearTokenCap > 0);
}

/** Özet istatistiklerin tüm öğelerini ve bildirim sayaçlarını çizer. */
function renderStats(stats: AdminStats): void {
  element("admin-updated", HTMLElement).textContent = fill(adminText.updated, { time: formatTime(stats.generatedAt) });
  renderOverview(stats);
  renderRevenue(stats);
  renderGrowth(stats);
  renderEngagement(stats);
  renderCosts(stats);
  element("count-feedback", HTMLElement).textContent = formatCount(stats.reports.openFeedback);
  element("count-crash", HTMLElement).textContent = formatCount(stats.reports.openCrash);
  element("count-contact", HTMLElement).textContent = formatCount(stats.reports.openContact);
  const openReports: number = stats.reports.openFeedback + stats.reports.openCrash + stats.reports.openContact;
  element("count-inbox", HTMLElement).textContent = openReports === 0 ? "" : formatCount(openReports);
}

/** Önemin sırası (önce kırmızı). Saf fonksiyondur. */
function toneRank(tone: AttentionTone): number {
  return tone === "danger" ? 0 : tone === "warn" ? 1 : 2;
}

/** İstatistiklerden "dikkat" satırları. Saf fonksiyondur. */
function statsAttention(stats: AdminStats): AttentionItem[] {
  const words: AdminLayoutCopy["attention"] = layout.attention;
  const openReports: number = stats.reports.openFeedback + stats.reports.openCrash + stats.reports.openContact;
  const spendRatio: number = stats.spend.ceilingUsd > 0 ? stats.spend.todayUsd / stats.spend.ceilingUsd : 0;
  const items: (AttentionItem | null)[] = [
    stats.billing.disputesLast30Days > 0 ? { tone: "danger", label: words.disputes, value: formatCount(stats.billing.disputesLast30Days), view: "revenue" } : null,
    spendRatio >= capacityWarnRatio ? { tone: spendRatio >= 1 ? "danger" : "warn", label: words.spend, value: percent(stats.spend.todayUsd, stats.spend.ceilingUsd), view: "costs" } : null,
    stats.elevenLabs.percent >= capacityWarnRatio * 100 ? { tone: "warn", label: words.elevenLabs, value: `${Math.round(stats.elevenLabs.percent)}%`, view: "costs" } : null,
    stats.deepgram.percent >= capacityWarnRatio * 100 ? { tone: "warn", label: words.deepgram, value: `${Math.round(stats.deepgram.percent)}%`, view: "costs" } : null,
    stats.churn.pastDue > 0 ? { tone: "warn", label: words.pastDue, value: formatCount(stats.churn.pastDue), view: "revenue" } : null,
    stats.churn.unpaid > 0 ? { tone: "warn", label: words.unpaid, value: formatCount(stats.churn.unpaid), view: "revenue" } : null,
    stats.usage.usersNearTokenCap > 0 ? { tone: "info", label: words.nearCap, value: formatCount(stats.usage.usersNearTokenCap), view: "costs" } : null,
    openReports > 0 ? { tone: "info", label: words.inbox, value: formatCount(openReports), view: "inbox" } : null,
  ];
  return items.filter((item: AttentionItem | null): item is AttentionItem => item !== null);
}

/** İçgörülerden (son 7 gün) "dikkat" satırları. Saf fonksiyondur. */
function insightsAttention(insights: Insights): AttentionItem[] {
  const words: AdminLayoutCopy["attention"] = layout.attention;
  const week: Insights["problems"]["last7Days"] = insights.problems.last7Days;
  const providerErrors: number = week.providerErrors.reduce((sum: number, item): number => sum + item.count, 0);
  const items: (AttentionItem | null)[] = [
    week.serverErrorsTotal > 0 ? { tone: "danger", label: words.serverErrors, value: formatCount(week.serverErrorsTotal), view: "reliability" } : null,
    providerErrors > 0 ? { tone: "warn", label: words.providerErrors, value: formatCount(providerErrors), view: "reliability" } : null,
    week.trialCapacityReached > 0 ? { tone: "warn", label: words.trialCeiling, value: formatCount(week.trialCapacityReached), view: "growth" } : null,
    week.spendCeilingReached > 0 ? { tone: "warn", label: words.spendCeiling, value: formatCount(week.spendCeilingReached), view: "costs" } : null,
  ];
  return items.filter((item: AttentionItem | null): item is AttentionItem => item !== null);
}

/** İşletim verisinden "dikkat" satırları. Saf fonksiyondur. */
function operationsAttention(ops: Operations): AttentionItem[] {
  const words: AdminLayoutCopy["attention"] = layout.attention;
  const oldest: number | null = ops.reservations.oldestExpiredAt;
  const items: (AttentionItem | null)[] = [
    ops.deepgram.stale > 0 ? { tone: "warn", label: words.deepgramStale, value: formatCount(ops.deepgram.stale), view: "operations" } : null,
    oldest !== null && ops.generatedAt - oldest > dayMs ? { tone: "warn", label: words.reservations, value: formatCount(ops.reservations.expired), view: "operations" } : null,
    ops.meetings.unendedLast7Days > 0 ? { tone: "info", label: words.unended, value: formatCount(ops.meetings.unendedLast7Days), view: "operations" } : null,
  ];
  return items.filter((item: AttentionItem | null): item is AttentionItem => item !== null);
}

/** "Dikkat" listesini çizer: önce kırmızı, sonra sarı, sonra bilgi; satır tıklanınca ilgili görünüm açılır. */
function renderAttention(sources: AttentionSources, onOpen: (view: AdminView) => void): void {
  const items: AttentionItem[] = [
    ...statsAttention(sources.stats),
    ...(sources.insights === null ? [] : insightsAttention(sources.insights)),
    ...(sources.operations === null ? [] : operationsAttention(sources.operations)),
  ].sort((a: AttentionItem, b: AttentionItem): number => toneRank(a.tone) - toneRank(b.tone));
  const nodes: HTMLLIElement[] = items.map((item: AttentionItem): HTMLLIElement => {
    const row: HTMLLIElement = document.createElement("li");
    const button: HTMLButtonElement = document.createElement("button");
    button.type = "button";
    button.className = `attention__item attention__item--${item.tone}`;
    const dot: HTMLSpanElement = document.createElement("span");
    dot.className = "attention__dot";
    dot.setAttribute("aria-hidden", "true");
    const label: HTMLSpanElement = document.createElement("span");
    label.className = "attention__label";
    label.textContent = item.label;
    const value: HTMLSpanElement = document.createElement("span");
    value.className = "attention__value tabular";
    value.textContent = item.value;
    button.append(dot, label, value);
    button.addEventListener("click", (): void => onOpen(item.view));
    row.append(button);
    return row;
  });
  element("ov-attention", HTMLElement).replaceChildren(...nodes);
  element("ov-attention-empty", HTMLElement).classList.toggle("hidden", items.length > 0);
}

/** Bildirimin kim/ne zaman satırı. Saf fonksiyondur. */
function reportMeta(report: ReportSummary): string {
  const who: string = report.email ?? report.userId ?? adminText.anonymous;
  return [report.quoteFirstName === null ? null : adminText.report.quotable, who, report.appVersion, report.os, formatTime(report.createdAt)].filter((part: string | null): part is string => part !== null && part !== "").join(" · ");
}

/** Bildirim listesini çizer. */
function renderList(state: InboxState, onSelect: (id: string) => void): void {
  const list: HTMLElement = element("inbox-list", HTMLElement);
  const nodes: HTMLLIElement[] = state.items.map((report: ReportSummary): HTMLLIElement => {
    const item: HTMLLIElement = document.createElement("li");
    const button: HTMLButtonElement = document.createElement("button");
    button.type = "button";
    button.className = "inbox__item";
    if (report.id === state.selection.targetId) {
      button.setAttribute("aria-current", "true");
    }
    const summary: HTMLSpanElement = document.createElement("span");
    summary.className = "inbox__summary";
    summary.textContent = report.summary ?? adminText.noSummary;
    const meta: HTMLSpanElement = document.createElement("span");
    meta.className = "inbox__meta";
    meta.textContent = reportMeta(report);
    button.append(summary, meta);
    button.addEventListener("click", (): void => onSelect(report.id));
    item.append(button);
    return item;
  });
  list.replaceChildren(...nodes);
  element("inbox-empty", HTMLElement).classList.toggle("hidden", state.items.length > 0);
  element("inbox-more", HTMLButtonElement).classList.toggle("hidden", state.nextBefore === null);
}

/** Kopyalama düğmelerinin "kopyalandı" durumunu geri alan zamanlayıcılar (yeni kopyalama süreyi baştan başlatır). */
const copiedTimers: Map<HTMLButtonElement, number> = new Map();

/** Kopyalanınca düğme ~2 sn onay işareti ve "Copied" etiketi gösterir; ekran okuyucuya da duyurulur. */
function showCopied(button: HTMLButtonElement): void {
  const label: string = dataValue(button, "label");
  const copied: string = adminText.report.copied;
  button.dataset["copied"] = "";
  button.setAttribute("aria-label", copied);
  button.title = copied;
  element("detail-copy-status", HTMLElement).textContent = copied;
  window.clearTimeout(copiedTimers.get(button));
  copiedTimers.set(
    button,
    window.setTimeout((): void => {
      delete button.dataset["copied"];
      button.setAttribute("aria-label", label);
      button.title = label;
      element("detail-copy-status", HTMLElement).textContent = "";
      copiedTimers.delete(button);
    }, 2000),
  );
}

/** Düğmeye basılınca metni olduğu gibi (kesilmeden) panoya yazar; yazılamazsa panelin hata bildirimi gösterilir. */
function bindCopy(button: HTMLButtonElement, value: string): void {
  button.onclick = (): void => {
    navigator.clipboard
      .writeText(value)
      .then((): void => showCopied(button))
      .catch((error: unknown): void => {
        console.error("report_copy_failed", { button: button.id, error: error instanceof Error ? error.message : String(error) });
        showNotice(element("admin-error", HTMLElement), adminText.report.copyFailed);
      });
  };
}

/** Çökme raporu bölümü: MetricKit özeti (biçim tanınırsa), girintili JSON ve ham metni kopyalayan düğme. */
function renderPayload(payload: string | null): void {
  element("detail-payload-block", HTMLElement).classList.toggle("hidden", payload === null);
  const summary: HTMLElement = element("detail-payload-summary", HTMLElement);
  if (payload === null) {
    element("detail-payload", HTMLElement).textContent = "";
    summary.classList.add("hidden");
    return;
  }
  const parsed: ParsedPayload = parsePayload(payload);
  const line: string | null = diagnosticSummaryLine(metricKitDiagnostics(parsed.json), adminText.report);
  summary.textContent = line ?? "";
  summary.classList.toggle("hidden", line === null);
  const pre: HTMLElement = element("detail-payload", HTMLElement);
  pre.textContent = parsed.pretty;
  pre.scrollTo(0, 0);
  bindCopy(element("detail-payload-copy", HTMLButtonElement), payload);
}

/** Ayrıntı panelini çizer; "bitti/yeniden aç" düğmesi bu bildirimin kimliğini taşır (`data-report-id`). */
function renderDetail(report: ReportDetail): void {
  element("detail-empty", HTMLElement).classList.add("hidden");
  const body: HTMLElement = element("detail-body", HTMLElement);
  body.classList.remove("hidden");
  element("detail-received", HTMLElement).textContent = formatTime(report.createdAt);
  element("detail-email", HTMLElement).textContent = report.email ?? "—";
  element("detail-user", HTMLElement).textContent = report.userId ?? adminText.anonymous;
  const userCopy: HTMLButtonElement = element("detail-user-copy", HTMLButtonElement);
  userCopy.classList.toggle("hidden", report.userId === null);
  if (report.userId !== null) {
    bindCopy(userCopy, report.userId);
  }
  element("detail-app", HTMLElement).textContent = report.appVersion ?? "—";
  element("detail-os", HTMLElement).textContent = report.os ?? "—";
  element("detail-message", HTMLElement).textContent = report.message ?? adminText.noMessage;
  renderPayload(report.payload);
  renderQuote(report);
  const toggle: HTMLButtonElement = element("detail-toggle", HTMLButtonElement);
  toggle.dataset["reportId"] = report.id;
  toggle.dataset["next"] = report.status === "open" ? "done" : "open";
  toggle.textContent = report.status === "open" ? toggle.dataset["labelDone"] ?? "" : toggle.dataset["labelReopen"] ?? "";
  element("detail-status", HTMLElement).textContent = report.status === "open" ? element("status-open", HTMLButtonElement).textContent : element("status-done", HTMLButtonElement).textContent;
  element("detail-status", HTMLElement).classList.toggle("pill--ok", report.status === "done");
}

/**
 * Alıntı izni bölümü: gönderen izin verdiyse ön adıyla birlikte, `web/src/testimonials.ts` listesine yapıştırılacak
 * girdiyi kopyalayan düğme. Hesapsız (anonim) gönderilen iznin bir kişiye bağlanamadığı ayrıca yazılır ve kopyalama
 * düğmesi gösterilmez. Hiçbir şey kendiliğinden yayımlanmaz.
 */
function renderQuote(report: ReportDetail): void {
  const block: HTMLElement = element("detail-quote-block", HTMLElement);
  const name: string | null = report.quoteFirstName;
  const quote: string | null = report.quote;
  block.classList.toggle("hidden", name === null || quote === null);
  if (name === null || quote === null) {
    return;
  }
  const consent: HTMLElement = element("detail-quote-consent", HTMLElement);
  const anonymous: boolean = report.userId === null;
  consent.textContent = fill(dataValue(consent, anonymous ? "templateAnonymous" : "template"), { name });
  const copy: HTMLButtonElement = element("detail-quote-copy", HTMLButtonElement);
  copy.classList.toggle("hidden", anonymous);
  bindCopy(copy, testimonialSnippet(report.id, name, quote, report.createdAt));
}

/** Ayrıntı panelini boşaltır. */
function clearDetail(): void {
  element("detail-body", HTMLElement).classList.add("hidden");
  element("detail-empty", HTMLElement).classList.remove("hidden");
}

/** Oturum yok (yenileme de başarısız) ya da sunucu yönetici erişimini reddetti (403). Saf fonksiyondur. */
function isAccessDenied(error: unknown): boolean {
  return error instanceof SignedOutError || (error instanceof ApiRequestError && (error.status === 403 || error.status === 401));
}

/** Panelin yerine standart "sayfa bulunamadı" görünümünü koyar (panel varsa kaldırılır). */
function showNotFound(): void {
  const notFound: HTMLElement = element("admin-not-found", HTMLElement);
  element("admin", HTMLElement).remove();
  document.documentElement.classList.remove("admin-app");
  notFound.hidden = false;
  document.title = dataValue(notFound, "title");
}

/**
 * Erişim yoksa "sayfa bulunamadı"; başka hatada (ağ, sunucu) nötr bir bildirim. Bir görünümün kaynakları ayrı ayrı
 * yüklenir: ilk hata paneli kaldırıp "sayfa bulunamadı"yı gösterdiyse sonrakiler yalnızca konsola yazılır.
 */
function showFailure(error: unknown): void {
  if (document.getElementById("admin") === null) {
    console.error(error);
    return;
  }
  if (isAccessDenied(error)) {
    showNotFound();
    return;
  }
  element("admin-loading", HTMLElement).classList.add("hidden");
  showNotice(element("admin-error", HTMLElement), errorText(error, text));
}

/** Panel şablonunu sayfaya ekler ve sekme başlığını panelinkiyle değiştirir (erişim doğrulandıktan sonra). */
function mountDashboard(): void {
  const root: HTMLElement = element("admin", HTMLElement);
  const template: HTMLTemplateElement | null = document.querySelector<HTMLTemplateElement>("template#admin-template");
  if (template === null) {
    throw new MissingElementError("template#admin-template bulunamadı.");
  }
  element("admin-mount", HTMLElement).replaceChildren(template.content.cloneNode(true));
  element("admin-loading", HTMLElement).classList.add("hidden");
  // Sitenin üst çubuğu ve alt bilgisi gizlenir; panel tam ekran kabuk olur (admin.astro).
  document.documentElement.classList.add("admin-app");
  document.title = dataValue(root, "title");
}

/** Görünümü gösterir: menü düğmesinin basılı durumu, panelin görünürlüğü, üst çubuktaki başlık ve açıklama. */
function showView(view: AdminView): void {
  for (const other of adminViews) {
    element(`view-${other}`, HTMLButtonElement).setAttribute("aria-pressed", String(other === view));
    element(`panel-${other}`, HTMLElement).classList.toggle("hidden", other !== view);
  }
  const button: HTMLButtonElement = element(`view-${view}`, HTMLButtonElement);
  element("admin-view-title", HTMLElement).textContent = dataValue(button, "title");
  element("admin-view-description", HTMLElement).textContent = dataValue(button, "description");
  element("console-main", HTMLElement).scrollTop = 0;
}

/** Adres çubuğundaki `#revenue` gibi görünüm adı; yoksa genel bakış. Saf fonksiyondur. */
function viewFromHash(hash: string): AdminView {
  return adminViews.find((view: AdminView): boolean => `#${view}` === hash) ?? "overview";
}

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  await claimTabSession();
  if (!hasSession()) {
    showNotFound();
    return;
  }
  // Önce erişim doğrulanır; başarısızsa (403, oturum yok) panel hiç eklenmez.
  const firstStats: AdminStats = await fetchStats();
  mountDashboard();
  const notice: HTMLElement = element("admin-error", HTMLElement);
  const state: InboxState = { kind: "feedback", status: "open", items: [], nextBefore: null, selection: initialSelection, listRequest: 0, listInFlight: null, quotableOnly: false };
  const view: { current: AdminView } = { current: "overview" };
  const attention: AttentionSources = { stats: firstStats, insights: null, operations: null };

  // Responses can arrive in any order: only the response of the latest detail request for the shown report is drawn
  // (an older read of the same report, e.g. from before a status change, is not).
  const requestReport = (transition: SelectionTransition, reveal: boolean): void => {
    const request: { readonly targetId: string; readonly generation: number } | null = requestedDetail(transition);
    if (request === null) {
      return;
    }
    fetchReport(request.targetId)
      .then((report: ReportDetail): void => {
        const arrived: SelectionTransition = selectionTransition(state.selection, { kind: "detailArrived", ...request });
        state.selection = arrived.state;
        if (!shouldRender(arrived)) {
          return;
        }
        renderDetail(report);
        if (reveal) {
          // Dar ekranda ayrıntı listenin altında: görünür alana kaydırılır.
          element("inbox-detail", HTMLElement).scrollIntoView({ block: "nearest" });
        }
      })
      .catch(showFailure);
  };
  const applySelection = (event: SelectionEvent): void => {
    const transition: SelectionTransition = selectionTransition(state.selection, event);
    state.selection = transition.state;
    if (requestedDetail(transition) !== null && event.kind !== "reload") {
      renderList(state, select);
    }
    requestReport(transition, event.kind !== "reload");
  };
  function select(id: string): void {
    applySelection({ kind: "select", targetId: id });
  }

  const loadList = async (append: boolean): Promise<void> => {
    const kind: ListRequestKind = append ? "append" : "replace";
    if (!admitsListRequest(state.listInFlight, kind)) {
      return;
    }
    state.listRequest += 1;
    const request: number = state.listRequest;
    state.listInFlight = kind;
    let page: ReportPage;
    try {
      page = await fetchReports(state.kind, state.status, append ? state.nextBefore : null, state.quotableOnly);
    } finally {
      if (request === state.listRequest) {
        state.listInFlight = null;
      }
    }
    if (request !== state.listRequest) {
      return;
    }
    state.items = append ? [...state.items, ...page.items] : [...page.items];
    state.nextBefore = page.nextBefore;
    renderList(state, select);
  };

  const kinds: readonly ReportKind[] = ["feedback", "crash", "contact"];
  const statuses: readonly ReportStatus[] = ["open", "done"];
  const setInboxFilter = (kind: ReportKind, status: ReportStatus): void => {
    state.kind = kind;
    state.status = status;
    state.selection = selectionTransition(state.selection, { kind: "clear" }).state;
    for (const other of kinds) {
      element(`tab-${other}`, HTMLButtonElement).setAttribute("aria-pressed", String(other === kind));
    }
    for (const other of statuses) {
      element(`status-${other}`, HTMLButtonElement).setAttribute("aria-pressed", String(other === status));
    }
    clearDetail();
  };

  // Kaynaklar görünümlerden önce kurulur; görünüm değişince yalnızca kaynakları yüklenir.
  const sources: { value: Readonly<Record<DataSource, Loadable>> | null } = { value: null };
  const switchView = (next: AdminView): void => {
    view.current = next;
    showView(next);
    history.replaceState(null, "", next === "overview" ? location.pathname : `#${next}`);
    const loaded: Readonly<Record<DataSource, Loadable>> | null = sources.value;
    if (loaded === null) {
      return;
    }
    for (const source of viewSources[next]) {
      loaded[source].ensureLoaded().catch(showFailure);
    }
  };
  const redrawAttention = (): void => renderAttention(attention, switchView);

  // Kullanıcı ayrıntısındaki ya da işletimdeki rapor bildirim kutusunda, kendi türü ve durumuyla açılır. It opens once its
  // list has loaded, and only if the admin has not changed the filter or picked a report meanwhile.
  const openReport = (id: string, kind: ReportKind, status: ReportStatus): void => {
    setInboxFilter(kind, status);
    switchView("inbox");
    const expectedGeneration: number = state.selection.generation;
    loadList(false)
      .then((): void => applySelection({ kind: "deferredSelect", targetId: id, expectedGeneration }))
      .catch(showFailure);
  };
  const users: UsersView = createUsersView(showFailure, openReport);
  const openUser = (id: string): void => {
    switchView("users");
    users.openUser(id).catch(showFailure);
  };
  const operations: OperationsView = createOperationsView(openUser, openReport, (ops: Operations): void => {
    attention.operations = ops;
    redrawAttention();
  });
  const insights: InsightsView = createInsightsView(openUser, (loaded: Insights): void => {
    attention.insights = loaded;
    redrawAttention();
  });
  const product: ProductView = createProductView();
  const trends: TrendsView = createTrendsView(renderOverviewTrends);
  const telemetry: TelemetryView = createTelemetryView();
  const blog: BlogView = createBlogView(showFailure);
  sources.value = { insights, product, trends, telemetry, operations, users, blog };

  const refresh = async (): Promise<void> => {
    hideNotice(notice);
    const current: AdminView = view.current;
    const loaded: Readonly<Record<DataSource, Loadable>> | null = sources.value;
    const [stats] = await Promise.all([
      fetchStats(),
      current === "inbox" ? loadList(false) : Promise.resolve(),
      ...(loaded === null ? [] : viewSources[current].map((source: DataSource): Promise<void> => loaded[source].refresh())),
    ]);
    attention.stats = stats;
    renderStats(stats);
    redrawAttention();
  };

  for (const kind of kinds) {
    element(`tab-${kind}`, HTMLButtonElement).addEventListener("click", (): void => {
      setInboxFilter(kind, state.status);
      loadList(false).catch(showFailure);
    });
  }
  for (const status of statuses) {
    element(`status-${status}`, HTMLButtonElement).addEventListener("click", (): void => {
      setInboxFilter(state.kind, status);
      loadList(false).catch(showFailure);
    });
  }
  // Alıntı izni yalnızca geri bildirimde olur: süzgeç açılınca Geri bildirim sekmesine geçilir.
  const quotable: HTMLButtonElement = element("filter-quotable", HTMLButtonElement);
  quotable.addEventListener("click", (): void => {
    state.quotableOnly = !state.quotableOnly;
    quotable.setAttribute("aria-pressed", String(state.quotableOnly));
    setInboxFilter(state.quotableOnly ? "feedback" : state.kind, state.status);
    loadList(false).catch(showFailure);
  });
  element("inbox-more", HTMLButtonElement).addEventListener("click", (): void => {
    loadList(true).catch(showFailure);
  });
  const toggle: HTMLButtonElement = element("detail-toggle", HTMLButtonElement);
  toggle.addEventListener("click", (): void => {
    // Hedef, ayrıntıda çizilen bildirimdir (`data-report-id`); durum ondan okunduğu için kimlik de ondan alınır.
    const id: string | undefined = toggle.dataset["reportId"];
    const next: string | undefined = toggle.dataset["next"];
    if (id === undefined || id !== state.selection.targetId || (next !== "open" && next !== "done")) {
      return;
    }
    toggle.disabled = true;
    setReportStatus(id, next)
      .then(async (): Promise<void> => {
        // A new detail request for the report: any read started before the change is no longer drawn.
        applySelection({ kind: "reload", targetId: id });
        await refresh();
      })
      .catch(showFailure)
      .finally((): void => {
        toggle.disabled = false;
      });
  });
  for (const each of adminViews) {
    element(`view-${each}`, HTMLButtonElement).addEventListener("click", (): void => switchView(each));
  }
  const refreshButton: HTMLButtonElement = element("admin-refresh", HTMLButtonElement);
  refreshButton.addEventListener("click", (): void => {
    refreshButton.disabled = true;
    refreshButton.classList.add("is-spinning");
    refresh()
      .catch(showFailure)
      .finally((): void => {
        refreshButton.disabled = false;
        refreshButton.classList.remove("is-spinning");
      });
  });

  renderStats(firstStats);
  redrawAttention();
  await loadList(false);
  switchView(viewFromHash(location.hash));
}

main().catch(showFailure);
