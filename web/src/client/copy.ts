// Tarayıcı betiklerinin gösterdiği, sunucu yanıtına bağlı kısa metinler (giriş, hesap, iletişim, yönetim). Sayfa
// metinlerinden ayrı tutulur: betik paketine yalnızca bunlar girer.
import { productName } from "../config";

/** Tarayıcı betiklerinin metinleri. */
export interface ClientCopy {
  readonly errors: {
    readonly network: string;
    readonly rateLimited: string;
    readonly turnstile: string;
    readonly appleFailed: string;
    readonly appleUnavailable: string;
    readonly googleFailed: string;
    readonly googleUnavailable: string;
    /** Uygulamadan gelen giriş adresi eksik ya da bozuk (`app=1` ile geçerli `nonce` yok). */
    readonly appRequestInvalid: string;
    /** Sağlayıcıdan dönüş bu denemeye ait değil (`state` eşleşmiyor). */
    readonly appReturnInvalid: string;
    /** Tarayıcı depolaması kullanılamıyor (uygulama adına giriş yönlendirme boyunca ona yazar). */
    readonly storageUnavailable: string;
    readonly upstream: string;
    readonly messageTooLong: string;
    /** Ücretsiz erişimi olan hesapta Portal ya da Checkout (`complimentary_subscription`). */
    readonly complimentary: string;
    /** App Store aboneliği sürerken Checkout (`app_store_subscription`): abonelik burada da geçerli. */
    readonly appStoreSubscription: string;
    /** Bilinmeyen hata; `{code}` sunucunun hata koduyla değişir. */
    readonly generic: string;
  };
  /** Davet kodu doğrulamasının ve Checkout'un davet hataları (sunucu kodlarıyla). */
  readonly inviteErrors: {
    readonly format: string;
    readonly referral_invalid: string;
    readonly referral_self: string;
    readonly referral_not_eligible: string;
    readonly referral_unavailable: string;
    /** Kodun sahibinin ödül bekleyen davetleri sınırda (`referral_limit_reached`). */
    readonly referral_limit_reached: string;
  };
  /** Davet kodu durum satırı: denetleniyor, plan başına uygulanan indirim. */
  readonly inviteChecking: string;
  readonly inviteApplied: { readonly monthly: string; readonly yearly: string };
  /** Abonenin davet kartındaki sayıların etiketleri; `ofCap` bu yıl kalan ödülün yanında yıllık sınırdır (`{cap}`). */
  readonly referralStats: {
    readonly joined: string;
    readonly rewarded: string;
    readonly pending: string;
    readonly left: string;
    readonly ofCap: string;
  };
  /** Davetin ücretsiz ilk ayındaki hesap: kod ilk ücretli faturadan sonra açılır. */
  readonly referralCodeAfterFirstPayment: string;
  /** Bekleyen ödülün tahmini tarihi: `{date}`. */
  readonly referralNextReward: string;
  /** Ücretsiz erişimli hesapta davet kartının notu: arkadaşlar indirimi alır, ödül uygulanmaz. */
  readonly referralComplimentaryNote: string;
  /** App Store abonesinde davet kartının notu: arkadaşlar indirimi alır, ödül web ödemesinden düşüldüğü için uygulanmaz. */
  readonly referralAppStoreNote: string;
  /**
   * Planın adı: `subscription` abonelik planı bilinmiyorsa (eski fiyat); `complimentary` yöneticinin verdiği ücretsiz
   * erişim; `none` aboneliği (ya da ücretsiz erişimi) bitmiş ve denemesi kalmamış hesap.
   */
  readonly plan: {
    readonly trial: string;
    readonly subscription: string;
    readonly monthly: string;
    readonly yearly: string;
    readonly complimentary: string;
    readonly none: string;
  };
  /** Plan kartının etiket/değer satırları (deneme ve abonelik). */
  readonly facts: {
    readonly trialIncludes: string;
    /** `{total}` toplantı, `{days}` gün. */
    readonly trialIncludesValue: string;
    readonly trialStarts: string;
    readonly trialStartsValue: string;
    readonly trialEnds: string;
    readonly renews: string;
    readonly renewal: string;
    readonly renewalCancelled: string;
    readonly accessUntil: string;
  };
  /** Deneme ölçerinin değeri: `{left}` / `{total}` toplantı. */
  readonly trialMeetings: string;
  /** Deneme bitti (toplantılar harcandı ya da süre doldu). */
  readonly trialEnded: string;
  /** `{used}` ve `{cap}` saatlerle değişir. */
  readonly hours: string;
  /** Ölçerin altındaki ikincil değer: `{left}` saat kaldı. */
  readonly hoursLeft: string;
  /** Aylık sınır doldu: `{date}` sınırın sıfırlandığı gün (UTC). */
  readonly hoursLimitReached: string;
  /** Toplantı dışı yapay zekâ ölçerinin altındaki sıfırlanma satırı: `{date}` (UTC). */
  readonly aiResets: string;
  /** Toplantı dışı yapay zekâ hakkı doldu: `{date}` hakkın sıfırlandığı gün (UTC); kayıt etkilenmez. */
  readonly aiLimitReached: string;
  /** Ek sürede (ödeme alınamadı, erişim sürüyor) Aboneliği yönet düğmesinin yanındaki uyarı. */
  readonly subscriptionGraceAlert: string;
  readonly subscriptionEnded: string;
  /** Yenileme ödemesi alınamadı ve ek süre bitti: abonelik Stripe'ta sürer, kart güncellenince erişim döner. */
  readonly subscriptionPaymentOverdue: string;
  /** Ücretsiz erişim: ödeme ve yönetilecek bir şey yok. */
  readonly subscriptionComplimentary: string;
  /** Bitiş tarihli ücretsiz erişim: `{date}`. */
  readonly subscriptionComplimentaryUntil: string;
  /** Ücretsiz erişim bitti (hiç ödeme yapılmadı; "abonelik bitti" değil). */
  readonly subscriptionComplimentaryEnded: string;
  /** App Store (iPhone) aboneliği: yalnızca Apple'da yönetilir. */
  readonly subscriptionAppStore: string;
  /** Hesap silinirken süren App Store aboneliğinin uyarısı (Apple iptal etmez). */
  readonly deleteAppStoreWarning: string;
  readonly pillActive: string;
  readonly pillCanceling: string;
  readonly pillGrace: string;
  readonly pillEnded: string;
  readonly pillTrial: string;
  readonly pillComplimentary: string;
  readonly working: string;
  /** `{count}` ve `{max}` karakter sayısıyla değişir. */
  readonly characters: string;
  readonly admin: AdminClientCopy;
}

/** Yönetim panelinin değerlere bağlı metinleri. */
export interface AdminClientCopy {
  /** `{time}` saatle değişir. */
  readonly updated: string;
  /** MRR alt satırı: Stripe'ın modu. */
  readonly stripeTest: string;
  readonly stripeLive: string;
  readonly anonymous: string;
  readonly noSummary: string;
  readonly noMessage: string;
  /** Değer yok. */
  readonly none: string;
  readonly plans: { readonly subscription: string; readonly trial: string; readonly free: string };
  /** Abonelik planı (aylık, yıllık); bilinmeyen fiyatta gösterilmez. */
  readonly billingPlans: { readonly monthly: string; readonly yearly: string };
  readonly providers: { readonly apple: string; readonly google: string };
  /**
   * Ücretsiz tam erişim: plan rozeti, ayrıntıdaki abonelik metni (`{date}` bitiş tarihi ya da süresiz) ve ayrıntıdaki
   * verme ve kaldırma düğmeleri.
   */
  readonly freeAccess: { readonly pill: string; readonly until: string; readonly noEnd: string; readonly grant: string; readonly remove: string };
  /** Abonelik durumu rozetleri (Stripe durumu ve erişim). */
  readonly subscriptionPills: { readonly active: string; readonly ending: string; readonly grace: string; readonly ended: string };
  /** Deneme hücresi: `{used}`, `{left}`. */
  readonly trialCell: string;
  readonly trialNotStarted: string;
  readonly meetingKinds: { readonly trial: string; readonly subscription: string };
  readonly meetingStates: { readonly open: string; readonly ended: string; readonly superseded: string; readonly expired: string };
  readonly meetingNotes: { readonly deferred: string; readonly reprocessed: string; readonly deepgram: string; readonly attested: string };
  /** `{minutes}`. */
  readonly minutes: string;
  /** `{hours}`. */
  readonly hours: string;
  /**
   * Bildirim ayrıntısı: kopyalama düğmelerinin etiketleri, "kopyalandı" durumu, kopyalanamadı bildirimi ve MetricKit
   * özet satırının türleri (`more`: `{count}` ek teşhis).
   */
  readonly report: {
    readonly copyPayload: string;
    readonly copyUser: string;
    readonly copied: string;
    readonly copyFailed: string;
    readonly kinds: { readonly crash: string; readonly hang: string };
    readonly more: string;
  };
  readonly timeline: {
    readonly account_created: string;
    readonly trial_started: string;
    readonly trial_device_verified: string;
    readonly trial_ends: string;
    readonly subscription_updated: string;
    readonly subscription_past_due: string;
    readonly subscription_cancel_at: string;
    readonly subscription_period_end: string;
  };
  /** Ölçer metni: `{used}`, `{cap}`. */
  readonly ofCap: string;
  /** Kullanıcı başlığı: `{id}`. */
  readonly userTitle: string;
  /** `{count}` gösterilen satır. */
  readonly shown: string;
  /** İşletim ölçülerinin tanım ipuçları. */
  readonly opsOpenHint: string;
  readonly opsUnendedHint: string;
  /** `{expired}`, `{oldest}`. */
  readonly opsReservationsSub: string;
  readonly opsReservationsOk: string;
  /** `{stale}`. */
  readonly opsDeepgramSub: string;
  /** `{count}` son 24 saat. */
  readonly opsWebhookSub: string;
  readonly opsWebhookNever: string;
  /** `{feedback}`, `{crash}`, `{contact}`. */
  readonly opsReportsSub: string;
  /** `{objects}`, `{size}`, `{classA}`, `{classB}`: eşitlenen nesneler, boyut ve bu ayın R2 işlemleri (bütçenin yüzdesi). */
  readonly opsSyncSub: string;
  /** Huni adımlarının adları. */
  readonly funnelSteps: {
    readonly downloads: string;
    readonly accounts: string;
    readonly first_meeting: string;
    readonly first_note: string;
    readonly three_meetings: string;
    readonly subscribed: string;
    readonly canceled: string;
  };
  /** İndirme düğmelerinin adları (sunucunun `src` değerleri); bilinmeyen değer olduğu gibi gösterilir. */
  readonly downloadSources: Readonly<Record<string, string>>;
  /** Referer alan adı yok ya da okunamadı. */
  readonly referrerNone: string;
  readonly referrerOther: string;
  /** Stripe Müşteri Portalı iptal seçenekleri (`feedback`); bilinmeyen değer olduğu gibi gösterilir. */
  readonly cancellationFeedback: Readonly<Record<string, string>>;
  readonly cancellationNoFeedback: string;
  /** Stripe'ın iptal nedenleri (`reason`). */
  readonly cancellationReasons: Readonly<Record<string, string>>;
  /** Stripe nedenlerinin özet satırı: `{list}`. */
  readonly cancellationReasonsLine: string;
  /** Sorun satırları: `{code}`, `{service}`. */
  readonly problemRows: {
    readonly trialCapacity: string;
    readonly spendCeiling: string;
    readonly serverErrors: string;
    readonly refusal: string;
    readonly provider: string;
    readonly server: string;
  };
  /** Kullanıcı listesindeki sorun hücresi: `{count}` hatalı toplantı. */
  readonly failedMeetings: string;
  /** Toplantının hata hücresi: `{count}`, `{code}`. */
  readonly meetingFailure: string;
  /** Toplantı rozetleri: not tamamlandı. */
  readonly noteDone: string;
}

/** Tarayıcı metinleri. */
export const clientCopy: ClientCopy = {
  errors: {
    network: "Couldn't reach the server. Check your connection and try again.",
    rateLimited: "Too many requests. Please wait a few minutes and try again.",
    turnstile: "The security check didn't pass. Try again.",
    appleFailed: "Sign in with Apple didn't complete. Try again or continue with Google.",
    appleUnavailable: "Sign in with Apple couldn't load right now. You can continue with Google.",
    googleFailed: "Sign in with Google didn't complete. Try again or continue with Apple.",
    googleUnavailable: "Sign in with Google isn't available right now. You can continue with Apple.",
    appRequestInvalid: `This sign-in link from the app is incomplete. Start signing in again from ${productName}.`,
    appReturnInvalid: "This sign-in didn't come back as expected. Choose Apple or Google again.",
    storageUnavailable: "Your browser blocked the storage this sign-in needs. Allow site data for this page and try again.",
    upstream: "A connected service isn't responding right now. Try again shortly.",
    messageTooLong: "Your message is too long. Please shorten it to 5,000 characters.",
    complimentary: "This account has free access; there is nothing to manage.",
    appStoreSubscription:
      "You already subscribe in the iPhone app, and it works here too. Manage or cancel it on your iPhone in Settings › your name › Subscriptions.",
    generic: "Something went wrong (code: {code}). Try again.",
  },
  inviteErrors: {
    format: "That doesn't look like an invite code. Check it and try again.",
    referral_invalid: "We couldn't find that invite code. Check it and try again.",
    referral_self: "That's your own invite code; share it with a friend instead.",
    referral_not_eligible: "Invite codes are for new subscribers, so this account can't use one. You can still subscribe without it.",
    referral_unavailable: "Invite codes can't be used right now. You can still subscribe without one.",
    referral_limit_reached: "This invite code can't take new friends right now. Try again later, or subscribe without it.",
  },
  inviteChecking: "Checking the code…",
  inviteApplied: {
    monthly: "Invite applied: your first month is free.",
    yearly: "Invite applied: $5.99 off your first year.",
  },
  referralStats: {
    joined: "Joined",
    rewarded: "Rewarded",
    pending: "Pending",
    left: "Left this year",
    ofCap: "of {cap}",
  },
  referralNextReward: "Next reward around {date}",
  referralCodeAfterFirstPayment: "Your invite code appears after your first paid month.",
  referralComplimentaryNote: "Your friends still get their invite discount. Your account is already free, so the $5.99 rewards don't apply.",
  referralAppStoreNote: "Your friends still get their invite discount. Rewards are taken off web subscription payments; your subscription is billed by the App Store, so they don't apply.",
  plan: {
    trial: "Free trial",
    subscription: productName,
    monthly: `${productName} monthly`,
    yearly: `${productName} yearly`,
    complimentary: "Free access",
    none: "No active plan",
  },
  facts: {
    trialIncludes: "Includes",
    trialIncludesValue: "{total} meetings or {days} days, whichever comes first",
    trialStarts: "Starts",
    trialStartsValue: "With your first meeting",
    trialEnds: "Trial ends",
    renews: "Renews",
    renewal: "Renewal",
    renewalCancelled: "Cancelled",
    accessUntil: "Access until",
  },
  trialMeetings: "{left} of {total}",
  trialEnded: "Your free trial has ended. Subscribe to start new meetings.",
  hours: "{used} / {cap} hours",
  hoursLeft: "{left} hours left",
  hoursLimitReached: "Monthly limit reached. You can start new meetings again on {date} (UTC).",
  aiResets: "Resets on {date} (UTC)",
  aiLimitReached: "AI allowance used up. Ask, note rewriting and task tools work again on {date} (UTC). Recording and meeting notes are not affected.",
  subscriptionGraceAlert: "Payment failed. Update your card to keep access.",
  subscriptionEnded: "Your subscription has ended.",
  subscriptionPaymentOverdue: "Payment failed. Update your card in Manage subscription to keep recording.",
  subscriptionComplimentary: "Full access, free of charge. Nothing to pay or manage.",
  subscriptionComplimentaryUntil: "Full access, free of charge until {date}. Nothing to pay.",
  subscriptionComplimentaryEnded: "Your free access has ended. Subscribe to start new meetings.",
  subscriptionAppStore: "Bought in the iPhone app. Manage or cancel it on your iPhone in Settings › your name › Subscriptions.",
  deleteAppStoreWarning:
    "Deleting your account doesn't cancel your App Store subscription, and Apple keeps billing it. Cancel it first on your iPhone in Settings › your name › Subscriptions.",
  pillActive: "Active",
  pillCanceling: "Ending",
  pillGrace: "Payment due",
  pillEnded: "Ended",
  pillTrial: "Trial",
  pillComplimentary: "Free",
  working: "Working…",
  characters: "{count} / {max}",
  admin: {
    updated: "Updated {time}",
    stripeTest: "Stripe test mode",
    stripeLive: "Stripe live",
    anonymous: "Not signed in",
    noSummary: "(no summary)",
    noMessage: "(no message)",
    none: "—",
    plans: { subscription: "Subscribed", trial: "Trial", free: "No plan" },
    billingPlans: { monthly: "Monthly", yearly: "Yearly" },
    providers: { apple: "Apple", google: "Google" },
    freeAccess: {
      pill: "Free access",
      until: "Free access until {date}, not billed",
      noEnd: "Free access with no end date, not billed",
      grant: "Grant free access",
      remove: "Remove free access",
    },
    subscriptionPills: { active: "Active", ending: "Ending", grace: "Payment due", ended: "Ended" },
    trialCell: "{used} used · {left} left",
    trialNotStarted: "Not started",
    meetingKinds: { trial: "Trial", subscription: "Subscription" },
    meetingStates: { open: "Live", ended: "Ended", superseded: "Replaced", expired: "Never ended" },
    meetingNotes: { deferred: "Processed later", reprocessed: "Reprocessed ×{count}", deepgram: "Deepgram", attested: "Verified Mac" },
    minutes: "{minutes} min",
    hours: "{hours} h",
    report: {
      copyPayload: "Copy crash report",
      copyUser: "Copy user ID",
      copied: "Copied",
      copyFailed: "Couldn't copy to the clipboard.",
      kinds: { crash: "Crash", hang: "Hang" },
      more: "+{count} more",
    },
    timeline: {
      account_created: "Account created",
      trial_started: "Trial started",
      trial_device_verified: "Trial tied to a Mac",
      trial_ends: "Trial period ends",
      subscription_updated: "Subscription last updated ({detail})",
      subscription_past_due: "Payment failed",
      subscription_cancel_at: "Cancelled; access ends",
      subscription_period_end: "Current period ends ({detail})",
    },
    ofCap: "{used} of {cap}",
    userTitle: "Account {id}",
    shown: "{count} shown",
    opsOpenHint: "Started and not yet ended or timed out.",
    opsUnendedHint: "Meetings whose end the app never reported (crash, network or a closed Mac).",
    opsReservationsSub: "{expired} expired, waiting for the daily cleanup · oldest {oldest}",
    opsReservationsOk: "No expired reservations waiting",
    opsDeepgramSub: "{stale} older than the longest meeting (should have settled)",
    opsWebhookSub: "{count} events in the last 24 hours",
    opsWebhookNever: "No events stored in the last 90 days",
    opsReportsSub: "{feedback} feedback · {crash} crashes · {contact} contact",
    opsSyncSub: "{objects} encrypted objects · {size} · R2 this month: writes {classA}, reads {classB} of the free-tier cap",
    funnelSteps: {
      downloads: "Downloads",
      accounts: "Accounts created",
      first_meeting: "Started a meeting",
      first_note: "Got a finished note",
      three_meetings: "3 or more meetings",
      subscribed: "Subscribed",
      canceled: "Cancelled",
    },
    downloadSources: {
      "home-hero": "Home page, top",
      "home-cta": "Home page, bottom",
      "download-page": "Download page",
      account: "Account page",
      direct: "Direct link (no button)",
      other: "Unknown button",
    },
    referrerNone: "No referrer",
    referrerOther: "Unreadable referrer",
    cancellationFeedback: {
      too_expensive: "Too expensive",
      missing_features: "Missing features",
      switched_service: "Switched to another service",
      unused: "Not using it enough",
      too_complex: "Too complicated",
      low_quality: "Quality not good enough",
      customer_service: "Customer service",
      other: "Other",
    },
    cancellationNoFeedback: "No reason picked",
    cancellationReasons: {
      cancellation_requested: "cancelled by the customer",
      payment_failed: "payment failed",
      payment_disputed: "payment disputed",
      canceled_by_retention_policy: "retention policy",
    },
    cancellationReasonsLine: "Stripe: {list}",
    problemRows: {
      trialCapacity: "Trials refused: daily trial ceiling",
      spendCeiling: "Requests refused: daily spend ceiling",
      serverErrors: "Server errors (5xx)",
      refusal: "Refused: {code}",
      provider: "Service failed: {service}",
      server: "5xx: {code}",
    },
    failedMeetings: "{count} meetings with errors; the latest error is shown",
    meetingFailure: "{count}× {code}",
    noteDone: "Note ready",
  },
};

/** `{ad}` yer tutucularını değerlerle doldurur. Saf fonksiyondur. */
export function fill(template: string, values: Readonly<Record<string, string>>): string {
  return template.replace(/\{(\w+)\}/g, (match: string, key: string): string => values[key] ?? match);
}
