# AI-Notepad

macOS 15+ menü çubuğu uygulaması: toplantıları canlı yazıya döker ve Türkçeye çevirir.
Tasarım: `docs/superpowers/specs/`. Planlar: `docs/superpowers/plans/`.

## Yapı

- `Packages/AINotepadCore/` — tüm mantık (Swift paketi). Testler buradadır.
- `App/` — yalnızca SwiftUI/AppKit arayüzü ve yaşam döngüsü.
- `iOS/` — iPhone uygulaması: Gistsmith (abonelik, `HOSTED_EDITION`, yalnız hesapla; SwiftUI); aynı paketi ve `App/Hosted`'taki
  ortak hesap dosyalarını kullanır. En düşük iOS 18.0 (project.yml ve Package.swift): iOS 26 API'leri (cam, kapat/onay
  düğmesi, sürdürülen işleme, `SpeechAnalyzer`…) `#available(iOS 26.0, *)` ile ya da `iOS/SystemCompat.swift`'teki
  karşılıklarıyla kullanılır; derleyici denetler. iOS 18 Simülatörü: Xcode 27'nin `xcodebuild -downloadPlatform`'u 26'dan
  eski çalışma zamanını bulmaz (FB24836279); Xcode › Settings › Components › "+" ile kur. Debug yerel sunucuya (`localhost:8787`) bağlanır; `--tanitim` (yalnız Debug) giriş
  olmadan sahte deneme hesabıyla (`--abone` ile App Store abonesi ve davet koduyla, `--pro` ile Pro abonesi) açar (Simülatör'de görsel kontrol; tanıtım sunucusu Pro'yu satar, `--pro-yok` satmaz); `--paywall` abonelik ekranını, `--teklif not-hazir|deneme-bitiyor|geri-cagirma` ana ekrandaki teklif kartını, `--teklif kayit-abone|pro-sinir` o nedenle açılan abonelik ekranını (`pro-sinir` `--abone` ile), `--sohbet <uuid>`
  saklı Sor sohbetini açar (`--ask-gecmis` Sor'un alttan açılan sohbet geçmişini; saklı sohbet yoksa bellekteki örneklerle, `--sekme sor` ya da `--sohbet` ile birlikte); sekme çubuğu yok (tek ana ekran, üstüne açılan sayfalar): `--sekme sor|gorevler|ayarlar` o sayfayı
  (`kayit`/`toplantilar` ana ekranı), `--ekran kitaplik|arama|kisiler|istatistikler|profil|hesap|asistan|baglantilar|paylas` o sayfayı (`paylas` Gistsmith'i paylaş: QR kodu ve paylaşım sayfası, `--abone` ile davet bağlantısıyla; `--baglanti <ad>` Bağlantılar'da o entegrasyonun sayfasını, ör. `slack`; `asistan` ile `--reddedilen` kabul edilmeyen toplantıları, `--asistan-acik` bağlanma adımlarını), `--ekran mac` Ayarlar'ın üstünde Mac uygulamasının tanıtım sayfasını (Mac'teki Gistsmith'te `--iphone-uygulamasi` iPhone'unkini), `--ekran telefon` telefon görüşmesi rehberini (cihaz bölgesi Apple'ın arama kaydı sunmadığı yerse, ör. AB, rehber Mac
  ve içe aktarmayla başlar; `-AppleLocale en_FI` ile görülür; `--arama izin|dogrula|kod|tus|gorusme` rehberde uygulamadan aramanın o adımını örnek veriyle), `--ekran klasorler` kitaplık
  sayfasını, `--toplanti <kimlik>` toplantıyı açar (onunla `--kaynak` özetin ilk maddesinin kaynak kutusunu, `--sor-ornek` "Bir şey sor" panelini sahte bir cevapla, `--cekmece` transkript çekmecesini açık gösterir), `--sekme ayarlar` ile `--ayar kayit|notlar|ceviri|takvim|bildirimler|beceriler` Ayarlar'ın o sayfasını açar (`konusmacilar` Kayıt ve diller'i açıp konuşmacılar bölümüne kaydırır; `saat` Apple Watch sayfasını, Simülatörde eşli saat yokken `--saat-durumu yok|kur|hazir|ios|araniyor` o durumla); `--hizli-eylem kayit|destek|depolama` ana ekran hızlı eylemini (uygulama simgesine uzun basış; `iOS/PhoneQuickActions.swift`) kullanılmış gibi açar; `--ornek-kayit` örnek canlı kaydı (`--ornek-bitir` ile bitiriliyor katmanını, `--ornek-duraklat` ile duraklatılmış hâlini, `--ornek-sinir` ile çevrimdışı ve aylık sınırla kısaltılmış hâlini, `--ornek-gorusme` ile bu iPhone'daki bir görüşmenin mikrofonu tuttuğu hâlini, `--ornek-cihazda` ile cihaz içi canlı önizlemeyle yeni başlamış hâlini, `--ornek-mikrofon` ile seçilen AirPods bağlı değilken iPhone mikrofonuyla süren hâlini) gösterir (`--ornek-gorusme` tek başına ana ekrandaki görüşme hatasını); `--ornek-takvim` örnek sıradaki toplantıları, `--ornek-saat-iceaktarma` ana ekranda içe aktarılamayan örnek bir saat kaydını gösterir; `--karsilama` ilk açılış karşılamasını (`--karsilama-adim <welcome|calendar|permissions|sample|ready>` o adımdan, `--karsilama-ornek <canli|not>` örnek toplantıyı sürerken ya da notuyla) açar; `--aciklama` üçüncü taraf yapay zekâ onay ekranını gösterir (onaysız hiçbir yapay zekâ isteği gitmez: `HostedAIConsentCenter`; sunucu 0.2.5+ uygulamaların isteğini kayıtlı onay olmadan reddeder, `server/src/aiConsent.ts`). Abonelik RevenueCat'le (`iOS/Purchases/`); şemadaki `Products.storekit` yalnızca Xcode'da
  Run'da geçerlidir — `xcodebuild`/`simctl` başlatması StoreKit sandbox'ını kullanır (Apple FB22237318), satın alma UI
  testi bu yüzden yok. Erişilebilirlik denetimi (App Store Erişilebilirlik Etiketlerinin kanıtı) `iOSUITests/` UI
  testidir (CI'da değil, ~25 dk; tohumlama ve komut dosyanın başında); saatinki `WatchScreensUITests.testAccessibilityAudit`.
  XCTest `accessibilityHidden` görünümleri de listeler: denetimin takıldığı süs görünümü `accessibilityIdentifier("decorative")` alır.
- Gistsmith Klavye (`iOSKeyboard/`, iPhone klavye uzantısı; tasarım `docs/superpowers/specs/2026-11-09-voice-keyboard.md`):
  yalnız bağımlılıksız `KeyboardCore`'a bağlanır (uzantının bellek sınırı; AINotepadCore/WhisperKit girmez). Uzantı
  mikrofona erişemez: sesle yazma `gistsmith://keyboard/dictate/<istek>` ile uygulamayı açar, `iOS/Keyboard/` dinler,
  ikisi App Group'taki dosyalar ve Darwin bildirimleriyle konuşur; klavyeden soru da aynı yolla
  (`gistsmith://keyboard/ask/<istek>`, cevabı uygulama kendi oturumuyla yazar). Mikrofon kapalıyken klavyedeki ilk dokunuş
  uygulamayı açıp yalnız mikrofonu ısıtır (canlı etkinlik: Dynamic Island'da klavye simgesi); kullanıcı geri döner, dikte
  klavyede yerinde başlar. Ayarlar › Klavye: `--sekme ayarlar --ayar klavye` (`--klavye-durum
  kurulmadi|denenmedi|hazir` üstteki kartın o hâli); rehberli kurulum `--klavye-kurulum
  tanitim|ac|tam-erisim|degistir|dene|hazir` o sayfadan açılır (adımı gözlenen durumdan seçen saf fonksiyon
  `keyboardSetupStep`). Yalnız belgelenmiş olgular: klavyenin App Group'a yazdığı rapor (Tam Erişim'le), kurulum
  alanının odağı ve kullanıcının Ayarlar'dan dönüşü; `UITextInputMode`'un belgelenmemiş `identifier`'ı kullanılmaz
  (App Review 2.5.1).
  Kaydırarak yazma ölçümü (macOS sözlüğüyle, ~1 dk): `AINOTEPAD_SWIPE_BENCH=1 swift test --package-path
  Packages/AINotepadCore --filter KeyboardSwipeBenchmark`.
  Simülatörde: Ayarlar › Uygulamalar › Gistsmith › Klavyeler'den ekle; cihaz içi dikte Simülatörde metin üretmez
  (`noAudioFormat`), sesle yazmanın metni yalnız cihazda denenir.
- Simülatörde mikrofon: `AVAudioEngine.inputNode` ilk kurulumda `_ReportRPCTimeout` (SIGABRT, `AURemoteIO::Initialize`)
  ile çökebilir. Simülatörde ses sunucusu uygulamanın içinde çalışır ve Mac'in coreaudiod'una bağlanır; Mac'in ses
  sistemi meşgulken (başka uygulama mikrofonu tutuyor, birkaç Simülatör açık) yanıt gecikir. Cihazda bu yol yok; kodumuz
  oturumu açtıktan sonra dokunur. Tekrarlanırsa Simülatörü yeniden başlat; çalışan AI-Notepad'i kapatma (kayıtta olabilir).
- Bağlantılar (iPhone ve Mac'teki Gistsmith): `gistsmith://record|ask|tasks|insights|meeting/<kimlik>` (ayrıştırıcı
  `Meeting/AppLinks.swift`; `record` kaydı başlatmaz). iPhone'da evrensel bağlantı `https://gistsmith.com/m/<kimlik>` ve
  `/open/<yol>` (`iOS/AINotepadiOS.entitlements`, site `web/public/.well-known/apple-app-site-association`); Mac'te
  Developer ID yüzünden yalnız şema. Simülatörde ilk açılışta sistem "ile Açılsın mı?" diye sorar.
- iPhone Duo (katlanabilir; iç ekran 669×951 pt "regular", dış ekran 466×678 pt "compact"): "regular" genişlik ve en az
  640 pt'de (`usesWideLayout`) ana ekran solda sütun, sayfa yığını sağda; kayıtta "Notlarım" canlı metnin yanında. Duo
  Simülatörü aygıtı listeleyen bir iOS 27.1+ çalışma zamanı ister (iOS 27.2 24B8117 listelemez: `simctl create` "Incompatible
  device"); yoksa geniş düzeni `TARGETED_DEVICE_FAMILY=1,2` ile ayrı bir derived data'ya
  derleyip iPad Simülatöründe gör (commit'leme). App Store Duo görselleri: `make -- --device duo` (2007×2853).
- Uygulamadan arama pilotu (`iOS/PhoneDialer/`: CallKit + Twilio Voice SDK, sunucuda `server/src/phone/`; tasarım
  `docs/superpowers/specs/2026-11-08-iphone-call-recording.md`): yalnız `PHONE_DIALER=YES` derlemesinde (Debug'da açık,
  Release'de kapalı; pilot TestFlight arşivine komut satırından verilir) ve sunucu `PHONE_CALLS_POLICY=on` iken görünür
  (üretimde kapalı). Gerçek arama Twilio hesabı ister; testler sahte Twilio'yla (`server/test/phone.test.ts`).
- Deneysel "bu iPhone'daki görüşmeyi kaydet" (`iOS/CallCapture/`, iOS 27 ScreenCaptureKit): yalnız
  `CALL_CAPTURE_EXPERIMENT=YES` derlemesinde (Debug'da açık, Release'de kapalı; TestFlight denemesi için arşive
  komut satırından verilir). ScreenCaptureKit Simulator SDK'sında yok: yalnız cihazda çalışır.
- `Watch/` — Gistsmith'in Apple Watch uygulaması (watchOS 26+, iPhone arşiviyle gider; tasarım
  `docs/superpowers/specs/2026-11-08-apple-watch.md`): saatin mikrofonuyla kayıt (iPhone'a `transferFile`, iPhone'da
  `iOS/PhoneWatchLink.swift` hesabına göre içe aktarır), iPhone'daki kaydı yönetme, bugünün toplantıları, görevler,
  komplikasyon ve "Saatte kaydet" denetimi. Ortak mesajlar ayrı pakette (`Packages/AINotepadWatchLink`, yalnız
  Foundation); metinler `Watch/Localizable.xcstrings` ve `Watch/InfoPlist.xcstrings`. Saatte sır yok, sunucuya
  gidilmez. Saatte kayıt sunucu anahtarına bağlı (`WATCH_RECORDING_POLICY`, kapalıyken `WATCH_RECORDING_USERS`
  listesi; üretimde kapalı). Simülatör: `transferFile` saatte "gönderildi" der ama iPhone dosyayı hiç almaz (Apple);
  mesajlar ve bağlam çalışır. Saat Debug'da `--ornek` (örnek veri, WatchConnectivity kapalı), `--ornek-kapali`,
  `--ornek-kayit`, `--ekran gorevler|iphone` alır. Eşli Simülatör: `xcrun simctl pair <saat> <iPhone>`; testler
  `-scheme AINotepadWatch test-without-building` ile, her koşudan önce `xcrun simctl install <saat> …/AINotepadWatch.app`
  (xcodebuild saat uygulamasını kurmaz, koşu sonunda kaldırır) ve ilk koşuda mikrofon iznini UI testi
  (`testRecordAndFinish`) verir: `simctl privacy` saatte işlemez, izin sorusu açıkken birim testi öldürülür.
  `TEST_RUNNER_WATCH_SHOTS_DIR=<klasör>` ekran PNG'lerini yazar; `TEST_RUNNER_WATCH_LINK_TEST=1` iPhone Simülatöründe
  `--tanitim --ornek-kayit --ornek-takvim` açıkken gerçek WatchConnectivity'yi dener (önce saat uygulamasını, sonra iPhone uygulamasını kur; tersinde iPhone anlık görüntü göndermez).
- `promo/` — Gistsmith tanıtım filmi (İngilizce; 16:9 `GistsmithPromo` ve 9:16 `GistsmithPromoVertical`): `voice/`
  Chatterbox seslendirme + faster-whisper kelime zamanları (uv; metin tek kaynak `voice_script.py`), `blender/`
  Blender'la laptop sahnesi (ve `devices.sh <png-klasörü>`: sitedeki Mac + iPhone + Apple Watch görseli, `web/src/assets/devices`), `music/` CC0 müzik, `film/` Remotion projesi (sahne süreleri seslendirmeden hesaplanır;
  laptop kare sayısı da). Yeniden üretim: `cd promo/voice && uv run python speak.py ../film/public/vo && uv run python
  words.py ../film/public/vo`; `cd promo/film && npm ci`; `promo/blender/render.sh` (kare sayısını `film/scripts/
  laptop-frames.ts`'ten alır, Node 22.18+; ses değişince yeniden çalıştır); `promo/music/fetch-music.sh`; `cd promo/film
  && scripts/fetch-sfx.sh && scripts/copy-shots.sh && npm run render`. Python denetimi: `cd promo/voice && uv run ruff
  check . ../blender && uv run ruff format --check . ../blender && uv run basedpyright`; film: `npx tsc --noEmit`. Yeni
  indirilen headless Chrome'un ilk açılışı macOS taraması yüzünden "root component" zaman aşımı verebilir; tekrar çalıştır.
- `server/` — Cloudflare Worker'ları: API (`wrangler.jsonc`, `src/index.ts`) ve uzak MCP bağlayıcısı `gistsmith-mcp`
  (`wrangler.mcp.jsonc`, `src/mcp/`; yapay zekâ asistanı kopyası `src/assistant/`, AB D1 göçleri `migrations-assistant/`).
  İkisi aynı test çalışma ortamında sınanır (`npm test`); MCP Worker'ın KV'si ve iki uyumluluk bayrağı yalnızca
  `vitest.config.ts`'te eklenir. Paketleme denetimi: `npx wrangler deploy --dry-run --config wrangler.mcp.jsonc --env "" --outdir <geçici>`.
- Karşılamadaki rehberli örnek toplantı (`App/SampleMeeting/`: sentetik iki sesli ses, zamanlı metin, `CREDITS.md`;
  iki uygulamaya da kaynak olarak girer) `promo/sample-meeting/` ile üretilir (Kokoro-82M, uv): `cd promo/sample-meeting &&
  uv run python generate.py out ../../App/SampleMeeting`. Örnek toplantı (`MeetingRecord.isSampleMeeting`) eşitlenmez,
  işlenmez; bildirim, MCP ve kendiliğinden gönderim `realMeetings` ile onu dışarıda bırakır.
- `project.yml` — XcodeGen tanımı; `AINotepad.xcodeproj` üretilir, repoya girmez.
- İmzalama: `Config/Local.xcconfig.example` dosyasını `Config/Local.xcconfig` olarak kopyalayıp `DEVELOPMENT_TEAM` yaz.

## Komutlar

```bash
xcodegen generate
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet
swift test --package-path Packages/AINotepadCore                              # hızlı testler
swift test --package-path Packages/AINotepadWatchLink                         # iPhone ↔ Apple Watch mesajları
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadWatch -configuration Debug \
  -derivedDataPath .build/xcode-watch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build -quiet   # Apple Watch uygulaması
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Debug \
  -derivedDataPath .build/xcode-ios -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet   # iPhone uygulaması
(cd Packages/AINotepadCore && xcodebuild test -scheme AINotepadCore-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet)                # çekirdek testleri iOS'ta
AINOTEPAD_MODEL_TESTS=1 swift test --package-path Packages/AINotepadCore      # + gerçek WhisperKit modeli (~630 MB indirir)
AINOTEPAD_SCREEN_TESTS=1 swift test --package-path Packages/AINotepadCore --filter ScreenSnapshotCaptureTests  # gerçek ekran görüntüsü döngüsü + CPU (terminalde Ekran Kaydı izni gerekir)
AINOTEPAD_ONDEVICE_TESTS=1 swift test --package-path Packages/AINotepadCore --filter DictationOnDeviceTests  # sesle yazma: gerçek Apple diktesi (macOS 26+)
AINOTEPAD_AUDIO_DEVICE_TESTS=1 AINOTEPAD_MIC_DEVICE_TESTS=1 swift test --package-path Packages/AINotepadCore --filter AudioInputSelectionTests  # mikrofon seçimi: bu Mac'in cihazları + gerçek yakalamada canlı giriş değişimi (mikrofon izni ve en az iki giriş cihazı)
AINOTEPAD_CLOUD_TESTS=1 AINOTEPAD_SCENARIO_TESTS=1 swift test --package-path Packages/AINotepadCore --filter LLMScenarioTests  # pahalı: uzun toplantı × her model × max effort
AINOTEPAD_CLOUD_TESTS=1 swift test --package-path Packages/AINotepadCore --filter ScreenNotesCostTests  # notta ekran görüntüleri: gerçek Haiku çağrısıyla ek token ve $ ölçümü (~$0.001)
AINOTEPAD_NOTE_EVAL=1 AINOTEPAD_EVAL_ANTHROPIC_KEY=… AINOTEPAD_NOTE_EVAL_OUT=<klasör> swift test --package-path Packages/AINotepadCore --filter NoteQualityEval  # not kalitesi değerlendirmesi: Haiku notu yazar, Opus 5.5 puanlar; anahtar ortamdan (Anahtar Zinciri değil), ~$0.45/çalıştırma, maliyet sonda yazılır
(cd server && node scripts/fake-upstreams.ts 8798 & cd server && npx wrangler dev --port 8797 --var UPSTREAM_STUB_URL:http://127.0.0.1:8798)   # sonra: AINOTEPAD_HOSTED_E2E=1 AINOTEPAD_HOSTED_UPSTREAM_STUB=1 AINOTEPAD_HOSTED_BASE=http://127.0.0.1:8797 swift test --no-parallel --package-path Packages/AINotepadCore --filter 'HostedE2E|HostedSyncE2E|HostedLongMeetingE2E' (server/.dev.vars sahte değerlerle, migrate:local önce; sahte Anthropic/ElevenLabs ücretsiz; --no-parallel: yerel D1 eşzamanlı yazımda SQLITE_BUSY verir; bittikten sonra ikisini de durdur)
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadHosted -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet   # abonelik sürümü (App/Hosted, HOSTED_EDITION)
scripts/make-test-fixtures.sh                                                 # test seslerini yeniden üretir
scripts/install-app.sh                                                        # Release'i /Applications'a kurar (izinler kalıcı)
```

Paket sabitleri: uygulamanın Swift paketleri (project.yml'deki Sparkle ve RevenueCat, çekirdek paketin WhisperKit'i ve
bağımlılıkları) sürüm ve işleme kimliğiyle `Config/Package.resolved`'da. Yayın betikleri (`scripts/release*.sh`) CI'daki
XcodeGen'i (2.45.3) ister, dosyayı üretilen projeye kopyalar ve `-onlyUsePackageVersionsFromResolvedFile` ile arşivler:
etiket taşınsa da sabitlenen işleme derlenir, sabit project.yml'le uyuşmazsa arşivleme durur. iPhone arşivi de böyle:

```bash
scripts/check-package-pins.sh && xcodegen generate
mkdir -p AINotepad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Config/Package.resolved AINotepad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Release -destination 'generic/platform=iOS' \
  -archivePath <yol> -allowProvisioningUpdates -onlyUsePackageVersionsFromResolvedFile CALL_CAPTURE_EXPERIMENT=YES archive
```

Paket sürümü değişince (project.yml `exactVersion` ya da `Packages/AINotepadCore/Package.swift` + `swift package
--package-path Packages/AINotepadCore resolve`): `xcodegen generate` ve yukarıdaki `mkdir`/`cp`, sonra bayraksız
`xcodebuild -resolvePackageDependencies -project AINotepad.xcodeproj -scheme AINotepadiOS` projedeki dosyayı günceller; onu
`Config/Package.resolved`'a geri kopyala, yeni işlemeleri `git ls-remote --tags <adres>` ile doğrula,
`scripts/check-package-pins.sh` çalıştır. Projede bu dosya yokken xcodebuild uygulamanın sabitlerini
`Packages/AINotepadCore/Package.resolved`'a yazar; öyle olduysa o dosyayı geri al.

`xcodebuild -exportLocalizations` `-derivedDataPath` kabul etmez ve `~/Library/Developer/Xcode/DerivedData`'ya ad-hoc
imzalı bir AINotepad.app bırakır; Spotlight onu bulur, açılınca izinler her seferinde yeniden sorulur. Çalıştırdıysan
o kopyayı sil.

Arayüz metinleri: kaynak Türkçe, her metnin İngilizcesi ve `scripts/l10n.py` `TARGET_LANGUAGES` dillerinin hepsi
katalogda olmalı (`LocalizationCompletenessTests`; eksik çeviri cihazda Türkçe kaynağa düşer). Yeni metinler için
`scripts/l10n.py export --lang <dil> --out …` → çevir → `validate` → `import`; `check` hepsini denetler.

Kod değiştiren her işten önce iki test komutunu da çalıştır.

## Sunucu yayını

`server/` değişikliği main'e girince `.github/workflows/deploy-server.yml` yayınlar: birleşmiş işlemede testler, iki
Worker'ın derleme denetimi, D1 yer imleri, göçler (önce göç, sonra kod), API ve MCP Worker'ı (`--tag` = işleme), sonra
yayındaki sürüm ve sağlık denetimi. Elle `npm run deploy`/`migrate:production` yapma; sonuç Actions'ta. Göç iki Worker'ın
çalışan koduyla uyumlu olmalı; DROP/RENAME/DELETE FROM içeren göç yayını durdurur, sahibin onayıyla Actions → Deploy server → Run
workflow (`allow_destructive_migrations=yes`). Vars yalnız wrangler yapılandırmasında (yayın panelden girilenleri siler);
gizli değerler elle `wrangler secret put … --env production`.

Acil geri alma (elle yapılan tek yayın): `cd server && npx wrangler rollback --env production -m <neden>` ve
`npx wrangler rollback --config wrangler.mcp.jsonc --env production -m <neden>`, sonra geri alma PR'ı (yoksa sonraki yayın
aynı kodu çıkarır). Geri alma D1'i geri almaz: göç bozduysa yeni göç; Time Travel (`wrangler d1 time-travel restore`,
yer imi yayın işinin özetinde) son çaredir, sonraki bütün yazımları siler.

## İnceleme

[REVIEW.md](REVIEW.md) incelemenin neye baktığını söyler. `.claude/hooks/pre-push-review.sh` her push'tan önce o
incelemeyi `claude` komutunun aboneliğiyle yapar; Important bulgu push'u durdurur. Kurulumu ve atlaması dosyanın
başında (genel `core.hooksPath` yüzünden yerel `core.hooksPath` da ayarlanır). Bulguların hepsini düzeltip tek push yap;
kanca yalnız yeni işlemeleri okur.

## PR

PR açılınca `gh pr merge <numara> --auto --squash --delete-branch`: zorunlu checkler (`test-and-build`, `ios`, `server`,
`web`) geçince GitHub birleştirir, checkleri beklemek gerekmez. Biri kırmızı olursa birleştirmez; düzelt ve yeniden gönder.
`nightly.yml` (her gece ve elle; zorunlu check değil) çekirdek testlerini iOS Simülatörü'nde ve AI-Notepad'in Release
derlemesini koşar: kırmızıysa yayından önce düzelt.
