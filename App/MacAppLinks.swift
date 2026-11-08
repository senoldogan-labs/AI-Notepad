import AINotepadCore
import Foundation
import os

private let macAppLinkLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AppLinks")

/// `gistsmith://…` bağlantısını (yalnız Gistsmith kaydeder; bkz. `appLinkRoute`) ana pencerede açar. Kayıt bağlantısı Ana
/// sayfayı açar, kaydı kullanıcı başlatır. Oturum yoksa yer yine seçilir, giriş kapısı bağlantının girişten sonra
/// açılacağını söyler. Hesapta olmayan toplantı "Toplantı bulunamadı" gösterir.
@MainActor
func openMacAppLink(route: AppLinkRoute, router: MainWindowRouter, model: AppModel) async {
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
        openMeetingInMainWindow(router: router, meetingID: await macLinkedMeetingID(linkID: linkID, model: model))
    }
}

/// Bağlantıdaki toplantının bu hesaptaki kimliği (UUID harf büyüklüğü farklı olabilir; bkz. `linkedMeetingID`). Oturum
/// yoksa, hesabın verisi hazır değilse ya da toplantı yoksa bağlantıdaki kimlik döner: Toplantılar toplantı gelince onu,
/// gelmezse "bulunamadı" gösterir.
@MainActor
private func macLinkedMeetingID(linkID: String, model: AppModel) async -> String {
    // Oturum yokken toplantılar okunmaz (`meetingsForIntents` hazır değil der): kimlik girişten sonra açılır.
    guard !isSignInRequired() else {
        return linkID
    }
    let meetings: [MeetingRecord]
    do {
        meetings = try await model.meetingsForIntents()
    } catch {
        macAppLinkLogger.warning("Bağlantıdaki toplantı aranamadı, kimlik olduğu gibi açılıyor, hata: \(String(describing: error), privacy: .public)")
        return linkID
    }
    guard let id = linkedMeetingID(linkID: linkID, meetingIDs: meetings.map(\.id)) else {
        macAppLinkLogger.warning("Bağlantıdaki toplantı bu hesapta yok, toplantı: \(linkID, privacy: .private)")
        return linkID
    }
    return id
}
