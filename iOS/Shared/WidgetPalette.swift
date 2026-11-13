import Foundation

/// Widget'ların çizdiği renk paleti (uygulamadaki `ThemeFamily`): Kor, Klasik ya da Zeytin. Widget eklentisi uygulamanın
/// ayarlarını okuyamaz; uygulama seçili görünümü (`WidgetLook`) App Group klasöründeki küçük bir dosyaya yazar
/// (`widgetPaletteFileURL`), widget'lar ve canlı etkinlik oradan okur.
enum WidgetPalette: String, Codable, Sendable {
    case ember
    case classic
    /// Flat (no gradients): lime fills (`WidgetEmberColors.finish`) with `widgetOliveInkHex` ink, lime accent text
    /// (`WidgetEmberColors.onDark`) on the warm charcoal/off-white fields.
    case olive
}

/// Kor'un vurgu tonundaki widget renkleri (uygulamadaki `emberTinted`; eklenti onu derlemez, uygulama hesaplayıp yazar):
/// kayıt küresinin dört durağı, "Bitir" düğmesinin dolgusu (beyaz yazı AA) ve kilit ekranındaki konuşmacı adı.
struct WidgetEmberColors: Equatable, Codable, Sendable {
    let orb: [UInt32]
    let finish: UInt32
    let onDark: UInt32

    /// Kor vurgusundaki renkler (vurgu paylaşılmadan önceki dosyalar da bunlarla çizilir).
    static let standard: WidgetEmberColors = WidgetEmberColors(orb: [0xE9C9AC, 0xA5664B, 0x93553D, 0x4A2519], finish: 0x984B2C, onDark: 0xE39A72)
}

/// Klasik paletin kayıt dairesinin turuncusu (vurgu paylaşılmadan önceki widget'larla aynı; Klasik'in turuncu
/// vurgusunda da bu kalır).
let widgetClassicOrangeFill: UInt32 = 0xE85C1C

/// Ink on Olive's lime fills (`ThemeColorSet.oliveDark.onPrimary`; the widget extension does not link the app's theme).
let widgetOliveInkHex: UInt32 = 0x1E1F14

/// Widget'ların görünümü: palet, Kor'un vurgu tonundaki renkleri ve Klasik'te kayıt dairesinin vurgu rengi.
struct WidgetLook: Equatable, Codable, Sendable {
    let palette: WidgetPalette
    let ember: WidgetEmberColors
    let classicFill: UInt32
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

/// Dosyanın içeriği: görünümün JSON'u. Saf fonksiyondur.
func widgetLookFileContents(look: WidgetLook) throws -> String {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(look), as: UTF8.self)
}

/// Dosyadaki kürenin durak sayısı dört değil.
struct WidgetLookOrbStopsInvalid: Error, CustomStringConvertible {
    let count: Int

    var description: String {
        "The widget look file has \(count) orb stops; expected 4."
    }
}

/// Dosyanın içeriğinden görünüm: görünümün JSON'u ya da önceki sürümlerin yazdığı yalnız paletin adı (Kor vurgusunun
/// renkleriyle). Tanınmayan içerik çözme hatasını (`DecodingError`) ya da `WidgetLookOrbStopsInvalid`'i fırlatır. Saf
/// fonksiyondur.
func widgetLook(fileContents: String) throws -> WidgetLook {
    let trimmed: String = fileContents.trimmingCharacters(in: .whitespacesAndNewlines)
    if let palette = WidgetPalette(rawValue: trimmed) {
        return WidgetLook(palette: palette, ember: .standard, classicFill: widgetClassicOrangeFill)
    }
    let look: WidgetLook = try JSONDecoder().decode(WidgetLook.self, from: Data(trimmed.utf8))
    guard look.ember.orb.count == 4 else {
        throw WidgetLookOrbStopsInvalid(count: look.ember.orb.count)
    }
    return look
}

/// The fill of the Live Activity's "Finish" button, which the system draws with white text (`.borderedProminent`). Both
/// fills keep white text at WCAG AA (4.5:1 or more): Ember's dark copper 984B2C is 6.2:1; Classic uses a deeper orange
/// C2410C (5.2:1) instead of its accent E85C1C, which is only 3.5:1. Pure function.
/// In Ember the fill follows the accent (`WidgetEmberColors.finish`, the Ember palette's light accent: 6.0:1 or more for
/// every accent). Pure function.
func widgetStopButtonFillHex(look: WidgetLook) -> UInt32 {
    switch look.palette {
    case .ember: look.ember.finish
    case .classic: 0xC2410C
    case .olive: look.ember.finish
    }
}
