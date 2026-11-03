# iPhone'da çalışan Teams/Zoom görüşmesini kaydetme — araştırma (iOS 27)

Tarih: 2026-11-03. Kaynak: bu makinedeki **Xcode 27.2 / iPhoneOS27.2.sdk** başlıkları (blog değil). Yollar
`$SDK = /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk`
köküne göredir. Prototip: `iOS/CallCapture/` (yalnız `CALL_CAPTURE_EXPERIMENT` bayrağıyla derlenir, bkz. §6).

## 1. Kısa sonuç

- **Evet, API var.** iOS 27 ScreenCaptureKit'i iPhone'a getiriyor: `SCStream` + `SCStreamOutputTypeAudio` (sistem /
  diğer uygulamaların sesi) + `SCStreamOutputTypeMicrophone` (mikrofon) aynı akışta, `ios(27.0)` işaretli.
- **İzin = sistem seçicisi.** iOS'ta içerik süzgeci (`SCContentFilter`) yalnız `SCContentSharingPicker`'dan gelir
  (ekran/pencere/uygulama listeleyen API'ler iOS'ta yok). Kullanıcı Denetim Merkezi tarzı sistem seçicisinde ekranı
  paylaşmayı onaylar; mikrofonu da seçicideki düğmeyle kendisi açar. Ayrı bir Info.plist izin metni yok.
- **Arka plan:** yeni `UIBackgroundModes` değeri `screen-capture` ("App provides screen sharing services"). Yoksa akış
  `SCStreamErrorMissingBackgroundMode` (-3824) ile durur.
- **Yalnız ses:** `SCStreamConfiguration.capturesAudio` var; ekran karesi çıkışı eklemek zorunlu değil. Ama içerik
  süzgeci her zaman "ekran" (display) — sistem tarafında ekran yakalama yine çalışır, kullanıcı "ekran kaydı/paylaşımı"
  göstergesini görür.
- **Belgelenmemiş, cihazda denenmesi gereken asıl soru:** Teams/Zoom'un **VoIP görüşme sesi** (karşı tarafın sesi)
  "sistem sesi"ne giriyor mu? Başlıklarda görüşme/CallKit/VoIP/DRM istisnasına dair tek satır yok; ne var ne yok
  diyor. Bunu yalnız cihaz testi cevaplar (§5).
- **ReplayKit yedek değil:** Broadcast Upload Extension (`RPBroadcastSampleHandler`, `RPSampleBufferTypeAudioApp` /
  `AudioMic`) iOS 27'de hâlâ derleniyor ama `API_DEPRECATED("No longer supported", ios(10.0, 27.0))`. Yeni iş için
  kullanılmamalı; ScreenCaptureKit çalışmazsa ReplayKit'in de aynı sistem servisini kullandığı varsayılmalı.
- **Core Audio process tap (Mac'teki yöntem) iOS'ta yok:** `CoreAudio.framework/Headers` yalnız `AudioHardwareBase.h`,
  `AudioServerPlugIn.h`, `CoreAudioTypes.h` içerir; `CATapDescription` / `AudioHardwareCreateProcessTap` yok.

## 2. API'ler (başlıklardan alıntı)

### 2.1 Akış ve ses çıkışları — `ScreenCaptureKit.framework/Headers/SCStream.h`

```objc
typedef NS_ENUM(NSInteger, SCStreamOutputType) {
    SCStreamOutputTypeScreen,
    SCStreamOutputTypeAudio API_AVAILABLE(macos(13.0), macCatalyst(18.2), ios(27.0), visionos(27.0), tvos(27.0)),
    SCStreamOutputTypeMicrophone API_AVAILABLE(macos(15.0), macCatalyst(18.2), ios(27.0), visionos(27.0)) API_UNAVAILABLE(tvos)
} API_AVAILABLE(macos(12.3), macCatalyst(18.2), ios(27.0), visionos(27.0), tvos(27.0));
```

> SCStreamOutputTypeAudio is an audio capture sample buffer. … The format of the audio buffer is based on sampleRate
> and channelCount set in SCStreamConfiguration. SCStreamOutputTypeMicrophone … is based on the selected microphone
> capture device's native format.

`SCStreamConfiguration` (iOS 27'de var): `capturesAudio` ("By default audio is not captured"), `sampleRate`
(varsayılan 48000), `channelCount` (varsayılan 2), `excludesCurrentProcessAudio` (varsayılan NO). iOS'ta **yok**:
`captureMicrophone` ve `microphoneCaptureDeviceID` (`API_UNAVAILABLE(ios, …)`); başlıktaki not:

> on iOS and visionos, client can configure showsMicrophoneControl in SCContentSharingPickerConfiguration for user to
> choose enable microphone capture or not

`SCContentFilter.microphoneEnabled` (`ios(27.0)`): "microphone enable state determined by user via system picker when
showsMicrophoneControl is enabled". Yani mikrofonu uygulama açamaz; kullanıcı seçicide açar, uygulama okur.

`SCStream` (iOS 27): `initWithFilter:configuration:delegate:`, `addStreamOutput:type:sampleHandlerQueue:error:`,
`startCapture…`, `stopCapture…`, `synchronizationClock`, `capturing`, `addRecordingOutput:` (SCRecordingOutput),
`addClipBufferingOutput:`. `SCStreamDelegate.stream:didStopWithError:` iOS'ta var.

`SCContentFilter`'ın bütün kurucuları (`initWithDisplay:…`, `initWithDesktopIndependentWindow:`) iOS'ta
`API_UNAVAILABLE(ios, …)`; `SCShareableContent`, `SCDisplay`, `SCWindow`, `SCRunningApplication` de iOS'ta yok
(`SCShareableContent.h`). **Süzgeç yalnız seçiciden gelir.**

### 2.2 Seçici (izin) — `SCContentSharingPicker.h`

- `SCContentSharingPicker` `ios(27.0)`: `sharedPicker`, `active` ("A picker needs to be marked as active to enable
  user interaction with system UI"), `available` ("Returns YES if screen recording is supported and allowed on this
  device"), `addObserver:`, `present`, `presentPickerUsingContentStyle:`, `presentPickerForCurrentApplication`
  (iOS/visionOS/tvOS; yalnız kendi uygulaman — işimize yaramaz).
- `SCContentSharingPickerConfiguration.showsMicrophoneControl` (`ios(27.0)`, "Default is NO"),
  `showsCameraControl`. iOS'ta **yok**: `allowedPickerModes`, `excludedBundleIDs`, `excludedWindowIDs`,
  `presentPickerForStream:` — uygulama belirli bir uygulamayı (ör. yalnız Teams) seçtiremez.
- `SCShareableContentStyle` iOS'ta: `Window`, `Display` (`Application` iOS'ta yok). Prototip `Display` ister.
- Gözlemci: `contentSharingPicker:didUpdateWithFilter:forStream:`, `…didCancelForStream:`,
  `contentSharingPickerStartDidFailWithError:`.

### 2.3 Hatalar — `SCError.h`

İlgili kodlar: `SCStreamErrorUserDeclined` -3801, `MissingEntitlements` -3803, `UserStopped` -3817 ("stopped by the
user" — durum çubuğundan/Denetim Merkezi'nden durdurma), `FailedToStartAudioCapture` -3818,
`FailedToStartMicrophoneCapture` -3820, `SystemStoppedStream` -3821, `NotSupported` -3823,
**`SCStreamErrorMissingBackgroundMode` -3824 `API_AVAILABLE(ios(27.0), visionos(27.0), tvos(27.0))` "The stream was
stopped due to missing background mode"**.

### 2.4 Arka plan modu ve yetkiler

- Xcode'un Info.plist şeması
  (`Xcode.app/Contents/PlugIns/DVTCorePlistStructDefs.dvtplugin/Contents/Resources/DVTCorePlistStructDefs.xcplugindata`)
  `BackgroundMode` değerleri arasında: `<value name="screen-capture" localizedString="App provides screen sharing
  services"/>`.
- Yetki (entitlement): portal yetenek listesinde
  (`SharedFrameworks/DVTPortal.framework/Versions/A/Resources/DVTPortalCachedPortalCapabilities.json`) iOS için ekran
  yakalama yetkisi yok; tek ilgili kayıt visionOS'a özel `com.apple.developer.screen-capture.include-passthrough`.
  Yani App ID'ye yeni yetenek eklemek gerekmiyor (`MissingEntitlements` -3803 kodu Mac'ten kalma görünüyor; cihazda
  çıkarsa §5'te raporlanmalı).
- Info.plist izin metni: Xcode şemasında ekran yakalama için `NS…UsageDescription` yok. Mikrofon için mevcut
  `NSMicrophoneUsageDescription` zaten var.

### 2.5 ReplayKit — `ReplayKit.framework/Headers/`

- `RPBroadcastExtension.h`: `RPSampleBufferType { Video = 1, AudioApp, AudioMic }` →
  `API_DEPRECATED("Use SCStreamOutputType instead", ios(10.0, 27.0), …)`; `RPBroadcastSampleHandler` →
  `API_DEPRECATED("No longer supported", ios(10.0, 27.0), …)`.
- `RPBroadcast.h`: `RPSystemBroadcastPickerView` → `API_DEPRECATED("Use ScreenCaptureKit SCContentSharingPicker
  instead", ios(12.0, 27.0))`.
- `RPScreenRecorder.h`: tamamı "Use ScreenCaptureKit instead" ile iOS 27'de kullanımdan kalkmış.

Sonuç: eski yöntem hâlâ derlenir (iOS 26 cihazlar için yedek olabilir) ama "No longer supported" ifadesi Apple'ın
desteği bıraktığını söylüyor. iOS 26.x kullanıcıları için ayrı bir broadcast eklentisi yazmaya değmez; önce
ScreenCaptureKit cihaz testinin sonucu beklenmeli.

### 2.6 Diğerleri

- `AVFAudio` `AVAudioSession*.h`: başka uygulamaların sesini almaya dair API yok.
- `SCRecordingOutput.h`: `mixesAudioWithMicrophone` (`ios(27.0)`, varsayılan YES; NO ise iki ayrı ses izi). Dosya
  MPEG-4 + H.264 video içerir; yalnız ses için uygun değil (video izi şişirir). Prototip ses örneklerini kendisi yazar.

## 3. Kısıtlar

1. Uygulama yalnız iOS 27+ cihazda çalışır (`#available(iOS 27.0, *)`); dağıtım hedefi 26.1 kaldığı için özellik
   iOS 26'da görünmez/çalışmaz.
2. Kullanıcı her kayıtta sistem seçicisinden **ekranın tamamını** paylaşmayı onaylar; mikrofonu seçicide açması
   gerekir (varsayılan kapalı olabilir).
3. Ses formatı: sistem sesi `sampleRate`/`channelCount` ile (prototip 48 kHz mono ister), mikrofon cihazın yerel
   formatında.
4. Ekran karesi çıkışı eklenmese de sistem ekran yakalar → pil/CPU maliyeti bilinmiyor (uzun görüşmede ölçülmeli).
5. `excludesCurrentProcessAudio = YES`: uygulamanın kendi sesi (ör. oynatıcı) kayda girmez.

## 4. Bilinmeyenler (yalnız cihaz testi cevaplar)

| # | Soru | Nasıl anlaşılır |
|---|------|-----------------|
| U1 | Teams/Zoom görüşmesinde karşı tarafın sesi `SCStreamOutputTypeAudio`'ya geliyor mu? (VoIP/CallKit istisnası var mı?) | "Sistem sesi" ölçeri ve "sesli saniye" sayacı karşı taraf konuşurken artıyor mu |
| U2 | Teams mikrofonu kullanırken bizim mikrofon akışımız ses alıyor mu (paylaşımlı mikrofon) ve Teams'in sesini bozuyor mu? | "Mikrofon" sayacı + karşı tarafa "sesim geliyor mu" sorusu |
| U3 | Uygulama arka plandayken (Teams önde) akış sürüyor mu? `screen-capture` modu yetiyor mu? | Teams'ten dönünce süre ve sayaçlar arttıysa sürmüştür; -3824 ya da -3821 görünürse durmuştur |
| U4 | Ekran kilitlenince ne oluyor? | Kilitleyip 1 dk konuşup açınca sayaçlar |
| U5 | Görüşme sırasında iOS kendi ekran kaydı göstergesini/uyarısını gösteriyor mu, Teams buna tepki veriyor mu (ör. "ekran kaydediliyor" bildirimi)? | Gözlem |
| U6 | Hoparlör / kulaklık / AirPods'ta fark var mı? (AirPods'ta sistem sesi yine yakalanıyor mu) | Üç rotada kısa deneme |
| U7 | Mikrofon kapalı seçilirse ne oluyor; seçicide mikrofon düğmesi görünüyor mu? | Gözlem |
| U8 | Pil/ısınma (30+ dk) | Ayarlar › Pil |
| U9 | FaceTime/normal telefon araması yakalanıyor mu? (muhtemelen hayır; kayıt yasası açısından da bilinmeli) | Kısa deneme |

## 5. Sahibin cihaz testi (TestFlight, iOS 27.2)

Derleme: `CALL_CAPTURE_EXPERIMENT=YES` ile arşivlenmiş ayrı bir TestFlight derlemesi (yalnız iç test; bkz. §6).

1. Gistsmith › Toplantılar › sağ üst "İçe aktar" menüsü › **"Bu iPhone'daki görüşmeyi kaydet (deneysel)"**.
2. "Başlat"a bas → sistem seçicisi açılır. **Mikrofon düğmesini aç**, ekranı paylaş.
3. Ekrandaki iki ölçeri gör: konuş → "Mikrofon" oynamalı. Bir YouTube videosu aç → "Sistem sesi" oynamalı (temel test).
4. Teams'te (ya da Zoom'da) birini ara / toplantıya katıl. Gistsmith'e geri dönmeden 1–2 dk konuşun; karşı taraf
   konuşsun.
5. Gistsmith'e dön: sayaçlar (süre, "sesli saniye") Teams'teyken artmış mı?
6. "Durdur" → "Toplantı olarak içe aktar" → toplantı işlenince transkriptte iki tarafın sözleri var mı?
7. Ayrıca "Ham dosyaları paylaş" ile `system.m4a` ve `mic.m4a`'yı kendine gönder, dinle.

**Rapor edilecek sonuç** (her biri evet/hayır + ekrandaki sayılar):

- R1: YouTube sesinde "Sistem sesi" ölçeri oynadı mı?
- R2: **Teams/Zoom'da karşı taraf konuşurken sistem sesi "sesli saniye" sayacı arttı mı** (asıl soru, U1)?
- R3: Mikrofon sayacı arttı mı; karşı taraf seni duymaya devam etti mi (U2)?
- R4: Teams öndeyken kayıt sürdü mü, ekranda bir hata kodu var mı (U3; ör. -3824, -3821, -3817)?
- R5: İçe aktarılan toplantıda iki tarafın konuşması var mı?
- R6: iOS ya da Teams bir uyarı/gösterge gösterdi mi (U5)? Ekran görüntüsü.
- R7 (isteğe bağlı): AirPods'la tekrar (U6), ekran kilitliyken (U4), 30 dk pil (U8).

## 6. Prototip ve bayrak

- Kod: `iOS/CallCapture/` (yeni dosyalar). Kanca: `iOS/MeetingsTab.swift`'te "İçe aktar" menüsüne bir bölüm ve bir
  sayfa. Kayıt bitince karışık dosya (`call-….m4a`) mevcut içe aktarma hattına (`PhoneRecorder.importFiles` →
  `importMediaAudio` → kuyruk) verilir.
- Bayrak: derleme ayarı `CALL_CAPTURE_EXPERIMENT` (`project.yml`, AINotepadiOS). **Debug'da YES, Release'de NO.**
  YES olunca (1) Swift koşulu `CALL_CAPTURE_EXPERIMENT` açılır, kod derlenir; (2) bir derleme betiği paketlenen
  Info.plist'e `UIBackgroundModes += screen-capture` ekler. NO olunca ikisi de yok: App Store derlemesi bugünküyle aynı
  (ne kod ne arka plan modu).
- Neden derleme ayarı, çalışma anı bayrağı değil: TestFlight'ta açılış argümanı verilemez; `AppTransaction`
  ortamı (sandbox) App Review'da da sandbox olduğu için özelliği inceleyiciye gösterirdi; kullanılmayan
  `screen-capture` modunu App Store derlemesinde bildirmek de 2.5.4 reddi riski.
- TestFlight derlemesi (ebeveyn yükler):
  `xcodebuild archive -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Release CALL_CAPTURE_EXPERIMENT=YES …`
  ve **ayrı bir derleme numarası**; bu derleme yalnız iç teste verilir, App Store incelemesine gönderilmez.
- Görünüm metinleri `Text(verbatim:)`: deneysel ekran metin kataloğuna girmez.
- ScreenCaptureKit **iOS Simulator SDK'sında yok** (`iPhoneSimulator27.2.sdk` yalnız ReplayKit içerir): yakalama kodu
  `canImport(ScreenCaptureKit)` ile ayrılır, Simulator'da sayfa yalnız nedenini söyler. Test yalnız cihazda.
- Ham dosyalar `Application Support/CallCaptureExperiment/<zaman>/` altında (`system.m4a`, `mic.m4a`, karışık
  `Telefon görüşmesi ….m4a`); yeni kayıt öncekini siler. Parça gelmeyen aralıklar sessizlikle doldurulur (iki kaynak
  hizalı karışsın); "boşluk" sayacı bunu gösterir — sistem sesi yalnız ses çalarken geliyorsa boşluk büyür.
- Doğrulanan derlemeler: AINotepadiOS Debug (cihaz + Simulator), Release cihaz `CALL_CAPTURE_EXPERIMENT=NO` (Info.plist
  `UIBackgroundModes = [audio]`, deneysel kod yok) ve `=YES` (`[audio, screen-capture]`), AINotepad, AINotepadHosted;
  `swift test` (536 test).

## 7. App Review değerlendirmesi (özellik ürüne girerse)

- `screen-capture` arka plan modu "screen sharing services" diye tanımlı. Ekran paylaşmayıp yalnız ses kaydeden bir
  not uygulamasının bu modu kullanması incelemede sorgulanabilir (2.5.4: arka plan modları yalnız amacına uygun).
  İnceleme notunda akış açıkça anlatılmalı; kayıt sırasında sistem göstergesi zaten görünür.
- 5.1.1 / 5.1.2 gizlilik: karşı tarafın sesi kaydedilir → kayıttan önce katılımcılara haber verme hatırlatması
  (mevcut "Kayıt başlarken haber vermeyi hatırlat" ayarı) bu akışta da gösterilmeli; gizlilik politikası "telefondaki
  görüşme sesi" kategorisini anmalı; App Privacy "Audio Data" zaten bildirilmiş olmalı (sunucuya transkripsiyon için
  gidiyor).
- 2.5.1 (genel API kullanımı): seçici ve sistem göstergesi Apple'ın kendi izin yüzü; sorun beklenmez.
- Teams/Zoom'un hizmet şartları ve yerel kayıt yasaları (tek/çift taraflı rıza) kullanıcı metninde anılmalı.
- Ayarlar'daki şu metin özellik ürüne girerse değişmeli: "Telefondaki Teams/Zoom görüşmeleri kaydedilemez (iOS izin
  vermez); onlar için Mac'i kullan." (`iOS/SettingsTab.swift`), site ve SSS de ("change the whole chain").

Gereken kullanıcı metinleri (taslak):

- Başlatmadan önce: "Görüşmeyi kaydetmeden önce katılımcılara haber ver. Açılan sistem penceresinde ekran paylaşımını
  onayla ve mikrofonu aç; Gistsmith yalnız sesi kaydeder, ekran görüntüsünü kaydetmez."
- Gizlilik politikası: "iOS 27 ve sonrasında, istediğinde telefonda çalan görüşme sesini (ör. Teams/Zoom) ve
  mikrofonunu kaydeder; ekran görüntüsü saklanmaz. Ses transkripsiyon için sunucumuza gönderilir ve …"

## 8. Cihaz testi olumsuz çıkarsa (U1 = hayır) alternatifler

| Yöntem | Nasıl | Maliyet | Artı / eksi |
|---|---|---|---|
| Toplantı botu (Recall.ai vb.) | Sunucu, toplantı bağlantısına bot gönderir; ayrı ses + konuşmacı adı gelir | Recall.ai kayıt saati başına yaklaşık $0.50–1 (güncel fiyat teyit edilmeli) + sunucu işi | iPhone'dan bağımsız, en güvenilir; "bot katıldı" görünür, kurumsal Teams botları engelleyebilir, takvim/bağlantı gerekir |
| Telefonla katılma (dial-in) | Teams/Zoom'un dial-in numarasını Twilio vb. ile arayıp sesi sunucuda kaydetmek | Twilio ses dakikası ~$0.01–0.02 + numara; toplantının dial-in açık olması gerekir | Basit ses; her toplantıda dial-in yok, PIN girişi gerekir |
| İkinci cihaz / Mac | Görüşme Mac'te ya da hoparlörde, telefon odada kaydeder | 0 | Bugün çalışıyor (Mac'te sistem sesi zaten alınıyor); hoparlör yankısı, kalite düşük |
| Hoparlör + mevcut yüz yüze kayıt | Teams'i hoparlöre alıp aynı telefonda mikrofonla kaydetmek | 0 | iOS, VoIP görüşmesinde başka uygulamanın mikrofonunu genelde keser; muhtemelen çalışmaz (U2 ile birlikte denenebilir) |
