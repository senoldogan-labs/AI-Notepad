import AINotepadCore
import SwiftUI

/// Sorunun adımlarında listelenen toplantılar ("8 not sonucu"): arşivde bulunup okunan toplantılar, okuma sırasıyla.
/// Soru tek bir toplantıya sorulduysa (toplantı sayfası, kapsam "bu toplantı") liste yok: tek satırlık "1 not sonucu"
/// yalnız gürültü olurdu. Saf fonksiyondur.
public func askNoteResults(exchange: ArchiveExchange) -> [ArchiveMeetingRef] {
    guard askScopeMeetingID(scope: exchange.scope) == nil else {
        return []
    }
    return readMeetings(passages: exchange.passages)
}

/// Soru hâlâ cevaplanıyor mu (soruyu anlama, arama ya da yazma adımında). Saf fonksiyondur.
public func isExchangeRunning(exchange: ArchiveExchange) -> Bool {
    [.understanding, .searching, .writing].contains(exchange.phase)
}

/// Cevabın üstündeki adımlar (Mac'te Sor sayfası, iPhone'da Sor): çalışırken arama terimleri, bulunan toplantılar
/// ("8 not sonucu", açık liste; dokununca toplantı açılır) ve parıltılı o anki adım ("8 toplantı okunuyor…"). Cevap
/// bitince yalnız kapalı "8 not sonucu" satırı kalır; dokununca liste yeniden açılır. Liste vurgu renginde ince bir
/// çizgiyle soldan bağlanır; bulanıklık ya da sürekli animasyon yok (yalnız açılıp kapanırken kısa geçiş).
struct AskProgressSteps: View {
    let exchange: ArchiveExchange
    let onOpen: @MainActor (ArchivePassage) -> Void
    /// Kullanıcı listeyi kendisi açtı ya da kapattı; nil: çalışırken açık, bitince kapalı. Cevap bitince sıfırlanır.
    @State private var userOpen: Bool?

    var body: some View {
        let results: [ArchiveMeetingRef] = askNoteResults(exchange: exchange)
        let isRunning: Bool = isExchangeRunning(exchange: exchange)
        let isOpen: Bool = userOpen ?? isRunning
        VStack(alignment: .leading, spacing: 8) {
            if isRunning, !exchange.terms.isEmpty {
                SearchedTermsStep(terms: exchange.terms)
                    .transition(.opacity)
            }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    NoteResultsToggle(count: results.count, isOpen: isOpen) {
                        withAnimation(.smooth(duration: 0.22)) { userOpen = !isOpen }
                    }
                    if isOpen {
                        NoteResultsList(meetings: results, passages: exchange.passages, onOpen: onOpen)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .transition(.opacity)
            }
            // Cevap akmaya başlayınca o anki adım satırı kalkar.
            if isRunning, exchange.answer.text.isEmpty {
                ThinkingLine(exchange: exchange)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: results.count)
        .animation(.smooth(duration: 0.25), value: isRunning)
        .onChange(of: isRunning) { (_: Bool, running: Bool) in
            // Cevap bitince liste kapanır (kullanıcı çalışırken açıp kapattıysa da).
            if !running {
                withAnimation(.smooth(duration: 0.25)) { userOpen = nil }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cevabın adımları")
    }
}

/// Aranan terimler: büyüteç ve "Aranan: “bütçe”, “Q3”" (soluk, tek satıra sığmazsa sarılır).
private struct SearchedTermsStep: View {
    let terms: [String]

    var body: some View {
        let quoted: String = terms.map { "“\($0)”" }.joined(separator: ", ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "magnifyingglass")
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text("Aranan: \(quoted)")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "8 not sonucu" satırı: vurgu renginde belge simgesi ve sayı, açılıp kapanan ok.
private struct NoteResultsToggle: View {
    let count: Int
    let isOpen: Bool
    let onToggle: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text("\(count) not sonucu")
                    .appFont(size: 13, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(isOpen ? Theme.ink : Theme.ink.opacity(0.8))
                Image(systemName: "chevron.down")
                    .appFont(size: 8, weight: .bold)
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 3)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .hoverHint(isOpen ? "Aranan toplantıları gizle" : "Aranan toplantıları göster", alignment: .leading, edge: .bottom)
        .accessibilityLabel(Text("\(count) not sonucu"))
        .accessibilityHint(isOpen ? "Aranan toplantıları gizle" : "Aranan toplantıları göster")
    }
}

/// Bulunan toplantılar: solda vurgu renginde ince çizgi, her satırda başlık, tarih ve aç oku. Dokununca toplantının notu
/// (notu okunmadıysa okunan ilk anı) açılır.
private struct NoteResultsList: View {
    let meetings: [ArchiveMeetingRef]
    let passages: [ArchivePassage]
    let onOpen: @MainActor (ArchivePassage) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(meetings, id: \.id) { (meeting: ArchiveMeetingRef) in
                let date: String = meeting.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))
                Button {
                    if let passage = coverageOpenPassage(meetingID: meeting.id, passages: passages) {
                        onOpen(passage)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        // Büyük yazıda başlık iki satıra sarılır (tarih yanında kalır).
                        Text(verbatim: meeting.title)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.ink.opacity(0.85))
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(verbatim: date)
                            .appFont(size: 12, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "arrow.up.right")
                            .appFont(size: 9, weight: .semibold)
                            .foregroundStyle(Theme.muted.opacity(0.8))
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .frame(minHeight: rowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("Toplantıyı aç", alignment: .leading, edge: .bottom)
                .accessibilityLabel(Text(verbatim: "\(meeting.title), \(date)"))
                .accessibilityHint("Toplantıyı aç")
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(appearance.accent.color.opacity(0.45))
                .frame(width: 2)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
        .padding(.leading, 7)
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// Satırın en az yüksekliği: iPhone'da parmakla dokunulacak kadar (44 pt), Mac'te sık liste.
    private var rowMinHeight: CGFloat {
        #if os(iOS)
        44
        #else
        0
        #endif
    }
}
