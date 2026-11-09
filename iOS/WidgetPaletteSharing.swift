import AINotepadUI
import Foundation
import os
import WidgetKit

private let widgetPaletteLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "WidgetPalette")

/// Uygulamanın paleti widget'larda (bkz. `WidgetPalette`). Saf fonksiyondur.
func widgetPalette(family: ThemeFamily) -> WidgetPalette {
    switch family {
    case .ember: .ember
    case .classic: .classic
    }
}

/// Seçili paleti App Group'taki dosyaya yazar ve widget'ları yeniler; dosyada zaten bu palet varsa bir şey yapmaz.
/// Widget'lar ve canlı etkinlik paleti oradan okur. Yazılamazsa hata günlüğe yazılır (uygulama etkilenmez; widget'lar
/// önceki paletle çizilir).
@MainActor
func shareWidgetPalette(family: ThemeFamily) {
    let palette: WidgetPalette = widgetPalette(family: family)
    do {
        let url: URL = try widgetPaletteFileURL()
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let stored: String = try String(contentsOf: url, encoding: .utf8)
            if widgetPalette(fileContents: stored) == palette {
                return
            }
        }
        try Data(palette.rawValue.utf8).write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    } catch {
        widgetPaletteLogger.error(
            "Widget palette could not be shared. palette: \(palette.rawValue, privacy: .public), error: \(String(describing: error), privacy: .public)"
        )
    }
}
