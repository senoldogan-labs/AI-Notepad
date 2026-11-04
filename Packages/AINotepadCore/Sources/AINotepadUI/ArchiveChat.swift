import AINotepadCore
import os
import SwiftUI

/// Arşiv sohbeti (Mac'te Sor sayfası, iPhone'da Sor sekmesi): soru, ajanın adımı, akan cevap (kaynak işaretleriyle),
/// kaynaklar ve nasıl cevaplandığı.

/// Arşive sorulan bir soru ve durumu.
public struct ArchiveExchange: Identifiable, Equatable, Sendable {
    /// Ajanın adımı: soruyu anlama (arama terimleri) → arşivde arama → cevabı yazma → bitti.
    public enum Phase: Equatable, Sendable {
        case understanding
        case searching
        case writing
        case done
        case stopped
        case failed(String)
    }

    public let id: UUID
    public let question: String
    /// `@` ile seçilen toplantılar (soru yalnız onlara soruldu); boşsa tüm arşiv.
    public let scopeMeetingIDs: [String]
    /// `@` ile seçilen toplantıların başlıkları.
    public let scopeTitles: [String]
    /// Soru bir tariften geldiyse tarifin adı (balonda uzun istem yerine o görünür).
    public let recipeTitle: String?
    public let startedAt: Date
    public var phase: Phase
    /// Hızlı modelin çıkardığı arama terimleri.
    public var terms: [String]
    /// Okunan parçalar.
    public var passages: [ArchivePassage]
    /// Cevapla gönderilen ekran görüntüsü sayısı (Mac, "Notlarda ekran görüntülerini kullan" açıkken; iPhone'da hep 0).
    public var screens: Int
    /// Akan (ya da bitmiş) cevap.
    public var answer: ArchiveAnswer
    /// Modelin yaptığı web aramalarının sorguları (web araması kapalıysa ya da aranmadıysa boş).
    public var webQueries: [String]
    /// Bu ayın web araması hakkı bittiği için arama sunulmadı (cevap yalnız toplantılardan).
    public var webSearchCapReached: Bool
    public var finishedAt: Date?

    public init(
        id: UUID, question: String, scopeMeetingIDs: [String], scopeTitles: [String], recipeTitle: String?, startedAt: Date, phase: Phase, terms: [String], passages: [ArchivePassage],
        screens: Int, answer: ArchiveAnswer, webQueries: [String], webSearchCapReached: Bool, finishedAt: Date?
    ) {
        self.id = id
        self.question = question
        self.scopeMeetingIDs = scopeMeetingIDs
        self.scopeTitles = scopeTitles
        self.recipeTitle = recipeTitle
        self.startedAt = startedAt
        self.phase = phase
        self.terms = terms
        self.passages = passages
        self.screens = screens
        self.answer = answer
        self.webQueries = webQueries
        self.webSearchCapReached = webSearchCapReached
        self.finishedAt = finishedAt
    }
}

/// Bitmiş soruyu sohbet geçmişine yazılacak tura çevirir (okunan parçalar metinsiz); bitmemiş, durdurulan ya da hatalı
/// soru nil. Saf fonksiyondur.
public func askTurn(exchange: ArchiveExchange) -> AskConversationTurn? {
    guard exchange.phase == .done, let finishedAt = exchange.finishedAt else {
        return nil
    }
    let read: [ArchivePassage] = exchange.passages.map { (passage: ArchivePassage) -> ArchivePassage in
        ArchivePassage(
            id: passage.id, meetingID: passage.meetingID, meetingTitle: passage.meetingTitle, meetingDate: passage.meetingDate,
            kind: passage.kind, startSec: passage.startSec, text: ""
        )
    }
    return AskConversationTurn(
        id: exchange.id, question: exchange.question, scopeMeetingIDs: exchange.scopeMeetingIDs, scopeTitles: exchange.scopeTitles,
        recipeTitle: exchange.recipeTitle, startedAt: exchange.startedAt, finishedAt: finishedAt, terms: exchange.terms, readPassages: read,
        readScreens: exchange.screens, answer: exchange.answer.text, sources: exchange.answer.sources, webSources: exchange.answer.webSources,
        webQueries: exchange.webQueries
    )
}

/// Saklanan turu sohbette gösterilecek bitmiş soruya çevirir. Saf fonksiyondur.
public func archiveExchange(turn: AskConversationTurn) -> ArchiveExchange {
    ArchiveExchange(
        id: turn.id, question: turn.question, scopeMeetingIDs: turn.scopeMeetingIDs, scopeTitles: turn.scopeTitles, recipeTitle: turn.recipeTitle,
        startedAt: turn.startedAt, phase: .done, terms: turn.terms, passages: turn.readPassages,
        screens: turn.readScreens ?? 0, answer: ArchiveAnswer(text: turn.answer, sources: turn.sources, webSources: turn.webSources ?? []),
        webQueries: turn.webQueries ?? [], webSearchCapReached: false, finishedAt: turn.finishedAt
    )
}

/// Bitmiş, durdurulmuş ya da hatalı son sorunun yeniden sorulacak hali: soru, `@` kapsamı ve tarif adı; çalışan ya da
/// sohbette olmayan soru nil. Saf fonksiyondur.
public func regeneratableExchange(exchanges: [ArchiveExchange]) -> ArchiveExchange? {
    guard let last = exchanges.last, ![.understanding, .searching, .writing].contains(last.phase) else {
        return nil
    }
    return last
}

/// Sorunun ilerleyişini soruya işler (Mac ve iPhone aynı kuralla): terimler aramaya, ekran sayısı yazmaya geçirir; web
/// aramaları ve arama hakkının bitişi yazılır. Saf fonksiyondur.
public func applying(progress: ArchiveProgress, to exchange: ArchiveExchange) -> ArchiveExchange {
    var updated: ArchiveExchange = exchange
    switch progress {
    case .searchTerms(let terms):
        updated.terms = terms
        updated.phase = .searching
    case .passages(let passages):
        updated.passages = passages
    case .screens(let count):
        updated.screens = count
        updated.phase = .writing
    case .answer(let answer):
        updated.answer = answer
    case .web(let queries, let capReached):
        updated.webQueries = queries
        updated.webSearchCapReached = capReached
    }
    return updated
}

/// Devam soruları için bağlam: bitmiş soruların soru, cevap ve kaynakları. Saf fonksiyondur.
public func archiveHistory(exchanges: [ArchiveExchange]) -> [ArchiveTurn] {
    exchanges.compactMap { (exchange: ArchiveExchange) -> ArchiveTurn? in
        exchange.phase == .done ? ArchiveTurn(question: exchange.question, answer: exchange.answer.text, sources: exchange.answer.sources) : nil
    }
}

/// Boş soru alanında ↑ ile düzenlemeye geri getirilen soru: sohbette kullanıcının yazdığı son soru (tariften gelenler
/// uzun istem olduğu için atlanır); yoksa nil. Saf fonksiyondur.
public func lastAskedQuestion(exchanges: [ArchiveExchange]) -> String? {
    exchanges.last { $0.recipeTitle == nil }?.question
}

/// Ajan çalışırken giriş alanının çerçevesinde dönen ince, tek renk ışık.
public struct ThinkingRing: View {
    let shape: RoundedRectangle

    public init(shape: RoundedRectangle) {
        self.shape = shape
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { (context: TimelineViewDefaultContext) in
            let angle: Double = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360
            shape.strokeBorder(
                AngularGradient(
                    colors: [Theme.line, Theme.ink.opacity(0.55), Theme.line, Theme.line],
                    center: .center, angle: .degrees(angle)
                ),
                lineWidth: 1.2
            )
        }
        .allowsHitTesting(false)
    }
}

/// Bir soru ve cevabı: soru sağda, altında ajanın adımları, akan Markdown cevap (kaynak rozetleriyle) ve altında
/// kopyala, Markdown, yeniden oluştur, kaynaklar ve nasıl cevaplandığı.
public struct ExchangeView: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void
    /// Soruyu tarif olarak kaydeder (tariften gelen soruda gösterilmez).
    let onSaveRecipe: @MainActor (String) -> Void
    /// Soruyu yeniden sorar (yalnız sohbetin son sorusunda; diğerlerinde nil).
    let onRegenerate: (@MainActor () -> Void)?

    public init(
        exchange: ArchiveExchange, onOpen: @escaping @MainActor (ArchivePassage) -> Void, onSaveRecipe: @escaping @MainActor (String) -> Void,
        onRegenerate: (@MainActor () -> Void)?
    ) {
        self.exchange = exchange
        self.onOpen = onOpen
        self.onSaveRecipe = onSaveRecipe
        self.onRegenerate = onRegenerate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !exchange.scopeTitles.isEmpty {
                HStack {
                    Spacer(minLength: 80)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(exchange.scopeTitles, id: \.self) { (title: String) in
                            MentionChip(title: title)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer(minLength: 80)
                Group {
                    if let recipe = exchange.recipeTitle {
                        Label(recipe, systemImage: "wand.and.stars")
                    } else {
                        Text(exchange.question)
                    }
                }
                    .appFont(size: 15, weight: .regular)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            // Çalışırken tek satır "Düşünüyor…" (parıltılı); cevap akmaya başlayınca kalkar.
            if exchange.answer.text.isEmpty, [.understanding, .searching, .writing].contains(exchange.phase) {
                ThinkingLine(exchange: exchange)
                    .transition(.opacity)
            }
            if !exchange.answer.text.isEmpty {
                StreamingAnswer(exchange: exchange) { (number: Int) -> Void in
                    if exchange.answer.sources.indices.contains(number - 1) {
                        onOpen(exchange.answer.sources[number - 1])
                    }
                }
                #if os(iOS)
                // Uzun basış: cevabı kopyala, Markdown olarak kopyala ya da .md olarak paylaş.
                .contextMenu {
                    AnswerExportMenuItems(exchange: exchange)
                }
                #endif
            }
            if exchange.webSearchCapReached {
                Label("Bu ayın web araması hakkı doldu; cevap yalnız toplantılardan.", systemImage: "globe")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            switch exchange.phase {
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    NoticeText(message, severity: .error)
                        .appFont(size: 13, weight: .regular)
                        .textSelection(.enabled)
                    if let onRegenerate {
                        Button("Tekrar dene", systemImage: "arrow.clockwise", action: onRegenerate)
                            .appFont(size: 12, weight: .medium)
                            .buttonStyle(.hoverPlain)
                    }
                }
            case .stopped:
                Label("Durduruldu", systemImage: "stop.circle")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
            case .understanding, .searching, .writing, .done:
                EmptyView()
            }
            if ![.understanding, .searching, .writing].contains(exchange.phase) {
                // Bitince tek sessiz satır: kopyala, kaynaklar ve nasıl cevaplandığı; ayrıntı altta açılır.
                AnswerFooter(exchange: exchange, onOpen: onOpen, onSaveRecipe: onSaveRecipe, onRegenerate: onRegenerate)
                    .transition(.opacity)
            }
        }
    }
}

/// Çalışırken tek satır: parıltılı durum ("Düşünüyor…", "Arşiv taranıyor…", "8 toplantı okunuyor…").
private struct ThinkingLine: View {
    let exchange: ArchiveExchange
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            ShimmerText(text: status)
                .appFont(size: 14, weight: .medium)
        }
        .animation(.easeOut(duration: 0.2), value: exchange.phase)
    }

    private var status: Text {
        switch exchange.phase {
        case .searching:
            Text("Arşiv taranıyor…")
        case .writing:
            if let query = exchange.webQueries.last(where: { !$0.isEmpty }) {
                Text("Web'de aranıyor: “\(query)”…")
            } else if !exchange.webQueries.isEmpty {
                Text("Web'de aranıyor…")
            } else {
                Text("\(Set(exchange.passages.map(\.meetingID)).count) toplantı okunuyor…")
            }
        case .understanding, .done, .stopped, .failed:
            Text("Düşünüyor…")
        }
    }
}

/// Metnin üstünden soldan sağa yavaşça geçen ışık (düşünme göstergesi); "Hareketi azalt" açıksa durgun ve soluk.
private struct ShimmerText: View {
    let text: Text
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            text.foregroundStyle(Theme.muted)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { (context: TimelineViewDefaultContext) in
                let phase: Double = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                text
                    .foregroundStyle(Theme.muted.opacity(0.75))
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, phase * 1.6 - 0.5)),
                                .init(color: Theme.ink, location: max(0, phase * 1.6 - 0.3)),
                                .init(color: .clear, location: max(0, phase * 1.6 - 0.1)),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .mask(text)
                        .allowsHitTesting(false)
                    }
            }
        }
    }
}

/// Cevabın altındaki satırda açılabilen ayrıntı.
private enum AnswerDetail: Equatable {
    case sources
    case web
    case reasoning
}

/// Bitmiş cevabın altı: kopyala ve diğer çıkış seçenekleri (Markdown olarak kopyala, .md kaydet/paylaş), yeniden
/// oluştur, tarif olarak kaydet, "Kaynaklar", "Web" ve "8 toplantıdan 42 parça okundu · 6,0 sn" hapları. Bir hapa
/// tıklanınca ayrıntısı altta ince bir kartta açılır (aynı anda biri).
private struct AnswerFooter: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void
    let onSaveRecipe: @MainActor (String) -> Void
    let onRegenerate: (@MainActor () -> Void)?
    @State private var detail: AnswerDetail?
    @State private var isSaved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                if exchange.phase == .done || !exchange.answer.text.isEmpty {
                    CopyAnswerButton(answer: exchange.answer)
                    AnswerExportMenu(exchange: exchange)
                }
                if let onRegenerate, !isFailed {
                    FooterIconButton(symbol: "arrow.clockwise", hint: "Yeniden oluştur", action: onRegenerate)
                }
                if exchange.phase == .done, exchange.recipeTitle == nil {
                    Button {
                        onSaveRecipe(exchange.question)
                        isSaved = true
                    } label: {
                        Image(systemName: isSaved ? "wand.and.stars" : "wand.and.stars.inverse")
                            .appFont(size: 12, weight: .medium)
                            .foregroundStyle(isSaved ? Theme.ink : Theme.muted)
                            .frame(width: 28, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverPlain)
                    .disabled(isSaved)
                    .hoverHint(isSaved ? "Tarif olarak kaydedildi: \"/\" ile çalıştır" : "Tarif olarak kaydet (\"/\" ile yeniden sor)", alignment: .leading, edge: .bottom)
                    .accessibilityLabel(isSaved ? "Tarif olarak kaydedildi" : "Tarif olarak kaydet")
                }
                if !exchange.answer.sources.isEmpty {
                    FooterPill(symbol: "text.quote", isOpen: detail == .sources) {
                        HStack(spacing: 5) {
                            Text("Kaynaklar")
                            Text(verbatim: "\(exchange.answer.sources.count)").fontWeight(.semibold)
                        }
                    } onToggle: {
                        toggle(detail: .sources)
                    }
                }
                if !exchange.answer.webSources.isEmpty {
                    FooterPill(symbol: "globe", isOpen: detail == .web) {
                        HStack(spacing: 5) {
                            Text("Web")
                            Text(verbatim: "\(exchange.answer.webSources.count)").fontWeight(.semibold)
                        }
                    } onToggle: {
                        toggle(detail: .web)
                    }
                }
                FooterPill(symbol: "magnifyingglass", isOpen: detail == .reasoning) {
                    Text(reasoningSummary(exchange: exchange))
                } onToggle: {
                    toggle(detail: .reasoning)
                }
            }
            switch detail {
            case .sources:
                SourcesList(sources: exchange.answer.sources, onOpen: onOpen)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .web:
                WebSourcesList(sources: exchange.answer.webSources)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case .reasoning:
                ReasoningDetails(exchange: exchange)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            case nil:
                EmptyView()
            }
        }
    }

    /// Hatalı soruda yeniden deneme hata satırındadır ("Tekrar dene").
    private var isFailed: Bool {
        if case .failed = exchange.phase {
            return true
        }
        return false
    }

    private func toggle(detail selected: AnswerDetail) {
        withAnimation(.smooth(duration: 0.22)) {
            detail = detail == selected ? nil : selected
        }
    }
}

/// Cevap altındaki yalnız simgeli küçük düğme.
private struct FooterIconButton: View {
    let symbol: String
    let hint: LocalizedStringKey
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.muted)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .hoverHint(hint, alignment: .leading, edge: .bottom)
        .accessibilityLabel(Text(hint))
    }
}

/// Cevabın çıkış menüsü (⋯): Markdown olarak kopyala ve Mac'te ".md olarak kaydet…" (kaydetme paneli), iPhone'da
/// ".md olarak paylaş".
private struct AnswerExportMenu: View {
    let exchange: ArchiveExchange
    #if os(macOS)
    @State private var isExporting: Bool = false
    /// Dosya yazılamadıysa nedeni (menünün yanında gösterilir).
    @State private var exportError: String?
    #endif

    var body: some View {
        HStack(spacing: 6) {
            menu
            #if os(macOS)
            if let exportError {
                NoticeText(exportError, severity: .error)
                    .appFont(size: 12, weight: .regular)
            }
            #endif
        }
    }

    private var menu: some View {
        Menu {
            AnswerExportMenuItems(exchange: exchange)
            #if os(macOS)
            Button(".md olarak kaydet…", systemImage: "square.and.arrow.down") { isExporting = true }
            #endif
        } label: {
            Image(systemName: "ellipsis")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.muted)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverPlain)
        .fixedSize()
        .accessibilityLabel("Diğer seçenekler")
        #if os(macOS)
        .fileExporter(
            isPresented: $isExporting, document: MarkdownFileDocument(text: answerMarkdown(exchange: exchange)), contentType: markdownContentType,
            defaultFilename: answerFileName(exchange: exchange)
        ) { (result: Result<URL, any Error>) -> Void in
            switch result {
            case .success:
                exportError = nil
            case .failure(let error as CocoaError) where error.code == .userCancelled:
                exportError = nil
            case .failure(let error):
                exportLogger.error("Sor cevabı .md olarak kaydedilemedi, hata: \(String(describing: error), privacy: .private)")
                exportError = userFacingMessage(error: error)
            }
        }
        #endif
    }
}

private let exportLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AskExport")

/// Cevabın Markdown dosyası (başlık sorunun ya da tarifin adı).
@MainActor
func answerMarkdown(exchange: ArchiveExchange) -> String {
    archiveAnswerMarkdown(title: exchange.recipeTitle ?? exchange.question, answer: exchange.answer, noteLabel: String(localized: "not"), locale: interfaceLocale())
}

/// Cevabın Markdown dosyasının adı.
@MainActor
func answerFileName(exchange: ArchiveExchange) -> String {
    askMarkdownFileName(title: exchange.recipeTitle ?? exchange.question, fallback: String(localized: "Sor cevabı"))
}

/// Cevabın kopyalama ve paylaşma seçenekleri (⋯ menüsü ve iPhone'da uzun basış menüsü).
struct AnswerExportMenuItems: View {
    let exchange: ArchiveExchange

    var body: some View {
        Button("Cevabı kopyala", systemImage: "doc.on.doc") {
            copyToPasteboard(text: archiveAnswerPlainText(
                answer: exchange.answer, sourcesHeading: String(localized: "Kaynaklar"), webHeading: String(localized: "Web kaynakları"),
                noteLabel: String(localized: "not"), locale: interfaceLocale()
            ))
        }
        Button("Markdown olarak kopyala", systemImage: "number") {
            copyToPasteboard(text: answerMarkdown(exchange: exchange))
        }
        #if os(iOS)
        ShareLink(
            item: MarkdownShareFile(fileName: answerFileName(exchange: exchange), text: answerMarkdown(exchange: exchange)),
            preview: SharePreview(answerFileName(exchange: exchange))
        ) {
            Label(".md olarak paylaş", systemImage: "square.and.arrow.up")
        }
        #endif
    }
}

/// "8 toplantıdan 42 parça okundu · 6,0 sn"; ekran görüntüsü de gittiyse "1 toplantıdan 6 parça ve 2 ekran görüntüsü
/// okundu · 6,0 sn". Toplantılar kimliğe göre sayılır (aynı adlı yinelenen toplantılar ayrı; yazılırken gösterilen
/// sayıyla aynı).
func reasoningSummary(exchange: ArchiveExchange) -> String {
    let meetings: Int = Set(exchange.passages.map(\.meetingID)).count
    let seconds: Double = (exchange.finishedAt ?? Date()).timeIntervalSince(exchange.startedAt)
    let duration: String = seconds.formatted(.number.precision(.fractionLength(1)).locale(interfaceLocale()))
    guard exchange.screens > 0 else {
        return String(localized: "\(meetings) toplantıdan \(exchange.passages.count) parça okundu · \(duration) sn")
    }
    return String(localized: "\(meetings) toplantıdan \(exchange.passages.count) parça ve \(exchange.screens) ekran görüntüsü okundu · \(duration) sn")
}

/// Cevap altındaki küçük, soluk hap: simge, metin ve dönen ok; açıkken hafif dolgulu.
private struct FooterPill<Label: View>: View {
    let symbol: String
    let isOpen: Bool
    @ViewBuilder let label: () -> Label
    let onToggle: @MainActor () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .appFont(size: 10, weight: .semibold)
                label()
                Image(systemName: "chevron.down")
                    .appFont(size: 8, weight: .bold)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(isOpen ? Theme.ink : Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOpen ? Theme.selected : Theme.soft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverPlain)
    }
}

/// Nasıl cevaplandı: arama terimleri ve okunan toplantılar (adı ve günü; aynı adlı toplantılar ayrılsın), ince kartta
/// küçük yazıyla. Cevabı yazan model gösterilmez.
private struct ReasoningDetails: View {
    let exchange: ArchiveExchange

    var body: some View {
        let meetings: [ArchivePassage] = exchange.passages.reduce(into: [ArchivePassage]()) { (result: inout [ArchivePassage], passage: ArchivePassage) -> Void in
            if !result.contains(where: { $0.meetingID == passage.meetingID }) {
                result.append(passage)
            }
        }
        let titles: [String] = meetings.map { (passage: ArchivePassage) -> String in
            "\(passage.meetingTitle) (\(passage.meetingDate.formatted(Date.FormatStyle().day().month(.abbreviated).locale(interfaceLocale()))))"
        }
        VStack(alignment: .leading, spacing: 6) {
            if !exchange.terms.isEmpty {
                row(label: "Aranan", value: exchange.terms.joined(separator: ", "))
            }
            if !titles.isEmpty {
                row(label: "Okunan", value: titles.joined(separator: " · "))
            }
            if !exchange.webQueries.filter({ !$0.isEmpty }).isEmpty {
                row(label: "Web'de", value: exchange.webQueries.filter { !$0.isEmpty }.map { "“\($0)”" }.joined(separator: ", "))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .appFont(size: 11, weight: .medium)
                .foregroundStyle(Theme.muted)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Akan cevap: gelen metin harf harf yumuşakça açılır (parça büyükse daha hızlı yetişir), yazarken sonda imleç. Metin
/// Markdown olarak çizilir (`AnswerMarkdownView`): başlıklar, listeler, tablolar, kod blokları; toplantı kaynakları
/// dokunulabilir rozetlerdir (kaynak açılır), web kaynakları tarayıcıda açılır.
private struct StreamingAnswer: View {
    let exchange: ArchiveExchange
    let onCitation: @MainActor (Int) -> Void
    @State private var shown: Int = 0

    private var isWriting: Bool {
        exchange.phase == .writing
    }

    var body: some View {
        let full: String = exchange.answer.text
        let visible: String = String(full.prefix(shown))
        let isRevealing: Bool = isWriting || shown < full.count
        AnswerMarkdownView(blocks: parseMarkdown(text: isRevealing ? visible + streamingCaret : visible), webSources: exchange.answer.webSources)
            .environment(\.openURL, OpenURLAction { (url: URL) -> OpenURLAction.Result in
                guard url.scheme == citationScheme, let number = Int(url.host() ?? "") else {
                    return .systemAction
                }
                onCitation(number)
                return .handled
            })
            .task(id: full) {
                // Bitmiş (ya da yeniden çizilen) cevap beklemeden görünür; akan cevap yakalanana dek açılır.
                if !isWriting, shown == 0 {
                    shown = full.count
                    return
                }
                while shown < full.count, !Task.isCancelled {
                    shown = min(full.count, shown + max(1, (full.count - shown) / 10))
                    do {
                        try await Task.sleep(for: .milliseconds(18))
                    } catch {
                        return
                    }
                }
            }
    }
}

/// Cevap akarken sondaki imleç.
private let streamingCaret: String = " ▍"

/// Web kaynakları: alan adı ve sayfa başlığı; tıklayınca tarayıcıda açılır.
private struct WebSourcesList: View {
    let sources: [WebSource]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sources.enumerated()), id: \.element.url) { (item: (offset: Int, element: WebSource)) in
                Button {
                    if let url = URL(string: item.element.url) {
                        openURL(url)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "globe")
                            .appFont(size: 10, weight: .semibold)
                            .foregroundStyle(Theme.muted)
                            .frame(width: 14, alignment: .trailing)
                        Text(verbatim: webSourceDomain(url: item.element.url))
                            .appFont(size: 12, weight: .medium)
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .lineLimit(1)
                            .fixedSize()
                        Text(verbatim: item.element.title)
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .appFont(size: 9, weight: .semibold)
                            .foregroundStyle(Theme.muted.opacity(0.8))
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("Tarayıcıda aç", alignment: .leading, edge: .bottom)
                .accessibilityLabel(Text(verbatim: "\(webSourceDomain(url: item.element.url)), \(item.element.title)"))
            }
        }
        .padding(6)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Kaynaklar: numaralı ince satırlar (numara metindeki [n]; toplantı, tarih, not ya da zaman), ince kartta. Tıklayınca
/// toplantı açılır.
private struct SourcesList: View {
    let sources: [ArchivePassage]
    let onOpen: @MainActor (ArchivePassage) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { (item: (offset: Int, element: ArchivePassage)) in
                Button {
                    onOpen(item.element)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "\(item.offset + 1)")
                            .appFont(size: 10, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(appearance.accent.color)
                            .frame(width: 14, alignment: .trailing)
                        Text(item.element.meetingTitle)
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(sourceDetail(source: item.element))
                            .appFont(size: 11, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "arrow.up.right")
                            .appFont(size: 9, weight: .semibold)
                            .foregroundStyle(Theme.muted.opacity(0.8))
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("Toplantıyı aç", alignment: .leading, edge: .bottom)
            }
        }
        .padding(6)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "26 Eki · not" ya da "26 Eki · 04:12".
    private func sourceDetail(source: ArchivePassage) -> String {
        let date: String = source.meetingDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
        let place: String = source.kind == .note ? String(localized: "not") : timestamp(seconds: source.startSec)
        return "\(date) · \(place)"
    }
}

/// Cevabı düz metin olarak, altında kaynak başlıklarıyla kopyalar; yalnız simge (sohbet uygulamalarındaki gibi), kısa
/// süre onay işareti gösterir.
private struct CopyAnswerButton: View {
    let answer: ArchiveAnswer
    @State private var copied: Bool = false

    var body: some View {
        Button {
            copyToPasteboard(text: archiveAnswerPlainText(
                answer: answer, sourcesHeading: String(localized: "Kaynaklar"), webHeading: String(localized: "Web kaynakları"), noteLabel: String(localized: "not"),
                locale: interfaceLocale()
            ))
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(copied ? Theme.ink : Theme.muted)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.hoverPlain)
        .hoverHint(copied ? "Kopyalandı" : "Cevabı kopyala", alignment: .leading, edge: .bottom)
        .accessibilityLabel(copied ? "Kopyalandı" : "Cevabı kopyala")
        .task(id: copied) {
            guard copied else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            copied = false
        }
    }
}


/// `@` ile etiketlenen toplantının çipi: vurgu renginde soluk kapsül, "@" ve başlık.
public struct MentionChip: View {
    let title: String
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 3) {
            Text(verbatim: "@").appFont(size: 12, weight: .bold)
            Text(title).appFont(size: 12, weight: .medium).lineLimit(1)
        }
        .foregroundStyle(appearance.accent.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(appearance.accent.color.opacity(0.12), in: Capsule())
    }
}

/// Soru alanındaki seçili toplantı çipi: dokununca (x) kaldırılır.
public struct RemovableMentionChip: View {
    let title: String
    let onRemove: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(title: String, onRemove: @escaping @MainActor () -> Void) {
        self.title = title
        self.onRemove = onRemove
    }

    public var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Text(verbatim: "@").appFont(size: 12, weight: .bold)
                Text(title).appFont(size: 12, weight: .medium).lineLimit(1)
                Image(systemName: "xmark").appFont(size: 8, weight: .bold).opacity(0.7)
            }
            .foregroundStyle(appearance.accent.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(appearance.accent.color.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title) etiketini kaldır"))
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// `@` önerileri: toplantı kapağının küçük dairesi, başlık ve tarih; seçili satır (klavyeyle gezilir) soluk dolgulu.
/// Dokununca ya da Return ile toplantı etikete eklenir.
public struct MentionSuggestions: View {
    let candidates: [MeetingRecord]
    let highlighted: Int
    let onPick: @MainActor (MeetingRecord) -> Void

    public init(candidates: [MeetingRecord], highlighted: Int, onPick: @escaping @MainActor (MeetingRecord) -> Void) {
        self.candidates = candidates
        self.highlighted = highlighted
        self.onPick = onPick
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Toplantı etiketle — soru yalnız ona sorulur")
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            if candidates.isEmpty {
                Text("Eşleşen toplantı yok")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .padding(10)
            }
            ForEach(Array(candidates.enumerated()), id: \.element.id) { (item: (offset: Int, element: MeetingRecord)) in
                let title: String = item.element.note?.title ?? item.element.title
                let date: String = item.element.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
                Button {
                    onPick(item.element)
                } label: {
                    HStack(spacing: 10) {
                        CoverBackground(seed: item.element.id)
                            .frame(width: 22, height: 22)
                            .clipShape(Circle())
                        Text(title)
                            .appFont(size: 14, weight: .regular)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(date)
                            .appFont(size: 12, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(item.offset == highlighted ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // VoiceOver satırı tek öğe okur: başlık ve tarih; klavyeyle seçili satır "seçili" duyurulur.
                .accessibilityLabel(Text(verbatim: "\(title), \(date)"))
                .accessibilityHint("Soru yalnız bu toplantıya sorulur")
                .accessibilityAddTraits(item.offset == highlighted ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Toplantı önerileri")
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
    }
}

/// Çapraz (45°) ince çizgiler: kart dokusu.
public struct DiagonalLines: Shape {
    let spacing: CGFloat

    public init(spacing: CGFloat) {
        self.spacing = spacing
    }

    public func path(in rect: CGRect) -> Path {
        var path: Path = Path()
        var x: CGFloat = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}


/// "/" ile tarif önerileri: simge, başlık ve (kullanıcınınkilerde) sil; seçili satır soluk dolgulu.
public struct RecipeSuggestions: View {
    let recipes: [Recipe]
    let highlighted: Int
    let onPick: @MainActor (Recipe) -> Void
    let onDelete: @MainActor (Recipe) -> Void

    public init(recipes: [Recipe], highlighted: Int, onPick: @escaping @MainActor (Recipe) -> Void, onDelete: @escaping @MainActor (Recipe) -> Void) {
        self.recipes = recipes
        self.highlighted = highlighted
        self.onPick = onPick
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tarifler — @ ile toplantı seçersen yalnız ona uygulanır")
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            if recipes.isEmpty {
                Text("Eşleşen tarif yok").appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted).padding(10)
            }
            ForEach(Array(recipes.enumerated()), id: \.element.id) { (item: (offset: Int, element: Recipe)) in
                Button {
                    onPick(item.element)
                } label: {
                    HStack(spacing: 10) {
                        // Her tarif kendi sabit gradyan ailesinde (ElevenLabs simge kutuları gibi), koyu simgeyle.
                        Image(systemName: item.element.symbol)
                            .appFont(size: 12, weight: .semibold)
                            .foregroundStyle(Color.black.opacity(0.78))
                            .frame(width: 28, height: 28)
                            .background { FilmGradient(seed: "tarif-\(item.element.id)", palette: filmPalette(seed: item.element.id)) }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(verbatim: "/" + item.element.title)
                            .appFont(size: 14, weight: .regular)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !item.element.isBuiltIn {
                            Text("Senin").appFont(size: 11, weight: .medium).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(item.offset == highlighted ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !item.element.isBuiltIn {
                        Button("Tarifi sil", systemImage: "trash", role: .destructive) { onDelete(item.element) }
                    }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
    }
}


/// Kaydırma alt kenara yakın mı (en çok 120 pt yukarıda): sohbet sonu görünüyor, akan cevap izlenebilir. Saf
/// fonksiyondur.
public func isNearScrollBottom(geometry: ScrollGeometry) -> Bool {
    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
}

/// Yukarı kaydırılmış sohbette sona dönüş düğmesi: küçük, gölgeli, aşağı oklu daire.
public struct JumpToLatestButton: View {
    let action: @MainActor () -> Void

    public init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sona git")
    }
}
