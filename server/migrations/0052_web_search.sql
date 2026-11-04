-- Sor'da web araması (src/llm/webSearch.ts): Anthropic'in sunucu tarafı arama aracı yalnız Sor cevabında, cevap başına
-- en çok 3 arama. Kullanıcı başına bu ayki arama sayısı `monthly_usage.web_searches`'ta tutulur (`MONTHLY_WEB_SEARCH_CAP`;
-- çağrıdan önce verilen hak düşülür, kesinleştirmede kullanılmayan geri verilir). Arama sorgusu ve sonuçlar saklanmaz.
-- Hesap silinince satır `monthly_usage` ile birlikte silinir.
ALTER TABLE monthly_usage ADD COLUMN web_searches INTEGER NOT NULL DEFAULT 0;

-- Amaç başına günlük toplamda web araması sayısı (yönetim paneli "Telemetri"; kullanıcıya bağlı değil).
ALTER TABLE llm_purpose_usage ADD COLUMN web_searches INTEGER NOT NULL DEFAULT 0;
