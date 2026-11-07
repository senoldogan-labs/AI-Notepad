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
