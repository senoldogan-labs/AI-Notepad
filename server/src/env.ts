/** Worker bağlamaları: `wrangler.jsonc` değişkenleri, gizli değerler (`wrangler secret put`), D1 ve hız sınırları. */
export interface Env {
  readonly DB: D1Database;
  readonly AUTH_IP_LIMITER: RateLimit;
  readonly API_IP_LIMITER: RateLimit;
  readonly START_USER_LIMITER: RateLimit;
  readonly PROXY_USER_LIMITER: RateLimit;
  readonly REPORT_IP_LIMITER: RateLimit;
  readonly DEEPGRAM_USER_LIMITER: RateLimit;
  /** `POST /v1/telemetry` ve `/v1/telemetry/features`: kullanıcı başına dakikada 6 (ayrıca günde 200, bkz. `telemetry.ts`). */
  readonly TELEMETRY_USER_LIMITER: RateLimit;
  /** `POST /v1/funnel` (ilk açılış hunisi, jetonsuz): IP başına dakikada 20 (bkz. `funnel.ts`). */
  readonly FUNNEL_IP_LIMITER: RateLimit;
  /** `/v1/sync/…` (Mac ↔ iPhone eşitleme): kullanıcı başına dakikada 300 (bkz. `sync.ts`). */
  readonly SYNC_USER_LIMITER: RateLimit;
  /**
   * Eşitlenen şifreli nesnelerin R2 kovası (AB yargı bölgesi; bkz. `sync.ts`). Sunucu yalnızca uçtan uca şifreli
   * blokları saklar: içerik anahtarı kullanıcının cihazlarındadır.
   */
  readonly SYNC_BUCKET: R2Bucket;
  /**
   * Yapay zekâ asistanı erişimi (uzak MCP bağlayıcısı; bkz. `assistant/`): AB D1 veritabanı `gistsmith-assistant`
   * (ayarlar, toplantı dizini, bağlantılar) ve şifreli notların R2 kovası (eşitleme kovası, `a/` öneki). Aynı
   * bağlamalar `gistsmith-mcp` Worker'ında da vardır (`wrangler.mcp.jsonc`). Üretimde sahip AB D1'i oluşturana kadar
   * yoktur (bkz. wrangler.jsonc'deki açılış sırası): `ASSISTANT_POLICY` `off` iken hiçbir asistan adımı onlara dokunmaz,
   * `on` iken eksiklerse `parseConfig` `ConfigError` fırlatır (`assistantStorageOf`).
   */
  readonly ASSISTANT_DB?: D1Database;
  readonly ASSISTANT_BUCKET?: R2Bucket;
  /** `GET /v1/public/shares/:id` (paylaşılan notun şifreli bloğu, oturumsuz): IP başına dakikada 60 (bkz. `shares.ts`). */
  readonly SHARE_IP_LIMITER: RateLimit;
  /** `/v1/assistant/…`: kullanıcı başına dakikada 300 (ilk açılışta arşivin yüklenmesi). */
  readonly ASSISTANT_USER_LIMITER: RateLimit;

  readonly ENVIRONMENT: string;
  readonly SITE_ORIGIN: string;
  readonly APPLE_CLIENT_IDS: string;
  /** Apple geliştirici ekip kimliği (Apple ile giriş istemci sırrının `iss`'i; bkz. `auth/appleTokens.ts`). */
  readonly APPLE_TEAM_ID: string;
  /** Sitenin Apple ile girişte kullandığı Services ID: yetkilendirme kodu bu istemciyle takas edilir ve iptal edilir. */
  readonly APPLE_SIGNIN_CLIENT_ID: string;
  readonly GOOGLE_CLIENT_IDS: string;
  readonly ADMIN_IDENTITIES: string;
  readonly CF_ACCESS_TEAM_DOMAIN: string;
  readonly CF_ACCESS_AUD: string;
  readonly DMG_URL: string;
  readonly APPCAST_URL: string;
  readonly PRICE_USD_MONTHLY: string;
  readonly PRICE_USD_YEARLY: string;
  readonly REFERRAL_POLICY: string;
  readonly SYNC_POLICY: string;
  readonly ASSISTANT_POLICY: string;
  readonly REFERRAL_MAX_PENDING: string;
  readonly REPORT_BYTES_PER_DAY: string;
  readonly APP_ATTEST_POLICY: string;
  readonly APP_ATTEST_ENVIRONMENT: string;
  readonly APP_ATTEST_APP_IDS: string;
  readonly APP_ATTEST_ALLOWED_CATEGORIES: string;
  readonly DEVICECHECK_POLICY: string;
  readonly DEVICECHECK_ENVIRONMENT: string;
  readonly DEVICECHECK_TEAM_ID: string;
  readonly DEVICECHECK_KEY_ID: string;
  readonly TRIAL_MEETINGS: string;
  readonly TRIAL_DAYS: string;
  readonly TRIAL_ACCOUNT_DAILY_TOKENS: string;
  readonly TRIAL_ACCOUNTS_PER_IP_PER_DAY: string;
  readonly TRIAL_MAX_MEETING_MINUTES: string;
  readonly SUBSCRIBER_MAX_MEETING_MINUTES: string;
  readonly MONTHLY_CAP_HOURS: string;
  readonly MEETING_GRACE_MINUTES: string;
  readonly MEETING_PROCESSING_HOURS: string;
  readonly PAST_DUE_GRACE_DAYS: string;
  readonly TRIAL_MEETING_TOKEN_BUDGET: string;
  readonly SUBSCRIBER_MEETING_TOKEN_BUDGET: string;
  readonly MONTHLY_TOKEN_CAP: string;
  readonly MONTHLY_ACCOUNT_TOKEN_CAP: string;
  readonly DAILY_TOKEN_CAP: string;
  readonly MAX_MEETING_STARTS_PER_DAY: string;
  readonly LLM_MAX_TOKENS: string;
  readonly LLM_ACCOUNT_MAX_TOKENS: string;
  readonly LLM_ASK_MAX_TOKENS: string;
  readonly MONTHLY_WEB_SEARCH_CAP: string;
  readonly WEB_SEARCH_POLICY: string;
  readonly LLM_MAX_REQUEST_BYTES: string;
  readonly LLM_MAX_INPUT_TOKENS: string;
  readonly TRANSCRIBE_MAX_BYTES: string;
  readonly TRANSCRIBE_MAX_KEYTERMS: string;
  readonly SCRIBE_USD_PER_HOUR: string;
  readonly SCRIBE_KEYTERMS_USD_PER_HOUR: string;
  readonly ELEVENLABS_MONTHLY_AUDIO_HOURS: string;
  readonly ELEVENLABS_BILLING_DAY: string;
  readonly DEEPGRAM_POLICY: string;
  readonly DEEPGRAM_BUDGET_USD: string;
  readonly DEEPGRAM_USD_PER_MINUTE: string;
  readonly DAILY_SPEND_CEILING_USD: string;
  readonly DAILY_TRIAL_SPEND_CEILING_USD: string;
  /** In-app dialer (`phone/calls.ts`): switch, countries, prices and limits. Production keeps the switch `off`. */
  readonly PHONE_CALLS_POLICY: string;
  readonly PHONE_CALLS_COUNTRIES: string;
  readonly PHONE_CALLER_COUNTRIES: string;
  readonly PHONE_USD_PER_MINUTE: string;
  readonly PHONE_CALL_MAX_MINUTES: string;
  readonly PHONE_MONTHLY_MINUTES: string;
  readonly PHONE_DAILY_SPEND_CEILING_USD: string;
  readonly PHONE_MAX_USD_PER_MINUTE: string;
  readonly PHONE_USER_MONTHLY_SPEND_USD: string;
  readonly REFRESH_TOKEN_DAYS: string;
  readonly STRIPE_PRICE_ID: string;
  readonly STRIPE_YEARLY_PRICE_ID: string;
  /** App Store abonelikleri (iPhone, RevenueCat; bkz. `appStore.ts`): ürün kimlikleri, fiyatlar ve Apple komisyonu. */
  readonly APP_STORE_PRODUCT_MONTHLY: string;
  readonly APP_STORE_PRODUCT_YEARLY: string;
  readonly APP_STORE_PRICE_USD_MONTHLY: string;
  readonly APP_STORE_PRICE_USD_YEARLY: string;
  readonly APP_STORE_COMMISSION_RATE: string;
  /** Sandbox satın alımları (TestFlight, App Review, sandbox hesapları) erişim verir mi: `true` ya da `false`. */
  readonly REVENUECAT_ACCEPT_SANDBOX: string;
  /** Blog yazılarının durduğu GitHub deposu (`sahip/ad`) ve yazıların işlendiği dal (bkz. `blog.ts`). */
  readonly GITHUB_BLOG_REPO: string;
  readonly GITHUB_BLOG_BRANCH: string;
  /** Sitenin Cloudflare Web Analytics verisinin hesabı ve site etiketi (bkz. `siteAnalytics.ts`); boşsa kapalı. */
  readonly CF_ANALYTICS_ACCOUNT_ID: string;
  readonly CF_ANALYTICS_SITE_TAG: string;

  readonly ACCESS_TOKEN_SECRET: string;
  /** Kimlik deneme defteri ve deneme IP özetlerinin HMAC sırrı (erişim jetonu sırrından ayrı). */
  readonly TRIAL_HASH_SECRET: string;
  readonly ANTHROPIC_API_KEY: string;
  readonly ELEVENLABS_API_KEY: string;
  readonly STRIPE_SECRET_KEY: string;
  readonly STRIPE_WEBHOOK_SECRET: string;
  readonly TURNSTILE_SECRET_KEY: string;
  /**
   * RevenueCat webhook'unun `Authorization` başlığının birebir değeri (panelde girilen). Yalnızca
   * `POST /v1/webhooks/revenuecat` okur; yoksa webhook `500` döner (RevenueCat yeniden dener).
   */
  readonly REVENUECAT_WEBHOOK_AUTH?: string;
  /**
   * RevenueCat gizli API anahtarı (v1, `sk_…`): abonelik durumu `GET /v1/subscribers/{kullanıcı}` ile buradan okunur.
   * Yoksa webhook `500`, `POST /v1/billing/app-store/sync` `503 app_store_unavailable` döner.
   */
  readonly REVENUECAT_SECRET_API_KEY?: string;
  /** Yalnızca `DEVICECHECK_POLICY=required` iken gerekir (Apple DeviceCheck .p8 anahtarı, PEM). */
  readonly DEVICECHECK_PRIVATE_KEY?: string;
  /** Yalnızca `DEEPGRAM_POLICY=on` iken gerekir (Deepgram API anahtarı; jeton vermek için, Member ya da üstü yetki). */
  readonly DEEPGRAM_API_KEY?: string;
  /** Yalnızca yerel uçtan uca denemelerde: Anthropic ve ElevenLabs'in sahte yerel adresi (bkz. `upstreamStub.ts`). */
  readonly UPSTREAM_STUB_URL?: string;
  /**
   * Yönetim panelinden blog yayını için GitHub jetonu (yalnızca bu depoda Contents okuma/yazma yetkili ince ayarlı
   * kişisel erişim jetonu). Yoksa blog uçları `503 blog_unavailable` döner.
   */
  readonly GITHUB_BLOG_TOKEN?: string;
  /**
   * Yönetim panelindeki site istatistikleri için Cloudflare API jetonu (yalnızca Account › Account Analytics › Read).
   * Yoksa `GET /v1/admin/site-analytics` `503 analytics_unavailable` döner.
   */
  readonly CF_ANALYTICS_TOKEN?: string;
  /**
   * Apple ile girişin yenileme jetonunu alıp hesap silinince iptal etmek için (bkz. `auth/appleTokens.ts`): Apple
   * Developer → Keys'teki "Sign in with Apple" yetkili anahtarın kimliği, `.p8` içeriği (PKCS#8 PEM) ve jetonu D1'de
   * şifreleyen AES-256 anahtarı (32 baytın base64'ü). Üçü birlikte girilir; hiçbiri yoksa kod ucu
   * `503 apple_tokens_unavailable` döner ve silmede iptal yapılamaz.
   */
  readonly APPLE_SIGNIN_KEY_ID?: string;
  readonly APPLE_SIGNIN_PRIVATE_KEY?: string;
  readonly APPLE_TOKEN_ENC_KEY?: string;
  /**
   * Asistan kopyasının şifreleme anahtarları (`<kimlik>:<32 baytın base64'ü>`, virgülle, en yenisi başta; bkz.
   * `assistant/crypto.ts`). `gistsmith-mcp` ile aynı değer. Yoksa `/v1/assistant/…` `503 assistant_unavailable`.
   */
  readonly ASSISTANT_DATA_KEY?: string;
  /**
   * Twilio Programmable Voice, needed only while `PHONE_CALLS_POLICY=on` (see `phone/twilio.ts` and the dialer spec):
   * account SID (`AC…`), an API key (`SK…` and its secret), the account auth token (webhook signatures) and the TwiML
   * App SID (`AP…`).
   */
  readonly TWILIO_ACCOUNT_SID?: string;
  readonly TWILIO_API_KEY_SID?: string;
  readonly TWILIO_API_KEY_SECRET?: string;
  readonly TWILIO_AUTH_TOKEN?: string;
  readonly TWILIO_TWIML_APP_SID?: string;
}
