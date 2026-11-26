import AINotepadCore
import AINotepadUI
import SwiftUI

/// Hesapsız ana ekran: giriş kapısında "Klavyeyi hesapsız kullan" seçilince (bkz. `phoneSignedOutScreen`) giriş yapılana
/// dek bu açılır. Gistsmith Klavye (yazma, kaydırarak yazma, Türkçe işaretler, cihaz içi sesle yazma) bize bir şeye mal
/// olmaz ve hesap istemez: bu ekran klavyenin kurulumunu ve ayarlarını (Ayarlar › Klavye'dekiyle aynı liste) verir; hesaba
/// bağlı olanlar (toplantı notları, Sor) yerine sakin bir "Giriş yap" kartı durur. Giriş yapılınca normal uygulama açılır;
/// klavye ayarları hesaptan bağımsız saklandığı için olduğu gibi kalır.
struct PhoneKeyboardHome: View {
    @AppStorage(PhoneSettingsKey.keyboardWithoutAccount) private var choseKeyboardWithoutAccount: Bool = false

    var body: some View {
        NavigationStack {
            PhoneKeyboardSettingsList(introSection: { PhoneKeyboardSignInCard(signIn: signIn) }, accountSection: { EmptyView() })
            .navigationTitle(PhoneSettingsPage.keyboard.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Giriş yap", action: signIn)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    /// Hesapsız ana ekran kapanır; giriş kapısı (Apple ve Google ile devam et) açılır.
    private func signIn() {
        choseKeyboardWithoutAccount = false
    }
}
