import AINotepadCore
import Foundation
import os

private let phoneAppLinkLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppLinks")

/// Dışarıdan gelen bağlantıyı (`gistsmith://…` ya da evrensel bağlantı `https://gistsmith.com/m/<kimlik>`; bkz.
/// `appLinkRoute`) açar: yığın baştan kurulur (bildirimdeki gibi). Kayıt bağlantısı yalnızca ana ekranı açar, kaydı
/// kullanıcı başlatır. Oturum yoksa yer yine kurulur, giriş kapısı bağlantının girişten sonra açılacağını söyler. Hesapta
/// olmayan toplantı "Toplantı bulunamadı" sayfasını açar.
@MainActor
func openPhoneAppLink(route: AppLinkRoute, router: PhoneRouter, account: HostedAccount, meetingIDs: [String]) {
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
        // Toplantılar henüz okunmadıysa kimlik okununca eşleşir (`PhoneRouter.matchLinkedMeetings`).
        router.show(meetingID: linkID)
        router.matchLinkedMeetings(meetingIDs: meetingIDs)
    case .joinSharedFolder(let link):
        // Davet "Benimle paylaşılanlar"daki katılma ekranında açılır; sır bağlantının `#` parçasındadır.
        SharedFolderCenter.shared.pendingInviteLink = link
        router.showAlone(route: .sharedWithMe)
    }
}
