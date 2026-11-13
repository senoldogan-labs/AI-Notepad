import AINotepadUI
import Foundation
import os
import WidgetKit

private let widgetPaletteLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "WidgetPalette")

/// Uygulamanın paleti ve vurgusu widget'larda (bkz. `WidgetLook`): Kor'un küresi ve "Bitir" düğmesi vurgunun tonunda
/// (uygulamadaki kayıt küresiyle aynı duraklar); Klasik'in kayıt dairesi vurgunun Klasik rengi (turuncuda önceki
/// widget turuncusu); Zeytin düz limon dolgu ve koyu yazıyla. Saf fonksiyondur.
func widgetLook(family: ThemeFamily, accent: PanelAccent) -> WidgetLook {
    let palette: WidgetPalette = switch family {
    case .ember: .ember
    case .classic: .classic
    case .olive: .olive
    }
    let accentColors: AccentColors = ThemePalette.ember.accents[accent]
    let oliveColors: AccentColors = ThemePalette.olive.accents[accent]
    let orb: [UInt32] = [0xE9C9AC, EmberStop.e500, EmberStop.e600, EmberStop.e900].map { (hex: UInt32) -> UInt32 in emberTinted(hex: hex, accent: accent) }
    let classicFill: UInt32 = accent == .orange ? widgetClassicOrangeFill : ThemePalette.classic.accents[accent].light
    return WidgetLook(
        palette: palette, ember: widgetEmberColors(family: family, orb: orb, ember: accentColors, olive: oliveColors), classicFill: classicFill
    )
}

/// The colour triple the widgets read: Ember's tinted orb, copper "Finish" fill and accent text; Olive's lime fill and
/// accent text (the orb stops are unused there). Pure function.
private func widgetEmberColors(family: ThemeFamily, orb: [UInt32], ember: AccentColors, olive: AccentColors) -> WidgetEmberColors {
    switch family {
    case .olive: WidgetEmberColors(orb: orb, finish: olive.dark, onDark: olive.dark)
    case .ember, .classic: WidgetEmberColors(orb: orb, finish: ember.light, onDark: ember.dark)
    }
}

/// Seçili görünümü App Group'taki dosyaya yazar ve widget'ları yeniler; dosyada zaten bu görünüm varsa bir şey yapmaz.
/// Widget'lar ve canlı etkinlik görünümü oradan okur. Yazılamazsa hata günlüğe yazılır (uygulama etkilenmez; widget'lar
/// önceki görünümle çizilir).
@MainActor
func shareWidgetLook(look: WidgetLook) {
    do {
        let url: URL = try widgetPaletteFileURL()
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let stored: String = try String(contentsOf: url, encoding: .utf8)
            do {
                if try widgetLook(fileContents: stored) == look {
                    return
                }
            } catch {
                // Okunamayan dosya yeni görünümle yeniden yazılır.
                widgetPaletteLogger.warning(
                    "Stored widget look is unreadable; rewriting it. error: \(String(describing: error), privacy: .public)"
                )
            }
        }
        try Data(try widgetLookFileContents(look: look).utf8).write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    } catch {
        widgetPaletteLogger.error(
            "Widget look could not be shared. palette: \(look.palette.rawValue, privacy: .public), error: \(String(describing: error), privacy: .public)"
        )
    }
}
