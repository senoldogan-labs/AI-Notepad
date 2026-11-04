import AINotepadCore
import AINotepadUI
import SwiftUI

// Mac'te silinen hesabın toplantılarını taşıma teklifi (bkz. `HostedDeletedMeetings`): ana pencerenin üstünde bir kez
// şerit (açılır pencere yok), "Şimdi değil"den sonra Ayarlar › Hesap'ta satır.

/// Ana pencerenin üstündeki teklif şeridi: kaç toplantı olduğu, silinmeyecekleri ve "Taşı" / "Şimdi değil".
struct HostedDeletedMeetingsBanner: View {
    let deleted: HostedDeletedMeetings
    let onMove: @MainActor () -> Void

    var body: some View {
        NoticeBar(
            severity: deleted.problem == nil ? .info : .error,
            title: Text("Silinen hesabından \(deleted.count) toplantı bu Mac'te duruyor. Bu hesaba taşınsın mı?"),
            detail: deleted.problem.map { Text(verbatim: $0) }
                ?? Text("Toplantılar silinmez; taşıyınca bu hesabın toplantıları arasında görünür. Sonra Ayarlar › Hesap'tan da taşıyabilirsin."),
            onDismiss: nil
        ) {
            HStack(spacing: 8) {
                Button("Şimdi değil") { deleted.dismiss() }
                    .buttonStyle(.hoverCapsule)
                Button("Taşı") { onMove() }
                    .buttonStyle(.pill)
            }
        }
    }
}

/// Ayarlar › Hesap: bu Mac'te silinen hesaptan kalan toplantılar (şeritte "Şimdi değil" denmiş olsa da burada durur).
struct HostedDeletedMeetingsRow: View {
    let deleted: HostedDeletedMeetings
    let onMove: @MainActor () -> Void

    var body: some View {
        if deleted.count > 0 || deleted.problem != nil {
            SettingsRow(title: Text("Silinen hesabının toplantıları")) {
                Text("Silinen hesabından \(deleted.count) toplantı bu Mac'te duruyor. Bu hesaba taşıyınca toplantıların arasında görünür; hiçbir şey silinmez.")
                if let problem = deleted.problem {
                    NoticeText(problem as String, severity: .error)
                }
            } control: {
                Button("Bu hesaba taşı") { onMove() }
                    .disabled(deleted.count == 0)
            }
        }
    }
}
