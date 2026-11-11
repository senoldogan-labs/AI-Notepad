import AINotepadCore
import AINotepadUI
import SwiftUI

// iPhone'da silinen hesabın toplantılarını taşıma teklifi (bkz. `HostedDeletedMeetings`; Mac'teki şeridin karşılığı):
// kayıt ekranında bir kez kart, "Şimdi değil"den sonra Ayarlar › Plan ve faturalandırma'da satır.

/// Kayıt ekranındaki teklif kartı: kaç toplantı olduğu, silinmeyecekleri ve "Taşı" / "Şimdi değil".
struct PhoneDeletedMeetingsCard: View {
    let deleted: HostedDeletedMeetings
    let store: PhoneStore

    var body: some View {
        if deleted.isOfferVisible {
            NoticeCard(
                severity: deleted.problem == nil ? .info : .error,
                title: Text("Silinen hesabından \(deleted.count) toplantı bu iPhone'da duruyor. Bu hesaba taşınsın mı?"),
                detail: deleted.problem.map { Text(verbatim: $0) } ?? Text("Toplantılar silinmez. Sonra Ayarlar › Plan ve faturalandırma'dan da taşıyabilirsin."),
                onDismiss: nil
            ) {
                HStack(spacing: 16) {
                    Button("Şimdi değil") { deleted.dismiss() }
                    Button("Taşı") { store.moveDeletedAccountMeetings(userID: HostedAccount.shared.signedInUserIDCache) }
                        .fontWeight(.semibold)
                }
                .appFont(size: 14, weight: .regular)
            }
        }
    }
}

/// Ayarlar › Hesap: bu iPhone'da silinen hesaptan kalan toplantılar (kartta "Şimdi değil" denmiş olsa da burada durur).
struct PhoneDeletedMeetingsSection: View {
    let deleted: HostedDeletedMeetings
    let store: PhoneStore

    var body: some View {
        if deleted.count > 0 || deleted.problem != nil {
            Section {
                Button("Bu hesaba taşı") { store.moveDeletedAccountMeetings(userID: HostedAccount.shared.signedInUserIDCache) }
                    .disabled(deleted.count == 0)
                if let problem = deleted.problem {
                    NoticeText(problem as String, severity: .error)
                }
            } header: {
                PhoneSecondaryText {
                    Text("Silinen hesabının toplantıları")
                }
            } footer: {
                PhoneSecondaryText {
                    Text("Silinen hesabından \(deleted.count) toplantı bu iPhone'da duruyor; taşıyınca bu hesapta görünür, hiçbir şey silinmez.")
                }
            }
        }
    }
}
