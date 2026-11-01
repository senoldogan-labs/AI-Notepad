-- Uygulamanın ilk açılış hunisi (yönetim paneli "Büyüme"; src/funnel.ts): Mac uygulaması (abonelik sürümü) Ayarlar'daki
-- "Anonim kullanım istatistiklerini paylaş" açıkken kurulumun ilk açılışını ve giriş adımlarını (`POST /v1/funnel`,
-- jetonsuz) bildirir. Adım (`first_launch`, `sign_in_started`, `sign_in_canceled`, `sign_in_failed`, `signed_in`),
-- ayrıntı (sağlayıcı `apple`/`google`, başarısızlık aşaması `window`/`callback`/`server`/`network`; ilk açılışta "")
-- ve uygulama sürümü başına günlük sayı. IP, hesap ya da başka bir tanımlayıcı tutmaz; 400 gün tutulur
-- (src/cleanup.ts). Gün sunucunun UTC günüdür.
CREATE TABLE app_funnel_daily (
  day TEXT NOT NULL,
  step TEXT NOT NULL,
  detail TEXT NOT NULL,
  app_version TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, step, detail, app_version)
);
