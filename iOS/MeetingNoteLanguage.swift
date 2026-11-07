import AINotepadCore
import AINotepadUI
import SwiftUI

// Toplantı sayfasında notu başka dilde okumak (Mac'teki özetin dil menüsü): seçilen dildeki sürüm yoksa sunucuda
// çevrilir (`PhoneStore.translateNote`) ve toplantıda saklanır; sayfa, paylaşım ve dışa aktarma o sürümü gösterir.

/// Notun dili: asıl not (yazıldığı dil), sık kullanılan Fince ve İngilizce, sonra diğer diller (`shareLanguageChoices`).
/// Seçili dil işaretli; adlar arayüz dilinde.
struct NoteLanguageMenu: View {
    let original: ShareLanguage
    @Binding var selection: ShareLanguage?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let choices: ShareLanguageChoices = shareLanguageChoices(original: original)
        Menu {
            item(language: nil, name: original.interfaceTitle)
            ForEach(choices.featured, id: \.rawValue) { (language: ShareLanguage) in
                item(language: language, name: language.interfaceTitle)
            }
            Menu("Diğer diller") {
                ForEach(choices.others, id: \.rawValue) { (language: ShareLanguage) in
                    item(language: language, name: language.interfaceTitle)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .foregroundStyle(selection == nil ? Theme.muted : appearance.accent.color)
                Text(verbatim: (selection ?? original).interfaceTitle)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .appFont(size: 14, weight: .medium)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(selection == nil ? Theme.line : appearance.accent.color.opacity(0.5)))
        }
        .fixedSize()
        .accessibilityLabel("Notun dili")
    }

    private func item(language: ShareLanguage?, name: String) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.25)) { selection = language }
        } label: {
            if selection == language {
                Label(name, systemImage: "checkmark")
            } else {
                Text(verbatim: name)
            }
        }
    }
}

/// Seçilen dildeki sürüm henüz yok (ya da eski, eksik bölümlü sürüm): çevrilirken ilerleme, olmazsa neden ve "Yeniden
/// dene". Sürüm saklanınca sayfa onu asıl notla aynı düzende gösterir. Toplantı kayıtta, işlenirken ya da notu
/// yazılırken çevrilmez (sonuç saklanamazdı); kilit kalkınca ya da not değişince yeniden istenir.
struct SharedNotePending: View {
    let store: PhoneStore
    let record: MeetingRecord
    /// Asıl not (dil seçimi değişmeden yeniden yazılırsa çeviri yeni not için istenir).
    let note: MeetingNote
    let language: ShareLanguage
    let isEditable: Bool
    @State private var error: String?
    @State private var attempt: Int = 0

    var body: some View {
        Group {
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    PhoneErrorList(messages: [String(localized: "Not çevrilemedi: \(error)")])
                    Button("Yeniden dene", systemImage: "arrow.clockwise") {
                        self.error = nil
                        attempt += 1
                    }
                    .appFont(size: 14, weight: .medium)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(language.interfaceName) sürümü hazırlanıyor…")
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }
        .task(id: "\(language.rawValue)-\(attempt)-\(note.summary.hashValue)-\(isEditable)") {
            guard error == nil, isEditable else {
                return
            }
            do {
                try await store.translateNote(meetingID: record.id, language: language)
            } catch is CancellationError {
                // Sayfa kapandı ya da dil değişti: hata değil.
                return
            } catch let cancelled as URLError where cancelled.code == .cancelled {
                return
            } catch {
                self.error = userFacingMessage(error: error)
            }
        }
    }
}
