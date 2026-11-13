import AINotepadUI
import AppKit
import os
import SwiftUI

private let appIconLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppIcon")

/// Why the chosen Dock icon could not be shown.
enum DockIconError: Error, CustomStringConvertible {
    /// The asset catalog has no image set for the choice (build mistake: `App/Assets.xcassets/DockIcons`).
    case missingImage(name: String)
    case unknownChoice(AppIconChoiceError)

    var description: String {
        switch self {
        case .missingImage(let name): "Dock icon image set \(name) is missing from App/Assets.xcassets/DockIcons"
        case .unknownChoice(let error): error.description
        }
    }
}

/// Shows the choice as the running app's Dock icon (`standard` restores the bundle icon). macOS keeps a custom icon only
/// while the app runs: when it quits, the Dock and Finder show the bundle icon again, and the app sets it again on the
/// next launch (`applyStoredDockIcon`). Changing the bundle's own icon would break its code signature.
@MainActor
func applyDockIcon(choice: AppIconChoice) throws(DockIconError) {
    guard let name = choice.dockImageName else {
        NSApp.applicationIconImage = nil
        return
    }
    guard let image = NSImage(named: name) else {
        throw DockIconError.missingImage(name: name)
    }
    NSApp.applicationIconImage = image
}

/// The stored icon choice (`AppIconChoice.macStorageKey`).
func storedAppIconChoice(defaults: UserDefaults) throws(DockIconError) -> AppIconChoice {
    do {
        return try appIconChoice(storedValue: defaults.string(forKey: AppIconChoice.macStorageKey))
    } catch {
        throw DockIconError.unknownChoice(error)
    }
}

/// Applies the stored icon at launch. There is no window to show an error in yet: it is logged, the Dock keeps the
/// bundle icon, and Settings › Appearance shows the same error when opened.
@MainActor
func applyStoredDockIcon(defaults: UserDefaults) {
    do {
        try applyDockIcon(choice: storedAppIconChoice(defaults: defaults))
    } catch {
        appIconLogger.error("Stored app icon not applied: \(error.description, privacy: .public)")
    }
}

/// Settings › Appearance › App icon: the five icons side by side; the chosen one has an accent ring. The choice is
/// this Mac's own (like the other appearance settings) and applies at once.
struct AppIconSettingsSection: View {
    @AppStorage(AppIconChoice.macStorageKey) private var storedChoice: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @State private var errorText: String?

    var body: some View {
        let current: Result<AppIconChoice, AppIconChoiceError> = Result { () throws(AppIconChoiceError) -> AppIconChoice in
            try appIconChoice(storedValue: storedChoice)
        }
        SettingsGroup(title: Text("Uygulama simgesi")) {
            SettingsStackedRow(icon: "app.badge", title: Text("Dock simgesi")) {
                Text("Uygulama açıkken Dock'ta görünür; uygulama kapalıyken Dock ve Finder varsayılan simgeyi gösterir.")
            } content: {
                HStack(spacing: 14) {
                    ForEach(AppIconChoice.allCases, id: \.self) { (choice: AppIconChoice) in
                        AppIconTile(choice: choice, isSelected: (try? current.get()) == choice, accent: appearance.accent.color) {
                            select(choice: choice)
                        }
                    }
                }
                if case .failure(let error) = current {
                    Text("Simge değiştirilemedi: \(error.description)").foregroundStyle(Theme.error)
                }
                if let errorText {
                    Text("Simge değiştirilemedi: \(errorText)").foregroundStyle(Theme.error)
                }
            }
        }
    }

    private func select(choice: AppIconChoice) {
        do {
            try applyDockIcon(choice: choice)
            storedChoice = choice == .standard ? nil : choice.rawValue
            errorText = nil
        } catch {
            appIconLogger.error("App icon not applied: \(error.description, privacy: .public)")
            errorText = error.description
        }
    }
}

/// One icon in the picker: the icon image (the bundle icon for `standard`) and its name under it.
private struct AppIconTile: View {
    let choice: AppIconChoice
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(nsImage: tileImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(isSelected ? accent : .clear, lineWidth: 2))
                Text(verbatim: choice.displayName)
                    .appFont(size: 12, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
            }
        }
        .buttonStyle(.plain)
        .linkPointer(isEnabled: true)
        .accessibilityLabel(Text(verbatim: choice.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The bundle's own icon for `standard` (not `NSApp.applicationIconImage`, which shows the current choice). A
    /// missing image set shows a warning sign, and choosing it reports `DockIconError.missingImage`.
    private var tileImage: NSImage {
        guard let name = choice.dockImageName else {
            return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }
        return NSImage(named: name) ?? NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage()
    }
}
