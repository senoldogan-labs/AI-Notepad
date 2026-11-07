import Foundation

/// Toplantı sayfasındaki "Bir şey sor" çubuğunun hazır eylemleri (Mac ve iPhone aynı): bu toplantıya sorulan bir tarif
/// ya da notu sorarak düzenleme.
public struct MeetingQuickAction: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Bu toplantıya Sor'la sorulur; cevap çubuğun üstünde açılır. Tariften geldiyse balonda tarifin adı görünür.
        case ask(prompt: String, recipeTitle: String)
        /// Not bu istekle yeniden yazılır (notu sorarak düzenleme; sonuç notun kendisinde görünür).
        case editNote(instruction: String)
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let kind: Kind

    public init(id: String, title: String, symbol: String, kind: Kind) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.kind = kind
    }
}

/// Çubuğun hazır eylemleri: takip e-postası ve aksiyonlar yerleşik tariflerden (tarif adı ve istemi aynen), kısa özet
/// ve notu uzatma bu sayfaya özgü. Yerleşik tarif listede yoksa onun eylemi atlanır. Saf fonksiyondur.
public func meetingQuickActions(recipes: [Recipe]) -> [MeetingQuickAction] {
    let fromRecipe: (String) -> MeetingQuickAction? = { (id: String) -> MeetingQuickAction? in
        recipes.first { $0.id == id && $0.isBuiltIn }.map { (recipe: Recipe) -> MeetingQuickAction in
            MeetingQuickAction(id: recipe.id, title: recipe.title, symbol: recipe.symbol, kind: .ask(prompt: recipe.prompt, recipeTitle: recipe.title))
        }
    }
    let tldr: MeetingQuickAction = MeetingQuickAction(
        id: "kisaca", title: String(localized: "Kısaca"), symbol: "text.append",
        kind: .ask(
            prompt: String(localized: "Bu toplantıyı en çok üç kısa maddede özetle: ne konuşuldu, ne karar verildi, sırada ne var."),
            recipeTitle: String(localized: "Kısaca")
        )
    )
    let longer: MeetingQuickAction = MeetingQuickAction(
        id: "notu-uzat", title: String(localized: "Notu uzat"), symbol: "arrow.up.left.and.arrow.down.right",
        kind: .editNote(instruction: String(localized: "Notu daha ayrıntılı yaz: özeti genişlet, kararların gerekçelerini ve konuşulan örnekleri ekle."))
    )
    return [fromRecipe("takip-epostasi"), fromRecipe("aksiyonlar"), tldr, longer].compactMap { $0 }
}

/// Cevaptan sonra önerilen devam soruları sayısı.
public let meetingFollowUpLimit: Int = 3

/// "Bir şey sor" çubuğunda son cevabın altındaki devam soruları: ek yapay zekâ çağrısı yapılmaz, notun içeriğinden
/// seçilir. Önce cevabı açtıran soru, sonra notta karar varsa nasıl varıldığı, açık konu varsa kimin takip edeceği, görev
/// varsa kimin neyi ne zamana yapacağı, en sonda e-posta taslağı; daha önce aynen sorulanlar atlanır, en çok
/// `meetingFollowUpLimit` tanesi döner. Son soru bitmemişse (cevap akıyor, durduruldu, hatalı) ya da sohbet boşsa boş.
/// Saf fonksiyondur.
public func meetingFollowUpSuggestions(note: MeetingNote?, askedQuestions: [String], lastAnswerFinished: Bool) -> [String] {
    guard lastAnswerFinished, !askedQuestions.isEmpty else {
        return []
    }
    let candidates: [String?] = [
        String(localized: "Bunu biraz daha aç"),
        (note?.decisions.isEmpty ?? true) ? nil : String(localized: "Bu kararlara nasıl varıldı?"),
        (note?.openQuestions ?? []).isEmpty ? nil : String(localized: "Açık kalan konuları kim takip edecek?"),
        (note?.tasks.isEmpty ?? true) ? nil : String(localized: "Kim neyi ne zamana yapacak?"),
        String(localized: "Bundan kısa bir e-posta taslağı yaz"),
    ]
    let asked: Set<String> = Set(askedQuestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    return Array(candidates.compactMap { $0 }.filter { !asked.contains($0.lowercased()) }.prefix(meetingFollowUpLimit))
}
