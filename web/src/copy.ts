// Sitenin sayfa metinleri (yasal metinler hariç: onlar src/pages/privacy.astro ve terms.astro içinde). Ürün adı ve
// yapan kişi tek yerden gelir (config.ts `productName`, `makerName`); işletmenin resmî bilgisi yalnızca yasal metinlerdedir.
import { cardStatementDescriptor, makerName, productName } from "./config";
import type { Brand } from "./lib/brands";
import type { IconName } from "./lib/icons";
import { interfaceLanguages, languageNameList, noteLanguages, spokenLanguages } from "./lib/languages";
import type { BillingPlan } from "./lib/plans";

/** Başlık ve açıklama (arama motorları ve paylaşım kartı). */
export interface PageMeta {
  readonly title: string;
  readonly description: string;
}

/** Soru ve yanıt. */
export interface Faq {
  readonly question: string;
  readonly answer: string;
}

/** Başlıklı kısa metin. */
export interface TitledText {
  readonly title: string;
  readonly text: string;
}

/** Simgeli, başlıklı kısa metin (kartlar). */
export interface IconText extends TitledText {
  readonly icon: IconName;
}

/** Simgeli liste öğesi. */
export interface IconItem {
  readonly icon: IconName;
  readonly text: string;
}

/** App Store rozetinin dili: Apple'ın rozeti sayfanın diliyle (`/` İngilizce, `/fi` Fince). */
export type BadgeLanguage = "en" | "fi";

/** Ortak metinler: üst çubuk, alt bilgi, fiyat. */
export interface CommonCopy {
  readonly skipLink: string;
  readonly homeLabel: string;
  readonly navLabel: string;
  readonly nav: {
    readonly features: string;
    readonly pricing: string;
    readonly download: string;
    readonly signIn: string;
    readonly account: string;
    readonly contact: string;
    readonly privacy: string;
    readonly terms: string;
    readonly compare: string;
    readonly blog: string;
    readonly mcp: string;
    readonly languages: string;
    readonly integrations: string;
    /** Sesle yazma sayfası (`/voice-typing`). */
    readonly voiceTyping: string;
    /** Gizlilik sayfasının başındaki veri işleme özeti (`/privacy#at-a-glance`). */
    readonly dataHandling: string;
  };
  readonly downloadCta: string;
  /** The header pill: the download page, which offers the Mac app and the iPhone app side by side. */
  readonly headerGetApp: string;
  /** Tema düğmesinin erişilebilir adı (basılıysa koyu tema). */
  readonly darkMode: string;
  readonly price: string;
  /** The monthly price as shown on the page in the page's language ("$5.99", "5,99 $"); `price` stays the machine form. */
  readonly priceDisplay: string;
  readonly perMonth: string;
  /** Yıllık planın fiyatı (`$49`). */
  readonly yearlyPrice: string;
  readonly offer: string;
  /** Ücretsiz denemenin koşulları (JSON-LD teklifinin açıklaması, /llms.txt). */
  readonly trial: string;
  readonly requirementsShort: string;
  /** iPhone uygulamasının gereksinimi (ör. "iOS 26.1 or later"; project.yml iOS `deploymentTarget`). */
  readonly iphoneRequirementsShort: string;
  /** Both apps' requirements, Mac first then iPhone (the home hero; each part stays on one line). */
  readonly platformsShort: readonly [string, string];
  /** App Store rozetinin dili (AppStoreBadge.astro) ve bağlantısının erişilebilir adı (rozetin yazısı). */
  readonly appStoreBadge: {
    readonly language: BadgeLanguage;
    readonly label: string;
  };
  /**
   * İndirme düğmesi bu cihazda işe yaramayacaksa açılan pencere (MacOnlyDialog.astro): telefon, tablet ya da Mac
   * olmayan bilgisayar (`notMac`), Intel Mac (`intel`) ve macOS 15'ten eski Mac (`oldMacos`; `{version}` sürümle dolar).
   */
  readonly macOnly: {
    readonly notMacTitle: string;
    readonly notMacText: string;
    /** Mac olmayan cihazda App Store rozetinin üstündeki satır (iPhone uygulaması). */
    readonly iphoneText: string;
    readonly intelTitle: string;
    readonly intelText: string;
    readonly oldMacosTitle: string;
    readonly oldMacosText: string;
    readonly copyLink: string;
    readonly copied: string;
    readonly copyFailed: string;
    readonly share: string;
    readonly email: string;
    readonly emailSubject: string;
    readonly downloadAnyway: string;
    readonly close: string;
  };
  /** Otomatik yenileme ve iptal (Abone ol düğmesinin yanında). */
  readonly renewalNote: string;
  /** Paylaşım kartı görselinin (public/og.png) metin karşılığı. */
  readonly ogImageAlt: string;
  readonly footer: {
    /** The brand line, set in the serif (sign-in page). */
    readonly tagline: string;
    /** One sentence under the logo in the footer: what the product is. */
    readonly summary: string;
    readonly product: string;
    /** Column of the comparison pages. */
    readonly compare: string;
    /** Link to the comparison index (`/compare`) in that column. */
    readonly allComparisons: string;
    readonly company: string;
    /** The account link (`/account`; it asks to sign in when there is no session). */
    readonly yourAccount: string;
    readonly privacyShort: string;
    readonly termsShort: string;
    readonly cookies: string;
    /** Who makes the product, after the copyright (config.ts `makerName`). */
    readonly madeBy: string;
    /** Link to the business's legal name, business ID and address (the terms' contact section). */
    readonly companyDetails: string;
    /** Small print before the typeface licence links. */
    readonly typefaces: string;
    /** Sayfa sonundaki çekmede görünen kısa teşekkür (PullReveal.astro). */
    readonly pullThanks: string;
    readonly copyright: string;
    /** Dil seçiminin erişilebilir adı (alt bilgi). */
    readonly language: string;
  };
  readonly lastUpdated: string;
  readonly contents: string;
}

/** Ana sayfadaki canlı ürün gösterimi (kayıt, canlı metin, kendiliğinden yazılan not). */
export interface DemoCopy {
  readonly label: string;
  readonly listening: string;
  readonly writing: string;
  readonly done: string;
  /** Sayaç dakikası; saniye CSS ile sayılır (global değil, HeroDemo). */
  readonly timerMinutes: string;
  readonly transcriptTitle: string;
  /** Not yazılmadan önce not kartında görünen satır. */
  readonly notePending: string;
  readonly transcript: readonly { readonly speaker: string; readonly text: string; readonly translation: string | null }[];
  readonly meetingTitle: string;
  readonly meetingMeta: string;
  readonly tasksTitle: string;
  readonly tasks: readonly string[];
  readonly decisionsTitle: string;
  readonly decision: string;
  /** Duraklat/oynat düğmesinin erişilebilir adları (oynarken, duraklatılmışken, gösterim bitmişken). */
  readonly pause: string;
  readonly play: string;
  readonly replay: string;
}

/** Ana sayfadaki uygulama ekran görüntülerinden biri: kartın altındaki etiket ve başlık, görselin metin karşılığı. */
export interface ShowcaseShot {
  /** Toplantının hangi anı (ör. "During the meeting"). */
  readonly label: string;
  readonly title: string;
  /** One sentence under the title. */
  readonly text: string;
  readonly alt: string;
}

/** "Son toplantılar" kartındaki örnek toplantı (MeetingCard.astro). */
export interface LibraryMeeting {
  readonly title: string;
  /** Not şablonu (toplantı adından seçilen). */
  readonly template: string;
  /** Ne zaman ve ne kadar sürdü (ör. "Yesterday · 38 min"). */
  readonly when: string;
  /** Görev ve karar sayısı (ör. "3 tasks", "2 decisions"). */
  readonly tasks: string;
  readonly decisions: string;
  /** Notun başındaki görevlerden biri. */
  readonly nextTask: string;
}

/** Ana sayfa. */
export interface HomeCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  /** Secondary action ("See pricing"); used outside the home view (WhyUs.astro). */
  readonly secondaryCta: string;
  /** Short assurances under the hero button, shown as one line with the requirements. */
  readonly assurances: readonly string[];
  /** The factual trust strip under the hero panel (one line; only true claims, no testimonials or ratings). */
  readonly proof: readonly string[];
  /** The last item of the trust strip: the listing in Claude's connector directory, linked. */
  readonly directory: { readonly text: string; readonly href: string };
  readonly demo: DemoCopy;
  /** The product film (public/video; muted, looping, plays when on screen), English only: the Finnish page leaves it out. */
  readonly launchVideo: {
    /** Heading and one line beside the film. */
    readonly title: string;
    readonly lead: string;
    /** Videonun erişilebilir adı: ekranda yazı yok, ekran okuyucular için ne gösterdiği. */
    readonly description: string;
    /** Video oynatılamazsa görünen metin ve dosya bağlantısı. */
    readonly fallback: string;
    readonly fallbackLink: string;
    /** Accessible names of the video's pause/play button (WCAG 2.2.2: it plays on its own for over five seconds). */
    readonly pause: string;
    readonly play: string;
  };
  /** Kahramanın altındaki "son toplantılar": uygulamadaki gibi gerçek bilgi taşıyan örnek toplantı kartları. */
  readonly library: {
    readonly label: string;
    readonly meetings: readonly LibraryMeeting[];
  };
  /** The features section: its two-tone heading is the brand line ("Quiet while you talk. Yours when you're done.");
   * the meeting in three rows with real screens (scripts/make-screenshots.sh), then the feature cards. */
  readonly showcase: {
    /** Muted first phrase of the heading. */
    readonly eyebrow: string;
    readonly title: string;
    /** One line under the heading: what happens during, after and later. */
    readonly lead: string;
    readonly live: ShowcaseShot;
    readonly note: ShowcaseShot;
    readonly ask: ShowcaseShot;
  };
  /** The iPhone app: in-person meetings through the microphone, Ask, tasks, and one account and subscription with the
   * Mac (optional sync). Real iPhone screens in a device frame (scripts/make-iphone-shots.ts) and the App Store badge. */
  readonly iphone: {
    /** Muted first phrase of the heading. */
    readonly eyebrow: string;
    readonly title: string;
    readonly lead: string;
    readonly points: readonly IconText[];
    /** Text equivalents of the phones (live recording, home, Ask). */
    readonly alt: { readonly live: string; readonly home: string; readonly ask: string };
  };
  /** Feature cards: one sentence each, under a pastel cover. */
  readonly features: {
    readonly missed: TitledText & { readonly button: string; readonly answer: string };
    readonly followUp: TitledText & { readonly recipe: string; readonly subject: string; readonly lines: readonly string[] };
    readonly templates: TitledText & { readonly sample: readonly string[] };
    /** Sesle yazma: kısayol etiketi ve imlecin olduğu alana yazılan örnek cümle. */
    readonly voiceTyping: TitledText & { readonly shortcut: string; readonly sample: string; readonly link: string };
    /** Paylaşılan ekranın görüntüleri: ekran adı, konuşulduğu an ve o ekrandayken söylenen cümle. */
    readonly screens: TitledText & { readonly frame: string; readonly time: string; readonly quote: string };
  };
  /** Heading of the feature cards on the night band. */
  readonly featuresTitle: string;
  /** One line under the feature cards: the other things every plan has, and a link to the full list. */
  readonly capabilities: {
    readonly title: string;
    readonly items: readonly string[];
    readonly link: string;
  };
  /** Not ekranındaki açıklama balonları (ekran görüntüsüne göre konumlar Home'da). */
  readonly noteCallouts: {
    readonly dueDate: string;
    readonly transcript: string;
  };
  /** Entegrasyonlar: notların ve görevlerin gittiği yerler, MCP ile yapay zekâ uygulamaları, dosyalar ve takvim. */
  readonly integrations: {
    readonly eyebrow: string;
    readonly title: string;
    readonly lead: string;
    readonly notes: TitledText;
    readonly tasks: TitledText;
    readonly ai: TitledText;
    /** Yapay zekâ kartından MCP sayfasına bağlantı. */
    readonly mcpLink: string;
    readonly files: TitledText;
    /** Claude'da toplantılar üstüne bir soru örneği (MCP). */
    readonly mcpDemo: {
      readonly label: string;
      readonly question: string;
      readonly tool: string;
      readonly answerLead: string;
      readonly answer: readonly string[];
      readonly source: string;
    };
  };
  /** Gizlilik ve güven ızgarası (her öğe kendi simgesiyle). */
  readonly trust: {
    readonly eyebrow: string;
    readonly title: string;
    readonly lead: string;
    readonly items: readonly IconText[];
    readonly link: string;
  };
  readonly pricingTitle: string;
  readonly pricingLead: string;
  /** The usage limits on the home price card (same as /pricing and the terms). */
  readonly pricingLimits: string;
  readonly pricingCta: string;
  /** Fiyat bandından karşılaştırma sayfasına bağlantı. */
  readonly pricingCompare: string;
  readonly faqTitle: string;
  readonly faq: readonly Faq[];
  /** Uygulamanın özellik listesi: yalnızca yapılandırılmış veride (`SoftwareApplication.featureList`). */
  readonly featureList: readonly string[];
  readonly finalTitle: string;
  readonly finalLead: string;
}

/** Fiyat sayfasında ve hesap sayfasının plan seçiminde bir plan. */
export interface PlanOptionCopy {
  readonly plan: BillingPlan;
  readonly name: string;
  readonly price: string;
  readonly per: string;
  /** Fiyatın altındaki kısa satır (ör. aylık karşılığı ve faturalama sıklığı). */
  readonly detail: string;
  /** Öne çıkan planın rozeti (ör. "Save 32%"); yoksa null. */
  readonly badge: string | null;
  /** Fiyat sayfasındaki düğme. */
  readonly cta: string;
}

/** Fiyat sayfası. */
export interface PricingCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  /** Plan kartlarının başlığı (ekran okuyucular için). */
  readonly plansTitle: string;
  readonly plans: readonly PlanOptionCopy[];
  /** Plan kartlarının altındaki not: deneme ve davet kodu ("{invite}" bağlantının yeri). */
  readonly plansNote: string;
  readonly plansInviteLink: string;
  readonly includedTitle: string;
  readonly planTagline: string;
  readonly included: readonly IconItem[];
  readonly limitsTitle: string;
  readonly limits: readonly IconText[];
  readonly faqTitle: string;
  readonly faq: readonly Faq[];
}

/** İndirme sayfası. */
export interface DownloadCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  /** Sürüm satırının etiketi (değeri sunucudan okunan numara). */
  readonly versionLabel: string;
  /** Gereksinim satırının etiketi (değeri `CommonCopy.requirementsShort`). */
  readonly requirementsLabel: string;
  /** Gereksinimin altındaki not: her şey macOS 15'te çalışır; sesle yazmanın motoru sürüme göre değişir. */
  readonly requirementsNote: string;
  /** Mac ve iPhone bloklarının başlıkları. */
  readonly macTitle: string;
  readonly iphoneTitle: string;
  /** One line on what each app is for, above its download button or badge. */
  readonly macBenefit: string;
  readonly iphoneBenefit: string;
  /** iPhone bloğunun açıklaması: ne kaydettiği, aynı hesap ve abonelik, App Store aboneliği. */
  readonly iphoneNote: string;
  /** iPhone görselinin metin karşılığı. */
  readonly iphoneAlt: string;
  /** The Mac window in the hero: its text equivalent. */
  readonly macAlt: string;
  /** Link to the latest release's notes (GitHub release page of the public releases repository). */
  readonly whatsNew: string;
  readonly installTitle: string;
  readonly installSteps: readonly TitledText[];
  /** Sayfanın sonundaki tek satır: güncellemeler ve yardım bağlantısı. */
  readonly footnote: string;
  readonly helpCta: string;
}

/** Giriş sayfası. */
export interface SignInCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly apple: string;
  /** Uygulama adına girişte Google düğmesi (yönlendirmeli; sitede Google'ın kendi düğmesi çizilir). */
  readonly google: string;
  /** "… the {Terms} and the {Privacy policy}." cümlesinin bağlantılar dışındaki parçaları. */
  readonly legalBefore: string;
  readonly legalBetween: string;
  readonly noScript: string;
  /** Mac uygulamasından açıldığında. */
  readonly appTitle: string;
  readonly appLead: string;
  readonly appReturning: string;
  readonly appReturningHelp: string;
  readonly appOpen: string;
}

/** İletişim sayfası. */
export interface ContactCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly emailLabel: string;
  readonly emailPlaceholder: string;
  readonly messageLabel: string;
  readonly messagePlaceholder: string;
  readonly turnstileLabel: string;
  readonly submit: string;
  readonly privacyNote: string;
  readonly sentTitle: string;
  readonly sentText: string;
  readonly sendAnother: string;
  readonly directTitle: string;
  readonly directText: string;
  /** Kim yapıyor kutusu: başlık, tek cümle ve işletme bilgisine (koşulların iletişim bölümü) bağlantı. */
  readonly companyTitle: string;
  readonly companyText: string;
  readonly companyLink: string;
  readonly noScript: string;
}

/** Hesap sayfası. */
export interface AccountCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly loading: string;
  /** Hesap yüklenemeyince hata bildiriminin altındaki düğme: hesabı yeniden yükler. */
  readonly retry: string;
  readonly paymentDone: string;
  /** Ödeme uygulamadan açıldıysa tarayıcıda oturum yoktur: giriş sayfası yerine bu not görünür. */
  readonly paymentDoneSignedOut: { readonly title: string; readonly text: string; readonly signIn: string };
  readonly planLabel: string;
  /** Denemede kalan toplantı ölçerinin erişilebilir adı. */
  readonly trialLabel: string;
  readonly hoursLabel: string;
  readonly hoursNote: string;
  /** Toplantı dışı yapay zekâ ölçerinin adı (uygulamalardaki ikinci ölçer). */
  readonly aiLabel: string;
  /** O ölçerden neyin düştüğü. */
  readonly aiNote: string;
  readonly subscribe: string;
  /** Abone olmadan önce plan seçimi (seçenekler `copy.pricing.plans`'tan). */
  readonly planChoiceLegend: string;
  /** Davet kodu alanı (abone ol düğmesinin üstünde, varsayılan kapalı). */
  readonly invite: {
    readonly summary: string;
    readonly label: string;
    readonly placeholder: string;
    readonly apply: string;
    readonly remove: string;
  };
  /** Abone ol düğmesinin altında: otomatik yenileme, iptal, satıcı (vergiler plan seçeneklerinde yazar). */
  readonly subscribeNote: string;
  readonly manage: string;
  /** Aboneliği yönet düğmesinin yanında (kart, iptal; makbuzlar Link'ten e-postayla, sipariş geçmişi link.com'da). */
  readonly manageNote: string;
  readonly signOut: string;
  /** Abonenin davet kartı ("bir ay ver, bir ay kazan"). */
  readonly referral: {
    readonly title: string;
    readonly text: string;
    readonly codeLabel: string;
    readonly copyLink: string;
    readonly copied: string;
    readonly howItWorks: string;
  };
  /** "Uygulamayı indir" kartı. */
  readonly appTitle: string;
  readonly appText: string;
  /** Yardım satırı. */
  readonly helpTitle: string;
  readonly helpContact: string;
  readonly dangerTitle: string;
  readonly dangerText: string;
  readonly deleteButton: string;
  readonly dialogTitle: string;
  readonly dialogText: string;
  readonly confirmWord: string;
  readonly confirmLabel: string;
  readonly cancel: string;
  readonly confirmDelete: string;
  readonly deletedTitle: string;
  readonly deletedText: string;
  readonly deletedRedirect: string;
  readonly backHome: string;
  readonly noScript: string;
}

/** Davet sayfası ("bir ay ver, bir ay kazan"). */
export interface InviteCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly stepsTitle: string;
  readonly steps: readonly IconText[];
  readonly rulesTitle: string;
  readonly rules: readonly string[];
  /** The hero's main button (to the account page, with the saved code when there is one) and where to enter a code. */
  readonly redeem: string;
  readonly redeemNote: string;
  /** Adresteki `?code=` ile gelen kodun kutusu. */
  readonly codeLabel: string;
  readonly codeNote: string;
  readonly subscribeWithCode: string;
  /** Davet edenin kendi kodu: hesap sayfası ve uygulama. */
  readonly ownCodeTitle: string;
  readonly ownCodeText: string;
  readonly ownCodeLink: string;
  readonly termsNote: string;
  readonly termsLink: string;
}

/** Yönetim panelinin kullanıcılar görünümü. */
export interface AdminUsersCopy {
  readonly title: string;
  readonly searchLabel: string;
  readonly searchPlaceholder: string;
  readonly search: string;
  readonly segmentLabel: string;
  /** Kesim seçiminin grupları: plan ve bırakma kesimleri. */
  readonly segmentGroups: { readonly plan: string; readonly dropOff: string };
  readonly segments: {
    readonly all: string;
    readonly subscribed: string;
    readonly pastDue: string;
    readonly canceled: string;
    readonly trial: string;
    readonly free: string;
    readonly noMeeting: string;
    readonly trialEnded: string;
    readonly inactive: string;
    readonly failed: string;
  };
  readonly providerLabel: string;
  readonly providers: { readonly all: string; readonly apple: string; readonly google: string };
  readonly columns: {
    readonly user: string;
    readonly provider: string;
    readonly created: string;
    readonly plan: string;
    readonly trial: string;
    readonly subscription: string;
    readonly meetings: string;
    readonly hours: string;
    readonly lastActive: string;
    readonly problems: string;
  };
  readonly empty: string;
  readonly loadMore: string;
  readonly back: string;
  readonly fields: {
    readonly provider: string;
    readonly created: string;
    readonly lastActive: string;
    readonly stripeCustomer: string;
    readonly trialDevice: string;
    readonly subscription: string;
    readonly trial: string;
    readonly cancellation: string;
  };
  readonly usageTitle: string;
  readonly usage: { readonly hours: string; readonly tokens: string; readonly accountTokens: string; readonly audio: string };
  readonly timelineTitle: string;
  readonly timelineNote: string;
  readonly meetingsTitle: string;
  readonly meetingColumns: {
    readonly started: string;
    readonly kind: string;
    readonly state: string;
    readonly duration: string;
    readonly audio: string;
    readonly tokens: string;
    readonly notes: string;
    readonly problem: string;
  };
  readonly noMeetings: string;
  readonly reportsTitle: string;
  readonly noReports: string;
}

/** Yönetim panelinin işletim görünümü. */
export interface AdminOperationsCopy {
  readonly kpis: {
    readonly open: string;
    readonly unended: string;
    readonly reservations: string;
    readonly deepgram: string;
    readonly webhook: string;
    readonly reports: string;
    readonly sync: string;
    readonly shares: string;
  };
  readonly openTitle: string;
  readonly openColumns: { readonly user: string; readonly kind: string; readonly started: string; readonly endsBy: string; readonly notes: string };
  readonly noOpen: string;
  readonly stripeTitle: string;
  readonly stripeColumns: { readonly type: string; readonly count: string };
  readonly noStripe: string;
  readonly crashesTitle: string;
  readonly noCrashes: string;
}

/** Yönetim panelinin içgörüler görünümü (sorunlar, huni, indirme kaynakları, iptal nedenleri). */
export interface AdminInsightsCopy {
  readonly problemsTitle: string;
  readonly problemsColumns: { readonly problem: string; readonly last7: string; readonly last30: string };
  readonly noProblems: string;
  readonly funnelTitle: string;
  readonly funnelColumns: { readonly step: string; readonly count: string; readonly fromPrevious: string; readonly lost: string };
  readonly funnelNote: string;
  readonly sourcesTitle: string;
  readonly sourceColumns: { readonly source: string; readonly count: string };
  readonly referrersTitle: string;
  readonly referrerColumns: { readonly host: string; readonly count: string };
  readonly noDownloads: string;
  readonly downloadsNote: string;
  readonly cancellationsTitle: string;
  readonly cancellationColumns: { readonly reason: string; readonly count: string };
  readonly noCancellations: string;
  readonly recentCancellationsTitle: string;
}

/** Yönetim panelinin durgun metinleri (değerlere bağlı olanlar client/copy.ts'te). */
export interface AdminCopy {
  /** Nötr başlık ve açıklama: yönetici erişimi doğrulanmadan panelin varlığı belli olmaz. */
  readonly meta: PageMeta;
  /** Erişim doğrulanınca sekme başlığı. */
  readonly documentTitle: string;
  /** Sol menüde ürün adının yanındaki rozet. */
  readonly title: string;
  /** Sol menüden siteye dönüş bağlantısı. */
  readonly backToSite: string;
  readonly refresh: string;
  /** Nötr yükleme satırı. */
  readonly loading: string;
  readonly users: AdminUsersCopy;
  readonly operations: AdminOperationsCopy;
  readonly insights: AdminInsightsCopy;
  readonly inboxTitle: string;
  readonly tabs: { readonly feedback: string; readonly crash: string; readonly contact: string };
  readonly statusOpen: string;
  readonly statusDone: string;
  readonly empty: string;
  readonly loadMore: string;
  readonly detailEmpty: string;
  readonly fields: {
    readonly received: string;
    readonly email: string;
    readonly user: string;
    readonly app: string;
    readonly os: string;
  };
  readonly messageTitle: string;
  readonly payloadTitle: string;
  /** Filter button: only feedback whose sender allowed quoting it on the site. */
  readonly quotableFilter: string;
  /** Heading of the quote consent block in a report. */
  readonly quoteTitle: string;
  /** Line before the first name: the sender allowed quoting with this name (`{name}`). */
  readonly quoteConsent: string;
  readonly markDone: string;
  readonly reopen: string;
}

/** Karşılaştırma tablosunun satırları (konular). */
export type ComparisonTopic =
  | "price"
  | "free"
  | "capture"
  | "platforms"
  | "limits"
  | "languages"
  | "translation"
  | "notes"
  | "ask"
  | "voiceTyping"
  | "screens"
  | "integrations"
  | "mcp"
  | "storage"
  | "plans";

/** Topics of the short overview table on /compare (each cell a few words; the detail is on the /vs pages). */
export type OverviewTopic = "price" | "free" | "capture" | "platforms" | "languages" | "translation";

/**
 * A cell's yes/no mark next to its text: the feature is there (`yes`), there in part (`partial`, e.g. a bot by default
 * with a bot-free app) or not offered (`no`, only when the vendor says so). Topics without a mark show text only.
 */
export type CellMark = "yes" | "partial" | "no";

/** Marks of one product's cells, by topic. */
export type CellMarks = Readonly<Partial<Record<ComparisonTopic, CellMark>>>;

/** Karşılaştırılan ürünler. */
export type Competitor = "granola" | "otter" | "fireflies" | "poffle";

/** "Kim hangisini seçmeli" kutusu: başlık ve maddeler. */
export interface PickCopy {
  readonly title: string;
  readonly points: readonly string[];
}

/**
 * Bir rakiple karşılaştırma sayfası. Rakibin değerleri yalnızca kendi fiyat sayfasında doğrulanmış gerçeklerdir; o
 * konuda doğrulanmış bilgi yoksa değer `null` olur ve tabloda tire görünür (özelliğin olmadığı anlamına gelmez).
 */
export interface CompetitorCopy {
  readonly meta: PageMeta;
  readonly name: string;
  readonly title: string;
  readonly lead: string;
  /** Karşılaştırma dizinindeki kartın kısa özeti. */
  readonly summary: string;
  readonly pricingUrl: string;
  readonly values: Readonly<Record<ComparisonTopic, string | null>>;
  readonly marks: CellMarks;
  /** The overview table's short cells (/compare); null when not checked. */
  readonly glance: Readonly<Record<OverviewTopic, string | null>>;
  /** The competitor's headline differences, a few words each (the summary card at the top of its /vs page). */
  readonly edge: readonly string[];
  /** Rakibin daha güçlü olduğu yerler (adil karşılaştırma; sayfada bizim güçlü yanlarımızdan sonra, kısa liste). */
  readonly strengthsTitle: string;
  readonly strengths: readonly string[];
  readonly pickCompetitor: PickCopy;
  readonly pickUs: PickCopy;
}

/** Karşılaştırma sayfalarının ortak metinleri ve dizin sayfası. */
export interface CompareCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  /** Dizindeki özet tablonun konuları. */
  readonly overviewTopics: readonly OverviewTopic[];
  readonly overviewTitle: string;
  readonly topics: Readonly<Record<ComparisonTopic, string>>;
  /** Bizim değerlerimiz (copy.ts, fiyat sayfası ve sunucu sınırlarıyla aynı). */
  readonly us: Readonly<Record<ComparisonTopic, string>>;
  readonly usMarks: CellMarks;
  /** Our short cells in the overview table. */
  readonly usGlance: Readonly<Record<OverviewTopic, string>>;
  /** The summary card at the top of the comparison pages: our headline points, a few words each. */
  readonly highlights: readonly string[];
  /** Screen-reader words for the cell marks. */
  readonly markLabels: Readonly<Record<CellMark, string>>;
  /**
   * Karşılaştırma sayfalarının başındaki vurgulu özet: ürünü seçmek için başlıca nedenler (her sayfada aynı, rakip
   * değerlerinden bağımsız ürün gerçekleri).
   */
  readonly why: {
    readonly title: string;
    readonly items: readonly IconText[];
  };
  /** Tablodaki bizim sütunun başlığının yanındaki etiket. */
  readonly usBadge: string;
  readonly topicColumn: string;
  readonly tableTitle: string;
  readonly checked: string;
  readonly source: string;
  readonly missingNote: string;
  /** Tirenin ekran okuyucudaki karşılığı. */
  readonly notChecked: string;
  readonly pickTitle: string;
  readonly readComparison: string;
  readonly trademarks: string;
  readonly ctaTitle: string;
  readonly ctaText: string;
  readonly competitors: Readonly<Record<Competitor, CompetitorCopy>>;
}

/** Blog dizini, yazı sayfası ve RSS akışı. */
export interface BlogCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly feedTitle: string;
  readonly feedLink: string;
  /** Label above the newest post at the top of the index. */
  readonly latest: string;
  /** Heading of the list of every other post. */
  readonly allTitle: string;
  readonly byline: string;
  /** "6 min read" gibi okuma süresinin eki. */
  readonly minutesRead: string;
  readonly backToBlog: string;
  /** Yazının `updated` günü varsa tarihin önündeki etiket. */
  readonly updated: string;
  /** Yazı sonundaki ilgili yazılar bölümünün başlığı. */
  readonly moreTitle: string;
  /** Yazının paylaşım görselinin alternatif metni; `{title}` yazının başlığı. */
  readonly coverAlt: string;
  readonly ctaTitle: string;
  readonly ctaText: string;
}

/** MCP aracının açıklaması (MCPServer.swift `mcpTools` ile aynı araçlar). */
export interface McpToolCopy {
  readonly name: string;
  readonly text: string;
  /** Girdileri (yoksa "No input"). */
  readonly input: string;
}

/** MCP istemcisinin yapılandırma dosyası (MCPClients.swift `configRelativePath`). */
export interface McpClientFileCopy {
  readonly client: string;
  readonly file: string;
}

/**
 * Uzak MCP bağlayıcısı (yapay zekâ asistanı erişimi: server/src/mcp/, uygulamada Ayarlar › Bağlantılar; varsayılan
 * kapalı). Onay cümlesi ve uyarılar docs/superpowers/specs/2026-11-05-remote-mcp.md "Copy and legal"le aynıdır.
 */
export interface McpRemoteCopy {
  readonly title: string;
  readonly lead: string;
  /** Spesifikasyonun zorunlu onay cümlesi. */
  readonly consent: string;
  readonly toolsTitle: string;
  readonly tools: readonly McpToolCopy[];
  readonly urlLabel: string;
  readonly url: string;
  readonly setups: readonly PickCopy[];
  readonly notes: readonly TitledText[];
}

/** MCP sayfası. */
export interface McpCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  /** Hero link to the local server section (the online connector comes first): text before the link and the link. */
  readonly localHint: { readonly text: string; readonly link: string };
  /** Title of the local server section (Claude Desktop, Cursor, VS Code on the Mac). */
  readonly localTitle: string;
  /** Copy buttons on the code blocks and the connector URL: label, success and failure. */
  readonly copyButton: { readonly label: string; readonly copied: string; readonly failed: string };
  readonly toolsTitle: string;
  readonly toolsLead: string;
  readonly toolInputLabel: string;
  readonly tools: readonly McpToolCopy[];
  readonly setupTitle: string;
  readonly setupLead: string;
  readonly oneClick: PickCopy;
  readonly manual: PickCopy;
  readonly configLabel: string;
  readonly configNote: string;
  readonly filesTitle: string;
  readonly fileColumns: { readonly client: string; readonly file: string };
  readonly files: readonly McpClientFileCopy[];
  readonly filesNote: string;
  readonly questionsTitle: string;
  readonly questionsLead: string;
  readonly questions: readonly string[];
  readonly privacyTitle: string;
  readonly privacy: readonly TitledText[];
  readonly remote: McpRemoteCopy;
}

/** Sayıyla öne çıkan kısa bilgi (ör. "35" + "spoken languages"). */
export interface StatCopy {
  readonly value: string;
  readonly label: string;
}

/** Diller sayfası (/languages): listeler lib/languages.ts'ten, sayılar listelerden. */
export interface LanguagesCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly stats: readonly StatCopy[];
  readonly spokenTitle: string;
  readonly spokenLead: string;
  readonly notesTitle: string;
  readonly notesLead: string;
  /** Uygulamanın kendi arayüzünün dilleri (konuşulan ve not dillerinden ayrı). */
  readonly interfaceTitle: string;
  readonly interfaceLead: string;
  /** Öne çıkan diller (Türkçe, Fince). */
  readonly highlightsTitle: string;
  readonly highlights: readonly TitledText[];
  /** Birden çok dilin konuşulduğu toplantılar. */
  readonly mixedTitle: string;
  readonly mixed: readonly TitledText[];
  readonly faqTitle: string;
  readonly faq: readonly Faq[];
}

/** Entegrasyonun bir öğesi: adı ve ne yaptığı. */
/** Entegrasyon kartının simgesi: ana sayfadaki kayan şeritteki marka karoları ya da markası olmayanlarda genel simge. */
export type IntegrationMark =
  | { readonly kind: "brands"; readonly brands: readonly Brand[] }
  | { readonly kind: "icon"; readonly icon: IconName };

export interface IntegrationItemCopy {
  readonly name: string;
  readonly text: string;
  readonly mark: IntegrationMark;
}

/** Entegrasyon grubu (sayfada çapalı bölüm: `#<id>`). */
export interface IntegrationGroupCopy {
  readonly id: string;
  readonly title: string;
  readonly lead: string;
  readonly items: readonly IntegrationItemCopy[];
}

/** Entegrasyonlar sayfası (/integrations). */
export interface IntegrationsCopy {
  readonly meta: PageMeta;
  readonly eyebrow: string;
  readonly title: string;
  readonly lead: string;
  readonly groups: readonly IntegrationGroupCopy[];
  /** Webhook'un gönderdiği JSON'un örneği (Webhook.swift `WebhookPayload` ile aynı alanlar). */
  readonly webhookExampleLabel: string;
  readonly webhookExample: string;
  readonly mcpLink: string;
  /** Yerleşik olmayanlar (dürüst liste). */
  readonly notBuiltInTitle: string;
  readonly notBuiltIn: readonly string[];
  readonly privacyTitle: string;
  readonly privacyText: string;
  readonly faqTitle: string;
  readonly faq: readonly Faq[];
}

/** 404 sayfası. */
/** Sesle yazma sayfasının üst gösterimi (VoiceTypingDemo.astro): e-posta taslağına dikte edilen yanıt. */
export interface VoiceTypingDemoCopy {
  /** Gösterimin erişilebilir anlatımı (gösterim `role="img"`). */
  readonly label: string;
  readonly windowTitle: string;
  readonly toLabel: string;
  readonly to: string;
  readonly subjectLabel: string;
  readonly subject: string;
  /** Taslakta zaten yazılı olan ilk satır. */
  readonly greeting: string;
  /** Söylenen ve kısayol bırakılınca imlecin yerine yazılan metin; dinlerken haptaki ara metin de bundan. */
  readonly dictated: string;
  readonly listening: string;
  /** Kısayol (uygulamanın varsayılanı: KeyBinding.swift `defaultDictateBinding`). */
  readonly shortcut: string;
  readonly pause: string;
  readonly play: string;
  readonly replay: string;
}

/** Hız karşılaştırması: aynı paragraf konuşarak ve yazarak (tipik hızlarla, ölçüm değil). */
export interface SpeedRaceCopy {
  readonly tone: string;
  readonly title: string;
  readonly lead: string;
  /** Yarışılan paragraf (kelime sayısı süreleri belirler: voice-typing.astro). */
  readonly passage: string;
  readonly voiceLabel: string;
  readonly typingLabel: string;
  /** Tipik konuşma ve klavyeyle yazma hızı (dakikada kelime; yaygın ortalamalar, ölçüm değil). */
  readonly voiceWpm: number;
  readonly typingWpm: number;
  /** Dakikada kelime birimi. */
  readonly perMinute: string;
  /** Hızlandırma notu (`{speed}` hızla dolar). */
  readonly replayNote: string;
  readonly note: string;
  readonly pause: string;
  readonly play: string;
  readonly replay: string;
}

/** Bir kullanım örneği: uygulama türü, örnek pencere ve dikte edilen metin. */
export interface VoiceUseCaseCopy {
  readonly kind: "email" | "chat" | "prompt" | "doc";
  readonly label: string;
  readonly title: string;
  readonly text: string;
  /** Pencere başlığı (genel; marka yok). */
  readonly window: string;
  /** Pencerede zaten olan içerik (alıcı ve konu, önceki mesaj, belge başlığı…). */
  readonly context: readonly string[];
  readonly dictated: string;
}

/** Sesle yazma sayfası (`/voice-typing`). Her bilgi uygulamanın kodunda doğrulandı (copy nesnesindeki açıklamaya bak). */
export interface VoiceTypingCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly lead: string;
  readonly assurances: readonly string[];
  readonly demo: VoiceTypingDemoCopy;
  readonly speed: SpeedRaceCopy;
  readonly free: {
    readonly title: string;
    readonly text: string;
    readonly points: readonly string[];
  };
  readonly useCasesTone: string;
  readonly useCasesTitle: string;
  readonly useCases: readonly VoiceUseCaseCopy[];
  readonly howTone: string;
  readonly howTitle: string;
  readonly modes: readonly (TitledText & { readonly keys: string })[];
  readonly details: readonly IconText[];
  readonly privacyTone: string;
  readonly privacyTitle: string;
  readonly privacyLead: string;
  readonly privacyPoints: readonly IconText[];
  readonly privacyLink: string;
  readonly languagesTitle: string;
  readonly languagesText: string;
  readonly languagesLink: string;
  readonly faqTitle: string;
  readonly faq: readonly Faq[];
  readonly ctaTitle: string;
  readonly ctaText: string;
}

export interface NotFoundCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly text: string;
  readonly home: string;
  /** Accessible name of the row of other pages (pricing, download, blog, contact) under the button. */
  readonly linksLabel: string;
}

/** Bağlantıyla paylaşılan not sayfası (`/s`). Notun kendi metinleri (başlıklar dahil) gönderenin dilindedir. */
/** Asistanın verdiği toplantı bağlantısının (`/m/<kimlik>`) sayfası. */
export interface MeetingLinkCopy {
  readonly meta: PageMeta;
  readonly title: string;
  readonly text: string;
  /** Uygulamada toplantıyı açan düğme (`gistsmith://meeting/<kimlik>`). */
  readonly openButton: string;
  /** Düğmenin altında: uygulama bu cihazda yoksa ne yapılacağı. */
  readonly openHint: string;
  /** Adımların başlığı (düğme işe yaramazsa toplantıyı elle bulmak). */
  readonly stepsTitle: string;
  readonly steps: readonly string[];
  readonly ctaTitle: string;
  readonly ctaText: string;
}

export interface ShareCopy {
  readonly meta: PageMeta;
  readonly loading: string;
  /** Notun üstündeki gizlilik satırı. */
  readonly privacyLine: string;
  readonly showTranscript: string;
  readonly errors: {
    readonly incompleteTitle: string;
    readonly incomplete: string;
    readonly goneTitle: string;
    readonly gone: string;
    readonly wrongKeyTitle: string;
    readonly wrongKey: string;
    readonly unreadableTitle: string;
    readonly unreadable: string;
    readonly networkTitle: string;
    readonly network: string;
    readonly rateLimited: string;
    readonly retry: string;
  };
  /** Notun altındaki satır: kimin paylaştığı ve kötüye kullanım bildirimi ("{report}" bağlantının yeri). */
  readonly ownerLine: string;
  readonly report: string;
  readonly madeWith: string;
  readonly madeWithLead: string;
}

/** Sitenin tüm metinleri. */
export interface Copy {
  readonly common: CommonCopy;
  readonly home: HomeCopy;
  readonly pricing: PricingCopy;
  readonly download: DownloadCopy;
  readonly compare: CompareCopy;
  readonly blog: BlogCopy;
  readonly mcp: McpCopy;
  readonly signIn: SignInCopy;
  readonly contact: ContactCopy;
  readonly account: AccountCopy;
  readonly invite: InviteCopy;
  readonly admin: AdminCopy;
  readonly languages: LanguagesCopy;
  readonly integrations: IntegrationsCopy;
  readonly voiceTyping: VoiceTypingCopy;
  readonly notFound: NotFoundCopy;
  readonly meetingLink: MeetingLinkCopy;
  readonly share: ShareCopy;
  readonly privacyMeta: PageMeta;
  readonly termsMeta: PageMeta;
}

const tagline: string = "Listens to your meetings, writes your notes.";
/** The brand line, in two halves: the home features heading sets the first half muted (two-tone). */
const brandQuiet: string = "Quiet while you talk";
const brandYours: string = "Yours when you're done.";
const brandLine: string = `${brandQuiet}. ${brandYours}`;
/** Commonly cited averages (words a minute) for conversational speech and keyboard typing; the voice typing page says so. */
const typicalSpeakingWpm: number = 150;
const typicalTypingWpm: number = 40;

/** Sitenin metinleri. */
export const copy: Copy = {
  common: {
    skipLink: "Skip to content",
    homeLabel: `${productName} home`,
    navLabel: "Main menu",
    nav: {
      features: "Features",
      pricing: "Pricing",
      download: "Download",
      signIn: "Sign in",
      account: "Account",
      contact: "Contact",
      privacy: "Privacy policy",
      terms: "Terms of service",
      compare: "Compare",
      blog: "Blog",
      mcp: "MCP for AI apps",
      languages: "Languages",
      integrations: "Integrations",
      voiceTyping: "Voice typing",
      dataHandling: "Data handling",
    },
    downloadCta: "Download for Mac",
    headerGetApp: "Get the app",
    darkMode: "Dark mode",
    price: "$5.99",
    priceDisplay: "$5.99",
    perMonth: "/ month",
    yearlyPrice: "$49",
    offer: "3 meetings or 7 days free, then $5.99 a month or $49 a year, taxes included",
    trial: "Free trial: 3 meetings or 7 days from your first meeting, whichever comes first, each up to 90 minutes; no card needed",
    requirementsShort: "macOS 15 or later · Apple silicon",
    iphoneRequirementsShort: "iOS 26.1 or later",
    platformsShort: ["Mac: macOS 15 or later, Apple silicon", "iPhone: iOS 26.1 or later"],
    appStoreBadge: { language: "en", label: "Download on the App Store" },
    macOnly: {
      notMacTitle: "Download the Mac app on your Mac",
      notMacText: "The Mac app runs on Macs with Apple silicon and macOS 15 or later. Send yourself the link and download it on your Mac.",
      iphoneText: `On an iPhone, get ${productName} from the App Store.`,
      intelTitle: "This Mac has an Intel processor",
      intelText: `${productName} needs a Mac with Apple silicon (M1 or later), so it won't open on this Mac.`,
      oldMacosTitle: `${productName} needs macOS 15 or later`,
      oldMacosText: `This Mac runs macOS {version}. Update it in System Settings › General › Software Update, then download ${productName}.`,
      copyLink: "Copy link",
      copied: "Link copied",
      copyFailed: "Couldn't copy. The link is gistsmith.com/download",
      share: "Share link",
      email: "Email it to me",
      emailSubject: `${productName} for Mac`,
      downloadAnyway: "Download anyway",
      close: "Close",
    },
    renewalNote: "Renews automatically every month or year, depending on your plan, until you cancel. Cancel anytime.",
    ogImageAlt: `The ${productName} logo and the tagline “${tagline}” on a soft pastel gradient, above a small sound wave.`,
    footer: {
      tagline: brandLine,
      summary: "AI meeting notes for Mac and iPhone, with live translation and your own tasks picked out.",
      product: "Product",
      compare: "Compare",
      allComparisons: "All comparisons",
      company: "Company",
      yourAccount: "Your account",
      privacyShort: "Privacy",
      termsShort: "Terms",
      cookies: "Cookies",
      madeBy: `Made by ${makerName}`,
      companyDetails: "Company details",
      typefaces: "Typefaces:",
      pullThanks: "Thanks for listening.",
      copyright: `© 2026 ${productName}`,
      language: "Language",
    },
    lastUpdated: "Last updated",
    contents: "On this page",
  },
  home: {
    meta: {
      title: `${productName}: AI meeting notes for Mac and iPhone, with live translation`,
      description: `AI meeting notes for Mac and iPhone: a live transcript, translation into ${noteLanguages.length} languages and your tasks picked out. No bot joins the call.`,
    },
    eyebrow: "AI meeting notes for Mac and iPhone",
    title: tagline,
    lead: `AI meeting notes for Mac and iPhone, with live translation in ${noteLanguages.length} languages and your own tasks picked out. No bot joins the call.`,
    secondaryCta: "See pricing",
    assurances: ["3 meetings or 7 days free", "No credit card"],
    proof: ["Mac app notarized by Apple", "iPhone app on the App Store"],
    directory: { text: "Listed in Claude's connector directory", href: "https://claude.ai/directory/connectors/gistsmith" },
    demo: {
      label: `${productName} recording a meeting and writing the note`,
      listening: "Listening",
      writing: "Writing your note",
      done: "Note ready",
      timerMinutes: "42",
      transcriptTitle: "Live transcript",
      notePending: "Your note appears here when the meeting ends.",
      transcript: [
        { speaker: "Elif", text: "Let's open the beta on 14 November.", translation: null },
        { speaker: "You", text: "Works for me. I'll write the release notes by Friday.", translation: null },
        { speaker: "Mikko", text: "Voitko lähettää hinnaston Ayşelle?", translation: "Could you send Ayşe the pricing table?" },
      ],
      meetingTitle: "Product weekly",
      meetingMeta: "Today · 42 min · 4 people",
      tasksTitle: "Your tasks",
      tasks: ["Write the beta release notes by Friday", "Send Ayşe the pricing table", "Set up Wednesday's call with support"],
      decisionsTitle: "Decisions",
      decision: "The beta opens on 14 November.",
      pause: "Pause the demo",
      play: "Play the demo",
      replay: "Replay the demo",
    },
    launchVideo: {
      title: `${productName} in 40 seconds.`,
      lead: "From the first word of the call to the note in your inbox: the live transcript and translation, your tasks, and answers from every meeting.",
      description: `A 37-second film about ${productName}: the questions a meeting leaves behind, the live transcript and translation during the call, the note with your tasks when you hang up, and asking across all your meetings.`,
      fallback: "Your browser can't play this video here.",
      fallbackLink: "Open the video file",
      pause: "Pause the video",
      play: "Play the video",
    },
    library: {
      label: "Recent meetings",
      meetings: [
        { title: "Stand-up · Web team", template: "Daily stand-up", when: "Today · 15 min", tasks: "4 tasks", decisions: "1 decision", nextTask: "Unblock the pricing page review" },
        { title: "Client call · Nordia", template: "Client call", when: "Yesterday · 38 min", tasks: "3 tasks", decisions: "2 decisions", nextTask: "Send the revised quote by Friday" },
        { title: "Sprint 42 planning", template: "Sprint planning", when: "Monday · 55 min", tasks: "5 tasks", decisions: "3 decisions", nextTask: "Fix the export bug before the release" },
        { title: "One-on-one: Elif", template: "One-on-one", when: "Last week · 30 min", tasks: "2 tasks", decisions: "1 decision", nextTask: "Share feedback on the onboarding flow" },
      ],
    },
    showcase: {
      eyebrow: brandQuiet,
      title: brandYours,
      lead: "A live transcript while people talk, a note with the summary and your tasks when the call ends, and answers from all your meetings whenever you need them.",
      live: {
        label: "Live translation",
        title: "Read along in your language",
        text: "Each sentence is on screen within seconds, with a translation into your language when the meeting is in another one.",
        alt: `The ${productName} live panel while recording a Finnish meeting: each speaker's Finnish sentences with the English translation underneath, your own lines in English, and a “What did I miss?” button at the bottom.`,
      },
      note: {
        label: "After the meeting",
        title: "Ready when you hang up",
        text: "A short summary, then your own tasks with due dates, everyone else's with owners, the decisions and a glossary.",
        alt: `The Product weekly note in the ${productName} app: the date, 42 minutes, 4 speakers and “3 tasks for you” at the top, a three-point summary, and your three tasks with due dates: write the beta release notes by Friday, send Ayşe the latest pricing table today, set up a weekly Wednesday call with support.`,
      },
      ask: {
        label: "Ask",
        title: "Answers from every meeting, with sources",
        text: "Ask across all your meetings and get an answer that links back to the meeting it came from.",
        alt: `The Ask page in ${productName}: the question “What did we decide about the budget?” answered in two bullet points with numbered citations, and a Sources button showing 3 sources.`,
      },
    },
    iphone: {
      eyebrow: "On iPhone",
      title: "Meetings in the room, too.",
      lead: "Put your iPhone on the table and tap record: it hears everyone in the room, and your note is ready when the meeting ends. Online meetings are recorded on the Mac.",
      points: [
        { icon: "mic", title: "In-person meetings", text: "It listens through your iPhone's microphone, with a live transcript and translation as people talk." },
        { icon: "search", title: "Ask your meetings", text: "Ask in plain words and get an answer that cites the meeting it came from." },
        {
          icon: "phone",
          title: "Notes from phone calls",
          text: "Coming in the next iPhone update: record the call with iPhone's built-in call recording, share the audio to Gistsmith, and get the note, decisions and tasks. Where call recording isn't available, take the call on your Mac.",
        },
        { icon: "check-circle", title: "Your tasks in one list", text: "The tasks from every meeting, with their due dates, in one place." },
        {
          icon: "refresh",
          title: "One account for Mac and iPhone",
          text: "Sign in with the same account and one subscription covers both. Turn on sync to see your notes on both, encrypted end to end.",
        },
      ],
      alt: {
        live: `${productName} on iPhone recording a Finnish meeting: a 12:43 timer, a sound wave and each speaker's Finnish sentences with the English translation underneath, and a Finish button at the bottom.`,
        home: `The ${productName} home screen on iPhone: today's upcoming meetings with Briefing and Join buttons, 8 open tasks, recent notes and an Ask a question button next to the record button.`,
        ask: `Ask in ${productName} on iPhone: the question “What did we decide about the budget?” answered in two points with numbered citations to the meetings.`,
      },
    },
    features: {
      missed: {
        title: "Catch up without interrupting",
        text: "“What did I miss?” sums up the last few minutes in one click, so nobody has to repeat themselves.",
        button: "What did I miss?",
        answer: "In the last 5 minutes: the beta moved to 14 November, and the release notes are yours.",
      },
      followUp: {
        title: "The follow-up email, already drafted",
        text: "One click drafts the follow-up from the note, with decisions and owners, ready to edit or open in Mail.",
        recipe: "Follow-up email",
        subject: "Subject: Product weekly, next steps",
        lines: ["Beta opens on 14 November.", "Release notes: me, by Friday."],
      },
      templates: {
        title: "The right note for every meeting",
        text: "Client calls, one-on-ones, stand-ups and interviews each get a note that puts the right things first, or write your own.",
        sample: ["Client call", "One-on-one", "Stand-up", "Sprint planning", "Interview", "Lecture", "Your own"],
      },
      voiceTyping: {
        title: "Type with your voice, in any app",
        text: "Hold the shortcut and speak to type wherever your cursor is, transcribed on your Mac and free with any account.",
        shortcut: "Hold ⌃⌥D",
        sample: "Thanks, I'll send the pricing table by Friday.",
        link: "More about voice typing",
      },
      screens: {
        title: "Feedback pinned to the right slide",
        text: "In online calls, snapshots of the shared screen are matched to what was said, so each comment lands on the right slide.",
        frame: "Pricing page",
        time: "12:40",
        quote: "The yearly toggle is hard to spot.",
      },
    },
    featuresTitle: "The details, handled before you ask.",
    capabilities: {
      title: "Also included",
      items: [
        "any call app",
        "stops when the call ends",
        "speaker names",
        "open tasks carried forward",
        `${spokenLanguages.length} spoken languages`,
        "in-person meetings and imported files",
      ],
      link: "Everything in the plan",
    },
    trust: {
      eyebrow: "Privacy",
      title: "Your meetings stay yours.",
      lead: "Built for conversations you'd rather keep private.",
      items: [
        {
          icon: "laptop",
          title: "Stored on your devices",
          text: "Notes, transcripts and recordings live on your Mac and iPhone. Our servers don't store your audio, or notes we can read unless you turn on AI assistant access.",
        },
        { icon: "sparkle", title: "Not used to train AI", text: "Your meetings aren't used to train our providers' models. We've opted out wherever that's a setting." },
        { icon: "lock", title: "Encrypted sync", text: "Optional sync between your Mac and iPhone is encrypted end to end: our server keeps only a copy it can't read." },
        { icon: "check-circle", title: "Delete any time", text: "Delete your account in the app or on the website at any time; a web or Mac subscription ends with it." },
      ],
      link: "Read the privacy policy",
    },
    noteCallouts: {
      dueDate: "Owner and due date",
      transcript: "Full transcript, by speaker",
    },
    integrations: {
      eyebrow: "Integrations",
      title: "Your meetings, where your work happens.",
      lead: "Send the note where your team works, put tasks in your tracker, and let your AI apps read your meetings.",
      notes: {
        title: "Notes to your team",
        text: "Send the note to Notion, Apple Notes, Slack, Microsoft Teams, Discord or Zoom Team Chat, or anywhere else through a webhook.",
      },
      tasks: {
        title: "Tasks to your tracker",
        text: "Turn your tasks into Linear or Jira issues, or into Apple Reminders.",
      },
      ai: {
        title: "Your AI apps, through MCP",
        text: "Claude, ChatGPT, Cursor and VS Code can search and read your meetings (on your Mac, or online with AI assistant access); they can never change them.",
      },
      mcpLink: "How MCP works",
      files: {
        title: "Your files and calendar",
        text: "Save notes as Markdown to a folder such as your Obsidian vault, export PDF, Word or subtitles, and let your calendar start the recording.",
      },
      mcpDemo: {
        label: "In Claude",
        question: "What did I promise Nordia last week?",
        tool: "Searched your meetings",
        answerLead: "In the client call on 27 October you said you'd:",
        answer: ["Send the revised quote by Friday", "Share the onboarding checklist"],
        source: "Client call · Nordia",
      },
    },
    pricingTitle: "Simple pricing, monthly or yearly.",
    pricingLead: "One plan with everything in it. Try it on your own meetings before you pay.",
    pricingLimits: "Up to 10 meeting hours a month and 4 hours per meeting. Voice typing runs on your Mac and doesn't count.",
    pricingCta: "Pricing details",
    pricingCompare: "Compare with Granola, Otter, Fireflies and Poffle",
    faqTitle: "Questions",
    faq: [
      {
        question: "How does the free trial work?",
        answer: "The trial is free and needs no card: 3 meetings or 7 days from your first meeting, whichever comes first. Meetings you haven't used by then expire. Trial meetings can be up to 90 minutes long. After that, the subscription is $5.99 a month or $49 a year, taxes included.",
      },
      {
        question: "Does a bot join my meetings?",
        answer: `No. ${productName} listens to your Mac's audio and microphone; participants never see a bot. It reminds you to tell participants before you start recording.`,
      },
      {
        question: "Where does my audio go?",
        answer:
          "While you record, the audio streams from your Mac or iPhone to our live speech-recognition provider for the live transcript; it is asked not to keep it or use it for training. If that isn't available, the live transcript is produced on your device instead (on iPhone this needs iOS 26 or later; on earlier versions the transcript is made after the meeting). When the meeting ends, the audio is passed through our server to our transcription provider to separate speakers and produce the final transcript; for notes and translation the text goes to our AI model provider. Our servers don't store audio, or notes they can read unless you turn on AI assistant access (sync and share links keep only end-to-end encrypted copies); they count the duration and hold the final transcript encrypted, only so it can be re-sent for 2 hours if the connection drops; it is deleted at the next daily cleanup, within about a day. The transcription and AI model providers may keep what they process for a time under their own retention rules (the AI model provider deletes it within 30 days). If you turn on “Use screen snapshots in notes”, up to six of the meeting's screen snapshots go to the AI model provider along with the transcript when the note is written, and up to three with an Ask question about that part of the meeting; otherwise snapshots never leave your Mac. Photos you add to a meeting on iPhone work the same way with “Use photos in notes”. The privacy policy names each provider and has the details.",
      },
      {
        question: "Which languages are supported?",
        answer: `You can speak in ${spokenLanguages.length} languages, including English, Finnish and Turkish, and get notes and live translations in ${noteLanguages.length}. You choose the language of your notes and translations, whatever language was spoken. The app itself is available in ${interfaceLanguages.length} languages: ${languageNameList(interfaceLanguages)}. It follows your Mac's language, and you can pick another one in Settings › Recording and languages.`,
      },
      {
        question: "Does it work for in-person meetings and recordings?",
        answer: "Yes. On the Mac, turn on “In person” before you start, and its microphone records everyone in the room. On iPhone, put the phone on the table and tap record. You can also import an audio or video file, such as a recorded call or a voice memo, and get the same transcript and note; an imported file counts as a meeting.",
      },
      {
        question: "Can Gistsmith record phone calls on iPhone?",
        answer: "iOS doesn't let any app listen to a call in progress. Use iPhone's own call recording (iOS 18.1 or later, not offered in every region) and, from the next iPhone update, share the audio to Gistsmith; or take the call on your Mac. Let the other person know you're recording; the law may require their consent.",
      },
    ],
    featureList: [
      "Records online calls (Zoom, Microsoft Teams, Google Meet and any other app) with no bot joining, plus in-person meetings and imported audio or video files",
      "Finishes the recording when the call ends, after a 30-second countdown; choose “Keep recording” to carry on, or turn it off in Settings",
      `Live transcript in ${spokenLanguages.length} languages, with live translation into any of ${noteLanguages.length} that carries what the speaker means rather than word for word`,
      `The app itself in ${interfaceLanguages.length} languages, following your Mac's language`,
      "A note after every meeting: your tasks with owners and due dates first, then a summary, a topic outline, decisions and a glossary",
      "Open tasks from earlier meetings in the same series or with the same people, shown when you record a meeting from your calendar",
      "Meeting templates picked from the meeting title (such as one-on-one, daily stand-up or sprint planning) and one-click recipes",
      "A follow-up email drafted from the note, with its key points, decisions and action items with owners and due dates, ready to edit, copy or open in Mail",
      "“What did I miss?” summaries during the meeting",
      "Ask questions across all your meetings or only the ones you tag with @, with answers that link to their sources; copy an answer or save it as a Markdown file",
      "Optional web search in Ask for what your meetings don't cover, with the web pages listed as sources",
      "Follow-up questions that keep the conversation and the meetings you asked about; saved chats you can rename, search and filter",
      "Optional snapshots of the shared screen, matched to what was said",
      "Send notes to Slack, Microsoft Teams, Discord, Zoom Team Chat, Notion and Apple Notes; tasks to Linear, Jira and Apple Reminders; anything else through webhooks",
      "Read-only access for Claude, ChatGPT, Cursor and VS Code over MCP, on your Mac or online with AI assistant access",
      "Voice typing in any Mac app, transcribed on your Mac",
      "Notes, transcripts and recordings stored on your Mac or iPhone",
      "An iPhone app for in-person meetings, with the same account and subscription as the Mac app",
      "Optional sync between Mac and iPhone, encrypted end to end; audio stays on the device that recorded it",
    ],
    finalTitle: "Let it write the note for your next meeting.",
    finalLead: "Set up in a minute, then just start listening.",
  },
  pricing: {
    meta: {
      title: `${productName} pricing: meeting notes for Mac and iPhone from $5.99 a month`,
      description: "$5.99 a month or $49 a year, taxes included. 3 meetings or 7 days free, up to 10 hours a month, up to 4 hours per meeting, cancel anytime.",
    },
    title: "Simple pricing, monthly or yearly.",
    lead: "Try it free for 3 meetings or 7 days, no card needed. If you like it, pick monthly or yearly.",
    plansTitle: "Plans",
    plans: [
      {
        plan: "monthly",
        name: "Monthly",
        price: "$5.99",
        per: "/ month",
        detail: "Billed every month. Taxes included.",
        badge: null,
        cta: "Choose monthly",
      },
      {
        plan: "yearly",
        name: "Yearly",
        price: "$49",
        per: "/ year",
        detail: "About $4.08 a month, billed once a year. Taxes included.",
        badge: "Save 32%",
        cta: "Choose yearly",
      },
    ],
    plansNote: "Both plans include everything above, on Mac and iPhone. Got an invite from a friend? {invite}",
    plansInviteLink: "How invites work",
    includedTitle: "Everything included",
    planTagline: "Everything from live transcript to tasks.",
    included: [
      { icon: "waveform", text: "Live transcript and live translation" },
      { icon: "note", text: "A note after every meeting: your tasks, decisions, summary and who said what" },
      { icon: "search", text: "“What did I miss?” and Ask across all your meetings, with saved chats and optional web search" },
      { icon: "users", text: "Online calls, in-person meetings and imported audio or video files" },
      { icon: "plug", text: "Send to Notion, Slack, Linear, Jira and more" },
      { icon: "sparkle", text: "Your AI apps can read your meetings through MCP, including snapshots of shared screens" },
      { icon: "mic", text: "Voice typing in any Mac app, transcribed on your Mac (free with any account)" },
      { icon: "refresh", text: "The Mac and iPhone apps on one subscription, with optional sync encrypted end to end" },
    ],
    limitsTitle: "The limits, plainly",
    limits: [
      { icon: "gift", title: "Trial", text: "3 meetings or 7 days from your first meeting, whichever comes first; each meeting up to 90 minutes. Opening a new account does not reset the trial." },
      {
        icon: "calendar",
        title: "10 hours a month",
        text: "A fair-use limit on meeting time that resets on the first day of each month (UTC). At the limit you can't start new meetings until the month resets; the app tells you clearly. AI outside meetings, such as Ask, has its own monthly allowance.",
      },
      { icon: "timer", title: "4 hours per meeting", text: "Enough for long workshops and lectures; longer meetings close at 4 hours." },
      {
        icon: "card",
        title: "Canceling",
        text: "Cancel in a click from your account page or at link.com. If you subscribed in the iPhone app, cancel on your iPhone in Settings › your name › Subscriptions. You keep access until the end of the paid period.",
      },
    ],
    faqTitle: "Questions",
    faq: [
      {
        question: "Who handles payment and taxes?",
        answer: `Checkout is hosted by Stripe, and your purchase is sold through Link, Stripe's payment service, as the merchant of record. The price of $5.99 a month or $49 a year includes sales tax, VAT or GST: Link calculates and remits the tax for your location, and checkout shows the included tax before you pay. You may see the price in your local currency. Your card details stay with Stripe and Link and never reach us. Purchases aren't available in some countries where Stripe can't sell, such as China, Cuba, Iran, North Korea, Russia and Syria. In the iPhone app you can also subscribe through the App Store: Apple handles that payment, the app shows the price for your country before you buy, and your Apple Account is charged.`,
      },
      {
        question: "What counts toward the monthly limits?",
        answer:
          "There are two monthly allowances, and the app and your account page show how much of each you've used. Meeting hours: up to 10 hours of meetings a month. The AI that works during and right after a meeting, such as live translation, “What did I miss?” and the note, comes with the meeting and doesn't use the second allowance. AI outside meetings: Ask, rewriting a note, translating a note to share and the task tools share a separate monthly allowance; when it's used up, they pause until the month resets. Web search in Ask has its own limit of 100 searches a month; after that, Ask answers from your meetings only. All of them reset on the first day of each month (UTC). During the free trial, AI outside meetings has a daily allowance instead.",
      },
      {
        question: "Does one subscription work on Mac and iPhone?",
        answer:
          "Yes. Sign in to both apps with the same Apple or Google account, and a subscription bought on this website, in the Mac app or in the iPhone app works in both. Subscriptions bought in the iPhone app go through the App Store: Apple bills them, and you manage or cancel them on your iPhone in Settings › your name › Subscriptions. Refunds for them are handled by Apple.",
      },
      {
        question: "What happens when the trial ends?",
        answer: "The app lets you know. You can't start new meetings until you subscribe; your existing notes and recordings stay on your device and remain readable.",
      },
      {
        question: "What if a payment fails?",
        answer: "The payment is retried over the following days. You keep access for up to 7 days; after that you can't start new meetings until the payment goes through. Update your card under “Manage subscription” or at link.com.",
      },
      {
        question: "Can I switch between monthly and yearly?",
        answer:
          "Not with a single click yet. Cancel your current plan with “Manage subscription” on your account page; you keep access until the end of the period you paid for. When it has ended, subscribe again from your account page and choose the other plan.",
      },
      {
        question: "Can I get a refund?",
        answer:
          "Refunds are handled by Link, the merchant of record for the subscription. Under Link's terms, consumers in the EU can cancel within 14 days of getting access by contacting Link support and giving “cooling off period” as the reason; Link may also refund within 60 days in certain other cases, such as a duplicate charge. Contact Link support at support.link.com, or write to us and we'll help. The details are in the terms of service.",
      },
      {
        question: "Who will I see on my receipt and card statement?",
        answer: `Receipts and some subscription emails come from Link, Stripe's payment service. Your card statement shows ${cardStatementDescriptor}.`,
      },
    ],
  },
  download: {
    meta: {
      title: `Download ${productName} for Mac and iPhone: AI meeting notes`,
      description: `Download ${productName} for your Mac (macOS 15 or later on Apple silicon) or get it on the App Store for iPhone. 3 meetings or 7 days free.`,
    },
    title: `Download ${productName}`,
    lead: "For Mac and iPhone. Free for 3 meetings or 7 days, no card needed.",
    versionLabel: "Version",
    requirementsLabel: "Requires",
    requirementsNote:
      "Everything works on macOS 15 or later on a Mac with Apple silicon (M1 or later). Voice typing uses Apple's on-device dictation on macOS 26 or later, and an on-device speech model on macOS 15 to 25.",
    macTitle: "Mac",
    iphoneTitle: "iPhone",
    macBenefit: "Records online calls in any meeting app, both sides of the conversation: a live transcript, translation and your note when you hang up.",
    iphoneBenefit: "Put your iPhone on the table and tap record: a live transcript, translation and the same note as on your Mac.",
    macAlt: `The ${productName} Mac app showing the Product weekly note: a list of meetings on the left, and on the right the summary and your three tasks with due dates, with a “3 tasks for you” label at the top.`,
    whatsNew: "What's new",
    iphoneNote:
      "For meetings in the room: it records the conversation around your iPhone. Online meetings are recorded on the Mac; sharing a phone call recorded with iPhone's own call recording comes in the next iPhone update. Sign in with the same account as on your Mac; one subscription covers both. In the app, subscriptions go through the App Store.",
    iphoneAlt: `The ${productName} home screen on iPhone: today's upcoming meetings, 8 open tasks, recent notes and an Ask a question button next to the record button.`,
    installTitle: "Three steps to your first meeting on the Mac",
    installSteps: [
      { title: "Install", text: `Open the disk image and drag ${productName} into Applications.` },
      { title: "Allow audio", text: "Open the app and allow the microphone and system audio, so it hears both sides of the call." },
      { title: "Sign in", text: "Sign in with Apple or Google and start listening." },
    ],
    footnote: "Updates arrive automatically inside the app.",
    helpCta: "Questions? Contact us",
  },
  // Rakip değerleri yalnızca rakiplerin kendi sitelerinden, 7 Kasım 2026'da denetlendi: fiyat sayfaları (granola.ai/pricing,
  // otter.ai/pricing, fireflies.ai/pricing; Fireflies fiyatları betikle çizer, değerler sayfanın HTML'inden okundu), ürün
  // sayfaları (otter.ai/desktop, fireflies.ai/desktop, fireflies.ai/talk) ve yardım merkezleri (docs.granola.ai: diller,
  // canlı çeviri, sesle yazma, telefon görüşmeleri; guide.fireflies.ai: botsuz masaüstü kaydı). Poffle'ın ayrı fiyat sayfası
  // yok: değerleri ana sayfasının fiyat ve SSS bölümlerinden (poffle.app). Otter'ın yardım merkezi okunamadı (403); canlı
  // çeviri için "listelenmiyor" yazılır, "yok" değil. Bizimkiler bu dosyadaki fiyat ve SSS metinleriyle, sunucu
  // sınırlarıyla (server/wrangler.jsonc) ve dil listeleriyle aynıdır. Yeni bir değer eklerken kaynağını denetle;
  // doğrulanmamış rakip bilgisi yazma (değer `null` kalır).
  compare: {
    meta: {
      title: `Compare ${productName} with Granola, Otter, Fireflies and Poffle`,
      description: `Compare ${productName} with Granola, Otter.ai, Fireflies.ai and Poffle: price, free plans, bots, platforms, languages and live translation. Checked Nov 2026.`,
    },
    eyebrow: "Compare",
    title: `How ${productName} compares`,
    lead: `${productName} is an AI meeting notes app for Mac and iPhone: live translation in ${noteLanguages.length} languages, notes that pick out your tasks, and no bot in the call. Here is how it differs from Granola, Otter, Fireflies and Poffle in price, how each one hears the meeting, platforms and languages. Where another app is stronger, we say so.`,
    overviewTopics: ["price", "free", "capture", "platforms", "languages", "translation"],
    overviewTitle: "At a glance",
    topics: {
      price: "Price",
      free: "Free option",
      capture: "How it hears the meeting",
      platforms: "Platforms",
      limits: "Meeting limits",
      languages: "Languages",
      translation: "Live translation",
      notes: "Notes",
      ask: "Questions across meetings",
      voiceTyping: "Voice typing",
      screens: "Shared screens",
      integrations: "Integrations",
      mcp: "MCP for AI apps",
      storage: "Where notes are kept",
      plans: "Plans for teams",
    },
    us: {
      price: "$5.99 a month or $49 a year, taxes included",
      free: "Free trial: 3 meetings or 7 days, whichever comes first; no card needed",
      capture: "No bot. Listens to your Mac's system audio and microphone, so it works with any call app; records in-person meetings on iPhone and imports audio or video files",
      platforms: "Mac with Apple silicon, macOS 15 or later; iPhone with iOS 26.1 or later, for in-person meetings",
      limits: "Up to 10 meeting hours a month and up to 4 hours per meeting",
      languages: `${spokenLanguages.length} spoken languages, including Turkish and Finnish; notes in ${noteLanguages.length}; app in ${interfaceLanguages.length} languages`,
      translation: `Included: what others say is translated into your language (any of ${noteLanguages.length}) within seconds`,
      notes: "The note starts with your own tasks (with owners and due dates), then a summary, decisions and a glossary; templates picked from the meeting title; a follow-up email drafted from the note",
      ask: "Ask across all your meetings; answers cite the meetings they came from, can look things up on the web, and copy or save as Markdown",
      voiceTyping: "Voice typing in any Mac app, transcribed on your Mac; free with any account",
      screens: "Optional snapshots of the shared screen, matched to what was said; notes and Ask can use them if you allow it",
      integrations:
        "Notion, Apple Notes, Slack, Microsoft Teams, Discord, Zoom Team Chat; tasks to Linear, Jira and Apple Reminders; Markdown folders (Obsidian) and webhooks (Zapier, Make, n8n)",
      mcp: "Read-only access for Claude, ChatGPT, Cursor and VS Code: on your Mac, or online with AI assistant access",
      storage: "Saved on the Mac or iPhone that recorded it, and on both with sync. Our servers hold copies only for features you turn on (sync, AI assistant access, share links) and briefly while a note is written; audio isn't kept by us",
      plans: "One personal plan, billed monthly or yearly; no shared team workspace",
    },
    usMarks: { capture: "yes", translation: "yes", voiceTyping: "yes", mcp: "yes" },
    usGlance: {
      price: "$5.99 a month or $49 a year, taxes included",
      free: "3 meetings or 7 days free, no card",
      capture: "No bot: listens to your Mac's audio",
      platforms: "Mac and iPhone",
      languages: `${spokenLanguages.length} spoken; notes in ${noteLanguages.length}`,
      translation: `Live, into any of ${noteLanguages.length} languages`,
    },
    highlights: [
      `Live translation in ${noteLanguages.length} languages`,
      "Your own tasks picked out in every note",
      "No bot in the call",
      "$5.99 a month, taxes included",
    ],
    markLabels: { yes: "Yes", partial: "Partly", no: "No" },
    why: {
      title: `Why pick ${productName}`,
      items: [
        { icon: "translate", title: "Live translation", text: `Read along in your language as people talk: ${spokenLanguages.length} spoken languages, notes and translation in any of ${noteLanguages.length}.` },
        { icon: "check-circle", title: "Your tasks, picked out", text: "Every note marks the tasks that are yours, with due dates, next to everyone else's with owners, the summary, decisions and glossary." },
        { icon: "shield", title: "No bot in the call", text: "It listens to your Mac's audio, so it works with any call app and nobody sees a note-taker join." },
        { icon: "plug", title: "Fits your stack", text: "Notes to Slack, Microsoft Teams and Notion, tasks to Linear and Jira, and your AI apps over MCP. $5.99 a month or $49 a year, taxes included." },
      ],
    },
    usBadge: "Our app",
    topicColumn: "Topic",
    tableTitle: "Side by side",
    checked: "Prices and features checked on 7 November 2026.",
    source: "Source",
    missingNote: "A dash means the point wasn't part of what we checked on the vendor's own site. It doesn't mean the feature is missing.",
    notChecked: "Not checked",
    pickTitle: "Who should pick which",
    readComparison: "Read the comparison",
    trademarks: `Granola, Otter.ai, Fireflies.ai and Poffle are trademarks of their owners. ${productName} isn't affiliated with any of these companies. Plans and prices change; check the vendor's site before you buy.`,
    ctaTitle: `Try ${productName} on your next meeting`,
    ctaText: "3 meetings or 7 days free, no card needed. Then $5.99 a month or $49 a year, taxes included.",
    competitors: {
      granola: {
        meta: {
          title: `${productName} vs Granola: live translation and your tasks picked out`,
          description: `${productName} vs Granola: both take notes without a bot. Compare price, free plans, platforms, languages, live translation and integrations. Checked Nov 2026.`,
        },
        name: "Granola",
        title: `${productName} vs Granola`,
        lead: `${productName} is a Mac and iPhone app with live translation as people talk, notes that pick out your tasks and one simple price. Both take notes without a bot joining the call; Granola runs on more devices, including Windows and Android, and has team plans and more business integrations.`,
        summary: `${productName} adds live translation and notes that pick out your tasks, for one simple price. Both work without a bot; Granola has a free plan, Windows, Android and Apple Watch apps, team plans and CRM integrations.`,
        pricingUrl: "https://www.granola.ai/pricing",
        values: {
          price: "Basic $0; Business $14 per user a month; Enterprise $35 per user a month",
          free: "Basic plan at $0, with 30 days of meeting history",
          capture: "No bot. Uses your computer's audio",
          platforms: "Mac, Windows, iPhone, Android and Apple Watch",
          limits: null,
          languages: "31 languages on Mac and Windows, 17 on iPhone and Android",
          translation: "Not offered: Granola's help center says it doesn't offer live translation during a meeting",
          notes: "Note templates",
          ask: "AI chat across meetings",
          voiceTyping: "Voice typing in any app, in beta on the Mac and Windows apps; free on every plan",
          screens: null,
          integrations: "Slack on all plans; Notion, HubSpot, Zapier, Attio, Affinity and an API on Business; Salesforce on Enterprise",
          mcp: "On all plans: your own notes from the last 30 days on Basic; workspace notes on Business and Enterprise",
          storage: null,
          plans: "Per-user Business and Enterprise plans; shared folders on every plan",
        },
        marks: { capture: "yes", translation: "no", voiceTyping: "yes", mcp: "yes" },
        glance: {
          price: "Business $14, Enterprise $35 per user a month",
          free: "Basic $0, with 30 days of history",
          capture: "No bot: uses your computer's audio",
          platforms: "Mac, Windows, iPhone, Android, Apple Watch",
          languages: "31 on desktop, 17 on mobile",
          translation: "Not offered, per its help center",
        },
        edge: ["A free plan with 30 days of history", "Windows, Android and Apple Watch apps", "Team plans and CRM integrations"],
        strengthsTitle: "Where Granola is stronger",
        strengths: [
          "A free Basic plan, with 30 days of meeting history.",
          "Apps for Windows, Android and Apple Watch as well as Mac and iPhone.",
          "Records outgoing phone calls made from its iPhone and Android apps.",
          "Per-user Business and Enterprise plans for teams, with shared folders, central billing and, on Enterprise, SSO and SCIM.",
          "HubSpot, Attio, Affinity and Zapier integrations and an API on the Business plan; Salesforce on Enterprise.",
        ],
        pickCompetitor: {
          title: "Pick Granola if",
          points: [
            "you want a free plan and 30 days of history is enough",
            "you also work on Windows, an Android phone or an Apple Watch, or want to place and record calls from inside the app",
            "your team wants one shared workspace with per-user billing",
            "your notes need to reach HubSpot, Attio or Salesforce, or you want an API",
          ],
        },
        pickUs: {
          title: `Pick ${productName} if`,
          points: [
            "your meetings are in another language and you want a live translation as people talk",
            "you want every note to pick out your own tasks, with due dates",
            "you work on a Mac and want simple pricing: $5.99 a month or $49 a year, taxes included",
            "you want notes, transcripts and recordings kept on your own Mac and iPhone",
          ],
        },
      },
      otter: {
        meta: {
          title: `${productName} vs Otter.ai: live translation and your tasks, on Mac and iPhone`,
          description: `${productName} vs Otter.ai: live translation, your tasks picked out and one simple price on Mac and iPhone. Compare price, minutes, languages and bots. Checked Nov 2026.`,
        },
        name: "Otter.ai",
        title: `${productName} vs Otter.ai`,
        lead: `${productName} translates live as people talk, in ${spokenLanguages.length} spoken languages, and picks out your tasks in every note, for one simple price on Mac and iPhone. Otter sends a bot to Zoom, Microsoft Teams and Google Meet by default, and its Mac and Windows desktop apps record without one; it has a free tier, more platforms, CRM integrations and team plans.`,
        summary: `${productName} translates live in ${spokenLanguages.length} spoken languages and picks out your tasks in every note. Otter has a free tier, a meeting bot and bot-free desktop apps, and runs on more platforms.`,
        pricingUrl: "https://otter.ai/pricing",
        values: {
          price: "Basic free; Pro $16.99 per user a month billed monthly ($8.33 billed annually); Business $30 per user a month billed monthly ($19.99 billed annually); Enterprise on request",
          free: "Basic plan: 300 transcription minutes a month, up to 30 minutes per conversation and 3 file imports in total",
          capture: "A bot joins Zoom, Microsoft Teams and Google Meet by default; the Mac and Windows desktop apps record without a bot",
          platforms: "Mac and Windows desktop apps, iOS and Android apps, Chrome extension",
          limits: "Pro: 1,200 minutes a month, up to 90 minutes per meeting. Business: unlimited meetings, up to 4 hours per meeting",
          languages: "Automatic transcription in English, Spanish, French, German, Japanese and Chinese",
          translation: "Not listed on Otter's pricing or desktop app pages (checked November 2026)",
          notes: null,
          ask: "AI Chat (20 questions a month on Basic)",
          voiceTyping: null,
          screens: null,
          integrations: "Zapier, Salesforce and HubSpot from Pro (Salesforce and HubSpot with user limits); Dropbox and Zoom cloud sync; an API with webhooks on Enterprise",
          mcp: "Otter MCP server, listed on every plan including Basic",
          storage: null,
          plans: "Per-user Pro, Business and Enterprise plans",
        },
        marks: { capture: "partial", mcp: "yes" },
        glance: {
          price: "Pro $8.33–$16.99, Business $19.99–$30 per user a month",
          free: "Basic: 300 minutes a month, 30 per meeting",
          capture: "A bot by default; desktop apps record without one",
          platforms: "Mac, Windows, iPhone, Android, Chrome",
          languages: "6 languages listed",
          translation: "Not listed on its pricing pages",
        },
        edge: ["A free tier with 300 minutes a month", "Windows and Android apps", "Team plans and CRM integrations"],
        strengthsTitle: "Where Otter is stronger",
        strengths: [
          "A free Basic plan with 300 transcription minutes a month.",
          "Apps for Mac, Windows, iOS and Android, and a Chrome extension.",
          "A meeting bot for Zoom, Microsoft Teams and Google Meet, and desktop apps for Mac and Windows that record without one.",
          "Salesforce, HubSpot and Zapier integrations from the Pro plan, and an MCP server on every plan.",
          "Per-user Pro, Business and Enterprise plans for teams, with unlimited meetings on Business.",
        ],
        pickCompetitor: {
          title: "Pick Otter if",
          points: [
            "you want a free tier and 300 minutes a month covers you",
            "you want a bot that can join calls for you, as well as bot-free desktop apps",
            "you need Windows or Android apps, or team plans",
            "your notes need to reach Salesforce or HubSpot",
          ],
        },
        pickUs: {
          title: `Pick ${productName} if`,
          points: [
            "you want a live translation as people talk",
            `you meet in a language beyond the six on Otter's pricing page: ${productName} understands ${spokenLanguages.length}`,
            "you want every note to pick out your own tasks, with due dates",
            "you work on a Mac and want simple pricing: $5.99 a month or $49 a year, taxes included",
          ],
        },
      },
      fireflies: {
        meta: {
          title: `${productName} vs Fireflies.ai: live translation on one simple plan`,
          description: `${productName} vs Fireflies.ai: one personal plan with live translation, or a team platform. Compare price, free plans, bots and languages. Checked Nov 2026.`,
        },
        name: "Fireflies.ai",
        title: `${productName} vs Fireflies.ai`,
        lead: `${productName} translates live as people talk, picks out your tasks in every note and has one simple personal plan. Fireflies is built for teams: its notetaker bot joins Zoom, Google Meet and Teams, its desktop app and Chrome extension record without the bot, meetings are kept in its cloud, and it has a free plan, workspaces and many integrations.`,
        summary: `${productName} translates live and has one simple personal plan. Fireflies is built for teams, with a meeting bot, a bot-free desktop app, a free plan and CRM integrations.`,
        pricingUrl: "https://fireflies.ai/pricing",
        values: {
          price: "Free $0; Pro $18 per seat a month billed monthly ($10 billed annually); Business $29 per seat a month billed monthly ($19 billed annually); Enterprise $39 per seat a month, billed annually only",
          free: "Free plan: transcription listed as unlimited (with a footnote), limited AI summaries, 400 minutes of storage per team and 20 AI credits",
          capture: "A bot (the Fireflies Notetaker) joins Zoom, Google Meet, Teams and more; the Mac and Windows desktop app and a Chrome extension record without the bot",
          platforms: "Web, Mac and Windows desktop app, iOS and Android apps, Chrome extension",
          limits: "Recording limit of 2 to 4 hours per meeting depending on plan; storage of 400 minutes per team on Free, 8,000 minutes per seat on Pro, unlimited on Business",
          languages: "Transcription in 100+ languages (beyond the main ones, in beta); automatic language detection; Multi-language Mode on Business",
          translation: "Not listed on Fireflies' pricing or help pages (checked November 2026)",
          notes: "AI summaries (limited on Free); action items and a task manager from Pro",
          ask: "AskFred AI assistant",
          voiceTyping: "Fireflies Talk: free, unlimited dictation wherever you type, on Mac, Windows, iPhone and Android",
          screens: "Records meeting video on paid plans",
          integrations: "Integrations including CRMs and a Slack assistant; unlimited integrations from Pro; an API on every plan, with rate limits",
          mcp: null,
          storage: "In Fireflies' cloud; private storage and custom data retention on Enterprise",
          plans: "Per-seat Pro, Business and Enterprise plans with team workspaces, channels and admin analytics",
        },
        marks: { capture: "partial", voiceTyping: "yes" },
        glance: {
          price: "Pro $10–$18, Business $19–$29 per seat a month",
          free: "Free plan, 400 storage minutes per team",
          capture: "A bot by default; desktop app records without one",
          platforms: "Web, Mac, Windows, iPhone, Android, Chrome",
          languages: "100+, most of them in beta",
          translation: "Not listed on its pricing or help pages",
        },
        edge: ["A free plan", "Web, Windows and Android apps", "Team workspaces and CRM integrations"],
        strengthsTitle: "Where Fireflies is stronger",
        strengths: [
          "A free plan, with transcription listed as unlimited, limited AI summaries and 400 minutes of storage per team.",
          "A web app, a Mac and Windows desktop app that records without the bot, iOS and Android apps and a Chrome extension.",
          "Team workspaces, channels, conversation intelligence and analytics for admins.",
          "Transcription in 100+ languages (most of them in beta) with automatic language detection, and a Multi-language Mode on Business.",
          "CRM integrations, an API on every plan, and SSO, SCIM and HIPAA compliance on Enterprise.",
          "Meeting video recording on paid plans.",
        ],
        pickCompetitor: {
          title: "Pick Fireflies if",
          points: [
            "your team wants shared workspaces, channels and admin analytics",
            "you need Windows or Android apps, or a web app",
            "your notes need to reach a CRM, or you want an API",
            "you want a bot that can join calls for you, as well as a bot-free desktop app",
          ],
        },
        pickUs: {
          title: `Pick ${productName} if`,
          points: [
            "you want a live translation as people talk",
            "you want every note to pick out your own tasks, with due dates",
            "you want notes, transcripts and recordings kept on your own Mac and iPhone",
            "you want simple pricing for one person: $5.99 a month or $49 a year, taxes included",
          ],
        },
      },
      poffle: {
        meta: {
          title: `${productName} vs Poffle: cloud notes or fully on your Mac`,
          description: `Poffle writes notes fully on your Mac for $25 once; ${productName} brings ${spokenLanguages.length} spoken languages and live translation. Compare price and languages. Checked Nov 2026.`,
        },
        name: "Poffle",
        title: `${productName} vs Poffle`,
        lead: `${productName} writes a live transcript, a final transcript separated by speaker and the note in the cloud, which brings ${spokenLanguages.length} spoken languages, live translation and integrations, on macOS 15 or later, for a monthly or yearly subscription. Both record calls on your Mac with no bot. Poffle does everything on the Mac: Apple's on-device speech recognition writes the transcript and Apple Intelligence writes the notes, for $25 once, next to a rail of everyday Mac tools.`,
        summary: `${productName} brings live translation, ${spokenLanguages.length} spoken languages and integrations. Poffle works fully on your Mac with Apple Intelligence, costs $25 once and adds everyday Mac tools.`,
        pricingUrl: "https://poffle.app/",
        values: {
          price: "$25 once, plus tax; not a subscription; all future updates included",
          free: "7-day trial with every feature; a card is needed to start, and $25 plus tax is charged after 7 days unless you cancel",
          capture: "No bot. Offers to record when a call starts, records your Mac's microphone and system audio, and stops when the call ends",
          platforms: "Mac with Apple silicon, macOS 26 or later; online at least every 30 days to check the license",
          limits: null,
          languages: "Transcripts in every language Apple's on-device speech recognition supports on your Mac; notes need Apple Intelligence to support the meeting's language",
          translation: "Not listed on Poffle's site (checked November 2026)",
          notes: "Written by Apple Intelligence (it must be turned on): decisions and action items with owners first, a map of who spoke when and where each topic starts, a clean or word-for-word transcript; templates picked from the meeting title",
          ask: "Ask across your saved notes and transcripts, answered on your Mac with sources you can open",
          voiceTyping: null,
          screens: null,
          integrations: "Action items to Apple Reminders; notes through the macOS Share menu (Mail, Messages), copied as Markdown or exported as Markdown with the transcript, which Apple Notes can import",
          mcp: null,
          storage: "Recordings, transcripts and notes stay on your Mac; no cloud transcription or summary service",
          plans: "One license for one person, on up to 2 Macs, for personal and commercial use",
        },
        marks: { capture: "yes" },
        glance: {
          price: "$25 once, plus tax",
          free: "7-day trial; a card is needed",
          capture: "No bot: records your Mac's audio",
          platforms: "Mac with macOS 26 or later",
          languages: "Those Apple's on-device recognition supports",
          translation: "Not listed on its site",
        },
        edge: ["Everything runs on your Mac", "$25 once instead of a subscription", "Everyday Mac tools beside the notes"],
        strengthsTitle: "Where Poffle is stronger",
        strengths: [
          "Everything runs on your Mac: Apple's on-device speech recognition for transcripts and Apple Intelligence for notes, with no cloud transcription or summary service.",
          "A one-time price of $25 plus tax, with all future updates included, instead of a subscription.",
          "More than meetings: a rail at the edge of the screen with clipboard history, a file tray, Now Playing controls, an audio spectrum, your calendar agenda and a meeting countdown.",
          "Suggestions as you type in any app, accepted with Tab, drawing on your meeting notes and the text on your screen, written by a model on your Mac.",
        ],
        pickCompetitor: {
          title: "Pick Poffle if",
          points: [
            "you want transcripts and notes made entirely on your Mac, with nothing sent to a cloud service",
            "you'd rather pay once ($25 plus tax) than subscribe",
            "you'd also use clipboard history, a file tray, a calendar rail and Tab suggestions in any app",
            "your Mac runs macOS 26 with Apple Intelligence turned on, and it supports your meetings' language",
          ],
        },
        pickUs: {
          title: `Pick ${productName} if`,
          points: [
            `you want a live transcript as people talk, a final transcript separated by speaker, and notes in any of ${noteLanguages.length} languages`,
            `you meet in one of ${spokenLanguages.length} languages, including Turkish and Finnish, and want notes in any of ${noteLanguages.length} without needing Apple Intelligence`,
            "you want a live translation as people talk",
            "your notes and tasks need to reach Slack, Microsoft Teams, Notion, Linear or Jira, or your AI apps over MCP",
            "your Mac runs macOS 15 or later, and you'd like to try 3 meetings or 7 days free with no card",
          ],
        },
      },
    },
  },
  blog: {
    meta: {
      title: `${productName} blog: meeting notes and calls on a Mac`,
      description: `Practical guides on meeting notes, task lists and recording calls on a Mac, from the team behind ${productName}.`,
    },
    eyebrow: "Blog",
    title: "Notes on better meetings",
    lead: "Practical guides on meeting notes, follow-ups and recording calls on a Mac. Short, specific and useful whether or not you use our app.",
    feedTitle: `${productName} blog`,
    feedLink: "RSS feed",
    latest: "Latest",
    allTitle: "All posts",
    byline: "By",
    minutesRead: "min read",
    backToBlog: "All posts",
    updated: "Updated",
    moreTitle: "More from the blog",
    coverAlt: `“{title}” in large type on a soft pastel gradient, with the ${productName} logo and a small sound wave.`,
    ctaTitle: `Try ${productName}`,
    ctaText: "AI meeting notes for Mac and iPhone. 3 meetings or 7 days free, then $5.99 a month or $49 a year, taxes included.",
  },
  mcp: {
    meta: {
      title: `${productName} MCP server: your meetings in Claude, ChatGPT and Cursor`,
      description: `${productName} connects your meeting notes to AI apps, read-only: a local MCP server for Claude Desktop, Cursor and VS Code, and an online connector for Claude and ChatGPT on the web and phone.`,
    },
    eyebrow: "MCP",
    title: "Ask your AI apps about your meetings.",
    lead: "Claude, ChatGPT, Cursor and VS Code can search and read your meetings (on your Mac, or online with AI assistant access); they can never change them.",
    localHint: { text: "Using Claude Desktop, Cursor or VS Code on your Mac?", link: "Set up the local server" },
    localTitle: "On your Mac: the local MCP server",
    copyButton: { label: "Copy", copied: "Copied", failed: "Couldn't copy" },
    toolsTitle: "What it offers",
    toolsLead: "The server gives your AI app six tools. The app decides when to call them, usually starting with a list or a search and then opening a meeting.",
    toolInputLabel: "Input",
    tools: [
      {
        name: "list_meetings",
        text: "Lists your recorded meetings, newest first: ID, date, title, length and whether the note is ready.",
        input: "limit (optional; 20 if not given)",
      },
      {
        name: "search_meetings",
        text: "Searches your notes and transcripts by keyword and returns the matching passages, with the meeting and the moment in it.",
        input: "query (required)",
      },
      {
        name: "get_meeting",
        text: "Returns a meeting's note as Markdown: summary, decisions, tasks and glossary. Add the transcript when you need the exact words.",
        input: "id from list_meetings (required); include_transcript (optional)",
      },
      {
        name: "list_my_tasks",
        text: "Lists the tasks from your meeting notes that are yours and not yet done, with due dates and the meeting each one came from.",
        input: "No input",
      },
      {
        name: "list_screens",
        text: "Lists the snapshots of the shared screen kept during a meeting, each with the time it was on screen and what was said meanwhile, so feedback can be tied to the exact slide or design frame. Needs “Take snapshots of the shared screen” turned on in Settings › Recording and languages.",
        input: "id from list_meetings (required); offset (optional, for long meetings)",
      },
      {
        name: "get_screen",
        text: "Returns one snapshot as an image, with what was said while it was on screen.",
        input: "id from list_meetings and screen from list_screens (both required)",
      },
    ],
    setupTitle: "Connect it",
    setupLead: `Keep ${productName} in your Applications folder and sign in to the app first: the server reads the meetings of the account you're signed in with.`,
    oneClick: {
      title: "One click: Claude, Cursor and VS Code",
      points: [
        `In ${productName}, open Settings › Connections.`,
        "Under AI apps, click Connect on the Claude, Cursor or Visual Studio Code card. A card is dimmed if that app isn't in your Applications folder.",
        `Quit and reopen the AI app. ${productName} now appears among its tools.`,
      ],
    },
    manual: {
      title: "Any other MCP app",
      points: [
        "In Settings › Connections, open “Advanced: skills and manual MCP setup”.",
        "Under Other MCP clients, click Copy configuration.",
        "Paste it into your app's MCP settings. In Claude Desktop that's Settings › Developer › Edit Config.",
      ],
    },
    configLabel: "The configuration, for the app in your Applications folder",
    configNote: `The app copies this with the real location of ${productName} on your Mac. If you keep it somewhere else, use the copy from the app.`,
    filesTitle: "Where the one-click setup writes",
    fileColumns: { client: "App", file: "Configuration file" },
    files: [
      { client: "Claude", file: "~/Library/Application Support/Claude/claude_desktop_config.json" },
      { client: "Cursor", file: "~/.cursor/mcp.json" },
      { client: "Visual Studio Code", file: "~/Library/Application Support/Code/User/mcp.json" },
    ],
    filesNote: `Connect adds a single “${productName.toLowerCase()}” entry and leaves everything else in the file as it was. VS Code keeps its servers under “servers” with “type”: “stdio”; Connect writes that form for you. If the file contains comments, which VS Code allows, ${productName} won't overwrite it and tells you why.`,
    questionsTitle: "Questions to try",
    questionsLead: "Ask in your own words. A few that work well:",
    questions: [
      "What did I promise Nordia last week?",
      "List my open tasks from this week's meetings, grouped by due date.",
      "Find the meetings where we discussed the budget and summarize what we decided.",
      "Go through the screens from yesterday's design review and list the feedback on each frame.",
    ],
    privacyTitle: "What it can and can't do",
    privacy: [
      { title: "Read only", text: "The tools list, search and read. Nothing can be edited, deleted or sent through them." },
      {
        title: "Runs on your Mac",
        text: `Your AI app starts ${productName} in the background and talks to it through standard input and output. The server doesn't open a network port.`,
      },
      {
        title: "Your AI app's provider sees what it reads",
        text: "Notes, transcripts and screen snapshots your AI app reads go to the company behind that AI app, under its own terms.",
      },
      {
        title: "Your signed-in account only",
        text: `If you sign out of ${productName}, the tools stop returning meetings until you sign in again. If you switch accounts, restart the AI app.`,
      },
      {
        title: "Meeting text is data, not instructions",
        text: "The server tells your AI app that notes and transcripts are what people said, and that it shouldn't follow requests found inside them.",
      },
    ],
    remote: {
      title: "Claude and ChatGPT on the web: AI assistant access",
      lead: `Assistants in the browser or on your phone can't start ${productName} on your Mac. For them there is AI assistant access, an online connector that reads your meeting notes (never transcripts or audio) and changes nothing. Turn on "Let AI assistants read my meeting notes" in the ${productName} app on Mac or iPhone under Settings › Connections (version 0.2.1 or later), then add ${productName} to your assistant.`,
      consent: "Off by default. Turn it on and an encrypted copy of your notes, never audio, is kept in the EU so the assistants you connect can read them. Turn it off and it is deleted at once (backups within 30 days).",
      toolsTitle: "Its four tools, all read-only",
      tools: [
        { name: "search", text: "Finds meetings by the words in their titles, summaries, decisions, open questions, tasks and outlines, best match first.", input: "query (required)" },
        { name: "fetch", text: "Opens one meeting note as Markdown: summary, decisions, open questions, tasks, outline and your own notes, with the date, length, folder and attendees.", input: "id from search or list_meetings (required)" },
        { name: "list_meetings", text: "Lists your meetings, newest first, optionally within a time range or a folder.", input: "since, until, folder, limit and cursor (all optional)" },
        { name: "list_my_tasks", text: "Lists the tasks assigned to you across your meetings, open ones only unless you ask for done ones too.", input: "include_done (optional)" },
      ],
      urlLabel: "Connector URL",
      url: "https://mcp.gistsmith.com/mcp",
      setups: [
        {
          title: "Claude",
          points: [
            `In Claude, open Customize › Connectors, find ${productName} in the connector directory and click Connect.`,
            `Sign in with the Apple or Google account you use in ${productName} and approve read access.`,
            "If your organization hides the directory, choose Add custom connector instead and paste the connector URL.",
          ],
        },
        {
          title: "ChatGPT",
          points: [
            "In ChatGPT, open Settings › Apps & Connectors › Advanced settings and turn on developer mode if your plan needs it for custom connectors.",
            `Choose Create, name it ${productName}, paste the connector URL and pick OAuth.`,
            `Sign in with the Apple or Google account you use in ${productName} and approve read access.`,
          ],
        },
      ],
      notes: [
        {
          title: "Our servers can read this copy",
          text: "It is encrypted at rest with a key for your account, but not end to end: our servers can technically read it, which is how they answer your assistant. Transcripts, audio, screen snapshots and voice profiles are never uploaded.",
        },
        {
          title: "Your assistant's provider sees what it reads",
          text: "What an assistant reads from your notes falls under that provider's policies, not ours.",
        },
        {
          title: "Meeting text can steer an assistant",
          text: "An assistant that also has other tools, such as email or web access, can be steered by text in your meetings. Check what it does before you let it act.",
        },
        {
          title: "Disconnect any time",
          text: "The app lists every connected assistant so you can disconnect it. Turning AI assistant access off disconnects them all and deletes the copy; when your subscription or trial ends, access stops at once and the copy is deleted within 7 days.",
        },
      ],
    },
  },
  signIn: {
    meta: { title: `Sign in — ${productName}`, description: `Sign in to your ${productName} account with Apple or Google.` },
    title: "Sign in",
    lead: "To manage your account and subscription. You use the same account in the Mac and iPhone apps.",
    apple: "Continue with Apple",
    google: "Continue with Google",
    legalBefore: "By continuing, you agree to the",
    legalBetween: "and confirm you have read the",
    noScript: "Signing in needs JavaScript.",
    appTitle: `Sign in to the ${productName} app`,
    appLead: "Continue with Apple or Google. When you're done, the app opens and finishes signing you in.",
    appReturning: "Returning to the app…",
    appReturningHelp: `If ${productName} didn't open, use the button below.`,
    appOpen: `Open ${productName}`,
  },
  contact: {
    meta: { title: `Contact — ${productName}`, description: `Questions about ${productName}, your account or your subscription? Send us a message.` },
    title: "Contact us",
    lead: "Questions about the app, your account or your subscription? Write to us and we'll reply by email.",
    emailLabel: "Your email",
    emailPlaceholder: "name@example.com",
    messageLabel: "Message",
    messagePlaceholder: "How can we help?",
    turnstileLabel: "Security check",
    submit: "Send message",
    privacyNote: "We use your email and message only to answer you, and delete them after 180 days.",
    sentTitle: "Message sent",
    sentText: "Thank you for writing. We'll reply to the address you gave as soon as we can.",
    sendAnother: "Send another message",
    directTitle: "Prefer email?",
    directText: "You can also write to us directly:",
    companyTitle: "Who makes it",
    companyText: `${productName} is made by ${makerName}.`,
    companyLink: "Company details",
    noScript: "The contact form needs JavaScript. You can also email us directly.",
  },
  account: {
    meta: { title: `Account — ${productName}`, description: `Your ${productName} account: plan, trial, monthly usage and subscription.` },
    title: "Your account",
    loading: "Loading your account…",
    retry: "Try again",
    paymentDone: "Payment received, thank you. Your subscription will show up here within a few seconds.",
    paymentDoneSignedOut: {
      title: "Payment received, thank you",
      text: `Go back to the ${productName} app: your subscription shows up there within a few seconds. You can close this tab.`,
      signIn: "Sign in to see your account here",
    },
    planLabel: "Plan",
    trialLabel: "Free trial meetings left",
    hoursLabel: "Usage this month",
    hoursNote: "Resets on the first day of each month (UTC).",
    aiLabel: "AI outside meetings",
    aiNote: "Ask, note rewriting, shared-note translation and task tools use this allowance. AI during a meeting doesn't.",
    subscribe: "Subscribe",
    planChoiceLegend: "Choose a plan",
    invite: {
      summary: "Have an invite code?",
      label: "Invite code",
      placeholder: "For example K7M2QX9D",
      apply: "Apply",
      remove: "Remove",
    },
    subscribeNote: "Your plan renews automatically every month or year until you cancel. Cancel anytime. Sold through Link, Stripe's payment service.",
    manage: "Manage subscription",
    manageNote: "Update your card or cancel anytime. Receipts are emailed to you by Link, and your order history is at link.com. Your plan renews automatically until you cancel.",
    signOut: "Sign out",
    referral: {
      title: "Give a month, get a month",
      text: "Friends save a month with your code, and you earn a free month for each one who stays.",
      codeLabel: "Your invite code",
      copyLink: "Copy invite link",
      copied: "Link copied",
      howItWorks: "How invites work",
    },
    appTitle: "Get the app",
    appText: `${productName} runs on your Mac and iPhone. Sign in to the app with the same Apple or Google account.`,
    helpTitle: "Need help?",
    helpContact: "Contact support",
    dangerTitle: "Delete account",
    dangerText:
      "Your account, sessions, device registrations and usage history are permanently deleted, and a subscription bought on this website or in the Mac app is cancelled immediately. Your notes and recordings stay on your Mac and iPhone. Receipts and payment records are kept by Stripe and Link as required by law. To prevent free-trial abuse, a pseudonymous record of how many free-trial meetings your sign-in has used is kept for up to 24 months, so signing in again with the same account continues the trial instead of restarting it. If you subscribed with an invite, a pseudonymous record that you used one is also kept for up to 24 months so it can't be used twice.",
    deleteButton: "Delete account",
    dialogTitle: "Delete your account?",
    dialogText: "This can't be undone. A subscription bought on this website or in the Mac app is cancelled immediately and ends with your account; the remaining time is not refunded automatically.",
    confirmWord: "DELETE",
    confirmLabel: "Type DELETE to confirm",
    cancel: "Cancel",
    confirmDelete: "Permanently delete my account",
    deletedTitle: "Your account was deleted",
    deletedText: "Your account data on our server is gone, apart from the pseudonymous free-trial and invite records described in the privacy policy. The notes and recordings on your Mac and iPhone are still there.",
    deletedRedirect: "Taking you to the home page…",
    backHome: "Back to the home page",
    noScript: "The account page needs JavaScript.",
  },
  invite: {
    meta: {
      title: `Invite a friend — ${productName}`,
      description: `Give a month, get a month: a friend who subscribes to ${productName} with your invite code gets their first month free (or $5.99 off a yearly plan), and you get $5.99 off your next payment.`,
    },
    eyebrow: "Invite a friend",
    title: "Give a month, get a month.",
    lead: `Share ${productName} with a friend. They get their first month free (or $5.99 off a yearly plan), and when they stay, you get $5.99 off your next payment.`,
    stepsTitle: "How it works",
    steps: [
      {
        icon: "gift",
        title: "Share your code",
        text: "Every subscriber gets a personal invite code, shown in the app under Settings › Plan and billing and on your account page. Send the code or your invite link to a friend.",
      },
      {
        icon: "card",
        title: "Your friend subscribes with it",
        text: "On the monthly plan their first month is free; on the yearly plan they get $5.99 off their first year. Invites are for people who haven't subscribed before.",
      },
      {
        icon: "check-circle",
        title: "You get a month",
        text: "Once your friend's first paid charge (after the free month on the monthly plan) has gone through and hasn't been refunded for 30 days, $5.99 is taken off your next payment. On the monthly plan that is a free month; on the yearly plan it comes off your next renewal.",
      },
    ],
    rulesTitle: "The rules, plainly",
    rules: [
      "Up to 12 rewards per person in any 12 months, and up to 3 invites waiting for their reward at a time.",
      "One reward for each new paying account. Your own account, another account of yours, or the same card on several invited accounts doesn't count.",
      "A reward is canceled if your friend's first payment is refunded or disputed.",
      "Rewards are credit on your next payments, not cash, and can't be exchanged or transferred.",
      "Accounts with free access from us can share their code, and their friends still get the discount, but they don't earn rewards while that access lasts.",
      "We may change or end the invite program; rewards already earned stay yours.",
    ],
    redeem: "Redeem your invite",
    redeemNote: "Got a code from a friend? Redeem it on your account page: sign in, choose a plan and enter the code under “Have an invite code?”. In the Mac app, enter it when you subscribe.",
    codeLabel: "Your friend's invite code",
    codeNote: "We've saved it in this browser. Subscribe here, or sign in to the Mac app and enter it when you subscribe.",
    subscribeWithCode: "Subscribe with this code",
    ownCodeTitle: "Looking for your own code?",
    ownCodeText: "Subscribers find it in the app under Settings › Plan and billing and on their account page.",
    ownCodeLink: "Go to your account",
    termsNote: "The full rules are in the",
    termsLink: "terms of service",
  },
  admin: {
    meta: { title: productName, description: tagline },
    documentTitle: `Dashboard — ${productName}`,
    title: "Admin",
    backToSite: "Back to site",
    refresh: "Refresh",
    loading: "Loading…",
    users: {
      title: "Users",
      searchLabel: "Account ID",
      searchPlaceholder: "Search by account ID prefix",
      search: "Search",
      segmentLabel: "Segment",
      segmentGroups: { plan: "Plan", dropOff: "Drop-off" },
      segments: {
        all: "All",
        subscribed: "Subscribed",
        pastDue: "Payment due",
        canceled: "Cancelled",
        trial: "Trial",
        free: "No plan",
        noMeeting: "Signed in, no meeting",
        trialEnded: "Trial ended, not subscribed",
        inactive: "Inactive for 7+ days",
        failed: "Meetings with errors",
      },
      providerLabel: "Sign-in",
      providers: { all: "Any", apple: "Apple", google: "Google" },
      columns: {
        user: "Account",
        provider: "Sign-in",
        created: "Joined",
        plan: "Plan",
        trial: "Trial",
        subscription: "Subscription",
        meetings: "Meetings",
        hours: "Hours, month",
        lastActive: "Last active",
        problems: "Problems",
      },
      empty: "No accounts match.",
      loadMore: "Load more",
      back: "All users",
      fields: {
        provider: "Sign-in",
        created: "Joined",
        lastActive: "Last active",
        stripeCustomer: "Stripe customer",
        trialDevice: "Trial tied to a Mac",
        subscription: "Subscription",
        trial: "Trial",
        cancellation: "Why they cancelled",
      },
      usageTitle: "This month",
      usage: { hours: "Meeting hours", tokens: "AI tokens", accountTokens: "AI outside meetings", audio: "Transcribed audio" },
      timelineTitle: "Timeline",
      timelineNote: "Built from the account's current dates; past subscription changes aren't stored.",
      meetingsTitle: "Meetings",
      meetingColumns: {
        started: "Started",
        kind: "Plan",
        state: "Status",
        duration: "Length",
        audio: "Audio",
        tokens: "Tokens",
        notes: "Notes",
        problem: "What went wrong",
      },
      noMeetings: "No meetings yet.",
      reportsTitle: "Reports from this account",
      noReports: "No reports.",
    },
    operations: {
      kpis: {
        open: "Meetings live now",
        unended: "Never ended, 7 days",
        reservations: "Usage reservations",
        deepgram: "Unsettled live transcripts",
        webhook: "Stripe webhook",
        reports: "Reports, 7 days",
        sync: "Mac ↔ iPhone sync accounts",
        shares: "Shared note links",
      },
      openTitle: "Live meetings",
      openColumns: { user: "Account", kind: "Plan", started: "Started", endsBy: "Ends by", notes: "Notes" },
      noOpen: "No meetings are live right now.",
      stripeTitle: "Stripe events, 7 days",
      stripeColumns: { type: "Event", count: "Count" },
      noStripe: "No Stripe events in the last 7 days.",
      crashesTitle: "Latest crash reports",
      noCrashes: "No crash reports.",
    },
    insights: {
      problemsTitle: "Problems",
      problemsColumns: { problem: "Problem", last7: "7 days", last30: "30 days" },
      noProblems: "No refusals, service errors or server errors in the last 30 days.",
      funnelTitle: "Funnel, last 30 days",
      funnelColumns: { step: "Step", count: "People", fromPrevious: "Of previous step", lost: "Lost" },
      funnelNote:
        "Downloads count each network once a day. The other steps follow the accounts created in the last 30 days and aren't nested: someone can subscribe without a meeting. “First note” counts only meetings held since the server began tracking finished notes.",
      sourcesTitle: "Downloads by button, 30 days",
      sourceColumns: { source: "Button", count: "Downloads" },
      referrersTitle: "Downloads by referring site, 30 days",
      referrerColumns: { host: "Site", count: "Downloads" },
      noDownloads: "No downloads with a source yet.",
      downloadsNote: "Visitors to the website itself are in Cloudflare Web Analytics.",
      cancellationsTitle: "Why people cancel",
      cancellationColumns: { reason: "Reason", count: "Cancellations" },
      noCancellations: "No cancellation reasons yet. They appear once the cancellation reason form is on in Stripe's customer portal.",
      recentCancellationsTitle: "Latest cancellations",
    },
    inboxTitle: "Inbox",
    tabs: { feedback: "Feedback", crash: "Crashes", contact: "Contact" },
    statusOpen: "Open",
    statusDone: "Done",
    empty: "Nothing here.",
    loadMore: "Load more",
    detailEmpty: "Select a report to read it.",
    fields: { received: "Received", email: "Email", user: "User", app: "App version", os: "OS" },
    messageTitle: "Message",
    payloadTitle: "Crash report",
    quotableFilter: "Quotable only",
    quoteTitle: "Quote consent",
    quoteConsent: "May be quoted on gistsmith.com as {name}. Nothing is published until you add it to web/src/testimonials.ts.",
    markDone: "Mark done",
    reopen: "Reopen",
  },
  // Diller: listeler ve sayılar lib/languages.ts'ten (uygulamanın `MeetingLanguage` ve `ShareLanguage` listeleri). Karışık
  // dilli toplantı davranışı: canlı metin tek dil izler (Otomatik'te ana toplantı dili; panelden değiştirilebilir,
  // Deepgram'a `multi` verilmez: DeepgramMessages.swift), nihai metinde Otomatik'te dili ElevenLabs algılar
  // (ElevenLabsDiarizer.swift), sabit dilde başka dildeki cümleler dışarıda kalır (SpokenLanguage.swift), canlı çeviri
  // yalnızca diğer katılımcıların sözlerini çevirir (AppModel.swift).
  languages: {
    meta: {
      title: `${productName} languages: ${spokenLanguages.length} spoken, ${noteLanguages.length} for notes and live translation`,
      description: `${productName} transcribes meetings in ${spokenLanguages.length} languages, including Turkish and Finnish, and writes notes and live translations in ${noteLanguages.length}. See the full lists.`,
    },
    eyebrow: "Languages",
    title: `Meetings in ${spokenLanguages.length} languages. Notes in ${noteLanguages.length}.`,
    lead: `Speak in any of ${spokenLanguages.length} languages and get your note, live translation and answers in any of ${noteLanguages.length}, whatever language the meeting was in. The app itself is available in ${interfaceLanguages.length} languages. Every language is included in the subscription.`,
    stats: [
      { value: String(spokenLanguages.length), label: "languages you can speak in a meeting (live and final transcript)" },
      { value: String(noteLanguages.length), label: "languages for notes, live translation, “What did I miss?” and Ask" },
      { value: String(interfaceLanguages.length), label: "languages for the app itself: menus, settings and messages" },
      { value: "Auto", label: "language detection from the recording, or pick the meeting's language yourself" },
    ],
    spokenTitle: "Languages you can speak",
    spokenLead:
      "The live transcript and the final transcript support these languages. The list holds only languages that every speech engine the app uses supports: the live cloud transcript, the final transcript with speaker separation and the on-device model the Mac falls back to.",
    notesTitle: "Languages for notes and live translation",
    notesLead:
      "Notes, live translation, “What did I miss?” summaries and Ask answers are written in the language you choose in Settings, whichever language was spoken.",
    interfaceTitle: "Languages for the app itself",
    interfaceLead:
      "The app's menus, settings and messages are available in these languages. It follows your Mac's language, and you can pick another one under Interface language in Settings › Recording and languages. This is separate from the languages of your meetings and notes.",
    highlightsTitle: "Turkish and Finnish",
    highlights: [
      {
        title: "Turkish",
        text: "Turkish (Türkçe) is supported both as a spoken language and as a note language. Record a meeting in Turkish and get an English note, or follow an English or Finnish meeting with a live Turkish translation. Azerbaijani is available as a note language too, and the app itself is available in Turkish.",
      },
      {
        title: "Finnish",
        text: `Finnish (Suomi) is supported both as a spoken language and as a note language, the app itself is available in Finnish, and ${productName} is made in Finland. Swedish, Estonian, Norwegian and Danish are supported too.`,
      },
    ],
    mixedTitle: "Meetings with more than one language",
    mixed: [
      {
        title: "One main language at a time",
        text: "Each meeting has a spoken language: choose one, or leave it on Automatic. The live transcript follows one language at a time (your main meeting language in Automatic mode), and you can switch the language from the panel during the meeting.",
      },
      {
        title: "The final transcript detects the language",
        text: "When the meeting ends, the transcript is made again from the recording. In Automatic mode, the speech service detects the language from the audio.",
      },
      {
        title: "A fixed language keeps the record clean",
        text: "If you fix the meeting language, sentences that are clearly in another language are left out of the transcript and the note; the live panel shows them dimmed.",
      },
      {
        title: "Live translation of what others say",
        text: "Live translation translates what the other participants say into your note language within seconds. Your own lines, and lines already in your language, are not translated.",
      },
    ],
    faqTitle: "Questions",
    faq: [
      {
        question: `Does ${productName} support Turkish?`,
        answer: `Yes. Turkish is one of the ${spokenLanguages.length} languages you can speak in a meeting and one of the ${noteLanguages.length} languages notes and live translation can be written in. A Turkish meeting can get an English note, and an English meeting can get a Turkish note or a live Turkish translation. The app itself is available in Turkish too.`,
      },
      {
        question: `Does ${productName} support Finnish?`,
        answer: `Yes. Finnish is supported as a spoken language and as a note language, for the live transcript, live translation, notes and Ask, and the app itself is available in Finnish. ${productName} is made in Finland.`,
      },
      {
        question: "Which languages is the app itself available in?",
        answer: `${languageNameList(interfaceLanguages)}. The app follows your Mac's language; to use another one, pick it under Interface language in Settings › Recording and languages, and it applies when the app restarts. The app's language doesn't limit your meetings: you can still speak in any of ${spokenLanguages.length} languages and get notes in any of ${noteLanguages.length}.`,
      },
      {
        question: "Can one meeting mix two languages?",
        answer:
          "The app follows one main language at a time. In Automatic mode the final transcript detects the language from the recording, and during the meeting you can switch the live transcript's language from the panel. With a fixed language, sentences clearly in another language are left out. If people switch languages sentence by sentence, expect the transcript of the other language to be weaker.",
      },
      {
        question: "Which language is the note written in?",
        answer: `In the note language you choose in Settings, one of ${noteLanguages.length}, whatever language was spoken. The same language is used for live translation, “What did I miss?” and Ask.`,
      },
      {
        question: "Does voice typing work in every language?",
        answer:
          "Voice typing uses your main meeting language. On macOS 26 or later it uses Apple's on-device dictation, which supports the languages Apple offers for dictation on your Mac; on macOS 15 to 25 it uses an on-device speech model that downloads once (about 630 MB). Either way the audio stays on your Mac.",
      },
    ],
  },
  // Entegrasyonlar: her öğe uygulamanın kodunda doğrulandı (AINotepadCore Integrations/Webhook.swift, ChannelAuth.swift,
  // MCPIntegrations.swift, Destinations.swift; App/EventKitConnector.swift, MeetingsPages.swift dışa aktarma menüsü). Hepsi
  // Mac uygulamasından doğrudan hedefe gider, sunucumuzdan geçmez. İki istisna sunucumuz üzerinden Anthropic'e gider
  // (saklanmaz): Linear/Jira iş açan ajan (MCPIntegrations.swift `sendTasksToTracker`, amaç `task_agent`) ve notu
  // paylaşım diline çevirme (App/AppModel.swift `generateSharedNote`, amaç `shared_note_translation`).
  integrations: {
    meta: {
      title: `${productName} integrations: Slack, Teams, Notion, Linear, Jira, webhooks and MCP`,
      description: `Send ${productName} notes to Slack, Teams, Notion or Apple Notes, tasks to Linear or Jira, anything else by webhook, and let your AI apps read meetings over MCP.`,
    },
    eyebrow: "Integrations",
    title: "Your meetings, where your work happens.",
    lead: `Everything ${productName} connects to, and how. Each integration sends from your Mac or iPhone directly to the place you choose, using the account or address you connect. Two steps use our AI model through our server first: creating Linear or Jira issues, and translating a note you send in another language.`,
    groups: [
      {
        id: "notes",
        title: "Notes to your team",
        lead: "Send the finished note to a page or a channel.",
        items: [
          { name: "Slack", text: "Post the note to a channel, through an incoming webhook or by signing in with Slack.", mark: { kind: "brands", brands: ["slack"] } },
          { name: "Microsoft Teams", text: "Post the note to a channel: as a message by signing in with Microsoft, or as a card through a Power Automate or Office webhook.", mark: { kind: "brands", brands: ["teams"] } },
          { name: "Discord", text: "Post the note to a channel, through a webhook or by signing in with Discord.", mark: { kind: "brands", brands: ["discord"] } },
          { name: "Zoom Team Chat", text: "Post the note to a channel through an incoming webhook.", mark: { kind: "brands", brands: ["zoom"] } },
          { name: "Notion", text: "Sign in with Notion and each note becomes a page.", mark: { kind: "brands", brands: ["notion"] } },
          { name: "Apple Notes", text: `Save the note in Apple Notes, in a folder named ${productName}.`, mark: { kind: "brands", brands: ["apple-notes"] } },
        ],
      },
      {
        id: "tasks",
        title: "Tasks to your tracker",
        lead: "Turn the tasks in a note, with their owners and due dates, into work items. For Linear and Jira, our AI model, reached through our server, works out the issue fields; the issues are created from your Mac or iPhone.",
        items: [
          { name: "Linear", text: "Create Linear issues from your tasks after signing in with Linear.", mark: { kind: "brands", brands: ["linear"] } },
          { name: "Jira", text: "Create Jira issues from your tasks after signing in with Atlassian.", mark: { kind: "brands", brands: ["jira"] } },
          { name: "Apple Reminders", text: "Send your tasks to Reminders, with their due dates.", mark: { kind: "brands", brands: ["reminders"] } },
        ],
      },
      {
        id: "webhooks",
        title: "Webhooks for Zapier, Make and n8n",
        lead: "Anything else gets the note through a webhook: a JSON POST to an HTTPS address you set, sent by hand or automatically when each note is ready.",
        items: [
          { name: "Zapier", text: "Use a “Catch Hook” trigger in Webhooks by Zapier, paste its address into the app, and route the note anywhere Zapier reaches, such as a CRM.", mark: { kind: "brands", brands: ["webhook"] } },
          { name: "Make", text: "Use a custom webhook module and paste its address into the app.", mark: { kind: "brands", brands: ["webhook"] } },
          { name: "n8n", text: "Use a Webhook trigger node and paste its production address into the app.", mark: { kind: "brands", brands: ["webhook"] } },
        ],
      },
      {
        id: "files",
        title: "Files and exports",
        lead: "Keep your notes as files you own.",
        items: [
          { name: "Markdown folder", text: "Save every note as a Markdown file to a folder you choose, such as an Obsidian vault or iCloud Drive, by hand or automatically.", mark: { kind: "brands", brands: ["markdown", "obsidian"] } },
          { name: "PDF and Word", text: "Export the note as a PDF or a Word (.docx) document.", mark: { kind: "icon", icon: "note" } },
          { name: "Web page, Markdown and email", text: "Export the note as a web page (HTML), copy it as Markdown or send it by email.", mark: { kind: "icon", icon: "mail" } },
          { name: "Transcript and subtitles", text: "Export the transcript as plain text or as SRT subtitles.", mark: { kind: "icon", icon: "copy" } },
        ],
      },
      {
        id: "mcp",
        title: "Your AI apps, through MCP",
        lead: `${productName} includes a local, read-only MCP server with six tools: list and search meetings, read a meeting's note and transcript, list your tasks, and list and view shared-screen snapshots. Assistants on the web and phone connect through AI assistant access instead.`,
        items: [
          {
            name: "Claude, Cursor and VS Code on your Mac; Claude and ChatGPT online",
            text: "Claude, ChatGPT, Cursor and VS Code can search and read your meetings (on your Mac, or online with AI assistant access); they can never change them. On the Mac, connect with one click in Settings.",
            mark: { kind: "brands", brands: ["claude", "cursor", "vscode"] },
          },
          { name: "Other MCP apps", text: "Any app that supports local MCP servers can connect with the configuration shown on the MCP page.", mark: { kind: "icon", icon: "plug" } },
        ],
      },
      {
        id: "calendar",
        title: "Calendar",
        lead: "The app reads the calendars on your Mac (Apple Calendar, including Google or Exchange accounts you've added to it). Your calendar isn't sent to us.",
        items: [
          { name: "What's next", text: "See upcoming meetings and get a reminder a minute before they start.", mark: { kind: "brands", brands: ["calendar"] } },
          { name: "Start recording on time", text: "If you turn it on, recording starts when a calendar meeting with a call link is running and your call app starts using the microphone.", mark: { kind: "icon", icon: "mic" } },
          { name: "Open tasks from earlier meetings", text: "When you record a meeting from your calendar, the app shows the unfinished tasks from earlier meetings in the same series or with the same people.", mark: { kind: "icon", icon: "check-circle" } },
          { name: "Briefing", text: "Before a meeting, ask for a briefing on what was said in earlier meetings with the same people.", mark: { kind: "icon", icon: "sparkle" } },
        ],
      },
    ],
    webhookExampleLabel: "What a webhook receives (example)",
    webhookExample: `{
  "meeting": {
    "decisions": ["The beta opens on 14 November."],
    "durationMinutes": 42,
    "id": "6F1C…",
    "language": "en",
    "outline": [{ "startSec": 0, "summary": "…", "title": "Beta date" }],
    "startedAt": "2026-11-03T09:00:00Z",
    "summary": "The beta opens on 14 November …",
    "tasks": [
      { "description": "Write the beta release notes", "dueDate": "Friday", "isMine": true, "owner": "Alex" }
    ],
    "title": "Product weekly"
  },
  "text": "# Product weekly …"
}`,
    mcpLink: "How MCP works",
    notBuiltInTitle: "Not built in",
    notBuiltIn: [
      "No native CRM integration (such as HubSpot or Salesforce): send notes there through a webhook with Zapier, Make or n8n.",
      "No direct Google Calendar connection: add your Google account to the Calendar app on your Mac and the app reads it from there.",
      "No shared team workspace: notes live on each person's Mac or iPhone and are shared by sending them to your team's tools.",
    ],
    privacyTitle: "What leaves your Mac or iPhone",
    privacyText:
      "Only what you send, and only to the destination you choose, using the account or address you connected. It does not pass through our server, and the receiving service handles it under its own terms. Two steps are the exception: to create Linear or Jira issues, the tasks, the meeting title and Linear's or Jira's replies go through our server to our AI model provider (named in the privacy policy), and so does a note you translate to send in another language. Our server doesn't store this text. MCP apps on your Mac read your meetings there; what they read is then handled by that app's provider. AI assistant access, off by default, is the one feature that keeps a copy our servers can read: an encrypted copy of your notes in the EU, so the online assistants you connect can read them. Sync and share links, if you use them, keep only end-to-end encrypted copies.",
    faqTitle: "Questions",
    faq: [
      {
        question: `Does ${productName} work with Zapier?`,
        answer: `Yes, through a webhook. Create a Zap that starts with Webhooks by Zapier's “Catch Hook”, paste its address into ${productName}'s webhook settings, and each note arrives as JSON with the title, date, length, language, summary, decisions, tasks (owner, description, due date) and the full note as Markdown. Make and n8n work the same way.`,
      },
      {
        question: `Does ${productName} integrate with HubSpot or Salesforce?`,
        answer: "Not directly. Send each note to a webhook and route it to your CRM with Zapier, Make or n8n.",
      },
      {
        question: "Do integrations go through your servers?",
        answer: "The note or tasks themselves don't. The Mac or iPhone app sends them directly to the destination you chose, using the account or address you connected. Two steps use our AI model provider (named in the privacy policy) through our server, which doesn't store the text: creating Linear or Jira issues (it reads the tasks, the meeting title and Linear's or Jira's replies) and translating a note you send in another language.",
      },
      {
        question: "Can Claude or ChatGPT read my meetings?",
        answer: `Yes. Claude, ChatGPT, Cursor and VS Code can search and read your meetings (on your Mac, or online with AI assistant access); they can never change them. On your Mac, Claude, Cursor and VS Code connect to ${productName}'s read-only MCP server with one click in Settings. Other apps that support local MCP servers can connect with the same configuration. For Claude and ChatGPT on the web or on your phone there is AI assistant access, an online connector you turn on in the app under Settings › Connections. Off by default. Turn it on and an encrypted copy of your notes, never audio, is kept in the EU so the assistants you connect can read them. Turn it off and it is deleted at once (backups within 30 days). Our servers can technically read that copy (it is encrypted at rest, not end to end), and what an assistant reads falls under its provider's policies. The MCP page has the steps.`,
      },
    ],
  },
  // Sesle yazma: her bilgi uygulamanın kodundan. Kısayol ⌃⌥D (KeyBinding.swift `defaultDictateBinding`); basılı tut ya da
  // dokun, eller serbestte yeniden dokun ya da Esc (Dictation.swift, DictationKeys.swift); bir seferde en çok 5 dakika
  // (`dictationMaxListeningSec`); macOS 26+ Apple'ın cihaz içi diktesi (noktalama açık, dinlerken ara metin), macOS 15–25
  // cihaz içi konuşma modeli (~630 MB); ses ve metin hiçbir yere gitmez, saklanmaz; ⌘V ile yapıştırır, pano eski hâline
  // döner ve geçici işaretlenir; Erişilebilirlik izni yoksa panoya kopyalar; parola alanına yazmaz; toplantı kaydı
  // sürerken kapalı; dil ana toplantı dili; giriş yapmış her hesapta ücretsiz ve sınırsız, deneme ve aylık süreden düşmez
  // (VoiceTypingSettings.swift). Yapay zekâyla yeniden yazma ve özel sözlük yok: sayfa bunları vaat etmez.
  voiceTyping: {
    meta: {
      title: `Voice typing for Mac, in any app: free with ${productName}`,
      description: `Hold ⌃⌥D, speak, let go: ${productName} types your words wherever the cursor is, in Mail, Slack, Notes or the browser. Transcribed on your Mac, free and unlimited with any account.`,
    },
    title: "Speak anywhere you'd type.",
    lead: `Hold ⌃⌥D, say it, let go. ${productName} types your words where the cursor is, in any app on your Mac. The audio never leaves your Mac, and it's free with any account.`,
    assurances: ["Free and unlimited", "Transcribed on your Mac", "Any app with a text field"],
    demo: {
      label:
        "Voice typing demo: an email reply is open. The shortcut Control-Option-D is held, a small listening bar with a waveform appears at the bottom and shows the words as they are spoken; when the shortcut is released, the sentence is typed into the email at the cursor.",
      windowTitle: "Re: Thursday's review",
      toLabel: "To",
      to: "Aino Virtanen",
      subjectLabel: "Subject",
      subject: "Re: Thursday's review",
      greeting: "Hi Aino,",
      dictated: "Thanks for the notes. Let's move the review to Thursday at ten, and I'll bring the updated numbers.",
      listening: "Listening",
      shortcut: "⌃⌥D",
      pause: "Pause the demo",
      play: "Play the demo",
      replay: "Play the demo again",
    },
    speed: {
      tone: "Speed",
      title: "Say it in a quarter of the time.",
      lead: `People typically speak around ${typicalSpeakingWpm} words a minute and type around ${typicalTypingWpm}. Here is the same short update, written both ways at those typical rates.`,
      passage:
        "Quick update on the launch: the build is ready, design signed off this morning, and support has the new help articles. The only open item is the pricing page copy, which I'll finish today. If nothing else comes up, we ship on Tuesday as planned.",
      voiceLabel: "Speaking",
      typingLabel: "Typing",
      voiceWpm: typicalSpeakingWpm,
      typingWpm: typicalTypingWpm,
      perMinute: "words a minute",
      replayNote: "Played at {speed}× speed.",
      note: `Typical rates, not a measurement: conversational speech averages roughly ${typicalSpeakingWpm} words a minute, and typing on a keyboard roughly ${typicalTypingWpm}. Your own speeds will differ.`,
      pause: "Pause the comparison",
      play: "Play the comparison",
      replay: "Run the comparison again",
    },
    free: {
      title: "Free and unlimited, with any account.",
      text: "Voice typing is part of every account, subscribed or not. It doesn't use your trial meetings or your monthly hours, and there's no word limit.",
      points: ["No weekly word cap", "Keeps working after the trial", "No subscription needed"],
    },
    useCasesTone: "Everywhere",
    useCasesTitle: "Wherever the cursor blinks.",
    useCases: [
      {
        kind: "email",
        label: "Email",
        title: "Clear the inbox out loud",
        text: "Reply in full sentences instead of three-word answers. Click into the reply, hold the shortcut and talk it through.",
        window: "New message",
        context: ["Jonas Lindqvist", "Contract draft"],
        dictated: "Hi Jonas, I read the draft over lunch. Two points: the notice period should be sixty days, and section four needs the new billing address. Otherwise it's good to sign.",
      },
      {
        kind: "chat",
        label: "Team chat",
        title: "Answer the thread before it moves on",
        text: "A thoughtful reply takes about as long as a thumbs-up. Your words land in the message box, ready to send.",
        window: "# product-launch",
        context: ["Maya", "Can someone sum up where we are with the beta invites?"],
        dictated: "We sent 400 invites yesterday and 130 people have signed up. Both bug reports so far are fixed in today's build.",
      },
      {
        kind: "prompt",
        label: "AI chat",
        title: "Give the assistant the whole picture",
        text: "Spoken prompts come out longer and more specific, and specific prompts usually get better answers. Talk through the context instead of trimming it.",
        window: "New chat",
        context: ["What can I help with?"],
        dictated: "I'm preparing a ten-minute talk for new customers. Draft an outline with five sections, keep the tone friendly, and suggest one question to open with.",
      },
      {
        kind: "doc",
        label: "Docs and notes",
        title: "Get the first draft out of your head",
        text: "Speaking is the fastest way past a blank page. Dictate the draft, then tidy it with the keyboard.",
        window: "Retro notes",
        context: ["Sprint 14 retrospective"],
        dictated: "What went well: the new review rotation halved our waiting time. What to change: we keep starting stories without acceptance criteria, so let's add them at planning.",
      },
    ],
    howTone: "How it works",
    howTitle: "Hold to talk, or tap and talk.",
    modes: [
      { keys: "Hold ⌃⌥D", title: "Hold to talk", text: "It listens while you hold the shortcut and types as soon as you let go. Best for a quick sentence." },
      { keys: "Tap ⌃⌥D", title: "Tap for hands-free", text: "Tap once and keep talking with your hands free. Tap again, or press Esc, to type it. Best for longer replies." },
    ],
    details: [
      { icon: "waveform", title: "See your words as you speak", text: "On macOS 26 or later the listening bar shows the text while you talk, so you know it's keeping up." },
      { icon: "check", title: "Punctuation included", text: "Periods, commas and question marks are added for you. What you say is what gets typed: no rewriting." },
      { icon: "clock", title: "Up to five minutes at a time", text: "Long enough for a detailed email. When you stop, the whole passage is typed in one go." },
      { icon: "grid", title: "Pick your own shortcut", text: "Prefer another key combination? Change it in Settings › Voice typing, or switch voice typing off there." },
      { icon: "copy", title: "Typed by paste", text: "The text goes in with ⌘V, which needs macOS's Accessibility permission. Without it, the text is copied and you paste it yourself." },
      { icon: "lock", title: "Never into password fields", text: "If a password field has focus, nothing is typed and nothing is copied." },
    ],
    privacyTone: "Privacy",
    privacyTitle: "What you say stays on your Mac.",
    privacyLead: "Voice typing hears everything you dictate: client emails, personal messages, notes about people. So it works without a server.",
    privacyPoints: [
      { icon: "laptop", title: "Transcribed on your Mac", text: "The audio is turned into text on your Mac. Neither the audio nor the text is sent to us or to anyone else." },
      { icon: "disk", title: "Nothing is kept", text: "No recording and no history of what you dictated is saved. Voice typing doesn't start a meeting either." },
      { icon: "copy", title: "Your clipboard comes back", text: "After pasting, whatever you had copied before is put back, and the dictated text is marked so clipboard managers skip it." },
      { icon: "shield", title: "Only what you dictate", text: "The Accessibility permission is used only to paste. The app doesn't read your keystrokes, your screen or other apps." },
    ],
    privacyLink: "How voice typing handles data",
    languagesTitle: "Dictate in your meeting language",
    languagesText:
      "Voice typing uses the main meeting language you set in Settings › Recording and languages. On macOS 26 or later it uses Apple's on-device dictation, which covers the languages Apple offers for dictation on your Mac; on macOS 15 to 25 it uses an on-device speech model that downloads once (about 630 MB).",
    languagesLink: "See all languages",
    faqTitle: "Questions",
    faq: [
      {
        question: "Is voice typing really free?",
        answer: `Yes. It works with any ${productName} account once you're signed in, with no word limit, and it doesn't count toward your trial meetings or monthly hours. It keeps working if you never subscribe.`,
      },
      {
        question: "Which apps does it work in?",
        answer: "Any app where you can paste text: Mail, Slack, Messages, Notes, browsers, document and code editors, and AI chat apps. The text is typed where your cursor is. It won't type into password fields.",
      },
      {
        question: "Does my voice leave my Mac?",
        answer: "No. The audio is transcribed on your Mac, and neither the audio nor the text is sent to us or to any provider. Nothing is saved afterwards.",
      },
      {
        question: "Does it clean up what I say?",
        answer: "It adds punctuation and types what you said, without rewriting it. There's no AI rewrite step, which is also why nothing has to leave your Mac.",
      },
      {
        question: "Which languages can I dictate in?",
        answer:
          "Your main meeting language, set in Settings › Recording and languages. On macOS 26 or later, voice typing supports the languages Apple's on-device dictation offers on your Mac; on macOS 15 to 25 it uses an on-device speech model, downloaded once (about 630 MB).",
      },
      {
        question: "Can I change the shortcut?",
        answer: "Yes. The default is ⌃⌥D (Control-Option-D). You can record another shortcut in Settings › Voice typing, then hold it to talk or tap it for hands-free.",
      },
      {
        question: "Can I use it during a meeting?",
        answer: `Not while ${productName} is recording a meeting, because the meeting is using the microphone. It's available again as soon as the recording ends.`,
      },
      {
        question: "Is voice typing on iPhone?",
        answer: "Not yet. Voice typing is part of the Mac app, which runs on Macs with Apple silicon and macOS 15 or later.",
      },
    ],
    ctaTitle: "Your next reply is one sentence away.",
    ctaText: `Download ${productName} for Mac, sign in, and hold ⌃⌥D wherever you'd type.`,
  },
  notFound: {
    meta: { title: `Page not found — ${productName}`, description: "The address may be mistyped, or the page has moved." },
    title: "This page doesn't exist.",
    text: "The address may be mistyped, or the page has moved.",
    home: "Back to the home page",
    linksLabel: "Other pages",
  },
  meetingLink: {
    meta: {
      title: `Open this meeting in ${productName}`,
      description: `This meeting note is in the ${productName} app on your Mac or iPhone.`,
    },
    title: `This meeting is in your ${productName} app`,
    text: `Your AI assistant linked to a meeting note. Notes stay in the ${productName} app on your Mac and iPhone, so they don't open on the web.`,
    openButton: `Open in ${productName}`,
    openHint: `Nothing happened? ${productName} isn't on this device yet. Get it for iPhone or Mac below.`,
    stepsTitle: "Or find it yourself",
    steps: [
      `Open ${productName} on your Mac or iPhone.`,
      "Find the meeting by its title or date in your meetings, or search for it.",
    ],
    ctaTitle: `Don't have ${productName} yet?`,
    ctaText: "Record your meetings and get the notes, decisions and tasks when they end.",
  },
  share: {
    meta: {
      title: `Shared note — ${productName}`,
      description: "A meeting note shared with an end-to-end encrypted link. Only people with the link can read it.",
    },
    loading: "Opening the note…",
    privacyLine: `End-to-end encrypted. Anyone with this link can read the note; ${productName} can't.`,
    showTranscript: "Show transcript",
    errors: {
      incompleteTitle: "This link is incomplete.",
      incomplete: "The part after the # sign is missing or cut short. Ask the sender to copy the whole link again.",
      goneTitle: "This note is no longer shared.",
      gone: "The link has expired, or the person who shared it removed it.",
      wrongKeyTitle: "This link can't open the note.",
      wrongKey: "The key in the link doesn't match. It may have been changed or cut short; ask the sender for the link again.",
      unreadableTitle: "This note can't be shown.",
      unreadable: "It was shared in a format this page doesn't know. Ask the sender to share it again.",
      networkTitle: "The note couldn't be loaded.",
      network: "Check your connection and try again.",
      rateLimited: "Too many requests from this network. Wait a minute and try again.",
      retry: "Try again",
    },
    ownerLine: `Shared by a ${productName} user, who decides who gets the link. {report}`,
    report: "Report this note",
    madeWith: `Made with ${productName}`,
    madeWithLead: tagline,
  },
  privacyMeta: {
    title: `Privacy policy — ${productName}`,
    description: `What data ${productName} processes and why, who it is shared with, how long it is kept and how to use your rights.`,
  },
  termsMeta: { title: `Terms of service — ${productName}`, description: `The terms for using ${productName} and its subscription.` },
};
