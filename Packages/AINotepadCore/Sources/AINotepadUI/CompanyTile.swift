import AINotepadCore
import SwiftUI

/// Şirketin harf karosu: adının baş harfi, adına göre seçilen kişi renginde yuvarlatılmış kare (kişi rozetinin
/// yuvarlak olmayan eşi; aynı tabloda kişi ile şirket ayırt edilsin).
public struct CompanyTile: View {
    let name: String
    let size: CGFloat

    public init(name: String, size: CGFloat) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        let hash: Int = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        let color: Color = personColor(person: hash % DesignTokens.personPalette.count + 1)
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .appFont(size: size * 0.44, weight: .semibold)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(shape.fill(color.opacity(0.15)).background(shape.fill(Theme.card)))
            .accessibilityHidden(true)
    }
}

/// iPhone'daki şirketler listesinin satırı: harf karosu, ad (kullanıcının kendi şirketiyse işaretli), alan adı ve kişi
/// sayısı, ileri oku (dokununca şirketin sayfası açılır).
public struct CompanyListRow: View {
    let company: CompanySummary

    public init(company: CompanySummary) {
        self.company = company
    }

    public var body: some View {
        HStack(spacing: 12) {
            CompanyTile(name: company.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: company.name)
                        .appFont(size: 16, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if company.isOwn {
                        OwnCompanyBadge()
                    }
                }
                HStack(spacing: 0) {
                    Text(verbatim: "\(company.domain) · ")
                    Text("\(company.people.count) kişi")
                }
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// "Senin şirketin" işareti: vurgu renginde küçük kapsül (hesabın e-posta alan adı).
public struct OwnCompanyBadge: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init() {}

    public var body: some View {
        Text("Senin şirketin")
            .appFont(size: 11, weight: .semibold)
            .foregroundStyle(appearance.accent.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(appearance.accent.color.opacity(0.12)))
            .lineLimit(1)
            .fixedSize()
    }
}
