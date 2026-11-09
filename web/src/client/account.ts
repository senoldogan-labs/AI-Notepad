// Hesap sayfası: `/v1/me`'den tek plan kartı (plan adı ve durum etiketi; cümle gerektiren durumda tek ileti satırı,
// tarihler için etiket/değer satırları; denemede kalan toplantı ya da abonede aylık saat ölçeri; ödeme alınamadıysa
// eylemin yanında uyarı ve duruma uyan eylem: Abone ol, Aboneliği yönet ya da ücretsiz erişimde hiçbiri). Hesap
// yüklenemezse hata ve yeniden deneme düğmesi görünür. Abone olurken plan seçimi (yıllık seçili) ve davet kodu
// (`POST /v1/referral/validate`) Checkout'a taşınır; abonenin davet kartı `GET /v1/referral`'dan; çıkış ve onaylı hesap
// silme (`DELETE /v1/me`). Adresteki `?plan=`, `?tier=`, `?code=` ve `?checkout=1` (fiyat ve davet sayfalarından) girişten
// önce saklanır; oturum yoksa giriş sayfasına geçilir. Plan ve katman seçimi tarayıcıda kalıcıdır (giriş başka bir
// sekmede bitse de kaybolmaz); `?checkout=1` niyeti giriş bitince hesap sayfasını doğrudan Stripe Checkout'a gönderir.
// Katman (Personal ya da Pro): sunucu Pro'yu sunuyorsa (`offeredTiers`) plan seçiminin üstünde katman seçimi görünür ve
// Checkout'a `tier` gider; Stripe abonesi katmanını `POST /v1/billing/change-plan`'ın Stripe sayfasında değiştirir,
// App Store abonesine iPhone'da değiştirmesi söylenir. Plan adı katmanı, saat ölçeri sunucunun sınırını yazar.
// Abone ol düğmesi seçili katmanın planının tutarını, altındaki satır yenileme koşullarını taşır (src/lib/subscribe-copy.ts);
// süren denemede başlık sunucunun deneme sayısıyla, hiç abone olmamış hesapta deneme bitince sakin bir "kaldığın yerden
// devam et" kartı görünür. `?payment=done` dönüşünde abonelik görününce onay kartı (plan ve tek sonraki adım), birkaç
// denemede görünmezse "Refresh my plan" düğmeli bekleme satırı. Stripe aboneliğinin ilk 14 gününde cayma işlevi (AB CRD
// Art. 11a): "Withdraw from contract" → onay adımı → `POST /v1/billing/withdraw`; sonuç (tarih ve saat, iade tutarı)
// ekranda kalır. Withdrawal and its refund retry share the single billing-action lock (src/lib/checkout-state.ts).
import {
  ApiRequestError,
  type Entitlements,
  type JsonObject,
  type RawResponse,
  type ReferralInfo,
  parseEntitlements,
  parseRedirectUrl,
  type WithdrawalResult,
  parseReferral,
  parseValidatedReferralCode,
  parseWithdrawal,
} from "./api";
import {
  checkoutIntended,
  forgetCheckoutIntent,
  forgetInviteCode,
  forgetPlan,
  forgetTier,
  storeCheckoutIntent,
  storeInviteCode,
  storePlan,
  storeTier,
  storedInviteCode,
  storedPlan,
  storedTier,
} from "./checkout-choice";
import { type ClientCopy, clientCopy, fill } from "./copy";
import { type CheckoutEvent, type CheckoutState, checkoutControlsLocked, checkoutTransition, idleCheckout } from "../lib/checkout-state";
import { dataValue, element, errorText, hideNotice, showNotice } from "./dom";
import { SignedOutError, authorizedSend, claimTabSession, clearSession, hasSession, signOut } from "./session";
import { siteLocale } from "../config";
import {
  type BillingPlan,
  type SubscriptionTier,
  type TierOffer,
  billingPlanOf,
  formatHourCount,
  formatUsdCents,
  normalizedInviteCode,
  planPriceCents,
  recommendedPlan,
  subscriptionTierOf,
  tierOffer,
  tierPrices,
} from "../lib/plans";
import { type PlanState, type TrialState, hasSubscriptionAccess, planState } from "../lib/plan-status";
import {
  type CheckoutTerms,
  checkoutTerms,
  formatRefund,
  subscribeLabel,
  switchTierLabel,
  switchTierNote,
  trialHeadline,
  trialMeetingsUsed,
  winBackText,
  withdrawalDeadline,
} from "../lib/subscribe-copy";

/** Ödeme dönüşünde aboneliğin görünmesi için en çok kaç kez, kaç ms arayla yeniden bakılır (webhook gecikmesi). */
const paymentPollAttempts: number = 6;
const paymentPollIntervalMs: number = 2000;
/** Hesap silinince ana sayfaya geçmeden önce bekleme. */
const deletedRedirectMs: number = 3000;

/** Etiket görünümü. */
type PillTone = "ok" | "warn" | "plain";

/** Başlıktaki plan durumu etiketi. */
interface Pill {
  readonly text: string;
  readonly tone: PillTone;
}

/** Plan kartının bir etiket/değer satırı (ör. "Renews" · "30 November 2026"). */
interface Fact {
  readonly label: string;
  readonly value: string;
}

/** Plan kartının durumu: cümle gerektiren durumda ileti (yoksa null) ve etiket/değer satırları (boş olabilir). */
interface PlanStatus {
  readonly message: string | null;
  readonly facts: readonly Fact[];
}

/** Sürmekte olan denemenin göstergesi: değer metni ("2 of 3"), kalan ve toplam toplantı, son toplantıda uyarı. */
interface TrialMeter {
  readonly text: string;
  readonly left: number;
  readonly total: number;
  readonly warn: boolean;
}

/**
 * Abonenin aylık saat göstergesi: değer metni ("3.4 / 10.0 hours"), kullanılan (sınırda kesilir), sınır, sınırın
 * %80'inde uyarı, sınır dolduysa dolu (hata rengi; uygulamadaki ölçerle aynı), ikincil değer (kalan saat) ve sınır
 * dolduysa sıfırlanma günlü uyarı satırı (dolmadıysa null).
 */
interface HoursMeter {
  readonly text: string;
  readonly used: number;
  readonly cap: number;
  readonly warn: boolean;
  readonly full: boolean;
  readonly left: string;
  readonly limitReached: string | null;
}

/**
 * Abonenin toplantı dışı yapay zekâ göstergesi (uygulamalardaki ikinci ölçer): yüzde metni, kullanılan (sınırda
 * kesilir), sınır, %80'de uyarı, dolunca dolu (hata rengi), sıfırlanma satırı ve hak dolduysa uyarı satırı (yoksa null).
 */
interface AiMeter {
  readonly text: string;
  readonly used: number;
  readonly cap: number;
  readonly warn: boolean;
  readonly full: boolean;
  readonly resets: string;
  readonly limitReached: string | null;
}

/** Plan seçimindeki bir katman: ad ve sunucunun aylık saat sınırı metni. */
interface TierChoice {
  readonly tier: SubscriptionTier;
  readonly name: string;
  readonly hours: string;
}

/** Stripe abonesinin katman değiştirmesi: hedef katman, korunan plan (aylık/yıllık), düğme metni ve ücret notu. */
interface TierSwitch {
  readonly tier: SubscriptionTier;
  readonly plan: BillingPlan;
  readonly label: string;
  readonly note: string;
}

/** Hesap sayfasında gösterilecek değerler. */
interface AccountView {
  readonly plan: string;
  readonly planPill: Pill;
  /** Plan kartının ileti satırı ve etiket/değer satırları: abonelik durumu ya da deneme. */
  readonly status: PlanStatus;
  /** Hiç abone olmamış hesapta deneme bittiyse "kaldığın yerden devam et" metni; yoksa null. */
  readonly winBack: string | null;
  /** Deneme sürüyorsa kalan toplantı göstergesi; yoksa null. */
  readonly trialMeter: TrialMeter | null;
  /** Aylık saat yalnızca abonelik erişiminde görünür (sınır aboneliğindir; denemede kafa karıştırır); yoksa null. */
  readonly hours: HoursMeter | null;
  /** Toplantı dışı yapay zekâ ölçeri, saat ölçeriyle aynı koşulda (abonelik erişimi) görünür; yoksa null. */
  readonly ai: AiMeter | null;
  /** Ödeme alınamadıysa (ek süre ya da süresi geçmiş ödeme) Aboneliği yönet düğmesinin yanındaki uyarı; yoksa null. */
  readonly alert: string | null;
  readonly canSubscribe: boolean;
  readonly canManage: boolean;
  /** Abone olurken katman seçimi: sunucu Pro'yu sunuyorsa sunulan katmanlar; yoksa (ya da abone olunamıyorsa) null. */
  readonly tierChoices: readonly TierChoice[] | null;
  /** Stripe abonesinin katman değiştirme düğmesi; değiştirilemiyorsa null. */
  readonly tierSwitch: TierSwitch | null;
  /** Hesap silme penceresindeki App Store uyarısı (yenilenecek App Store aboneliği varsa); yoksa null. */
  readonly deleteWarning: string | null;
  /** Cayma kartının metni (son günüyle ya da bekleyen iadenin metni); cayılamıyorsa null (kart gizli). */
  readonly withdrawal: string | null;
  /** Abone caydı ama iadesi doğrulanmadı: kart yeniden denemeyi gösterir. */
  readonly withdrawalPending: boolean;
}

/** Saat ölçeri kullanımın bu oranından sonra uyarır. */
const hoursWarnRatio: number = 0.8;
/** Deneme ölçeri bu kadar toplantı kalınca uyarır. */
const trialWarnMeetingsLeft: number = 1;

/** Tarihi sitenin yerel ayarında, tarayıcının saat diliminde yazar. Saf fonksiyondur. */
function formatDate(iso: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: "long" }).format(new Date(iso));
}

/** Tarihi sitenin yerel ayarında, UTC'de yazar (aylık sınır UTC ayının başında sıfırlanır). Saf fonksiyondur. */
function formatUtcDate(iso: string, locale: string): string {
  return new Intl.DateTimeFormat(locale, { dateStyle: "long", timeZone: "UTC" }).format(new Date(iso));
}

/** Oranı sitenin yerel ayarında ondalıksız yüzde olarak yazar (uygulamalarla aynı). Saf fonksiyondur. */
function formatPercent(fraction: number, locale: string): string {
  return new Intl.NumberFormat(locale, { style: "percent", maximumFractionDigits: 0 }).format(fraction);
}

/** Saati sitenin yerel ayarında hep bir ondalıkla yazar (değer değişince genişlik oynamaz). Saf fonksiyondur. */
function formatHours(hours: number, locale: string): string {
  return new Intl.NumberFormat(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(hours);
}

/**
 * Planın adı: abonelik erişiminde katmanla aylık, yıllık ya da (fiyat tanınmıyorsa) yalnızca katman; ücretsiz erişim;
 * abonelik bitmiş ve denemesi kalmamış hesapta "plan yok"; denemede deneme. Saf fonksiyondur.
 */
function planName(state: PlanState, text: ClientCopy): string {
  switch (state.kind) {
    case "trial":
      return text.plan.trial;
    case "complimentary":
      return text.plan.complimentary;
    case "subscribed":
    case "ending":
    case "grace": {
      const tier: string = text.tiers[state.subscription.tier];
      return fill(state.subscription.plan === null ? text.plan.subscription : text.plan[state.subscription.plan], { tier });
    }
    case "paymentOverdue":
      return state.trial.kind === "ended" ? text.plan.none : text.plan.trial;
    case "complimentaryEnded":
    case "expired":
      return text.plan.none;
  }
}

/**
 * Denemenin durumu: başlamadıysa kapsamı (kalan toplantı; devralınan deneme toplantıları yüzünden toplamdan az
 * olabilir) ve başlangıcı, sürüyorsa bitiş tarihi (kalan toplantı ölçerdedir) satır olarak; bittiyse ileti. Saf
 * fonksiyondur.
 */
function trialStatus(trial: TrialState, trialDays: number, used: number, text: ClientCopy, locale: string): PlanStatus {
  switch (trial.kind) {
    case "notStarted":
      return {
        message: trialHeadline(used, text.trialHeadline),
        facts: [
          { label: text.facts.trialIncludes, value: fill(text.facts.trialIncludesValue, { total: String(trial.left), days: String(trialDays) }) },
          { label: text.facts.trialStarts, value: text.facts.trialStartsValue },
        ],
      };
    case "running":
      return { message: trialHeadline(used, text.trialHeadline), facts: [{ label: text.facts.trialEnds, value: formatDate(trial.endsAt, locale) }] };
    case "ended":
      // Toplantı kaydedildiyse "kaldığın yerden devam et" kartı anlatır (`winBackText`); ileti satırı boş kalır.
      return { message: used > 0 ? null : text.trialEnded, facts: [] };
  }
}

/**
 * Aboneliğin durumu. Ücretsiz erişimde ödeme ve yenileme yoktur: ileti yazılır (bitiş tarihi varsa onunla), bittiyse
 * "ücretsiz erişim bitti" (abonelik bitti değil: hiç ödeme yapılmadı). Etkin, iptal edilmiş ve ek süredeki abonelik
 * tarihleri satır olarak gösterir; ödeme alınamadıysa neden eylemin yanındaki uyarıdadır (`paymentAlert`). App Store
 * aboneliği erişim sürerken nerede yönetileceğini söyleyen iletiyi de taşır; Pro sunuluyorsa ya da abonelik Pro ise
 * katmanın da iPhone'da değiştirileceğini söyler. Saf fonksiyondur.
 */
function planStatus(state: PlanState, trialDays: number, used: number, proOffered: boolean, text: ClientCopy, locale: string): PlanStatus {
  const facts: PlanStatus = subscriptionFacts(state, trialDays, used, text, locale);
  if (!hasSubscriptionAccess(state) || state.kind === "trial" || state.subscription.source !== "app_store") {
    return facts;
  }
  const tiersMatter: boolean = proOffered || state.subscription.tier === "pro";
  return { message: tiersMatter ? text.subscriptionAppStoreTiers : text.subscriptionAppStore, facts: facts.facts };
}

/**
 * Abone olurken katman seçimi: sunucu Pro'yu sunuyorsa sunulan her katman, adı ve aylık saat sınırıyla; Pro
 * sunulmuyorsa (eski sunucu da) ya da abone olunamıyorsa null (yalnızca Personal satılır, seçim gösterilmez). Saf
 * fonksiyondur.
 */
function tierChoices(offers: readonly TierOffer[], canSubscribe: boolean, text: ClientCopy, locale: string): readonly TierChoice[] | null {
  if (!canSubscribe || tierOffer(offers, "pro") === null) {
    return null;
  }
  return offers.map(
    (offer: TierOffer): TierChoice => ({
      tier: offer.tier,
      name: text.tiers[offer.tier],
      hours: fill(text.tierHours, { hours: formatHourCount(offer.monthlyHours, locale) }),
    }),
  );
}

/**
 * Stripe abonesinin katman değiştirmesi: yalnızca yenilenecek (iptal edilmemiş, ek sürede olmayan), ücretsiz erişim
 * olmayan ve planı bilinen Stripe aboneliğinde. Personal abone Pro sunuluyorsa Pro'ya, Pro abone Personal'a geçebilir;
 * aylık/yıllık plan korunur (onay ve ücret farkı Stripe'ın sayfasında). Saf fonksiyondur.
 */
function tierSwitch(state: PlanState, offers: readonly TierOffer[], text: ClientCopy): TierSwitch | null {
  if (state.kind !== "subscribed" || state.subscription.source !== "stripe" || state.subscription.complimentary || state.subscription.plan === null) {
    return null;
  }
  const plan: BillingPlan = state.subscription.plan;
  const target: SubscriptionTier = state.subscription.tier === "pro" ? "personal" : "pro";
  if (target === "pro" && tierOffer(offers, "pro") === null) {
    return null;
  }
  return { tier: target, plan, label: switchTierLabel(target, plan, text), note: switchTierNote(target, plan, text) };
}

/** Plan durumunun ileti ve satırları (tanımlar `planStatus`'ta; App Store iletisi olmadan). Saf fonksiyondur. */
function subscriptionFacts(state: PlanState, trialDays: number, used: number, text: ClientCopy, locale: string): PlanStatus {
  switch (state.kind) {
    case "trial":
      return trialStatus(state.trial, trialDays, used, text, locale);
    case "complimentary":
      return { message: state.until === null ? text.subscriptionComplimentary : fill(text.subscriptionComplimentaryUntil, { date: formatDate(state.until, locale) }), facts: [] };
    case "complimentaryEnded":
      return { message: text.subscriptionComplimentaryEnded, facts: [] };
    case "ending":
      return {
        message: null,
        facts: [
          { label: text.facts.renewal, value: text.facts.renewalCancelled },
          { label: text.facts.accessUntil, value: formatDate(state.endsAt, locale) },
        ],
      };
    case "subscribed":
      return { message: null, facts: [{ label: text.facts.renews, value: formatDate(state.renewsAt, locale) }] };
    case "grace":
      return { message: null, facts: [{ label: text.facts.accessUntil, value: formatDate(state.endsAt, locale) }] };
    case "paymentOverdue":
      return state.trial.kind === "ended" ? { message: null, facts: [] } : trialStatus(state.trial, trialDays, used, text, locale);
    case "expired":
      return { message: text.subscriptionEnded, facts: [] };
  }
}

/**
 * Ödeme alınamadıysa Aboneliği yönet düğmesinin yanındaki uyarı: ek sürede ya da süresi geçmiş ödemede. App Store
 * aboneliğinde kart Apple'dadır; durum iletisi nerede yönetileceğini söyler. Saf fonksiyondur.
 */
function paymentAlert(state: PlanState, text: ClientCopy): string | null {
  if (state.kind === "grace" && state.subscription.source !== "app_store") {
    return text.subscriptionGraceAlert;
  }
  if (state.kind === "paymentOverdue" && state.subscription.source !== "app_store") {
    return text.subscriptionPaymentOverdue;
  }
  return null;
}

/**
 * Plan adının yanındaki durum etiketi: ücretsiz erişim (bitiş tarihi olsa da "bitiyor" uyarısı değil), ek süre ya da
 * süresi geçmiş ödeme, iptal edilmiş, etkin; abonelik erişimi yoksa bitmiş ya da deneme. Saf fonksiyondur.
 */
function planPill(state: PlanState, text: ClientCopy): Pill {
  switch (state.kind) {
    case "complimentary":
      return { text: text.pillComplimentary, tone: "ok" };
    case "grace":
    case "paymentOverdue":
      return { text: text.pillGrace, tone: "warn" };
    case "ending":
      return { text: text.pillCanceling, tone: "warn" };
    case "subscribed":
      return { text: text.pillActive, tone: "ok" };
    case "complimentaryEnded":
    case "expired":
      return { text: text.pillEnded, tone: "plain" };
    case "trial":
      return state.trial.kind === "ended" ? { text: text.pillEnded, tone: "plain" } : { text: text.pillTrial, tone: "plain" };
  }
}

/**
 * Sürmekte olan denemenin ölçeri (ödemesi alınamamış abonelikte de deneme sürüyorsa): son toplantıda uyarır; deneme
 * sürmüyorsa null. Saf fonksiyondur.
 */
function trialMeter(state: PlanState, text: ClientCopy): TrialMeter | null {
  const trial: TrialState | null = state.kind === "trial" || state.kind === "paymentOverdue" ? state.trial : null;
  if (trial === null || trial.kind !== "running") {
    return null;
  }
  const { left, total }: { readonly left: number; readonly total: number } = trial;
  return {
    text: fill(text.trialMeetings, { left: String(left), total: String(total) }),
    left,
    total,
    warn: left <= trialWarnMeetingsLeft,
  };
}

/** Abonenin aylık saat ölçeri: sınırın %80'inde uyarır, sınır dolunca hata renginde ve sıfırlanma günü (UTC) yazılır. Saf fonksiyondur. */
function hoursMeter(me: Entitlements, text: ClientCopy, locale: string): HoursMeter {
  const cap: number = me.monthlyHoursCap;
  const used: number = me.monthlyHoursUsed;
  return {
    text: fill(text.hours, { used: formatHours(used, locale), cap: formatHours(cap, locale) }),
    used: Math.min(used, cap),
    cap,
    warn: used >= cap * hoursWarnRatio,
    full: used >= cap,
    left: fill(text.hoursLeft, { left: formatHours(Math.max(cap - used, 0), locale) }),
    limitReached: used >= cap ? fill(text.hoursLimitReached, { date: formatUtcDate(me.monthlyResetsAt, locale) }) : null,
  };
}

/** Abonenin toplantı dışı yapay zekâ ölçeri: saat ölçeriyle aynı eşikler, değer yüzde. Saf fonksiyondur. */
function aiMeter(me: Entitlements, text: ClientCopy, locale: string): AiMeter {
  const cap: number = me.accountTokensCap;
  const used: number = me.accountTokensUsed;
  const fraction: number = cap > 0 ? Math.min(used / cap, 1) : 1;
  const resetDate: string = formatUtcDate(me.accountTokensResetsAt, locale);
  return {
    text: formatPercent(fraction, locale),
    used: Math.min(used, cap),
    cap,
    warn: fraction >= hoursWarnRatio,
    full: fraction >= 1,
    resets: fill(text.aiResets, { date: resetDate }),
    limitReached: fraction >= 1 ? fill(text.aiLimitReached, { date: resetDate }) : null,
  };
}

/**
 * Sunucu yanıtından gösterilecek değerleri üretir. Aboneliği yönetme yalnızca Stripe'ta karşılığı olan (ücretsiz erişim
 * ve App Store aboneliği olmayan) abonelikte vardır: ücretsiz erişim bitmiş olsa da Portal'da yönetilecek bir şey yoktur;
 * App Store aboneliği iPhone'da yönetilir. Yenilenecek App Store aboneliğinde silme penceresi Apple'da iptal etmeyi
 * söyler (hesap silme onu iptal etmez). Saf fonksiyondur.
 */
export function accountView(me: Entitlements, text: ClientCopy, locale: string, now: Date): AccountView {
  const state: PlanState = planState(me, now);
  const subscribed: boolean = hasSubscriptionAccess(state);
  const proOffered: boolean = tierOffer(me.offeredTiers, "pro") !== null;
  const used: number = trialMeetingsUsed(me);
  const withdrawalPending: boolean = me.subscription !== null && me.subscription.source === "stripe" && me.subscription.withdrawalPending;
  return {
    plan: planName(state, text),
    planPill: planPill(state, text),
    status: planStatus(state, me.trialDays, used, proOffered, text, locale),
    winBack: winBackText(state, used, text.winBack),
    trialMeter: trialMeter(state, text),
    hours: subscribed ? hoursMeter(me, text, locale) : null,
    ai: subscribed ? aiMeter(me, text, locale) : null,
    alert: paymentAlert(state, text),
    canSubscribe: !subscribed,
    canManage: me.subscription !== null && !me.subscription.complimentary && me.subscription.source === "stripe",
    tierChoices: tierChoices(me.offeredTiers, !subscribed, text, locale),
    tierSwitch: tierSwitch(state, me.offeredTiers, text),
    withdrawal: withdrawalPending
      ? text.withdrawal.pendingText
      : ((until: string | null): string | null => (until === null ? null : fill(text.withdrawal.text, { date: formatDate(until, locale) })))(withdrawalDeadline(state, now)),
    withdrawalPending,
    deleteWarning:
      me.subscription !== null && me.subscription.source === "app_store" && me.subscription.access !== "none" && me.subscription.cancelAt === null
        ? text.deleteAppStoreWarning
        : null,
  };
}

/** Etiketi günceller. */
function renderPill(pill: HTMLElement, value: Pill): void {
  pill.classList.remove("hidden");
  pill.classList.toggle("pill--ok", value.tone === "ok");
  pill.classList.toggle("pill--warn", value.tone === "warn");
  pill.textContent = value.text;
}

/** Plan kartının ileti satırını ve etiket/değer satırlarını yazar; boş olan gizlenir. */
function renderStatus(status: PlanStatus): void {
  const message: HTMLElement = element("plan-status", HTMLElement);
  message.classList.toggle("hidden", status.message === null);
  message.textContent = status.message ?? "";
  const facts: HTMLElement = element("plan-facts", HTMLElement);
  facts.classList.toggle("hidden", status.facts.length === 0);
  facts.replaceChildren(
    ...status.facts.flatMap((fact: Fact): HTMLElement[] => {
      const label: HTMLElement = document.createElement("dt");
      label.textContent = fact.label;
      const value: HTMLElement = document.createElement("dd");
      value.textContent = fact.value;
      return [label, value];
    }),
  );
}

/** Abonenin toplantı dışı yapay zekâ bloğunu yazar; yoksa gizler. Sınıra yaklaşan ölçer sarı, dolu ölçer kırmızıdır. */
function renderAiMeter(ai: AiMeter | null): void {
  element("ai-card", HTMLElement).classList.toggle("hidden", ai === null);
  if (ai === null) {
    return;
  }
  element("ai-value", HTMLElement).textContent = ai.text;
  const meter: HTMLProgressElement = element("ai-meter", HTMLProgressElement);
  meter.max = ai.cap;
  meter.value = ai.used;
  meter.textContent = ai.text;
  meter.classList.toggle("meter--warn", ai.warn && !ai.full);
  meter.classList.toggle("meter--full", ai.full);
  element("ai-resets", HTMLElement).textContent = ai.resets;
  element("ai-foot", HTMLElement).classList.toggle("hidden", ai.limitReached !== null);
  const limit: HTMLElement = element("ai-limit", HTMLElement);
  limit.classList.toggle("hidden", ai.limitReached === null);
  limit.textContent = ai.limitReached ?? "";
}

/** Ölçerleri yazar: deneme ölçeri ve abonenin saat bloğu, olmayan gizlenir; sınıra yaklaşan ölçer sarıdır. */
function renderMeters(trial: TrialMeter | null, hours: HoursMeter | null): void {
  element("trial-card", HTMLElement).classList.toggle("hidden", trial === null);
  if (trial !== null) {
    element("trial-value", HTMLElement).textContent = trial.text;
    const trialMeter: HTMLProgressElement = element("trial-meter", HTMLProgressElement);
    trialMeter.max = trial.total;
    trialMeter.value = trial.left;
    trialMeter.textContent = trial.text;
    trialMeter.classList.toggle("meter--warn", trial.warn);
  }
  element("hours-card", HTMLElement).classList.toggle("hidden", hours === null);
  if (hours !== null) {
    element("hours-value", HTMLElement).textContent = hours.text;
    const meter: HTMLProgressElement = element("hours-meter", HTMLProgressElement);
    meter.max = hours.cap;
    meter.value = hours.used;
    meter.textContent = hours.text;
    meter.classList.toggle("meter--warn", hours.warn && !hours.full);
    meter.classList.toggle("meter--full", hours.full);
    element("hours-left", HTMLElement).textContent = hours.left;
    element("hours-foot", HTMLElement).classList.toggle("hidden", hours.limitReached !== null);
    const limit: HTMLElement = element("hours-limit", HTMLElement);
    limit.classList.toggle("hidden", hours.limitReached === null);
    limit.textContent = hours.limitReached ?? "";
  }
}

/** Katman seçimini yazar (adlar ve saatler); Pro sunulmuyorsa gizler. */
function renderTierChoices(choices: readonly TierChoice[] | null): void {
  const fieldset: HTMLElement = element("tier-choice", HTMLElement);
  fieldset.classList.toggle("hidden", choices === null);
  for (const option of Array.from(fieldset.querySelectorAll<HTMLElement>("[data-tier-option]"))) {
    const choice: TierChoice | undefined = choices?.find((item: TierChoice): boolean => item.tier === option.dataset["tierOption"]);
    option.classList.toggle("hidden", choice === undefined);
    if (choice !== undefined) {
      element(`tier-name-${choice.tier}`, HTMLElement).textContent = choice.name;
      element(`tier-hours-${choice.tier}`, HTMLElement).textContent = choice.hours;
    }
  }
}

/** Katman değiştirme düğmesini ve notunu yazar; hedef katman ve plan düğmenin `data-*` değerlerindedir. */
function renderTierSwitch(value: TierSwitch | null): void {
  const button: HTMLButtonElement = element("switch-tier-button", HTMLButtonElement);
  button.classList.toggle("hidden", value === null);
  const note: HTMLElement = element("switch-tier-note", HTMLElement);
  note.classList.toggle("hidden", value === null);
  note.textContent = value === null ? "" : value.note;
  button.textContent = value === null ? "" : value.label;
  button.dataset["tier"] = value === null ? "" : value.tier;
  button.dataset["plan"] = value === null ? "" : value.plan;
}

/** Değerleri sayfaya yazar. */
function render(view: AccountView): void {
  element("plan-value", HTMLElement).textContent = view.plan;
  renderPill(element("plan-pill", HTMLElement), view.planPill);
  renderStatus(view.status);
  element("win-back", HTMLElement).classList.toggle("hidden", view.winBack === null);
  element("win-back-text", HTMLElement).textContent = view.winBack ?? "";
  renderMeters(view.trialMeter, view.hours);
  renderAiMeter(view.ai);
  const alert: HTMLElement = element("plan-alert", HTMLElement);
  alert.classList.toggle("hidden", view.alert === null);
  alert.textContent = view.alert ?? "";
  element("subscribe-button", HTMLButtonElement).classList.toggle("hidden", !view.canSubscribe);
  element("plan-choice", HTMLElement).classList.toggle("hidden", !view.canSubscribe);
  element("invite", HTMLElement).classList.toggle("hidden", !view.canSubscribe);
  element("manage-button", HTMLButtonElement).classList.toggle("hidden", !view.canManage);
  element("subscribe-note", HTMLElement).classList.toggle("hidden", !view.canSubscribe);
  element("manage-note", HTMLElement).classList.toggle("hidden", view.canSubscribe || !view.canManage);
  renderTierChoices(view.tierChoices);
  renderTierSwitch(view.tierSwitch);
  element("withdraw-card", HTMLElement).classList.toggle("hidden", view.withdrawal === null);
  element("withdraw-text", HTMLElement).textContent = view.withdrawal ?? "";
  element("withdraw-button", HTMLButtonElement).classList.toggle("hidden", view.withdrawalPending);
  element("withdraw-retry", HTMLButtonElement).classList.toggle("hidden", !view.withdrawalPending);
  const deleteWarning: HTMLElement = element("delete-app-store-warning", HTMLElement);
  deleteWarning.classList.toggle("hidden", view.deleteWarning === null);
  deleteWarning.textContent = view.deleteWarning ?? "";
}

/** `GET /v1/me`. */
async function fetchMe(): Promise<Entitlements> {
  const path: string = "/v1/me";
  const response: RawResponse = await authorizedSend({ method: "GET", path, body: null, attempts: 3 });
  return parseEntitlements(response, path);
}

/** Bekler. */
function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve: () => void): void => {
    setTimeout(resolve, milliseconds);
  });
}

/** Ödeme dönüşünde abonelik görünene dek (en çok `paymentPollAttempts` kez) yeniden bakar. */
async function fetchMeAfterPayment(): Promise<Entitlements> {
  let me: Entitlements = await fetchMe();
  for (let attempt: number = 1; attempt < paymentPollAttempts && me.plan !== "subscription"; attempt += 1) {
    await delay(paymentPollIntervalMs);
    me = await fetchMe();
  }
  return me;
}

/** Ödeme eylemlerinin durumu (sayfa ömrünce; geçişler src/lib/checkout-state.ts'te). */
let checkout: CheckoutState = idleCheckout;

/** Ödeme durumu kilitliyken kapanan düğmeler. */
const checkoutButtonIds: readonly string[] = [
  "subscribe-button",
  "manage-button",
  "switch-tier-button",
  "invite-apply",
  "invite-remove",
  "withdraw-button",
  "withdraw-confirm-button",
  "withdraw-retry",
];

/** Ödeme olayını uygular ve düğmeleri yeni duruma göre açar ya da kapatır; olay bu durumda geçersizse false. */
function applyCheckout(event: CheckoutEvent): boolean {
  const next: CheckoutState | null = checkoutTransition(checkout, event);
  if (next === null) {
    console.info("checkout_event_ignored", { event: event.type, state: checkout.kind });
    return false;
  }
  checkout = next;
  const locked: boolean = checkoutControlsLocked(next);
  for (const id of checkoutButtonIds) {
    element(id, HTMLButtonElement).disabled = locked;
  }
  return true;
}

/**
 * Ödeme eylemini kilit altında yürütür: başka bir ödeme eylemi yürürken çağrılırsa hiçbir şey yapmaz. Eylem
 * yönlendirmeden biterse (hata dahil) kilit açılır; yönlendirmede sayfa kapanana kadar kilitli kalır.
 */
async function runCheckout(start: "validateInvite" | "openBilling" | "withdraw", action: () => Promise<void>): Promise<void> {
  if (!applyCheckout({ type: start })) {
    return;
  }
  try {
    await action();
  } finally {
    if (checkout.kind !== "redirecting") {
      applyCheckout({ type: "settled" });
    }
  }
}

/** Checkout, Portal ya da katman değiştirme (Stripe) adresini alıp oraya geçer (`runCheckout("openBilling", …)` içinde çağrılır). */
async function openBilling(path: "/v1/billing/checkout" | "/v1/billing/portal" | "/v1/billing/change-plan", body: JsonObject): Promise<void> {
  const response: RawResponse = await authorizedSend({ method: "POST", path, body, attempts: 1 });
  const url: string = parseRedirectUrl(response, path);
  if (!applyCheckout({ type: "redirect" })) {
    throw new Error(`${path} yönlendirmesi ödeme kilidi dışında istendi (durum ${checkout.kind}).`);
  }
  window.location.assign(url);
}

/**
 * Checkout gövdesi: seçilen plan, Pro ise katman (Personal varsayılandır; katmanı bilmeyen eski sunucu bilinmeyen alanı
 * reddettiği için Personal'de gönderilmez) ve (doğrulanmışsa) davet kodu. Saf fonksiyondur.
 */
export function checkoutBody(plan: BillingPlan, tier: SubscriptionTier, referralCode: string | null): JsonObject {
  const tierField: JsonObject = tier === "pro" ? { tier } : {};
  return referralCode === null ? { plan, ...tierField } : { plan, ...tierField, referralCode };
}

/** Stripe abonesinin katman değiştirmesi: düğmenin hedef katmanı ve planıyla Stripe'ın onay sayfasını açar. */
async function changeTier(button: HTMLButtonElement): Promise<void> {
  const tier: SubscriptionTier | null = subscriptionTierOf(button.dataset["tier"] ?? null);
  const plan: BillingPlan | null = billingPlanOf(button.dataset["plan"] ?? null);
  if (tier === null || plan === null) {
    throw new Error(`Katman değiştirme düğmesinde hedef yok: tier=${String(button.dataset["tier"])}, plan=${String(button.dataset["plan"])}.`);
  }
  await openBilling("/v1/billing/change-plan", { tier, plan });
}

/** Davet hatasının kodu (sunucunun `referral_*` kodları); başka hata null. Saf fonksiyondur. */
function inviteErrorCode(error: unknown): keyof ClientCopy["inviteErrors"] | null {
  if (!(error instanceof ApiRequestError)) {
    return null;
  }
  const codes: readonly (keyof ClientCopy["inviteErrors"])[] = ["referral_invalid", "referral_self", "referral_not_eligible", "referral_unavailable", "referral_limit_reached"];
  return codes.find((code: keyof ClientCopy["inviteErrors"]): boolean => code === error.code) ?? null;
}

/** Plan seçimi ve davet kodu alanının durumu (sayfa ömrünce). */
interface CheckoutForm {
  /** Sunucunun doğruladığı kod; yoksa null. */
  validatedCode: string | null;
}

/** Seçili plan (radyo düğmeleri; biri her zaman seçilidir). */
function selectedPlan(): BillingPlan {
  const checked: HTMLInputElement | null = document.querySelector<HTMLInputElement>('#plan-choice input[name="plan"]:checked');
  const plan: BillingPlan | null = billingPlanOf(checked === null ? null : checked.value);
  if (plan === null) {
    throw new Error("Plan seçimi okunamadı: seçili radyo düğmesi yok.");
  }
  return plan;
}

/** Seçili katman: katman seçimi gizliyse (Pro sunulmuyor) Personal, değilse seçili radyo düğmesi. */
function selectedTier(): SubscriptionTier {
  if (element("tier-choice", HTMLElement).classList.contains("hidden")) {
    return "personal";
  }
  const checked: HTMLInputElement | null = document.querySelector<HTMLInputElement>('#tier-choice input[name="tier"]:checked');
  const tier: SubscriptionTier | null = subscriptionTierOf(checked === null ? null : checked.value);
  if (tier === null) {
    throw new Error("Katman seçimi okunamadı: seçili radyo düğmesi yok.");
  }
  return tier;
}

/** Katmanı seçer ve plan seçeneklerinde o katmanın fiyatlarını gösterir. */
function selectTier(tier: SubscriptionTier): void {
  const input: HTMLInputElement | null = document.querySelector<HTMLInputElement>(`#tier-choice input[name="tier"][value="${tier}"]`);
  if (input === null) {
    throw new Error(`Katman seçiminde "${tier}" düğmesi yok.`);
  }
  input.checked = true;
  showTierPrices(tier);
}

/**
 * Seçime bağlı metinleri yazar: Abone ol düğmesi (katman ve tutar), altındaki yenileme koşulları ve katman seçiminde her
 * katmanın seçili plandaki tutarı.
 */
function renderSelection(text: ClientCopy): void {
  const tier: SubscriptionTier = selectedTier();
  const plan: BillingPlan = selectedPlan();
  element("subscribe-button", HTMLButtonElement).textContent = subscribeLabel(tier, plan, text);
  const terms: CheckoutTerms = checkoutTerms(tier, plan, text);
  element("subscribe-terms-lead", HTMLElement).textContent = terms.lead;
  element("subscribe-terms-rest", HTMLElement).textContent = terms.rest;
  for (const option of ["personal", "pro"] as const) {
    element(`tier-price-${option}`, HTMLElement).textContent = fill(text.billedTotal[plan], { price: formatUsdCents(planPriceCents(tierPrices[option], plan)) });
  }
}

/** Plan seçeneklerinde yalnızca katmanın fiyatlarını (fiyat, ayrıntı, rozet) gösterir. */
function showTierPrices(tier: SubscriptionTier): void {
  for (const price of Array.from(document.querySelectorAll<HTMLElement>("#plan-choice [data-price-tier]"))) {
    price.classList.toggle("hidden", price.dataset["priceTier"] !== tier);
  }
}

/** Planı seçer. */
function selectPlan(plan: BillingPlan): void {
  const input: HTMLInputElement | null = document.querySelector<HTMLInputElement>(`#plan-choice input[name="plan"][value="${plan}"]`);
  if (input === null) {
    throw new Error(`Plan seçiminde "${plan}" düğmesi yok.`);
  }
  input.checked = true;
}

/** Davet durum satırını gösterir (`ok`: uygulandı, `error`: hata, `plain`: denetleniyor); metin null ise gizler. */
function showInviteStatus(message: string | null, tone: "ok" | "error" | "plain"): void {
  const status: HTMLElement = element("invite-status", HTMLElement);
  status.classList.toggle("hidden", message === null);
  status.classList.toggle("invite__ok", tone === "ok");
  status.classList.toggle("invite__error", tone === "error");
  status.textContent = message ?? "";
}

/** Uygulanan kodun satırını seçili plana göre yazar; kaldır düğmesi yalnızca kod uygulanınca görünür. */
function renderAppliedInvite(form: CheckoutForm, text: ClientCopy): void {
  element("invite-remove", HTMLButtonElement).classList.toggle("hidden", form.validatedCode === null);
  if (form.validatedCode !== null) {
    showInviteStatus(text.inviteApplied[selectedTier()][selectedPlan()], "ok");
  }
}

/**
 * Alandaki kodu sunucuda doğrular. Geçerliyse kaydedilir ve true; biçimsiz ya da sunucu reddederse satırda neden yazar
 * ve false. Ağ ve beklenmeyen hatalar fırlatılır (düğmenin bildirimi gösterir).
 */
async function applyInvite(form: CheckoutForm, text: ClientCopy): Promise<boolean> {
  const input: HTMLInputElement = element("invite-input", HTMLInputElement);
  form.validatedCode = null;
  renderAppliedInvite(form, text);
  const code: string | null = normalizedInviteCode(input.value);
  if (code === null) {
    showInviteStatus(text.inviteErrors.format, "error");
    return false;
  }
  showInviteStatus(text.inviteChecking, "plain");
  const path: string = "/v1/referral/validate";
  try {
    const response: RawResponse = await authorizedSend({ method: "POST", path, body: { code }, attempts: 1 });
    form.validatedCode = parseValidatedReferralCode(response, path);
  } catch (error: unknown) {
    const reason: keyof ClientCopy["inviteErrors"] | null = inviteErrorCode(error);
    if (reason === null) {
      showInviteStatus(null, "plain");
      throw error;
    }
    if (reason !== "referral_unavailable" && reason !== "referral_limit_reached") {
      // Bu hesapta kullanılamayan kod saklanmaz: sonraki ziyarette yeniden denenmez (geçici redler saklanır).
      forgetInviteCode();
    }
    showInviteStatus(text.inviteErrors[reason], "error");
    return false;
  }
  input.value = form.validatedCode;
  storeInviteCode(form.validatedCode);
  renderAppliedInvite(form, text);
  return true;
}

/** Davet kodunu kaldırır: alan boşalır, kayıt silinir. */
function removeInvite(form: CheckoutForm, text: ClientCopy): void {
  form.validatedCode = null;
  element("invite-input", HTMLInputElement).value = "";
  forgetInviteCode();
  renderAppliedInvite(form, text);
  showInviteStatus(null, "plain");
}

/**
 * Alanda uygulanmış koddan farklı bir şey yazılı mı: boş değil ve biçimsiz ya da doğrulanan koddan farklı. Biçimsiz
 * metin de sayılır (yoksa yazım hatalı bir kod sessizce atlanır ve Checkout tam fiyatla açılır). Saf fonksiyondur.
 */
function hasUnappliedInvite(typed: string, validatedCode: string | null): boolean {
  if (typed === "") {
    return false;
  }
  const typedCode: string | null = normalizedInviteCode(typed);
  return typedCode === null || typedCode !== validatedCode;
}

/**
 * Abone ol: alanda uygulanmamış bir kod varsa önce doğrulanır; biçimsiz ya da geçersizse Checkout açılmaz, davet alanı
 * açılır ve satırda neden yazar. Bitmemiş abonelik varsa sunucu 409 döner, Portal açılır; Checkout davet kodunu
 * reddederse neden satırda yazar.
 */
async function subscribe(form: CheckoutForm, text: ClientCopy): Promise<void> {
  const typed: string = element("invite-input", HTMLInputElement).value.trim();
  if (hasUnappliedInvite(typed, form.validatedCode) && !(await applyInvite(form, text))) {
    element("invite", HTMLDetailsElement).open = true;
    return;
  }
  try {
    await openBilling("/v1/billing/checkout", checkoutBody(selectedPlan(), selectedTier(), form.validatedCode));
  } catch (error: unknown) {
    if (error instanceof ApiRequestError && error.code === "subscription_exists") {
      await openBilling("/v1/billing/portal", {});
      return;
    }
    const reason: keyof ClientCopy["inviteErrors"] | null = inviteErrorCode(error);
    if (reason !== null) {
      form.validatedCode = null;
      renderAppliedInvite(form, text);
      element("invite", HTMLDetailsElement).open = true;
      showInviteStatus(text.inviteErrors[reason], "error");
      return;
    }
    throw error;
  }
}

/** Plan seçimini ve davet alanını bağlar; kayıtlı plan ve kod alanlara yazılır (kod sayfa açılınca doğrulanır). */
function bindCheckoutForm(form: CheckoutForm, text: ClientCopy, notice: HTMLElement, signInPath: string): void {
  selectPlan(storedPlan() ?? recommendedPlan);
  for (const input of Array.from(document.querySelectorAll<HTMLInputElement>('#plan-choice input[name="plan"]'))) {
    input.addEventListener("change", (): void => {
      storePlan(selectedPlan());
      renderAppliedInvite(form, text);
      renderSelection(text);
    });
  }
  for (const input of Array.from(document.querySelectorAll<HTMLInputElement>('#tier-choice input[name="tier"]'))) {
    input.addEventListener("change", (): void => {
      const tier: SubscriptionTier = selectedTier();
      storeTier(tier);
      showTierPrices(tier);
      renderAppliedInvite(form, text);
      renderSelection(text);
    });
  }
  bindCheckoutAction(element("invite-apply", HTMLButtonElement), notice, text, signInPath, (): Promise<void> =>
    runCheckout("validateInvite", async (): Promise<void> => {
      await applyInvite(form, text);
    }),
  );
  element("invite-remove", HTMLButtonElement).addEventListener("click", (): void => {
    removeInvite(form, text);
  });
  element("invite-input", HTMLInputElement).addEventListener("keydown", (event: KeyboardEvent): void => {
    if (event.key === "Enter") {
      event.preventDefault();
      element("invite-apply", HTMLButtonElement).click();
    }
  });
}

/** Kayıtlı davet kodu varsa alanı açar, kodu yazar ve doğrular (abone olabilen hesapta). */
async function prefillInvite(form: CheckoutForm, text: ClientCopy): Promise<void> {
  const code: string | null = storedInviteCode();
  if (code === null) {
    return;
  }
  element("invite", HTMLDetailsElement).open = true;
  element("invite-input", HTMLInputElement).value = code;
  await runCheckout("validateInvite", async (): Promise<void> => {
    await applyInvite(form, text);
  });
}

/** `GET /v1/referral`. */
async function fetchReferral(): Promise<ReferralInfo> {
  const path: string = "/v1/referral";
  const response: RawResponse = await authorizedSend({ method: "GET", path, body: null, attempts: 3 });
  return parseReferral(response, path);
}

/** Davet kartının bir sayısı: etiket, değer ve (bu yıl kalan ödülde) yıllık sınır metni; sınır yoksa null. */
interface ReferralStat {
  readonly label: string;
  readonly value: string;
  readonly cap: string | null;
}

/** Davet kartının değerleri: sayı satırı (boş olabilir) ve altındaki kısa not (yoksa null). */
interface ReferralView {
  readonly stats: readonly ReferralStat[];
  readonly note: string | null;
}

/**
 * Davet kartının değerleri. Davetin ücretsiz ilk ayındaki hesapta sunucu kod vermez: sayı yok, not kodun ilk ücretli
 * aydan sonra açılacağını söyler. Ücretsiz erişimli hesapta arkadaşlar yine davet indirimini alır, ama ödenecek fatura
 * olmadığından 5,99 $ ödülü uygulanmaz (sunucu `referrer_complimentary` ile düşürür): yalnızca katılanlar ve bunu
 * anlatan not. App Store abonesinde de ödül (web ödemesinden düşülen alacak) uygulanmaz: yalnızca katılanlar ve not.
 * Diğerlerinde dört sayı ve bekleyen ödül varsa en yakınının tahmini tarihi. Saf fonksiyondur.
 */
function referralView(referral: ReferralInfo, text: ClientCopy, locale: string): ReferralView {
  if (referral.code === null || referral.inviteUrl === null) {
    return { stats: [], note: text.referralCodeAfterFirstPayment };
  }
  const joined: ReferralStat = { label: text.referralStats.joined, value: String(referral.joined), cap: null };
  if (referral.complimentary) {
    return { stats: [joined], note: text.referralComplimentaryNote };
  }
  if (referral.appStoreBilled) {
    return { stats: [joined], note: text.referralAppStoreNote };
  }
  return {
    stats: [
      joined,
      { label: text.referralStats.rewarded, value: String(referral.rewarded), cap: null },
      { label: text.referralStats.pending, value: String(referral.pending), cap: null },
      {
        label: text.referralStats.left,
        value: String(referral.rewardsLeftThisYear),
        cap: fill(text.referralStats.ofCap, { cap: String(referral.rewardsPerYear) }),
      },
    ],
    note: referral.nextRewardAt === null ? null : fill(text.referralNextReward, { date: formatDate(referral.nextRewardAt, locale) }),
  };
}

/** Davet kartının sayı satırını ve notunu yazar; boş olan gizlenir. */
function renderReferralView(view: ReferralView): void {
  const stats: HTMLElement = element("referral-stats", HTMLElement);
  stats.classList.toggle("hidden", view.stats.length === 0);
  stats.replaceChildren(
    ...view.stats.map((stat: ReferralStat): HTMLElement => {
      const item: HTMLElement = document.createElement("div");
      item.className = "stat";
      const label: HTMLElement = document.createElement("dt");
      label.className = "stat__label";
      label.textContent = stat.label;
      const value: HTMLElement = document.createElement("dd");
      value.className = "stat__value";
      value.textContent = stat.value;
      if (stat.cap !== null) {
        const cap: HTMLElement = document.createElement("span");
        cap.className = "stat__cap";
        cap.textContent = ` ${stat.cap}`;
        value.append(cap);
      }
      item.append(label, value);
      return item;
    }),
  );
  const note: HTMLElement = element("referral-note", HTMLElement);
  note.classList.toggle("hidden", view.note === null);
  note.textContent = view.note ?? "";
}

/** Davet kartını çizer: program açık ve kod varsa (abonelik erişimi) paylaşım alanıyla, kod yoksa yalnızca notla görünür. */
function renderReferral(referral: ReferralInfo, text: ClientCopy, locale: string, notice: HTMLElement): void {
  const card: HTMLElement = element("referral-card", HTMLElement);
  const share: HTMLElement = element("referral-share", HTMLElement);
  const inviteUrl: string | null = referral.inviteUrl;
  if (!referral.enabled) {
    card.classList.add("hidden");
    return;
  }
  renderReferralView(referralView(referral, text, locale));
  if (referral.code === null || inviteUrl === null) {
    share.classList.add("hidden");
    card.classList.remove("hidden");
    return;
  }
  share.classList.remove("hidden");
  element("referral-code", HTMLElement).textContent = referral.code;
  const copied: HTMLElement = element("referral-copied", HTMLElement);
  const button: HTMLButtonElement = element("referral-copy", HTMLButtonElement);
  button.onclick = (): void => {
    hideNotice(notice);
    navigator.clipboard
      .writeText(inviteUrl)
      .then((): void => {
        copied.classList.remove("hidden");
      })
      .catch((error: unknown): void => {
        console.error("invite_link_copy_failed", { error: error instanceof Error ? error.message : String(error) });
        showNotice(notice, fill(text.errors.generic, { code: "clipboard" }));
      });
  };
  card.classList.remove("hidden");
}

/** Abonenin davet kartını yükler; yüklenemezse kart gizli kalır ve hata konsola yazılır (hesabın geri kalanı çalışır). */
async function loadReferral(text: ClientCopy, notice: HTMLElement): Promise<void> {
  try {
    const referral: ReferralInfo = await fetchReferral();
    renderReferral(referral, text, siteLocale, notice);
  } catch (error: unknown) {
    if (error instanceof SignedOutError) {
      throw error;
    }
    console.error("referral_load_failed", { error: error instanceof Error ? error.message : String(error) });
    element("referral-card", HTMLElement).classList.add("hidden");
  }
}

/**
 * Adresteki `?plan=`, `?tier=` ve `?code=` seçimlerini saklar (girişe yönlendirmeden önce; sorgu adresten silinir).
 * Biçimsiz kod saklanmaz. Fiyat sayfasının Personal düğmeleri katman göndermez: plan seçildiyse katman Personal'dir
 * (önceki bir Pro seçimi kalmaz).
 */
function rememberQueryChoices(params: URLSearchParams): boolean {
  const plan: BillingPlan | null = billingPlanOf(params.get("plan"));
  const tier: SubscriptionTier | null = subscriptionTierOf(params.get("tier"));
  if (tier !== null) {
    storeTier(tier);
  } else if (plan !== null) {
    storeTier("personal");
  }
  const rawCode: string | null = params.get("code");
  const code: string | null = rawCode === null ? null : normalizedInviteCode(rawCode);
  const checkout: boolean = params.get("checkout") === "1";
  if (plan !== null) {
    storePlan(plan);
  }
  if (code !== null) {
    storeInviteCode(code);
  }
  if (checkout) {
    // Fiyat sayfasındaki plan düğmesi: seçim yapıldı, ödeme sayfasına gidilecek (giriş gerekirse sonra).
    storeCheckoutIntent();
  }
  return params.has("plan") || params.has("tier") || params.has("code") || checkout;
}

/** Düğme eyleminin hatası: oturum düştüyse giriş sayfasına geçilir, değilse bildirimde yazar. */
function reportActionError(error: unknown, notice: HTMLElement, text: ClientCopy, signInPath: string): void {
  if (error instanceof SignedOutError) {
    window.location.replace(signInPath);
    return;
  }
  showNotice(notice, errorText(error, text));
}

/** Düğmeye uzun süren bir işlem bağlar: süre boyunca düğme kapalı, hata bildirimde. */
function bindAction(button: HTMLButtonElement, notice: HTMLElement, text: ClientCopy, signInPath: string, action: () => Promise<void>): void {
  button.addEventListener("click", (): void => {
    hideNotice(notice);
    button.disabled = true;
    action()
      .catch((error: unknown): void => {
        reportActionError(error, notice, text, signInPath);
      })
      .finally((): void => {
        button.disabled = false;
      });
  });
}

/** Ödeme düğmesine işlem bağlar: düğmenin açık ya da kapalı oluşu ödeme durumundan gelir (`applyCheckout`), hata bildirimde. */
function bindCheckoutAction(button: HTMLButtonElement, notice: HTMLElement, text: ClientCopy, signInPath: string, action: () => Promise<void>): void {
  button.addEventListener("click", (): void => {
    hideNotice(notice);
    action().catch((error: unknown): void => {
      reportActionError(error, notice, text, signInPath);
    });
  });
}

/**
 * Ödeme dönüşünün sonucu: abonelik erişimi göründüyse onay kartı (plan adı ve aylık saat; tek sonraki adım takvim),
 * görünmediyse (webhook gecikti) "Refresh my plan" düğmeli bekleme satırı.
 */
function renderPaymentResult(me: Entitlements, text: ClientCopy): void {
  const state: PlanState = planState(me, new Date());
  const subscribed: boolean = hasSubscriptionAccess(state);
  element("payment-done", HTMLElement).classList.toggle("hidden", !subscribed);
  element("payment-pending", HTMLElement).classList.toggle("hidden", subscribed);
  if (subscribed) {
    element("confirmation-plan", HTMLElement).textContent = fill(text.confirmation.text, {
      plan: planName(state, text),
      hours: formatHourCount(me.monthlyHoursCap, siteLocale),
    });
  }
}

/**
 * Silme penceresini bağlar: onay kelimesi yazılınca silme düğmesi açılır. Alanda Enter, pencereyi kapatan örtük form
 * gönderimi (`method="dialog"`) yerine silme düğmesine basar (düğme kapalıysa hiçbir şey olmaz); Escape pencereyi kapatır.
 */
function bindDeletion(text: ClientCopy, signInPath: string, homePath: string): void {
  const dialog: HTMLDialogElement = element("delete-dialog", HTMLDialogElement);
  const input: HTMLInputElement = element("confirm-input", HTMLInputElement);
  const confirm: HTMLButtonElement = element("confirm-delete", HTMLButtonElement);
  const dialogNotice: HTMLElement = element("delete-error", HTMLElement);
  const confirmWord: string = dataValue(dialog, "confirmWord");

  element("delete-button", HTMLButtonElement).addEventListener("click", (): void => {
    input.value = "";
    confirm.disabled = true;
    hideNotice(dialogNotice);
    dialog.showModal();
  });
  element("cancel-delete", HTMLButtonElement).addEventListener("click", (): void => {
    dialog.close();
  });
  input.addEventListener("input", (): void => {
    confirm.disabled = input.value.trim().toUpperCase() !== confirmWord;
  });
  input.addEventListener("keydown", (event: KeyboardEvent): void => {
    if (event.key !== "Enter") {
      return;
    }
    event.preventDefault();
    if (!confirm.disabled) {
      confirm.click();
    }
  });
  bindAction(confirm, dialogNotice, text, signInPath, async (): Promise<void> => {
    await authorizedSend({ method: "DELETE", path: "/v1/me", body: null, attempts: 1 });
    clearSession();
    dialog.close();
    element("account-content", HTMLElement).classList.add("hidden");
    // Oturum yok: çıkış düğmesi de gizlenir.
    element("signout-button", HTMLButtonElement).classList.add("hidden");
    const deleted: HTMLElement = element("account-deleted", HTMLElement);
    deleted.classList.remove("hidden");
    deleted.focus();
    // Kısa bir süre "hesabın silindi" görünür, sonra ana sayfaya geçilir (elle dönüş bağlantısı da durur).
    setTimeout((): void => {
      window.location.assign(homePath);
    }, deletedRedirectMs);
  });
}

/** Oturumsuz ödeme dönüşü: yükleniyor ve hesap düğmeleri gizlenir, "ödeme alındı" kartı görünür. */
function showPaidSignedOut(): void {
  element("account-loading", HTMLElement).classList.add("hidden");
  element("signout-button", HTMLButtonElement).classList.add("hidden");
  element("payment-done-signed-out", HTMLElement).classList.remove("hidden");
}

/**
 * Yüklenen hesabı çizer ve sonrasını yürütür: abone olabilen hesapta kayıtlı katman (sunuluyorsa) seçilir ve kayıtlı
 * davet kodu doğrulanır, abonede davet kartı yüklenir, fiyat sayfasından gelen ödeme niyeti varsa Checkout açılır.
 * Fiyat sayfasında Pro seçilmiş ama sunucu Pro'yu artık sunmuyorsa Checkout açılmaz (yerine Personal satılmaz):
 * bildirim Pro'nun satılmadığını söyler, seçim Personal kalır.
 */
async function showAccount(me: Entitlements, form: CheckoutForm, text: ClientCopy, notice: HTMLElement): Promise<void> {
  const view: AccountView = accountView(me, text, siteLocale, new Date());
  render(view);
  const wantedTier: SubscriptionTier | null = storedTier();
  const proUnavailable: boolean = wantedTier === "pro" && view.tierChoices === null;
  selectTier(wantedTier !== null && !proUnavailable ? wantedTier : "personal");
  renderSelection(text);
  element("account-loading", HTMLElement).classList.add("hidden");
  element("account-content", HTMLElement).classList.remove("hidden");
  if (view.canSubscribe) {
    await prefillInvite(form, text);
  }
  if (me.plan === "subscription") {
    await loadReferral(text, notice);
  }
  // Fiyat sayfasından gelen ziyaretçi planını seçti ve giriş yaptı: artık doğrudan Ödeme sayfasına geçilir
  // (niyet yalnızca seçimin yapıldığı sekmede tutulur ve bir kez kullanılır).
  if (checkoutIntended()) {
    forgetCheckoutIntent();
    if (view.canSubscribe && proUnavailable) {
      console.warn("checkout_pro_unavailable", { offeredTiers: me.offeredTiers.map((offer: TierOffer): SubscriptionTier => offer.tier) });
      showNotice(notice, text.errors.proUnavailable);
      return;
    }
    if (view.canSubscribe) {
      await runCheckout("openBilling", (): Promise<void> => subscribe(form, text));
    }
  }
}

/** Hesap sayfasının hatasını gösterir: oturum düştüyse giriş sayfasına geçilir, değilse "yükleniyor" gizlenip hata yazılır. */
function reportAccountError(error: unknown, text: ClientCopy, notice: HTMLElement, signInPath: string): void {
  if (error instanceof SignedOutError) {
    window.location.replace(signInPath);
    return;
  }
  element("account-loading", HTMLElement).classList.add("hidden");
  showNotice(notice, errorText(error, text));
}

/**
 * Hesabı `fetchAccount` ile okuyup gösterir. Okunamazsa hatanın altında yeniden deneme düğmesi de görünür (oturum
 * düşmediyse); gösterdikten sonraki bir hata (davet kodu, Checkout) yalnızca bildirimde yazar.
 */
async function loadAccount(fetchAccount: () => Promise<Entitlements>, form: CheckoutForm, text: ClientCopy, notice: HTMLElement, signInPath: string): Promise<void> {
  let me: Entitlements;
  try {
    me = await fetchAccount();
  } catch (error: unknown) {
    reportAccountError(error, text, notice, signInPath);
    element("account-retry", HTMLButtonElement).classList.toggle("hidden", error instanceof SignedOutError);
    return;
  }
  try {
    await showAccount(me, form, text, notice);
  } catch (error: unknown) {
    reportAccountError(error, text, notice, signInPath);
  }
}

/**
 * Ödeme dönüşünde hesabı yükler (abonelik görünene dek birkaç kez bakar) ve sonucu gösterir. "Refresh my plan" aynı
 * işi yeniden yapar.
 */
function loadAfterPayment(form: CheckoutForm, text: ClientCopy, notice: HTMLElement, signInPath: string): Promise<void> {
  return loadAccount(
    async (): Promise<Entitlements> => {
      const me: Entitlements = await fetchMeAfterPayment();
      renderPaymentResult(me, text);
      return me;
    },
    form,
    text,
    notice,
    signInPath,
  );
}

/** Cayma onay adımını açar ya da kapatır (açıkken "Withdraw from contract" düğmesi gizlenir). */
function showWithdrawConfirm(open: boolean): void {
  element("withdraw-confirm", HTMLElement).classList.toggle("hidden", !open);
  element("withdraw-button", HTMLButtonElement).classList.toggle("hidden", open);
  hideNotice(element("withdraw-error", HTMLElement));
}

/**
 * Cayma işlevini bağlar: düğme onay adımını açar; "Confirm withdrawal" `POST /v1/billing/withdraw`'u çağırır, sonucu
 * (yerel tarih ve saat, plan, iade tutarı) kalıcı onay kartına yazar ve hesabı yeniden yükler (abonelik bitti).
 */
function bindWithdrawal(form: CheckoutForm, text: ClientCopy, notice: HTMLElement, signInPath: string): void {
  element("withdraw-button", HTMLButtonElement).addEventListener("click", (): void => {
    showWithdrawConfirm(true);
  });
  element("withdraw-cancel", HTMLButtonElement).addEventListener("click", (): void => {
    showWithdrawConfirm(false);
  });
  // Withdrawal runs under the billing lock (`runCheckout("withdraw", …)`): no Checkout, Portal or plan change meanwhile.
  bindCheckoutAction(element("withdraw-confirm-button", HTMLButtonElement), element("withdraw-error", HTMLElement), text, signInPath, () => runCheckout("withdraw", async (): Promise<void> => {
    const path: string = "/v1/billing/withdraw";
    const plan: string = element("plan-value", HTMLElement).textContent ?? "";
    const response: RawResponse = await authorizedSend({ method: "POST", path, body: null, attempts: 1 });
    const result: WithdrawalResult = parseWithdrawal(response, path);
    const at: string = new Intl.DateTimeFormat(siteLocale, { dateStyle: "long", timeStyle: "short" }).format(new Date());
    const doneText: string = fill(text.withdrawal.doneText, {
      dateTime: at,
      plan,
      amount: formatRefund(result.refundedCents, result.currency, siteLocale),
    });
    element("withdraw-done-text", HTMLElement).textContent = result.pending ? `${doneText} ${text.withdrawal.refundPending}` : doneText;
    showWithdrawConfirm(false);
    element("withdraw-card", HTMLElement).classList.add("hidden");
    const done: HTMLElement = element("withdraw-done", HTMLElement);
    done.classList.remove("hidden");
    done.focus();
    await loadAccount(fetchMe, form, text, notice, signInPath);
  }));
  // Cayıldı ama iade doğrulanmadı: aynı uç, kayıtlı anla aynı tutarı yeniden dener (onay adımı yok, abonelik zaten bitti).
  const retryStatus: HTMLElement = element("withdraw-retry-status", HTMLElement);
  bindCheckoutAction(element("withdraw-retry", HTMLButtonElement), element("withdraw-retry-error", HTMLElement), text, signInPath, () => runCheckout("withdraw", async (): Promise<void> => {
    const path: string = "/v1/billing/withdraw";
    retryStatus.classList.add("hidden");
    const response: RawResponse = await authorizedSend({ method: "POST", path, body: null, attempts: 1 });
    const result: WithdrawalResult = parseWithdrawal(response, path);
    retryStatus.textContent = result.pending
      ? text.withdrawal.refundPending
      : fill(text.withdrawal.retryDone, { amount: formatRefund(result.refundedCents, result.currency, siteLocale) });
    retryStatus.classList.remove("hidden");
    await loadAccount(fetchMe, form, text, notice, signInPath);
  }));
}

/** Yeniden deneme düğmesini bağlar: bildirim ve düğme gizlenir, "yükleniyor" görünür, hesap yeniden okunur. */
function bindRetry(form: CheckoutForm, text: ClientCopy, notice: HTMLElement, signInPath: string): void {
  const retry: HTMLButtonElement = element("account-retry", HTMLButtonElement);
  retry.addEventListener("click", (): void => {
    retry.classList.add("hidden");
    hideNotice(notice);
    element("account-loading", HTMLElement).classList.remove("hidden");
    void loadAccount(fetchMe, form, text, notice, signInPath);
  });
}

/** Sayfayı başlatır. */
async function main(): Promise<void> {
  const root: HTMLElement = element("account", HTMLElement);
  const signInPath: string = dataValue(root, "signInPath");
  const notice: HTMLElement = element("account-error", HTMLElement);
  const homePath: string = dataValue(root, "homePath");
  const text: ClientCopy = clientCopy;
  const params: URLSearchParams = new URLSearchParams(window.location.search);
  // Stripe Checkout dönüşü: `/account?payment=done`. Sorgu hemen silinir; yenilemede bildirim yeniden görünmez.
  const paymentDone: boolean = params.get("payment") === "done";
  if (rememberQueryChoices(params) && !paymentDone) {
    history.replaceState(null, "", window.location.pathname);
  }
  if (paymentDone) {
    // Ödeme tamamlandı: davet kodu kullanıldı (ya da artık gerekmiyor), seçilen plan aboneliğe dönüştü.
    forgetInviteCode();
    forgetPlan();
    forgetTier();
    forgetCheckoutIntent();
  }
  await claimTabSession();
  if (!hasSession()) {
    if (paymentDone) {
      // Ödeme uygulamadan açıldı (bu sekmede oturum yok): giriş sayfası yerine "ödeme alındı, uygulamaya dön".
      showPaidSignedOut();
      history.replaceState(null, "", window.location.pathname);
      return;
    }
    window.location.replace(signInPath);
    return;
  }
  if (paymentDone) {
    history.replaceState(null, "", window.location.pathname);
  }

  const form: CheckoutForm = { validatedCode: null };
  bindCheckoutForm(form, text, notice, signInPath);
  bindCheckoutAction(element("subscribe-button", HTMLButtonElement), notice, text, signInPath, (): Promise<void> =>
    runCheckout("openBilling", (): Promise<void> => subscribe(form, text)),
  );
  bindCheckoutAction(element("manage-button", HTMLButtonElement), notice, text, signInPath, (): Promise<void> =>
    runCheckout("openBilling", (): Promise<void> => openBilling("/v1/billing/portal", {})),
  );
  const switchButton: HTMLButtonElement = element("switch-tier-button", HTMLButtonElement);
  bindCheckoutAction(switchButton, notice, text, signInPath, (): Promise<void> =>
    runCheckout("openBilling", (): Promise<void> => changeTier(switchButton)),
  );
  // Stripe'tan Geri ile dönülünce sayfa geri/ileri önbellekten olduğu gibi açılabilir: yönlendirme kilidi açılır.
  window.addEventListener("pageshow", (event: PageTransitionEvent): void => {
    if (event.persisted) {
      applyCheckout({ type: "pageRestored" });
    }
  });
  bindAction(element("signout-button", HTMLButtonElement), notice, text, signInPath, async (): Promise<void> => {
    try {
      await signOut();
    } finally {
      window.location.assign(homePath);
    }
  });
  bindDeletion(text, signInPath, homePath);
  bindRetry(form, text, notice, signInPath);
  bindWithdrawal(form, text, notice, signInPath);
  bindAction(element("payment-refresh", HTMLButtonElement), notice, text, signInPath, (): Promise<void> => loadAfterPayment(form, text, notice, signInPath));
  await (paymentDone ? loadAfterPayment(form, text, notice, signInPath) : loadAccount(fetchMe, form, text, notice, signInPath));
}

void main();
