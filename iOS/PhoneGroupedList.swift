import AINotepadUI
import SwiftUI

// Gruplu listeler (ayarlar, hesap, bağlantılar, düzenleme sayfaları): Kor paletinde zemin, satırlar ve ayırıcılar
// paletin sıcak renklerinde (zemin `Theme.background`, satır `Theme.card`, ayırıcı `Theme.line`); sistemin gruplu grisi
// Kor'da soğuk kalıyordu. Klasik'te sistemin gruplu renkleri olduğu gibi kalır (görünüm değişmez). Bir satırın kendi
// `listRowBackground`'u önceliklidir.

/// Gruplu `List`: Kor'da paletin zemini, satır ve ayırıcı rengi; Klasik'te sistemin gruplu renkleri.
struct PhoneGroupedList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        List {
            content
                .listRowBackground(phoneGroupedRowBackground())
                .listRowSeparatorTint(phoneGroupedSeparator())
        }
        .modifier(PhoneGroupedBackground())
    }
}

/// Gruplu `Form` (`PhoneGroupedList` gibi).
struct PhoneGroupedForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
                .listRowBackground(phoneGroupedRowBackground())
                .listRowSeparatorTint(phoneGroupedSeparator())
        }
        .modifier(PhoneGroupedBackground())
    }
}

/// Gruplu listenin zemini: Kor'da sistemin zeminini gizleyip paletin zeminini koyar; Klasik'te sistemin zemini kalır.
private struct PhoneGroupedBackground: ViewModifier {
    func body(content: Content) -> some View {
        let isEmber: Bool = ThemeStore.shared.palette.family == .ember
        content
            .scrollContentBackground(isEmber ? .hidden : .automatic)
            .background(isEmber ? Theme.background : Color.clear)
    }
}

/// Gruplu listenin satır zemini: Kor'da paletin kart rengi, Klasik'te nil (sistemin satır rengi).
@MainActor
private func phoneGroupedRowBackground() -> Color? {
    ThemeStore.shared.palette.family == .ember ? Theme.card : nil
}

/// Gruplu listenin satır ayırıcısı: Kor'da paletin çizgi rengi, Klasik'te nil (sistemin ayırıcısı).
@MainActor
private func phoneGroupedSeparator() -> Color? {
    ThemeStore.shared.palette.family == .ember ? Theme.line : nil
}
