import AINotepadUI
import Foundation
import os
import WidgetKit

private let widgetPaletteLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "WidgetPalette")

/// Uygulamanın paleti ve vurgusu widget'larda (bkz. `WidgetLook`): Kor'un küresi ve "Bitir" düğmesi vurgunun tonunda
/// (uygulamadaki kayıt küresiyle aynı duraklar). Saf fonksiyondur.
func widgetLook(family: ThemeFamily, accent: PanelAccent) -> WidgetLook {
    let palette: WidgetPalette = switch family {
    case .ember: .ember
    case .classic: .classic
    }
    let accentColors: AccentColors = ThemePalette.ember.accents[accent]
    let orb: [UInt32] = [0xE9C9AC, EmberStop.e500, EmberStop.e600, EmberStop.e900].map { (hex: UInt32) -> UInt32 in emberTinted(hex: hex, accent: accent) }
    return WidgetLook(palette: palette, ember: WidgetEmberColors(orb: orb, finish: accentColors.light, onDark: accentColors.dark))
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
