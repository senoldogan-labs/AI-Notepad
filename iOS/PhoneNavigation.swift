import AINotepadCore
import AINotepadUI
import SwiftUI

/// Gezinme yığınındaki sayfa (bkz. `PhoneRoute`): her sayfa ana ekranın üstüne açılır, geri ana ekrana ya da gelinen
/// sayfaya döner.
struct PhoneDestination: View {
    let route: PhoneRoute
    let store: PhoneStore
    let recorder: PhoneRecorder
    let ask: PhoneAsk
    let router: PhoneRouter
    let player: MeetingAudioPlayer
    let calendar: PhoneCalendar
    let account: HostedAccount
    let crashReports: CrashReportCenter
    /// Hesabın verisine yazan bir iş sürüyor (bkz. `phoneOpenWriters`): çıkış, hesap silme ve kurulum kapalı.
    let isMeetingInFlight: Bool
    /// Toplantı sayfasındaki ⋯ › Tarif uygula: seçilen tarifi toplantıya (kimliği) Sor'da uygular.
    let onRunRecipe: @MainActor (Recipe, String) -> Void

    var body: some View {
        switch route {
        case .meeting(let id):
            PhoneMeetingDestination(meetingID: id, store: store, recorder: recorder, router: router, player: player, ask: ask) { (recipe: Recipe) -> Void in
                onRunRecipe(recipe, id)
            }
        case .tasks:
            TasksTab(store: store, router: router)
                .modifier(PhoneMiniPlayerInset(player: player, store: store, router: router, isHidden: false))
        case .search:
            PhoneSearchScreen(store: store, router: router, ask: ask)
        case .library(let scope):
            MeetingsLibraryScreen(store: store, recorder: recorder, router: router, player: player, initialScope: scope)
        case .people:
            PhonePeopleList(store: store, router: router)
        case .insights:
            PhoneInsightsScreen(store: store)
        case .recentlyDeleted:
            RecentlyDeletedList(store: store, recorder: recorder)
        case .ask:
            AskTab(ask: ask, store: store, router: router)
        case .askConversation:
            AskConversationView(ask: ask, store: store, router: router)
        case .askHistory:
            AskHistoryScreen(ask: ask, router: router)
        case .settings:
            PhoneSettingsTab(store: store, ask: ask, calendar: calendar, account: account, isMeetingInFlight: isMeetingInFlight, crashReports: crashReports)
        case .account:
            PhoneAccountScreen(account: account, isMeetingInFlight: isMeetingInFlight, store: store)
        case .profile:
            PhoneProfileScreen(store: store, account: account)
        case .templateGallery:
            TemplateGalleryScreen()
        case .templatePreview(let id):
            if let template = templateGallery().first(where: { $0.id == id }) {
                TemplatePreviewScreen(template: template, router: router)
            }
        case .customTemplate:
            CustomTemplateScreen()
        case .assistantAccess:
            PhoneAssistantScreen()
        case .connections:
            PhoneConnectionsScreen()
        }
    }
}

/// Toplantı sayfası ya da toplantı yoksa nedeni: son silinenlerdeyse geri yükleme (Sor'daki kaynak, görev ya da kişi
/// buraya götürdü), hiç yoksa "bulunamadı" (ör. Mac'ten silindi). Silme onaydan sonra toplantıyı son silinenlere taşır
/// ve sayfayı kapatır; olmazsa neden sayfanın üstünde görünür.
private struct PhoneMeetingDestination: View {
    let meetingID: String
    let store: PhoneStore
    let recorder: PhoneRecorder
    let router: PhoneRouter
    let player: MeetingAudioPlayer
    /// Sor: tarifler ve toplantı sayfasının "Bir şey sor" çubuğu.
    let ask: PhoneAsk
    let onRunRecipe: @MainActor (Recipe) -> Void
    /// Silme ya da geri yükleme hataları.
    @State private var errors: [String] = []

    var body: some View {
        // Sayfa notu konuşmacı adlarıyla gösterir (saklı not genel etiketleri korur).
        Group {
            if let record = store.namedMeetings().first(where: { $0.id == meetingID }) {
                MeetingReadView(
                    record: record, store: store, player: player, isRecording: recorder.phase != .idle,
                    processingStep: recorder.processingSteps[record.id], ask: ask, openingSource: router.openingSource
                ) {
                    errors = phoneTrashMeetings(ids: [meetingID], store: store, recorder: recorder, player: player, router: router)
                } onReprocess: {
                    try recorder.reprocess(meetingID: meetingID)
                } onRunRecipe: { (recipe: Recipe) -> Void in
                    onRunRecipe(recipe)
                } onSourceShown: {
                    router.openingSource = nil
                }
            } else if store.deletedMeetings.contains(where: { $0.id == meetingID }) {
                PhoneEmptyState(symbol: "trash", title: "Bu toplantı silindi", message: "Son silinenler'den geri yükleyebilirsin.") {
                    Button("Geri yükle", systemImage: "arrow.uturn.backward") { restore() }
                        .buttonStyle(.accentPill)
                }
                .background(Theme.background)
            } else {
                PhoneEmptyState(symbol: "doc.questionmark", title: "Toplantı bulunamadı", message: "Bu toplantı silinmiş olabilir.") {
                    EmptyView()
                }
                .background(Theme.background)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !errors.isEmpty {
                PhoneErrorList(messages: errors)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.background)
            }
        }
    }

    /// Silinen toplantıyı geri yükler; bekleyen kayıt geri geldiyse kuyruk çalışır.
    private func restore() {
        let result: (restored: [MeetingRecord], errors: [String]) = store.restoreDeleted(ids: [meetingID])
        errors = result.errors
        if result.restored.contains(where: { $0.status == .queued }) {
            Task { await recorder.runQueue() }
        }
    }
}

/// Toplantıları son silinenlere taşır: çalan toplantı önce durur, silinenlerin açık sayfaları kapanır. Silinemeyenlerin
/// nedenleri döner (üzerinde iş süren toplantı silinmez).
@MainActor
func phoneTrashMeetings(ids: Set<String>, store: PhoneStore, recorder: PhoneRecorder, player: MeetingAudioPlayer, router: PhoneRouter) -> [String] {
    if let playing = player.meetingID, ids.contains(playing) {
        player.stop()
        store.playingMeetingID = nil
    }
    let errors: [String] = store.trashMeetings(ids: ids, locked: phoneLockedMeetingIDs(store: store, recorder: recorder), now: Date())
    let remaining: Set<String> = Set(store.meetings.map(\.id))
    router.closeMeetings(ids: ids.subtracting(remaining))
    return errors
}

/// Bir toplantı çalarken sayfanın altında mini çalar (ana ekran, kitaplık, arama, görevler); toplantı sayfasında çalma
/// sağ üstteki düğmeyle yönetilir. Seç modunda alt çubuk onun yerini alır.
struct PhoneMiniPlayerInset: ViewModifier {
    let player: MeetingAudioPlayer
    let store: PhoneStore
    let router: PhoneRouter
    let isHidden: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.meetingID != nil, !isHidden {
                MiniPlayer(player: player, store: store, router: router)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}
