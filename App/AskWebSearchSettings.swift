import AINotepadCore
import SwiftUI

/// Ayarlar › Genel: "Sor'da web aramasına izin ver" (varsayılan açık). Abonelik sürümünde her zaman görünür; kendi
/// anahtarlı sürümde yalnız sağlayıcı Anthropic (Claude) iken (diğer sağlayıcılar web aramasını desteklemez).
struct AskWebSearchSettingsRow: View {
    @AppStorage(askWebSearchSettingKey) private var isEnabled: Bool = true
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue

    var body: some View {
        if isAvailable {
            SettingsRow(title: Text("Sor'da web aramasına izin ver")) {
                #if HOSTED_EDITION
                Text("Açıkken Sor, soru toplantılarında olmayan bir bilgi gerektirdiğinde (güncel bilgi, tanım, ürün, fiyat ya da dış kaynak) cevap başına en çok 3 kez webde arar; web kaynakları cevapta alan adıyla ve cevabın altındaki \"Web\" listesinde ayrıca görünür, tıklayınca tarayıcıda açılır. Aramayı Anthropic (Claude) yapar: modelin sorundan (ve okunan toplantı parçalarından) yazdığı kısa arama sorgusu sunucumuz üzerinden Anthropic'e, oradan arama sağlayıcısına gider; arama sağlayıcısına yalnız bu sorgu gider. Ayda 100 arama hakkın var; dolunca Sor ay sonuna kadar yalnız toplantılardan cevaplar. Kapalıyken webde hiç aranmaz.")
                #else
                Text("Açıkken Sor, soru toplantılarında olmayan bir bilgi gerektirdiğinde (güncel bilgi, tanım, ürün, fiyat ya da dış kaynak) cevap başına en çok 3 kez webde arar; web kaynakları cevapta alan adıyla ve cevabın altındaki \"Web\" listesinde ayrıca görünür, tıklayınca tarayıcıda açılır. Aramayı Anthropic yapar: modelin sorundan (ve okunan toplantı parçalarından) yazdığı kısa arama sorgusu Anthropic üzerinden arama sağlayıcısına gider. Her arama Anthropic hesabına ayrıca ücretlendirilir (1000 aramada 10 $). Kapalıyken webde hiç aranmaz.")
                #endif
            } control: {
                Toggle("Sor'da web aramasına izin ver", isOn: $isEnabled)
                    .settingsToggle()
            }
        }
    }

    /// Ayar anlamlı mı: abonelikte her zaman, kendi anahtarlı sürümde yalnız Anthropic sağlayıcısında.
    private var isAvailable: Bool {
        #if HOSTED_EDITION
        true
        #else
        provider == LLMProviderKind.anthropic.rawValue
        #endif
    }
}
