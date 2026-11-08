import AINotepadCore
import Foundation
import os

private let macAppLinkLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppLinks")

/// `gistsmith://…` bağlantısını (yalnız Gistsmith kaydeder; bkz. `appLinkRoute`) ana pencerede açar. Kayıt bağlantısı Ana
/// sayfayı açar, kaydı kullanıcı başlatır. Oturum yoksa yer yine seçilir, giriş kapısı bağlantının girişten sonra
/// açılacağını söyler. Hesapta olmayan toplantı "Toplantı bulunamadı" gösterir.
@MainActor
func openMacAppLink(route: AppLinkRoute, router: MainWindowRouter, meetingIDs: [String]) {
    macAppLinkLogger.info("Bağlantı açılıyor, yer: \(String(describing: route), privacy: .private), oturum gerekli: \(isSignInRequired(), privacy: .public)")
    router.isLinkWaitingForSignIn = isSignInRequired()
    switch route {
    case .record:
        openMainWindow(router: router, section: .home)
    case .tasks:
        openMainWindow(router: router, section: .tasks)
    case .ask:
        openMainWindow(router: router, section: .ask)
    case .insights:
        openMainWindow(router: router, section: .insights)
    case .meeting(let linkID):
        // Toplantılar henüz okunmadıysa kimlik okununca eşleşir (`matchLinkedMeeting`).
        openMeetingInMainWindow(router: router, meetingID: linkID)
        matchLinkedMeeting(router: router, meetingIDs: meetingIDs)
    case .joinSharedFolder(let link):
        // Davet "Benimle paylaşılanlar"daki katılma ekranında açılır; sır bağlantının `#` parçasındadır.
        router.pendingInviteLink = link
        openMainWindow(router: router, section: .shared)
    }
}

/// Seçili toplantının kimliğini cihazdaki toplantınınkiyle değiştirir (bağlantıdaki UUID'nin harf büyüklüğü farklı
/// olabilir; bkz. `linkedMeetingID`): listedeki vurgu ve silme seçimi tutsun. Bağlantı açılınca ve toplantılar okunup
/// değişince çağrılır; eşleşmeyen kimlik kalır ("Toplantı bulunamadı").
@MainActor
func matchLinkedMeeting(router: MainWindowRouter, meetingIDs: [String]) {
    guard let selected = router.selectedMeetingID, let found = linkedMeetingID(linkID: selected, meetingIDs: meetingIDs), found != selected else {
        return
    }
    router.selectedMeetingID = found
}
