import AINotepadCore
import AINotepadUI
import SwiftUI

// Toplantı arşivinin düzeni (Mac'teki toplantı listesinin iPhone karşılığı): çoklu seçim, son silinenler (Mac'te Çöp
// Sepeti), bekleyen kaydı "Şimdi dene" ve seçilen kartın işareti. Liste ve klasör çipleri `MeetingsTab`'tadır.

/// Üzerinde iş süren, bu yüzden silinemeyen ve taşınamayan toplantılar: kayıtta ya da işleniyor (durumu ya da süren
/// işleme adımı), notu yazılıyor ya da bekleyenlerin kuyruğu çalışırken bekleyen kayıtlar (sunucu oturumu
/// hazırlanıyor olabilir). Saf fonksiyondur.
func phoneLockedMeetingIDs(records: [MeetingRecord], processing: Set<String>, regenerating: Set<String>, isRunningQueue: Bool) -> Set<String> {
    let busy: [String] = records
        .filter { (record: MeetingRecord) -> Bool in
            record.status == .recording || record.status == .processing || (isRunningQueue && record.status == .queued)
        }
        .map(\.id)
    return Set(busy).union(processing).union(regenerating)
}

/// Yüklü hesabın şu an kilitli toplantıları (bkz. `phoneLockedMeetingIDs`).
@MainActor
func phoneLockedMeetingIDs(store: PhoneStore, recorder: PhoneRecorder) -> Set<String> {
    phoneLockedMeetingIDs(
        records: store.meetings, processing: Set(recorder.processingSteps.keys), regenerating: store.regeneratingIDs,
        isRunningQueue: recorder.isRunningQueue
    )
}

/// Seç modundaki kart: dokununca işaretlenir (açılmaz); sağ üstte işaret dairesi. Kilitli toplantı seçilemez, soluk görünür.
struct SelectableMeetingCard: View {
    let record: MeetingRecord
    let isChecked: Bool
    let isLocked: Bool
    let onToggle: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Button(action: onToggle) {
            PhoneMeetingCard(record: record, height: 132)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .appFont(size: 24, weight: .regular)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isChecked ? appearance.accent.color : Color.black.opacity(0.25))
                        .contentTransition(.symbolEffect(.replace))
                        .padding(12)
                }
                .overlay {
                    if isChecked {
                        RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(appearance.accent.color, lineWidth: 3)
                    }
                }
                .opacity(isLocked ? 0.45 : 1)
        }
        .buttonStyle(PressableCardStyle())
        .disabled(isLocked)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}

/// Bekleyen (çevrimdışı kaydedilmiş ya da içe aktarılmış) toplantının kartı, toplantı sayfasında: nedeni ve
/// "Şimdi dene" (Mac'teki gibi; kendiliğinden yeniden denemeyi beklemeden kuyruğu çalıştırır).
struct QueuedMeetingNotice: View {
    let record: MeetingRecord
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("İşlenmeyi bekliyor", systemImage: "clock.arrow.circlepath")
                .appFont(size: 14, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
            if let notice = record.notice ?? record.failureMessage {
                Text(notice)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Şimdi dene") {
                    Task { await recorder.retryQueuedNow(meetingID: record.id) }
                }
                .buttonStyle(.accentPill)
                .controlSize(.small)
                .disabled(recorder.phase != .idle || recorder.isRunningQueue)
                if recorder.isRunningQueue {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accent.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Toplantılar listesinin sonundaki "Son silinenler" satırı (yalnız silinen toplantı varken).
struct RecentlyDeletedLink: View {
    let store: PhoneStore
    let recorder: PhoneRecorder

    var body: some View {
        NavigationLink {
            RecentlyDeletedList(store: store, recorder: recorder)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 22)
                Text("Son silinenler")
                    .appFont(size: 16, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                Text(verbatim: "\(store.deletedMeetings.count)")
                    .appFont(size: 14, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                Image(systemName: "chevron.right")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .cardSurface(cornerRadius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableCardStyle())
        .padding(.top, 10)
    }
}

/// Son silinenler (Mac'te Çöp Sepeti): silinen toplantılar `recentlyDeletedRetentionDays` gün burada kalır. Sağa
/// kaydırınca geri yükle, sola kaydırınca kalıcı sil; "Seç" ile birden çoğu birlikte. Kalıcı silme onay ister.
struct RecentlyDeletedList: View {
    let store: PhoneStore
    let recorder: PhoneRecorder
    @State private var selection: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var errors: [String] = []
    /// Kalıcı silinmesi onay bekleyen toplantılar.
    @State private var pendingPurge: Set<String>?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let items: [DeletedMeeting] = store.deletedMeetings
        let ids: Set<String> = Set(items.map(\.id))
        let effective: Set<String> = selection.intersection(ids)
        let now: Date = Date()
        List(selection: $selection) {
            let problems: [String] = errors + store.deletedLoadProblems
            if !problems.isEmpty || !store.actionProblems.isEmpty {
                Section {
                    PhoneErrorList(messages: problems)
                    PhoneDismissibleErrorList(messages: store.actionProblems) { store.dismissActionProblems() }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                ForEach(items) { (item: DeletedMeeting) in
                    DeletedMeetingRow(item: item, now: now)
                        .listRowBackground(Theme.card)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button("Geri yükle", systemImage: "arrow.uturn.backward") { restore(ids: [item.id]) }
                                .tint(appearance.accent.color)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Kalıcı olarak sil", systemImage: "trash") { pendingPurge = [item.id] }
                                .tint(.red)
                        }
                        .contextMenu {
                            Button("Geri yükle", systemImage: "arrow.uturn.backward") { restore(ids: [item.id]) }
                            Button("Kalıcı olarak sil", systemImage: "trash", role: .destructive) { pendingPurge = [item.id] }
                        }
                }
            } header: {
                if !items.isEmpty {
                    Text("Silinen toplantılar \(recentlyDeletedRetentionDays) gün burada kalır, sonra kalıcı olarak silinir.")
                        .appFont(size: 13, weight: .regular)
                        .textCase(nil)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .overlay {
            if items.isEmpty && store.deletedLoadProblems.isEmpty {
                PhoneEmptyState(
                    symbol: "trash", title: "Son silinenler boş",
                    message: "Silinen toplantılar \(recentlyDeletedRetentionDays) gün burada kalır, sonra kalıcı olarak silinir."
                ) {
                    EmptyView()
                }
            }
        }
        .navigationTitle("Son silinenler")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar(editMode.isEditing ? .hidden : .visible, for: .tabBar)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode.isEditing ? "Bitti" : "Seç") {
                        withAnimation(.smooth(duration: 0.25)) {
                            editMode = editMode.isEditing ? .inactive : .active
                            selection = []
                        }
                    }
                }
            }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(effective == ids && !ids.isEmpty ? "Seçimi kaldır" : "Tümünü seç") {
                        selection = effective == ids ? [] : ids
                    }
                    Spacer()
                    Button("Geri yükle", systemImage: "arrow.uturn.backward") { restore(ids: effective) }
                        .disabled(effective.isEmpty)
                    Button("Kalıcı olarak sil", systemImage: "trash") { pendingPurge = effective }
                        .tint(.red)
                        .disabled(effective.isEmpty)
                }
            }
        }
        .confirmationDialog(
            "Kalıcı olarak silinsin mi?",
            isPresented: Binding<Bool>(get: { pendingPurge != nil }, set: { (shown: Bool) -> Void in
                if !shown {
                    pendingPurge = nil
                }
            }),
            titleVisibility: .visible,
            presenting: pendingPurge
        ) { (targets: Set<String>) in
            Button("Kalıcı olarak sil", role: .destructive) { purge(ids: targets) }
            Button("Vazgeç", role: .cancel) {}
        } message: { (_: Set<String>) in
            Text("Not, transkript ve ses silinir; geri alınamaz.")
        }
        .task {
            await store.reloadDeletedAndWait()
            store.purgeExpiredDeleted(now: Date())
        }
        .refreshable { await store.reloadDeletedAndWait() }
        .onChange(of: items.isEmpty) { (_: Bool, isEmpty: Bool) in
            if isEmpty {
                editMode = .inactive
            }
        }
    }

    /// Toplantıları geri yükler; bekleyen kayıt geri geldiyse kuyruk çalışır (sunucuda işlensin).
    private func restore(ids: Set<String>) {
        let result: (restored: [MeetingRecord], errors: [String]) = store.restoreDeleted(ids: ids)
        withAnimation(.smooth(duration: 0.25)) {
            errors = result.errors
            selection.subtract(result.restored.map(\.id))
        }
        if result.restored.contains(where: { $0.status == .queued }) {
            Task { await recorder.runQueue() }
        }
    }

    private func purge(ids: Set<String>) {
        withAnimation(.smooth(duration: 0.25)) {
            errors = store.purgeDeleted(ids: ids)
            selection.subtract(ids)
        }
    }
}

/// Son silinenlerdeki satır: kapak, ad, toplantı tarihi ve kalıcı silinmeye kalan gün.
private struct DeletedMeetingRow: View {
    let item: DeletedMeeting
    let now: Date

    var body: some View {
        let days: Int = deletedMeetingDaysLeft(deletedAt: item.deletedAt, now: now, retentionDays: recentlyDeletedRetentionDays)
        let date: String = item.record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
        HStack(spacing: 12) {
            CoverBackground(seed: item.record.id)
                .overlay { CoverScrim() }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.record.note?.title ?? item.record.title)
                    .appFont(size: 16, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(verbatim: "\(date) · \(String(localized: "\(days) gün kaldı"))")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
