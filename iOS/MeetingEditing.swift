import AINotepadCore
import AINotepadUI
import SwiftUI

/// Notu sorarak düzenle (Mac'teki gibi): tek satır istek ("özeti kısalt", "görevlere tarih ekle") ve odaklanınca hazır
/// öneri hapları; düzenlenirken "Not düzenleniyor…". Eski not geçmişe girer (⋯ › Önceki sürümler).
struct PhoneNoteEditBar: View {
    let isWorking: Bool
    /// Kayıttaki ya da işlenen toplantıda kapalı.
    let isEnabled: Bool
    let onEdit: @MainActor (String) -> Void
    @State private var instruction: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    /// Hazır istekler (kaynak dilde; gösterilirken ve gönderilirken arayüz diline çevrilir). Mac'tekilerle aynı.
    private let suggestions: [String] = ["Özeti kısalt", "Görevlere tarih ekle", "Kararları gerekçeleriyle yaz", "Daha resmi yaz"]

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isWorking ? "sparkles" : "wand.and.stars")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
                TextField(isWorking ? "Not düzenleniyor…" : "Notu düzenle: \"özeti kısalt\"…", text: $instruction)
                    .appFont(size: 15, weight: .regular)
                    .submitLabel(.send)
                    .focused($isFocused)
                    .disabled(isWorking || !isEnabled)
                    .onSubmit(send)
                if !instruction.isEmpty, !isWorking {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .appFont(size: 13, weight: .bold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 30, height: 30)
                            .background(Theme.primary, in: Circle())
                    }
                    .buttonStyle(PressableCardStyle())
                    .accessibilityLabel("Notu düzenle")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.card, in: shape)
            .overlay(shape.strokeBorder(isFocused ? appearance.accent.color.opacity(0.45) : Theme.line))
            if isFocused, instruction.isEmpty, !isWorking {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(suggestions, id: \.self) { (suggestion: String) in
                        Button {
                            isFocused = false
                            onEdit(String(localized: String.LocalizationValue(suggestion)))
                        } label: {
                            Text(LocalizedStringKey(suggestion))
                                .appFont(size: 13, weight: .medium)
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.soft, in: Capsule())
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: isFocused)
    }

    private func send() {
        guard !isWorking, isEnabled else {
            return
        }
        onEdit(instruction)
        instruction = ""
        isFocused = false
    }
}

/// Konuşmacılara ad ver: her kişi için konuşma payı ve ad alanı. Boş ad "Konuşmacı N" etiketini geri getirir; ad
/// transkriptte ve notta görünür (notu yeni adlarla yazmak için "Notu yenile"). "Sen" adlandırılmaz. Satırdaki birleştirme
/// menüsü kişiyi başka bir konuşmacıyla birleştirir (Mac'teki "Şununla birleştir"; son geçiş aynı kişiyi ikiye böldüyse),
/// hemen saklanır.
struct SpeakerNamingSheet: View {
    let shares: [SpeakerShare]
    let speakerNames: [Int: String]
    let onSave: @MainActor ([Int: String]) throws -> Void
    /// Birleştirme: ilk kişinin tüm bölümleri ikinciye geçer.
    let onMerge: @MainActor (Int, Int) throws -> Void
    @State private var drafts: [Int: String] = [:]
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        // Az konuşanlar (bkz. `groupedSpeakers`) ayrı bölümde, sonda: ad verilebilir ama listeyi kalabalıklaştırmaz.
        let groups: SpeakerGroups = groupedSpeakers(shares: shares, speakerNames: speakerNames)
        let persons: [SpeakerShare] = groups.major.filter { $0.key.person != nil }
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        PhoneErrorList(messages: [errorMessage])
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(Array(persons.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerShare)) in
                        if let person = item.element.key.person {
                            row(share: item.element, person: person)
                        }
                    }
                } header: {
                    PhoneHintHeader(
                        title: Text("Adlar"),
                        hint: Text("Ad transkriptte \"Konuşmacı N\" yerine görünür. Notu yeni adlarla yazmak için ⋯ › Notu yenile.")
                    )
                }
                if !groups.minor.isEmpty {
                    Section("Kısa konuşmalar (\(groups.minor.count))") {
                        ForEach(Array(groups.minor.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerShare)) in
                            if let person = item.element.key.person {
                                row(share: item.element, person: person)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Konuşmacılar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet", action: save)
                }
            }
        }
        .onAppear { drafts = speakerNames }
    }

    private func row(share: SpeakerShare, person: Int) -> some View {
        HStack(spacing: 12) {
            SpeakerBadge(speaker: share.key.speaker, person: person, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    speakerLabel(speaker: share.key.speaker, person: person),
                    text: Binding<String>(
                        get: { drafts[person] ?? "" },
                        set: { (name: String) -> Void in drafts[person] = name }
                    )
                )
                .appFont(size: 16, weight: .medium)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                // Konuşma payı (Özet'teki "Kim ne kadar konuştu" ile aynı yazım).
                Text(verbatim: "\(speakerLabel(speaker: share.key.speaker, person: person)) · \(share.fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))")
                    .appFont(size: 12, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            let others: [Int] = shares.compactMap(\.key.person).filter { $0 != person }
            if !others.isEmpty {
                Menu {
                    Section("Şununla birleştir") {
                        ForEach(others, id: \.self) { (target: Int) in
                            Button(speakerDisplayName(person: target)) { merge(from: person, into: target) }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                        .appFont(size: 15, weight: .medium)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Şununla birleştir"))
            }
        }
        .padding(.vertical, 4)
    }

    /// Kişinin görünen adı: verilmiş (ya da yazılmakta olan) ad, yoksa "Konuşmacı N".
    private func speakerDisplayName(person: Int) -> String {
        let name: String = (drafts[person] ?? speakerNames[person] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? speakerLabel(speaker: .others, person: person) : name
    }

    /// Birleştirir; birleşen kişinin yazılmakta olan adı bırakılır. Olmazsa neden sayfada görünür.
    private func merge(from: Int, into: Int) {
        do {
            try onMerge(from, into)
            drafts[from] = nil
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Konuşmacılar birleştirilemedi: \(userFacingMessage(error: error))")
        }
    }

    private func save() {
        do {
            // Yalnız listedeki kişiler yazılır; boş alan adı kaldırır.
            let edits: [Int: String] = Dictionary(
                shares.compactMap { (share: SpeakerShare) -> (Int, String)? in
                    share.key.person.map { (person: Int) -> (Int, String) in (person, drafts[person] ?? "") }
                },
                uniquingKeysWith: { (first: String, _: String) -> String in first }
            )
            try onSave(edits)
            dismiss()
        } catch {
            errorMessage = String(localized: "Adlar kaydedilemedi: \(userFacingMessage(error: error))")
        }
    }
}
