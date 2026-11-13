import AINotepadUI
import os
import SwiftUI
import UIKit

private let appIconLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.hosted", category: "AppIcon")

/// Settings › Appearance › App icon: the five icons side by side (the Mac's Settings offer the same set). The system
/// keeps the choice (`UIApplication.alternateIconName`) and shows its own confirmation alert after a change. Errors
/// (unknown icon name, a refused change) appear under the icons.
struct PhoneAppIconSection: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @State private var current: AppIconChoice?
    @State private var errorText: String?
    @State private var isChanging: Bool = false

    var body: some View {
        Section {
            HStack(spacing: 0) {
                ForEach(AppIconChoice.allCases, id: \.self) { (choice: AppIconChoice) in
                    PhoneAppIconTile(choice: choice, isSelected: current == choice, accent: appearance.accent.color) {
                        Task { await select(choice: choice) }
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isChanging)
                }
            }
            .padding(.vertical, 6)
        } header: {
            PhoneSecondaryText {
                Text("Uygulama simgesi")
            }
        } footer: {
            if let errorText {
                Text(verbatim: errorText).foregroundStyle(Theme.error)
            }
        }
        .task { readCurrent() }
    }

    private func readCurrent() {
        do {
            current = try appIconChoice(alternateIconName: UIApplication.shared.alternateIconName)
        } catch {
            appIconLogger.error("Current app icon unknown: \(error.description, privacy: .public)")
            errorText = String(localized: "Simge değiştirilemedi: \(error.description)")
        }
    }

    private func select(choice: AppIconChoice) async {
        guard choice != current else {
            return
        }
        isChanging = true
        defer { isChanging = false }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateIconName)
            current = choice
            errorText = nil
        } catch {
            appIconLogger.error(
                "App icon not changed: \(error.localizedDescription, privacy: .public), requested: \(choice.alternateIconName ?? "primary", privacy: .public)"
            )
            errorText = String(localized: "Simge değiştirilemedi: \(error.localizedDescription)")
        }
    }
}

/// One icon in the picker: the icon with the system's corner shape and its name under it; the chosen one has an
/// accent ring.
private struct PhoneAppIconTile: View {
    let choice: AppIconChoice
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(choice.previewImageName)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(isSelected ? accent : .clear, lineWidth: 2))
                Text(verbatim: choice.displayName)
                    .appFont(size: 12, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: choice.displayName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
