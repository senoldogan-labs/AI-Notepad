# Gistsmith: Mac ↔ iPhone toplantı eşitleme — seçenekler ve öneri

Tarih: 2026-11-03. Durum: **karar bekliyor** (yalnız araştırma ve tasarım; ürün kodu, göç, dağıtım yok).
Kaynaklar: bu repodaki kod (yollar aşağıda), bu makinedeki gerçek toplantı dosyalarının boyutları ve 2026-11-03'te
okunan Cloudflare/Apple fiyat sayfaları (§13).

---

## 0. Sahibi için kısa özet (karar sayfası)

**Bugün:** Mac ve iPhone'daki Gistsmith yalnızca hesabı ve aboneliği paylaşıyor. Toplantılar, notlar, görevler, kişiler,
Sor sohbetleri, ses ve ekran görüntüleri kaydedildikleri cihazda kalıyor. Gizlilik politikası da bunu söylüyor:
"Bir cihazda kaydedilen toplantı diğerinde görünmez."

**Seçenekler (sade dille):**

| | Ne demek | Bize maliyeti | Kullanıcıya | İş |
|---|---|---|---|---|
| **A. iCloud Drive** | Toplantı klasörleri kullanıcının iCloud'una kopyalanır (geliştirici sürümünde bugün çalışan yol) | $0 | iCloud'u açık olmalı, Mac ve iPhone **aynı Apple hesabında** olmalı, iCloud kotasını yer | ~2–3 hafta |
| **B. CloudKit** | Aynı fikir, ama Apple'ın veritabanıyla, kayıt kayıt ve daha güvenilir | $0 | A ile aynı kısıtlar (Apple hesabı, kota) | ~4–5 hafta |
| **C. Kendi sunucumuz, uçtan uca şifreli** | Cihaz her şeyi kendi anahtarıyla şifreler, biz yalnızca okuyamadığımız kopyayı saklarız | Kullanıcı başına ayda **$0.002 (yalnız metin) – $0.05 (ses+ekran dahil, en yoğun kullanıcı)** | Sadece **Gistsmith hesabıyla giriş**; Apple hesabı, iCloud, kota önemli değil | ~5–6 hafta (metin), +2 hafta (ses/ekran) |
| **D. Karma** | Metin C ile; ses ve ekran görüntüleri cihazda kalır (ya da istenince indirilir) | C'nin metin maliyeti | C ile aynı | C'nin ilk aşaması |

**Öneri: C, iki aşamada (yani önce D).**

1. **Aşama 1 — yalnız metin:** toplantı kaydı (metin, not, görevler, başlık, klasör, işaretler), kişiler ve Sor
   sohbetleri uçtan uca şifreli olarak sunucumuz üzerinden eşitlenir. Ses ve ekran görüntüleri kaydedildiği cihazda
   kalır. Maliyet pratikte sıfır (1.000 aktif kullanıcıda ayda ~$2).
2. **Aşama 2 — ses ve ekran (isteğe bağlı):** "Diğer cihazda dinle / ekranı gör" için ses ve görüntüler de şifreli
   yüklenir; saklama süresi bugünkü ses saklama ayarına bağlı. 1.000 kullanıcıda ayda ~$5–10.

**Neden iCloud değil?** Gistsmith hesabı Google ya da Apple ile açılıyor; Mac'teki ve iPhone'daki iCloud hesabının aynı
olacağının garantisi yok (iş Mac'i, paylaşılan Mac, iCloud Drive kapalı, 5 GB'lık dolu ücretsiz iCloud). Bu durumlarda
eşitleme sessizce çalışmaz ve biz nedenini sunucudan göremeyiz. Kullanıcının beklentisi "aynı hesapla girdim,
toplantılarım orada" — bunu yalnız C karşılıyor. Maliyet abonelik fiyatının (aylık $5.99) %1'inin altında.

**Neden "uçtan uca şifreli"?** Bugünkü söz "sunucularımız ses ve not saklamaz". Uçtan uca şifrelemeyle sözü
"sunucularımız yalnızca **okuyamadığımız** şifreli kopyayı saklar; anahtar yalnız senin cihazlarında" olarak dürüstçe
güncelleyebiliriz. Bedeli: tüm cihazlarını kaybeden ve kurtarma kodunu saklamayan kullanıcının eşitlenen kopyası
açılamaz (cihazdaki toplantılar zaten cihazda).

**Senin vermen gereken kararlar (ayrıntı §12):**

1. Seçenek: C (önerilen) mi, A/B mi?
2. Aşama 1'de ses ve ekran görüntüleri dışarıda kalsın mı? (Önerilen: evet.)
3. Uçtan uca şifreleme mi (önerilen), yoksa sunucunun da okuyabildiği şifreleme mi (web'den okuma kolaylaşır, gizlilik
   sözü zayıflar)?
4. Kurtarma kodu zorunlu mu, isteğe bağlı mı? (Önerilen: isteğe bağlı, Ayarlar'da; anahtar varsayılan olarak iCloud
   Anahtar Zinciri ve "cihaz ekle" koduyla taşınır.)
5. Eşitleme varsayılan açık mı? (Önerilen: yeni kullanıcıda açık, mevcut kullanıcıya bir kez sorulur.)
6. Abonelik bitince sunucudaki şifreli kopya kaç gün tutulsun? (Önerilen: 90 gün, sonra silinir; cihazdakiler kalır.)
7. Veri bölgesi: Cloudflare R2'de AB yargı bölgesi (jurisdiction) mi, otomatik mi?

---

## 1. Bugünkü durum (koddan)

### 1.1 Yerel veri düzeni

Abonelik sürümünde (Mac `AINotepadHosted`, iPhone `AINotepadiOS`) kullanıcı verisi hesap başınadır
(`Packages/AINotepadCore/Sources/AINotepadCore/Support/AccountData.swift`):

```
~/Library/Application Support/AINotepad Hosted/          (Mac; iPhone'da uygulamanın Application Support'u)
  Models/, CrashReports/                                  hesaplar arası ortak, kullanıcı içeriği değil
  Accounts/<accountDataKey>/                              anahtar = SHA-256(userId)'nin ilk 16 baytı, hex
    Sessions/<yyyyMMdd-HHmmss>/                           bir toplantı (klasör adı = MeetingRecord.id)
      meeting.json                                        MeetingRecord (tüm metin, not, işaretler)
      me.m4a, others.m4a  (kayıt sırasında .caf)          16 kHz mono AAC, 32 kbps (Audio/AudioFinalizer.swift)
      Screens/<geçen süre>.jpg                            yalnız Mac, ekran görüntüleri (Screen/ScreenSnapshots.swift)
    AskHistory/<uuid>.json                                Sor sohbetleri (Meeting/AskHistory.swift)
    People.json                                           kişiler defteri, silinenler tombstone'lu (Meeting/People.swift)
    Voices.json                                           kişilerin ses izleri (Diarization/Voiceprint.swift)
  hesabın UserDefaults alanı: klasörler, Sor tarifleri, Markdown/Apple Notlar ayarları
  hesabın Anahtar Zinciri servisi: not hedefleri, görev araçları (App/Hosted/HostedAccountData.swift)
```

- `MeetingRecord` (`Meeting/MeetingRecord.swift`) tek dosyada hem **değişmeyen içeriği** (canlı ve son geçiş
  bölümleri, kelime zamanları, çeviriler, ses izleri) hem **kullanıcının değiştirdiği durumu** taşır: `title`,
  `note`, `noteHistory` (en fazla 10 sürüm), `sharedNotes` (paylaşım dillerindeki not önbelleği), `myNotes`,
  `speakerNames`, `completedTasks`, `remindedTasks`, `folder`, `highlights`, `sentDestinationIDs`, `sentTaskKeys`,
  `notesSentAt`, `webhookSentAt`, `audioDeleted`, `status`.
- Görevlerin "tamamlandı" durumu ayrı bir dosya değil, kayıttaki `completedTasks` (görev anahtarları, `taskKey`).
- Ses saklama: `audioToDelete` (`Meeting/MeetingStore.swift`) bitmiş toplantının sesini `audioRetentionDays` sonra
  siler (varsayılan **30 gün**, Mac'te 7–365 arası). **Ekran görüntüleri otomatik silinmez.**
- Çevrimdışı kuyruk (`Hosted/HostedOffline.swift`): bağlantısızken kaydedilen toplantı `queued` durumunda bekler,
  `clientRef` ile sunucuda aynı oturuma bağlanır. Eşitleme yalnızca `done` (ve isteğe bağlı `failed/interrupted`)
  toplantıları taşımalı; kayıttaki/işlenen toplantı asla.
- Hesap değiştirme: Mac'te süreç yeniden başlar; iPhone'da yazan her iş kapanınca yerinde değişir
  (`AppPaths.switchAccount`, `accountSwitchReadiness`). Eşitleme motoru da bu "yazan iş" listesine girmeli.
- MCP (Mac) yalnız `Accounts/<anahtar>/Sessions`'ı okur (`hostedMCPArchive`): eşitlenen toplantılar bu klasöre
  inmeli ki yapay zekâ uygulamaları da görsün.

### 1.2 Gerçek boyutlar (bu Mac'teki 13 toplantı, 15 sn–17,5 dk)

| Parça | Ölçülen | Saat başına | Not |
|---|---|---|---|
| `meeting.json` (ham) | 250–310 bayt/sn | **~0,9–1,1 MB/sa** | `prettyPrinted` + kelime zamanları |
| `meeting.json` (gzip -9) | ham/6,3 | **~0,18 MB/sa** | şifrelemeden önce sıkıştırılır |
| Ses (`me.m4a`+`others.m4a`) | 4,1 KB/sn | **~15 MB/sa** (tavan ~29 MB/sa: 2×32 kbps) | sessiz izler küçük kalıyor |
| Ekran görüntüsü (Mac) | ~320 KB/adet | tipik ~10 MB/sa (≈30 adet) | tavan: toplantı başına 120 adet ≈ 38 MB |
| Sor sohbeti | birkaç KB–100 KB | — | |
| `People.json`, `Voices.json` | birkaç KB | — | |

Kullanım tavanı: aboneye ayda **10 saat** bulut dökümü (`MONTHLY_CAP_HOURS`, `server/wrangler.jsonc`), toplantı
başına en çok 240 dk. Yerel motorla kayıt bu tavanı aşabilir; yoğun senaryoda 20 sa/ay da hesaplandı.

### 1.3 Geliştirici sürümündeki iCloud eşitlemesi (yeniden kullanılabilecekler)

`Support/CloudStorage.swift` + `App/AppModel.swift` (`CloudSyncController`), kapsayıcı `iCloud.com.senoldogan.AINotepad`
(yalnız `App/AINotepad.entitlements`; abonelik sürümünün yetkilerinde iCloud yok):

- Kayıt ve işleme her zaman yerelde; `done` olan toplantı klasörü `setUbiquitous` ile
  `<kapsayıcı>/Documents/Sessions/<id>` altına taşınır. Liste yerel + iCloud klasörünün birleşimi.
- Değişiklik izleme: `ICloudMeetingWatcher` (`NSMetadataQuery`, 1 sn birleştirme).
- Çakışma: `resolveCloudConflicts` (`NSFileVersion`) → **son yazılan kazanır**, diğer sürümlerdeki kullanıcı
  işaretleri eklenir: `mergingConflictVersions` (`Meeting/TaskTracking.swift`) tamamlanan/anımsatılan/araca gönderilen
  görevleri ve not gönderim işaretlerini birleştirir; `mergingMeetingCopies` sesin silinmiş olmasını korur.
- Uzun not işleri bitince diskteki en güncel kayda uygulanır (`withJobMarks`): iş sürerken diğer cihazdan gelen
  işaretler ezilmez. Bu "en güncel kayda uygula" deseni iPhone kodunda da var (`iOS/AINotepadiOSApp.swift`).

**Bu saf birleştirme fonksiyonları hangi taşıma seçilirse seçilsin yeniden kullanılır.** Taşıma katmanı
(`setUbiquitous`, `NSMetadataQuery`, `NSFileVersion`) yalnız A'da kullanılır.

**Abonelik sürümünde neden açılmadı** (kod yorumları ve geçmiş, `05bc649`):

- iOS: "iCloud eşitlemesi bu sürümde kapalı; Mac'le eşitleme ayrı bir Gistsmith kapsayıcısıyla gelecek."
- `CloudSyncController` hesap başına veriyi bilmiyor: `AppPaths.sessionsDirectory()` ↔ tek bir
  `Documents/Sessions` taşıyor. Aynı Mac'te iki Gistsmith hesabı aynı iCloud klasörünü görür (hesap ayrımı bozulur).
- Gistsmith hesabı (Google ya da Apple ile giriş) ≠ cihazın iCloud hesabı; eşleşmezse eşitleme olmaz ve bunu
  uygulama da sunucu da güvenilir şekilde anlayamaz.
- iCloud'a taşınan klasör `Accounts/<anahtar>/Sessions` dışına çıkar: MCP arşivi, hesap değiştirme, ses saklama
  ("yalnız bu cihazın klasörü", `localMeetingIDs`) yeniden düşünülmeli.

### 1.4 Sunucu bugün ne saklıyor

D1 (`server/migrations/0001…0049`): kullanıcılar, giriş kimlikleri, jetonlar, cihaz doğrulama, abonelik/fatura,
`meeting_sessions` (süre, token, hata kodu; **içerik yok**), kullanım sayıları, telemetri. İçeriğe en yakın tek tablo:
`transcription_results` — son geçiş dökümü, **istemcinin anahtarıyla şifreli**, en fazla 2 saat (`0021`). R2 kovası
yok. Hesap silme (`server/src/account.ts`) tüm satırları hemen siler.

Gizlilik politikası (`web/src/pages/privacy.astro`) bugün açıkça şunu söylüyor: "Our servers keep no audio, notes or
translations", "The apps do not sync them to any cloud service, and meetings recorded on one device do not appear on
the other." **Her seçenek bu metni değiştirir** (A/B'de "iCloud'unda", C'de "şifreli kopya").

### 1.5 Apple tarafı

- Mac Gistsmith **Developer ID + Sparkle** ile dağıtılıyor (App Store değil); iPhone App Store'da. İkisi **aynı paket
  kimliğini** kullanıyor: `com.senoldogan.AINotepad.hosted` (`project.yml`).
- Sonuç 1: iCloud Anahtar Zinciri'nde `kSecAttrSynchronizable` öğe Mac ve iPhone'da aynı varsayılan erişim grubundan
  okunur (geliştirici sürümü bunu anahtarlar için zaten yapıyor: `saveSyncedSecret`, `Support/Keychain.swift`). Mac
  için iCloud/Anahtar Zinciri yetkili Developer ID provisioning profili gerekir (geliştirici sürümünde var, bkz.
  `9aaf03d`).
- Sonuç 2: Developer ID uygulaması iCloud Drive kullanabiliyor (geliştirici sürümü kanıt). CloudKit'in Developer ID'de
  desteklendiği Apple'ın yetenek tablosunda geçiyor ancak bu oturumda tablo hücreleri okunamadı — B seçilirse ilk iş
  doğrulanmalı (§12).
- Apple ile giriş Developer ID'de yok; Mac'te giriş tarayıcıda. Eşitleme kimliği zaten Gistsmith `userId` olduğundan
  C bundan etkilenmez.

---

## 2. Eşitlenecek veri ve sınıfları

| Veri | Boyut | Değişir mi | Aşama 1 (metin) | Aşama 2 |
|---|---|---|---|---|
| Toplantı içeriği: bölümler, kelime zamanları, çeviriler, `outline` | ~0,18 MB/sa sıkışık | yeniden işlemede değişir | ✓ | |
| Toplantı durumu: başlık, not, not geçmişi, kendi notların, konuşmacı adları, görev işaretleri, klasör, vurgular, gönderim işaretleri | KB | sık, iki cihazda | ✓ | |
| `sharedNotes` (dil önbelleği) | KB | not değişince silinir | ✓ (önbellek; çakışmada atılabilir) | |
| Ses izleri (`voiceprints`, `Voices.json`) | KB | nadiren | ✓ (öneri; kararı §12) | |
| `People.json` | KB | ara sıra | ✓ | |
| Sor sohbetleri | KB | sohbet devam ettikçe | ✓ | |
| Klasör listesi, Sor tarifleri (hesabın UserDefaults'u) | B | nadiren | ✓ | |
| Ses | ~15 MB/sa | silinir (saklama) | ✗ cihazda kalır | ✓ isteğe bağlı |
| Ekran görüntüleri (Mac) | ~10 MB/sa | tek tek silinebilir | ✗ | ✓ isteğe bağlı |
| Not hedefleri, görev araçları (Anahtar Zinciri: OAuth jetonları) | B | nadiren | ✗ (cihaz başına bağlanır) | ✗ |
| Çökme raporları, modeller | — | — | ✗ | ✗ |

Not hedefleri/görev aracı jetonları bilinçli olarak eşitlenmez: başka bir cihaza gizli anahtar taşımak ayrı bir risk
ve "kendiliğinden gönder" işlerinin iki cihazda iki kez çalışmasına yol açar. Gönderim işaretleri (`sentDestinationIDs`,
`sentTaskKeys`) ise eşitlenir: böylece Mac'te gönderilen not iPhone'da yeniden gönderilmez.

---

## 3. Seçenek A — iCloud Drive (ubiquity container)

**Nasıl:** Abonelik sürümüne yeni kapsayıcı (`iCloud.com.senoldogan.AINotepad.hosted`; geliştirici sürümünün
kapsayıcısıyla karışmasın). Klasör `Documents/Accounts/<accountDataKey>/{Sessions,AskHistory,People.json}`.
`CloudSyncController` hesap anahtarıyla parametrelenir; geri kalanı bugünkü kod.

- **Kurulum:** Ayarlar › "iCloud ile eşitle". iCloud'a giriş yoksa ya da iCloud Drive kapalıysa açılamaz
  (`iCloudUnavailable`).
- **Hangi hesap:** cihazın iCloud hesabı. Mac ile iPhone farklı Apple hesabındaysa **eşitleme olmaz ve uygulama bunu
  söyleyemez** (iCloud Drive API'si hesap kimliği vermez; `ubiquityIdentityToken` yalnız "aynı cihazda değişti mi"yi
  söyler).
- **Çevrimdışı:** iyi; iCloud kendisi sıraya alır. "Depolamayı optimize et" dosyaları indirir/boşaltır (kodda
  `downloading` durumu var).
- **Çakışma:** dosya düzeyinde; `meeting.json` bütün olarak son yazılan kazanır + işaret birleştirme. İki cihazda
  aynı anda not düzenlemesi → biri kaybolur (yalnız işaretler korunur).
- **Gizlilik:** veri kullanıcının iCloud'unda; Apple anahtarlı şifreleme (Gelişmiş Veri Koruması açıksa uçtan uca).
  Bizde hiçbir şey yok. Politika: "iCloud ile eşitlemeyi açarsan Apple hesabındaki iCloud'da saklanır".
- **Hesap silme:** sunucudan silemeyiz; uygulama hesabı silerken iCloud klasörünü de silmeli; hesap web'den
  silinirse bir sonraki açılışta uygulama silmeyi önermeli. Apple 5.1.1(v) açısından makul, ama tam garanti yok.
- **Kota:** kullanıcının iCloud'u (ücretsiz 5 GB; çoğu kişide fotoğraflarla dolu). Ses + ekran yılda 1–4 GB
  yiyebilir → "iCloud dolu" hataları.
- **App Store:** sorun yok (iCloud yaygın). Mac için iCloud'lu Developer ID profili ve `release-gistsmith.sh`'de profil
  gömme denetimi.
- **İş:** ~2–3 hafta (hesap başına kapsayıcı yolu, hesap değiştirmede izleyiciyi yeniden başlatma, MCP ve ses
  saklamanın iCloud klasörünü görmesi, Sor/kişiler için dosya birleştirme, ayarlar arayüzü iki platformda, testler).
- **Riskler:** "neden iPhone'da görünmüyor?" destek talepleri ve hata ayıklayamamak (iCloud Drive kara kutu, gecikme
  saniyeler–saatler); paylaşılan Mac'te iki Gistsmith hesabı aynı iCloud'da; asla web/Android/Windows.

## 4. Seçenek B — CloudKit özel veritabanı

**Nasıl:** `CKSyncEngine` (macOS 14+/iOS 17+; hedeflerimiz macOS 15 / iOS 26.1). Her Gistsmith hesabı için ayrı
kayıt bölgesi (zone, ad = `accountDataKey`). Kayıt türleri: `Meeting` (durum alanları), `MeetingContent`
(sıkıştırılmış içerik, `CKAsset`), `AskChat`, `People`. Metin alanları `encryptedValues` ile (anahtarlar iCloud
Anahtar Zinciri'nde, uçtan uca). Ses ve görüntüler `CKAsset` (Apple anahtarlı; Gelişmiş Veri Koruması açıksa uçtan uca).

- **Kurulum/hesap:** A ile aynı kısıt: cihazların iCloud hesabı aynı olmalı. B'de en azından anlaşılabilir:
  `CKContainer.userRecordID` cihazlar arasında karşılaştırılabilir (ör. sunucuya özetini yazarak "Mac'in farklı bir
  iCloud hesabında" uyarısı gösterilebilir).
- **Çakışma:** alan düzeyinde (kayıt değişiklik etiketi; `serverRecordChanged` → üç yollu birleştirme). A'dan çok
  daha iyi. Push ile hızlı (sessiz bildirim).
- **Maliyet:** bize $0; özel veritabanı kullanıcının iCloud kotasından düşer.
- **Hesap silme:** uygulama bölgeyi siler; web'den silinince A ile aynı açık.
- **İş:** ~4–5 hafta (şema + üretime dağıtım, `CKSyncEngine` durumu, kayıt eşlemesi, varlık indirme, hesap
  değiştirme, iki platform arayüzü, testler — CloudKit'in otomatik testi zor; gerçek iCloud hesabıyla elle QA).
- **Riskler:** A'nın kimlik ve kota sorunları aynen; Developer ID + CloudKit profili; CloudKit Console dışında hata
  ayıklama yok; üretim şeması geri alınamaz (yalnız eklenebilir).

## 5. Seçenek C — kendi sunucumuz (R2 + D1), uçtan uca şifreli

**Nasıl:** Eşitleme kimliği **Gistsmith `userId`** (giriş zaten var). Cihaz her nesneyi hesabın eşitleme anahtarıyla
şifreler; sunucu yalnız şifreli bloklar ve sürüm numaraları görür. Ayrıntı §8.

- **Kurulum:** sıfır adım (aynı hesapla giriş yeter). Yeni cihaz anahtarı şu sırayla bulur: (1) iCloud Anahtar
  Zinciri'ndeki eşitlenen öğe (aynı paket kimliği → Mac ve iPhone'da aynı grup; çoğu kullanıcıda kendiliğinden),
  (2) yoksa "Cihaz ekle": diğer cihazda gösterilen 6 haneli kod / QR ile anahtar aktarımı (sunucu yalnız şifreli
  zarfı taşır), (3) isteğe bağlı kurtarma kodu.
- **Çevrimdışı:** yerel dosyalar asıl kaynak kalır; değişiklikler giden kuyruğuna girer, bağlantı gelince gönderilir.
- **Çakışma:** sunucu sürüm numarasıyla iyimser eşzamanlılık + istemcide **üç yollu birleştirme** (son eşitlenen
  "taban" kopya yerelde tutulur). Bugünkü `mergingConflictVersions` ve `withJobMarks` yeniden kullanılır. §8.4.
- **Gizlilik:** sunucu içeriği okuyamaz; görebildiği üst veri: nesne sayısı, boyutlar, değişiklik zamanları,
  hangi cihazın yüklediği. Politika metni yeniden yazılır (§9).
- **Hesap silme / abonelik bitişi:** tamamen bizim elimizde: hesap silinince R2 öneki ve satırlar silinir (cron
  toplu silme), abonelik bitince N gün sonra.
- **Web:** ileride tarayıcıda okuma mümkün (anahtar tarayıcıya "cihaz ekle" ile verilir) — A/B'de imkânsız.
- **App Store:** sunucuda kullanıcı içeriği saklamak normal; Gizlilik Etiketi güncellenir (§9.2). Şifreleme CryptoKit
  standart algoritmaları; `ITSAppUsesNonExemptEncryption = false` durumu yeniden değerlendirilmeli (§12).
- **İş:** Aşama 1 ~5–6 hafta, Aşama 2 +2 hafta (§11).
- **Riskler:** anahtar yönetimi (kayıp = eşitlenen kopya kaybı; cihazdakiler durur), sunucuda kullanıcı içeriği
  tutmanın sorumluluğu (şifreli bile olsa ihlal bildirimi, KVKK/GDPR kayıtları), bugünkü "hiç saklamıyoruz" pazarlama
  cümlesi değişir, sunucu kesintisinde eşitleme durur (yerel çalışma sürer).

**C' — sunucu anahtarlı şifreleme (uçtan uca değil):** anahtar sunucuda (ör. Workers secret + kullanıcı başına
türetme). Daha basit (anahtar dağıtımı yok, kurtarma sorunu yok, web kolay, sunucuda arama mümkün) ama "biz
okuyabiliriz" demek ve bugünkü gizlilik çizgisinden belirgin geri adım. Önerilmez; karar §12.

## 6. Seçenek D — karma

- **D1 (önerilen ilk aşama):** metin C ile; ses ve görüntü cihazda. Diğer cihazda toplantı açılınca "Ses bu
  toplantıyı kaydeden Mac'te" gösterilir; oynatıcı ve "Tekrar işle" o cihazda kalır.
- **D2:** metin C ile, ses/görüntü kullanıcının iCloud'unda (CloudKit varlık). İki taşıma, iki hata kaynağı, iki
  gizlilik metni — karmaşıklık kazancı aşar. Önerilmez.
- **D3:** ses/görüntü yalnız istenince: diğer cihaz "sesi getir" der, kaydeden cihaz çevrimiçiyse yükler, alıcı
  indirince sunucudan silinir (kısa ömürlü aktarma). Depolama sıfıra yakın ama iki cihazın aynı anda açık olmasını
  ister; Aşama 2'de "her zaman yükle" yerine düşünülebilir.

---

## 7. Karşılaştırma tablosu

| Ölçüt | A iCloud Drive | B CloudKit | C Sunucu E2EE (tam) | D1 Sunucu E2EE (yalnız metin) |
|---|---|---|---|---|
| Kimlik | iCloud hesabı | iCloud hesabı | Gistsmith hesabı | Gistsmith hesabı |
| Google ile giriş + farklı Apple ID | ✗ çalışmaz, sessiz | ✗ çalışmaz, uyarılabilir | ✓ | ✓ |
| Aynı Mac'te iki Gistsmith hesabı | klasörle ayrılır, aynı iCloud'da | bölgeyle ayrılır, aynı iCloud'da | ✓ tam ayrım | ✓ |
| Kurulum | iCloud + iCloud Drive açık | iCloud açık | yok (anahtar çoğu zaman kendiliğinden) | yok |
| Kullanıcı kotası | iCloud (5 GB ücretsiz) | iCloud | bizim sınırımız (ör. 10 GB) | ihmal edilir |
| Çakışma | dosya, son yazan + işaretler | alan düzeyi | alan düzeyi, üç yollu | alan düzeyi, üç yollu |
| Hız | sn–dk (bazen saat) | sn (push) | sn (ön planda çekme; ileride push) | sn |
| Uçtan uca şifreleme | yalnız ADP açıksa | metin evet (`encryptedValues`), varlık ADP'ye bağlı | evet | evet |
| Bizim gördüğümüz | hiçbir şey | hiçbir şey (Console'da sayılar) | boyut, sayı, zaman | boyut, sayı, zaman |
| Hesap silme | uygulama siler; web silmesi açık kalır | aynı | tam (sunucu) | tam |
| Web / başka platform | ✗ | ✗ (CloudKit JS var ama E2EE alanlar okunamaz) | ✓ ileride | ✓ ileride |
| Hata ayıklama | çok zor | zor | kolay (log, yönetim paneli) | kolay |
| Bize aylık maliyet (1.000 kullanıcı) | $0 | $0 | ~$5–10 | ~$1–2 |
| İş (hafta) | 2–3 | 4–5 | 7–8 | 5–6 |
| Mevcut kodu kullanma | en çok | birleştirme fonksiyonları | birleştirme fonksiyonları + `transcription_results` deseni | aynı |

---

## 8. Önerilen tasarım (C, aşamalı) — veri modeli ve çakışma

### 8.1 Eşitleme nesneleri

Her nesne: `objectId` (rastgele UUID, sunucuda opak), `kind`, `rev` (sunucu sayacı), şifreli gövde. Klasör adı
(`yyyyMMdd-HHmmss`) zaman bilgisi taşıdığı için sunucuya gönderilmez; şifreli gövdenin içindedir.

| `kind` | İçerik (şifreli, gzip) | Ne zaman yazılır |
|---|---|---|
| `meeting.state` | `MeetingRecord`'un kullanıcı durumu: başlık, `note`, `noteHistory`, `myNotes`, `speakerNames`, `completedTasks`, `remindedTasks`, `folder`, `highlights`, `sent*`, `audioDeleted`, `template`, `attendees`, `calendarEventID`, `status`, klasör adı (`id`), `startedAt`/`endedAt` | her düzenlemede (birleştirilerek, ~2 sn gecikmeyle) |
| `meeting.content` | `liveSegments`, `finalSegments`, `translations`, `voiceprints`, `language`, `engine` … | işleme / yeniden işleme bitince (nadiren) |
| `ask.chat` | bir `AskConversation` | sohbet bitince / yeni tur |
| `people` | `PeopleBook` (kayıtlı + silinen tombstone'lar) | değişince |
| `voices` | `Voices.json` | değişince |
| `prefs` | klasör listesi, Sor tarifleri, hesapla gelen ayarlar (`settings`: not dili, dil modu, ana dil, canlı çeviri görünümü, not şablonu, "Ne kaçırdım?" süresi, Sor web araması, bildirimler; ayar başına değişiklik anı, son yazan kazanır; liste `Sync/SyncedSettings.swift` `syncedSettingKeys`) | değişince |
| `meeting.audio` / `meeting.screen` (Aşama 2) | ses dosyası / tek JPEG; içerik adresli (şifreli metnin özeti) | toplantı bitince / görüntü eklenince |

`meeting.state` ile `meeting.content`'i ayırmak önemli: büyük ve neredeyse hiç değişmeyen metin, her görev
işaretinde yeniden yüklenmez; çakışmalar yalnız küçük durum nesnesinde olur.

Silme: nesne silinmez, `deleted` tombstone olur (`rev` artar); 90 gün sonra cron temizler. Toplantı silme hem
`state` hem `content` hem varlıklar için tombstone yazar.

### 8.2 Sunucu (Cloudflare)

- **R2 kovası** `gistsmith-sync` (isteğe bağlı AB yargı bölgesi): anahtar `u/<userHash>/<objectId>/<rev>`. Küçük
  nesneler (≤1 MB) Worker üzerinden; ses/görüntü için kısa ömürlü imzalı yükleme adresi (S3 API, çok parçalı) —
  Worker veri yolunda değil, CPU maliyeti yok; büyük ses dosyaları istek gövdesi sınırına takılmaz.
- **D1 tabloları** (yalnız dizin, içerik değil):
  - `sync_objects(user_id, object_id, kind, rev, size, deleted, r2_key, updated_at, updated_by_device)` +
    `(user_id, rev)` dizini (değişiklik akışı).
  - `sync_cursor(user_id, last_rev)` — kullanıcı başına artan sayaç.
  - `sync_key_envelopes(user_id, envelope_id, kind, ciphertext, created_at)` — "cihaz ekle" ve kurtarma için
    şifreli anahtar zarfları (sunucu açamaz).
  - D1 10 GB/veritabanı sınırı içerik için uygun değil; yalnız dizin satırları burada (kullanıcı başına KB'lar).
- **Uç noktalar:**
  - `GET /v1/sync/changes?since=<rev>&limit=500` → `{changes:[{objectId,kind,rev,size,deleted}], nextSince}`
  - `GET /v1/sync/objects/{id}` → şifreli gövde (ya da büyük nesne için imzalı indirme adresi)
  - `PUT /v1/sync/objects/{id}` + `If-Match: <rev>` → `200 {rev}` ya da `409 {currentRev}`
  - `POST /v1/sync/uploads` → imzalı yükleme adresi (Aşama 2) ; `POST /v1/sync/uploads/{id}/complete`
  - `DELETE /v1/sync/objects/{id}` + `If-Match`
  - `POST/GET /v1/sync/pairing` → "cihaz ekle" zarfı (10 dk ömürlü, tek kullanımlık)
- **Kurallar:** yalnız etkin abonelik/deneme yazabilir (okuma ve silme her zaman); hesap başına kota (ör. 10 GB, Aşama
  2'de); hız sınırlayıcı (`SYNC_USER_LIMITER`); `cleanup.ts`'e tombstone ve bitmiş abonelik temizliği;
  `account.ts` silmesine R2 öneki + satırlar; yönetim paneline eşitleme sayıları (kullanıcı, GB, hata) — içerik değil.
- **Bildirim:** v1'de uygulama ön plana gelince ve her yerel değişiklikten sonra çeker. v2: kullanıcı başına Durable
  Object (WebSocket hibernation) ya da APNs sessiz bildirim (iPhone).

### 8.3 Şifreleme ve anahtarlar

- **Hesap eşitleme anahtarı (ASK):** 256 bit, ilk eşitleyen cihazda rastgele üretilir. Sunucuya hiç açık gitmez.
- **Nesne şifrelemesi:** AES-256-GCM (CryptoKit). Nesne anahtarı = HKDF-SHA256(ASK, info: `objectId`). AAD =
  `userId‖objectId‖kind‖rev-taban` (sunucu nesneleri yer değiştiremez, eski sürümü yenisi gibi sunamaz).
  Gövde önce gzip'lenir. (Desen bugünkü `transcription_results` ile aynı: anahtar istemcide, sunucu okuyamaz.)
- **Anahtarın cihazlara ulaşması:**
  1. **iCloud Anahtar Zinciri** (`kSecAttrSynchronizable`, servis `<HostedKeychainService>.sync.<accountKey>`):
     aynı Apple hesabındaki Mac ve iPhone'da kendiliğinden. `saveSyncedSecret` hazır.
  2. **Cihaz ekle:** yeni cihaz geçici X25519 anahtarı üretir, sunucuya açık anahtarını ve 6 haneli kodu bırakır;
     ASK'ı olan cihaz kodu girer, ECDH ile ASK'ı şifreleyip zarf bırakır. Kod ortadaki-adam saldırısını önler
     (SAS doğrulaması). iCloud Anahtar Zinciri kapalı ya da farklı Apple hesabı için.
  3. **Kurtarma kodu (isteğe bağlı):** 24 kelime ya da 32 karakter; ASK bundan türetilen anahtarla şifreli zarf
     olarak sunucuda. Tüm cihazlar kaybolursa tek yol.
- **Hiçbir yoldan anahtar yoksa:** "Bu hesabın eşitlenen toplantıları başka bir cihazında. O cihazda Ayarlar ›
  Eşitleme › Cihaz ekle." Cihazdaki toplantılar etkilenmez; kullanıcı isterse "yeniden başlat" (eski şifreli kopyalar
  silinir, bu cihazınkiler yeni anahtarla yüklenir).
- **Anahtar döndürme:** v1'de yok (cihaz kaldırma = oturumu kapatma). İleride: yeni ASK + tüm nesneleri yeniden
  şifreleme (metin küçük olduğu için ucuz).

### 8.4 Çakışma stratejisi

Her nesne için yerelde `base` (son eşitlenen düz metin kopya) tutulur: `Sessions/<id>/.sync/state.base.json`.

1. Yerel değişiklik → giden kuyruğuna `objectId` girer → `PUT If-Match: baseRev`.
2. `409` → uzak sürüm indirilir → **üç yollu birleştirme** `merge(base, local, remote)` (saf fonksiyon) → yeniden
   `PUT If-Match: remoteRev`. Döngü sınırlı (ör. 5), sonra hata ve sonraki turda yeniden.
3. Gelen değişiklik, yerelde gönderilmemiş değişiklik yoksa doğrudan yazılır; varsa aynı birleştirme.

Alan kuralları (`mergeMeetingState(base:local:remote:) -> MeetingRecordState`, saf):

| Alan | Kural | Örnek |
|---|---|---|
| `completedTasks`, `remindedTasks`, `sentDestinationIDs`, `sentTaskKeys` | **küme üç yollu**: base'e göre eklenenler ve çıkarılanlar iki taraftan uygulanır | iPhone'da görev tamamlandı, Mac'te başka görev tamamlandı → ikisi de; Mac'te geri alındı → geri alınır |
| `title`, `folder`, `template`, `speakerNames[n]`, `audioDeleted` | **alan bazında**: yalnız bir taraf değiştirdiyse o; ikisi de değiştirdiyse son yazan (değişiklik anı istemcide alan başına tutulur) | Mac başlığı, iPhone klasörü değiştirdi → ikisi de kalır |
| `note` | ikisi de değiştirdiyse son yazan kazanır, **kaybeden `noteHistory`'ye girer** (`noteHistoryLimit` = 10) — kullanıcı "önceki sürüm"den geri alabilir; `sharedNotes` önbelleği silinir | iki cihazda aynı anda "notu yeniden yaz" |
| `myNotes` (serbest metin) | tek taraf → o; ikisi de → satır düzeyinde üç yollu birleştirme, birleşemezse ikisi ayraçla birlikte ve "iki cihazda düzenlendi" uyarısı | |
| `highlights` | kimliğe göre birleşim (silinenler tombstone) | |
| `status`, `failureMessage`, `notice` | yalnız toplantıyı kaydeden cihaz yazar (sahip cihaz kimliği gövdede) | iPhone, Mac'in işlediği toplantıyı "yarıda kaldı" işaretlemez |
| Uzun not işleri | bugünkü `withJobMarks` deseni: iş bitince diskteki en güncel kayda uygulanır | |

`meeting.content` için çakışma neredeyse yok (yalnız yeniden işlemede yazılır, onu da sahip cihaz yapar): son yazan
kazanır. Yeniden işleme sonrası görev işaretleri `withCarriedTaskMarks` ile taşınır (bugünkü gibi).

`people`: `PeopleBook` zaten silinenleri `removedAt` ile tutuyor → kişi adına göre birleşim, en yeni ekleme/silme
kazanır. `ask.chat`: turlar `id`'ye göre birleşim (ekle-sadece).

### 8.5 İstemci bileşenleri

- `Packages/AINotepadCore/Sources/AINotepadCore/Sync/` (yeni): saf modeller ve birleştirme (`SyncObject`,
  `mergeMeetingState`, `splitMeetingRecord`/`joinMeetingRecord`), şifreleme (`SyncCrypto`), HTTP adaptörü
  (`HostedSyncClient`, `HostedClient` yeniden deneme desenleriyle), motor (`SyncEngine` actor: giden kuyruk, çekme,
  birleştirme, uygulama).
- Uygulama: eşitleme `AccountDataWriter`'a (`.syncing`) eklenir — hesap değiştirme bekler. Gelen değişiklik bugünkü
  "diskteki en güncel kayda uygula" yolundan listeye yansır. Ayarlar › Eşitleme (Mac tam açıklamalı, iPhone kısa;
  `mac-iphone-parity`), "Cihaz ekle", "Kurtarma kodu", durum ("Son eşitleme 2 dk önce", hata).
- Toplantı kimliği çakışması: iki cihazda aynı saniyede başlayan iki toplantı aynı klasör adını alabilir → gelen
  toplantının `objectId`'si yerel klasördekinden farklıysa klasör `-2` ekiyle açılır (eşleme `.sync/object-id`).
- Ses/görüntü yokken (Aşama 1) diğer cihaz: oynatıcı ve "Ekranlar" sekmesi "bu toplantıyı kaydeden <cihaz>da"
  gösterir; Sor yine çalışır (metin var), ekranlı Sor yalnız sahip cihazda.

---

## 9. Gizlilik, hukuk, App Store

### 9.1 Politika metni (`web/src/pages/privacy.astro`) — değişecek yerler

- Özet: "Our servers keep no audio, notes…" → "If sync is on, our server stores an end-to-end encrypted copy of your
  notes, transcripts, tasks, people and Ask chats so they appear on your other devices. It is encrypted on your device
  with a key only your devices hold; we cannot read it." (+ Aşama 2'de ses ve ekran görüntüleri.)
- "Storage" bölümü: "do not sync them to any cloud service…" cümlesi kaldırılır; eşitlemenin nasıl kapatılacağı,
  kapatınca sunucudaki kopyanın silineceği.
- Tablo (§ ne tutuyoruz): yeni satır "Synced content (encrypted)": içerik okunamaz; görülen üst veri (boyut, sayı,
  zaman, cihaz); amaç; saklama.
- Saklama: hesap silinince hemen (R2 silme toplu işle 24 saat içinde), abonelik bitince 90 gün (karar), eşitleme
  kapatılınca hemen, silinen toplantı tombstone'u 90 gün.
- Alt işleyenler: Cloudflare R2 depolama (bölge/AB yargı bölgesi kararına göre).
- Kurtarma kodunun bizde olmadığı, kaybedilirse kopyanın açılamayacağı.
- Kullanım şartları (`terms.astro`): eşitlemenin yedek olmadığı, kota.
- Site ve sürüm notları: kullanıcı faydası dilinde ("toplantıların Mac ve iPhone'da"), iç ayrıntı yok.
- **Zincirin tamamı** (`change-the-whole-chain`): sunucu + yönetim paneli istatistikleri + site + iki uygulama +
  yasal metinler + testler aynı sürümde.

### 9.2 App Store

- App Privacy etiketi: "User Content → Other User Content / Audio Data", "Linked to you", amaç "App Functionality".
  Apple'ın uçtan uca şifreli veri için istisnası varsa (sağlayıcının okuyamadığı veri) beyan gerekmeyebilir — Apple'ın
  "App privacy details" sayfasıyla doğrulanmalı; şüphede beyan et.
- `ITSAppUsesNonExemptEncryption = false` (bugün iPhone'da): kullanıcı verisini korumak için standart şifreleme
  çoğunlukla muafiyet kapsamında; ama yeni E2EE özelliği için ihracat uyumluluk cevabı gözden geçirilmeli.
- Hesap silme (5.1.1(v)): C'de tam karşılanır.
- İnceleme notu: "Sync is end-to-end encrypted; to test, sign in with the demo account on two devices."

### 9.3 A/B için metin

"If you turn on iCloud sync, meetings are stored in your iCloud account (Apple's terms apply); we never receive
them." + iCloud kotası ve Gelişmiş Veri Koruması açıklaması.

---

## 10. Maliyet modeli

### 10.1 Birim fiyatlar (Cloudflare, 2026-11-03'te okundu, §13)

- **R2 Standard:** depolama **$0.015/GB-ay**; Class A (yazma/listeleme) **$4.50/milyon**; Class B (okuma)
  **$0.36/milyon**; **çıkış (egress) ücretsiz**; ücretsiz: 10 GB-ay, 1 M Class A, 10 M Class B / ay.
  (Infrequent Access: $0.01/GB-ay ama $0.01/GB okuma ve 30 gün asgari — ses için cazip değil.)
- **D1 (Workers Paid):** okunan satır ilk 25 milyar/ay dahil, sonra $0.001/milyon; yazılan satır ilk 50 M/ay dahil,
  sonra **$1.00/milyon**; depolama ilk 5 GB dahil, sonra $0.75/GB-ay; veritabanı başına en fazla 10 GB.
- **Workers Paid:** ayda $5 (zaten ödüyoruz); 10 M istek ve 30 M CPU-ms dahil; sonra $0.30/milyon istek,
  $0.02/milyon CPU-ms.
- **Durable Objects** (yalnız ileride push için): 1 M istek dahil, sonra $0.15/milyon; süre $12.50/milyon GB-sn.

### 10.2 Kullanıcı başına (aylık)

Varsayımlar: yoğun kullanıcı **10 sa/ay** (abone tavanı), stres **20 sa/ay**; toplantı başına ~1 saat; her toplantıda
~10 durum yazımı (görev işaretleri, başlık, not düzenleme); 2 cihaz, ayda ~3.000 eşitleme isteği (ön plana gelme +
değişiklik); ses saklama varsayılan 30 gün; ekran görüntüleri silinmiyor.

**Aşama 1 — yalnız metin (10 sa/ay):**

| Kalem | Hesap | $/ay |
|---|---|---|
| Depolama | 10 sa × 0,18 MB = 1,8 MB/ay birikir → 1 yılda ~22 MB = 0,022 GB × $0.015 | 0.0003 |
| R2 Class A | 10 toplantı × (10 durum + 1 içerik) + Sor/kişiler ~50 = ~160 yazma × $4.50/M | 0.0007 |
| R2 Class B | 2. cihaz her yazmayı okur ~160 + ilk kurulum × $0.36/M | 0.0001 |
| Workers isteği | 3.000 × $0.30/M (dahil kotayı aşınca) | 0.0009 |
| D1 yazma | ~200 satır × $1/M | 0.0002 |
| **Toplam** | | **≈ $0.002** |

**Aşama 2 — ses + ekran dahil (10 sa/ay):**

| Kalem | Hesap | $/ay |
|---|---|---|
| Ses depolama (30 gün saklama) | sabit durumda 10 sa × 15 MB = 0,15 GB (tavan 29 MB/sa → 0,29 GB) × $0.015 | 0.0023 (– 0.0044) |
| Ekran depolama (birikir) | 10 sa × 10 MB = 0,1 GB/ay; 12. ayda 1,2 GB × $0.015 | 0.0015 (1. ay) → 0.018 (12. ay) |
| Class A | ses: 10 toplantı × 2 dosya × ~3 parça = 60; ekran: ~300 → ~360 + metin 160 = ~520 × $4.50/M | 0.0023 |
| Metin (yukarıdan) | | 0.002 |
| **Toplam** | | **≈ $0.008 (1. ay) → $0.025 (12. ay)**; ses 365 gün saklanırsa +$0.03–0.05 → en kötü **≈ $0.05–0.08** |

20 sa/ay stres senaryosunda her şey ~2 katı: en kötü ~$0.10–0.15/ay. Abonelik $5.99/ay (yıllık $49 ≈ $4.08/ay):
en kötü durumda gelirin **≈ %2–4'ü**, tipik durumda %0.5'in altında. Çıkış ücretsiz olduğu için indirme maliyeti yok.

### 10.3 Ölçekte (aylık, tipik kullanıcı 4 sa/ay, %50'si Mac'te ekran görüntüsü açık, 1 yıl sonrası)

| Aktif kullanıcı | Yalnız metin | Ses + ekran |
|---|---|---|
| 100 | ~$0 (ücretsiz kotada) | ~$0 (≈ 30 GB; 10 GB ücretsiz) → ~$0.3 |
| 1.000 | ~$1–2 | ~$5–7 (≈ 300–400 GB) |
| 10.000 | ~$10–20 | ~$50–70 (≈ 3–4 TB) |

Workers $5 temel ücreti zaten ödeniyor. D1'de yalnız dizin satırları (kullanıcı başına KB) olduğu için 10 GB sınırına
on binlerce kullanıcıda bile yaklaşılmaz.

**A/B:** bize $0. Kullanıcıya: metin yılda ~22 MB (önemsiz), ses+ekran yılda 1–4 GB → ücretsiz 5 GB iCloud'u olan
kullanıcı için gerçek sorun; iCloud+ 50 GB $0.99/ay (ABD).

---

## 11. Aşamalı yayın planı (C)

Her aşamada iki platform birlikte (Mac ↔ iPhone eşitliği), "doğrulamadan sonra yayın" kuralıyla: QA + e2e + görsel +
sahip kontrolü.

| Aşama | Kapsam | Süre (tek geliştirici) |
|---|---|---|
| 0. Karar + doğrulamalar | §12'deki sorular; Developer ID profiline Anahtar Zinciri/iCloud yetkisi; politika taslağı | 2–3 gün |
| 1a. Sunucu | göç (`sync_objects`, `sync_cursor`, `sync_key_envelopes`), R2 kovası, uç noktalar, kota/hız sınırı, hesap silme + cleanup, yönetim paneli sayıları, vitest + `HostedE2E` | ~1,5 hafta |
| 1b. Çekirdek | `Sync/` modülü: bölme/birleştirme, üç yollu `mergeMeetingState`, `SyncCrypto`, `SyncEngine`, birim testleri (saf birleştirme) + gerçek yerel sunucuya karşı e2e (iki "cihaz" klasörü) | ~2 hafta |
| 1c. Uygulamalar | Ayarlar › Eşitleme, cihaz ekle, kurtarma kodu, durum/hata, hesap değiştirme, ses/ekran yok durumları, MCP | ~1,5 hafta |
| 1d. Yasal + site + sürüm | gizlilik/şartlar, site, App Privacy, TestFlight + Mac beta; içeriden kullanıcılarla 1–2 hafta deneme | ~0,5 hafta + deneme |
| 2. Ses ve ekran | imzalı çok parçalı yükleme, içerik adresli varlıklar, saklama ile sunucu silme, kota arayüzü, isteğe bağlı "yalnız Wi-Fi" | ~2 hafta |
| 3. (isteğe bağlı) | push (APNs / Durable Object), web'de okuma, anahtar döndürme | ayrı karar |

Geçiş: mevcut kullanıcıda eşitleme ilk açılışta bir kez sorulur; açınca bu cihazdaki tüm `done` toplantılar arka
planda yüklenir (ilerleme gösterilir). İkinci cihaz açınca ikisi birleşir (farklı toplantılar → ikisi de; aynı
toplantı olamaz çünkü toplantılar cihaza özgü kaydedildi).

Geri dönüş: eşitleme bir sunucu bayrağıyla (`SYNC_ENABLED`) kullanıcı/sürüm bazında kapatılabilir; yerel dosyalar
asıl kaynak olduğu için kapatmak veri kaybettirmez.

---

## 12. Açık sorular (sahibe)

1. **Seçenek:** C (önerilen) / A / B?
2. **Aşama 1 kapsamı:** ses ve ekran görüntüleri ilk aşamada dışarıda kalsın mı? (Önerilen: evet.)
3. **Şifreleme:** uçtan uca (önerilen) mi, sunucu anahtarlı (C') mı?
4. **Kurtarma kodu:** isteğe bağlı (önerilen) / zorunlu / hiç yok?
5. **Varsayılan:** yeni kullanıcıda eşitleme açık mı (önerilen: açık), mevcut kullanıcıya sorulsun mu (önerilen: evet)?
6. **Abonelik bitince** sunucudaki şifreli kopya kaç gün kalsın? (Önerilen: 90 gün; okuma/silme bu sürede açık.)
7. **Veri bölgesi:** R2 AB yargı bölgesi mi, otomatik konum mu? (AB müşterileri için AB önerilir; bütün kullanıcılar
   için tek kova daha basit.)
8. **Ses izleri** (`voiceprints`, `Voices.json`) eşitlensin mi? Uçtan uca şifreli olsalar da biyometrik sayılabilirler;
   eşitlenmezse diğer cihaz kişileri sesinden tanımaz. (Önerilen: eşitlensin, politikada açıkça yazılsın.)
9. **Kota:** Aşama 2'de hesap başına üst sınır (ör. 10 GB) ve aşılınca ne olur (en eski ekran görüntüleri
   yüklenmez, uyarı)?
10. **Teknik doğrulamalar (Aşama 0):** Developer ID profiliyle abonelik Mac uygulamasında synchronizable Anahtar
    Zinciri öğesinin iPhone'da okunduğu (aynı paket kimliği, `keychain-access-groups`); B seçilirse CloudKit'in Developer
    ID'de çalıştığı; App Privacy etiketinde E2EE verinin beyanı; ihracat uyumluluğu cevabı.

---

## 13. Kaynaklar

Kod (bu repo): `Packages/AINotepadCore/Sources/AINotepadCore/Support/{CloudStorage,AccountData,AppPaths,Keychain}.swift`,
`Meeting/{MeetingRecord,MeetingStore,TaskTracking,People,AskHistory,NoteHistory}.swift`,
`Audio/AudioFinalizer.swift`, `Screen/ScreenSnapshots.swift`, `Hosted/HostedOffline.swift`,
`App/Hosted/HostedAccountData.swift`, `App/AppModel.swift`, `iOS/AINotepadiOSApp.swift`, `project.yml`,
`App/AINotepad.entitlements`, `App/Hosted/AINotepadHosted.entitlements`, `server/migrations/`,
`server/src/account.ts`, `server/wrangler.jsonc`, `web/src/pages/privacy.astro`,
`docs/superpowers/specs/2026-10-27-iphone-design.md`.

Fiyat ve platform (2026-11-03'te okundu):

- Cloudflare R2 fiyatları — https://developers.cloudflare.com/r2/pricing/
- Cloudflare D1 fiyatları — https://developers.cloudflare.com/d1/platform/pricing/
- Cloudflare D1 sınırları (10 GB/veritabanı, 2 MB satır) — https://developers.cloudflare.com/d1/platform/limits/
- Cloudflare Workers ve Durable Objects fiyatları — https://developers.cloudflare.com/workers/platform/pricing/
- Apple macOS yetenek tablosu (Developer ID sütunu) — https://developer.apple.com/help/account/reference/supported-capabilities-macos
- CloudKit özel veritabanının kullanıcı kotasından düşmesi — https://developer.apple.com/documentation/cloudkit/ckdatabase/scope/private
- iCloud+ planları — https://support.apple.com/en-us/108047
