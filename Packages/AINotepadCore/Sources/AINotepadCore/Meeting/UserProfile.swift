import Foundation

// Kullanıcının kendini tanıttığı profil (Ayarlar > Profil): ad, unvan, şirket ve şirket açıklaması. Ad gibi saklanır
// (geliştirici sürümünde standart ayarlarda, abonelikte hesabın ayar alanında; bkz. `userNameDefaultsKey`) ve
// eşitlenmez. Not, not düzenleme, Sor ve takip e-postası istemlerine arka plan bilgisi olarak gider
// (`withUserProfile`); konuşmacı incelemesine ve çeviriye gitmez.

/// Unvanın ayar anahtarı (Mac ve iPhone'da aynı).
public let userJobTitleDefaultsKey: String = "profile.jobTitle"

/// Şirket adının ayar anahtarı (Mac ve iPhone'da aynı).
public let userCompanyNameDefaultsKey: String = "profile.companyName"

/// Şirket açıklamasının ayar anahtarı (Mac ve iPhone'da aynı).
public let userCompanyDescriptionDefaultsKey: String = "profile.companyDescription"

/// Tek satırlık profil alanlarının (unvan, şirket) en uzun hâli (karakter).
public let profileFieldLimit: Int = 120

/// Şirket açıklamasının en uzun hâli (karakter): her istemle gider, kısa kalmalı.
public let profileDescriptionLimit: Int = 600

/// Kullanıcının profili. Boş metin: alan verilmedi.
public struct UserProfile: Sendable, Equatable {
    /// Kullanıcının adı (istemde `promptUserRule` taşır; `userProfilePromptBlock` yazmaz).
    public let name: String
    public let jobTitle: String
    public let companyName: String
    public let companyDescription: String

    public init(name: String, jobTitle: String, companyName: String, companyDescription: String) {
        self.name = name
        self.jobTitle = jobTitle
        self.companyName = companyName
        self.companyDescription = companyDescription
    }

    /// Hiçbir alanı verilmemiş profil.
    public static let empty: UserProfile = UserProfile(name: "", jobTitle: "", companyName: "", companyDescription: "")
}

/// Profil alanını saklanacak hâline getirir: en fazla `limit` karakter (baştaki ve sondaki boşluk korunur; yazarken
/// imleç zıplamasın). Saf fonksiyondur.
public func cappedProfileText(text: String, limit: Int) -> String {
    String(text.prefix(limit))
}

/// İstemdeki "kullanıcı hakkında" bloğu: unvan, şirket ve şirket açıklaması (bu sırayla; boş alan yazılmaz, her alan
/// kırpılır ve sınırına kısaltılır). Üçü de boşsa boş metin: istem bugünküyle bayt bayt aynı kalır. Ad yazılmaz: istemde
/// zaten `promptUserRule` taşır. Saf fonksiyondur.
public func userProfilePromptBlock(profile: UserProfile) -> String {
    let fields: [(label: String, value: String, limit: Int)] = [
        (label: "Unvan", value: profile.jobTitle, limit: profileFieldLimit),
        (label: "Şirket", value: profile.companyName, limit: profileFieldLimit),
        (label: "Şirket açıklaması", value: profile.companyDescription, limit: profileDescriptionLimit),
    ]
    let lines: [String] = fields.compactMap { (field: (label: String, value: String, limit: Int)) -> String? in
        let value: String = String(field.value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(field.limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : "\(field.label): \(value)"
    }
    guard !lines.isEmpty else {
        return ""
    }
    return """
    Kullanıcı hakkında arka plan bilgisi (<kullanici_hakkinda>; kullanıcının kendi verdiği, toplantıda söylenmedi): bunu \
    yalnızca jargonu, ürün ve proje adlarını ve kullanıcının hangi tarafta olduğunu (ör. kendi şirketi mi, müşteri mi) \
    anlamak için kullan. Toplantıda söylenmiş gibi yazma, ondan bilgi, karar ya da görev çıkarma, transkriptte olmayan \
    bir şeyi bununla tamamlama.
    <kullanici_hakkinda>
    \(lines.joined(separator: "\n"))
    </kullanici_hakkinda>
    """
}

/// Sistem istemine profil bloğunu ekler; blok boşsa istem aynen döner (bayt bayt). Saf fonksiyondur.
public func withUserProfile(system: String, profile: UserProfile) -> String {
    let block: String = userProfilePromptBlock(profile: profile)
    return block.isEmpty ? system : "\(system)\n\(block)"
}
