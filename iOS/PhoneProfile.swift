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
                    ProfileAvatar(imageURL: account.avatarURL, initial: accountAvatarInitial(userName: store.userName, email: account.signedInIdentity?.email), size: 96)
                    // Rozetin altında ad; e-posta biliniyorsa altında (bilinmiyorsa "Hesap" yazmak bir şey söylemiyordu).
                    let name: String = store.userName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        Text(verbatim: name)
                            .appFont(size: 20, weight: .medium)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    if let email = account.signedInIdentity?.email {
                        Text(verbatim: email)
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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
            // Profil ve hesap Ayarlar'da tek satır: plan, kullanım, çıkış ve hesap silme buradan açılır.
            Section {
                NavigationLink(value: PhoneRoute.account) {
                    PhoneAccountRow(account: account)
                }
            } header: {
                Text("Hesap ve plan")
            }
        }
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .tint(appearance.accent.color)
    }
}

/// Ayarlar › Hesap'taki profil satırı: baş harf, ad (yazılmadıysa davet) ve giriş yapılan e-posta.
struct PhoneProfileRow: View {
    let store: PhoneStore
    let account: HostedAccount

    var body: some View {
        let name: String = store.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 12) {
            ProfileAvatar(imageURL: account.avatarURL, initial: accountAvatarInitial(userName: store.userName, email: account.signedInIdentity?.email), size: 40)
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
                // Altta giriş yapılan kimlik (plan durumu Ayarlar'ın üstündeki plan kartında).
                Text(verbatim: phoneIdentityTitle(identity: account.signedInIdentity))
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
