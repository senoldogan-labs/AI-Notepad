-- Apple ile girişin yenileme jetonları (src/auth/appleTokens.ts): yalnızca hesap silinince Apple'da yetkiyi geri almak
-- (`POST https://appleid.apple.com/auth/revoke`) için saklanır; başka hiçbir iş için okunmaz.
--
-- Site, Apple'ın yetkilendirme kodunu (`code`) `POST /v1/auth/apple/authorization-code` ile gönderir; sunucu kodu
-- `POST https://appleid.apple.com/auth/token` ile yenileme jetonuna çevirir. Uygulama adına girişte kod, hesap henüz
-- oluşturulmadan gelir: bu yüzden satır hesap kimliğine değil Apple kimliğine (`auth_identities.subject`, sağlayıcı
-- `apple`) bağlıdır. Aynı kimliğin yeni girişi satırı değiştirir (en son jeton).
--   client_id: jetonun verildiği istemci (Services ID); iptal aynı istemciyle yapılır.
--   refresh_token_ciphertext: base64(12 baytlık IV || AES-256-GCM şifreli metin ve etiket); anahtar APPLE_TOKEN_ENC_KEY,
--     ek doğrulanmış veri `subject` (satırlar arasında taşınamaz). Düz jeton hiçbir yerde saklanmaz ya da loglanmaz.
--   stored_at: jetonun saklandığı an (ms).
-- Hesap silinince satır iptalden sonra silinir (src/account.ts). Hesaba bağlanmamış satır (giriş yarıda kaldı) bir gün
-- sonra silinir (src/cleanup.ts).
CREATE TABLE apple_sign_in_tokens (
  subject TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  refresh_token_ciphertext TEXT NOT NULL,
  stored_at INTEGER NOT NULL
);

CREATE INDEX apple_sign_in_tokens_stored ON apple_sign_in_tokens (stored_at);
