import AINotepadCore
import SwiftUI

/// Toplantı sayfasının sakin not görünümü (Mac ve iPhone): başlığın altında tek satır bilgi çipleri, sonra not başlıklar
/// ve maddeler halinde. Her maddenin kaynağı (transkriptte geçtiği yerler) Mac'te üstüne gelince sağda beliren
/// büyüteçle, iPhone'da maddeye dokununca ya da basılı tutunca "Transkriptten" kutusunda açılır.

/// Başlığın altındaki bilgi çipi: simge ve kısa metin (şablon, tarih, katılımcı sayısı, klasör…).
public struct MeetingInfoChip: Identifiable, Equatable {
    public let id: String
    public let symbol: String
    public let text: String

    public init(id: String, symbol: String, text: String) {
        self.id = id
        self.symbol = symbol
        self.text = text
    }
}

/// Toplantının bilgi çipleri, bu sırayla ve olanlar: notun şablonu, tarih ve saat, süre, konuşmacı sayısı (kısa
/// konuşanlar hariç, `speakers`), klasör ve konuşulan dil. Saf fonksiyondur.
public func meetingInfoChips(record: MeetingRecord, speakers: Int, locale: Locale) -> [MeetingInfoChip] {
    let template: [MeetingInfoChip] = record.template.map { [MeetingInfoChip(id: "template", symbol: "doc.text", text: $0.kind.displayName)] } ?? []
    let date: MeetingInfoChip = MeetingInfoChip(
        id: "date", symbol: "calendar", text: record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    )
    let duration: [MeetingInfoChip] = meetingDurationMinutes(record: record).map { [MeetingInfoChip(id: "duration", symbol: "clock", text: String(localized: "\($0) dk"))] } ?? []
    let people: [MeetingInfoChip] = speakers > 0 ? [MeetingInfoChip(id: "speakers", symbol: "person.2", text: String(localized: "\(speakers) konuşmacı"))] : []
    let folder: [MeetingInfoChip] = record.folder.map { [MeetingInfoChip(id: "folder", symbol: "folder", text: $0)] } ?? []
    let language: [MeetingInfoChip] = record.language.map { [MeetingInfoChip(id: "language", symbol: "globe", text: meetingLanguageName(language: $0))] } ?? []
    return template + [date] + duration + people + folder + language
}

/// Bilgi çiplerinin satırı: soluk yüzeyde küçük kapsüller; dar ekranda alt satıra sarılır.
public struct MeetingInfoChips: View {
    let chips: [MeetingInfoChip]

    public init(chips: [MeetingInfoChip]) {
        self.chips = chips
    }

    public var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(chips) { (chip: MeetingInfoChip) in
                Label {
                    Text(verbatim: chip.text).lineLimit(1)
                } icon: {
                    Image(systemName: chip.symbol).imageScale(.small)
                }
                .labelStyle(ChipLabelStyle())
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.soft, in: Capsule())
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Çip etiketi: simge ve metin dar aralıkla.
private struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

/// Notun bölüm başlığı (Özet, Kararlar, Görevler…): sakin, yarı kalın.
public struct NoteDocumentHeading: View {
    let title: LocalizedStringKey

    public init(title: LocalizedStringKey) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .appFont(size: 17, weight: .semibold)
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 2)
    }
}

/// Kaynağı gösterilebilen not satırı. `leading` maddenin işareti (nokta, numara, görev kutusu), `content` metni.
/// Mac'te üstüne gelince satır hafifçe dolar ve sağda büyüteç belirir; büyüteç kutuyu satırın hemen altında açar ve
/// kapatır (açılır pencere sayfanın üstündeki çiplerin ve dil düğmesinin üstüne binerdi). iPhone'da satıra dokununca
/// (satırdaki düğmeler kendi dokunuşunu alır) kaynak kutusu açılır. Kaynaklar kutu açılırken bulunur (`noteSources`):
/// her çizimde bütün maddeler için transkript taranmaz.
public struct NoteSourceRow<Leading: View, Content: View>: View {
    /// Maddenin metni ve (karar, açık konu, konu akışında) anı: kaynak bunlarla aranır.
    let text: String
    let anchorSec: Double?
    let paragraphs: [TranscriptParagraph]
    let outline: [OutlineItem]
    let speakerNames: [Int: String]
    let canPlay: Bool
    let onJump: @MainActor (TranscriptParagraph) -> Void
    /// Kutudaki "Sor": maddenin nasıl konuşulduğunu bu toplantıya sorar (Sor kullanılamıyorsa nil).
    let onAsk: (@MainActor () -> Void)?
    let leading: () -> Leading
    let content: () -> Content
    @State private var isHovered: Bool = false
    @State private var shown: NoteSources?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.noteSourceAutoOpenText) private var autoOpenText: String?

    public init(
        text: String, anchorSec: Double?, paragraphs: [TranscriptParagraph], outline: [OutlineItem], speakerNames: [Int: String], canPlay: Bool, onJump: @escaping @MainActor (TranscriptParagraph) -> Void,
        onAsk: (@MainActor () -> Void)?, @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder content: @escaping () -> Content
    ) {
        self.text = text
        self.anchorSec = anchorSec
        self.paragraphs = paragraphs
        self.outline = outline
        self.speakerNames = speakerNames
        self.canPlay = canPlay
        self.onJump = onJump
        self.onAsk = onAsk
        self.leading = leading
        self.content = content
    }

    private var isOpen: Binding<Bool> {
        Binding<Bool>(get: { shown != nil }, set: { (open: Bool) -> Void in shown = open ? noteSources(text: text, anchorSec: anchorSec, paragraphs: paragraphs, outline: outline) : nil })
    }

    public var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 6) {
            row
            if shown != nil {
                popoverContent
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
                    .padding(.leading, 32)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.2), value: shown != nil)
        #else
        row
        #endif
    }

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leading()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            Button {
                isOpen.wrappedValue = shown == nil
            } label: {
                Image(systemName: "magnifyingglass")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(shown != nil ? appearance.accent.color : Theme.muted)
                    .frame(width: 22, height: 22)
                    .background(Theme.card, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.line))
            }
            .buttonStyle(.plain)
            .linkPointer(isEnabled: true)
            .opacity(isHovered || shown != nil ? 1 : 0)
            .accessibilityLabel(shown == nil ? Text("Kaynağı göster") : Text("Kaynağı gizle"))
            .hoverHint("Bu maddenin transkriptte geçtiği yerler", alignment: .trailing, edge: .top)
            #endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered || shown != nil ? Theme.soft : Color.clear)
        }
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { (hovering: Bool) -> Void in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        #else
        // Dokunuş açar; uzun basma satırın kendi menüsüne kalır (görevde "Anımsatıcılara ekle", "Metni kopyala").
        .onTapGesture { isOpen.wrappedValue = true }
        .popover(isPresented: isOpen, arrowEdge: .top) {
            popoverContent.presentationCompactAdaptation(.popover)
        }
        .accessibilityAction(named: Text("Kaynağı göster")) { isOpen.wrappedValue = true }
        #endif
        .task {
            // Görsel kontrol: sayfa bu maddenin kutusunu açık ister (yalnız tanıtım sahnesi verir).
            guard autoOpenText == text else {
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                return
            }
            isOpen.wrappedValue = true
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        if let shown {
            NoteSourcesCard(
                sources: shown, speakerNames: speakerNames, canPlay: canPlay,
                onJump: { (paragraph: TranscriptParagraph) -> Void in
                    self.shown = nil
                    onJump(paragraph)
                },
                onAsk: onAsk.map { (ask: @escaping @MainActor () -> Void) -> @MainActor () -> Void in
                    {
                        self.shown = nil
                        ask()
                    }
                }
            )
        }
    }
}

/// "Transkriptten" kutusu: tek satır bağlam ("Fiyatlandırma konuşulurken geçti · 10:12–10:48") ve en çok üç alıntı
/// (konuşmacı, zaman, söz). Alıntıya tıklayınca transkriptte o ana gidilir (ses varsa oradan çalar).
public struct NoteSourcesCard: View {
    let sources: NoteSources
    let speakerNames: [Int: String]
    let canPlay: Bool
    let onJump: @MainActor (TranscriptParagraph) -> Void
    let onAsk: (@MainActor () -> Void)?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(
        sources: NoteSources, speakerNames: [Int: String], canPlay: Bool, onJump: @escaping @MainActor (TranscriptParagraph) -> Void, onAsk: (@MainActor () -> Void)?
    ) {
        self.sources = sources
        self.speakerNames = speakerNames
        self.canPlay = canPlay
        self.onJump = onJump
        self.onAsk = onAsk
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transkriptten", systemImage: "text.quote")
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(Theme.muted)
            if let context = sources.context {
                contextLine(context: context)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sources.quotes.isEmpty {
                Text("Bu maddenin transkriptte geçtiği yer bulunamadı.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(sources.quotes) { (quote: NoteSourceQuote) in
                quoteRow(quote: quote)
            }
            if let onAsk {
                Divider().overlay(Theme.line)
                Button(action: onAsk) {
                    Label("Nasıl konuşulduğunu sor", systemImage: "sparkle")
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(appearance.accent.color)
                }
                .buttonStyle(.plain)
                .linkPointer(isEnabled: true)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(Theme.card)
    }

    /// Bağlam satırı: konu akışı bölümü varsa adıyla, yoksa yalnız zaman aralığıyla.
    private func contextLine(context: NoteSourceContext) -> Text {
        let range: String = context.endSec - context.startSec >= 1
            ? "\(timestamp(seconds: context.startSec))–\(timestamp(seconds: context.endSec))"
            : timestamp(seconds: context.startSec)
        // Alıntılardan biri aralığın dışındaysa başlık "en çok" der: aralık alıntılarla çelişmesin.
        switch (context.topic, context.isSpread) {
        case (.some(let topic), false):
            return Text("Bu, “\(topic)” konuşulurken geçti · \(range)")
        case (.some(let topic), true):
            return Text("Bu en çok “\(topic)” konuşulurken geçti · \(range)")
        case (.none, false):
            return Text("Bu, toplantının \(range) arasında geçti")
        case (.none, true):
            return Text("Bu en çok toplantının \(range) arasında geçti")
        }
    }

    private func quoteRow(quote: NoteSourceQuote) -> some View {
        let color: Color = quote.paragraph.person.map { personColor(person: $0) } ?? appearance.accent.color
        return Button {
            onJump(quote.paragraph)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.7))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(verbatim: paragraphLabel(paragraph: quote.paragraph, speakerNames: speakerNames))
                            .appFont(size: 12, weight: .semibold)
                            .foregroundStyle(Theme.ink)
                        Text(verbatim: timestamp(seconds: quote.paragraph.startSec))
                            .appFont(size: 11, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                        if canPlay {
                            Image(systemName: "play.fill")
                                .appFont(size: 8, weight: .bold)
                                .foregroundStyle(appearance.accent.color)
                        }
                    }
                    Text(verbatim: "“\(quote.excerpt)”")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.ink.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .accessibilityHint(Text("Transkriptte bu ana git"))
    }
}

/// Düz not maddesinin işareti: küçük yuvarlak nokta.
public struct NoteBulletDot: View {
    public init() {}

    public var body: some View {
        Circle()
            .fill(Theme.ink.opacity(0.55))
            .frame(width: 5, height: 5)
            .offset(y: -3)
            .frame(width: 12)
            .accessibilityHidden(true)
    }
}

public extension EnvironmentValues {
    /// Kaynak kutusu kendiliğinden açılacak maddenin metni (yalnız görsel kontrol sahneleri verir; yoksa nil).
    @Entry var noteSourceAutoOpenText: String? = nil
}
