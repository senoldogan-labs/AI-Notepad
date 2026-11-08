Sor cevabı (`ask_answer`) hesap çağrısında `LLM_ASK_MAX_TOKENS` (8192) kullanır ve tek araç olarak web araması isteyebilir (`tools: [{type: "web_search_20260209", name: "web_search", max_uses: 1–3}]`; başka amaçta ya da başka araçta `400 invalid_body`): sunucu aracı doğrudan çağrıyla (`allowed_callers: ["direct"]`) ve kullanıcının aylık `MONTHLY_WEB_SEARCH_CAP` (100) hakkından kalan kadar aramayla ekler, yanıtta `x-web-search: on` ya da hak bittiyse aracı göndermeden `cap_reached`; `WEB_SEARCH_POLICY` `off` ise ya da Anthropic kuruluşta aramayı reddederse (400 `invalid_request_error`; istek bir kez araçsız yinelenir, hak geri verilir, `anthropic_web_search_disabled` alarmı saatte en çok bir kez) `unavailable`; yapılan aramalar (`usage.server_tool_use.web_search_requests`) aylık sayaca (`monthly_usage.web_searches`), amaç toplamına ve arama başına 0,01 $ harcamaya yazılır (`src/llm/webSearch.ts`). Akışsız çağrı 120 sn, akışın ilk baytı 30 sn zaman aşımlıdır |# Gistsmith sunucusu (abonelik sürümü)

Cloudflare Worker + D1. Mac uygulamasının abonelik sürümü kullanıcı anahtarı olmadan çalışır: bu Worker bizim Anthropic
(yalnızca Claude Haiku 5.5) ve ElevenLabs anahtarlarımızla vekillik yapar, ödemeyi Stripe ile alır. Anahtarlar yalnızca
Worker gizli değerlerindedir. Üretim adresi `https://api.gistsmith.com` (özel alan adı; workers.dev ve önizleme
adresleri kapalı, bölgenin WAF kuralı atlanamasın diye); ayrıca yalnızca yönetici API'si sitenin kaynağında,
`https://gistsmith.com/v1/admin/*` rotasında da çalışır (Cloudflare Access için; aşağıda "Yönetici erişimi"). Site
`https://gistsmith.com`. İç adlar (worker, D1,
paket kimlikleri) `ainotepad` adını korur. Plan: `docs/superpowers/plans/2026-10-28-abonelik-surumu.md`.

## Yerel geliştirme

```bash
cd server
npm ci
cp .dev.vars.example .dev.vars        # sahte ya da test anahtarlarıyla doldur; repoya girmez
npm run migrate:local
npm run dev                           # http://localhost:8787
npm run typecheck
npm test                              # Workers çalışma zamanında, gerçek D1 (miniflare); dış servisler sahte
node scripts/fake-upstreams.ts 8798   # yerel uçtan uca deneme: sahte Anthropic ve ElevenLabs (ücretsiz)
npx wrangler dev --port 8797 --var UPSTREAM_STUB_URL:http://127.0.0.1:8798   # üst servisler sahteye gider
```

`UPSTREAM_STUB_URL` yalnızca `ENVIRONMENT=development`'ta ve geri döngü adresiyle (`http://127.0.0.1:<port>`) geçerlidir;
üretimde ayar varsa yapılandırma reddedilir (`src/upstreamStub.ts`).

Gerçek servis testleri (Stripe test modu, Anthropic Haiku) yalnızca açıkça istenirse çalışır:

```bash
AINOTEPAD_SERVER_LIVE_TESTS=1 LIVE_ANTHROPIC_API_KEY=... LIVE_STRIPE_SECRET_KEY=sk_test_... \
  LIVE_STRIPE_PRICE_ID=price_... npx vitest run test/live.test.ts
```

## Gizli değerler (`wrangler secret put <AD> --env production`)

`ACCESS_TOKEN_SECRET` (en az 32 karakter, rastgele), `TRIAL_HASH_SECRET` (en az 32 karakter, rastgele; erişim jetonu
sırrından farklı), `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`, `STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET`, `TURNSTILE_SECRET_KEY` (sitedeki iletişim formu), `DEVICECHECK_PRIVATE_KEY` (yalnızca
`DEVICECHECK_POLICY=required` iken: Apple Developer → Keys'te DeviceCheck yetkili anahtarın `.p8` dosyasının içeriği,
olduğu gibi: `npx wrangler secret put DEVICECHECK_PRIVATE_KEY --env production < AuthKey_XXXXXXXXXX.p8`),
`DEEPGRAM_API_KEY` (yalnızca `DEEPGRAM_POLICY=on` iken: Deepgram konsolunda Member ya da üstü yetkili anahtar; yalnızca
kısa ömürlü jeton vermek için kullanılır), `GITHUB_BLOG_TOKEN` (isteğe bağlı; yönetim panelinden blog yayını, aşağıda
"Blog yayını"; girilmemişse blog uçları `503 blog_unavailable`; girilmişse boşluksuz ve en az 20 karakter olmalı, değilse
her istek `500`), `CF_ANALYTICS_TOKEN` (isteğe bağlı; yönetim panelindeki site istatistikleri, aşağıda "Site
istatistikleri"; girilmemişse uç `503 analytics_unavailable`), `REVENUECAT_WEBHOOK_AUTH` ve
`REVENUECAT_SECRET_API_KEY` (App Store abonelikleri; aşağıda "App Store abonelikleri (RevenueCat)"),
`APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_PRIVATE_KEY` ve `APPLE_TOKEN_ENC_KEY` (Apple ile girişin jeton iptali; üçü birlikte;
aşağıda "Apple ile giriş jetonunun iptali"), `TWILIO_ACCOUNT_SID`, `TWILIO_API_KEY_SID`, `TWILIO_API_KEY_SECRET`,
`TWILIO_AUTH_TOKEN` ve `TWILIO_TWIML_APP_SID` (yalnızca `PHONE_CALLS_POLICY=on` iken; aşağıda "Uygulamadan arama").
`TRIAL_HASH_SECRET` kimlik deneme defterinin, deneme IP özetlerinin ve davet edilenin kart parmak izi özetinin HMAC
sırrıdır (webhook da okur); değiştirilirse defterdeki eski satırlar yeni girişlerle eşleşmez (silinmiş hesabın kimliği
denemeyi yeniden alabilir, eski davetlerin kartları yeniden kullanılabilir). `ACCESS_TOKEN_SECRET`
değiştirilirse yalnızca açık oturumlar düşer. Hız sınırı ve IP özeti IPv6'da adresin /64 önekine göredir.

## Ayarlar (`wrangler.jsonc` → `vars`)

Gizli olmayan ayarlar `vars`'tadır (deneme sayısı, aylık sınır, bütçeler, fiyat kimliği, App Attest politikası…;
türetmeler dosyadaki açıklamalarda). Bu sürümle gelenler:

| Ayar | Anlamı |
|---|---|
| `GOOGLE_CLIENT_IDS` | Google kimlik jetonunda kabul edilen `aud` değerleri (virgülle). Mac uygulaması jetonu site üzerinden aldığı için yalnızca sitenin web istemcisi. |
| `ADMIN_IDENTITIES` | Yönetici API'sine erişen kimlikler, `apple:<sub>` ya da `google:<sub>` (virgülle). Boşsa kimse yönetici değildir. |
| `CF_ACCESS_TEAM_DOMAIN`, `CF_ACCESS_AUD` | Yönetici uçlarının ikinci etkeni: Cloudflare Access ekibi ve panel + yönetici API'sini koruyan Access uygulamasının AUD etiketi (64 onaltılık). AUD boşsa denetim kapalıdır (günlük `cf_access_check_disabled` uyarısı). Bkz. "Yönetici erişimi (Cloudflare Access)". |
| `DMG_URL` | `GET /v1/download/mac` yönlendirmesinin hedefi (https). |
| `STRIPE_PRICE_ID`, `STRIPE_YEARLY_PRICE_ID` | Aynı ürünün aylık (varsayılan) ve yıllık fiyatı. Checkout `plan`'a göre birini kullanır; webhook, iade ve itiraz ikisini de "bizim" sayar; abonelik satırına plan (`monthly`/`yearly`) yazılır. Haklar plana bakmaz. İkisi aynı olamaz. |
| `PRICE_USD_MONTHLY`, `PRICE_USD_YEARLY` | Fiyatlar (Stripe fiyatlarıyla elle aynı tutulur; Stripe çağrılmaz). Aylık: MRR, yıllık davet indirimi tutarı ve davet ödülü (bakiye alacağı). Yıllık: yalnızca MRR (ayda 1/12'si). |
| `REFERRAL_POLICY` | Davet programı: `on` ise abonelere kod verilir ve Checkout kodu kabul eder; `off` ise kod verilmez, kod `503 referral_unavailable` alır; hak kazanılmış bekleyen ödüller yine verilir. Ayrıntı: aşağıda "Davet programı". |
| `REFERRAL_MAX_PENDING` | Davet edenin aynı anda açık tutabileceği en çok davet (3): ödülü bekleyen, son 24 saatte Checkout'a götürülen, son 365 günde kart yüzünden düşen ve son 365 günde kartsız katılıp ücretsiz ayında biten davetler; dolunca kod `409 referral_limit_reached` alır. |
| `MONTHLY_ACCOUNT_TOKEN_CAP` | Abonenin toplantıya bağlı olmayan çağrılarının (Sor, not düzenleme…) aylık token sınırı; `MONTHLY_TOKEN_CAP`'in parçası, ondan büyük olamaz. Toplantı bütçeleri değişmez. |
| `ELEVENLABS_MONTHLY_AUDIO_HOURS`, `ELEVENLABS_BILLING_DAY` | ElevenLabs aylık kredi planının ses saati (Creator: ~110 saat) ve yenilendiği gün (1–28, UTC). Dönem kullanımı `daily_spend.audio_seconds`'tan; %80 ve %95 aşılınca `elevenlabs_capacity_threshold` alarmı, eşik üstündeyken her gün Cron'da `elevenlabs_capacity_high` alarmı; `GET /v1/admin/stats` → `elevenLabs: {cycleStart, usedHours, capHours, percent}`. |
| `CF_ANALYTICS_ACCOUNT_ID`, `CF_ANALYTICS_SITE_TAG` | Site istatistiklerinin Cloudflare hesap kimliği ve Web Analytics site etiketi (32 onaltılık karakter); boşsa `GET /v1/admin/site-analytics` `503 analytics_unavailable`. Aşağıda "Site istatistikleri". |
| `REPORT_BYTES_PER_DAY` | Rapor türü başına (geri bildirim, çökme, iletişim ayrı) tüm kullanıcılar için günlük bayt bütçesi; ayrıca hesap başına günde 20 rapor. |
| `TRIAL_DAYS` | Denemenin süresi (gün); hesabın ilk deneme toplantısıyla başlar. Deneme `TRIAL_MEETINGS` toplantı ya da bu süre, hangisi önce dolarsa. |
| `DAILY_TRIAL_SPEND_CEILING_USD` | Deneme harcamasının (deneme toplantıları + denemedeki toplantı dışı çağrılar) ayrı günlük tavanı; aşılınca deneme harcaması açan her istek (yeni ve açık deneme toplantıları, yeniden işleme, denemedeki hesap çağrısı) `503 trial_capacity_reached` (`daily_trial_spend_ceiling_reached` alarmı, günde bir kez). Aboneler yalnızca `DAILY_SPEND_CEILING_USD`'ye tabidir. |
| `DEVICECHECK_POLICY` | Mac başına ücretsiz deneme (Apple DeviceCheck) için tek anahtar: `required` (üretim) ya da `off` (yerel, testler: DeviceCheck hiç çağrılmaz). Ayrıntı: aşağıda "Deneme kötüye kullanımı". |
| `DEVICECHECK_ENVIRONMENT` | `production` (`api.devicecheck.apple.com`) ya da `development` (`api.development.devicecheck.apple.com`); üretimde `required` iken `production` olmalı. |
| `DEEPGRAM_POLICY` | Deepgram canlı metni için tek anahtar: `on` (üretim) ya da `off` (yerel, testler, acil kapatma: jeton verilmez, `/v1/me` → `liveEngine: "whisperkit"`, uygulama canlı metni Mac'te üretir). Ayrıntı: aşağıda "Deepgram canlı metni". |
| `DEEPGRAM_BUDGET_USD`, `DEEPGRAM_USD_PER_MINUTE` | Ücretsiz Deepgram kredisinin canlı metne ayrılan ömür boyu bütçesi (üretim 185; kredinin kalanı payı) ve akış dakikası fiyatı (Nova-3 çok dilli liste fiyatı 0,0092; temkinli). `GET /v1/admin/stats` → `deepgram: {policy, budgetUsd, estimatedUsd, percent, streamMinutes, meetings, openMeetings, usdPerMinute}`. |
| `GITHUB_BLOG_REPO`, `GITHUB_BLOG_BRANCH` | Blog yazılarının deposu (`sahip/ad`, `senoldogan-labs/AI-Notepad`) ve panelin pull request'lerinin hedef dalı (`main`); yazılar `web/src/content/blog/*.md`. Ayrıntı: aşağıda "Blog yayını". |
| `APPLE_TEAM_ID`, `APPLE_SIGNIN_CLIENT_ID` | Apple ekip kimliği (`79DZ4AA4DW`; istemci sırrının `iss`'i) ve sitenin Apple ile giriş Services ID'si (`com.senoldogan.AINotepad.web`; `APPLE_CLIENT_IDS` içinde olmalı): yetkilendirme kodu bu istemciyle takas edilir. Aşağıda "Apple ile giriş jetonunun iptali". |
| `DEVICECHECK_TEAM_ID`, `DEVICECHECK_KEY_ID` | Yetki JWT'sinin `iss`'i (Apple ekip kimliği) ve `kid`'i (DeviceCheck anahtar kimliği); `required` iken 10 karakterlik Apple biçiminde olmalı (yer tutucu `DEVICECHECK_KEY_ID_PENDING` geçmez). |

Hız sınırları `ratelimits`'tedir (süre 10 ya da 60 sn): `AUTH_IP_LIMITER` (giriş, IP başına 10/dk), `API_IP_LIMITER`
(her uç, 1200/dk), `START_USER_LIMITER` ve `PROXY_USER_LIMITER` (kullanıcı başına), `REPORT_IP_LIMITER` (raporlar, IP
başına 5/dk), `DEEPGRAM_USER_LIMITER` (Deepgram jetonu, kullanıcı başına 10/dk), `FUNNEL_IP_LIMITER` (ilk açılış
hunisi, IP başına 20/dk). Her ortamın kendi `namespace_id`'si
vardır; kimlik hesap genelindedir, bu yüzden API ve MCP Worker'ı arasında da tekrarlanmaz (`test/wranglerConfig.test.ts`). IP sınırı yalnızca kimliksiz sel için kaba bir kapıdır: asıl maliyet kullanıcı başına sınırlardadır
(`PROXY_USER_LIMITER` 120/dk). Aynı NAT ya da operatör CGNAT'ı arkasında canlı çeviri yapan kişi dakikada ~15 istek
attığından 300/dk ~20 kişide 429 veriyordu; 1200/dk ~80 kişiye yeter. Kimliksiz uçlar bu sınırda bile D1 yazımı
harcatamaz: `/v1/health` D1'e dokunmaz, `/v1/download/mac` ağ başına günde bir kez yazar.

Eksik ya da geçersiz bir değer her istekte `500 internal_error` ve `config_invalid` logu verir. Üretimde yer tutucu
kalmışsa da öyledir (`TEAMID…` uygulama kimliği, `placeholder` içeren Google istemci ya da fiyat kimliği, `example.com`
ya da `localhost` adresleri): log `ConfigPlaceholderError` ve ayar adlarını taşır, değerleri değil. Yerelde ve
testlerde yer tutucular geçerlidir.

## Göçler

`migrations/` altındaki SQL dosyaları sırayla uygulanır: yerelde `npm run migrate:local`, üretimde main'e girince
`Deploy server` workflow'u (`.github/workflows/deploy-server.yml`; DROP/RENAME içeren göç elle onay ister). Yeni şema değişikliği yeni bir numaralı dosyadır; uygulanmış dosya değiştirilmez.
`0007` e-posta giriş tablosunu siler ve `auth_identities` tablosunu `google` sağlayıcısına izin verecek biçimde yeniden
kurar (`email` kimliği varsa göç açıkça başarısız olur; üretimde e-posta hiç gönderilmediği için yoktur). `0008`
raporları, indirme sayacını ve istatistik dizinlerini ekler. `0009` kimlik deneme defterini ve kullanıcının devraldığı
deneme sayısı ile Mac doğrulama anını ekler (aşağıda "Deneme kötüye kullanımı"). `0010` denemenin başladığı anı
(`users.trial_started_at`, defterde de) ekler; var olan hesaplar ilk deneme toplantısından, var olan defter satırları
silinme anından doldurulur. `0011` raporların bayt boyunu (`reports.size_bytes`, tür başına günlük bütçe) ekler.
`0012` süreli ayırma satırlarını (`usage_reservations`, aşağıda "Ayırma ve kesinleştirme") ve abonenin toplantı dışı
token sayacını (`monthly_usage.account_tokens`) ekler; eski `*_reserved` sayaç sütunları artık kullanılmaz. `0013`
yenileme jetonunun yerine geçen jetonu (`refresh_tokens.replaced_by`) ekler. `0014` aboneliğin `past_due`'ya geçtiği anı
(`subscriptions.past_due_since`; var olan `past_due` satırları son webhook yazımından) ekler. `0015` giriş kimliklerindeki
e-postaları siler (yeni girişlerde de saklanmaz) ve cihaz saklama temizliği için dizin ekler. `0016` ElevenLabs'e giden
ses saniyesinin günlük toplamını (`daily_spend.audio_seconds`) ekler; sayaç göçle sıfırdan başlar. `0017` Deepgram canlı
metninin toplantı başına jeton sayısını ve bütçe tahminini (`deepgram_live_meetings`) ekler; satırlar silinmez (bütçe
ömür boyu) ve kullanıcıya bağlanmaz. `0018` kimlik defterine o ayın kullanımını (`usage_month`, `usage_seconds`,
`usage_tokens`, `usage_account_tokens`) ve `monthly_usage`'a devralınan süreyi (`carried_seconds`) ekler (aşağıda
"Deneme kötüye kullanımı"). `0032` Deepgram bütçesinin tek satırlık toplamını (`deepgram_budget`, tetikleyicilerle
güncellenir; var olan satırlardan doldurulur) ekler: bütçe denetimi tabloyu taramaz. `0033` "Sorunlar" sayacını
(`ops_events`) ve tavan alarmlarının günlük işaretini (`daily_spend.ceiling_alerted_at`, `trial_ceiling_alerted_at`),
`0034` indirme kaynaklarını (`download_sources`) ve ağ başına günlük tekilleştirmeyi (`download_visitors`), `0035`
toplantının ilk not anını ve hata alanlarını (`meeting_sessions.first_note_at`, `failure_count`, `last_failure_code`,
`last_failure_at`), `0036` Stripe iptal nedenlerini (`subscription_cancellations`), `0040` davet edilenin kart parmak
izi özetini (`referral_redemptions.card_fingerprint_hash`; aşağıda "Davet programı"), `0048` App Store aboneliklerini
(`app_store_subscriptions`), işlenmiş RevenueCat olaylarını (`revenuecat_events`) ve günlük anlık görüntünün App Store
sütunlarını (aşağıda "App Store abonelikleri (RevenueCat)"), `0049` Apple ile girişin şifreli yenileme jetonlarını
(`apple_sign_in_tokens`, Apple kimliğine bağlı; aşağıda "Apple ile giriş jetonunun iptali"), `0051` App Store
aboneliğinin son "yok" okumasının anını (`users.app_store_absent_synced_at`; aşağıda "App Store abonelikleri
(RevenueCat)"), `0055` toplantı duraklatmalarını (`meeting_sessions.paused_ms`, `paused_at`, `pause_extension_ms`,
`pause_count`; aşağıda "Toplantı duraklatma") ekler.

## App Store abonelikleri (RevenueCat)

iPhone uygulaması aynı planları (aylık 5,99 $, yıllık 49 $) otomatik yenilenen App Store abonelikleri olarak RevenueCat
ile satar (`src/appStore.ts`, göç `0048`). Uygulama RevenueCat'te kullanıcıyı bizim hesap kimliğimizle tanıtır
(`Purchases.logIn(userId)`; `app_user_id` = `users.id`). Hak iki kaynağın birleşimidir: Stripe ya da App Store
aboneliği erişim veriyorsa hesap abonedir, Mac ve iPhone aynı hakkı görür (`src/entitlements.ts` → `paidAccess`).

- **Durum REST'ten okunur, olaydan değil.** RevenueCat her webhook olayından sonra `GET /v1/subscribers` ile güncel
  durumun okunmasını önerir; teslimat en az bir kezdir ve sıra garanti değildir. `POST /v1/webhooks/revenuecat` olayı
  yalnızca "bu hesapların durumu değişti" sinyali sayar: aday kimlikler (`app_user_id`, `original_app_user_id`, takma
  adlar, `TRANSFER`'in `transferred_from`/`transferred_to`'su; UUID olmayan anonim kimlikler elenir) içinden bizde var
  olan her hesap için `GET https://api.revenuecat.com/v1/subscribers/{id}` (`Authorization: Bearer
  <REVENUECAT_SECRET_API_KEY>`; 10 sn zaman aşımı, 5xx/429/ağ hatası `upstream_retry` uyarısıyla 3 kez) okunur. App Store
  kayıtlarından (`store` `app_store`/`mac_app_store`) erişimi en geç biten seçilir ve satır onunla değiştirilir; kayıt
  kalmadıysa (satın alma başka hesaba aktarıldı) satır silinir ve okumanın anı hesaba yazılır
  (`users.app_store_absent_synced_at`, göç `0051`). Yanıtın anı (`request_date_ms`) daha yeni bir okumanın üstüne eski bir
  okumanın yazılmasını engeller; aktarımdan önce başlamış eski okuma silinen satırı da yeniden yaratamaz. RevenueCat bu uçta abone yoksa yaratır: yalnızca bizim hesaplarımız
  sorulur.
- **Durum ve erişim:** `active` (yenilenecek; dönem sonu + 24 saat erişim, yenileme olayı gecikirse), `canceled`
  (yenilenmeyecek, dönem sonuna dek), `billing_issue` (dönem sürüyorsa erişim; bittiyse Apple'ın fatura ek süresi
  `grace_period_expires_date`'e dek `grace`), `expired`, `refunded` (iade; erişim yok).
- **Webhook yanıtları:** `Authorization` başlığı `REVENUECAT_WEBHOOK_AUTH` ile sabit zamanlı karşılaştırılır (`401`);
  bozuk gövde `400 webhook_invalid`; işlenmiş olay (`revenuecat_events`, aynı `id`) yeniden işlenmez (`duplicate`);
  `TEST` olayı kaydedilir. Olaydaki kimliklerden hiçbiri bizim hesabımız değilse (silinmiş hesabın yenilemesi,
  uygulamanın `logIn`'siz satın alması) `200` döner (RevenueCat boşuna yeniden denemesin), `revenuecat_unknown_user`
  uyarısı loglanır ve "Sorunlar"a `provider_error`/`revenuecat_unknown_user` sayılır. RevenueCat okunamazsa `502`, olay
  kaydedilmez: RevenueCat yalnızca 200'ü başarı sayar ve 5 kez (~2,5 → 40 dk) yeniden dener. Gizli değerlerden biri
  eksikse `500` ve `revenuecat_webhook_config_invalid` alarmı. Yanıt `{received, outcome, users}`.
- **Uygulamanın eşitlemesi:** `POST /v1/billing/app-store/sync` (bearer, gövde yok, kullanıcı başına 10/dk) satın
  almadan ya da geri yüklemeden hemen sonra aynı okumayı yapar ve güncel `/v1/me` yanıtını döndürür;
  `REVENUECAT_SECRET_API_KEY` girilmemişse `503 app_store_unavailable`.
- **Sandbox (`REVENUECAT_ACCEPT_SANDBOX`):** TestFlight ve App Review satın alımları sandbox'tır ve uygulama üretim
  API'sine bağlanır; bu yüzden üretimde de `true`. Kapalıyken sandbox olayları yok sayılır (`sandbox_ignored`, REST
  çağrılmaz), REST'teki sandbox kayıtları atılır ve var olan sandbox satırları erişim vermez. Sandbox satırları gelire ve
  abone sayılarına girmez; yönetim panelinde `bySource.appStore.sandbox` olarak ayrıca sayılır. Herkese açık TestFlight
  bağlantısı açılırsa ya da kötüye kullanım görülürse `false` yapılır.
- **Ödeme ve hesap:** App Store aboneliği erişim verirken Stripe Checkout açılmaz (`409 app_store_subscription`);
  Stripe'ta bitmemiş aboneliği olmayan, App Store satırı olan hesabın Portal'ı Apple'ın abonelik sayfasıdır
  (`https://apps.apple.com/account/subscriptions`; yayındaki Mac sürümünün "Hesabı yönet"i de oraya gider); Stripe'ta
  yaşayan (`incomplete`, `unpaid`, ek süresi geçmiş `past_due`) abonelik Stripe Portal'ına gider. iPhone'daki satın
  almadan önce açılmış bir Checkout sayfası sonradan ödenirse webhook `stripe_subscription_with_app_store_access`
  alarmı yazar (iade kendiliğinden yapılmaz, sahibi Stripe ödemesini iade eder). Hesap silme App Store aboneliğini
  iptal edemez (yalnızca kullanıcı Apple'da iptal eder): silme yapılır, yanıt kullanıcıya iptal etmesini söyler
  (`DELETE /v1/me`). Davet programı yalnızca Stripe'tır (ödül Stripe bakiyesidir); iPhone'da ödemiş App Store abonesi
  web'de davet kodu kullanamaz.
- **Yönetim paneli:** `GET /v1/admin/stats` → `subscriptions.bySource` Stripe ve App Store'u (yalnızca üretim) ayırır;
  App Store MRR'ı `APP_STORE_PRICE_USD_MONTHLY`/`_YEARLY` fiyatlarıyla ve Apple komisyonu (`APP_STORE_COMMISSION_RATE`,
  Small Business Program: 0,15) düşülerek (net) sayılır, `grossMrrUsd` komisyondan öncedir; toplam `mrrUsd` Stripe liste
  MRR'ı + App Store net MRR'ıdır. App Store ücretsiz deneme dönemindekiler (`period_type = trial`) `trial`'da sayılır,
  plan sayılarına ve MRR'a girmez. Günlük anlık görüntü App Store'u ayrı sütunlarda tutar. Kullanıcı listesi ve
  ayrıntısında erişimi olan App Store abonesinin planı `subscription`'dır (`subscribed` kesiminde; `trial`, `free`,
  `trial_ended` kesimlerinde değil); `subscription` alanı yalnızca Stripe satırını anlatır.

Kurulum (sahibin bir kez yapacakları):

1. **App Store Connect:** Gistsmith iOS uygulamasında "Gistsmith" abonelik grubu; iki otomatik yenilenen abonelik
   `com.senoldogan.gistsmith.monthly` (1 ay, 5,99 $) ve `com.senoldogan.gistsmith.yearly` (1 yıl, 49 $). Small Business
   Program'a kayıt (komisyon 0,15). Uygulama açıklamasına Kullanım Şartları (`https://gistsmith.com/terms`, Apple'ın
   standart EULA'sına bağlantıyla) ve Gizlilik (`https://gistsmith.com/privacy`) bağlantıları. Abonelik bildirimleri
   için App Store Server Notifications V2 adresi RevenueCat'in verdiği adrestir; In-App Purchase anahtarı (`.p8`)
   RevenueCat'e yüklenir.
2. **RevenueCat:** proje ve iOS uygulaması (paket kimliği, In-App Purchase anahtarı); iki ürün; tek hak (entitlement)
   `pro`, iki ürün ona bağlı; uygulamanın açık (public) SDK anahtarı iPhone uygulamasına girer.
3. **RevenueCat webhook:** Project settings → Integrations → Webhooks: adres
   `https://api.gistsmith.com/v1/webhooks/revenuecat`, ortam "Production and Sandbox", "Authorization header value"
   en az 32 karakterlik rastgele bir değer (ör. `Bearer <rastgele>`); aynı değer
   `npx wrangler secret put REVENUECAT_WEBHOOK_AUTH --env production`.
4. **RevenueCat gizli anahtarı:** Project settings → API keys → Secret API key (v1, `sk_…`):
   `npx wrangler secret put REVENUECAT_SECRET_API_KEY --env production`.
5. Göç ve dağıtım (main'e birleşince `Deploy server`); RevenueCat panelinden "Send test event" → `200`, `outcome: "test"`.

## Apple ile giriş jetonunun iptali

Apple, Apple ile giriş sunan uygulamaların hesap silinince kullanıcının jetonlarını Sign in with Apple REST API ile iptal
etmesini ister ("Offering account deletion in your app"; TN3194). Sunucu bunun için Apple'ın yenileme jetonunu saklar
ve yalnızca silmede kullanır (`src/auth/appleTokens.ts`, göç `0049`):

- **Kod:** Apple ile girişte Apple'ın yanıtı kimlik jetonuyla birlikte tek kullanımlık (5 dk) bir yetkilendirme kodu
  taşır (`response_type=code id_token`). Site kodu `POST /v1/auth/apple/authorization-code` ile gönderir: kendi girişinde
  girişle aynı anda, uygulama adına girişte uygulamaya dönmeden önce (uygulamalar değişmedi; dönüş parçasında yine
  yalnızca `idToken` var). Kod uygulama adına girişte hesap oluşmadan geldiği için jeton hesap kimliğine değil Apple
  kimliğine (`sub`) bağlıdır.
- **Takas:** `POST https://appleid.apple.com/auth/token` (`client_id` = `APPLE_SIGNIN_CLIENT_ID`, `grant_type=authorization_code`,
  `redirect_uri` = `<SITE_ORIGIN>/sign-in`, istemci sırrı: ES256 JWT, `kid` = `APPLE_SIGNIN_KEY_ID`, `iss` =
  `APPLE_TEAM_ID`, `sub` = istemci, `aud` = `https://appleid.apple.com`, 5 dk ömür, her çağrıda yeniden üretilir).
  Yanıttaki kimlik jetonunun `iss`, `aud` ve `sub`'u denetlenir; yenileme jetonu AES-256-GCM ile (`APPLE_TOKEN_ENC_KEY`,
  ek veri `sub`) şifrelenip saklanır, aynı kimliğin yeni girişi eskisinin yerine geçer. 5xx, 429 ve ağ hatası
  `upstream_retry` uyarısıyla 3 kez denenir. Takas başarısızsa uç `502` döner ve "Sorunlar"a `provider_error`/`apple_token`
  sayılır; giriş bundan bağımsızdır (site hatayı konsola yazar ve girişi sürdürür). Gizli değerler girilmemişse
  `503 apple_tokens_unavailable` (5xx olarak sayılır).
- **İptal:** `DELETE /v1/me` Stripe'tan sonra, satırlar silinmeden önce saklanan jetonu `POST https://appleid.apple.com/auth/revoke`
  (`token_type_hint=refresh_token`, jetonun verildiği istemciyle) ile iptal eder; Apple geçersiz jetonda da 200 döner,
  tekrar güvenlidir. Kalıcı başarısızlıkta (Apple yanıt vermiyor, gizli değerler kaldırılmış, jeton çözülemiyor) hesap
  yine silinir (silme hakkı), `apple_token_revoke_failed` alarmı loglanır ve "Sorunlar"a `provider_error`/`apple_revoke`
  sayılır: elle takip gerekir (jeton artık yoktur; kullanıcıya Apple Kimliği ayarlarından "Apple ile giriş"i durdurmasını
  söyle). Jeton satırı silme işleminde silinir.
- **Eski hesaplar:** bu sürümden önce Apple ile giriş yapmış hesapların jetonu yoktur; bir sonraki Apple girişinde
  kendiliğinden saklanır. O zamana dek silinirlerse iptal yapılamaz: silme yapılır ve "Sorunlar"a
  `provider_error`/`apple_revoke_no_token` sayılır (Apple'ın yönergesi: kullanıcı Apple Kimliği ayarlarından kendisi
  durdurabilir, https://support.apple.com/en-us/102571).
- **Temizlik:** hesaba bağlanmamış jeton (uygulama adına giriş takastan sonra yarıda kaldı) bir gün sonra silinir.

Kurulum (sahibin bir kez yapacakları):

1. Apple Developer → Certificates, Identifiers & Profiles → Keys → yeni anahtar, "Sign in with Apple" yetkisi, Configure →
   birincil App ID `com.senoldogan.AINotepad.hosted` (Services ID `com.senoldogan.AINotepad.web` bu App ID'ye bağlıdır).
   `.p8` dosyasını indir (bir kez indirilebilir) ve anahtar kimliğini (10 karakter) not et.
2. `npx wrangler secret put APPLE_SIGNIN_KEY_ID --env production` (anahtar kimliği),
   `npx wrangler secret put APPLE_SIGNIN_PRIVATE_KEY --env production < AuthKey_XXXXXXXXXX.p8`,
   `openssl rand -base64 32 | npx wrangler secret put APPLE_TOKEN_ENC_KEY --env production` (değiştirilirse saklanan
   jetonlar çözülemez ve o hesaplar silinirken `apple_revoke` sayılır; sonraki Apple girişinde yenisi saklanır).
3. Göç ve dağıtım: main'e birleşince `Deploy server` ve `Deploy web`.

## Toplantı duraklatma

`POST /v1/meetings/{id}/pause` ve `/resume` (bearer, gövde yok) → `200 {meetingId, paused, expiresAt, pausedSeconds}`:
uygulama kaydı duraklattığı ve sürdürdüğü anda çağırır; zaman yalnızca sunucu saatidir (istemci aralık bildirmez).
Duraklatılan süre ne toplantının süre sınırına ne aylık süreye sayılır. Duraklatılınca toplantının en çok bitişi
(`expiresAt`) kalan duraklatma hakkı kadar ileri alınır (süren duraklatmada toplantının süresi dolmaz); sürdürülünce
duraklatmanın sayılan kısmı kadar ileride kalır. Sayılan duraklatma toplamı en çok toplantının taban süresidir (başlatmada
verilen en çok süre; toplantı en çok bunun iki katı sürer). Toplantı başına en çok 100 duraklatma (`409
pause_limit_reached`); bitmiş, süresi geçmiş ya da sonradan işlenen kayıt `403 meeting_not_active`; başkasının toplantısı
`404 not_found`. Tekrar duraklatma ve duraklatılmamış toplantıyı sürdürme durumu döndürür. Toplantı duraklatılmışken
bitince (ya da yeni toplantı onu kapatınca) duraklatma sayılır; `minutes` kaydedilen (duraklatılmamış) süredir.

Kötüye kullanıma karşı: duraklatmada Deepgram jetonu ya da ses yüklemesi (`/v1/transcribe`) duraklatmayı o anda kapatır
(`meeting_pause_ended_by_audio` uyarısı; uygulama duraklatmada ses göndermez); toplantının ses hakkı taban süreye göredir
(uzatma büyütmez); aylık süre toplantı başına kaydedilen süre ile örtüşmesiz yazılan sesin büyüğüdür (yazıya dökülen ses
her zaman sayılır). Deepgram bütçe tahmini ilk jetondan bitişe duvar saatiyle kalır (temkinli). Bilinen sınır: sunucu
açık Deepgram bağlantısını göremez; duraklatmadan önce açılmış bağlantıdan duraklatmada ses akıtan değiştirilmiş bir
istemci, son geçiş sesini yüklemezse en çok taban süre kadar canlı metni aylık süreye saydırmadan alabilir (toplam duvar
saati 2 × taban süreyle, harcama Deepgram bütçesi ve günlük tavanla sınırlı). Uygulama duraklatmada Deepgram'a ses
göndermez ve jeton istemez (kopan bağlantı kayıt sürünce kurulur). Tanımlar `src/meetingPause.ts`.

## Deepgram canlı metni

`POST /v1/live/deepgram-token` (bearer, `x-meeting-id` başlığı, gövde yok) açık (bitmemiş, ek süre sayılmaz) toplantıya
Deepgram'ın kısa ömürlü jetonunu verir: `{accessToken, expiresIn, model: "nova-3", mipOptOut: true, grantsLeft}`.
Sunucu `POST https://api.deepgram.com/v1/auth/grant`'ı `Authorization: Token <DEEPGRAM_API_KEY>` ve
`{"ttl_seconds": 30}` ile çağırır (5xx/429/ağ hatası uyarıyla 3 kez, sonra `502 upstream_unavailable`); uygulama
`wss://api.deepgram.com/v1/listen`'a `Authorization: Bearer <jeton>` ve `mip_opt_out=true` ile bağlanır. Jeton yalnızca
bağlantı kurulurken geçerli olmalıdır; her bağlantı ve yeniden bağlanma yeni jeton ister: toplantının ilk saatinde en
çok 30 (deneme toplantısında 12), sonra her tamamlanan saat için 15 (denemede 6) fazla (uzun toplantıda kopmalar birikir;
`deepgramGrantLimit`), 5 dakikada en çok 8 (`429 deepgram_grant_limit`). Jeton loglanmaz ve saklanmaz.

Sunucu akışı görmez; harcama temkinli tahmindir: toplantının ilk jetonunda kalan en çok süresi × 2 akış ("Sen" ve
"Diğerleri") peşin sayılır, toplantı bitince (`/end`, yeni toplantının kapattığı toplantı bir sonraki bitişte ya da günlük
Cron'da) ilk jetondan bitişe geçen gerçek süreye indirilir. Tahmin `DEEPGRAM_BUDGET_USD`'ye ulaşınca yeni toplantılar jeton
alamaz (`503 deepgram_unavailable`, `deepgram_budget_exhausted` uyarısı) ve `/v1/me` `liveEngine: "whisperkit"` der;
jeton almış toplantının yeniden bağlanmaları sürer. Bütçeyi en çok bir toplantının penceresi kadar (4 saat × 2 akış ≈
4,4 $) aşabilir. %80 ve %95 aşılınca `deepgram_budget_threshold` alarmı. `DEEPGRAM_POLICY=off` iken de jeton verilmez.

## Uygulamadan arama (iPhone, pilot)

`PHONE_CALLS_POLICY=on` iken (üretimde `off`; tasarım, sağlayıcı seçimi, maliyet ve açma adımları
`docs/superpowers/specs/2026-11-08-iphone-call-recording.md`) `PHONE_CALLS_COUNTRIES`'teki aboneler iPhone'dan Twilio
üzerinden arama yapar; arayan numara yalnızca kullanıcının Twilio'nun arayıp kodla doğruladığı kendi numarasıdır (hesap
başına bir, numara başına bir hesap). Twilio'nun TwiML App'i `POST /v1/phone/webhooks/voice`'u çağırır; sunucu ayırmadaki
hedefe `<Dial>` döner: zaman sınırı, iki kanallı kayıt ve karşı tarafa bağlanmadan önce okunan kayıt duyurusu
(`<Number url>` → `/v1/phone/webhooks/announcement`). Her webhook Twilio imzası (`X-Twilio-Signature`,
`TWILIO_AUTH_TOKEN`) ve hesap kimliği ister, yoksa `403`. Görüşme bitince uygulama kaydı sunucu üzerinden indirir, içe
aktarılan kayıt gibi işler ve Twilio'da siler; alınmayan kayıt bir gün sonra günlük temizlikte silinir.

Harcama: her arama en kötü durumunu (en uzun süre + 1 dk × ülkenin `PHONE_USD_PER_MINUTE`'ı) `phone_calls`'ta ayırır;
ayırma genel günlük tavana (`DAILY_SPEND_CEILING_USD`) ve aramaların günlük tavanına (`PHONE_DAILY_SPEND_CEILING_USD`)
sayılır, arama bitince (`<Dial action>` ya da TwiML App durum geri çağrısı) gerçek maliyetle değişir (`daily_spend.
phone_micro_usd`). Kullanıcı başına aynı anda tek arama, günde 30 arama, ayda `PHONE_MONTHLY_MINUTES` dakika; arama planın
kalan aylık süresini aşamaz. Ücretli ve özel numaralar (NANP 900, 976, 5XX, 700, Karayipler; Fin ve Türk ücretli
önekleri) ve izin listesi dışındaki ülkeler reddedilir; acil ve kısa numaraları uygulama Telefon uygulamasıyla açar.

## Blog yayını

Yönetim panelinin Blog görünümü sitenin blog yazılarını (`web/src/content/blog/<kısa ad>.md`) GitHub üzerinden yönetir
(`src/blog.ts`). Panel `GITHUB_BLOG_BRANCH` dalına doğrudan yazmaz: her yazım (kayıt `blog: <başlık>`, görsel
`blog: image <kısa ad>/<ad>`, silme `blog: remove <kısa ad>`) yazının pull request'ine bir commit'tir, deponun zorunlu
denetimleri (`test-and-build`, `ios`, `server`, `web`) onu dala girmeden önce sınar. Dala giriş sitenin yayın iş akışını
tetikler (`.github/workflows/deploy-web.yml`; ayrıca her gün 06:00 UTC'de derlenir, zamanlanmış yazılar tarihlerinde
yayımlanır). Haftalık akış: yaz → zamanla (gelecek tarihli kaydet) → pull request denetimlerden geçip birleşir → günlük
derleme yayımlar → paylaş (panelde X, LinkedIn, Bluesky); ayrıntı `web/README.md` "Haftalık blog".

- **Pull request:** yazının açık panel pull request'i yoksa yazım dalın başından `blog/<kısa ad>-<YYYYMMDDHHMMSS>`
  (UTC) dalını açar (REST `git/refs`), commit'i GraphQL `createCommitOnBranch` ile beklenen dal başına yazar, pull
  request açar (REST `pulls`, başlık ilk commit'inki) ve otomatik birleştirmeyi (squash) GraphQL
  `enablePullRequestAutoMerge` ile açar (REST'te bu uç yoktur). Açık pull request varsa yazım onun dalına gider ve
  sürüm denetimleri o dalda yapılır; otomatik birleştirme kapalıysa yeniden açılmaya çalışılır. Açık pull request'ler
  dal adından bulunur (başı bu depoda olan, adı kalıba uyan; kayıt tutulmaz: GitHub'da birleştirilen ya da kapatılan
  pull request'in kopyası eskimez, göç gerekmez). Bir yazının iki açık pull request'i varsa yazım `409 blog_conflict`
  (fazlası GitHub'da kapatılır). Dal arada ilerlerse, yeni dal adı alınmışsa ya da pull request commit dalına ulaşmadan
  birleşir/kapanırsa (commit dala dışarıda kalırdı) yazım `blog_write_retry` uyarısıyla yeniden okunup 3 kez denenir,
  sonra `409 blog_conflict`. Otomatik birleştirme açılamazsa (ör. depo ayarında kapalı) yazım yine kaydedilir, yanıt
  `autoMergeError`'da GitHub'ın nedenini taşır, `blog_auto_merge_failed` uyarısı yazılır; panel "yayımlandı" demez.
- **Liste ve okuma:** liste dalın yazılarını, açık ve son birleşen/kapanan panel pull request'lerini tek GraphQL
  isteğiyle okur; açık pull request'lerin yazı sürümleri ikinci bir GraphQL isteğiyle (pull request başına bir takma ad)
  üstüne konur ve yazı `change` alanında o pull request'i taşır. Tek yazı açık pull request'inin dalından okunur.

- **Kurallar** içerik şemasıyla (`web/src/content.config.ts`) aynıdır: başlık 10–90, açıklama 50–170 karakter, yazar boş
  değil, `published` gerçek bir `YYYY-MM-DD` günü, `updated` null ya da `published`'dan önce olmayan gerçek bir gün,
  `cover` null ya da sitenin film ailelerinden biri (`sunset`, `coral`, `ocean`, `mint`, `rose`, `violet`; liste
  `web/src/lib/film.ts` ile aynı, test denetler), `draft` mantıksal, gövde boş değil ve en çok 60 000 karakter, kısa ad
  `^[a-z0-9]+(-[a-z0-9]+)*$` ve en çok 80 karakter. Başlık, açıklama ve yazarda denetim karakteri (satır sonu dahil)
  olamaz; gövdede `\r` ve sekme/satır sonu dışı denetim karakteri olamaz.
- **Dosya biçimi** sabittir: `title`, `description`, `author` JSON kaçışlı çift tırnakta (YAML 1.2'de geçerli), ardından
  `published: YYYY-MM-DD`, doluysa `updated: YYYY-MM-DD` ve `cover: <aile>`, `draft: true|false`, boş satır, gövde
  (baştaki boş satırlar ve sondaki boşluk atılır) ve tek satır sonu. Okurken yalnızca bu yedi alan kabul edilir
  (`updated` ve `cover` isteğe bağlı; bilinmeyen alan kayıtta kaybolmasın diye reddedilir, yazılmış ama geçersiz isteğe
  bağlı alan da); okunamayan dosya `500 blog_post_invalid` (dosya adıyla; site de derlenemez).
- **Sürüm:** güncelleme ve silme panelin açtığı sürümü (`sha`) ister; arada değişmişse hiçbir şey yazılmaz
  (`409 blog_conflict`). Kısa ad yazı varken değişmez (adres sabit kalır).
- **Görseller:** `web/public/blog/<kısa ad>/<ad>.webp` (sitede `/blog/<kısa ad>/<ad>.webp`). Panel tarayıcıda en çok
  1600 px genişliğe küçültüp WebP'ye çevirir; sunucu yeniden denetler: ad `^[a-z0-9-]+\.webp$` ve en çok 80 karakter
  (`400 bad_request`), gövde katı `{data}` standart base64 (`400 invalid_body`), çözülmüş en çok 600 KB
  (`413 payload_too_large`), RIFF/WEBP imzası ve RIFF boyu dosyayla tutmalı, ilk parça `VP8 `/`VP8L`/`VP8X`
  (`415 unsupported_media_type`), genişlik 1–1600 px (`400 invalid_body`). Yazı depoda olmalı (`404 not_found`: klasör
  kısa adla anılır, panel önce kaydettirir); aynı adda görsel varsa `409 blog_image_exists` (görseller değiştirilmez, yeni
  adla yüklenir). Görsel yazının pull request'ine tek commit'tir (`blog: image <kısa ad>/<ad>`).
- **Silme** yazıyı ve görsel klasörünü yazının pull request'inde tek commit'te siler (`blog: remove <kısa ad>`): dalın
  başındaki commit, yazının sürümü ve klasörün dosyaları tek GraphQL isteğiyle aynı commit'ten okunur. Yazı yalnızca açık
  pull request'inde varsa (hiç birleşmemiş) o pull request kapatılır ve dalı silinir (yanıtta `state: "closed"`).
  Klasörde alt klasör varsa `500 blog_post_invalid` (elle temizlenir).
- **GitHub hataları:** 408, 429, 5xx, ağ hatası ve zaman aşımı `upstream_retry` uyarısıyla 3 kez denenir (10 sn zaman
  aşımı), sonra `502 upstream_unavailable`; ret (401, 403, 422…) `502 upstream_rejected` (GraphQL hataları
  `github_graphql_failed` uyarısıyla). GitHub'ın hata gövdesi `github_request_failed` uyarısında loglanır, jeton
  loglanmaz. Kayıt, silme ve görsel yükleme kullanıcı başına dakikada 10'dur (`START_USER_LIMITER`, doğrulamadan sonra).
  Başarılı yazımlar `blog_post_saved` / `blog_post_deleted` (silinen görsel sayısıyla) / `blog_image_saved` pull request
  numarasıyla loglanır.
- **Jeton:** GitHub → Settings → Developer settings → Fine-grained personal access tokens → yalnızca
  `senoldogan-labs/AI-Notepad` deposu, "Repository permissions › Contents: Read and write" ve "Pull requests: Read and
  write" (Metadata: Read kendiliğinden gelir); başka yetki gerekmez. `npx wrangler secret put GITHUB_BLOG_TOKEN --env
  production`. Jetonun süresi dolunca blog uçları `502 upstream_rejected` döner; yenisi aynı komutla girilir. Jeton
  `GITHUB_TOKEN` olmadığı için açtığı pull request CI'ı (`ci.yml`) tetikler. Depoda "Allow auto-merge" açık olmalı
  (`gh api repos/senoldogan-labs/AI-Notepad --jq .allow_auto_merge` → `true`), yoksa yazımlar `autoMergeError` taşır.
  Birleşen `blog/*` dallarının kalmaması için "Automatically delete head branches" önerilir.

## Ayırma ve kesinleştirme

Üst servise giden her çağrı (Anthropic, ElevenLabs) önce en kötü durum miktarını (LLM: tahmini girdi + `max_tokens`;
ses: WAV başlığından ya da FLAC STREAMINFO'sundan kesin süre) tek koşullu ifadeyle `usage_reservations`'a süreli bir satır olarak ayırır; sınırlar
kesinleşmiş kullanım + süresi dolmamış satırlardır. Üst çağrı ve kesinleştirme `waitUntil` ile istemci koparsa da
tamamlanır: gerçek kullanım ve maliyet yazılır, satır silinir. Üst çağrı istek gönderildikten sonra başarısız olursa
kullanıcıya bir şey yazılmaz, tahmini girdi maliyeti (ses tamamen gittiyse ses maliyeti) günlük harcamaya sayılır.
Worker kesinleştiremeden durursa satırın süresi dolar (LLM 15 dk, ses 20 dk): sınırlar onu yok sayar, günlük temizlik
tahmini maliyetini harcamaya ekleyip siler (`usage_reservations_expired` uyarısı). Kullanıcının (tüm toplantılarında)
aynı anda tek ses isteği işlenir; süren varken yenisi `409 transcription_in_progress` alır.

## Deneme kötüye kullanımı

Deneme hesap başına `TRIAL_MEETINGS` toplantı ya da `TRIAL_DAYS` gündür, hangisi önce dolarsa. Süre hesabın ilk deneme
toplantısıyla başlar (`users.trial_started_at`, ilk toplantıyla aynı işlemde yazılır); dolunca kullanılmamış toplantılar
da düşer (`402 trial_exhausted`, `trial_refused` logunda `reason: expired`) ve toplantı dışı yapay zekâ kapanır. Üç ek
engel vardır:

- **Kimlik deneme defteri** (`src/trialLedger.ts`): hesap silinince her giriş kimliği için (`trial-identity:<sağlayıcı>:<sub>`
  metninin `TRIAL_HASH_SECRET` ile HMAC özeti; kimlik açık saklanmaz) harcanan deneme sayısı, denemenin başladığı an
  ve Mac doğrulaması `trial_identity_ledger`'a yazılır. Aynı kimlikle yeniden açılan hesap bunları devralır
  (`users.carried_trial_meetings`, `users.trial_started_at`, `users.trial_device_verified_at`) ve IP sınırına yeni deneme hesabı olarak girmez.
  Defter o ayın (UTC) kullanımını da taşır (süre, token, toplantı dışı token; aynı ay için büyüğü): aynı ay içinde
  yeniden açılan hesap bunu `monthly_usage`'a devralır (süre `carried_seconds` olarak aylık süre sınırına eklenir),
  sonraki ay sıfırdan başlar; silip yeniden açarak aylık sınırlar sıfırlanamaz. Kullanımı olmayan, deneme harcamamış ve
  Mac doğrulamamış hesap için satır yazılmaz. Satır son güncellemeden 730 gün sonra silinir.
- **Mac başına deneme** (`src/deviceCheck.ts`, `DEVICECHECK_POLICY=required`): Apple DeviceCheck her Mac için iki bit
  saklar; sunucu cihaz kimliği görmez. `bit0` = "bu Mac bir hesaba deneme verdi" (`bit1` kullanılmaz, korunur).
  Denemesi henüz bir Mac'e bağlanmamış hesabın deneme toplantısı `deviceCheckToken` ister (`400 device_check_required`);
  `bit0` doluysa `403 trial_device_used`; boşsa Mac işaretlenir ve hesap doğrulanmış sayılır (sonraki deneme
  toplantıları jeton istemez). Apple 400 verirse `400 device_check_invalid`; 5xx/429/ağ hatası uyarıyla 3 kez denenir,
  sonra `502 upstream_unavailable`. Abonelik toplantısı ve denemesi bitmiş hesap DeviceCheck çağırmaz. `off` iken
  DeviceCheck hiç çağrılmaz.
- **IP başına yeni deneme hesabı**: `TRIAL_ACCOUNTS_PER_IP_PER_DAY` (IP'nin HMAC özeti, gün sonunda silinir).

App Attest (`APP_ATTEST_POLICY`) macOS'ta desteklenmediği için bugün cihaz sınırı vermez; kodu yerinde durur. Bu
yüzden davet programındaki cihaz denetimi (`sharesDevice`) de Mac'te eşleşmez (aşağıda "Davet programı"). iPhone
uygulaması (aynı paket kimliği, `com.senoldogan.AINotepad.hosted`) App Attest göndermez: doğrulama (`src/attest/appAttest.ts`)
yalnızca macOS onayını kabul eder (macOS anahtar erişim politikası, `APP_ATTEST_ALLOWED_CATEGORIES` = Developer ID);
iPhone'da cihaz başına deneme DeviceCheck ile sınırlıdır (aynı takım anahtarı, ek ayar gerekmez).

Uygulamalar her isteğe `x-app-version` (ör. `0.1.12 (21)`) ve `x-os-version` (`macOS 15.4.1` ya da `iOS 26.1.0`)
koyar; ikisi birlikte gelmeli, biçimi `src/clientVersions.ts`'te. `GET /v1/me` sonuncularını hesabın satırına yazar;
yönetim panelinin sürüm listesi işletim sisteminin adıyla Mac ile iPhone'u ayırır.

## Davet programı

"Bir ay ver, bir ay al" (`src/referrals.ts`, `src/referralRewards.ts`, göç `0038_referrals.sql`):

- Abonelik erişimi olan hesap (Stripe ya da App Store) `GET /v1/referral` ile kişisel kodunu alır (8 karakter, rastgele, `0 1 I L O` yok).
- Hiç abone olmamış hesap kodla abone olur: istemci kodu `POST /v1/referral/validate` ile denetletir ve Checkout'a
  `referralCode` olarak geçirir. Sunucu kodu yeniden doğrular, Stripe'ta kuponu (yoksa) kendisi açar ve oturuma ekler:
  aylıkta `gistsmith_invite_first_month` (%100, bir kez: ilk ay ücretsiz), yıllıkta `gistsmith_invite_yearly_599`
  (5,99 $, bir kez). Kod aboneliğin `metadata.referral_code`'una yazılır.
- `invoice.paid`: kodla açılan aboneliğin ilk faturası `joined`; ilk sıfırdan büyük ödeme (aylıkta ikinci ay, yıllıkta
  ilk fatura) `qualified` ve 30 gün bekleme. Bu sürede iade (kısmi dahil) ya da itiraz gelirse ödül düşer.
- Günlük Cron günü gelen ödülleri verir: davet edenin Stripe müşterisine `-599` sent (USD) müşteri bakiyesi hareketi
  (`metadata.purpose=referral_reward`); Stripe sonraki faturalarından düşer. Müşteri bakiyesi seçildi çünkü plandan
  bağımsızdır, birden çok ödül birikir ve aboneliği değiştirmez. Çift ödül yok: satır durumu, idempotency anahtarı ve
  çağrıdan önce bakiye hareketlerinde aynı ödül araması.
- Ücretsiz ayında aboneliği biten (Stripe'ta `canceled`/`incomplete_expired`) ya da hesabını silen arkadaşın daveti
  düşer (`void`/`canceled_before_payment`): davet edenin "bekleyen" sayısında ve tahmini ödül tarihinde kalmaz.
- Kötüye kullanım:
  - Kendi kodu `403 referral_self`. App Attest cihazını paylaşan hesaplar da `referral_self` alır (`sharesDevice`), ama
    App Attest macOS'ta desteklenmediği için bu denetim Mac'te hiç eşleşmez: Mac'te aynı bilgisayarda açılan yeni
    Google/Apple hesaplarını cihaz denetimi durdurmaz. Onları aşağıdaki kart denetimi ve açık davet sınırı karşılar.
  - Daha önce abonelik ya da ücretsiz erişim satırı olan hesap (ücretsiz erişimin süresi dolsa ya da yönetici kaldırsa
    da satır kalır), iPhone'da ödemiş App Store abonesi (üretim ortamı, deneme dönemi dışında; bitmiş olsa da) ya da
    aynı giriş kimliğiyle (hesap silinmiş olsa da; kimlik özeti 730 gün) daha önce davetle abone olmuş kimlik
    `409 referral_not_eligible`.
  - Kodun sahibi kod paylaşabilmeli: abonelik erişimi var ve kendisi davetin ücretsiz ilk ayında değil (ilk ücretli
    faturası ödenmeden kodu yoktur ve kodu `404 referral_invalid` alır): ücretsiz aylar hesaptan hesaba zincirlenemez.
  - Kart: kodla açılan aboneliğin ilk faturası ödenince (`invoice.paid`) aboneliğin varsayılan ödeme yönteminin kart
    parmak izi okunur ve `TRIAL_HASH_SECRET` ile HMAC özeti saklanır (göç `0040`; parmak izi açık saklanmaz). Kart davet
    edenin Stripe'ta kayıtlı kartlarından biriyse ya da davet edenin kendi davetindeki kartsa `void`/`self_card`, başka
    bir davette kullanılmışsa (herhangi bir davet eden) `void`/`card_reused`: ödül verilmez, arkadaşın Stripe'ta aldığı
    indirim geri alınmaz. Ödeme yöntemi kart değilse (ör. Link) denetim yapılamaz (`referral_join_without_card`
    uyarısı; yönetim panelinde "kart denetlenmedi").
  - Açık davet sınırı `REFERRAL_MAX_PENDING` (3): ödülü bekleyen (`joined`, `qualified`), son 24 saatte Checkout'a
    götürülen, son 365 günde kart yüzünden düşen ve son 365 günde kartsız (ör. Link) katılıp ücretsiz ayında biten
    (`canceled_before_payment`) davetler sayılır; dolunca kod yeni arkadaşa `409 referral_limit_reached` döner. Böylece
    tek kod ve tek kartla (ya da kartsız ödeme yöntemiyle) açılan hesaplar sınırsız ücretsiz ay alamaz.
  - Davet eden son 365 günde en çok 12 ödül (`capped`); doğrulama kullanıcı başına dakikada 10.

## Site istatistikleri

Yönetim panelinin "Trends" görünümü sitenin Cloudflare Web Analytics toplamlarını (son 30 gün: sayfa görüntüleme,
ziyaret, günler, en çok açılan sayfalar, yönlendiren siteler) Cloudflare GraphQL API'sinin
`rumPageloadEventsAdaptiveGroups` veri kümesinden okur (`src/siteAnalytics.ts`; yeni veri toplanmaz). Sahibin bir kez
yapacakları: Cloudflare panelinde My Profile › API Tokens › Create Token › Custom: yalnızca Account › Account Analytics ›
Read (hesap: gistsmith.com'un hesabı); `npx wrangler secret put CF_ANALYTICS_TOKEN --env production`. Hesap kimliği
(panelde hesabın Overview sayfası) ve Web Analytics › gistsmith.com sitesinin GraphQL `siteTag` değeri (işaretçi
betiğindeki jetonla karıştırma; sahte bir değerde uç `502` ve Cloudflare'in hata mesajı loglanır) `wrangler.jsonc` → `env.production.vars` →
`CF_ANALYTICS_ACCOUNT_ID`, `CF_ANALYTICS_SITE_TAG`'e yazılır. Biri eksikse yalnızca o bölüm "Not configured" gösterir;
Cloudflare hatası (ör. yetkisiz jeton) `502 upstream_unavailable` ve `site_analytics_failed` logu verir.

## Günlük anlık görüntü ve gerçek gelir

Cron her gece biten UTC gününün toplamlarını ve gün sonundaki durumu `daily_metrics`'e yazar (`src/dailyMetrics.ts`;
`daily_metrics` adımı): hesaplar, aktif kullanıcılar (gün, 7 ve 30 gün; toplantı başlatan), toplantılar, denemeler,
plan ve duruma göre abonelikler, liste fiyatıyla MRR, sağlayıcıya göre harcama (Anthropic `daily_spend.llm_micro_usd`,
ElevenLabs farkı, Deepgram gün içinde ilk jetonu alan toplantıların bütçeye sayılan akışı) ve para birimine göre
faturalanan MRR (`daily_revenue_metrics`). Gerçek gelir Stripe webhook'undan gelir (`src/revenue.ts`): `invoice.paid`
bizim müşterimizin abonelik faturasını `revenue_invoices`'a (tahsilat, vergisiz toplam, indirim, vergi, para birimi)
yazar ve hesabın ilk ücretli ödeme anını `subscriptions.first_paid_at`'e koyar; `charge.refunded` kayıtlı faturanın
birikimli iadesini `revenue_refunds`'a yazar. Hesap silinince gelir satırlarının hesap bağı kalkar. Bu kayıtlardan önceki
günler ve faturalar boştur (geriye dönük doldurma yok).

## Zamanlanmış temizlik

`wrangler.jsonc` → `triggers.crons` her gün 03:17 UTC'de `scheduled` işleyicisini çalıştırır (`src/cleanup.ts`). Silinenler:
süresi dolmuş ayırmalar (tahmini maliyeti harcamaya yazılarak), süresi dolmuş nonce'lar (Apple ve Google), süresi dolmuş
ya da kullanılmış cihaz meydan okumaları, süresi dolmuş ya da ailesi düşürülmüş yenileme jetonları (kullanılmış jetonlar
ve geçersiz yazılmış halef çalınma algılaması için süresi dolana dek kalır) ve jetonu kalmamış aileler, 90 günden eski Stripe olayları ve günlük harcama, bugünden eski deneme
başlangıçları, 2 günden eski kullanıcı günlük kullanımı, 13 aydan eski toplantılar (deneme toplantıları önce
`users.carried_trial_meetings`'e eklenir: deneme hakkı geri gelmez) ve aylık kullanım, 13 aydır kullanılmayan cihazlar,
180 günden eski raporlar (durumundan bağımsız), 730 gündür güncellenmemiş kimlik deneme defteri satırları ve hesabı
silinmiş davet edilenlerin davet satırları, bir günden eski ve hesaba bağlanmamış Apple ile giriş jetonları; 400 günden eski günlük token kovaları, konuşma tanıma dilleri ve indirme
kampanyaları; süresi dolmuş paylaşım bağlantıları (`note_shares`; okuma ucu süresi dolanı zaten 404 döner); 5 yıldan eski günlük anlık görüntüler; 10 yıldan eski gelir kayıtları (önce iadeleri). Aynı Cron günü gelen davet ödüllerini de verir (`referral_rewards` adımı).
`phone_cleanup` adımı (`src/phone/calls.ts`): ayırması dolmuş kesinleşmemiş aramalar (bağlanmamışsa ücretsiz, bağlandıysa
en kötü durumla), bir günden eski alınmamış arama kayıtları ve sırada bekleyen Twilio silmeleri (silinen hesapların
kayıtları ve arayan numaraları); Twilio adımları yalnızca `PHONE_CALLS_POLICY=on` iken çalışır; 90 günden eski
kesinleşmiş arama satırları silinir.
İndirme sayacı (gün başına tek satır, kişisel veri yok) silinmez. Silme tablo başına 1000 satırlık en çok 3 turdur; kalan
ertesi gün silinir (`cleanup_incomplete` uyarısı). Her adım ayrı denenir: biri başarısız olursa `cleanup_failed` alarmı
yazılır, diğerleri çalışır ve sonunda `CleanupFailedError` fırlatılır. Yerelde: `npx wrangler dev --test-scheduled`, sonra
`curl "http://localhost:8787/__scheduled?cron=17+3+*+*+*"`.

## Yönetici erişimi (Cloudflare Access)

Yönetici uçları (`/v1/admin/*`) iki etken ister: `ADMIN_IDENTITIES`'teki hesabın oturum jetonu ve Cloudflare Access'in
imzalı jetonu (`Cf-Access-Jwt-Assertion`; `src/auth/access.ts` ekibin anahtarlarıyla, `aud` = `CF_ACCESS_AUD` ve süreyle
doğrular). Panel (`https://gistsmith.com/admin`) yönetici API'sini sitenin kendi kaynağından çağırır
(`https://gistsmith.com/v1/admin/*`, üretimde bu Worker'ın rotası; `web/src/config.ts` → `adminApiBase`). Tek bir Access
uygulaması iki yolu birlikte korur: tarayıcı Access çerezini aynı kaynağa kendiliğinden gönderir, Access de her isteğe
jetonu ekler. `api.gistsmith.com/v1/admin/*`'e doğrudan gelen istek Access'ten geçmez ve AUD doluyken 403 alır. Access
oturumu bitince panelin istekleri Access girişine yönlendirilir; panel "sayfayı yeniden yükle" der (`AccessSessionError`).

Kurulum (Cloudflare panosu, bir kez):

1. Zero Trust → Settings → Authentication → Login methods: "One-time PIN" açık olsun (ya da Google kimlik sağlayıcısı).
   Önerilen (hesapta varsa): Access'in giriş yönteminden bağımsız MFA'sını (Independent MFA) açıp kimlik doğrulayıcı
   uygulama ya da güvenlik anahtarı kaydet; böylece ikinci etken Google oturumundan da bağımsız olur.
2. Zero Trust → Access → Applications → Add an application → Self-hosted. Ad: `Gistsmith admin`. Session duration:
   24 hours. Public hostname'ler (iki hedef, aynı uygulama): `gistsmith.com` + yol `admin` ve `gistsmith.com` + yol
   `v1/admin`.
3. Policy: Action `Allow`, Include → Emails → sahibin e-postası (yalnız o). Independent MFA açıksa uygulamada da
   zorunlu kıl.
4. CORS ayarı gerekmez: panelin istekleri aynı kaynaktandır.
5. Kaydet; uygulamanın Overview sekmesindeki "Application Audience (AUD) Tag" değerini kopyala.
6. `https://gistsmith.com/admin`'i aç: önce Access girişi, sonra Google ile giriş; panelin yüklendiğini doğrula (AUD
   henüz boşken de çalışır).
7. AUD'yi `wrangler.jsonc` → `env.production.vars.CF_ACCESS_AUD`'ye yaz, PR'la main'e birleştir (`Deploy server`
   yayınlar). Bundan sonra Access jetonu olmayan yönetici isteği 403'tür.

Sıra önemlidir: AUD Access uygulaması kurulmadan yazılırsa panel kilitlenir. Kilitlenirsen AUD'yi boşaltan PR yeterlidir
(ya da acil durumda `npx wrangler rollback --env production`).

## İlk dağıtım (sahibin bir kez yapacakları)

Yalnızca hesap ve veritabanı ilk kez kurulurken elle yapılır; sonraki her yayın main'e birleşince `Deploy server`'la olur.

1. `npx wrangler login`
2. `npx wrangler d1 create ainotepad-production` → çıkan `database_id`'yi `wrangler.jsonc` → `env.production` içine yaz.
3. `wrangler.jsonc` → `env.production`:
   - `routes`: `api.gistsmith.com` özel alan adı (gistsmith.com bölgesi aynı Cloudflare hesabında olmalı; dağıtımda
     DNS kaydı ve sertifika kendiliğinden kurulur) ve `gistsmith.com/v1/admin/*` bölge rotası (yalnızca yönetim paneli;
     dağıtım jetonunda gistsmith.com için "Workers Routes: Edit" gerekir). `workers_dev` ve `preview_urls` üretimde
     `false`'tur: Stripe webhook'u ve uygulamalar yalnızca `api.gistsmith.com`'u kullanmalı.
   - `vars`: `SITE_ORIGIN` (`https://gistsmith.com`), `APP_ATTEST_APP_IDS` (`TEAMID.com.senoldogan.AINotepad.hosted`),
     `STRIPE_PRICE_ID`, `GOOGLE_CLIENT_IDS` (Google Cloud Console → sitenin OAuth web istemcisi), `DMG_URL`,
     `PRICE_USD_MONTHLY` (Stripe fiyatıyla aynı), `REPORT_BYTES_PER_DAY`. `APPLE_CLIENT_IDS` hazırdır:
     `com.senoldogan.AINotepad.hosted` (abonelik uygulamasının paket kimliği) ve `com.senoldogan.AINotepad.web` (sitenin
     Apple ile giriş Services ID'si; bkz. `web/README.md`).
   - `ADMIN_IDENTITIES` önce boş kalır. Dağıtımdan sonra sitede kendi hesabınla giriş yap; kimliğin (`google:…` ya da
     `apple:…`) D1'de: `npx wrangler d1 execute ainotepad-production --remote --env production --command
     "SELECT provider || ':' || subject FROM auth_identities WHERE user_id = '<kullanıcı kimliği>'"` (kullanıcı kimliği
     giriş yanıtındaki `userId` ya da `admin_forbidden` uyarısındaki `userId`); onu yazıp main'e birleştir (`Deploy server` yayınlar).
4. Yukarıdaki gizli değerleri `wrangler secret put … --env production` ile gir.
5. `npm run migrate:production`
6. `npm run deploy`
7. Stripe panelinde webhook uç noktası: `https://api.gistsmith.com/v1/billing/webhook`, olaylar
   `customer.subscription.created|updated|deleted|paused|resumed`, `customer.deleted`, `charge.refunded`,
   `charge.dispute.created`, `invoice.paid` (kopya aboneliğin geç ödemesi ve davet ödülü); imza sırrını `STRIPE_WEBHOOK_SECRET` yap.
   Davetin kart denetimi için webhook'un anahtarı abonelikleri (`default_payment_method` genişletilmiş), ödeme
   yöntemlerini ve müşterinin ödeme yöntemleri listesini okuyabilmelidir (kısıtlı anahtarda "Payment Methods: Read"). Canlıya geçerken anahtar (`sk_live_`/`rk_live_`)
   ve canlı moddaki webhook birlikte değişmeli: olayın modu anahtarınkiyle uyuşmazsa webhook `500` ve
   `stripe_mode_mismatch` alarmı verir; anahtarın modu `GET /v1/admin/stats` → `stripe.mode`'dadır.
   Stripe Tax'i ve Müşteri Portalı'nı panelden aç.
8. `curl https://api.gistsmith.com/v1/health` → `{"status":"ok"}`
9. Önerilen: Cloudflare panelinde `api.gistsmith.com` ve `gistsmith.com/v1/admin/*` için bir WAF hız sınırı kuralı.
   Workers Free planının hesap genelindeki günlük 100 000 istek ve D1 yazma kotası Worker'ın kendi hız sınırlarından önce
   tükenebilir (fatura değil, kesinti riski). Yönetici rotası Access uygulaması kurulunca Access'in arkasındadır: girişi
   olmayan istek Worker'a ulaşmaz.

## Uçlar

| Uç | Kimlik | Not |
|---|---|---|
| `GET /v1/health` | — | |
| `POST /v1/auth/apple` | — | `{identityToken, nonce}`; Apple'a `sha256hex(nonce)` verilir; e-posta saklanmaz |
| `POST /v1/auth/apple/authorization-code` | — | `{code}` (Apple'ın yetkilendirme kodu; site gönderir); kodu Apple'da takas eder, yenileme jetonunu şifreli saklar, `200 {stored: true}`; Apple reddederse `502 upstream_rejected`, yanıt vermezse `502 upstream_unavailable`, gizli değerler yoksa `503 apple_tokens_unavailable`. Yukarıda "Apple ile giriş jetonunun iptali" |
| `POST /v1/auth/google` | — | `{identityToken, nonce}`; Google'a `sha256hex(nonce)` verilir. `iss` `https://accounts.google.com` ya da `accounts.google.com`, `aud` ∈ `GOOGLE_CLIENT_IDS`, RS256, nonce tek kullanımlık. Kimlik `google:<sub>`; e-posta saklanmaz. Apple hesabıyla otomatik bağlama yoktur (ayrı kullanıcı). Oturum yanıtı ve deneme kuralları Apple ile aynı |
| `POST /v1/auth/refresh`, `/v1/auth/logout` | — | `{refreshToken}`; dönen jeton, yeniden kullanım aileyi düşürür; yalnızca hemen önceki jeton 10 dk içinde yeniden sunulursa ve halefi hiç kullanılmadıysa (yanıtı kaybolan yenileme) yeni çift verilir; kaybolan halef geçersiz işaretlenir, sonradan sunulursa tüm aile düşer. Kullanılmış jetonların özetleri süresi dolana dek (60 gün) tutulur: ailenin daha önce kullanılmış herhangi bir jetonu (saldırgan çalınan jetonu art arda döndürmüş olsa da) yeniden gelirse aile düşer ve `refresh_token_reuse` alarmı yazılır |
| `GET /v1/me` | Bearer | plan, etkin kalan deneme (isteğe bağlı `x-device-key-id` ile hesap ve cihazın küçüğü; süre dolduysa 0), `trialDays`, `trialEndsAt` (ilk deneme toplantısı + `TRIAL_DAYS`, ISO 8601; deneme başlamadıysa ya da abonelikte `null`), aylık saat ve sınır, `monthlyResetsAt` (aylık sınırların sıfırlandığı an: sonraki UTC ayının başı), toplantı dışı yapay zekâ hakkı (`accountTokensUsed`, `accountTokensCap`, `accountTokensPeriod`: abonede `month` ve `MONTHLY_ACCOUNT_TOKEN_CAP`, denemede `day` ve `TRIAL_ACCOUNT_DAILY_TOKENS`; `accountTokensResetsAt`), `liveEngine` (`deepgram` / `whisperkit`, bkz. "Deepgram canlı metni"), abonelik erişimi (`active` / `grace` / `none`) ve planı (`subscription.plan`: `monthly` / `yearly`; fiyatı tanınmayan eski abonelikte `null`); `subscription.source` (`stripe` / `app_store`: asıl abonelik, bkz. "App Store abonelikleri"), `subscriptionSources` (erişim veren kaynaklar) ve `appStoreSubscription` (`{status, plan, productId, access, expiresAt, willRenew, graceEndsAt, environment, manageUrl}` ya da `null`) |
| `DELETE /v1/me` | Bearer | hesabı siler (GDPR), `200 {deleted: true, appStoreSubscription, notice}` (`appStoreSubscription`: erişimi süren App Store aboneliği varsa `{willRenew, expiresAt, manageUrl}` ve İngilizce `notice` — Apple aboneliği silmeyle iptal olmaz, kullanıcı iPhone'da iptal etmeli; yoksa ikisi `null`; 0.1.12 ve öncesi 204 bekler ama her 2xx'i kabul eder): önce Stripe'taki bitmemiş abonelikler hemen iptal edilir (başarısızsa hiçbir şey silinmez, `502`); sonra Apple ile girişin saklanan yenileme jetonu Apple'da iptal edilir (başarısız olsa da silme sürer; yukarıda "Apple ile giriş jetonunun iptali"); sonra kimlikler, Apple jetonu, oturumlar, cihazlar, toplantılar, kullanım, abonelik ve Stripe müşteri eşlemesi, deneme kayıtları ve hesabın raporları tek işlemde silinir; aynı işlemde önce her kimliğin deneme defteri satırı yazılır (harcanan deneme ve Mac doğrulaması, kimliğin HMAC özetiyle; deneme harcanmadıysa yazılmaz) (raporlar serbest metin ve e-posta taşıyabildiği için bağı kaldırılmaz, silinir; jetonsuz gönderilmiş raporlar hesaba bağlanamaz, 180 günde silinir). Bugünkü deneme başlangıcı IP özeti başına günlük sayaçta hesap bağı olmadan kalır. Stripe'taki müşteri ve faturalar vergi kayıtları için Stripe'ta kalır. Tekrarı (aynı jetonla) `200`, uyarısız |
| `POST /v1/device/challenge` | Bearer | `{purpose: "attest" \| "assert"}` |
| `POST /v1/device/attest` | Bearer | `{keyId, attestation, challenge}` (base64) |
| `POST /v1/meetings/start` | Bearer | `{device?: {keyId, assertion, clientData}, deviceCheckToken?: <base64>, clientRef?, deferred?}`; clientData = `{"action":"meetings.start","challenge":…}`; `deviceCheckToken` (`DCDevice.generateToken()`) denemesi henüz bir Mac'e bağlanmamış hesabın deneme toplantısında gerekir (bkz. "Deneme kötüye kullanımı"); `clientRef` (`[A-Za-z0-9._-]{1,64}`) istemcinin kayıt kimliğidir: aynı kimlikle yinelenen başlatma aynı oturumu döndürür; `deferred: true` sonradan işlenen kayıttır, açık toplantıyı kapatmaz. Yeni hesabın ilk denemesi IP başına günde `TRIAL_ACCOUNTS_PER_IP_PER_DAY` (üretimde 10); kullanıcı başına günde en çok 20 başlatma; yeni toplantı açık olanı ek süresiz kapatır, reddedilen başlatma açık toplantıya dokunmaz ve sayılmaz |
| `POST /v1/meetings/{id}/end` | Bearer | → `{meetingId, minutes, tokensUsed, audioSeconds}`; `minutes` kaydedilen (duraklatılmamış) süre |
| `POST /v1/meetings/{id}/pause`, `/resume` | Bearer | gövde yok → `{meetingId, paused, expiresAt, pausedSeconds}`; bkz. "Toplantı duraklatma" |
| `POST /v1/meetings/{id}/reprocess` | Bearer | gövde yok → `{meetingId, usableUntil, reprocessesLeft}`; bitmiş toplantıyı yeniden yazıya dökme ve not için açar: canlı çağrılara `MEETING_GRACE_MINUTES`, kaydın işlenmesine (ses, not) `MEETING_PROCESSING_HOURS` boyunca (toplantı başına en çok 2 kez, `409 reprocess_limit_reached`). Toplantı işleme süresi içindeyse ve sesi henüz yazılmadıysa hak harcanmaz. Uygulama kaydın notu ya da son geçişi `meeting_not_active` alınca bunu kendiliğinden çağırır. Aboneliği ya da çalışan denemesi (başlamış, süresi ve toplantıları bitmemiş; hiç başlamamış deneme sayılmaz) olmayan hesap yalnızca bitişten sonraki 7 gün içinde (`402 subscription_required`). Harcama tavanı doluysa hak harcanmadan `503 spend_ceiling_reached`; deneme toplantısında deneme tavanı ya da ElevenLabs deneme durağı doluysa `503 trial_capacity_reached`. Tanımlar `src/meetings.ts` → `reprocessMeeting` |
| `POST /v1/live/deepgram-token` | Bearer + `x-meeting-id` | kısa ömürlü Deepgram jetonu; bkz. "Deepgram canlı metni" |
| `POST /v1/llm/messages` | Bearer, isteğe bağlı `x-meeting-id` | zorunlu `effort: "low" \| "medium"` + Anthropic Messages alt kümesi; `thinking` yok; `stream: true` ise SSE. `x-meeting-id` varsa toplantı bütçesinden düşer, çağrı başı `LLM_MAX_TOKENS`: canlı amaçlar (`live_translation`, `missed_summary`, `live_question`) toplantı açıkken ya da ek sürede (`MEETING_GRACE_MINUTES`) geçer ve bütçenin nota ayrılan %15'ini kullanamaz (`429 meeting_budget_exhausted`); kaydın işlenmesi (not, not parçası ve birleştirmesi, konuşmacı incelemesi; amacı bildirilmemiş eski istemci çağrısı) düzgün biten toplantıda `MEETING_PROCESSING_HOURS` (24 saat) boyunca geçer (yeni toplantıyla kapanan `superseded` toplantı uzatma almaz). Yoksa hesap çağrısıdır (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı): erişimi olan abonelik ya da ilk toplantıyla başlamış (DeviceCheck `required` iken Mac'e bağlanmış), bitmemiş deneme gerekir (deneme hiç başlamadıysa `403 trial_not_started`, bittiyse `402 subscription_required`), çağrı başı daha küçük `LLM_ACCOUNT_MAX_TOKENS`; aboneliği olmayan kullanıcıda bu çağrılar ayrıca günlük `TRIAL_ACCOUNT_DAILY_TOKENS` (300 K; türetme `wrangler.jsonc`'ta) ile sınırlıdır (`429 daily_cap_reached`), abonede aylık `MONTHLY_ACCOUNT_TOKEN_CAP` (1,5 M) ile (`403 monthly_cap_reached`). Her iki durumda kullanıcı başına aylık (8,5 M) ve günlük (3,6 M) token sınırı ve harcama tavanı. Akışsız çağrı 120 sn, akışın ilk baytı 30 sn zaman aşımlıdır; akış ayırmadan en çok 12 dk sürer (ayırmanın 15 dk ömründen kısa), sonra kesilir ve ayrılan üst sınırla kesinleşir. Sistem istemi sunucunun koyduğu prompt önbelleği kesme noktasıyla gider (5 dk; istemci önbellek işareti gönderemez): aynı amacın sabit talimatları tekrar okunur, her çağrıda değişen kullanıcı mesajı önbelleğe yazılmaz. Önbellek tokenları bütçelerde tam sayılır, harcamaya önbellek fiyatıyla yazılır (yazma 1,25×, okuma 0,1× girdi fiyatı) |
| `POST /v1/transcribe` | Bearer + `x-meeting-id` | gövde 16 kHz mono 16 bit FLAC (`Content-Type: audio/flac`; uygulamanın gönderdiği biçim) ya da ham PCM WAV (`audio/wav`; FLAC'tan önceki sürümler), `Content-Length` zorunlu; başka tür `415`. FLAC'ta `fLaC` imzası ve ilk blok STREAMINFO olmalı, 16 kHz / mono / 16 bit dışı biçim, toplam örneği 0 olan ya da boyutu STREAMINFO'daki örnek sayısına sığmayan (PCM boyutunun %1 fazlası + 4 KB) dosya `400 invalid_body`; dosya ElevenLabs'e `audio.flac` olarak iletilir; `?language_code=&diarize=`; anahtar terimler `x-keyterms` başlığında: UTF-8 JSON dizgi dizisinin dolgusuz base64url'i (en çok `TRANSCRIBE_MAX_KEYTERMS`; terim <50 karakter, ≤5 kelime, `<>{}[]\` yok; değerler loglanmaz). Yayımlanmış 0.1.4 uygulaması için tekrar eden `?keyterms=` de kabul edilir (ikisi birlikte `400`). Süre WAV başlığından (veri baytı / bayt hızı) ya da FLAC STREAMINFO'sundan (toplam örnek / 16000) kesin hesaplanıp önceden ayrılır; toplantının sesi en çok toplantının taban süresi kadar (duraklatma uzatması sayılmaz); düzgün biten toplantıda `MEETING_PROCESSING_HOURS` boyunca yüklenebilir; kullanıcının tüm toplantılarında aynı anda tek istek (`409 transcription_in_progress`). ElevenLabs isteği 15 dk zaman aşımlıdır. Uzun toplantıda ses parçalar halinde sırayla gönderilir (FLAC: en çok 95 MB ve 60 dk; eski WAV: 95 MB, ~49 dk; parçalar 1 dk örtüşür) |
| `POST /v1/billing/checkout` | Bearer | `{plan: "monthly" \| "yearly", referralCode?}` (katı; kod plansız gönderilemez) → `{url}`. Plansız istek aylıktır: yalnızca eski istemciler için (uygulama ≤ 0.1.5 gövdesiz, eski site `{}`). Kod verilirse `POST /v1/referral/validate` ile aynı denetim ve hatalar; planın davet kuponu eklenir. Bitmemiş abonelik varken (`active`, `trialing`, `past_due`, `unpaid`, `incomplete`, `paused`; ek süre geçmiş olsa da; yerel satırda ya da Stripe'taki listede) `409 subscription_exists`, istemci Portal'ı açar; süren ücretsiz erişimde Stripe'a gitmeden `409 complimentary_subscription`; erişimi süren App Store aboneliğinde `409 app_store_subscription` |
| `POST /v1/billing/portal` | Bearer | `{url}`: Stripe Müşteri Portalı; Stripe'ta bitmemiş aboneliği yokken App Store aboneliği varsa Apple'ın abonelik sayfası; süren ücretsiz erişimde Stripe'a gitmeden sitedeki hesap sayfası (`<SITE_ORIGIN>/account`); Stripe müşterisi yoksa `402 subscription_required` |
| `GET /v1/referral` | Bearer | `{enabled, code, inviteUrl, joined, rewarded, pending, nextRewardAt, complimentary, appStoreBilled, rewardsLeftThisYear, rewardsPerYear, rewardUsd, holdDays}`; `code` yalnızca program açık, abonelik erişimi (Stripe ya da App Store) var ve hesap davetin ücretsiz ilk ayında değilken (ilk istekte üretilir); `nextRewardAt` bekleyen ödülün en yakın tahmini tarihi (ücretsiz aydaki arkadaşta yenilenecek aboneliğin ilk ücretli faturası + 30 gün, ödeme alınmışsa kesin tarih) ya da null; `complimentary` ücretsiz erişimde true (ödül uygulanmaz); `appStoreBilled` asıl abonelik App Store'dansa true (ödül Stripe alacağıdır, Apple faturasına uygulanmaz; Stripe müşterisi yoksa `referrer_no_customer`) |
| `POST /v1/referral/validate` | Bearer | `{code}` → `{code}` (normalize: boşluk ve tire atılır, büyük harf). `404 referral_invalid`, `403 referral_self`, `409 referral_not_eligible`, `409 referral_limit_reached`, `503 referral_unavailable` (bkz. "Davet programı"); kullanıcı başına dakikada 10 |
| `POST /v1/billing/webhook` | Stripe imzası | olayın anlık görüntüsüne değil Stripe'taki güncel duruma güvenilir: müşterinin abonelikleri listelenir, kullanıcı başına tek geçerli abonelik yazılır (yaşayanlardan erişimi en yüksek, eşitse en eski). Yaşayan ikinci abonelik alarmla iptal edilir; tanınmayan müşterinin yaşayan aboneliği iptal edilir. `past_due` ek süresi (`PAST_DUE_GRACE_DAYS`) `past_due`'ya geçişten sayılır. `customer.deleted` eşlemeyi siler; `charge.refunded` alarm; `charge.dispute.created` alarm ve aboneliği hemen iptal. Hesap silinirken müşterinin açık Checkout oturumları da sona erdirilir |
| `POST /v1/webhooks/revenuecat` | `Authorization` = `REVENUECAT_WEBHOOK_AUTH` | bkz. "App Store abonelikleri (RevenueCat)" |
| `POST /v1/billing/app-store/sync` | Bearer | gövde yok → güncel `/v1/me` yanıtı; bkz. "App Store abonelikleri (RevenueCat)" |
| `POST /v1/reports` | İsteğe bağlı Bearer | `{kind, message?, email?, appVersion?, os?, payload?, turnstileToken?}` → `202 {}`. `contact` (site): `message` (≤5000), `email` (≤254) ve `turnstileToken` zorunlu, Turnstile doğrulanır. `feedback`: `message` zorunlu. `crash`: `payload` zorunlu (JSON nesnesi, ≤64 KB, aşarsa `413`; MetricKit ise listede kısa imza). `appVersion` ≤40, `os` ≤80. Türe ait olmayan alan reddedilir (ör. `feedback` + `payload`, `crash` + `turnstileToken`). Jeton varsa geçerli olmalı (`401`), rapor hesaba bağlanır; jetonsuz `feedback`/`crash` (hesapsız geliştirici sürümü ve iPhone) kabul edilir ama birlikte tür bütçesinin en çok dörtte birini kullanır. Gövde ayrıştırmadan önce en çok 160 KB (`413`); IP başına 5/dk, hesap başına günde 20, tür başına günde `REPORT_BYTES_PER_DAY` bayt (`429 daily_cap_reached`) |
| `POST /v1/shares` | Bearer (abonelik ya da süren deneme) | notu bağlantıyla paylaşma: gövde `application/octet-stream` = uygulamanın şifrelediği not (`GSS1`, ≤1 MiB), başlıklar `x-share-id` (16 rastgele bayt, base64url) ve `x-share-expires-days` (7, 30, 90) → `201 {shareId, size, createdAt, expiresAt}`; aynı yüklemenin tekrarı aynı satırı döndürür, başka blokla aynı kimlik `409 share_exists`, hesapta 50 açık bağlantı `409 share_limit_reached`, tüm hesapların 1 GB bütçesi dolunca `503 share_unavailable`. Kullanıcı başına 10/dk. Bkz. `src/shares.ts` |
| `GET /v1/shares` | Bearer | hesabın açık bağlantıları `{shares: [{shareId, size, createdAt, expiresAt}], maxActive}` (şifreli içerik yok) |
| `DELETE /v1/shares/{id}` | Bearer | bağlantıyı hemen siler (`{deleted: true}`); başkasının ya da olmayan bağlantı `404` |
| `GET /v1/phone` | Bearer | uygulamadan arama görünür mü: `{available, reason (policy_off \| country_not_allowed \| subscription_required \| null), countries, provider, consentVersion, consentAccepted, number: {e164, status} \| null, maxCallMinutes, monthlyMinutes, usedMinutes}`; ülke doğrulanmış numaranınki, yoksa IP'ninki (Cloudflare). Kapalıyken de `200`. Bkz. "Uygulamadan arama" |
| `POST /v1/phone/consent` | Bearer | `{version}` (güncel açıklama sürümü, 1) → `{consentVersion, consentAccepted: true}`; numara ve aramadan önce gerekir (`403 phone_consent_required`). Politika kapalıyken bu ve aşağıdaki uçlar `503 phone_unavailable` |
| `POST /v1/phone/number` | Bearer (abone) | `{number}` (E.164) → Twilio numarayı arar: `{e164, status: "pending", validationCode, expiresAt}` (kullanıcı kodu tuşlar); zaten doğrulanmışsa aramasız `{e164, status: "verified"}`. Başka hesabın numarası `409 phone_number_in_use`, hesap başına günde 5 doğrulama araması (numara silinse de sayılır; `429 phone_verification_limit`; her biri 0,05 $ olarak harcama tavanlarına yazılır, tavan doluysa `503 phone_capacity_reached` ya da `spend_ceiling_reached`), ücretli ya da izin dışı ülke `403 phone_number_blocked`, biçim `400 phone_number_invalid` |
| `GET /v1/phone/number` | Bearer | `{number: {e164, status: pending \| verified \| failed} \| null}`; süresi geçmiş bekleyen doğrulamada Twilio'ya bir kez sorulur |
| `DELETE /v1/phone/number` | Bearer | numarayı unutur (`{removed}`); Twilio'daki arayan numarası günlük temizlikte silinir |
| `POST /v1/phone/calls` | Bearer (abone, doğrulanmış numara) | `{to}` (E.164) → `201 {callId, accessToken, maxSeconds, country, provider}`: Voice SDK jetonu (2 dk, yalnızca giden arama). Retler: `409 phone_call_active`, `403 phone_minutes_exhausted`, `403 monthly_cap_reached`, `503 phone_capacity_reached`, `503 spend_ceiling_reached`, `429 rate_limited` (günde 30) |
| `GET /v1/phone/calls/{id}` | Bearer | `{callId, status: reserved \| dialing \| completed \| failed \| expired, billedSeconds, recording: pending \| ready \| absent \| deleted}`; başkasının araması `404` |
| `GET /v1/phone/calls/{id}/recording` | Bearer | iki kanallı MP3 (`audio/mpeg`, Twilio'dan akıtılır); hazır değilse `409 phone_recording_unavailable` |
| `DELETE /v1/phone/calls/{id}/recording` | Bearer | kaydı Twilio'da siler (tekrarı zararsız) → arama durumu |
| `POST /v1/phone/webhooks/{voice \| announcement \| dial-done \| call-status \| recording \| verification}` | Twilio imzası | Twilio'nun çağırdığı uçlar (form gövdesi, TwiML yanıtı); imza ya da hesap kimliği tutmazsa `403` |
| `GET /v1/public/shares/{id}` | — | sitenin paylaşım sayfası (`/s`, CORS yalnızca site kaynağı) için şifreli not (`application/octet-stream`, `no-store`, `noindex`); olmayan, süresi dolmuş ya da kaldırılmış bağlantı aynı `404`. IP başına 60/dk (`SHARE_IP_LIMITER`). Kötüye kullanım bildirilen bağlantı elle kaldırılır: `npx wrangler d1 execute ainotepad-production --env production --remote --command "DELETE FROM note_shares WHERE share_id = '<id>'"` (kimlik bağlantıda `#`'ten sonraki ilk parçadır; anahtar gerekmez) |
| `GET /v1/download/mac/version` | — | `{version}`: DMG ile aynı sürümün Sparkle akışından (`APPCAST_URL`) okunan sürüm numarası (sitedeki indirme sayfası); `Cache-Control: public, max-age=300`, D1'e dokunmaz |
| `GET /v1/download/mac` | — | `?src=<home-hero \| home-cta \| download-page \| account>` (yoksa `direct`, tanınmayan `other`) → `302` → `DMG_URL`; ağ başına günde bir indirme sayılır: UTC gün toplamı ve kaynak + Referer alan adı sayacı (`download_sources`; yol ya da tam adres değil). Tekilleştirme için ağın gün ile HMAC özeti ertesi güne dek tutulur; tekrar indirme D1'e yazmaz. Sayaç yazılamazsa yine yönlendirir (`download_count_failed` uyarısı) |
| `POST /v1/funnel` | — | Uygulamanın ilk açılış hunisi (abonelik sürümü, "Anonim kullanım istatistiklerini paylaş" açıkken): `{step, detail}`: `first_launch` + `""`; `sign_in_started`, `sign_in_canceled`, `signed_in` + `apple \| google`; `sign_in_failed` + `window \| callback \| server \| network` → `202 {}`. `x-app-version` zorunlu. Gün, adım, ayrıntı ve sürüm başına sayılır (`app_funnel_daily`; günde en çok 20 sürüm ayrı, sonraki yeni sürümler `other`); IP yalnızca hız sınırının anahtarıdır (IP başına 20/dk), tanımlayıcı saklanmaz. Listeler `src/funnel.ts` |
| `GET /v1/admin/stats` | Bearer + yönetici | indirme, kullanıcı, deneme, abonelik (plan başına yenilenecek sayılar; MRR = aylık × `PRICE_USD_MONTHLY` + yıllık × `PRICE_USD_YEARLY` / 12 + App Store net MRR; kaynağa göre ayrım `subscriptions.bySource`), davet sayaçları (nedene göre düşen davetler dahil), toplantı, harcama, token ve açık rapor özetleri; 30 günlük seriler (UTC, eskiden yeniye, boş gün 0). Tanımlar `src/admin.ts` → `adminStats` |
| `GET /v1/admin/insights` | Bearer + yönetici | sorunlar (son 7 ve 30 gün: deneme kapasitesi ve harcama tavanı retleri, koda göre retler, servise göre üst servis hataları, 5xx), son 30 günün hunisi (indirme → hesap → ilk toplantı → ilk not → ≥ 3 toplantı → abone → davetle abone → iptal), uygulamanın ilk açılış hunisi (`firstRun`: adım ve ayrıntı başına son 30 gün, günlük ilk açılış ve giriş), indirme kaynakları ve Referer alan adları, Stripe iptal nedenleri, davet özeti (son 30 günde Checkout, katılım, ilk ödeme, ödül, nedene göre düşen davetler; şu an ücretsiz aydakiler; en çok davet edenler). Tanımlar `src/adminInsights.ts` |
| `GET /v1/admin/trends` | Bearer + yönetici | son 90 günün anlık görüntüleri (`daily: [{day, snapshot \| null}]`), gerçek gelir (`revenue: {currencies: [{currency, mrrCents, payingSubscriptions, arpuCents, paidLast30DaysCents, taxLast30DaysCents, discountLast30DaysCents, refundedLast30DaysCents, netLast30DaysCents, paidAllTimeCents, netAllTimeCents, paidSubscriptionsAllTime, ltvCents, daily}], firstPaymentsLast30Days, medianDaysToFirstPayment}`) ve son 30 günün token kovaları, konuşma tanıma dilleri, hesap silmeleri, yeniden denemeler ve indirme kampanyaları. Tanımlar `src/adminTrends.ts` |
| `GET /v1/admin/site-analytics` | Bearer + yönetici | `{generatedAt, days, pageViews, visits, daily: [{day, pageViews, visits}], topPaths: [{key, pageViews, visits}], topReferrers: [...]}` (Cloudflare Web Analytics, son 30 gün); ayarlı değilse `503 analytics_unavailable` |
| `GET /v1/admin/operations` | Bearer + yönetici | açık ve bitirilmemiş toplantılar, takılı ayırmalar, kesinleşmemiş Deepgram tahminleri, Stripe olayları (son olay, 24 saat, 7 günün türleri) ve son çökmeler. Tanımlar `src/adminOps.ts` |
| `GET /v1/admin/users` | Bearer + yönetici | `?q=<kimlik öneki>&segment=&provider=&cursor=`; `segment`: `subscribed`, `past_due`, `canceled`, `trial`, `free`, `invited` (davet koduyla abone olmuş) ya da bırakma kesimleri `no_meeting`, `trial_ended`, `inactive` (7 gündür toplantı yok), `failed` (toplantısında istek başarısız). Öğede `invite`: `invited` / `free_month` (davetin ücretsiz ilk ayında) / `null`. Tanımlar `src/adminUsers.ts` |
| `GET /v1/admin/users/{id}` | Bearer + yönetici | hesabın ayrıntısı: özet, Mac doğrulaması, Stripe müşterisi, son iptal nedeni, bu ayın kullanımı, toplantılar (en çok 100), raporlar (en çok 20), kullandığı davet (`invitedBy`: davet eden, kod, durum ve düşme nedeni, ücretsiz ayda mı, kart denetlendi mi, zamanlar), davetleri (`invites`: kod, sayaçlar, tahmini ödül tarihi, arkadaşlar) ve zaman çizelgesi (davet olayları dahil). Tanımlar `src/adminUsers.ts` |
| `POST /v1/admin/users/{id}/complimentary` | Bearer + yönetici | `{grant: true, until?: <ISO 8601 tarih ya da zaman>}` ücretsiz tam erişim verir (yoksa süresiz; varsa süresini değiştirir), `{grant: false}` süren ücretsiz erişimi şimdi bitirir (satır kalır: hesap yeniden abone olabilir, davet kodu kullanamaz) → kullanıcının ayrıntısı. Bitmemiş Stripe aboneliği varsa `409 subscription_exists`; süren ücretsiz erişim yoksa kaldırma `404`. Tanımlar `src/complimentary.ts` |
| `POST`/`DELETE /v1/admin/assistant/reviewer` | Bearer + yönetici | Bağlayıcı dizini incelemecisinin hesabı (`REVIEWER_LOGINS` içindeki `userId`): `POST` sabit kimlikli hesabı açar ya da yeniden kullanır (Apple/Google kimliği yok), süresiz ücretsiz erişim ve asistan erişimi verir, kurgusal altı örnek toplantıyı normal anahtarla şifreleyip yazar (tarihler son iki haftaya taşınır, eskiler silinir) → `{userId, epoch, meetingIds}`; `DELETE` asistan erişimini kapatır (bağlantılar düşer, kopya silinir) ve ücretsiz erişimi bitirir → `{userId, assistantEnabled, complimentaryRevoked}`. Parola sunucuya gelmez. `ASSISTANT_POLICY` kapalıyken `503 assistant_unavailable`. Tanımlar `src/assistant/reviewer.ts` |
| `GET /v1/admin/reports` | Bearer + yönetici | `?kind=&status=&before=<ms>` → `{items: [{id, kind, status, createdAt, userId, email, appVersion, os, summary}], nextBefore}`; sayfa 50, yeniden eskiye, `createdAt` ISO 8601, `nextBefore` ms ya da son sayfada `null` |
| `GET /v1/admin/reports/{id}` | Bearer + yönetici | `{id, kind, status, createdAt, userId, email, appVersion, os, message, payload}` |
| `POST /v1/admin/reports/{id}` | Bearer + yönetici | `{status: "open" \| "done"}` → `204` |
| `GET /v1/admin/blog/posts` | Bearer + yönetici | `{today, posts: [{slug, title, description, author, published, updated, cover, draft, status, sha, change}], changes: [change]}`: depodaki tüm yazılar, yeniden eskiye (aynı gün başlığa göre), açık pull request'i olanlar onun sürümüyle; `status` `draft` / `scheduled` (`published` > `today`, UTC) / `live`; `updated` ve `cover` yazılmamışsa `null`; `sha` dosyanın GitHub sürümü; `change` yazının açık panel pull request'i ya da `null`: `{number, url, slug, title, state: open\|merged\|closed, autoMerge, checks: pending\|passing\|failing\|none, updatedAt}`; `changes` açık ve son 10 birleşen/kapanan panel pull request'i, yeniden eskiye. Bkz. "Blog yayını" |
| `GET /v1/admin/blog/posts/{slug}` | Bearer + yönetici | listedeki alanlar + `body` (Markdown), açık pull request'i varsa onun dalından; yoksa `404` |
| `PUT /v1/admin/blog/posts/{slug}` | Bearer + yönetici | `{title, description, author, published, updated, cover, draft, body, sha}` (katı; `updated` ve `cover` her istekte, yoksa `null`) → yeni yazıda `201`, güncellemede `200` ve yazının kayıttan sonraki hâli (`change`: yazının pull request'i) + `autoMergeError` (otomatik birleştirme açılamadıysa GitHub'ın nedeni, yoksa `null`). Yeni yazıda `sha: null` (dosya varsa `409 blog_post_exists`); güncellemede açılan sürüm (dosya değişmiş ya da silinmişse `409 blog_conflict`). Kurallar ve dosya biçimi: "Blog yayını"; ihlal `400 invalid_body`, geçersiz kısa ad `400 bad_request` |
| `DELETE /v1/admin/blog/posts/{slug}?sha=` | Bearer + yönetici | `200 {images, change, autoMergeError}`: yazı ve görsel klasörü yazının pull request'inde tek commit'te silinir (yalnızca pull request'inde olan yazıda pull request kapanır, `change.state` `closed`); yoksa `404`, sürüm uyuşmazsa ya da dal sürekli değişirse `409 blog_conflict`, `sha` yoksa `400` |
| `PUT /v1/admin/blog/posts/{slug}/images/{name}` | Bearer + yönetici | `{data}` (katı; WebP'nin standart base64'ü, en çok 600 KB, genişlik en çok 1600 px) → `201 {path, sha, bytes, width, height, change, autoMergeError}` (`path`: `/blog/<slug>/<name>`; görsel yazının pull request'ine commit'lenir). Ad `^[a-z0-9-]+\.webp$` (değilse `400 bad_request`); WebP değilse `415 unsupported_media_type`, büyükse `413 payload_too_large`, genişse `400 invalid_body`; yazı yoksa `404`, ad kullanılmışsa `409 blog_image_exists`. Bkz. "Blog yayını" |

Hatalar her zaman `{"error": {"code", "message"}}` biçimindedir; yönetici olmayan kullanıcının yönetici isteği düz
`403 forbidden` döner (gövdede kimlik yok).
Günlük harcama tavanı aşılınca toplantı başlatma ve her vekil çağrısı `503 spend_ceiling_reached` döner; günlük deneme
harcaması tavanı aşılınca deneme harcaması açan her istek (yeni deneme toplantısı, denemedeki hesap çağrısı, açık ya da
yeniden açılmış deneme toplantısının yapay zekâ ve yazıya dökme çağrıları, deneme toplantısını yeniden işleme)
`503 trial_capacity_reached` döner. Günün harcaması kesinleşmiş harcamaya süren (kesinleşmemiş, süresi dolmamış)
ayırmaların en kötü durum tahminini de katar ve vekil çağrıları tavanı ayırma ifadesinin içinde yeniden denetler:
eşzamanlı istekler tavanı birlikte geçemez, aşım en çok bir çağrının tahmini kadardır. İki tavanın alarmı günde bir kez yazılır; retlerin sayısı yönetim panelindedir
(`ops_events`). Site kaynağı
(`SITE_ORIGIN`) CORS'u yalnızca site uçlarında (`src/app.ts` → `webRoutes`: `/v1/health`, `/v1/download/mac/version`,
giriş, yenileme ve çıkış, `/v1/me`, ödeme ve Portal, `/v1/referral`, `/v1/referral/validate`, `/v1/reports`) ve yönetici
uçlarında alır; `GET /v1/download/mac/version` dışında her yanıt `Cache-Control: no-store` taşır.
