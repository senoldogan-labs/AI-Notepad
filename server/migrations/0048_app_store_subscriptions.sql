-- App Store abonelikleri (iPhone uygulaması, RevenueCat üzerinden; src/appStore.ts). Stripe tabloları değişmez: bir hesap
-- iki kaynaktan birinden (ya da ikisinden) abone olabilir, hak ikisinin birleşimidir (src/entitlements.ts).
--
-- Satırı yalnızca RevenueCat eşitlemesi yazar: webhook olayı geldiğinde (ya da uygulama satın almadan sonra
-- `POST /v1/billing/app-store/sync` çağırınca) RevenueCat REST API'sinden (`GET /v1/subscribers/{kullanıcı}`) hesabın güncel
-- abonelik durumu okunur ve satır onunla değiştirilir; olayların sırasına güvenilmez. `synced_at` RevenueCat yanıtının
-- anıdır (`request_date_ms`): daha eski bir okuma daha yenisinin üstüne yazamaz.
--   store: `app_store` ya da `mac_app_store` (RevenueCat'in küçük harfli mağaza adı).
--   product_id: App Store ürün kimliği; plan: ürün kimliği APP_STORE_PRODUCT_MONTHLY / _YEARLY ise `monthly`/`yearly`,
--     tanınmayan üründe null (hak verir, MRR'a girmez).
--   status: okuma anında `active` (yenilenecek), `canceled` (yenilenmeyecek, bitişe dek sürer), `billing_issue` (Apple
--     ödemeyi alamadı; ek süre varsa `grace_expires_at`'e dek erişim), `expired`, `refunded` (Apple iade etti).
--   period_type: RevenueCat'in dönem türü (`normal`, `trial`, `intro`, `promotional`, `prepaid`); `trial` MRR'a girmez.
--   expires_at / grace_expires_at: dönem sonu ve fatura ek süresinin sonu (ms).
--   environment: `PRODUCTION` ya da `SANDBOX` (TestFlight, App Review, sandbox hesapları); sandbox satırı gelire ve abone
--     sayılarına girmez, erişimi REVENUECAT_ACCEPT_SANDBOX'a bağlıdır.
-- Hesap silinince satır silinir (src/account.ts).
CREATE TABLE app_store_subscriptions (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  store TEXT NOT NULL,
  product_id TEXT NOT NULL,
  plan TEXT CHECK (plan IN ('monthly', 'yearly')),
  status TEXT NOT NULL CHECK (status IN ('active', 'canceled', 'billing_issue', 'expired', 'refunded')),
  period_type TEXT NOT NULL,
  purchased_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  grace_expires_at INTEGER,
  environment TEXT NOT NULL CHECK (environment IN ('PRODUCTION', 'SANDBOX')),
  last_event_id TEXT,
  synced_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX app_store_subscriptions_expires ON app_store_subscriptions (environment, expires_at);

-- İşlenmiş RevenueCat webhook olayları (yinelenen teslimat ikinci kez işlenmez; RevenueCat en az bir kez teslim eder ve
-- yeniden denemede aynı `id`'yi gönderir). `outcome`: `synced` (bilinen hesaplar eşitlendi), `unknown_user` (olaydaki
-- kimliklerden hiçbiri bizim hesabımız değil), `sandbox_ignored` (REVENUECAT_ACCEPT_SANDBOX kapalıyken sandbox olayı),
-- `test` (paneldeki deneme olayı). Kullanıcı kimliği tutulmaz; 90 gün tutulur (src/cleanup.ts).
CREATE TABLE revenuecat_events (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  environment TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('synced', 'unknown_user', 'sandbox_ignored', 'test')),
  processed_at INTEGER NOT NULL
);

CREATE INDEX revenuecat_events_processed ON revenuecat_events (processed_at);

-- Günlük anlık görüntüye App Store abonelikleri (src/dailyMetrics.ts; yalnızca PRODUCTION): erişimi süren, yenilenecek
-- aylık ve yıllık abonelikler ve Apple komisyonu düşülmüş MRR (sent). Bu göçten önceki günlerde 0.
ALTER TABLE daily_metrics ADD COLUMN app_store_active INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_metrics ADD COLUMN app_store_monthly INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_metrics ADD COLUMN app_store_yearly INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_metrics ADD COLUMN app_store_mrr_net_cents INTEGER NOT NULL DEFAULT 0;
