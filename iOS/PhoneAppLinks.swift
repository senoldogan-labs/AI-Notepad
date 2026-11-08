import AINotepadCore
import Foundation
import os

private let phoneAppLinkLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppLinks")

/// Dışarıdan gelen bağlantıyı (`gistsmith://…` ya da evrensel bağlantı `https://gistsmith.com/m/<kimlik>`; bkz.
/// `appLinkRoute`) açar: yığın baştan kurulur (bildirimdeki gibi). Kayıt bağlantısı yalnızca ana ekranı açar, kaydı
/// kullanıcı başlatır. Oturum yoksa yer yine kurulur, giriş kapısı bağlantının girişten sonra açılacağını söyler. Hesapta
/// olmayan toplantı "Toplantı bulunamadı" sayfasını açar.
@MainActor
func openPhoneAppLink(route: AppLinkRoute, router: PhoneRouter, sessions: PhoneSessionHost, account: HostedAccount) async {
    phoneAppLinkLogger.info("Bağlantı açılıyor, yer: \(String(describing: route), privacy: .private), oturum gerekli: \(account.requiresSignIn, privacy: .public)")
    router.isLinkWaitingForSignIn = account.requiresSignIn
    switch route {
    case .record:
        router.showHome()
    case .tasks:
        router.showTasks()
    case .ask:
        router.showAlone(route: .ask)
    case .insights:
        router.showAlone(route: .insights)
    case .meeting(let linkID):
        router.show(meetingID: await phoneLinkedMeetingID(linkID: linkID, sessions: sessions, account: account))
    }
}

/// Bağlantıdaki toplantının bu hesaptaki kimliği (UUID harf büyüklüğü farklı olabilir; bkz. `linkedMeetingID`). Hesabın
/// verisi yüklü değilse ya da toplantı yoksa bağlantıdaki kimlik döner: sayfa toplantı gelince onu, gelmezse "bulunamadı"
/// gösterir.
@MainActor
private func phoneLinkedMeetingID(linkID: String, sessions: PhoneSessionHost, account: HostedAccount) async -> String {
    guard !account.requiresSignIn, account.isAccountDataLoaded else {
        return linkID
    }
    let store: PhoneStore = sessions.session.store
    if !store.isLoaded {
        store.loadIdentity()
        await store.reloadAndWait()
    }
    guard let id = linkedMeetingID(linkID: linkID, meetingIDs: store.meetings.map(\.id) + store.deletedMeetings.map(\.id)) else {
        phoneAppLinkLogger.warning("Bağlantıdaki toplantı bu hesapta yok, toplantı: \(linkID, privacy: .private)")
        return linkID
    }
    return id
}
