import AINotepadCore
import SwiftUI

// Sor'un boş başlangıcı (Mac'te sohbet açık değilken Sor sayfası, iPhone'da Sor sekmesinin kökü): sakin başlık, tek
// satırlık örnek soru hapları ve (varsa) kısa son sohbetler listesi. Büyük kart, sayaç ve ayar yok (web araması
// Ayarlar'da).

/// Örnek soru: simge ve Türkçe kaynak metin (uygulamanın String Catalog'unda çevrilir).
public struct AskExampleQuestion: Sendable, Equatable {
    public let symbol: String
    public let text: String

    public init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
    }

    /// Arayüz dilindeki soru (sorulan metin).
    public var localized: String {
        String(localized: String.LocalizationValue(text))
    }
}

/// Mac'te ve iPhone'da aynı örnek sorular.
public let askExampleQuestions: [AskExampleQuestion] = [
    AskExampleQuestion(symbol: "checklist", text: "Bana hangi görevler verildi?"),
    AskExampleQuestion(symbol: "checkmark.seal", text: "Son toplantılarda alınan kararlar neler?"),
    AskExampleQuestion(symbol: "eurosign.circle", text: "Bütçe hakkında neler konuşuldu?"),
    AskExampleQuestion(symbol: "person.2", text: "Bu hafta kimlerle neler konuştum?"),
]

/// Sor'un boş başlangıcının zemini (Mac ve iPhone): üstte durgun pastel film gradyanı, aşağı doğru sayfanın zeminine
/// solar; selamlama onun üstünde durur. Durgundur (bulanık gradyan canlandırılmaz: boşta yüksek işlemci); koyu temada
/// soluk tutulur, açık yazı okunur kalsın. Dokunuşları ve VoiceOver'ı almaz.
public struct AskBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    public init() {}

    public var body: some View {
        FilmGradient(seed: "ask", palette: .violet)
            .opacity(colorScheme == .dark ? 0.34 : 0.62)
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.55), location: 0.5), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Başlık: durgun pastel film gradyanlı kart (Sor'un tanıdık yüzü), simge, "Toplantılarına sor" ve tek kısa satır.
/// Sayaç ve uzun açıklama yok: kart boş ekranı süsler, veri yüklemez.
public struct AskStartHeader: View {
    public init() {}

    public var body: some View {
        // Pastel zeminde koyu mürekkep (her temada okunur).
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .appFont(size: 22, weight: .semibold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Toplantılarına sor")
                    .appTitleFont(size: 28, weight: .semibold)
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)
                Text("Tüm toplantılarında arar")
                    .appFont(size: 15, weight: .regular)
                    .opacity(0.7)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.black.opacity(0.8))
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { FilmGradient(seed: "ask", palette: .violet) }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Örnek sorular: tek satırlık haplar, sığmayan alt satıra geçer; dokununca soru sorulur.
public struct AskExampleChips: View {
    let questions: [AskExampleQuestion]
    let onAsk: @MainActor (AskExampleQuestion) -> Void

    public init(questions: [AskExampleQuestion], onAsk: @escaping @MainActor (AskExampleQuestion) -> Void) {
        self.questions = questions
        self.onAsk = onAsk
    }

    public var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(questions, id: \.text) { (question: AskExampleQuestion) in
                AskExampleChip(question: question) { onAsk(question) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Örnek sorular")
    }
}

/// Örnek soru hapı: vurgu renginde simge, soru; üzerine gelince kenar vurgu rengine döner.
private struct AskExampleChip: View {
    let question: AskExampleQuestion
    let onAsk: @MainActor () -> Void
    @State private var isHovering: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.isEnabled) private var isEnabled: Bool

    var body: some View {
        Button(action: onAsk) {
            HStack(spacing: 7) {
                Image(systemName: question.symbol)
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(question.text))
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(isHovering ? appearance.accent.color.opacity(0.55) : Theme.line))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { (hovering: Bool) -> Void in isHovering = hovering }
        .linkPointer(isEnabled: isEnabled)
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// Son sohbetler listesinin satırı: başlık (tek satır) ve sağda kısa ayrıntı (göreli zaman ya da "Cevaplanıyor…").
public struct AskRecentChat: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    /// Cevap sürüyor: simgenin yerinde bekleme göstergesi.
    public let isAnswering: Bool

    public init(id: String, title: String, detail: String, isAnswering: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isAnswering = isAnswering
    }
}

/// Sohbetin son güncellenme zamanı, arayüz dilinde göreli ("2 sa önce", "dün"); gelecekteki tarih (saat farkı) "şimdi" olur.
public func askRecentChatTime(date: Date, now: Date) -> String {
    let formatter: RelativeDateTimeFormatter = RelativeDateTimeFormatter()
    formatter.locale = interfaceLocale()
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: min(date, now), relativeTo: now)
}

/// Son sohbet satırının alt yazısı: göreli zaman ve sohbetin kapsamı ("2 sa önce · Haftalık toplantı").
@MainActor
public func askRecentChatDetail(conversation: AskConversation, now: Date) -> String {
    [askRecentChatTime(date: conversation.updatedAt, now: now), askConversationScopeTitle(conversation: conversation)].joined(separator: " · ")
}

/// Son sohbetler: küçük başlık ve "Tümünü gör", altında çizgilerle ayrılmış düz satırlar (kart yok).
public struct AskRecentChats: View {
    let chats: [AskRecentChat]
    let onOpen: @MainActor (String) -> Void
    /// "Tümünü gör" (tüm geçmiş); nil ise düğme yok (ör. yalnız henüz saklanmamış sohbet var).
    let onSeeAll: (@MainActor () -> Void)?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(chats: [AskRecentChat], onOpen: @escaping @MainActor (String) -> Void, onSeeAll: (@MainActor () -> Void)?) {
        self.chats = chats
        self.onOpen = onOpen
        self.onSeeAll = onSeeAll
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Son sohbetler")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let onSeeAll {
                    Button("Tümünü gör", action: onSeeAll)
                        .buttonStyle(.plain)
                        .appFont(size: 13, weight: .medium)
                        .foregroundStyle(appearance.accent.color)
                        .linkPointer(isEnabled: true)
                }
            }
            .padding(.bottom, 2)
            ForEach(chats) { (chat: AskRecentChat) in
                Rectangle().fill(Theme.line).frame(height: 1)
                AskRecentChatRow(chat: chat) { onOpen(chat.id) }
            }
        }
    }
}

private struct AskRecentChatRow: View {
    let chat: AskRecentChat
    let onOpen: @MainActor () -> Void
    @State private var isHovering: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Group {
                    if chat.isAnswering {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "bubble.left")
                            .appFont(size: 12, weight: .medium)
                            .foregroundStyle(appearance.accent.color)
                    }
                }
                .frame(width: 18)
                .accessibilityHidden(true)
                Text(verbatim: chat.title)
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(isHovering ? appearance.accent.color : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(verbatim: chat.detail)
                    .appFont(size: 12, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { (hovering: Bool) -> Void in isHovering = hovering }
        .linkPointer(isEnabled: true)
        .accessibilityElement(children: .combine)
    }
}
