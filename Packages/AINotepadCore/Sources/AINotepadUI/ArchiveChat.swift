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
    /// Sorunun kapsamı (kapsam çipinde seçili olan). `@` ile toplantı seçildiyse tüm toplantılar: soruyu etiketler
    /// daraltır (`scopeMeetingIDs`).
    public let scope: AskScope
    /// `@` ile seçilen toplantılar (soru yalnız onlara soruldu); kapsam bu toplantıysa o toplantı (eski sürümler sohbeti
    /// böyle tanır); boşsa kapsamın toplantıları.
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
    /// Web araması yapılamadıysa nedeni (bu ayın hakkı bitti ya da şu an yok; cevap yalnız toplantılardan).
    public var webSearchNotice: WebSearchNotice
    /// Soruyla ilgili olup bağlama sığmadığı için okunmayan toplantılar (tarih sırasıyla; kapsam dipnotunda "Bunlara da
    /// sor"). Okunan toplantılar `passages`tan gelir.
    public var skippedMeetings: [ArchiveMeetingRef]
    public var finishedAt: Date?

    public init(
        id: UUID, question: String, scope: AskScope, scopeMeetingIDs: [String], scopeTitles: [String], recipeTitle: String?, startedAt: Date, phase: Phase, terms: [String],
        passages: [ArchivePassage], screens: Int, answer: ArchiveAnswer, webQueries: [String], webSearchNotice: WebSearchNotice, skippedMeetings: [ArchiveMeetingRef],
        finishedAt: Date?
    ) {
        self.id = id
        self.question = question
        self.scope = scope
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
        self.webSearchNotice = webSearchNotice
        self.skippedMeetings = skippedMeetings
        self.finishedAt = finishedAt
    }
}

/// Henüz başlamış (cevabı boş) soru: `tagged` `@` ile seçilen toplantılar, kapsam bu toplantıysa o toplantı. Saf
/// fonksiyondur.
public func startedExchange(id: UUID, question: String, scope: AskScope, tagged: [MeetingRecord], recipeTitle: String?, startedAt: Date) -> ArchiveExchange {
    ArchiveExchange(
        id: id, question: question, scope: scope, scopeMeetingIDs: tagged.map(\.id), scopeTitles: tagged.map { $0.note?.title ?? $0.title }, recipeTitle: recipeTitle,
        startedAt: startedAt, phase: .understanding, terms: [], passages: [], screens: 0, answer: ArchiveAnswer(text: "", sources: [], webSources: []),
        webQueries: [], webSearchNotice: .ok, skippedMeetings: [], finishedAt: nil
    )
}

/// Sorulmadan başarısız olan soru (etiketli toplantı silinmiş, Sor kullanılamıyor): soru ve neden sohbette görünür.
/// `scope` ve `scopeMeetingIDs` istenen kapsamdır. Saf fonksiyondur.
public func failedExchange(id: UUID, question: String, scope: AskScope, scopeMeetingIDs: [String], recipeTitle: String?, reason: String, at date: Date) -> ArchiveExchange {
    ArchiveExchange(
        id: id, question: question, scope: scope, scopeMeetingIDs: scopeMeetingIDs, scopeTitles: [], recipeTitle: recipeTitle, startedAt: date, phase: .failed(reason),
        terms: [], passages: [], screens: 0, answer: ArchiveAnswer(text: "", sources: [], webSources: []), webQueries: [], webSearchNotice: .ok, skippedMeetings: [],
        finishedAt: date
    )
}

/// Devam sorusunun başlangıç kapsamı (soru alanında kaldırılabilir etiket olarak görünür): sohbetin son sorusu `@` ile
/// toplantılara sorulduysa devam soruları da onlara sorulur; kullanıcı etiketi kaldırınca sonraki soru tüm arşive gider
/// ve kapsam boşalır. Sohbet boşsa boş. Arşivde artık olmayan toplantılar düşer (sıra korunur). Saf fonksiyondur.
public func followUpScope(exchanges: [ArchiveExchange], records: [MeetingRecord]) -> [MeetingRecord] {
    guard let last = exchanges.last else {
        return []
    }
    return exchangeMentionIDs(exchange: last).compactMap { (id: String) -> MeetingRecord? in records.first { $0.id == id } }
}

/// Sorunun `@` ile seçilen toplantıları: kapsamı tek toplantı olan soruda (toplantı sayfası) etiket yoktur. Saf
/// fonksiyondur.
public func exchangeMentionIDs(exchange: ArchiveExchange) -> [String] {
    askScopeMeetingID(scope: exchange.scope) == nil ? exchange.scopeMeetingIDs : []
}

/// Bitmiş ya da yazılırken durdurulmuş (o ana kadar cevabı olan) soruyu sohbet geçmişine yazılacak tura çevirir (okunan
/// parçalar metinsiz); süren, hatalı ya da cevabı yokken durdurulan soru nil. Saf fonksiyondur.
public func askTurn(exchange: ArchiveExchange) -> AskConversationTurn? {
    let isStopped: Bool = exchange.phase == .stopped && !exchange.answer.text.isEmpty
    guard exchange.phase == .done || isStopped, let finishedAt = exchange.finishedAt else {
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
        webQueries: exchange.webQueries, webSearchNotice: exchange.webSearchNotice, skippedMeetings: exchange.skippedMeetings,
        wasStopped: isStopped ? true : nil, scope: exchange.scope
    )
}

/// Saklanan turu sohbette gösterilecek bitmiş soruya çevirir; eski sürümlerin cevaba yankılanmış istem etiketleri
/// gösterilmez (`withoutPromptTags`). Saf fonksiyondur.
public func archiveExchange(turn: AskConversationTurn) -> ArchiveExchange {
    ArchiveExchange(
        id: turn.id, question: turn.question, scope: askTurnScope(turn: turn), scopeMeetingIDs: turn.scopeMeetingIDs, scopeTitles: turn.scopeTitles, recipeTitle: turn.recipeTitle,
        startedAt: turn.startedAt, phase: turn.wasStopped == true ? .stopped : .done, terms: turn.terms, passages: turn.readPassages,
        screens: turn.readScreens ?? 0, answer: ArchiveAnswer(text: withoutPromptTags(text: turn.answer), sources: turn.sources, webSources: turn.webSources ?? []),
        webQueries: turn.webQueries ?? [], webSearchNotice: turn.webSearchNotice ?? .ok, skippedMeetings: turn.skippedMeetings ?? [], finishedAt: turn.finishedAt
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
    case .coverage(let coverage):
        updated.skippedMeetings = coverage.skipped
    case .passages(let passages):
        updated.passages = passages
    case .screens(let count):
        updated.screens = count
        updated.phase = .writing
    case .answer(let answer):
        updated.answer = answer
    case .web(let queries, let notice):
        updated.webQueries = queries
        updated.webSearchNotice = notice
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
/// kopyala, Markdown, yeniden oluştur, kaynaklar ve nasıl cevaplandığı. Tüm arşive sorulan sorunun cevabının altında
/// kapsam dipnotu ("10 toplantıya dayanıyor · 3–6 Kas") durur.
public struct ExchangeView: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void
    /// Soruyu tarif olarak kaydeder (tariften gelen soruda gösterilmez).
    let onSaveRecipe: @MainActor (String) -> Void
    /// Soruyu yeniden sorar (yalnız sohbetin son sorusunda; diğerlerinde nil).
    let onRegenerate: (@MainActor () -> Void)?
    /// Aynı soruyu verilen toplantılara (`@` kapsamı) yeniden sorar: kapsam dipnotundaki "Bunlara da sor". Soru
    /// sorulamıyorken (cevap sürüyor, toplantı sayfasının çubuğu) nil.
    let onAskMeetings: (@MainActor ([String]) -> Void)?

    public init(
        exchange: ArchiveExchange, onOpen: @escaping @MainActor (ArchivePassage) -> Void, onSaveRecipe: @escaping @MainActor (String) -> Void,
        onRegenerate: (@MainActor () -> Void)?, onAskMeetings: (@MainActor ([String]) -> Void)?
    ) {
        self.exchange = exchange
        self.onOpen = onOpen
        self.onSaveRecipe = onSaveRecipe
        self.onRegenerate = onRegenerate
        self.onAskMeetings = onAskMeetings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !exchangeMentionIDs(exchange: exchange).isEmpty, !exchange.scopeTitles.isEmpty {
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
                    // Uzun soru satırlara sarılır; cevabın yerleşimi sıkıştırınca tek satırda "…" ile kesilmez.
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Adımlar: aranan terimler, "8 not sonucu" (çalışırken açık, bitince kapalı) ve parıltılı o anki adım.
            AskProgressSteps(exchange: exchange, onOpen: onOpen)
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
            if showsCoverageFootnote(exchange: exchange) {
                CoverageFootnote(exchange: exchange, onAskMeetings: onAskMeetings)
                    .transition(.opacity)
            }
            switch exchange.webSearchNotice {
            case .capReached:
                WebSearchNoticeLine(text: "Bu ayın web araması hakkı doldu; cevap yalnız toplantılardan.")
            case .unavailable:
                WebSearchNoticeLine(text: "Web araması şu an kullanılamıyor; cevap toplantılarından.")
            case .ok:
                EmptyView()
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

/// Web araması istendiği halde yapılamadığında cevabın altındaki kısa not (küre simgesi, soluk).
private struct WebSearchNoticeLine: View {
    let text: LocalizedStringKey

    var body: some View {
        Label(text, systemImage: "globe")
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Cevabın altında kapsam dipnotu gösterilir mi: bitmiş, toplantılardan parça okumuş bir cevap; soru bir kapsama
/// (tüm toplantılar, bu toplantı, klasör, kişi, tarih aralığı) sorulduysa ya da `@` ile seçilen toplantılardan bazıları
/// sığmadıysa (`@` ile seçilen tek toplantıda "1 toplantıya dayanıyor" gürültü olurdu). Saf fonksiyondur.
public func showsCoverageFootnote(exchange: ArchiveExchange) -> Bool {
    exchange.phase == .done && !exchange.answer.text.isEmpty && !exchange.passages.isEmpty
        && (exchangeMentionIDs(exchange: exchange).isEmpty || !exchange.skippedMeetings.isEmpty)
}

/// Kapsam dipnotunda bir okunan toplantı açılınca gidilecek parça: toplantının notu, notu okunmadıysa okunan ilk
/// transkript parçası. Okunmayan toplantı için nil. Saf fonksiyondur.
public func coverageOpenPassage(meetingID: String, passages: [ArchivePassage]) -> ArchivePassage? {
    passages.first { $0.meetingID == meetingID && $0.kind == .note } ?? passages.first { $0.meetingID == meetingID }
}

/// Kapsam dipnotunun özeti, arayüz dilinde ve sorunun kapsamına göre: "Bu toplantıya dayanıyor", "Müşteriler
/// klasöründe 6 toplantıya dayanıyor · 3–6 Kas", "Anna ile 4 toplantıya dayanıyor · …", "10 toplantıya dayanıyor · …".
@MainActor
func coverageSummary(exchange: ArchiveExchange, meetings: [ArchiveMeetingRef]) -> String {
    let range: String? = coverageDateRange(meetings: meetings, now: Date(), locale: interfaceLocale(), calendar: Calendar.current)
    let count: String
    switch exchangeMentionIDs(exchange: exchange).isEmpty ? exchange.scope : .allMeetings {
    case .meeting:
        return String(localized: "Bu toplantıya dayanıyor")
    case .folder(let name):
        count = String(localized: "\(meetings.count) toplantıya dayanıyor, klasör: \(name)")
    case .person(let name):
        count = String(localized: "\(meetings.count) toplantıya dayanıyor, kişi: \(name)")
    case .lastDays(let days):
        count = String(localized: "\(meetings.count) toplantıya dayanıyor, son \(days) gün")
    case .allMeetings:
        count = String(localized: "\(meetings.count) toplantıya dayanıyor")
    }
    return ([count] + [range].compactMap { $0 }).joined(separator: " · ")
}

/// Cevabın altındaki küçük, soluk kapsam dipnotu (sayı ve tarihler koddan; model kapsam satırı yazmaz). Okunan
/// toplantıların listesi cevabın üstündeki "8 not sonucu" satırındadır (`AskProgressSteps`). Soruyla ilgili toplantılar
/// sığmadıysa altında sayısı ve "Bunlara da sor" (aynı soru en yeni `coverageAskMoreLimit` okunmayan toplantıya `@` ile
/// sorulur).
private struct CoverageFootnote: View {
    let exchange: ArchiveExchange
    let onAskMeetings: (@MainActor ([String]) -> Void)?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let summary: String = coverageSummary(exchange: exchange, meetings: readMeetings(passages: exchange.passages))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical")
                    .appFont(size: 10, weight: .semibold)
                    .accessibilityHidden(true)
                Text(verbatim: summary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .accessibilityElement(children: .combine)
            if !exchange.skippedMeetings.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(exchange.skippedMeetings.count) ilgili toplantı bu cevaba sığmadı")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if let onAskMeetings {
                        Button("Bunlara da sor") {
                            onAskMeetings(askMoreMeetingIDs(skipped: exchange.skippedMeetings))
                        }
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(appearance.accent.color)
                        .buttonStyle(.hoverPlain)
                        .hoverHint("Aynı soru sığmayan en yeni toplantılara sorulur", alignment: .leading, edge: .bottom)
                    }
                }
            }
        }
    }
}

/// Çalışırken tek satır: parıltılı durum ("Düşünüyor…", "Arşiv taranıyor…", "8 toplantı okunuyor…").
struct ThinkingLine: View {
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
struct ShimmerText: View {
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

/// Bitmiş cevabın altında tek satır (iPhone genişliğinde de taşmaz): solda kopyala, yeniden oluştur ve tarif olarak
/// kaydet simgeleri ile tek "Kaynaklar" hapı (toplantı ve web kaynaklarının sayısı), en sağda diğer seçenekler (⋯:
/// Markdown olarak kopyala, .md kaydet/paylaş). Hap açılınca altında ince bir kartta okuma özeti ("1 toplantı · 19 parça
/// · 16 sn"), kaynaklar, web kaynakları ve aranan terimler görünür.
private struct AnswerFooter: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void
    let onSaveRecipe: @MainActor (String) -> Void
    let onRegenerate: (@MainActor () -> Void)?
    @State private var isOpen: Bool = false
    @State private var isSaved: Bool = false
    #if os(macOS)
    /// .md dosyası yazılamadıysa nedeni (satırın altında; satırı genişletmesin).
    @State private var exportError: String?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                if hasAnswer {
                    CopyAnswerButton(answer: exchange.answer)
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
                if hasDetails {
                    FooterPill(symbol: "text.quote", isOpen: isOpen) {
                        HStack(spacing: 5) {
                            Text("Kaynaklar")
                            if sourceCount > 0 {
                                Text(verbatim: "\(sourceCount)").fontWeight(.semibold)
                            }
                        }
                    } onToggle: {
                        withAnimation(.smooth(duration: 0.22)) { isOpen.toggle() }
                    }
                    .padding(.leading, 4)
                }
                Spacer(minLength: 8)
                if hasAnswer {
                    #if os(macOS)
                    AnswerExportMenu(exchange: exchange, exportError: $exportError)
                    #else
                    AnswerExportMenu(exchange: exchange)
                    #endif
                }
            }
            #if os(macOS)
            if let exportError {
                NoticeText(exportError, severity: .error)
                    .appFont(size: 12, weight: .regular)
            }
            #endif
            if isOpen {
                AnswerDetails(exchange: exchange, onOpen: onOpen)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Kopyalanacak ya da dışa aktarılacak bir cevap var.
    private var hasAnswer: Bool {
        exchange.phase == .done || !exchange.answer.text.isEmpty
    }

    /// Hapta gösterilecek bir şey var: kaynak, okunan parça ya da arama.
    private var hasDetails: Bool {
        sourceCount > 0 || !exchange.passages.isEmpty || !exchange.terms.isEmpty || !exchange.webQueries.isEmpty
    }

    /// Toplantı ve web kaynaklarının toplamı.
    private var sourceCount: Int {
        exchange.answer.sources.count + exchange.answer.webSources.count
    }

    /// Hatalı soruda yeniden deneme hata satırındadır ("Tekrar dene").
    private var isFailed: Bool {
        if case .failed = exchange.phase {
            return true
        }
        return false
    }
}

/// "Kaynaklar" hapının kartı: okuma özeti, toplantı kaynakları, web kaynakları ve nasıl cevaplandığı.
private struct AnswerDetails: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(answerReadingSummary(exchange: exchange))
                .appFont(size: 12, weight: .regular)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 6)
            if !exchange.answer.sources.isEmpty {
                SourcesList(sources: exchange.answer.sources, onOpen: onOpen)
            }
            if !exchange.answer.webSources.isEmpty {
                WebSourcesList(sources: exchange.answer.webSources)
            }
            if !exchange.terms.isEmpty || !exchange.passages.isEmpty || exchange.webQueries.contains(where: { !$0.isEmpty }) {
                ReasoningDetails(exchange: exchange)
            }
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
    /// Dosya yazılamadıysa nedeni (cevap satırının altında gösterilir).
    @Binding var exportError: String?
    @State private var isExporting: Bool = false
    #endif

    var body: some View {
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

/// Okuma özeti: "1 toplantı · 19 parça · 16 sn"; ekran görüntüsü de gittiyse "1 toplantı · 6 parça · 2 ekran görüntüsü ·
/// 6 sn". Her sayı dilin çoğul kuralıyla yazılır (katalogda çoğul biçimler). Toplantılar kimliğe göre sayılır (aynı adlı
/// yinelenen toplantılar ayrı; yazılırken gösterilen sayıyla aynı). Süre tam saniye (en az 1).
@MainActor
func answerReadingSummary(exchange: ArchiveExchange) -> String {
    let meetings: Int = Set(exchange.passages.map(\.meetingID)).count
    let seconds: Double = (exchange.finishedAt ?? Date()).timeIntervalSince(exchange.startedAt)
    let duration: String = Duration.seconds(max(1, seconds.rounded())).formatted(
        Duration.UnitsFormatStyle(allowedUnits: [.seconds], width: .abbreviated).locale(interfaceLocale())
    )
    let screens: [String] = exchange.screens > 0 ? [String(localized: "\(exchange.screens) ekran görüntüsü")] : []
    return ([String(localized: "\(meetings) toplantı"), String(localized: "\(exchange.passages.count) parça")] + screens + [duration]).joined(separator: " · ")
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
    /// Akarken çizilen bloklar ve önceki karenin ayrıştırması (`streamingMarkdown`): her karede yalnız yarım paragraf
    /// ayrıştırılır. nil iken (ilk kare) bütün metin ayrıştırılır.
    @State private var rendered: [MarkdownBlock]?
    @State private var parsed: StreamingMarkdown = .empty

    private var isWriting: Bool {
        exchange.phase == .writing
    }

    var body: some View {
        let full: String = exchange.answer.text
        AnswerMarkdownView(blocks: rendered ?? parseMarkdown(text: isWriting ? streamingCaret : full), webSources: exchange.answer.webSources)
            .environment(\.openURL, OpenURLAction { (url: URL) -> OpenURLAction.Result in
                guard url.scheme == citationScheme, let number = Int(url.host() ?? "") else {
                    // Yalnız web adresleri sisteme verilir; başka şemalar (file:, smb:, uygulama şemaları) açılmaz.
                    return isWebAddress(url.absoluteString) ? .systemAction : .discarded
                }
                onCitation(number)
                return .handled
            })
            .task(id: full) {
                let total: Int = full.count
                // Bitmiş (ya da yeniden çizilen) cevap beklemeden görünür; akan cevap yakalanana dek açılır.
                if !isWriting, shown == 0 {
                    shown = total
                    rendered = parseMarkdown(text: full)
                    return
                }
                while shown < total, !Task.isCancelled {
                    shown = min(total, shown + max(1, (total - shown) / 10))
                    let step: (state: StreamingMarkdown, blocks: [MarkdownBlock]) = streamingMarkdown(
                        previous: parsed, text: String(full.prefix(shown)) + streamingCaret
                    )
                    parsed = step.state
                    rendered = step.blocks
                    do {
                        try await Task.sleep(for: .milliseconds(18))
                    } catch {
                        return
                    }
                }
                // Bitince imleçsiz ve bütün olarak (akıştaki önek/kalan ayrımı olmadan) çizilir.
                if !isWriting {
                    rendered = parseMarkdown(text: full)
                }
            }
            .onChange(of: isWriting) { (_: Bool, writing: Bool) in
                if !writing, shown >= full.count {
                    rendered = parseMarkdown(text: full)
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
                    if isWebAddress(item.element.url), let url = URL(string: item.element.url) {
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
        .background(appearance.accent.softFill(tintOpacity: 0.12), in: Capsule())
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
            .background(appearance.accent.softFill(tintOpacity: 0.12), in: Capsule())
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
