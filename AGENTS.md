# AI-Notepad

macOS 15+ menü çubuğu uygulaması: toplantıları canlı yazıya döker ve Türkçeye çevirir.
Tasarım: `docs/superpowers/specs/`. Planlar: `docs/superpowers/plans/`.

## Yapı

- `Packages/AINotepadCore/` — tüm mantık (Swift paketi). Testler buradadır.
- `App/` — yalnızca SwiftUI/AppKit arayüzü ve yaşam döngüsü.
- `iOS/` — iPhone uygulaması: Gistsmith (abonelik, `HOSTED_EDITION`, yalnız hesapla; SwiftUI); aynı paketi ve `App/Hosted`'taki
  ortak hesap dosyalarını kullanır. Debug yerel sunucuya (`localhost:8787`) bağlanır; `--tanitim` (yalnız Debug) giriş
  olmadan sahte deneme hesabıyla (`--abone` ile App Store abonesi ve davet koduyla) açar (Simülatör'de görsel kontrol); `--paywall` abonelik ekranını, `--sohbet <uuid>`
  saklı Sor sohbetini açar; `--ornek-kayit` örnek canlı kaydı (`--ornek-bitir` ile bitiriliyor katmanını, `--ornek-duraklat` ile duraklatılmış hâlini, `--ornek-sinir` ile çevrimdışı ve aylık sınırla kısaltılmış hâlini) gösterir; `--ornek-takvim` örnek sıradaki toplantıları gösterir. Abonelik RevenueCat'le (`iOS/Purchases/`); şemadaki `Products.storekit` yalnızca Xcode'da
  Run'da geçerlidir — `xcodebuild`/`simctl` başlatması StoreKit sandbox'ını kullanır (Apple FB22237318), UI testi bu
  yüzden yok.
- Deneysel "bu iPhone'daki görüşmeyi kaydet" (`iOS/CallCapture/`, iOS 27 ScreenCaptureKit): yalnız
  `CALL_CAPTURE_EXPERIMENT=YES` derlemesinde (Debug'da açık, Release'de kapalı; TestFlight denemesi için arşive
  komut satırından verilir). ScreenCaptureKit Simulator SDK'sında yok: yalnız cihazda çalışır.
- `promo/` — Gistsmith tanıtım filmi (İngilizce; 16:9 `GistsmithPromo` ve 9:16 `GistsmithPromoVertical`): `voice/`
  Chatterbox seslendirme + faster-whisper kelime zamanları (uv; metin tek kaynak `voice_script.py`), `blender/`
  Blender'la laptop sahnesi, `music/` CC0 müzik, `film/` Remotion projesi (sahne süreleri seslendirmeden hesaplanır;
  laptop kare sayısı da). Yeniden üretim: `cd promo/voice && uv run python speak.py ../film/public/vo && uv run python
  words.py ../film/public/vo`; `cd promo/film && npm ci`; `promo/blender/render.sh` (kare sayısını `film/scripts/
  laptop-frames.ts`'ten alır, Node 22.18+; ses değişince yeniden çalıştır); `promo/music/fetch-music.sh`; `cd promo/film
  && scripts/fetch-sfx.sh && scripts/copy-shots.sh && npm run render`. Python denetimi: `cd promo/voice && uv run ruff
  check . ../blender && uv run ruff format --check . ../blender && uv run basedpyright`; film: `npx tsc --noEmit`. Yeni
  indirilen headless Chrome'un ilk açılışı macOS taraması yüzünden "root component" zaman aşımı verebilir; tekrar çalıştır.
- `project.yml` — XcodeGen tanımı; `AINotepad.xcodeproj` üretilir, repoya girmez.
- İmzalama: `Config/Local.xcconfig.example` dosyasını `Config/Local.xcconfig` olarak kopyalayıp `DEVELOPMENT_TEAM` yaz.

## Komutlar

```bash
xcodegen generate
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet
swift test --package-path Packages/AINotepadCore                              # hızlı testler
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Debug \
  -derivedDataPath .build/xcode-ios -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet   # iPhone uygulaması
(cd Packages/AINotepadCore && xcodebuild test -scheme AINotepadCore-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet)                # çekirdek testleri iOS'ta
AINOTEPAD_MODEL_TESTS=1 swift test --package-path Packages/AINotepadCore      # + gerçek WhisperKit modeli (~630 MB indirir)
AINOTEPAD_SCREEN_TESTS=1 swift test --package-path Packages/AINotepadCore --filter ScreenSnapshotCaptureTests  # gerçek ekran görüntüsü döngüsü + CPU (terminalde Ekran Kaydı izni gerekir)
AINOTEPAD_ONDEVICE_TESTS=1 swift test --package-path Packages/AINotepadCore --filter DictationOnDeviceTests  # sesle yazma: gerçek Apple diktesi (macOS 26+)
AINOTEPAD_CLOUD_TESTS=1 AINOTEPAD_SCENARIO_TESTS=1 swift test --package-path Packages/AINotepadCore --filter LLMScenarioTests  # pahalı: uzun toplantı × her model × max effort
AINOTEPAD_CLOUD_TESTS=1 swift test --package-path Packages/AINotepadCore --filter ScreenNotesCostTests  # notta ekran görüntüleri: gerçek Haiku çağrısıyla ek token ve $ ölçümü (~$0.001)
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
