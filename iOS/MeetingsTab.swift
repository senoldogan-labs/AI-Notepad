import AINotepadCore
import AINotepadUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

/// Toplantı kitaplığı (ana ekranın kitaplık sayfasından): tarihe göre gruplanmış film gradyanlı kartlar ve arama; uzun
/// basınca Markdown kopyası, klasöre taşıma ve silme. Dokununca toplantı sayfası. Sağ üstteki "Seç" (Mac'teki gibi) birden
/// çok toplantıyı birlikte siler ya da klasöre taşır; silinen toplantı Son silinenler'e gider (çiplerin sonundaki çöp
/// çipi). Klasör çiplerinde "+" boş klasör açar, uzun basınca klasör silinir (toplantılar kalır).
struct MeetingsLibraryScreen: View {
    let store: PhoneStore
    /// İçe aktarma durumu ve bekleyen kaydı yeniden deneme için.
    let recorder: PhoneRecorder
    let router: PhoneRouter
    let player: MeetingAudioPlayer
    /// Kitaplığın açıldığı kapsam (tüm toplantılar ya da kitaplık sayfasında seçilen klasör).
    let initialScope: MeetingListScope
    @Environment(PhoneImportState.self) private var imports: PhoneImportState
    @State private var query: String = ""
    /// Son biten aramanın eşleşen toplantıları.
    @State private var matchedIDs: Set<String> = []
    /// Çiplerle seçilen süzgeç (Mac'teki Hepsi / Görevlerim / Hatalı) ya da klasör; seçilmediyse açılış kapsamı.
    @State private var selectedScope: MeetingListScope?
    @State private var pendingDelete: MeetingRecord?
    /// Silme, geri yükleme ve klasöre taşıma hataları.
    @State private var libraryErrors: [String] = []
    /// "Seç" modu: kartlara dokunmak toplantıyı açmaz, işaretler; altta tümünü seç, klasöre taşı ve sil.
    @State private var isSelecting: Bool = false
    @State private var checked: Set<String> = []
    @State private var isConfirmingBulkDelete: Bool = false
    /// Yeni klasörün adı soruluyor: boş klasör (çiplerdeki "+") ya da seçilenleri taşımak için.
    @State private var newFolderRequest: NewFolderRequest?
    /// Silinmesi onay bekleyen klasör.
    @State private var pendingFolderDelete: String?
    /// Sıkı liste: büyük kartlar yerine satırlar (ekrana dört kart sığıyordu); seçim saklanır.
    @AppStorage(PhoneSettingsKey.libraryCompact) private var isCompact: Bool = false
    /// Notlardaki konuşmacı etiketleri adlarla gösterilir; adı kullanıcının adı olan konuşmacının görevleri onundur.
    private var userName: String { store.userName }
    /// Gösterilen kapsam.
    private var scope: MeetingListScope { selectedScope ?? initialScope }

    var body: some View {
        // Kartlar ve sayfa notu konuşmacı adlarıyla gösterir (saklı not genel etiketleri korur, değişiklikler kimlikle
        // saklı kayda yapılır).
        let meetings: [MeetingRecord] = store.namedMeetings()
        let scoped: [MeetingRecord] = meetingsInScope(records: meetings, scope: scope, userName: userName)
        // Arama önbellekli ve ana iş parçacığının dışında (bkz. `PhoneSearchScreen`); yeni sonuç gelene dek eskisi görünür.
        let trimmedQuery: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown: [MeetingRecord] = trimmedQuery.isEmpty ? scoped : scoped.filter { matchedIDs.contains($0.id) }
        let sections: [MeetingSection] = meetingSections(records: shown, now: Date(), calendar: .current, locale: interfaceLocale())
        let locked: Set<String> = phoneLockedMeetingIDs(store: store, recorder: recorder)
        // Yalnız görünen işaretliler sayılır ve işlenir (Mac'teki gibi): arama, klasör ya da süzgeç değişince gizlenen
        // işaretliler işlemden çıkar.
        let visibleIDs: Set<String> = Set(sections.flatMap(\.meetings).map(\.id))
        let effective: Set<String> = checked.intersection(visibleIDs)
        let statusMessages: [String] = store.loadProblems + recorder.importErrors + libraryErrors + [imports.pickError].compactMap { $0 }
        // Listenin üstündeki hata ve içe aktarma satırları: varken "Henüz toplantı yok" sahnesi gösterilmez (bkz.
        // `emptyOverlay`).
        let hasStatusRows: Bool = !statusMessages.isEmpty || !store.actionProblems.isEmpty || recorder.importingCount > 0 || imports.isLoadingVideos
        ScrollView {
            LazyVStack(alignment: .leading, spacing: isCompact ? 2 : 14) {
                PhoneErrorList(messages: statusMessages)
                PhoneDismissibleErrorList(messages: store.actionProblems) { store.dismissActionProblems() }
                if recorder.importingCount > 0 || imports.isLoadingVideos {
                    ImportProgressRow()
                }
                if !store.meetings.isEmpty {
                    // Son silinenler çipi Seç modunda gizli (işaretlerken başka sayfaya geçilmesin).
                    MeetingScopeChips(
                        records: meetings, folders: store.folders, userName: userName,
                        selection: Binding<MeetingListScope>(get: { scope }, set: { (value: MeetingListScope) -> Void in selectedScope = value }),
                        deletedCount: isSelecting ? 0 : store.deletedMeetings.count,
                        deletedDestination: RecentlyDeletedList(store: store, recorder: recorder),
                        onCreateFolder: { newFolderRequest = .create },
                        onDeleteFolder: { (name: String) -> Void in pendingFolderDelete = name },
                        canDeleteFolder: { (name: String) -> Bool in
                            !meetingsInFolder(records: store.meetings, folder: name).contains { locked.contains($0.id) }
                        }
                    )
                }
                ForEach(sections) { (section: MeetingSection) in
                    Text(section.title)
                        .appFont(size: 13, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 10)
                    ForEach(section.meetings, id: \.id) { (record: MeetingRecord) in
                        card(record: record, locked: locked)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .overlay {
            emptyOverlay(hasResults: !sections.isEmpty, hasStatusRows: hasStatusRows)
        }
        .background(Theme.background)
        .navigationTitle(libraryTitle)
        .searchable(text: $query, prompt: "Toplantılarda ara")
        .task(id: PhoneSearchRequest(query: trimmedQuery, stamps: scoped.map(searchStamp(record:)))) {
            guard !trimmedQuery.isEmpty else {
                matchedIDs = []
                return
            }
            do {
                try await Task.sleep(for: searchDebounce)
            } catch {
                return
            }
            let hits: [MeetingSearchHit] = await store.searchCache.search(records: scoped, query: trimmedQuery)
            guard !Task.isCancelled else {
                return
            }
            matchedIDs = Set(hits.map(\.meetingID))
        }
        // Çalan toplantı altta (seç modunda alt çubuk onun yerini alır, Fotoğraflar'daki gibi).
        .modifier(PhoneMiniPlayerInset(player: player, store: store, router: router, isHidden: isSelecting))
        .toolbar {
            if isSelecting {
                // Seç modundan çıkış: iOS 26'nın onay düğmesi (vurgulu onay işareti; erişilebilirlik adı "Bitti").
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .confirm) {
                        setSelecting(false)
                    } label: {
                        Label("Bitti", systemImage: "checkmark")
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    selectionBar(effective: effective, selectable: visibleIDs.subtracting(locked), locked: locked)
                }
            } else {
                if !store.meetings.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { isCompact.toggle() }
                        } label: {
                            Label(isCompact ? "Kart görünümü" : "Liste görünümü", systemImage: isCompact ? "rectangle.grid.1x2" : "list.bullet")
                        }
                    }
                    // Simge (erişilebilirlik adı "Seç").
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Seç", systemImage: "checkmark.circle") { setSelecting(true) }
                    }
                }
            }
        }
        .confirmationDialog(
            Text("\(effective.count) toplantı silinsin mi?"), isPresented: $isConfirmingBulkDelete, titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) { deleteChecked(ids: effective) }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Son silinenler'e taşınır; \(recentlyDeletedRetentionDays) gün içinde geri yükleyebilirsin.")
        }
        .confirmationDialog(
            Text("\"\(pendingFolderDelete ?? "")\" klasörü silinsin mi?"),
            isPresented: Binding<Bool>(get: { pendingFolderDelete != nil }, set: { (shown: Bool) -> Void in
                if !shown {
                    pendingFolderDelete = nil
                }
            }),
            titleVisibility: .visible,
            presenting: pendingFolderDelete
        ) { (name: String) in
            Button("Klasörü sil", role: .destructive) { deleteFolder(name: name) }
            Button("Vazgeç", role: .cancel) {}
        } message: { (_: String) in
            Text("Toplantılar silinmez, klasörsüz kalır.")
        }
        .sheet(item: $newFolderRequest) { (request: NewFolderRequest) in
            PhoneTextEntrySheet(
                title: "Yeni klasör", placeholder: "Klasör adı", actionTitle: request.actionTitle, initialText: ""
            ) { (name: String) -> Void in
                createFolder(name: name, request: request)
            }
        }
        .refreshable { await store.reloadAndWait() }
        // Uzun basınca silme: ekranın ortasında uyarı (kartın üstünde açılan menü listeye bağlıydı, sayfadayken görünmüyordu).
        .modifier(MeetingDeleteConfirmation(pending: $pendingDelete) { (record: MeetingRecord) -> Void in delete(record: record) })
    }

    /// Liste kartı: seç modunda işaretlenir; değilse dokununca açılır, uzun basınca menü (Mac'teki satır menüsü gibi).
    @ViewBuilder
    private func card(record: MeetingRecord, locked: Set<String>) -> some View {
        if isSelecting {
            SelectableMeetingCard(record: record, isChecked: checked.contains(record.id), isLocked: locked.contains(record.id)) {
                toggle(id: record.id)
            }
        } else {
            NavigationLink(value: PhoneRoute.meeting(record.id)) {
                if isCompact {
                    HomeMeetingRow(record: record)
                } else {
                    PhoneMeetingCard(record: record, height: 132)
                }
            }
            .buttonStyle(PressableCardStyle())
            .contextMenu {
                Button("Markdown olarak kopyala", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = meetingMarkdown(record: record)
                    recordFeatureUsage(feature: .export(.copyMarkdown))
                }
                if record.status == .queued {
                    Button("Şimdi dene", systemImage: "arrow.clockwise") {
                        Task { await recorder.retryQueuedNow(meetingID: record.id) }
                    }
                    .disabled(recorder.phase != .idle || recorder.isRunningQueue)
                }
                Menu("Klasöre taşı", systemImage: "folder") {
                    moveMenuItems(ids: [record.id])
                }
                .disabled(locked.contains(record.id))
                Button("Seç", systemImage: "checkmark.circle") {
                    setSelecting(true)
                    checked = locked.contains(record.id) ? [] : [record.id]
                }
                Divider()
                Button("Sil", systemImage: "trash", role: .destructive) { pendingDelete = record }
                    .disabled(locked.contains(record.id))
            }
        }
    }

    /// "Klasöre taşı" menüsünün öğeleri: klasörler (boş olanlar dahil), yeni klasör ve klasörden çıkarma.
    @ViewBuilder
    private func moveMenuItems(ids: Set<String>) -> some View {
        ForEach(store.folders) { (folder: FolderSummary) in
            Button(folder.name, systemImage: "folder") { move(ids: ids, folder: folder.name) }
        }
        Button("Yeni klasör…", systemImage: "folder.badge.plus") { newFolderRequest = .move(ids) }
        Button("Klasörden çıkar", systemImage: "folder.badge.minus") { move(ids: ids, folder: nil) }
    }

    /// Seç modunun alt çubuğu: tümünü seç, sayı, klasöre taşı ve sil.
    @ViewBuilder
    private func selectionBar(effective: Set<String>, selectable: Set<String>, locked: Set<String>) -> some View {
        let allChecked: Bool = !selectable.isEmpty && effective.isSuperset(of: selectable)
        Button(allChecked ? "Seçimi kaldır" : "Tümünü seç") {
            checked = allChecked ? [] : selectable
        }
        Spacer()
        Text("\(effective.count) seçili")
            .appFont(size: 13, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(Theme.muted)
            .contentTransition(.numericText())
        Spacer()
        Menu {
            moveMenuItems(ids: effective)
        } label: {
            Label("Klasöre taşı", systemImage: "folder")
        }
        .disabled(effective.isEmpty)
        Button("Sil", systemImage: "trash") { isConfirmingBulkDelete = true }
            .disabled(effective.isEmpty)
    }

    /// Boş durumlar: hiç toplantı yok (son silinenler varsa oraya bağlantı), boş klasör ya da eşleşmeyen arama/süzgeç.
    /// Toplantı yokken üstte hata ya da içe aktarma satırı varsa sahne gösterilmez: tam boy kaydırma görünümü o satırların
    /// üstüne biniyor, kapatma düğmesine dokunuşu ve aşağı çekip yenilemeyi yutuyordu.
    @ViewBuilder
    private func emptyOverlay(hasResults: Bool, hasStatusRows: Bool) -> some View {
        if store.meetings.isEmpty {
            if !hasStatusRows {
                emptyArchiveScene
            }
        } else if !hasResults {
            if case .folder = scope, query.trimmingCharacters(in: .whitespaces).isEmpty {
                PhoneEmptyState(symbol: "folder", title: "Bu klasör boş", message: "Toplantı sayfasındaki \"Klasöre taşı\" ile buraya ekle.") {
                    Button("Tüm toplantılar") { selectedScope = .filter(.all) }
                        .buttonStyle(.accentPill)
                }
            } else {
                PhoneEmptyState(symbol: "magnifyingglass", title: "Eşleşen toplantı yok", message: "Başka bir kelimeyle ara.") {
                    EmptyView()
                }
            }
        }
    }

    /// Hiç toplantı yok: kayda geçiş ve varsa son silinenler.
    private var emptyArchiveScene: some View {
        PhoneEmptyScene(
            symbol: "waveform", palette: .sunset, title: "Henüz toplantı yok",
            message: "İlk toplantını kaydet; not, görevler ve transkript burada hazır olur."
        ) {
            VStack(spacing: 12) {
                Button("Kaydı başlat", systemImage: "mic.fill") { router.showHome() }
                    .buttonStyle(.accentPill)
                    .controlSize(.large)
                if !store.deletedMeetings.isEmpty {
                    NavigationLink {
                        RecentlyDeletedList(store: store, recorder: recorder)
                    } label: {
                        Label("Son silinenler", systemImage: "trash")
                            .appFont(size: 15, weight: .medium)
                    }
                }
            }
        }
    }

    private func setSelecting(_ selecting: Bool) {
        withAnimation(.smooth(duration: 0.25)) {
            isSelecting = selecting
            checked = []
            libraryErrors = []
        }
    }

    private func toggle(id: String) {
        withAnimation(.snappy(duration: 0.2)) {
            if checked.contains(id) {
                checked.remove(id)
            } else {
                checked.insert(id)
            }
        }
    }

    /// Toplantıları son silinenlere taşır (bkz. `phoneTrashMeetings`); hatalar döner.
    private func trash(ids: Set<String>) -> [String] {
        phoneTrashMeetings(ids: ids, store: store, recorder: recorder, player: player, router: router)
    }

    /// Tek toplantıyı siler (uzun basma menüsü ya da toplantı sayfası, onaydan sonra).
    private func delete(record: MeetingRecord) {
        withAnimation(.snappy(duration: 0.3)) {
            libraryErrors = trash(ids: [record.id])
        }
    }

    /// İşaretlileri siler; silinemeyenler işaretli kalır, hataları listenin üstünde görünür (Mac'teki gibi).
    private func deleteChecked(ids: Set<String>) {
        withAnimation(.snappy(duration: 0.3)) {
            let errors: [String] = trash(ids: ids)
            checked = ids.intersection(Set(store.meetings.map(\.id)))
            libraryErrors = errors
            if errors.isEmpty {
                isSelecting = false
                checked = []
            }
        }
    }

    /// Toplantıları klasöre taşır (nil: klasörden çıkarır); seç modundaysa başarıyla biter.
    private func move(ids: Set<String>, folder: String?) {
        let errors: [String] = store.moveMeetings(ids: ids, to: folder, locked: phoneLockedMeetingIDs(store: store, recorder: recorder))
        withAnimation(.smooth(duration: 0.25)) {
            libraryErrors = errors
            if isSelecting, errors.isEmpty {
                isSelecting = false
                checked = []
            }
        }
    }

    /// Yeni klasör: boş olarak oluşturulur; seçilenler için açıldıysa onlar da oraya taşınır.
    private func createFolder(name: String, request: NewFolderRequest) {
        store.createFolder(name: name)
        if case .move(let ids) = request {
            move(ids: ids, folder: name)
        }
    }

    /// Klasörü siler (toplantılar kalır, klasörsüz olur); o klasör açıksa liste Tümü'ne döner.
    private func deleteFolder(name: String) {
        store.deleteFolder(name: name, locked: phoneLockedMeetingIDs(store: store, recorder: recorder))
        if case .folder(let selected) = scope, selected.caseInsensitiveCompare(name) == .orderedSame {
            selectedScope = .filter(.all)
        }
    }

    /// Başlık: klasörden açıldıysa klasörün adı, yoksa "Tüm toplantılar".
    private var libraryTitle: Text {
        if case .folder(let name) = initialScope {
            return Text(verbatim: name)
        }
        return Text("Tüm toplantılar")
    }
}

/// Yeni klasör adı sorulma nedeni: boş klasör oluşturmak ya da verilen toplantıları yeni klasöre taşımak.
private enum NewFolderRequest: Identifiable {
    case create
    case move(Set<String>)

    var id: String {
        switch self {
        case .create: "create"
        case .move(let ids): "move." + ids.sorted().joined(separator: ",")
        }
    }

    /// Ad sayfasının eylem düğmesi.
    var actionTitle: LocalizedStringKey {
        switch self {
        case .create: "Oluştur"
        case .move: "Taşı"
        }
    }
}

/// "Sesi sil" onayı (sayfanın içinde, Mac'teki gibi): kalıcıdır; metin ve not kalır.
private struct AudioDeleteConfirmation: View {
    let onConfirm: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ses kalıcı olarak silinsin mi? Metin ve not kalır; geri alınamaz.", systemImage: "speaker.slash")
                .appFont(size: 14, weight: .medium)
                .foregroundStyle(NoticeSeverity.error.tint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Sesi sil", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(NoticeSeverity.error.tint)
                Button("Vazgeç", action: onCancel)
                    .buttonStyle(.bordered)
            }
            .appFont(size: 14, weight: .semibold)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoticeSeverity.error.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "Toplantı silinsin mi?" uyarısı: `pending` doluyken ekranın ortasında açılır; "Sil" onaylar, "Vazgeç" kapatır. Uyarı
/// bağlandığı görünüm ekrandayken görünür: listede liste, toplantı sayfasında sayfa kendi uyarısını taşır.
struct MeetingDeleteConfirmation: ViewModifier {
    @Binding var pending: MeetingRecord?
    let onConfirm: @MainActor (MeetingRecord) -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Toplantı silinsin mi?",
            isPresented: Binding<Bool>(get: { pending != nil }, set: { (shown: Bool) -> Void in
                if !shown {
                    pending = nil
                }
            }),
            presenting: pending
        ) { (record: MeetingRecord) in
            Button("Sil", role: .destructive) { onConfirm(record) }
            Button("Vazgeç", role: .cancel) {}
        } message: { (_: MeetingRecord) in
            Text("Son silinenler'e taşınır; \(recentlyDeletedRetentionDays) gün içinde geri yükleyebilirsin.")
        }
    }
}

/// Toplantı listesinin kapsamı: süzgeç ya da klasör.
enum MeetingListScope: Hashable {
    case filter(MeetingListFilter)
    case folder(String)
}

/// Kapsama uyan toplantılar, sıra korunur. Saf fonksiyondur.
func meetingsInScope(records: [MeetingRecord], scope: MeetingListScope, userName: String) -> [MeetingRecord] {
    switch scope {
    case .filter(let filter): filterMeetings(records: records, listFilter: filter, userName: userName)
    case .folder(let name): meetingsInFolder(records: records, folder: name)
    }
}

/// Listenin üstündeki çipler: Tümü, Görevlerim, Hatalı (varsa), klasörler (boş olanlar dahil, sayılarıyla), yeni klasör
/// ("+") ve silinen toplantı varken sonda Son silinenler (çöp simgesi ve sayı; dokununca o sayfa); yatay kayar. Klasöre
/// uzun basınca silinir (toplantılar kalır). Seçilen süzgeç boşalırsa ya da klasör artık yoksa Tümü'ne döner (boş klasör
/// seçili kalır: "Bu klasör boş").
private struct MeetingScopeChips: View {
    let records: [MeetingRecord]
    let folders: [FolderSummary]
    let userName: String
    @Binding var selection: MeetingListScope
    /// Son silinenlerdeki toplantı sayısı; 0 ise çip görünmez.
    let deletedCount: Int
    /// Çipin açtığı Son silinenler sayfası.
    let deletedDestination: RecentlyDeletedList
    let onCreateFolder: @MainActor () -> Void
    let onDeleteFolder: @MainActor (String) -> Void
    /// İçinde üzerinde iş süren toplantı olan klasör silinemez (o toplantı klasörden çıkarılamaz).
    let canDeleteFolder: @MainActor (String) -> Bool

    var body: some View {
        let mine: Int = filterMeetings(records: records, listFilter: .myTasks, userName: userName).count
        let problems: Int = filterMeetings(records: records, listFilter: .problems, userName: userName).count
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(scope: .filter(.all), title: Text("Tümü"), systemImage: nil)
                if mine > 0 {
                    chip(scope: .filter(.myTasks), title: Text("Görevlerim \(mine)"), systemImage: "checkmark.circle")
                }
                if problems > 0 {
                    chip(scope: .filter(.problems), title: Text("Sorunlu \(problems)"), systemImage: "exclamationmark.triangle")
                }
                ForEach(folders) { (folder: FolderSummary) in
                    chip(scope: .folder(folder.name), title: Text(verbatim: "\(folder.name) \(folder.count)"), systemImage: "folder")
                        .contextMenu {
                            Button("Klasörü sil", systemImage: "trash", role: .destructive) { onDeleteFolder(folder.name) }
                                .disabled(!canDeleteFolder(folder.name))
                        }
                }
                Button(action: onCreateFolder) {
                    Image(systemName: "folder.badge.plus")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Yeni klasör")
                // Süzgeç değil, ayrı sayfa: seçili görünmez, soluk renkte.
                if deletedCount > 0 {
                    NavigationLink {
                        deletedDestination
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").appFont(size: 12, weight: .semibold)
                            Text(verbatim: "\(deletedCount)").appFont(size: 14, weight: .medium)
                        }
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Son silinenler")
                    .accessibilityValue(Text(verbatim: "\(deletedCount)"))
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -20)
        .onChange(of: isGone(scope: selection)) { (_: Bool, gone: Bool) in
            if gone {
                selection = .filter(.all)
            }
        }
    }

    /// Seçilen kapsam artık gösterilemez: süzgeç boşaldı ya da klasör silindi.
    private func isGone(scope: MeetingListScope) -> Bool {
        switch scope {
        case .filter(.all):
            false
        case .filter(let filter):
            filterMeetings(records: records, listFilter: filter, userName: userName).isEmpty
        case .folder(let name):
            !folders.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    private func chip(scope: MeetingListScope, title: Text, systemImage: String?) -> some View {
        let isSelected: Bool = selection == scope
        return Button {
            withAnimation(.smooth(duration: 0.2)) { selection = scope }
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).appFont(size: 12, weight: .semibold)
                }
                title.appFont(size: 14, weight: isSelected ? .semibold : .medium)
            }
            .monospacedDigit()
            .foregroundStyle(isSelected ? Theme.onPrimary : Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? AnyShapeStyle(Theme.primary) : AnyShapeStyle(Theme.card), in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Toplantı sayfasının sekmesi.
private enum MeetingPane: Hashable {
    case summary
    case transcript
}

/// Toplantı sayfası: sakin başlık (tarih, başlık, tek satır bilgi), Özet (not bölümleri: görevler, konu akışı, kararlar,
/// açık konular, işaretli anlar; özet, kendi notların, not düzenleme; kapalı "Ayrıntılar"da konuşma payları ve sözlük) ve
/// Transkript (konuşmacılı paragraflar; çalarken o anki kelime vurgulanır, dokununca oradan çalar). Sağ üstte Dinle ve ⋯
/// (paylaş, dışa aktar, gönder, düzenle, yeniden yaz, sil…).
struct MeetingReadView: View {
    let record: MeetingRecord
    let store: PhoneStore
    let player: MeetingAudioPlayer
    let isRecording: Bool
    /// Sor: tarifler (⋯ › Tarif uygula) ve alttaki "Bir şey sor" çubuğunun sohbeti.
    let ask: PhoneAsk
    /// Sor'da basılan kaynak (cevaptaki [n], kaynak listesi, kapsam dipnotu): bu toplantınınsa sayfa o anı açar
    /// (transkript çekmecesi o paragrafta, not kaynağında özet) ve `onSourceShown` ile tüketir.
    let openingSource: ArchivePassage?
    /// Onaylanan silme: toplantıyı siler ve sayfayı kapatır (onay bu sayfada sorulur).
    let onDelete: @MainActor () -> Void
    /// "Tekrar işle": son geçiş ve not yeniden (bkz. `PhoneRecorder.reprocess`).
    let onReprocess: @MainActor () throws -> Void
    /// ⋯ › Tarif uygula: seçilen tarif bu toplantıya Sor'da uygulanır.
    let onRunRecipe: @MainActor (Recipe) -> Void
    /// Sor'dan gelen kaynak açıldı (`openingSource` tüketildi).
    let onSourceShown: @MainActor () -> Void
    @State private var pane: MeetingPane = .summary
    /// Alttaki çubuğun transkript çekmecesi açık.
    @State private var isTranscriptOpen: Bool = false
    /// "Bu toplantıya sor" sohbet paneli açık (transkript çekmecesiyle aynı anda açık olmaz).
    @State private var isAskPanelOpen: Bool = false
    /// Sayfanın yüksekliği: alttaki panel ve çekmece en çok %45'ini kaplar.
    @State private var pageHeight: CGFloat = 0
    /// Çekmecede kayılacak ve vurgulanacak paragraf (not maddesinin kaynağından gelinince).
    @State private var transcriptFocusID: String?
    /// Silme onayı bekleyen toplantı (⋯ › Sil).
    @State private var pendingDelete: MeetingRecord?
    @State private var errorMessage: String?
    /// Konuşmacılara ad verme sayfası açık.
    @State private var isNamingSpeakers: Bool = false
    /// Kendi notlarını düzenleme sayfası açık.
    @State private var isEditingMyNotes: Bool = false
    /// Ad değiştirme alanı açık; yazılan ad.
    @State private var isRenaming: Bool = false
    @State private var newTitle: String = ""
    /// Yeni klasör adı soruluyor.
    @State private var isCreatingFolder: Bool = false
    /// Paylaşım sayfasıyla gönderilecek dışa aktarma dosyası.
    @State private var exported: ExportedFile?
    /// Notun gösterildiği dil (Mac'teki özetin dil menüsü; saklanır: bütün toplantılarda ve yeniden açılışta sürer);
    /// boşsa notun yazıldığı dil.
    @AppStorage(PhoneSettingsKey.meetingNoteDisplayLanguage) private var shownNoteLanguage: String = ""
    /// Paragrafın ses klibi hazırlanıyor (bitince paylaşım sayfası açılır).
    @State private var isExportingClip: Bool = false

    /// Notun gösterildiği dil: nil asıl not (yazıldığı dilde), değilse o dildeki sürümü. Paylaşım, Markdown kopyası ve
    /// notlu dışa aktarmalar da bu dilde çıkar. Seçilen dil notun yazıldığı dilse asıl not.
    private var noteLanguage: ShareLanguage? {
        ShareLanguage(rawValue: shownNoteLanguage).flatMap { (language: ShareLanguage) -> ShareLanguage? in
            language == record.note?.writtenLanguage ? nil : language
        }
    }
    /// "Sesi sil" satır içi onayı bekliyor (Mac'teki gibi; ayrı uyarı penceresi yok).
    @State private var isConfirmingAudioDelete: Bool = false
    /// Takip e-postası sayfası açık: taslağın ilk dili (sayfada seçili not dili); kapalıyken nil.
    @State private var followUpLanguage: ShareLanguage?
    /// "Bağlantıyla paylaş" sayfası açık.
    @State private var isSharingWithLink: Bool = false
    @Environment(\.openURL) private var openURL: OpenURLAction

    /// Not ve adlar değiştirilebilir: kayıtta, işlenen ya da notu yazılan toplantıda değil.
    private var isEditable: Bool {
        record.status != .recording && record.status != .processing && !store.regeneratingIDs.contains(record.id)
    }

    var body: some View {
        let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(paragraphs: paragraphs, proxy: proxy)
                    // Çalma hatası (dosya açılamadı, ses oturumu) da burada görünür.
                    let messages: [String] = [errorMessage, player.errorMeetingID == record.id ? player.errorMessage : nil].compactMap { $0 }
                    if !messages.isEmpty {
                        PhoneErrorList(messages: messages)
                    }
                    // Not yenileme, şablonla yazma, not düzenleme ve çeviri hataları (yalnız listede kalsaydı sayfada
                    // dönen çark sessizce dururdu).
                    PhoneDismissibleErrorList(messages: store.actionProblems) { store.dismissActionProblems() }
                    // Kanala ve görev aracına gönderimin durumu (bkz. `PhoneIntegrations`).
                    PhoneSendStatus(meetingID: record.id)
                    if isExportingClip {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Ses klibi hazırlanıyor…")
                                .appFont(size: 13, weight: .medium)
                                .foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if isConfirmingAudioDelete {
                        AudioDeleteConfirmation {
                            deleteAudio()
                        } onCancel: {
                            isConfirmingAudioDelete = false
                        }
                    }
                    if record.status == .queued {
                        QueuedMeetingNotice(record: record)
                    } else if let failure = record.failureMessage ?? record.notice {
                        Label(failure, systemImage: "info.circle")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                        // Hazırlanamayan ya da yarıda kalan toplantı: ses durdukça yeniden denemek tek dokunuş (⋯ menüsünde
                        // aranmasın). Son geçiş ve not yeniden yapılır.
                        if record.status == .failed || record.status == .interrupted, !record.audioDeleted, !isRecordedElsewhere, isEditable, !isRecording {
                            Button("Tekrar işle", systemImage: "arrow.triangle.2.circlepath") { reprocess() }
                                .buttonStyle(.accentPill)
                                .controlSize(.small)
                        }
                    }
                    if isRecordedElsewhere {
                        Label("Başka bir cihazında kaydedildi; sesi o cihazda kalır.", systemImage: "laptopcomputer.and.iphone")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    // Sekmeler ve notun dili tek satırda (Mac'teki gibi): dil, notun başka dildeki sürümünü gösterir.
                    HStack(spacing: 8) {
                        PillTabs(selection: $pane, options: [(MeetingPane.summary, "Not"), (MeetingPane.transcript, "Transkript")])
                        if pane == .summary, let note = record.note {
                            NoteLanguageMenu(original: note.writtenLanguage, selection: Binding<ShareLanguage?>(
                                get: { noteLanguage },
                                set: { (language: ShareLanguage?) -> Void in shownNoteLanguage = language?.rawValue ?? "" }
                            ))
                        }
                    }
                    switch pane {
                    case .summary:
                        if let note = record.note, let language = noteLanguage {
                            if let shown = sharedNoteVersion(record: record, language: language) {
                                Text("Paylaşınca ve dışa aktarınca da not bu dilde çıkar.")
                                    .appFont(size: 12, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                                summary(note: shown, paragraphs: paragraphs)
                            } else {
                                // Dil ya da not değişince durum (hata, deneme) sıfırlansın.
                                SharedNotePending(store: store, record: record, note: note, language: language, isEditable: isEditable)
                                    .id(language)
                                    .transition(.opacity)
                            }
                        } else {
                            summary(note: record.note, paragraphs: paragraphs)
                        }
                    case .transcript:
                        if paragraphs.contains(where: { $0.person != nil }) {
                            PhoneSpeakerReviewSection(store: store, record: record, isEditable: isEditable, canPlay: canPlay) { (startSec: Double) -> Void in
                                play(from: startSec)
                            }
                        }
                        let skipped: [StoredSegment] = skippedLanguageSegments(record: record)
                        if !skipped.isEmpty {
                            SkippedLanguageNote(record: record, segments: skipped, canPlay: canPlay) { (startSec: Double) -> Void in
                                play(from: startSec)
                            }
                        }
                        TranscriptList(
                            record: record, paragraphs: paragraphs, player: player, canPlay: canPlay, proxy: proxy,
                            highlighted: highlightedParagraphIDs(paragraphs: paragraphs, highlights: record.highlights ?? []),
                            isEditable: isEditable, onToggleHighlight: toggleHighlight(paragraph:), onClip: exportClip(paragraph:),
                            onRetryTranslation: { () -> Void in Task { await store.retryTranscriptTranslations(meetingID: record.id) } }
                        ) { (startSec: Double) -> Void in
                            play(from: startSec)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            // Altta yüzen "Bir şey sor" çubuğu ve üstünde açılan transkript çekmecesi (Mac'teki gibi).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar(paragraphs: paragraphs)
            }
            .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in proxy.size.height } action: { (height: CGFloat) -> Void in
                pageHeight = height
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canPlay {
                // Dinle / Duraklat (eski kapaktaki düğme): baştan çalar, çalıyorsa duraklatır.
                ToolbarItem(placement: .topBarTrailing) {
                    let isPlayingThis: Bool = player.meetingID == record.id && player.isPlaying
                    Button {
                        if player.meetingID == record.id {
                            player.togglePause()
                        } else {
                            play(from: 0)
                        }
                    } label: {
                        Label(isPlayingThis ? "Duraklat" : "Dinle", systemImage: isPlayingThis ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Not, Markdown kopyası ve notlu dosyalar sayfada seçili dilde çıkar (Mac'teki gibi); o dildeki sürüm
                    // hazırlanırken kapalıdır.
                    if record.note != nil {
                        if let text = shownShareText {
                            ShareLink(item: text) {
                                Label("Notu paylaş", systemImage: "square.and.arrow.up")
                            }
                        } else {
                            Button("Notu paylaş", systemImage: "square.and.arrow.up") {}
                                .disabled(true)
                        }
                        // Mac'teki "E-postayla gönder": not (seçili dilde) e-posta uygulamasında yeni ileti olarak açılır.
                        Button("E-postayla gönder", systemImage: "envelope") { emailNote() }
                            .disabled(shownShareText == nil)
                    }
                    Menu("Dışa aktar", systemImage: "square.and.arrow.down") {
                        ForEach(MeetingExportFormat.allCases.filter { isMeetingExportAvailable(record: record, format: $0) }) { (format: MeetingExportFormat) in
                            Button(format.title, systemImage: format.systemImage) { export(format: format) }
                                .disabled(format.carriesNote && shownRecord == nil)
                        }
                    }
                    Button("Markdown olarak kopyala", systemImage: "doc.on.doc") {
                        guard let shown = shownRecord else {
                            return
                        }
                        UIPasteboard.general.string = meetingMarkdown(record: shown)
                        recordFeatureUsage(feature: .export(.copyMarkdown))
                    }
                    .disabled(shownRecord == nil)
                    // Mac'teki "Takip e-postası yaz": nottan e-posta taslağı (düzenle, kopyala, paylaş ya da Mail).
                    Button("Takip e-postası yaz", systemImage: "envelope.badge") { openFollowUp() }
                        .disabled(record.note == nil || !isEditable)
                    // Mac'teki "Bağlantıyla paylaş…": uçtan uca şifreli bağlantı (sunucu notu okuyamaz).
                    Button("Bağlantıyla paylaş…", systemImage: "link") { isSharingWithLink = true }
                        .disabled(record.note == nil || record.isSampleMeeting)
                    // Mac'teki "Kanala gönder" ve "Görevleri gönder".
                    PhoneSendMenuItems(record: record)
                    // Mac'teki "Tarif": bu toplantıya tarif uygular, cevap Sor'da açılır.
                    Menu("Tarif uygula", systemImage: "wand.and.stars") {
                        ForEach(ask.recipes) { (recipe: Recipe) in
                            Button(recipe.title, systemImage: recipe.symbol) { onRunRecipe(recipe) }
                        }
                    }
                    .disabled(record.note == nil)
                    Divider()
                    Button("Adını değiştir", systemImage: "pencil") {
                        newTitle = record.note?.title ?? record.title
                        isRenaming = true
                    }
                    .disabled(!isEditable)
                    Menu("Klasöre taşı", systemImage: "folder") {
                        ForEach(store.folders, id: \.name) { (folder: FolderSummary) in
                            Button(folder.name, systemImage: record.folder?.caseInsensitiveCompare(folder.name) == .orderedSame ? "checkmark" : "folder") {
                                move(folder: folder.name)
                            }
                        }
                        Button("Yeni klasör…", systemImage: "folder.badge.plus") { isCreatingFolder = true }
                        if record.folder != nil {
                            Button("Klasörden çıkar", systemImage: "folder.badge.minus") { move(folder: nil) }
                        }
                    }
                    .disabled(!isEditable)
                    if paragraphs.contains(where: { $0.person != nil }) {
                        Button("Ad ver ya da birleştir", systemImage: "person.text.rectangle") { isNamingSpeakers = true }
                            .disabled(!isEditable)
                        // Mac'teki "Gözden geçir": öneriler transkriptin başındaki kartta.
                        Button("Konuşmacıları gözden geçir", systemImage: "sparkles") {
                            withAnimation(.smooth(duration: 0.25)) { pane = .transcript }
                            store.reviewSpeakers(meetingID: record.id)
                        }
                        .disabled(!isEditable || store.speakerReviews[record.id] == .loading)
                    }
                    Button(store.regeneratingIDs.contains(record.id) ? "Not yazılıyor…" : "Notu yenile", systemImage: "arrow.clockwise") {
                        Task { await store.regenerateNote(meetingID: record.id) }
                    }
                    .disabled(record.status == .recording || record.status == .processing || store.regeneratingIDs.contains(record.id))
                    Menu("Şablonla yeniden yaz", systemImage: "doc.badge.gearshape") {
                        ForEach(NoteTemplateKind.allCases, id: \.self) { (kind: NoteTemplateKind) in
                            Button {
                                let custom: String = UserDefaults.standard.string(forKey: PhoneSettingsKey.customTemplate) ?? ""
                                Task { await store.regenerateNote(meetingID: record.id, template: NoteTemplate(kind: kind, customInstructions: custom)) }
                            } label: {
                                if (record.template?.kind ?? .general) == kind {
                                    // Toplantı adından seçilen şablon bunu belirtir.
                                    Label(record.template?.displayName ?? kind.displayName, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: kind.displayName)
                                }
                            }
                        }
                    }
                    .disabled(record.status == .recording || record.status == .processing || store.regeneratingIDs.contains(record.id))
                    if let versions = record.noteHistory, let latest = versions.first {
                        Button("Geri al (\(latest.reason))", systemImage: "arrow.uturn.backward") { restoreVersion(index: 0) }
                            .disabled(record.status == .recording || record.status == .processing || store.regeneratingIDs.contains(record.id))
                        Menu("Önceki sürümler", systemImage: "clock.arrow.circlepath") {
                            Section("Değişiklikten önceki not") {
                                ForEach(Array(versions.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteVersion)) in
                                    Button(noteVersionTitle(version: item.element, locale: interfaceLocale())) {
                                        restoreVersion(index: item.offset)
                                    }
                                }
                            }
                        }
                        .disabled(record.status == .recording || record.status == .processing || store.regeneratingIDs.contains(record.id))
                    }
                    // Örnek toplantı (karşılamadaki deneme) işlenmez: sesi sunucuya gitmez, kullanıma yazılmaz. Mac'ten
                    // eşitlenen toplantının sesi Mac'te: burada işlenemez ve silinemez.
                    Button("Tekrar işle", systemImage: "arrow.triangle.2.circlepath") { reprocess() }
                        .disabled(!isEditable || record.audioDeleted || record.isSampleMeeting || isRecordedElsewhere)
                    Divider()
                    Button("Sesi sil", systemImage: "speaker.slash", role: .destructive) { isConfirmingAudioDelete = true }
                        .disabled(!isEditable || record.audioDeleted || record.status == .queued || isRecordedElsewhere)
                    Button("Sil", systemImage: "trash", role: .destructive) { pendingDelete = record }
                        .disabled(!isEditable)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Diğer")
            }
        }
        .modifier(MeetingDeleteConfirmation(pending: $pendingDelete) { (_: MeetingRecord) -> Void in onDelete() })
        // Sor'daki kaynaktan gelindi: sayfa o anı açar (sayfa açıkken basılan yeni kaynak da).
        .onChange(of: openingSource, initial: true) { (_: ArchivePassage?, source: ArchivePassage?) -> Void in
            guard let source, source.meetingID == record.id else {
                return
            }
            openSource(passage: source, paragraphs: paragraphs)
            onSourceShown()
        }
        .sheet(item: $exported) { (file: ExportedFile) in
            ActivityShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding<Bool>(get: { followUpLanguage != nil }, set: { if !$0 { followUpLanguage = nil } })) {
            if let language = followUpLanguage, let note = record.note {
                PhoneFollowUpEmailSheet(store: store, meetingID: record.id, noteLanguage: note.writtenLanguage, initialLanguage: language)
            }
        }
        .sheet(isPresented: $isSharingWithLink) {
            PhoneNoteShareSheet(record: record, language: noteLanguage)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isEditingMyNotes) {
            PhoneMyNotesEditor(initialText: record.myNotes ?? "") { (text: String) -> Void in
                Task { await store.saveMyNotes(meetingID: record.id, text: text) }
            }
        }
        .sheet(isPresented: $isRenaming) {
            PhoneTextEntrySheet(title: "Toplantının adı", placeholder: "Ad", actionTitle: "Kaydet", initialText: newTitle) { (text: String) -> Void in
                rename(title: text)
            }
        }
        .sheet(isPresented: $isCreatingFolder) {
            PhoneTextEntrySheet(title: "Yeni klasör", placeholder: "Klasör adı", actionTitle: "Taşı", initialText: "") { (text: String) -> Void in
                move(folder: text)
            }
        }
        .sheet(isPresented: $isNamingSpeakers) {
            SpeakerNamingSheet(shares: speakerShares(paragraphs: paragraphs), speakerNames: record.speakerNames) { (names: [Int: String]) throws -> Void in
                try store.renameSpeakers(meetingID: record.id, names: names)
            } onMerge: { (from: Int, into: Int) throws -> Void in
                try store.mergeSpeakers(meetingID: record.id, from: from, into: into)
            }
        }
        #if DEBUG
        .task {
            // `--cal <sn>` (yalnız Debug, görsel kontrol): transkripti açıp o saniyeden çalar.
            if let index = CommandLine.arguments.firstIndex(of: "--cal"), CommandLine.arguments.indices.contains(index + 1),
               let startSec = Double(CommandLine.arguments[index + 1]), player.meetingID == nil {
                play(from: startSec)
            }
            // `--konusmacilar` (yalnız Debug, görsel kontrol): konuşmacılara ad verme sayfasını açar.
            if CommandLine.arguments.contains("--konusmacilar") {
                isNamingSpeakers = true
            }
            // `--cekmece` (yalnız Debug, görsel kontrol): transkript çekmecesini toplantının ortasında açar.
            if CommandLine.arguments.contains("--cekmece") {
                transcriptFocusID = paragraphs.isEmpty ? nil : paragraphs[paragraphs.count / 2].id
                isTranscriptOpen = true
            }
            // `--sor-ornek` (yalnız Debug, görsel kontrol): "Bir şey sor" paneli bitmiş bir soruyla açılır (sahte cevap,
            // yapay zekâ çağrılmaz).
            if CommandLine.arguments.contains("--sor-ornek"), ask.meetingAsk.exchanges(meetingID: record.id).isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(600))
                } catch {
                    return
                }
                ask.meetingAsk.restore(exchange: phoneDemoMeetingExchange(record: record, paragraphs: paragraphs), meetingID: record.id)
            }
        }
        // `--kaynak` (yalnız Debug, görsel kontrol): özetin ilk maddesinin "Transkriptten" kutusu açık.
        .environment(\.noteSourceAutoOpenText, CommandLine.arguments.contains("--kaynak") ? record.note.flatMap { noteSummaryBullets(summary: $0.summary).first } : nil)
        #endif
    }

    /// Takip e-postası sayfasını açar (sayfada seçili not dilinde); hakkı yoksa abonelik ekranı açılır.
    private func openFollowUp() {
        guard !HostedAccount.shared.requiresSubscription else {
            HostedAccount.shared.requestSubscription()
            return
        }
        followUpLanguage = noteLanguage ?? record.note?.writtenLanguage
    }

    /// Notun önceki sürümünü geri yükler; olmazsa neden sayfada görünür.
    private func restoreVersion(index: Int) {
        do {
            try store.restoreNoteVersion(meetingID: record.id, index: index)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Not sürümü geri yüklenemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Sayfada seçili dildeki toplantı (asıl not ya da o dildeki sürümü); sürüm henüz hazır değilse nil.
    private var shownRecord: MeetingRecord? {
        recordInLanguage(record: record, language: noteLanguage)
    }

    /// Paylaşılacak not metni (seçili dilde); not yoksa ya da o dildeki sürüm hazır değilse nil.
    private var shownShareText: String? {
        guard let shown = shownRecord, let note = shown.note else {
            return nil
        }
        return shareText(record: shown, note: note, language: noteLanguage)
    }

    /// Notu (seçili dilde, konu notun başlığı) e-posta uygulamasında yeni ileti olarak açar (Mac'teki "E-postayla
    /// gönder"); açılamazsa neden sayfada görünür.
    private func emailNote() {
        guard let text = shownShareText else {
            return
        }
        let draft: FollowUpEmailDraft = FollowUpEmailDraft(subject: shownRecord?.note?.title ?? record.title, body: text)
        guard let url = followUpMailtoURL(draft: draft, recipients: []) else {
            errorMessage = String(localized: "Mail açılamadı: not e-posta bağlantısına çevrilemedi. \"Notu paylaş\" ile gönderebilirsin.")
            return
        }
        openURL(url) { (accepted: Bool) -> Void in
            if accepted {
                recordFeatureUsage(feature: .export(.email))
                errorMessage = nil
            } else {
                errorMessage = String(localized: "Mail açılamadı: bu iPhone'da e-posta uygulaması yok. \"Notu paylaş\" ile gönderebilirsin.")
            }
        }
    }

    /// Özet sekmesi: verilen not (asıl not ya da seçili dildeki sürümü; görevler asıl görevlerin işaretlerini taşır).
    private func summary(note: MeetingNote?, paragraphs: [TranscriptParagraph]) -> some View {
        MeetingSummary(
            record: record, note: note, paragraphs: paragraphs, store: store, canPlay: canPlay, isEditable: isEditable,
            onNameSpeakers: { isNamingSpeakers = true }, onEditMyNotes: { isEditingMyNotes = true }, onClip: exportClip(paragraph:),
            onJump: { (paragraph: TranscriptParagraph) -> Void in jump(to: paragraph, paragraphs: paragraphs) },
            onAskSource: { (text: String) -> Void in askAboutLine(text: text) }
        ) { (startSec: Double) -> Void in
            play(from: startSec)
        }
        .transition(.opacity)
    }

    /// Altta yüzen çubuk: Sor'un okuyabileceği toplantıda (kayıtta ya da işlenirken değil) "Bir şey sor" ve transkript
    /// çekmecesi; kayıt süren toplantıda yok.
    @ViewBuilder
    private func bottomBar(paragraphs: [TranscriptParagraph]) -> some View {
        if isMentionableMeeting(record: record) {
            VStack(spacing: 8) {
                if isTranscriptOpen {
                    TranscriptDrawer(
                        paragraphs: paragraphs, speakerNames: record.speakerNames, focusID: transcriptFocusID, canPlay: canPlay,
                        onPlay: { (startSec: Double) -> Void in playInPlace(from: startSec) },
                        onClose: { isTranscriptOpen = false }
                    )
                    .frame(height: bottomPanelMaxHeight(pageHeight: pageHeight, cap: 340))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Akan cevap yalnız çubuğu yeniden çizer (bkz. `ObservationScope`).
                ObservationScope {
                    MeetingAskBar(
                        exchanges: ask.meetingAsk.exchanges(meetingID: record.id), isAnswering: ask.meetingAsk.isAnswering(meetingID: record.id),
                        followUps: ask.meetingAsk.followUps(meetingID: record.id, note: record.note),
                        quickActions: record.note == nil ? [] : meetingQuickActions(recipes: ask.recipes), recipes: ask.recipes,
                        isEditingNote: store.regeneratingIDs.contains(record.id), isTranscriptOpen: isTranscriptOpen,
                        isPanelOpen: $isAskPanelOpen, conversationMaxHeight: bottomPanelMaxHeight(pageHeight: pageHeight, cap: 340) - 90,
                        onAsk: { (question: String, recipeTitle: String?) -> Void in
                            ask.askAboutMeeting(meetingID: record.id, question: question, recipeTitle: recipeTitle)
                        },
                        onQuickAction: { (action: MeetingQuickAction) -> Void in run(action: action) },
                        onStop: { ask.meetingAsk.stop(meetingID: record.id) },
                        onClear: { ask.meetingAsk.clear(meetingID: record.id) },
                        onRegenerate: { ask.regenerateMeetingAnswer(meetingID: record.id) },
                        onOpenSource: { (passage: ArchivePassage) -> Void in openSource(passage: passage, paragraphs: paragraphs) },
                        onSaveRecipe: { (question: String) -> Void in ask.saveRecipe(question: question) },
                        onToggleTranscript: {
                            transcriptFocusID = nil
                            isTranscriptOpen.toggle()
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            // Çubuğun arkasında zemine durgun geçiş: altından kayan not çubukla panel arasında görünmesin.
            .background(alignment: .bottom) {
                LinearGradient(stops: [.init(color: Theme.background.opacity(0), location: 0), .init(color: Theme.background, location: 0.35)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
            .animation(.smooth(duration: 0.25), value: isTranscriptOpen)
            // Toplantının saklı son sohbeti geri gelir (geçmiş açılışta arka planda okunur: gelince de denenir).
            .onAppear { ask.meetingAsk.resume(meetingID: record.id, conversations: ask.conversations) }
            .onChange(of: ask.conversations.count) { (_: Int, _: Int) -> Void in
                ask.meetingAsk.resume(meetingID: record.id, conversations: ask.conversations)
            }
            // Sohbet paneli ve transkript çekmecesi aynı anda açık olmaz: biri açılınca öteki kapanır.
            .onChange(of: isAskPanelOpen) { (_: Bool, open: Bool) in
                if open {
                    isTranscriptOpen = false
                }
            }
            .onChange(of: isTranscriptOpen) { (_: Bool, open: Bool) in
                if open {
                    isAskPanelOpen = false
                }
            }
        }
    }

    /// Hazır eylem: tarif bu sayfada sorulur, "Notu uzat" notu yeniden yazar.
    private func run(action: MeetingQuickAction) {
        switch action.kind {
        case .ask(let prompt, let recipeTitle):
            ask.askAboutMeeting(meetingID: record.id, question: prompt, recipeTitle: recipeTitle)
        case .editNote(let instruction):
            Task { await store.editNote(meetingID: record.id, instruction: instruction) }
        }
    }

    /// Kaynak kutusundaki "Sor": maddenin toplantıda nasıl konuşulduğunu bu toplantıya sorar.
    private func askAboutLine(text: String) {
        ask.askAboutMeeting(
            meetingID: record.id, question: String(localized: "Notta \"\(text)\" yazıyor. Bu toplantıda nasıl konuşuldu: kim ne dedi, neden bu sonuca varıldı?"),
            recipeTitle: nil
        )
    }

    /// Cevaptaki kaynak: transkript parçasıysa çekmecede o ana gidilir; not parçası Özet'i gösterir.
    private func openSource(passage: ArchivePassage, paragraphs: [TranscriptParagraph]) {
        guard passage.kind == .transcript, let paragraph = paragraphs.last(where: { $0.startSec <= passage.startSec + 0.5 }) ?? paragraphs.first else {
            withAnimation(.smooth(duration: 0.25)) { pane = .summary }
            return
        }
        jump(to: paragraph, paragraphs: paragraphs)
    }

    /// Kaynaktan transkriptte o ana gider: çekmece açılır, paragrafa kayıp vurgular; ses varsa oradan çalar (sekme
    /// değişmez, not görünür kalır).
    private func jump(to paragraph: TranscriptParagraph, paragraphs: [TranscriptParagraph]) {
        transcriptFocusID = paragraph.id
        isTranscriptOpen = true
        playInPlace(from: paragraph.startSec)
    }

    /// Sekmeyi değiştirmeden verilen andan çalar (ses yoksa bir şey yapmaz).
    private func playInPlace(from startSec: Double) {
        guard canPlay else {
            return
        }
        do {
            let urls: [URL] = try store.audioURLs(record: record)
            guard !urls.isEmpty else {
                return
            }
            player.play(record: record, urls: urls, startSec: startSec)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    /// Paragrafın sesini (iki kayıt karışık) M4A klip olarak hazırlar ve paylaşım sayfasını açar (Mac'teki "Klip olarak
    /// kaydet"; iPhone'da Dosyalar'a kaydet, Mesajlar, AirDrop…); olmazsa neden sayfada görünür.
    private func exportClip(paragraph: TranscriptParagraph) {
        guard canPlay, !isExportingClip else {
            return
        }
        let sources: [URL]
        do {
            sources = try store.audioURLs(record: record)
        } catch {
            errorMessage = String(localized: "Klip kaydedilemedi: \(userFacingMessage(error: error))")
            return
        }
        guard !sources.isEmpty else {
            errorMessage = String(localized: "Bu toplantının ses kaydı yok.")
            return
        }
        isExportingClip = true
        let shown: MeetingRecord = record
        Task {
            defer { isExportingClip = false }
            do {
                exported = ExportedFile(url: try await writeMeetingClip(record: shown, paragraph: paragraph, sources: sources))
                recordFeatureUsage(feature: .export(.audioClip))
                errorMessage = nil
            } catch {
                meetingReadLogger.error("Klip kaydedilemedi, toplantı: \(shown.id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                errorMessage = String(localized: "Klip kaydedilemedi: \(userFacingMessage(error: error))")
            }
        }
    }

    /// Toplantıyı yeniden işler; olmazsa neden sayfada görünür.
    private func reprocess() {
        do {
            try onReprocess()
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Tekrar işlenemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Yalnız sesi siler (bu toplantı çalıyorsa önce durur); olmazsa neden sayfada görünür.
    private func deleteAudio() {
        isConfirmingAudioDelete = false
        if player.meetingID == record.id {
            player.stop()
            store.playingMeetingID = nil
        }
        do {
            try store.deleteAudio(meetingID: record.id)
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Ses silinemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Toplantıyı dosya olarak yazar (notlu dosyalar seçili dilde) ve paylaşım sayfasını açar; olmazsa neden sayfada
    /// görünür.
    private func export(format: MeetingExportFormat) {
        let source: MeetingRecord
        if format.carriesNote {
            guard let shown = shownRecord else {
                return
            }
            source = shown
        } else {
            source = record
        }
        let language: ShareLanguage? = format.carriesNote ? noteLanguage : nil
        Task {
            do {
                exported = ExportedFile(url: try await writeMeetingExport(record: source, language: language, format: format))
                recordFeatureUsage(feature: .export(format.telemetryFormat))
                errorMessage = nil
            } catch {
                errorMessage = String(localized: "Dışa aktarılamadı: \(userFacingMessage(error: error))")
            }
        }
    }

    /// Toplantının adını (not başlığıyla birlikte) değiştirir; boş ad yok sayılır.
    private func rename(title: String) {
        let trimmed: String = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        apply(failure: "Ad değiştirilemedi") { (current: MeetingRecord) -> MeetingRecord in current.with(title: trimmed) }
    }

    /// Toplantıyı klasöre taşır (nil ya da boş ad klasörden çıkarır).
    private func move(folder: String?) {
        let trimmed: String? = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: String? = trimmed?.isEmpty == false ? trimmed : nil
        apply(failure: "Klasöre taşınamadı") { (current: MeetingRecord) -> MeetingRecord in current.with(folder: target) }
    }

    /// Paragrafın işaretini açar ya da kaldırır.
    private func toggleHighlight(paragraph: TranscriptParagraph) {
        apply(failure: "İşaret kaydedilemedi") { (current: MeetingRecord) -> MeetingRecord in
            let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: current)
            return current.with(highlights: togglingHighlight(highlights: current.highlights ?? [], paragraphs: paragraphs, paragraph: paragraph))
        }
    }

    /// Düzenlemeyi diskteki güncel kayda uygular; olmazsa `failure` ve neden sayfada görünür.
    private func apply(failure: String.LocalizationValue, change: (MeetingRecord) -> MeetingRecord) {
        do {
            try store.updateMeeting(meetingID: record.id, change: change)
            errorMessage = nil
        } catch {
            errorMessage = "\(String(localized: failure)): \(userFacingMessage(error: error))"
        }
    }

    /// Kapaktaki karar ya da görev çipinden nottaki bölüme gider: transkriptteyse önce özete geçer, bölüm çizilince kaydırır.
    private func reveal(anchor: MeetingNoteAnchor, proxy: ScrollViewProxy) {
        let needsSwitch: Bool = pane != .summary
        withAnimation(.smooth(duration: 0.25)) { pane = .summary }
        Task { @MainActor in
            if needsSwitch {
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    // Görünüm kapandı (görev iptal): kaydırılacak sayfa yok.
                    return
                }
            }
            withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    /// Sakin başlık (Mac'teki gibi): küçük pastel kutu, başlık, tek satır bilgi çipleri (şablon, tarih, süre, konuşmacı
    /// sayısı, klasör, dil) ve sana düşen görev varsa sayısı (dokununca nottaki görevlere gider).
    private func header(paragraphs: [TranscriptParagraph], proxy: ScrollViewProxy) -> some View {
        // Kısa konuşmalar (bkz. `groupedSpeakers`) konuşmacı sayısına girmez.
        let majorCount: Int = groupedSpeakers(shares: speakerShares(paragraphs: paragraphs), speakerNames: record.speakerNames).major.count
        let mine: Int = (record.note?.tasks ?? []).filter(\.isMine).count
        // Başlık sayfanın en üstünde: renkli kare listede toplantıyı ayırır, sayfada bir şey söylemez.
        return VStack(alignment: .leading, spacing: 12) {
            Text(record.note?.title ?? record.title)
                .appFont(size: 28, weight: .semibold)
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            MeetingInfoChips(chips: meetingInfoChips(record: record, speakers: majorCount, locale: interfaceLocale()))
            if mine > 0 {
                Button {
                    reveal(anchor: .myTasks, proxy: proxy)
                } label: {
                    Text("Sana \(mine) görev")
                }
                .buttonStyle(.plain)
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// Ses varsa ve kayıt sürmüyorsa çalınabilir (başka cihazdan eşitlenen toplantının sesi o cihazda).
    private var canPlay: Bool {
        !isRecording && !record.audioDeleted && !isRecordedElsewhere && (record.status == .done || record.status == .failed || record.status == .interrupted)
    }

    /// Mac'ten eşitlenen toplantı (sesi kaydedildiği cihazda).
    private var isRecordedElsewhere: Bool {
        store.meetingsRecordedElsewhere.contains(record.id)
    }

    private func play(from startSec: Double) {
        guard canPlay else {
            return
        }
        do {
            let urls: [URL] = try store.audioURLs(record: record)
            guard !urls.isEmpty else {
                errorMessage = String(localized: "Bu toplantının ses kaydı yok.")
                return
            }
            errorMessage = nil
            withAnimation(.smooth(duration: 0.25)) { pane = .transcript }
            player.play(record: record, urls: urls, startSec: startSec)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

/// Özet: senin görevlerin (işaretlenebilir), özet, kim ne kadar konuştu, kararlar, konu akışı (dokununca
/// oradan çalar), diğer görevler, sözlük.
private struct MeetingSummary: View {
    let record: MeetingRecord
    /// Gösterilen not: asıl not ya da seçili dildeki sürümü (`sharedNoteVersion`; görevleri asıl görevlerin
    /// işaretlerine bağlı). Notu olmayan toplantıda nil.
    let note: MeetingNote?
    let paragraphs: [TranscriptParagraph]
    let store: PhoneStore
    let canPlay: Bool
    /// Not ve konuşmacı adları değiştirilebilir (kayıtta, işlenen ya da notu yazılan toplantıda değil).
    let isEditable: Bool
    let onNameSpeakers: @MainActor () -> Void
    let onEditMyNotes: @MainActor () -> Void
    /// İşaretli anın sesini klip olarak paylaşır (uzun basınca).
    let onClip: @MainActor (TranscriptParagraph) -> Void
    /// Maddenin kaynağından transkriptte o ana gider (çekmece açılır, ses varsa oradan çalar).
    let onJump: @MainActor (TranscriptParagraph) -> Void
    /// Kaynak kutusundaki "Sor": maddenin nasıl konuşulduğunu bu toplantıya sorar.
    let onAskSource: @MainActor (String) -> Void
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// "Görev ekle" sayfası açık.
    @State private var isAddingTask: Bool = false

    var body: some View {
        if let note {
            let mine: [NoteTask] = note.tasks.filter(\.isMine)
            let shares: [SpeakerShare] = speakerShares(paragraphs: paragraphs)
            let groups: SpeakerGroups = groupedSpeakers(shares: shares, speakerNames: record.speakerNames)
            VStack(alignment: .leading, spacing: 28) {
                // Not bir belge gibi: başlıklar ve maddeler; maddeye dokununca kaynağı (Mac'te üstüne gelince büyüteç).
                noteDocument(note: note)
                // Özetin altındaki sakin blok: yüz yüze toplantıda "Hangisi sendin?", kendi notların (varsa) ve not
                // düzenleme satırı (kendi notun yoksa sonunda "Notlarım").
                VStack(alignment: .leading, spacing: 12) {
                    if mine.isEmpty {
                        // Yüz yüze toplantıda kullanıcı da "Konuşmacı N": hangisi olduğunu seçince görevleri ona düşer.
                        UserSpeakerPrompt(record: record, userName: store.userName, isLocked: !isEditable) { (person: Int, name: String) -> Void in
                            store.nameUserSpeaker(meetingID: record.id, person: person, name: name)
                        }
                        if isEditable, !record.isSampleMeeting {
                            addTaskButton
                        }
                    }
                    if let myNotes = record.myNotes {
                        myNotesCard(text: myNotes)
                    }
                    PhoneNoteEditBar(
                        isWorking: store.regeneratingIDs.contains(record.id), isEnabled: isEditable,
                        onAddMyNotes: record.myNotes == nil && isEditable ? onEditMyNotes : nil
                    ) { (instruction: String) -> Void in
                        Task { await store.editNote(meetingID: record.id, instruction: instruction) }
                    }
                }
                // Adı verilmemiş konuşmacı varsa ad verme Ayrıntılar'ın dışında da görünür: görevlerin kime düştüğü adlara
                // bağlı ("Hangisi sendin?" görünüyorsa o yeter).
                if isEditable, !mine.isEmpty, hasUnnamedSpeakers(shares: shares) {
                    Button("Konuşmacılara ad ver", systemImage: "person.text.rectangle", action: onNameSpeakers)
                        .appFont(size: 14, weight: .medium)
                }
                // Az kullanılan bilgiler kapalı bir bölümde: konuşma payları, konuşmacı şeridi ve sözlük.
                if shares.count > 1 || !note.glossary.isEmpty {
                    MeetingDetailsDisclosure {
                        if shares.count > 1 {
                            VStack(alignment: .leading, spacing: 12) {
                                // Adı verilebilecek konuşmacı varsa başlıkta "Ad ver" (transkript ve not adlarla görünür).
                                PhoneSectionHeader(
                                    title: "Kim ne kadar konuştu",
                                    actionTitle: isEditable && shares.contains(where: { $0.key.person != nil }) ? "Ad ver" : nil,
                                    action: onNameSpeakers
                                )
                                let totalSec: Double = paragraphs.map(\.endSec).max() ?? 0
                                if totalSec > 0 {
                                    SpeakerStrip(spans: speakerSpans(paragraphs: paragraphs), totalSec: totalSec)
                                }
                                ForEach(Array(groups.major.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerShare)) in
                                    ShareRow(share: item.element, speakerNames: record.speakerNames)
                                }
                                // Az konuşanlar tek satırda; dokununca tek tek görünür (ad vermek için "Ad ver").
                                if !groups.minor.isEmpty {
                                    MinorSpeakersRow(groups: groups, speakerNames: record.speakerNames)
                                }
                            }
                        }
                        if !note.glossary.isEmpty {
                            PhoneGlossarySection(glossary: note.glossary)
                        }
                    }
                }
            }
        } else {
            EmptyStateCard(symbol: "doc.text", title: "Bu toplantının notu yok", message: nil)
        }
    }

    /// Bu toplantıya elle görev ekleme düğmesi (kendi görevin); sayfada iş ve isteğe bağlı son gün.
    private var addTaskButton: some View {
        Button("Görev ekle", systemImage: "plus") { isAddingTask = true }
            .appFont(size: 14, weight: .medium)
            .foregroundStyle(appearance.accent.color)
            .sheet(isPresented: $isAddingTask) {
                NavigationStack {
                    AddTaskForm(meetings: [record], fixedMeetingID: record.id) { (meetingID: String, text: String, dueDay: Date?) -> Void in
                        store.addTask(meetingID: meetingID, description: text, dueDay: dueDay)
                        isAddingTask = false
                    } onCancel: {
                        isAddingTask = false
                    }
                    .navigationTitle("Görev ekle")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
    }

    /// Adı verilmemiş (hâlâ "Konuşmacı N") konuşmacı var mı.
    private func hasUnnamedSpeakers(shares: [SpeakerShare]) -> Bool {
        shares.contains { (share: SpeakerShare) -> Bool in
            guard let person = share.key.person else {
                return false
            }
            return (record.speakerNames[person] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// İşaretli paragraflar (kayıtta "İşaretle" ya da transkriptte uzun basarak), zaman sırasıyla.
    private var markedParagraphs: [TranscriptParagraph] {
        let ids: Set<String> = highlightedParagraphIDs(paragraphs: paragraphs, highlights: record.highlights ?? [])
        return paragraphs.filter { ids.contains($0.id) }
    }

    /// Not belgesi (Mac'teki gibi): Özet, Görevler, Kararlar, Açık konular, Konu akışı ve İşaretli anlar başlıkları ve
    /// maddeleri; boş bölüm yok.
    @ViewBuilder
    private func noteDocument(note: MeetingNote) -> some View {
        let marked: [TranscriptParagraph] = markedParagraphs
        let outline: [OutlineItem] = note.outline ?? []
        let mine: [NoteTask] = openFirst(tasks: note.tasks.filter(\.isMine))
        let others: [NoteTask] = openFirst(tasks: note.tasks.filter { !$0.isMine })
        // Sana düşen işler notun en başında, kendi kartında (karşılamadaki örnek not da böyle söz verir).
        if !mine.isEmpty {
            myTasksCard(mine: mine)
                .id(MeetingNoteAnchor.myTasks)
        }
        noteBlock(title: "Özet") {
            ForEach(Array(noteSummaryBullets(summary: note.summary).enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                bullet(text: item.element, anchorSec: nil) {
                    Text(item.element)
                }
            }
        }
        .id(MeetingNoteAnchor.sections)
        if !others.isEmpty {
            if mine.isEmpty {
                // Senin görevin yoksa bölüm yalnız "Görevler"; kapaktaki bağlantı da buraya kayar.
                noteBlock(title: "Görevler") {
                    ForEach(others, id: \.trackingKey) { (task: NoteTask) in taskRow(task: task) }
                }
                .id(MeetingNoteAnchor.myTasks)
            } else {
                noteBlock(title: "Diğer görevler") {
                    ForEach(others, id: \.trackingKey) { (task: NoteTask) in taskRow(task: task) }
                }
            }
        }
        if !note.decisions.isEmpty {
            noteBlock(title: "Kararlar") {
                ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                    anchoredBullet(line: anchoredLine(text: item.element))
                }
            }
            .id(MeetingNoteAnchor.decisions)
        }
        if let questions = note.openQuestions, !questions.isEmpty {
            noteBlock(title: "Açık konular") {
                ForEach(Array(questions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                    anchoredBullet(line: anchoredLine(text: item.element))
                }
            }
            .id(MeetingNoteAnchor.openQuestions)
        }
        if !outline.isEmpty {
            noteBlock(title: "Konu akışı") {
                ForEach(Array(outline.enumerated()), id: \.offset) { (item: (offset: Int, element: OutlineItem)) in
                    bullet(text: item.element.title + ". " + item.element.summary, anchorSec: item.element.startSec) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.element.title).fontWeight(.semibold)
                            Text(item.element.summary).foregroundStyle(Theme.ink.opacity(0.8))
                            NoteTimeChip(startSec: item.element.startSec, canPlay: canPlay, onPlay: onPlay)
                        }
                    }
                }
            }
        }
        if !marked.isEmpty {
            noteBlock(title: "İşaretli anlar") {
                momentsSection(marked: marked)
            }
        }
    }

    /// Notun bir bölümü: başlık ve altında maddeler.
    private func noteBlock<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NoteDocumentHeading(title: title)
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(.horizontal, -10)
        }
    }

    /// Kaynağı gösterilebilen nokta işaretli madde (dokununca ya da basılı tutunca "Transkriptten").
    private func bullet<Content: View>(text: String, anchorSec: Double?, @ViewBuilder content: @escaping () -> Content) -> some View {
        sourceRow(text: text, anchorSec: anchorSec) {
            NoteBulletDot()
        } content: {
            content()
                .readingText(size: 16, weight: .regular, lineSpacing: 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Karar ya da açık konu maddesi: metin ve altında (varsa) konuşulduğu an (dar ekranda metne yer kalsın).
    private func anchoredBullet(line: AnchoredLine) -> some View {
        bullet(text: line.text, anchorSec: line.startSec) {
            VStack(alignment: .leading, spacing: 6) {
                Text(line.text)
                if let start = line.startSec {
                    NoteTimeChip(startSec: start, canPlay: canPlay, onPlay: onPlay)
                }
            }
        }
    }

    private func sourceRow<Leading: View, Content: View>(
        text: String, anchorSec: Double?, @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        NoteSourceRow(
            text: text, anchorSec: anchorSec, paragraphs: paragraphs, outline: record.note?.outline ?? [],
            speakerNames: record.speakerNames, canPlay: canPlay, onJump: onJump, onAsk: { onAskSource(text) },
            leading: leading, content: content
        )
    }

    /// Tamamlananlar sonda; sıra öyle kalır.
    private func openFirst(tasks: [NoteTask]) -> [NoteTask] {
        tasks.filter { !isTaskDone(record: record, task: $0) } + tasks.filter { isTaskDone(record: record, task: $0) }
    }

    /// "Senin görevlerin" kartı (Mac'teki gibi): notun başında, vurgu renginin hafif zemininde; başlıkta ilerleme.
    private func myTasksCard(mine: [NoteTask]) -> some View {
        let done: Int = mine.filter { isTaskDone(record: record, task: $0) }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Senin görevlerin")
                    .appFont(size: 17, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: String(localized: "\(done)/\(mine.count) tamamlandı"))
                    .appFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(appearance.accent.color)
                Spacer(minLength: 0)
                if isEditable, !record.isSampleMeeting {
                    addTaskButton
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(Text("Görev ekle"))
                }
            }
            .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(mine, id: \.trackingKey) { (task: NoteTask) in taskRow(task: task) }
            }
            .padding(.horizontal, -10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accent.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(appearance.accent.color.opacity(0.18)))
    }

    private func taskRow(task: NoteTask) -> some View {
        sourceRow(text: task.description, anchorSec: nil) {
            EmptyView()
        } content: {
            PhoneTaskRowContent(record: record, task: task, showsMeeting: false) {
                withAnimation(.smooth(duration: 0.25)) { store.toggleTask(meetingID: record.id, task: task) }
            }
        }
        .id(task.trackingKey)
    }

    /// İşaretlediğin anlar: dokununca oradan çalar; uzun basınca ses klibi.
    private func momentsSection(marked: [TranscriptParagraph]) -> some View {
        ForEach(marked) { (paragraph: TranscriptParagraph) in
            HighlightRow(paragraph: paragraph, speakerNames: record.speakerNames, canPlay: canPlay) {
                onPlay(paragraph.startSec)
            }
            .padding(.horizontal, 10)
            // Uzun basınca (Mac'teki sağ tık): anın sesini klip olarak paylaş.
            .contextMenu {
                Button("Ses klibini paylaş", systemImage: "waveform") { onClip(paragraph) }
                    .disabled(!canPlay)
            }
        }
    }

    /// Kendi notların: vurgu renginde ince kenarlı kart; düzenlenebiliyorsa başlıkta "Düzenle".
    private func myNotesCard(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("SENİN NOTLARIN", systemImage: "square.and.pencil")
                    .appFont(size: 11, weight: .semibold)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(appearance.accent.color)
                Spacer()
                if isEditable {
                    Button("Düzenle", action: onEditMyNotes)
                        .appFont(size: 13, weight: .medium)
                }
            }
            Text(text)
                .readingText(size: 15, weight: .regular, lineSpacing: 3)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accent.color.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                .fill(appearance.accent.color.opacity(0.7))
                .frame(width: 3)
        }
    }
}

/// Sözlük: açılıp kapanan bölüm (Mac'teki gibi). Başlıkta terim sayısı ve ok; kapalıyken ilk terimler çip olarak,
/// dokununca açılır; açıkken terim ve altında anlamı. Açık/kapalı tercihi tüm toplantılar için hatırlanır.
private struct PhoneGlossarySection: View {
    let glossary: [GlossaryEntry]
    @AppStorage(PhoneSettingsKey.glossaryExpanded) private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("SÖZLÜK")
                        .appFont(size: 12, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(Theme.muted)
                    Text("\(glossary.count) terim")
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Theme.soft, in: Capsule())
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .appFont(size: 12, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Sözlük açık") : Text("Sözlük kapalı"))
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(glossary.enumerated()), id: \.offset) { (item: (offset: Int, element: GlossaryEntry)) in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.element.term).appFont(size: 15, weight: .semibold)
                            Text(item.element.meaning)
                                .appFont(size: 14, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Kapalıyken ilk terimler; dokununca açılır.
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(glossary.prefix(6), id: \.term) { (entry: GlossaryEntry) in
                        Text(entry.term)
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(Theme.ink.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.soft, in: Capsule())
                    }
                    if glossary.count > 6 {
                        Text(verbatim: "+\(glossary.count - 6)")
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Theme.line))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.smooth(duration: 0.3)) { isExpanded = true } }
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Konuşma payı satırı: rozet, ad, yüzde ve kişinin renginde ince çubuk.
private struct ShareRow: View {
    let share: SpeakerShare
    let speakerNames: [Int: String]

    var body: some View {
        let color: Color = share.key.person.map { personColor(person: $0) } ?? DesignTokens.meSpeakerColor
        HStack(spacing: 10) {
            SpeakerBadge(speaker: share.key.speaker, person: share.key.person, size: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(share.key.person.flatMap { speakerNames[$0] } ?? speakerLabel(speaker: share.key.speaker, person: share.key.person))
                        .appFont(size: 14, weight: .medium)
                    Spacer()
                    Text(verbatim: share.fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
                        .appFont(size: 13, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                GeometryReader { (proxy: GeometryProxy) in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.soft)
                        Capsule().fill(color).frame(width: proxy.size.width * share.fraction)
                    }
                }
                .frame(height: 5)
            }
        }
    }
}

/// Sabit toplantı dilinden başka dilde olduğu için transkriptten, nottan ve Sor'dan atlanan bölümler: tek satır ve
/// dokununca soluk liste (bölüme dokununca oradan çalar, Mac'teki gibi). Bölümler kayıtta durur.
private struct SkippedLanguageNote: View {
    let record: MeetingRecord
    let segments: [StoredSegment]
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @State private var isExpanded: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Label("Başka dilde \(segments.count) bölüm atlandı", systemImage: "globe")
                    Spacer()
                    Text(isExpanded ? "Gizle" : "Göster")
                        .foregroundStyle(Theme.ink)
                }
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(segments, id: \.key) { (segment: StoredSegment) in
                    Button {
                        onPlay(segment.startSec)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(timestamp(seconds: segment.startSec))
                                .monospacedDigit()
                                .foregroundStyle(canPlay ? appearance.accent.color : Theme.muted)
                            Text(verbatim: "\(segment.person.flatMap { record.speakerNames[$0] } ?? speakerLabel(speaker: segment.speaker, person: segment.person)): \(segment.text)")
                                .italic()
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.leading)
                        }
                        .appFont(size: 13, weight: .regular)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPlay)
                }
            }
        }
    }
}

/// Kısa konuşmalar (bkz. `groupedSpeakers`): toplam payıyla tek satır; dokununca kişiler tek tek görünür.
private struct MinorSpeakersRow: View {
    let groups: SpeakerGroups
    let speakerNames: [Int: String]
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "ellipsis")
                        .appFont(size: 12, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 26, height: 26)
                        .background(Theme.soft, in: Circle())
                    Text("Kısa konuşmalar (\(groups.minor.count))")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .appFont(size: 11, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Text(verbatim: groups.minorFraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
                        .appFont(size: 13, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(Array(groups.minor.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerShare)) in
                    ShareRow(share: item.element, speakerNames: speakerNames)
                        .padding(.leading, 14)
                }
            }
        }
    }
}

/// İşaretli an: zaman, konuşmacı ve metin; dokununca oradan çalar.
private struct HighlightRow: View {
    let paragraph: TranscriptParagraph
    let speakerNames: [Int: String]
    let canPlay: Bool
    let onPlay: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "star.fill")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(timestamp(seconds: paragraph.startSec))
                            .appFont(size: 12, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(appearance.accent.color)
                        Text(paragraphLabel(paragraph: paragraph, speakerNames: speakerNames))
                            .appFont(size: 12, weight: .medium)
                            .foregroundStyle(Theme.muted)
                    }
                    Text(paragraph.text)
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
    }
}

/// Kendi notlarını düzenleme sayfası: kaydedince notlar saklanır ve toplantı notu onlarla yeniden yazılır (Mac'teki
/// "Notlarım").
private struct PhoneMyNotesEditor: View {
    let initialText: String
    let onSave: @MainActor (String) -> Void
    @State private var text: String = ""
    @Environment(\.dismiss) private var dismiss: DismissAction
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .readingText(size: 16, weight: .regular, lineSpacing: 3)
                .focused($isFocused)
                .padding(.horizontal, 16)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .safeAreaInset(edge: .bottom) {
                    Text("Kaydedince not, notlarını da hesaba katarak yeniden yazılır.")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Senin notların")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Vazgeç") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Kaydet") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(text == initialText)
                    }
                }
        }
        .onAppear {
            text = initialText
            isFocused = true
        }
    }
}

/// Takip e-postası (Mac'teki "Takip e-postası yaz"): nottan yazılan taslak; yazılırken ilerleme, olmazsa neden ve
/// "Yeniden dene"; hazır olunca konu ve gövde düzenlenir, Kopyala, Paylaş ya da Mail (alıcılar bağlı takvim etkinliğinin
/// katılımcıları). Dil değişince taslak o dilde yeniden yazılır; sayfa kapanınca istek iptal edilir.
private struct PhoneFollowUpEmailSheet: View {
    let store: PhoneStore
    let meetingID: String
    /// Notun yazıldığı dil (dil menüsünün başında).
    let noteLanguage: ShareLanguage
    @State private var language: ShareLanguage
    @State private var phase: PhoneFollowUpPhase = .drafting
    @State private var subject: String = ""
    @State private var text: String = ""
    @State private var attempt: Int = 0
    /// Mail açılamadı ya da kopyalandı: sayfanın altında.
    @State private var actionMessage: String?
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction

    init(store: PhoneStore, meetingID: String, noteLanguage: ShareLanguage, initialLanguage: ShareLanguage) {
        self.store = store
        self.meetingID = meetingID
        self.noteLanguage = noteLanguage
        _language = State(initialValue: initialLanguage)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Nottan kısa bir takip e-postası; göndermeden önce düzenle.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    switch phase {
                    case .drafting:
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Takip e-postası yazılıyor…")
                                .appFont(size: 14, weight: .medium)
                                .foregroundStyle(Theme.muted)
                        }
                    case .failed(let message):
                        PhoneErrorList(messages: [String(localized: "Takip e-postası yazılamadı: \(message)")])
                        Button("Yeniden dene", systemImage: "arrow.clockwise") { attempt += 1 }
                    case .ready:
                        TextField("Konu", text: $subject, axis: .vertical)
                            .appFont(size: 16, weight: .semibold)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        TextEditor(text: $text)
                            .readingText(size: 16, weight: .regular, lineSpacing: 3)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 280)
                            .padding(8)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        if let actionMessage {
                            Text(actionMessage)
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Takip e-postası")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    languageMenu
                }
                if phase == .ready {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Kopyala", systemImage: "doc.on.doc") { copy() }
                        Spacer()
                        ShareLink(item: "\(subject)\n\n\(text)", subject: Text(subject)) {
                            Label("Paylaş", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button("Mail", systemImage: "envelope") { openInMail() }
                        Spacer()
                        Button("Yeniden yaz", systemImage: "arrow.clockwise") { attempt += 1 }
                    }
                }
            }
        }
        .task(id: "\(language.rawValue)-\(attempt)") {
            phase = .drafting
            actionMessage = nil
            do {
                let draft: FollowUpEmailDraft = try await store.draftFollowUpEmail(meetingID: meetingID, language: language)
                subject = draft.subject
                text = draft.body
                phase = .ready
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                meetingReadLogger.error("Takip e-postası yazılamadı, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                phase = .failed(userFacingMessage(error: error))
            }
        }
    }

    /// Taslağın dili: notun dili, sık kullanılan Fince ve İngilizce, sonra diğer diller.
    private var languageMenu: some View {
        let choices: ShareLanguageChoices = shareLanguageChoices(original: noteLanguage)
        return Menu {
            Button(noteLanguage.interfaceTitle) { language = noteLanguage }
            ForEach(choices.featured, id: \.self) { (choice: ShareLanguage) in
                Button(choice.interfaceTitle) { language = choice }
            }
            Menu("Diğer diller") {
                ForEach(choices.others, id: \.self) { (choice: ShareLanguage) in
                    Button(choice.interfaceTitle) { language = choice }
                }
            }
        } label: {
            Label {
                Text(verbatim: language.interfaceTitle)
            } icon: {
                Image(systemName: "globe")
            }
        }
        .disabled(phase == .drafting)
        .accessibilityLabel("Takip e-postasının dili")
    }

    /// Konu ve gövdeyi panoya kopyalar (ilk satır konu).
    private func copy() {
        UIPasteboard.general.string = "\(subject)\n\n\(text)"
        actionMessage = String(localized: "Takip e-postası kopyalandı")
    }

    /// Taslağı e-posta uygulamasında yeni ileti olarak açar; alıcılar bağlı takvim etkinliğinin katılımcıları (yoksa boş).
    private func openInMail() {
        let draft: FollowUpEmailDraft = FollowUpEmailDraft(subject: subject, body: text)
        guard let url = followUpMailtoURL(draft: draft, recipients: store.followUpRecipients(meetingID: meetingID)) else {
            actionMessage = String(localized: "Mail açılamadı: taslak e-posta bağlantısına çevrilemedi. \"Kopyala\" ile yapıştırabilirsin.")
            return
        }
        openURL(url) { (accepted: Bool) -> Void in
            actionMessage = accepted ? nil : String(localized: "Mail açılamadı: bu iPhone'da e-posta uygulaması yok. \"Paylaş\" ya da \"Kopyala\" ile gönderebilirsin.")
        }
    }
}

/// Takip e-postası sayfasının durumu.
private enum PhoneFollowUpPhase: Equatable {
    case drafting
    case ready
    case failed(String)
}

/// Transkript: konuşmacılı paragraflar (≤30 sn), sohbet gibi rozetle. Çalan paragraf hafif dolgulu ve kelime kelime
/// vurgulu; görünür alanın üst üçte birine kayar. Paragrafa dokununca oradan çalar.
private struct TranscriptList: View {
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    let player: MeetingAudioPlayer
    let canPlay: Bool
    let proxy: ScrollViewProxy
    /// İşaretli paragrafların kimlikleri (yıldızla görünür).
    let highlighted: Set<String>
    /// İşaret konabilir (kayıtta, işlenen ya da notu yazılan toplantıda değil).
    let isEditable: Bool
    let onToggleHighlight: @MainActor (TranscriptParagraph) -> Void
    /// Paragrafın sesini klip olarak paylaşır (uzun basınca).
    let onClip: @MainActor (TranscriptParagraph) -> Void
    /// Toplantı sonu çevirisi yapılamayan parçaları yeniden çevirir ("Çeviri alınamadı · Tekrar dene").
    let onRetryTranslation: @MainActor () -> Void
    let onPlay: @MainActor (Double) -> Void
    /// Çalan paragraf: yalnızca paragraf değişince yazılır (tüm liste saniyede onlarca kez yeniden çizilmesin).
    @State private var activeID: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if paragraphs.isEmpty {
                EmptyStateCard(symbol: "text.alignleft", title: "Transkript yok", message: nil)
            }
            ForEach(Array(paragraphs.enumerated()), id: \.element.id) { (item: (offset: Int, element: TranscriptParagraph)) in
                let paragraph: TranscriptParagraph = item.element
                let continues: Bool = item.offset > 0
                    && paragraphs[item.offset - 1].speaker == paragraph.speaker && paragraphs[item.offset - 1].person == paragraph.person
                let isActive: Bool = activeID == paragraph.id
                Button {
                    onPlay(paragraph.startSec)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if continues {
                                Color.clear
                            } else {
                                SpeakerBadge(speaker: paragraph.speaker, person: paragraph.person, size: 30)
                            }
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if !continues {
                                    Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames))
                                        .appFont(size: 13, weight: .semibold)
                                        .foregroundStyle(paragraph.person.map { personColor(person: $0) } ?? Theme.ink)
                                }
                                Text(timestamp(seconds: paragraph.startSec))
                                    .appFont(size: 11, weight: .regular)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.muted)
                                if highlighted.contains(paragraph.id) {
                                    Image(systemName: "star.fill")
                                        .appFont(size: 10, weight: .semibold)
                                        .foregroundStyle(appearance.accent.color)
                                        .accessibilityLabel(Text("İşaretli"))
                                }
                            }
                            Group {
                                if isActive {
                                    KaraokeParagraph(words: paragraph.words, player: player, accent: appearance.accent.color)
                                } else {
                                    Text(paragraph.text).foregroundStyle(Theme.ink)
                                }
                            }
                            .readingText(size: 16, weight: .regular, lineSpacing: 4)
                            if let turkish = paragraph.turkish {
                                Text(turkish)
                                    .readingText(size: 14, weight: .regular, lineSpacing: 3)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(isActive ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, continues ? 0 : 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                // Uzun basınca: işaretle (Mac'teki transkript işareti; not yenilenince öne çıkar), sesini klip olarak paylaş
                // ve kopyala.
                .contextMenu {
                    let isHighlighted: Bool = highlighted.contains(paragraph.id)
                    Button(isHighlighted ? "İşareti kaldır" : "İşaretle", systemImage: isHighlighted ? "star.slash" : "star") {
                        onToggleHighlight(paragraph)
                    }
                    .disabled(!isEditable)
                    Button("Ses klibini paylaş", systemImage: "waveform") { onClip(paragraph) }
                        .disabled(!canPlay)
                    Button("Metni kopyala", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = paragraph.text
                    }
                }
                .id(paragraph.id)
                // Oynatma düğmesinin içinde değil, altında: iç içe düğme dokunuşu oynatmaya giderdi.
                if paragraph.translationFailed {
                    Button(action: onRetryTranslation) {
                        Label("Çeviri alınamadı · Tekrar dene", systemImage: "arrow.clockwise")
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(NoticeSeverity.attention.tint)
                            .padding(.vertical, 4)
                            .padding(.leading, 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEditable)
                }
            }
        }
        .padding(.horizontal, -10)
        .background {
            PlaybackFollower(player: player, meetingID: record.id, paragraphs: paragraphs) { (id: String?) -> Void in
                withAnimation(.easeOut(duration: 0.2)) { activeID = id }
                if let id, player.isPlaying {
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
            }
        }
    }
}

private let meetingReadLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Meetings")

#if DEBUG
/// Görsel kontrolün sahte toplantı sorusu (`--sor-ornek`): transkriptin ilk sözüne dayanan kısa bir cevap. Saf
/// fonksiyondur.
private func phoneDemoMeetingExchange(record: MeetingRecord, paragraphs: [TranscriptParagraph]) -> ArchiveExchange {
    let sources: [ArchivePassage] = paragraphs.prefix(1).map { (paragraph: TranscriptParagraph) -> ArchivePassage in
        ArchivePassage(
            id: "demo-\(paragraph.id)", meetingID: record.id, meetingTitle: record.note?.title ?? record.title, meetingDate: record.startedAt, kind: .transcript,
            startSec: paragraph.startSec, text: paragraph.text
        )
    }
    let tasks: [String] = (record.note?.tasks ?? []).filter(\.isMine).map { "- **\($0.description)**\($0.dueDate.map { " (\($0))" } ?? "")" }
    let answer: String = (["You have \(tasks.count) tasks from this meeting [1]:", ""] + tasks).joined(separator: "\n")
    return ArchiveExchange(
        id: UUID(), question: "What do I owe people after this meeting?", scopeMeetingIDs: [record.id], scopeTitles: [], recipeTitle: nil, startedAt: Date(),
        phase: .done, terms: [], passages: sources, screens: 0, answer: ArchiveAnswer(text: answer, sources: sources, webSources: []), webQueries: [],
        webSearchNotice: .ok, skippedMeetings: [], finishedAt: Date()
    )
}
#endif
