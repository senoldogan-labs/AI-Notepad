import Foundation

/// Widget'ların çizdiği renk paleti (uygulamadaki `ThemeFamily`): Kor ya da Klasik. Widget eklentisi uygulamanın
/// ayarlarını okuyamaz; uygulama seçili paleti App Group klasöründeki küçük bir dosyaya yazar (`widgetPaletteFileURL`),
/// widget'lar ve canlı etkinlik oradan okur. Dosya yalnızca paletin adını taşır.
enum WidgetPalette: String, Sendable {
    case ember
    case classic
}

/// Uygulama, klavye ve widget eklentisinin paylaştığı App Group (KeyboardCore'daki `keyboardAppGroupIdentifier` ile aynı;
/// widget eklentisi KeyboardCore'a bağlanmaz).
let widgetAppGroupIdentifier: String = "group.com.senoldogan.AINotepad.hosted"

/// App Group klasörü açılamadı (eklentinin ya da uygulamanın yetkisinde grup yok).
struct WidgetPaletteContainerUnavailable: Error, CustomStringConvertible {
    let group: String

    var description: String {
        "App Group container is unavailable; check the target's application-groups entitlement. group: \(group)"
    }
}

/// Paletin yazıldığı dosya (App Group klasöründe).
func widgetPaletteFileURL() throws -> URL {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: widgetAppGroupIdentifier) else {
        throw WidgetPaletteContainerUnavailable(group: widgetAppGroupIdentifier)
    }
    return container.appending(path: "widget-palette", directoryHint: .notDirectory)
}

/// Dosyanın içeriğinden palet: dosya yoksa (uygulama bu sürümle henüz açılmadı) nil; tanınmayan içerik nil. Saf fonksiyondur.
func widgetPalette(fileContents: String?) -> WidgetPalette? {
    fileContents.flatMap { WidgetPalette(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}
