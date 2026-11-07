import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kısayol satırının simgesi. Saf fonksiyondur.
private func shortcutSymbol(action: ShortcutAction) -> String {
    switch action {
    case .record: "record.circle"
    case .toggleWindows: "rectangle.on.rectangle"
    case .dictate: "mic"
    }
}

/// Ayarlar › Kısayollar: uygulamanın bütün kısayolları. Her yerde çalışan (global) kısayollar ve sesle yazmanınki
/// değiştirilebilir (kaydedici); ana penceredeki menü kısayolları, Sor'un soru alanı ve arama penceresinin tuşları
/// sabittir, tuş başlıklarıyla listelenir. Uygulamaya yeni bir kısayol eklenince buraya da eklenir.
struct ShortcutSettings: View {
    let shortcuts: ShortcutController
    @AppStorage(SettingsKey.voiceTypingEnabled) private var voiceTypingEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: Text("Her uygulamada")) {
                ForEach([ShortcutAction.record, ShortcutAction.toggleWindows], id: \.self) { (action: ShortcutAction) in
                    SettingsRow(icon: shortcutSymbol(action: action), title: Text(action.title)) {
                        if let error = shortcuts.errors[action] {
                            NoticeText(error, severity: .error)
                        }
                    } control: {
                        ShortcutRecorder(shortcuts: shortcuts, action: action, binding: shortcuts.currentBinding(action: action))
                    }
                }
            } footer: {
                Text("Kısayola tıklayıp yeni tuşlara bas; vazgeçmek için Esc. ⌃, ⌥ ya da ⌘ ile birlikte bir harf ya da rakam seç.")
            }
            SettingsGroup(title: Text("Sesle yazma")) {
                SettingsRow(icon: shortcutSymbol(action: .dictate), title: Text(ShortcutAction.dictate.title)) {
                    Text("Basılı tut: konuştuğun sürece dinler, bırakınca yazar. Kısa dokun: eller serbest dinler.")
                    if !voiceTypingEnabled {
                        NoticeText("Sesle yazma kapalı; Sesle yazma sekmesinden açabilirsin.", severity: .attention)
                    } else if let error = shortcuts.errors[.dictate] {
                        NoticeText(error, severity: .error)
                    } else if let reason = shortcuts.unsetDefaults[.dictate] {
                        NoticeText(String(localized: "Varsayılan kısayol atanmadı: \(reason) Sesle yazmak için bir kısayol seç."), severity: .attention)
                    }
                } control: {
                    ShortcutRecorder(shortcuts: shortcuts, action: .dictate, binding: shortcuts.assignedBinding(action: .dictate))
                        .disabled(!voiceTypingEnabled)
                }
                FixedShortcutRow(icon: "escape", title: Text("Eller serbest dinlemeyi bitir"), keys: [["esc"]])
            }
            SettingsGroup(title: Text("Ana pencere")) {
                FixedShortcutRow(icon: "record.circle", title: Text("Kaydı başlat / durdur"), keys: [["⌘", "N"]])
                FixedShortcutRow(icon: "magnifyingglass", title: Text("Toplantılarda ara"), keys: [["⌘", "K"], ["⌘", "F"]])
                FixedShortcutRow(icon: "arrow.uturn.backward", title: Text("Kayıt ekranından uygulamaya dön"), keys: [["esc"]])
                FixedShortcutRow(icon: "gearshape", title: Text("Ayarlar"), keys: [["⌘", ","]])
                FixedShortcutRow(icon: "power", title: Text("Çık"), keys: [["⌘", "Q"]])
            }
            SettingsGroup(title: Text("Gezinme")) {
                FixedShortcutRow(icon: "house", title: Text("Ana sayfa"), keys: [["⌘", "1"]])
                FixedShortcutRow(icon: "list.bullet.rectangle", title: Text("Toplantılar"), keys: [["⌘", "2"]])
                FixedShortcutRow(icon: "sparkle.magnifyingglass", title: Text("Sor"), keys: [["⌘", "3"]])
                FixedShortcutRow(icon: "checkmark.circle", title: Text("Görevlerim"), keys: [["⌘", "4"]])
                FixedShortcutRow(icon: "person.2", title: Text("Kişiler"), keys: [["⌘", "5"]])
                FixedShortcutRow(icon: "chart.bar.xaxis", title: Text("İstatistikler"), keys: [["⌘", "6"]])
            }
            SettingsGroup(title: Text("Sor")) {
                FixedShortcutRow(icon: "arrow.up.circle", title: Text("Soruyu gönder"), keys: [["↩"]])
                FixedShortcutRow(icon: "text.append", title: Text("Yeni satır"), keys: [["⇧", "↩"]])
                FixedShortcutRow(icon: "clock.arrow.circlepath", title: Text("Son soruyu geri getir (alan boşken)"), keys: [["↑"]])
                FixedShortcutRow(icon: "at", title: Text("Toplantı seç"), keys: [["@"]])
                FixedShortcutRow(icon: "text.badge.star", title: Text("Tarif uygula"), keys: [["/"]])
                FixedShortcutRow(icon: "arrow.up.arrow.down", title: Text("Önerilerde gezin"), keys: [["↑"], ["↓"]])
                FixedShortcutRow(icon: "return", title: Text("Öneriyi seç"), keys: [["⇥"], ["↩"]])
                FixedShortcutRow(icon: "xmark.circle", title: Text("Öneriyi kapat, alanı temizle"), keys: [["esc"]])
            }
            SettingsGroup(title: Text("Arama penceresi")) {
                FixedShortcutRow(icon: "arrow.up.arrow.down", title: Text("Sonuçlarda gezin"), keys: [["↑"], ["↓"]])
                FixedShortcutRow(icon: "return", title: Text("Sonucu aç"), keys: [["↩"]])
                FixedShortcutRow(icon: "xmark.circle", title: Text("Kapat"), keys: [["esc"]])
            }
        }
    }
}

/// Değiştirilemeyen kısayolun satırı: sağda tuş başlıkları; `keys` birbirinin yerine geçen bileşimlerdir (ör. ⌘K ya da
/// ⌘F), aralarında soluk "/".
private struct FixedShortcutRow: View {
    let icon: String
    let title: Text
    let keys: [[String]]

    var body: some View {
        SettingsRow(icon: icon, title: title) {
            EmptyView()
        } control: {
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { (item: (offset: Int, element: [String])) in
                    if item.offset > 0 {
                        Text(verbatim: "/")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    KeycapRow(labels: item.element, height: 22, fontSize: 12)
                }
            }
            // VoiceOver bileşimleri harf harf değil tek ad olarak okur.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: keys.map { $0.joined() }.joined(separator: ", ")))
        }
    }
}

/// Tuş başlıkları: her tuş küçük, yuvarlatılmış, ince çerçeveli bir başlık (ör. ⌘ K). Karşılamanın "Hazırsın" adımında
/// ve Ayarlar › Kısayollar'da aynı görünüm.
struct KeycapRow: View {
    let labels: [String]
    let height: CGFloat
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: height * 0.16) {
            ForEach(Array(labels.enumerated()), id: \.offset) { (key: (offset: Int, element: String)) in
                Text(verbatim: key.element)
                    .appFont(size: fontSize, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: height, minHeight: height)
                    .padding(.horizontal, height * 0.16)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: height * 0.27, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: height * 0.27, style: .continuous).strokeBorder(Theme.line))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
            }
        }
    }
}
