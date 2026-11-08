// Yönetim panelinin telemetri verisinin metinleri (İngilizce; yalnızca yönetici görür) ve sunucunun telemetri
// listeleri (yapay zekâ çağrısının amacı, istemci olay türleri, özellik adları, entegrasyon türleri, dışa aktarma
// biçimleri). Listeler sunucuyla birebir aynıdır (`server/src/llm/purpose.ts`, `server/src/telemetry.ts`). Sayfa
// (admin.astro) ve betik (admin-telemetry.ts) aynı nesneyi kullanır; DOM'a dokunmaz.

/** Yapay zekâ çağrısının amacı (`x-llm-purpose`); `unattributed` başlığı göndermeyen eski uygulama sürümleridir. */
export const llmPurposes = [
  "live_translation",
  "missed_summary",
  "live_question",
  "note",
  "note_chunk",
  "note_overview",
  "speaker_review",
  "transcript_translation",
  "note_edit",
  "shared_note_translation",
  "follow_up_email",
  "ask_search_terms",
  "ask_answer",
  "task_agent",
  "connection_test",
  "unattributed",
] as const;
export type LlmPurpose = (typeof llmPurposes)[number];

/** Sayılan istemci olayları: güvenilirlik, "öbür uygulamayı al" tanıtımının adımları ve cihaz içi canlı önizleme. */
export const countEventKinds = [
  "deepgram_socket_drop",
  "deepgram_reconnect",
  "final_pass_give_up",
  "note_generation_failed",
  "recording_overrun",
  "mac_promo_shown",
  "mac_promo_opened",
  "mac_promo_shared",
  "mac_promo_reminded",
  "iphone_promo_shown",
  "iphone_promo_opened",
  "iphone_promo_copied",
  "on_device_live_started",
  "on_device_live_unavailable",
  "on_device_live_failed",
] as const;
export type CountEventKind = (typeof countEventKinds)[number];

/** Süresi ölçülen istemci olayları. */
export const durationEventKinds = ["final_pass_duration", "note_generation_duration"] as const;
export type DurationEventKind = (typeof durationEventKinds)[number];

/** Günlük özellik raporundaki özellik adları (`report`: raporu gönderen kullanıcı-günü, oranların paydası). */
export const featureNames = ["report", "live_translation", "translation_language", "ask", "integration", "export", "mcp", "on_device_live", "dictation", "screen_snapshots", "screen_notes", "sync"] as const;
export type FeatureName = (typeof featureNames)[number];

/** Değeri olmayan (evet/hayır) özellikler; tabloda bu sırayla görünür. */
export const flagFeatures = ["live_translation", "ask", "mcp", "on_device_live", "dictation", "screen_snapshots", "screen_notes", "sync"] as const;
export type FlagFeature = (typeof flagFeatures)[number];

/**
 * Abonelik hunisinin listeleri (`server/src/conversion.ts` ile birebir aynı; Conversion kartı). `platform` sunucunun
 * `x-os-version`'dan çıkardığı değerdir; hatırlatma satırının `kind`'ı `shown`/`tapped`/`opt_in` (sunucu
 * `trial_reminder_` önekini atar), `opt_in`'in kanalı boştur.
 */
export const conversionPlatforms = ["macos", "ios", "unknown"] as const;
export type ConversionPlatform = (typeof conversionPlatforms)[number];
export const conversionTriggers = [
  "trial_note_ready",
  "trial_ending",
  "trial_ended",
  "subscription_required",
  "plan_choice",
  "monthly_warning",
  "monthly_full",
  "win_back",
  "trial_reminder",
  "meeting_start",
] as const;
export type ConversionTrigger = (typeof conversionTriggers)[number];
export const conversionReasons = [
  "products_unavailable",
  "store_error",
  "payment_pending",
  "purchase_not_allowed",
  "network",
  "server",
  "entitlement_timeout",
  "not_signed_in",
  "configuration",
] as const;
export type ConversionReason = (typeof conversionReasons)[number];
export const conversionRestoreResults = ["restored", "nothing_found"] as const;
export type ConversionRestoreResult = (typeof conversionRestoreResults)[number];
export const conversionReminderKinds = ["shown", "tapped", "opt_in"] as const;
export type ConversionReminderKind = (typeof conversionReminderKinds)[number];
export const conversionChannels = ["in_app", "notification", ""] as const;
export type ConversionChannel = (typeof conversionChannels)[number];
export const conversionTiers = ["personal", "pro"] as const;
export type ConversionTier = (typeof conversionTiers)[number];
export const conversionPlans = ["monthly", "yearly"] as const;
export type ConversionPlan = (typeof conversionPlans)[number];
export const checkoutSources = ["app", "web"] as const;
export type CheckoutSource = (typeof checkoutSources)[number];

/** Conversion kartının metinleri. */
export interface ConversionCopy {
  readonly funnelTitle: string;
  /** Kartın başındaki not: yalnızca istatistik paylaşan uygulamalar, alt sınır. */
  readonly lowerBound: string;
  /** Sunucu `conversion` alanını göndermiyor (eski sunucu). */
  readonly notReported: string;
  readonly empty: string;
  readonly funnelColumns: {
    readonly platform: string;
    readonly trigger: string;
    readonly shown: string;
    readonly selected: string;
    readonly started: string;
    readonly completed: string;
    readonly cancelled: string;
    readonly failed: string;
    readonly startRate: string;
    readonly completeRate: string;
  };
  readonly failuresTitle: string;
  readonly restoresTitle: string;
  readonly planMixTitle: string;
  readonly remindersTitle: string;
  readonly upsellsTitle: string;
  readonly checkoutsTitle: string;
  /** Sunucu tarafı sayım: uygulamaların istatistik ayarından bağımsız. */
  readonly checkoutsNote: string;
  readonly columns: {
    readonly platform: string;
    readonly reason: string;
    readonly result: string;
    readonly count: string;
    readonly tier: string;
    readonly plan: string;
    readonly started: string;
    readonly completed: string;
    readonly step: string;
    readonly channel: string;
    readonly trigger: string;
    readonly shown: string;
    readonly tapped: string;
    readonly tapRate: string;
    readonly source: string;
    readonly checkouts: string;
  };
  readonly platforms: Readonly<Record<ConversionPlatform, string>>;
  readonly triggers: Readonly<Record<ConversionTrigger, string>>;
  readonly reasons: Readonly<Record<ConversionReason, string>>;
  readonly restoreResults: Readonly<Record<ConversionRestoreResult, string>>;
  readonly reminderKinds: Readonly<Record<ConversionReminderKind, string>>;
  readonly channels: Readonly<Record<ConversionChannel, string>>;
  readonly tiers: Readonly<Record<ConversionTier, string>>;
  readonly plans: Readonly<Record<ConversionPlan, string>>;
  readonly sources: Readonly<Record<CheckoutSource, string>>;
}

/** Telemetri görünümünün metinleri. `{ad}` yer tutucuları değerlerle doldurulur. */
export interface AdminTelemetryCopy {
  /** `{days}`. */
  readonly windowNote: string;
  readonly versionsTitle: string;
  /** `{users}`, `{days}`. */
  readonly activeUsers: string;
  readonly appVersionsTitle: string;
  readonly osVersionsTitle: string;
  readonly versionColumns: { readonly version: string; readonly users: string; readonly share: string };
  readonly noVersions: string;
  readonly purposesTitle: string;
  readonly purposeColumns: { readonly purpose: string; readonly calls: string; readonly input: string; readonly output: string; readonly webSearches: string; readonly share: string };
  readonly noPurposes: string;
  readonly purposesDailyTitle: string;
  readonly dailyTokenColumns: { readonly day: string; readonly calls: string; readonly tokens: string; readonly trend: string };
  readonly purposes: Readonly<Record<LlmPurpose, string>>;
  readonly reliabilityTitle: string;
  readonly reliabilityColumns: { readonly event: string; readonly total: string; readonly versions: string };
  readonly noEvents: string;
  readonly reliabilityDailyTitle: string;
  readonly dayColumn: string;
  readonly countKinds: Readonly<Record<CountEventKind, string>>;
  /** Günlük olay tablosunun kısa sütun başlıkları. */
  readonly countKindsShort: Readonly<Record<CountEventKind, string>>;
  readonly durationKinds: Readonly<Record<DurationEventKind, string>>;
  readonly durationColumns: { readonly bucket: string; readonly runs: string; readonly share: string };
  /** `{runs}`, `{mean}`. */
  readonly durationSummary: string;
  readonly noDurations: string;
  /** `≤{value}`. */
  readonly bucketAtMost: string;
  /** `>{value}`. */
  readonly bucketOver: string;
  /** `{value}` saniye. */
  readonly seconds: string;
  /** `{value}` dakika. */
  readonly minutes: string;
  readonly featuresTitle: string;
  /** `{reports}`, `{days}`. */
  readonly featureReports: string;
  readonly featureColumns: { readonly feature: string; readonly userDays: string; readonly share: string; readonly uses: string };
  readonly noFeatures: string;
  readonly flagFeatures: Readonly<Record<FlagFeature, string>>;
  readonly languagesTitle: string;
  readonly integrationsTitle: string;
  readonly exportsTitle: string;
  readonly valueColumn: string;
  readonly integrations: Readonly<Record<string, string>>;
  readonly exports: Readonly<Record<string, string>>;
  readonly featuresNote: string;
  readonly conversion: ConversionCopy;
}

/** Telemetri görünümünün metinleri. */
export const adminTelemetryCopy: AdminTelemetryCopy = {
  windowNote: "Last {days} days. Counts are daily totals that are not linked to accounts, except app and OS versions (macOS or iOS), which are the latest values per account.",
  versionsTitle: "Version adoption",
  activeUsers: "Accounts that checked in from the Mac app in the last {days} days: {users}",
  appVersionsTitle: "App versions (active accounts)",
  osVersionsTitle: "OS versions: macOS and iOS (active accounts)",
  versionColumns: { version: "Version", users: "Accounts", share: "Share" },
  noVersions: "No app has reported its version yet.",
  purposesTitle: "AI tokens by purpose",
  purposeColumns: { purpose: "Purpose", calls: "Calls", input: "Input tokens", output: "Output tokens", webSearches: "Web searches", share: "Share of tokens" },
  noPurposes: "No AI calls in this window.",
  purposesDailyTitle: "AI tokens per day",
  dailyTokenColumns: { day: "Day", calls: "Calls", tokens: "Tokens", trend: "Trend" },
  purposes: {
    live_translation: "Live translation",
    missed_summary: "“What did I miss?”",
    live_question: "Question during the meeting",
    note: "Meeting note",
    note_chunk: "Long-meeting note: section",
    note_overview: "Long-meeting note: overview",
    speaker_review: "Speaker review",
    transcript_translation: "Transcript translation (after the meeting)",
    note_edit: "Note edit or rewrite",
    shared_note_translation: "Shared note translation",
    follow_up_email: "Follow-up email draft",
    ask_search_terms: "Ask: search terms",
    ask_answer: "Ask: answer",
    task_agent: "Task tracker agent",
    connection_test: "Connection test",
    unattributed: "Older app versions (no purpose header)",
  },
  reliabilityTitle: "Client events",
  reliabilityColumns: { event: "Event", total: "Total", versions: "By app version" },
  noEvents: "No client events in this window.",
  reliabilityDailyTitle: "Client events per day",
  dayColumn: "Day",
  countKinds: {
    deepgram_socket_drop: "Live transcript connection drops",
    deepgram_reconnect: "Live transcript reconnects",
    final_pass_give_up: "Final transcription gave up",
    note_generation_failed: "Note generation failed",
    recording_overrun: "Recording hit the time limit",
    mac_promo_shown: "iPhone: Mac app banner shown (once per launch)",
    mac_promo_opened: "iPhone: Mac app page opened",
    mac_promo_shared: "iPhone: share sheet for the Mac link opened",
    mac_promo_reminded: "iPhone: Mac app reminder set",
    iphone_promo_shown: "Mac: iPhone app card shown (once per launch)",
    iphone_promo_opened: "Mac: iPhone app page opened",
    iphone_promo_copied: "Mac: App Store link copied",
    on_device_live_started: "On-device live preview started",
    on_device_live_unavailable: "On-device live preview unavailable on the device",
    on_device_live_failed: "On-device live preview stopped mid-meeting",
  },
  countKindsShort: {
    deepgram_socket_drop: "Drops",
    deepgram_reconnect: "Reconnects",
    final_pass_give_up: "Final pass gave up",
    note_generation_failed: "Note failed",
    recording_overrun: "Time limit",
    mac_promo_shown: "Mac banner",
    mac_promo_opened: "Mac page",
    mac_promo_shared: "Mac shared",
    mac_promo_reminded: "Mac reminder",
    iphone_promo_shown: "iPhone card",
    iphone_promo_opened: "iPhone page",
    iphone_promo_copied: "iPhone copied",
    on_device_live_started: "On-device",
    on_device_live_unavailable: "On-device unavailable",
    on_device_live_failed: "On-device stopped",
  },
  durationKinds: {
    final_pass_duration: "Final transcription duration",
    note_generation_duration: "Note generation duration",
  },
  durationColumns: { bucket: "Duration", runs: "Runs", share: "Share" },
  durationSummary: "{runs} runs · mean {mean}",
  noDurations: "No measurements in this window.",
  bucketAtMost: "≤{value}",
  bucketOver: ">{value}",
  seconds: "{value} s",
  minutes: "{value} min",
  featuresTitle: "Feature usage",
  featureReports: "{reports} daily reports (account-days) in the last {days} days. Shares are of these reports.",
  featureColumns: { feature: "Feature", userDays: "Account-days", share: "Share", uses: "Uses" },
  noFeatures: "No feature reports in this window.",
  flagFeatures: {
    live_translation: "Live translation",
    ask: "Ask",
    mcp: "Archive used over MCP",
    on_device_live: "Live transcript ran on the Mac",
    dictation: "Voice typing",
    screen_snapshots: "Shared-screen snapshots",
    screen_notes: "Screen snapshots used in notes",
    sync: "Mac–iPhone sync on",
  },
  languagesTitle: "Live translation target language",
  integrationsTitle: "Integrations by type",
  exportsTitle: "Exports by format",
  valueColumn: "Type",
  integrations: {
    slack: "Slack",
    teams: "Microsoft Teams",
    discord: "Discord",
    webhook: "Webhook",
    notion: "Notion",
    apple_notes: "Apple Notes",
    markdown_folder: "Markdown folder",
    tracker_linear: "Linear (tasks)",
    tracker_jira: "Jira (tasks)",
    tracker_notion: "Notion (tasks)",
  },
  exports: {
    pdf: "PDF",
    html: "HTML",
    markdown: "Markdown",
    docx: "Word (DOCX)",
    transcript_text: "Transcript (TXT)",
    srt: "Subtitles (SRT)",
    copy_markdown: "Copy as Markdown",
    email: "Email",
    pdf_share: "Share PDF",
    link_share: "Share link",
    audio_clip: "Audio clip",
  },
  featuresNote: "Opt-out statistics: only Mac apps with “Share anonymous usage statistics” on send these.",
  conversion: {
    funnelTitle: "Plan screen funnel by platform and moment",
    lowerBound: "Apps with usage statistics on only; lower bound. Billed subscriptions are in Conversion and margin above.",
    notReported: "Not reported: this server doesn't send plan screen statistics yet.",
    empty: "No plan screen events in this window.",
    funnelColumns: {
      platform: "Platform",
      trigger: "Moment",
      shown: "Shown",
      selected: "Plan changed",
      started: "Started",
      completed: "Completed",
      cancelled: "Cancelled",
      failed: "Failed",
      startRate: "Started / shown",
      completeRate: "Completed / started",
    },
    failuresTitle: "Purchase failures",
    restoresTitle: "Restore and plan refresh",
    planMixTitle: "Plan mix",
    remindersTitle: "Trial reminder",
    upsellsTitle: "Upgrade and win-back notices",
    checkoutsTitle: "Stripe checkouts opened (server)",
    checkoutsNote: "Counted by the server for every checkout page it opens, whatever the app's statistics setting.",
    columns: {
      platform: "Platform",
      reason: "Reason",
      result: "Result",
      count: "Count",
      tier: "Tier",
      plan: "Plan",
      started: "Started",
      completed: "Completed",
      step: "Step",
      channel: "Channel",
      trigger: "Notice",
      shown: "Shown",
      tapped: "Tapped",
      tapRate: "Tap rate",
      source: "Opened from",
      checkouts: "Checkouts",
    },
    platforms: { macos: "Mac", ios: "iPhone", unknown: "Unknown" },
    triggers: {
      trial_note_ready: "Trial note ready",
      trial_ending: "Trial ending",
      trial_ended: "Trial ended",
      subscription_required: "Start without a plan",
      plan_choice: "Opened plans",
      monthly_warning: "Near monthly limit",
      monthly_full: "Monthly limit reached",
      win_back: "Win-back",
      trial_reminder: "Trial reminder",
      meeting_start: "Meeting starting",
    },
    reasons: {
      products_unavailable: "Products unavailable",
      store_error: "Store error",
      payment_pending: "Payment pending",
      purchase_not_allowed: "Purchases not allowed",
      network: "Network",
      server: "Server",
      entitlement_timeout: "Subscription didn't arrive",
      not_signed_in: "Not signed in",
      configuration: "Configuration",
    },
    restoreResults: { restored: "Restored", nothing_found: "Nothing found" },
    reminderKinds: { shown: "Shown", tapped: "Tapped", opt_in: "Turned on" },
    channels: { in_app: "In the app", notification: "Notification", "": "—" },
    tiers: { personal: "Personal", pro: "Pro" },
    plans: { monthly: "Monthly", yearly: "Yearly" },
    sources: { app: "Mac app", web: "Website" },
  },
};
