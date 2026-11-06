import AINotepadCore
import AINotepadUI
import SwiftUI

/// Profil satırları (Mac'teki Ayarlar > Profil): ad, unvan, şirket ve şirket açıklaması. Yalnızca satırlardır; bölüm
/// başlığını ve açıklamasını çağıran verir (ayrı bir Profil ekranına taşınabilsin). Değerler hesabın ayar alanında
/// saklanır (bkz. `PhoneStore.userProfile`).
struct PhoneProfileFields: View {
    let store: PhoneStore

    var body: some View {
        // Etiketli satır: ad yazılınca alan yalnızca adı gösteriyor, neyin adı olduğu anlaşılmıyordu.
        PhoneCaptionedRow(caption: Text("Notta sana düşen görevleri ayırmak için kullanılır.")) {
            LabeledContent {
                TextField("Adın", text: Binding<String>(get: { store.userName }, set: { (name: String) -> Void in store.setUserName(name: name) }), prompt: Text("İsteğe bağlı"))
                    .multilineTextAlignment(.trailing)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } label: {
                PhoneSettingLabel(icon: "person.crop.circle", title: Text("Adın"))
            }
        }
        LabeledContent {
            TextField("Unvan", text: Binding<String>(get: { store.jobTitle }, set: { (text: String) -> Void in store.setJobTitle(text: text) }), prompt: Text("İsteğe bağlı"))
                .multilineTextAlignment(.trailing)
                .textContentType(.jobTitle)
                .textInputAutocapitalization(.sentences)
        } label: {
            PhoneSettingLabel(icon: "briefcase", title: Text("Unvan"))
        }
        LabeledContent {
            TextField("Şirket", text: Binding<String>(get: { store.companyName }, set: { (text: String) -> Void in store.setCompanyName(text: text) }), prompt: Text("İsteğe bağlı"))
                .multilineTextAlignment(.trailing)
                .textContentType(.organizationName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        } label: {
            PhoneSettingLabel(icon: "building.2", title: Text("Şirket"))
        }
        NavigationLink {
            PhoneCompanyDescriptionScreen(store: store)
        } label: {
            PhoneSettingLabel(icon: "text.alignleft", title: Text("Şirket açıklaması")) {
                if !store.companyDescription.isEmpty {
                    Text(verbatim: store.companyDescription)
                        .lineLimit(2)
                }
            }
        }
    }
}

/// Şirket açıklaması: çok satırlı alan ve karakter sayacı; en fazla `profileDescriptionLimit` karakter saklanır.
private struct PhoneCompanyDescriptionScreen: View {
    let store: PhoneStore
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ne yaptığınızı, ürünlerinizi ve sık geçen terimleri birkaç cümleyle yaz.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .appFont(size: 16, weight: .regular)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            Text("\(text.count)/\(profileDescriptionLimit)")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .background(Theme.background)
        .navigationTitle(Text("Şirket açıklaması"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            text = store.companyDescription
            isFocused = true
        }
        .onChange(of: text) { (_: String, value: String) in
            store.setCompanyDescription(text: value)
            // Sınırı aşan yazı alanda da kalmasın (saklanan metinle aynı).
            let capped: String = cappedProfileText(text: value, limit: profileDescriptionLimit)
            if capped != value {
                text = capped
            }
        }
    }
}
