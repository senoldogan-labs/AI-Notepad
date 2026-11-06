import AINotepadCore
import AINotepadUI
import SwiftUI

/// Profil (Ayarlar › Hesap'ın ilk satırı): büyük baş harf, giriş yapılan e-posta, kartta ad, unvan, şirket ve şirket
/// açıklaması (`PhoneProfileFields`). Ad notta sana düşen görevleri ayırır; diğerleri notlara bağlam olur.
struct PhoneProfileScreen: View {
    let store: PhoneStore
    let account: HostedAccount
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    PhoneAvatar(initial: phoneAvatarInitial(userName: store.userName, email: account.signedInIdentity?.email), size: 96)
                    Text(verbatim: phoneIdentityTitle(identity: account.signedInIdentity))
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            } header: {
                Text("Gistsmith seni tanıdıkça notlarda sana düşen işleri doğru ayırır.")
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .textCase(nil)
                    .padding(.bottom, 8)
            }
            Section {
                PhoneProfileFields(store: store)
            } footer: {
                Text("Notlar bağlamını anlamak için bunu kullanır; yalnızca not ya da cevap yazılırken toplantı metniyle gönderilir.")
            }
        }
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .tint(appearance.accent.color)
    }
}

/// Ayarlar'daki profil satırı: baş harf, ad (yazılmadıysa davet) ve e-posta.
struct PhoneProfileRow: View {
    let store: PhoneStore
    let account: HostedAccount

    var body: some View {
        let name: String = store.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 12) {
            PhoneAvatar(initial: phoneAvatarInitial(userName: store.userName, email: account.signedInIdentity?.email), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if name.isEmpty {
                        Text("Adını yaz")
                    } else {
                        Text(verbatim: name)
                    }
                }
                .appFont(size: 16, weight: .medium)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                Text("Profil")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Baş harfli yuvarlak: kullanıcının vurgu renginin soluk tonunda, harf vurgu renginde; harf yoksa kişi simgesi.
struct PhoneAvatar: View {
    let initial: String
    let size: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
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

/// Profil simgesinin harfi: adın, yoksa e-postanın ilk harfi (büyük); ikisi de yoksa boş. Saf fonksiyondur.
func phoneAvatarInitial(userName: String, email: String?) -> String {
    let source: String = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (email ?? "") : userName
    return source.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? ""
}
