import AINotepadCore
import AINotepadUI
import SwiftUI

// iPhone'un ortak tasarım parçaları: Mac'teki ElevenLabs dili (sakin zemin, Inter, film gradyanlı kapaklar, soluk
// konuşmacı renkleri) telefona uygun ölçülerle.

/// Bölüm başlığı: büyük harfli küçük etiket ve isteğe bağlı sağda eylem ("Tümünü gör ›").
struct PhoneSectionHeader: View {
    let title: LocalizedStringKey
    let actionTitle: LocalizedStringKey?
    let action: (@MainActor () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .appFont(size: 12, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .textCase(.uppercase)
                .foregroundStyle(Theme.muted)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right").appFont(size: 10, weight: .semibold)
                    }
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Ayar satırının etiketi: solda simge kutusu (Mac'teki ayar kartlarıyla aynı `SettingsIconTile`), başlık ve varsa altında
/// tek cümlelik kısa açıklama. Anahtar, açılır seçim ve bağlantı satırlarının etiketi olarak kullanılır.
struct PhoneSettingLabel<Detail: View>: View {
    let icon: String
    let title: Text
    let detail: Detail

    init(icon: String, title: Text, @ViewBuilder detail: () -> Detail) {
        self.icon = icon
        self.title = title
        self.detail = detail()
    }

    init(icon: String, title: Text) where Detail == EmptyView {
        self.init(icon: icon, title: title) { EmptyView() }
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            SettingsIconTile(systemImage: icon)
        }
    }
}

/// Simgeli ayar satırında açılır seçim (`MenuPickerRow`'un simgeli karşılığı): solda simge ve ad, sağda seçili değer.
/// VoiceOver adı bir kez, seçimle birlikte okur.
struct PhoneSettingMenuRow<Value: Hashable>: View {
    let icon: String
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [MenuPickerOption<Value>]

    var body: some View {
        LabeledContent {
            MenuPicker(title: title, selection: $selection, options: options, size: 15)
        } label: {
            PhoneSettingLabel(icon: icon, title: Text(title))
                .accessibilityHidden(true)
        }
    }
}

/// Satır ve altında kısa açıklama (yalnız o satırı anlatan tek cümle; bölümü anlatan açıklama bölüm altına yazılır).
struct PhoneCaptionedRow<Content: View>: View {
    let caption: Text
    let content: Content

    init(caption: Text, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            caption
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Konuşmacı rozeti: kişinin soluk renginde daire içinde numarası ("Sen" için kişi simgesi).
struct SpeakerBadge: View {
    let speaker: Speaker
    let person: Int?
    let size: CGFloat

    var body: some View {
        let color: Color = person.map { personColor(person: $0) } ?? (speaker == .me ? DesignTokens.meSpeakerColor : Theme.muted)
        ZStack {
            Circle().fill(color.opacity(0.16))
            if let person {
                Text(verbatim: "\(person)")
                    .appFont(size: size * 0.42, weight: .semibold)
                    .foregroundStyle(color)
            } else {
                Image(systemName: speaker == .me ? "person.fill" : "person.2.fill")
                    .appFont(size: size * 0.38, weight: .semibold)
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Hap sekmeler (Mac'teki Özet/Transkript gibi): soluk zemin üstünde seçili sekme beyaz hap.
struct PillTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: LocalizedStringKey)]
    @Namespace private var namespace: Namespace.ID
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            verticalTabs
        } else {
            pills
        }
    }

    /// Erişilebilirlik boyutlarında sekmeler alt alta, tam genişlikte (yan yana sığmayınca "Summar/y" gibi bölünüyordu).
    private var verticalTabs: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { (item: (offset: Int, element: (value: Value, title: LocalizedStringKey))) in
                let isSelected: Bool = selection == item.element.value
                Button {
                    selection = item.element.value
                } label: {
                    HStack(spacing: 10) {
                        Text(item.element.title)
                            .appFont(size: 14, weight: isSelected ? .semibold : .medium)
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .appFont(size: 13, weight: .semibold)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                if item.offset < options.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var pills: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { (item: (offset: Int, element: (value: Value, title: LocalizedStringKey))) in
                let isSelected: Bool = selection == item.element.value
                Button {
                    withAnimation(.smooth(duration: 0.25)) { selection = item.element.value }
                } label: {
                    Text(item.element.title)
                        .appFont(size: 14, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .frame(minHeight: 44)
                        .background {
                            if isSelected {
                                Capsule()
                                    // Koyu zeminde seçili hap zeminden açık olmalı (kart rengi koyuda daha koyu).
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Theme.card)
                                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Theme.soft, in: Capsule())
    }
}

/// Toplantı kapağı (`CoverBackground`) üstündeki çip: beyaz yazı, koyu yarı saydam zemin (açık kapakta da okunur).
struct GlassChip: View {
    let text: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).appFont(size: 11, weight: .semibold)
            }
            Text(text)
        }
        .appFont(size: 12, weight: .medium)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.28), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.20)))
    }
}

/// Açık pastel film gradyanı (kayıt ve Sor kartları) üstündeki çip: koyu yazı, beyaz zemin (Mac'teki kayıt kartı gibi).
struct PastelChip: View {
    let text: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).appFont(size: 11, weight: .semibold)
            }
            Text(text)
        }
        .appFont(size: 12, weight: .medium)
        .foregroundStyle(Color.black.opacity(0.8))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.9), in: Capsule())
    }
}

/// Kapak üstündeki beyaz yazının okunması için alttan koyulaşan katman (ortak `CoverBackground` Mac'te de kullanıldığı
/// için iPhone kapaklarına ayrıca eklenir).
struct CoverScrim: View {
    var body: some View {
        LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
    }
}

/// Konuşmacı zaman çizgisi: toplantı boyunca kim ne zaman konuştu (kapakta ince renkli şerit).
struct SpeakerStrip: View {
    let spans: [SpeakerSpan]
    let totalSec: Double

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                ForEach(Array(spans.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerSpan)) in
                    let span: SpeakerSpan = item.element
                    let color: Color = span.key.person.map { personColor(person: $0) } ?? DesignTokens.meSpeakerColor
                    Capsule()
                        .fill(color.mix(with: .white, by: 0.25))
                        .frame(width: max(2, proxy.size.width * (span.endSec - span.startSec) / max(totalSec, 1)))
                        .offset(x: proxy.size.width * span.startSec / max(totalSec, 1))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Bitmemiş toplantının durumu (kartta); bitmişse boş. Saf fonksiyondur.
func meetingStatusText(status: MeetingStatus) -> String? {
    switch status {
    case .recording: String(localized: "Kayıtta")
    case .processing: String(localized: "Hazırlanıyor")
    case .failed: String(localized: "Hata")
    case .interrupted: String(localized: "Yarıda kaldı")
    case .queued: String(localized: "İşlenmeyi bekliyor")
    case .done: nil
    }
}

/// Toplantı kartı: film gradyanı üstünde başlık; altta saat, süre, dil ve (varsa) sana düşen görev sayısı ya da durum.
struct PhoneMeetingCard: View {
    let record: MeetingRecord
    let height: CGFloat

    var body: some View {
        let myTasks: Int = (record.note?.tasks ?? []).filter { $0.isMine && !isTaskDone(record: record, task: $0) }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let status = meetingStatusText(status: record.status) {
                    GlassChip(text: status, systemImage: record.status == .failed ? "exclamationmark.triangle.fill" : nil)
                }
                Spacer(minLength: 0)
                if myTasks > 0 {
                    GlassChip(text: String(localized: "\(myTasks) görev"), systemImage: "checkmark.circle")
                }
            }
            Spacer(minLength: 0)
            Text(record.note?.title ?? record.title)
                .appFont(size: 18, weight: .semibold)
                .tracking(-0.2)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 1)
            Text(subtitle)
                .appFont(size: 12, weight: .medium)
                .opacity(0.88)
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottomLeading)
        .background {
            CoverBackground(seed: record.id)
                .overlay { CoverScrim() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var subtitle: String {
        let time: String = record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
        let minutes: [String] = meetingDurationMinutes(record: record).map { [String(localized: "\($0) dk")] } ?? []
        let language: [String] = record.language.map { [$0.flag] } ?? []
        return ([time] + minutes + language).joined(separator: " · ")
    }
}

/// Hata satırları (turuncu, okunur boyutta).
struct PhoneErrorList: View {
    let messages: [String]

    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages, id: \.self) { (message: String) in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(NoticeSeverity.attention.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Kapatılabilen hata satırları (toplantı işlemlerinin hataları): `PhoneErrorList` gibi, sağda kapatma düğmesi.
struct PhoneDismissibleErrorList: View {
    let messages: [String]
    let onDismiss: @MainActor () -> Void

    var body: some View {
        if !messages.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages, id: \.self) { (message: String) in
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .appFont(size: 13, weight: .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .appFont(size: 11, weight: .semibold)
                        .frame(width: 28, height: 28)
                        // Dokunma alanı en az 44 pt (Apple HIG); simge küçük kalır.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kapat")
            }
            .foregroundStyle(NoticeSeverity.attention.tint)
            .padding(.vertical, 14)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Hiç veri yokken sekmenin boş sahnesi (Toplantılar, Görevler, Sor): Mac'teki boş sahneyle aynı (durgun pastel gradyan
/// üstünde örnek not kartı, başlık, tek cümle, vurgu renkli eylemler); alanın dikey ortasında, sığmazsa kaydırılır.
struct PhoneEmptyScene<Actions: View>: View {
    let symbol: String
    let palette: FilmPalette
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ScrollView {
                EmptyScene(symbol: symbol, palette: palette, title: title, message: message) {
                    actions()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Sakin boş durum (arama sonucu yok, tamamlanan yok, saklanan sohbet yok): Mac'teki gibi vurgu renkli simge kutusu, kısa
/// başlık, tek cümle ve varsa tek eylem; arkada süs yok. Bulunduğu alanı doldurur, içerik ortalanır.
struct PhoneEmptyState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 60)
            VStack(spacing: 6) {
                Text(title)
                    .appFont(size: 19, weight: .semibold)
                    .tracking(-0.3)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            actions()
                .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Giriş ve yapay zekâ açıklaması ekranlarının üstündeki pastel kart: durağan film gradyanı (hareketsiz; bkz. tasarım
/// kuralları), içerik ortada, açık renk düzeninde (koyu modda da pastel kalır).
struct PhoneHeroCard<Content: View>: View {
    let seed: String
    let palette: FilmPalette
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        FilmGradient(seed: seed, palette: palette)
            .overlay { content().padding(24) }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .environment(\.colorScheme, .light)
    }
}

/// Pastel kartın yüksekliği: ekranın (güvenli alan içi) belirli bir oranı, en az ve en çok sınırlarla; küçük iPhone'da
/// düğmeler kaydırmadan görünür, büyükte kart orantılı büyür. Saf fonksiyondur.
func phoneHeroHeight(screenHeight: CGFloat, ratio: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    min(max(screenHeight * ratio, minimum), maximum)
}

/// Tam genişlik birincil düğme yazısı (koyu hap, açık yazı): giriş ve açıklama ekranlarında aynı ölçü.
struct PhonePrimaryButtonLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .appFont(size: 16, weight: .semibold)
            .foregroundStyle(Theme.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.primary, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Kısa tek alanlı giriş (ad değiştirme, yeni klasör): küçük sayfa, alan odakta; boş metinle eylem kapalıdır.
struct PhoneTextEntrySheet: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let initialText: String
    let onSave: @MainActor (String) -> Void
    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            TextField(placeholder, text: $text)
                .appFont(size: 17, weight: .regular)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                .padding(20)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.background)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Vazgeç") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(actionTitle, action: save)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.height(190)])
        .onAppear {
            text = initialText
            isFocused = true
        }
    }

    private func save() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        onSave(text)
        dismiss()
    }
}

/// Toplantının küçük pastel kutusu: durağan film gradyanı (toplantıya göre) üstünde toplantı simgesi. Ana ekrandaki,
/// aramadaki satırlarda ve toplantı sayfasının başlığında. Kayıt türü (oda, görüşme, içe aktarma) toplantıda saklanmadığı
/// için simge hepsinde aynıdır.
struct MeetingTile: View {
    let record: MeetingRecord
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(.clear)
            .frame(width: size, height: size)
            .background { CoverBackground(seed: record.id) }
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Toplantı sayfasının sonunda kapalı başlayan "Ayrıntılar" bölümü (konuşma payları, sözlük); açık/kapalı tercihi tüm
/// toplantılar için hatırlanır.
struct MeetingDetailsDisclosure<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @AppStorage(PhoneSettingsKey.meetingDetailsExpanded) private var isExpanded: Bool = false

    var body: some View {
        // Sistemin açılır bölümü: VoiceOver "genişletildi/daraltıldı" diye okur.
        DisclosureGroup(isExpanded: Binding<Bool>(
            get: { isExpanded },
            set: { (value: Bool) -> Void in withAnimation(.smooth(duration: 0.3)) { isExpanded = value } }
        )) {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(.top, 12)
        } label: {
            Text("Ayrıntılar")
                .appFont(size: 15, weight: .semibold)
                .foregroundStyle(Theme.ink)
        }
        .tint(Theme.muted)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}
