import SwiftUI

/// Hesap simgesinin harfi: adın, yoksa e-postanın ilk harfi (büyük); ikisi de yoksa boş. Saf fonksiyondur.
public func accountAvatarInitial(userName: String, email: String?) -> String {
    let source: String = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (email ?? "") : userName
    return source.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? ""
}

/// Baş harfli yuvarlak: kullanıcının vurgu renginin soluk tonunda, harf vurgu renginde; harf yoksa kişi simgesi.
/// Mac'te kenar çubuğunda, iPhone'da ana ekranda ve Ayarlar'da aynı görünüm.
public struct InitialAvatar: View {
    let initial: String
    let size: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(initial: String, size: CGFloat) {
        self.initial = initial
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(appearance.accent.color.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                if initial.isEmpty {
                    Image(systemName: "person.fill")
                        .appFont(size: size * 0.42, weight: .medium)
                        .foregroundStyle(appearance.accent.color)
                } else {
                    Text(verbatim: initial)
                        .appFont(size: size * 0.44, weight: .medium)
                        .foregroundStyle(appearance.accent.color)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Hesabın avatarı: profil resmi (Google) varsa o; yüklenene dek, yüklenemezse ya da resim yoksa baş harfli yuvarlak.
public struct ProfileAvatar: View {
    let imageURL: URL?
    let initial: String
    let size: CGFloat

    public init(imageURL: URL?, initial: String, size: CGFloat) {
        self.imageURL = imageURL
        self.initial = initial
        self.size = size
    }

    public var body: some View {
        if let imageURL {
            AsyncImage(url: imageURL) { (phase: AsyncImagePhase) in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Theme.line))
                default:
                    InitialAvatar(initial: initial, size: size)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            InitialAvatar(initial: initial, size: size)
        }
    }
}
