-- Geri bildirimde alıntı izni (src/reports.ts): kullanıcı "gistsmith.com'da ön adımla alıntılanabilir" kutusunu
-- işaretlediyse verdiği ön ad; yoksa NULL (izin yok). Sunucu hiçbir şeyi kendiliğinden yayımlamaz: yönetici paneli izinli
-- geri bildirimleri listeler, sahip onayladığı alıntıyı sitenin listesine (web/src/testimonials.ts) elle ekler. Rapor
-- satırıyla birlikte silinir (180 gün sonra ya da hesap silinince).
ALTER TABLE reports ADD COLUMN quote_first_name TEXT;
CREATE INDEX reports_quotable ON reports(created_at) WHERE quote_first_name IS NOT NULL;
