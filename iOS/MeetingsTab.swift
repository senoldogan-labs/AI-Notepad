import AINotepadCore
import AINotepadUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import os

/// Toplantılar: tarihe göre gruplanmış film gradyanlı kartlar ve arama; uzun basınca Markdown kopyası, klasöre taşıma ve
/// silme. Dokununca toplantı sayfası. "Seç" (Mac'teki gibi) birden çok toplantıyı birlikte siler ya da klasöre taşır;
/// silinen toplantı Son silinenler'e gider (listenin sonunda). Klasör çiplerinde "+" boş klasör açar, uzun basınca
/// klasör silinir (toplantılar kalır). Sağ üstteki "İçe aktar" ses ya da video dosyasını (Dosyalar ya da Fotoğraflar)
/// toplantı olarak ekler.
struct MeetingsTab: View {
    let store: PhoneStore
    /// İçe aktarma ve toplantıyı yeniden işleme (⋯ › Tekrar işle) için.
    let recorder: PhoneRecorder
    @Bindable var router: PhoneRouter
    let player: MeetingAudioPlayer
    /// Kayıt sürüyorsa çalma kapalıdır (mikrofon ve hoparlör aynı ses oturumunu paylaşamaz).
    let isRecording: Bool
    /// Toplantı sayfasındaki ⋯ › Tarif uygula: tarifler ve seçilen tarifi toplantıya (kimliği) Sor'da uygulayan.
    let recipes: [Recipe]
    let onRunRecipe: @MainActor (Recipe, String) -> Void
    @State private var query: String = ""
    /// Liste süzgeci (Mac'teki Hepsi / Görevlerim / Hatalı) ya da klasör.
    @State private var scope: MeetingListScope = .filter(.all)
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
    /// Dosyalar seçicisi açık (ses ya da video içe aktarma).
    @State private var isPickingFiles: Bool = false
    /// Fotoğraflar seçicisi açık; seçilen videolar.
    @State private var isPickingVideos: Bool = false
    @State private var pickedVideos: [PhotosPickerItem] = []
    /// Fotoğraflar'dan seçilen videolar uygulamaya kopyalanıyor (dönüştürme ondan sonra başlar).
    @State private var isLoadingVideos: Bool = false
    /// Seçici ya da Fotoğraflar kopyası hatası.
    @State private var pickError: String?
    #if CALL_CAPTURE_EXPERIMENT
    /// Deneysel görüşme kaydı sayfası açık (yalnız `CALL_CAPTURE_EXPERIMENT` derlemesinde).
    @State private var isCapturingCall: Bool = false
    #endif
    /// Kart, açılan toplantıya büyüyerek geçer (kapanınca kartına döner).
    @Namespace private var cardTransition: Namespace.ID
    /// Notlardaki konuşmacı etiketleri adlarla gösterilir; adı kullanıcının adı olan konuşmacının görevleri onundur.
    @AppStorage(PhoneSettingsKey.userName) private var userName: String = ""

    var body: some View {
        // Kartlar ve sayfa notu konuşmacı adlarıyla gösterir (saklı not genel etiketleri korur, değişiklikler kimlikle
        // saklı kayda yapılır).
        let meetings: [MeetingRecord] = namedRecords(records: store.meetings, userName: userName)
        let scoped: [MeetingRecord] = meetingsInScope(records: meetings, scope: scope, userName: userName)
        let sections: [MeetingSection] = meetingSections(
            records: filterMeetings(records: scoped, query: query), now: Date(), calendar: .current, locale: interfaceLocale()
        )
        let locked: Set<String> = phoneLockedMeetingIDs(store: store, recorder: recorder)
        // Yalnız görünen işaretliler sayılır ve işlenir (Mac'teki gibi): arama, klasör ya da süzgeç değişince gizlenen
        // işaretliler işlemden çıkar.
        let visibleIDs: Set<String> = Set(sections.flatMap(\.meetings).map(\.id))
        let effective: Set<String> = checked.intersection(visibleIDs)
        NavigationStack(path: $router.meetingsPath) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    PhoneErrorList(messages: store.loadProblems + recorder.importErrors + libraryErrors + [pickError].compactMap { $0 })
                    PhoneDismissibleErrorList(messages: store.actionProblems) { store.dismissActionProblems() }
                    if recorder.importingCount > 0 || isLoadingVideos {
                        ImportProgressRow()
                    }
                    if !store.meetings.isEmpty {
                        MeetingScopeChips(
                            records: meetings, folders: store.folders, userName: userName, selection: $scope,
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
                    if !store.deletedMeetings.isEmpty, !isSelecting, !sections.isEmpty {
                        RecentlyDeletedLink(store: store, recorder: recorder)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .overlay {
                emptyOverlay(hasResults: !sections.isEmpty)
            }
            .background(Theme.background)
            .navigationTitle("Toplantılar")
            .searchable(text: $query, prompt: "Toplantılarda ara")
            // Seç modunda alt çubuk sekme çubuğunun yerini alır (Fotoğraflar'daki gibi).
            .toolbar(isSelecting ? .hidden : .visible, for: .tabBar)
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Bitti") { setSelecting(false) }
                            .fontWeight(.semibold)
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        selectionBar(effective: effective, selectable: visibleIDs.subtracting(locked), locked: locked)
                    }
                } else {
                    if !store.meetings.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Seç") { setSelecting(true) }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            PhonePeopleList(store: store, router: router)
                        } label: {
                            Label("Kişiler", systemImage: "person.2")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        importMenu
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
            .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { (result: Result<[URL], any Error>) in
                switch result {
                case .success(let urls):
                    pickError = nil
                    Task { await recorder.importFiles(urls: urls) }
                case .failure(let error):
                    pickError = String(localized: "Dosya seçilemedi: \(userFacingMessage(error: error))")
                }
            }
            .photosPicker(isPresented: $isPickingVideos, selection: $pickedVideos, matching: .videos, photoLibrary: .shared())
            #if CALL_CAPTURE_EXPERIMENT
            .sheet(isPresented: $isCapturingCall) {
                CallCaptureExperimentScreen(recorder: recorder, isRecording: isRecording)
            }
            #endif
            .onChange(of: pickedVideos) { (_: [PhotosPickerItem], items: [PhotosPickerItem]) in
                guard !items.isEmpty else {
                    return
                }
                pickedVideos = []
                importVideos(items: items)
            }
            .navigationDestination(for: String.self) { (id: String) in
                if let record = meetings.first(where: { $0.id == id }) {
                    // Onay toplantı sayfasının kendisinde sorulur (listeye bağlı onay sayfa kapanana dek görünmüyordu).
                    MeetingReadView(record: record, store: store, player: player, isRecording: isRecording, recipes: recipes) {
                        delete(record: record)
                    } onReprocess: {
                        try recorder.reprocess(meetingID: record.id)
                    } onRunRecipe: { (recipe: Recipe) -> Void in
                        onRunRecipe(recipe, record.id)
                    }
                    .navigationTransition(.zoom(sourceID: id, in: cardTransition))
                } else if store.deletedMeetings.contains(where: { $0.id == id }) {
                    // Son silinenlerdeki toplantı (Sor'daki kaynak, görev ya da kişi buraya götürdü): geri yüklenebilir.
                    PhoneEmptyState(symbol: "trash", title: "Bu toplantı silindi", message: "Son silinenler'den geri yükleyebilirsin.") {
                        Button("Geri yükle", systemImage: "arrow.uturn.backward") { restore(ids: [id]) }
                            .buttonStyle(.accentPill)
                    }
                    .background(Theme.background)
                } else {
                    // Toplantı silindi (ör. Mac'ten): boş sayfa yerine neden görünür.
                    PhoneEmptyState(symbol: "doc.questionmark", title: "Toplantı bulunamadı", message: "Bu toplantı silinmiş olabilir.") {
                        EmptyView()
                    }
                    .background(Theme.background)
                }
            }
            .refreshable { await store.reloadAndWait() }
        }
        // Toplantı sayfasındaki "Şimdi dene" (bekleyen kayıt) kaydediciye buradan ulaşır.
        .environment(recorder)
        // Uzun basınca silme: ekranın ortasında uyarı (kartın üstünde açılan menü listeye bağlıydı, sayfadayken görünmüyordu).
        .modifier(MeetingDeleteConfirmation(pending: $pendingDelete) { (record: MeetingRecord) -> Void in delete(record: record) })
    }

    /// Fotoğraflar'dan seçilen videoları geçici klasöre kopyalar, toplantı olarak içe aktarır ve kopyaları siler.
    /// Kopyalanamayan video atlanır, nedeni listede görünür.
    private func importVideos(items: [PhotosPickerItem]) {
        pickError = nil
        isLoadingVideos = true
        Task {
            var copies: [PickedMovie] = []
            var failures: [String] = []
            for item in items {
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        throw MediaImportError.readFailed(path: item.itemIdentifier ?? "?", reason: "Fotoğraflar videoyu vermedi")
                    }
                    copies.append(movie)
                } catch {
                    failures.append(userFacingMessage(error: error))
                }
            }
            isLoadingVideos = false
            pickError = failures.isEmpty ? nil : String(localized: "Video alınamadı: \(failures.joined(separator: "; "))")
            await recorder.importFiles(urls: copies.map(\.url))
            for copy in copies {
                removePickedMovie(movie: copy)
            }
        }
    }

    /// Sağ üstteki "İçe aktar": ses ya da video dosyası (Dosyalar ya da Fotoğraflar).
    private var importMenu: some View {
        Menu {
            Section("Ses ya da video dosyası içe aktar") {
                Button("Dosyalar'dan seç", systemImage: "folder") { isPickingFiles = true }
                Button("Fotoğraflar'dan video seç", systemImage: "photo.on.rectangle") { isPickingVideos = true }
            }
            #if CALL_CAPTURE_EXPERIMENT
            Section {
                Button { isCapturingCall = true } label: {
                    Label { Text(verbatim: "Bu iPhone'daki görüşmeyi kaydet (deneysel)") } icon: { Image(systemName: "phone.badge.waveform") }
                }
            }
            #endif
        } label: {
            Label("İçe aktar", systemImage: "square.and.arrow.down")
        }
        .disabled(isLoadingVideos)
    }

    /// Liste kartı: seç modunda işaretlenir; değilse dokununca açılır, uzun basınca menü (Mac'teki satır menüsü gibi).
    @ViewBuilder
    private func card(record: MeetingRecord, locked: Set<String>) -> some View {
        if isSelecting {
            SelectableMeetingCard(record: record, isChecked: checked.contains(record.id), isLocked: locked.contains(record.id)) {
                toggle(id: record.id)
            }
        } else {
            NavigationLink(value: record.id) {
                PhoneMeetingCard(record: record, height: 132)
                    .matchedTransitionSource(id: record.id, in: cardTransition)
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
    @ViewBuilder
    private func emptyOverlay(hasResults: Bool) -> some View {
        if store.meetings.isEmpty {
            PhoneEmptyScene(
                symbol: "waveform", palette: .sunset, title: "Henüz toplantı yok",
                message: "İlk toplantını kaydet; not, görevler ve transkript burada hazır olur."
            ) {
                VStack(spacing: 12) {
                    Button("Kaydı başlat", systemImage: "mic.fill") { router.tab = .record }
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
        } else if !hasResults {
            if case .folder = scope, query.trimmingCharacters(in: .whitespaces).isEmpty {
                PhoneEmptyState(symbol: "folder", title: "Bu klasör boş", message: "Toplantı sayfasındaki \"Klasöre taşı\" ile buraya ekle.") {
                    Button("Tüm toplantılar") { scope = .filter(.all) }
                        .buttonStyle(.accentPill)
                }
            } else {
                PhoneEmptyState(symbol: "magnifyingglass", title: "Eşleşen toplantı yok", message: "Başka bir kelimeyle ara.") {
                    EmptyView()
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

    /// Toplantıları son silinenlere taşır (çalan toplantı önce durur, açık sayfası kapanır); hatalar döner.
    private func trash(ids: Set<String>) -> [String] {
        if let playing = player.meetingID, ids.contains(playing) {
            player.stop()
            store.playingMeetingID = nil
        }
        let errors: [String] = store.trashMeetings(ids: ids, locked: phoneLockedMeetingIDs(store: store, recorder: recorder), now: Date())
        let remaining: Set<String> = Set(store.meetings.map(\.id))
        router.meetingsPath.removeAll { ids.contains($0) && !remaining.contains($0) }
        return errors
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
            scope = .filter(.all)
        }
    }

    /// Silinen toplantıyı geri yükler; bekleyen kayıt geri geldiyse kuyruk çalışır.
    private func restore(ids: Set<String>) {
        let result: (restored: [MeetingRecord], errors: [String]) = store.restoreDeleted(ids: ids)
        libraryErrors = result.errors
        if result.restored.contains(where: { $0.status == .queued }) {
            Task { await recorder.runQueue() }
        }
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

/// Listenin üstündeki çipler: Tümü, Görevlerim, Hatalı (varsa), klasörler (boş olanlar dahil, sayılarıyla) ve yeni klasör
/// ("+"); yatay kayar. Klasöre uzun basınca silinir (toplantılar kalır). Seçilen süzgeç boşalırsa ya da klasör artık
/// yoksa Tümü'ne döner (boş klasör seçili kalır: "Bu klasör boş").
private struct MeetingScopeChips: View {
    let records: [MeetingRecord]
    let folders: [FolderSummary]
    let userName: String
    @Binding var selection: MeetingListScope
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

/// Toplantı sayfası: kapak (tarih, başlık, çipler, konuşmacı şeridi, Dinle, paylaş), Özet (görevler, özet, bir bakışta,
/// konuşma payları, kararlar, konu akışı, diğer görevler, sözlük) ve Transkript (konuşmacılı paragraflar; çalarken o
/// anki kelime vurgulanır, dokununca oradan çalar). Sağ üstte paylaş ve sil.
struct MeetingReadView: View {
    let record: MeetingRecord
    let store: PhoneStore
    let player: MeetingAudioPlayer
    let isRecording: Bool
    /// ⋯ › Tarif uygula: yerleşik ve kullanıcı tarifleri.
    let recipes: [Recipe]
    /// Onaylanan silme: toplantıyı siler ve sayfayı kapatır (onay bu sayfada sorulur).
    let onDelete: @MainActor () -> Void
    /// "Tekrar işle": son geçiş ve not yeniden (bkz. `PhoneRecorder.reprocess`).
    let onReprocess: @MainActor () throws -> Void
    /// ⋯ › Tarif uygula: seçilen tarif bu toplantıya Sor'da uygulanır.
    let onRunRecipe: @MainActor (Recipe) -> Void
    @State private var pane: MeetingPane = .summary
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
    /// Başka dile çevrilip paylaşılacak not: çevrilirken dil, çevrilince paylaşım metni.
    @State private var translatingLanguage: ShareLanguage?
    @State private var sharedText: SharedText?
    /// "Sesi sil" satır içi onayı bekliyor (Mac'teki gibi; ayrı uyarı penceresi yok).
    @State private var isConfirmingAudioDelete: Bool = false
    /// Çevrilen notta da konuşmacı adları gösterilir.
    @AppStorage(PhoneSettingsKey.userName) private var userName: String = ""

    /// Not ve adlar değiştirilebilir: kayıtta, işlenen ya da notu yazılan toplantıda değil.
    private var isEditable: Bool {
        record.status != .recording && record.status != .processing && !store.regeneratingIDs.contains(record.id)
    }

    var body: some View {
        let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero(paragraphs: paragraphs)
                    // Çalma hatası (dosya açılamadı, ses oturumu) da burada görünür.
                    let messages: [String] = [errorMessage, player.errorMeetingID == record.id ? player.errorMessage : nil].compactMap { $0 }
                    if !messages.isEmpty {
                        PhoneErrorList(messages: messages)
                    }
                    // Not yenileme, şablonla yazma, not düzenleme ve çeviri hataları (yalnız listede kalsaydı sayfada
                    // dönen çark sessizce dururdu).
                    PhoneDismissibleErrorList(messages: store.actionProblems) { store.dismissActionProblems() }
                    if let language = translatingLanguage {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Not \(language.interfaceName) diline çevriliyor…")
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
                    }
                    PillTabs(selection: $pane, options: [(MeetingPane.summary, "Özet"), (MeetingPane.transcript, "Transkript")])
                    switch pane {
                    case .summary:
                        MeetingSummary(
                            record: record, paragraphs: paragraphs, store: store, canPlay: canPlay, isEditable: isEditable,
                            onNameSpeakers: { isNamingSpeakers = true }, onEditMyNotes: { isEditingMyNotes = true }
                        ) { (startSec: Double) -> Void in
                            play(from: startSec)
                        }
                        .transition(.opacity)
                    case .transcript:
                        let skipped: [StoredSegment] = skippedLanguageSegments(record: record)
                        if !skipped.isEmpty {
                            SkippedLanguageNote(record: record, segments: skipped)
                        }
                        TranscriptList(
                            record: record, paragraphs: paragraphs, player: player, canPlay: canPlay, proxy: proxy,
                            highlighted: highlightedParagraphIDs(paragraphs: paragraphs, highlights: record.highlights ?? []),
                            isEditable: isEditable, onToggleHighlight: toggleHighlight(paragraph:)
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
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let note = record.note {
                        ShareLink(item: shareText(record: record, note: note, language: nil)) {
                            Label("Notu paylaş", systemImage: "square.and.arrow.up")
                        }
                        // Mac'teki dil menüsü gibi: sık kullanılan Fince ve İngilizce önde, diğerleri alt menüde.
                        Menu("Başka dilde paylaş", systemImage: "character.bubble") {
                            ForEach([ShareLanguage.finnish, .english].filter { $0 != note.writtenLanguage }, id: \.rawValue) { (language: ShareLanguage) in
                                Button(language.interfaceName) { shareTranslated(language: language) }
                            }
                            Menu("Diğer diller") {
                                ForEach(ShareLanguage.allCases.filter { ![.finnish, .english, note.writtenLanguage].contains($0) }, id: \.rawValue) { (language: ShareLanguage) in
                                    Button(language.interfaceName) { shareTranslated(language: language) }
                                }
                            }
                        }
                        .disabled(translatingLanguage != nil)
                    }
                    Menu("Dışa aktar", systemImage: "square.and.arrow.down") {
                        ForEach(MeetingExportFormat.allCases.filter { isMeetingExportAvailable(record: record, format: $0) }) { (format: MeetingExportFormat) in
                            Button(format.title, systemImage: format.systemImage) { export(format: format) }
                        }
                    }
                    Button("Markdown olarak kopyala", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = meetingMarkdown(record: record)
                        recordFeatureUsage(feature: .export(.copyMarkdown))
                    }
                    // Mac'teki "Tarif": bu toplantıya tarif uygular, cevap Sor'da açılır.
                    Menu("Tarif uygula", systemImage: "wand.and.stars") {
                        ForEach(recipes) { (recipe: Recipe) in
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
                                    Label(kind.displayName, systemImage: "checkmark")
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
                    Button("Tekrar işle", systemImage: "arrow.triangle.2.circlepath") { reprocess() }
                        .disabled(!isEditable || record.audioDeleted)
                    Divider()
                    Button("Sesi sil", systemImage: "speaker.slash", role: .destructive) { isConfirmingAudioDelete = true }
                        .disabled(!isEditable || record.audioDeleted || record.status == .queued)
                    Button("Sil", systemImage: "trash", role: .destructive) { pendingDelete = record }
                        .disabled(!isEditable)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Diğer")
            }
        }
        .modifier(MeetingDeleteConfirmation(pending: $pendingDelete) { (_: MeetingRecord) -> Void in onDelete() })
        .sheet(item: $exported) { (file: ExportedFile) in
            ActivityShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $sharedText) { (shared: SharedText) in
            TextShareSheet(text: shared.text)
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
        }
        #endif
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

    /// Notu verilen dile çevirir (daha önce çevrildiyse saklanan kopya) ve paylaşım sayfasını açar; olmazsa neden sayfada
    /// görünür.
    private func shareTranslated(language: ShareLanguage) {
        translatingLanguage = language
        Task {
            defer { translatingLanguage = nil }
            do {
                let stored: MeetingNote = try await store.sharedNote(meetingID: record.id, language: language)
                let note: MeetingNote = namedNote(note: stored, speakerNames: record.speakerNames, userName: userName)
                sharedText = SharedText(text: shareText(record: record, note: note, language: language))
                errorMessage = nil
            } catch {
                errorMessage = String(localized: "Not çevrilemedi: \(userFacingMessage(error: error))")
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

    /// Toplantıyı dosya olarak yazar ve paylaşım sayfasını açar; olmazsa neden sayfada görünür.
    private func export(format: MeetingExportFormat) {
        do {
            exported = ExportedFile(url: try writeMeetingExport(record: record, format: format))
            recordFeatureUsage(feature: .export(format.telemetryFormat))
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Dışa aktarılamadı: \(userFacingMessage(error: error))")
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

    private func hero(paragraphs: [TranscriptParagraph]) -> some View {
        let shares: [SpeakerShare] = speakerShares(paragraphs: paragraphs)
        // Kısa konuşmalar (bkz. `groupedSpeakers`) konuşmacı sayısına girmez.
        let majorCount: Int = groupedSpeakers(shares: shares, speakerNames: record.speakerNames).major.count
        let totalSec: Double = paragraphs.map(\.endSec).max() ?? 0
        let isPlayingThis: Bool = player.meetingID == record.id && player.isPlaying
        return VStack(alignment: .leading, spacing: 12) {
            Text(interfaceUppercased(text: record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(interfaceLocale()))))
                .appFont(size: 11, weight: .semibold)
                .tracking(0.6)
                .opacity(0.88)
            Text(record.note?.title ?? record.title)
                .appFont(size: 27, weight: .regular)
                .tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 1)
            HStack(spacing: 6) {
                if let minutes = meetingDurationMinutes(record: record) {
                    GlassChip(text: String(localized: "\(minutes) dk"), systemImage: "clock")
                }
                if let language = record.language {
                    GlassChip(text: languageName(language: language), systemImage: nil)
                }
                if !shares.isEmpty {
                    GlassChip(text: String(localized: "\(majorCount) konuşmacı"), systemImage: "person.2")
                }
            }
            if totalSec > 0, !shares.isEmpty {
                SpeakerStrip(spans: speakerSpans(paragraphs: paragraphs), totalSec: totalSec)
                    .padding(.top, 4)
            }
            HStack(spacing: 10) {
                if canPlay {
                    Button {
                        if player.meetingID == record.id {
                            player.togglePause()
                        } else {
                            play(from: 0)
                        }
                    } label: {
                        Label(isPlayingThis ? "Duraklat" : "Dinle", systemImage: isPlayingThis ? "pause.fill" : "play.fill")
                            .appFont(size: 15, weight: .semibold)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.white, in: Capsule())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PressableCardStyle())
                }
                Spacer()
                if let note = record.note {
                    ShareLink(item: shareText(record: record, note: note, language: nil)) {
                        Image(systemName: "square.and.arrow.up")
                            .appFont(size: 15, weight: .semibold)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.18), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.28)))
                    }
                    .accessibilityLabel("Notu paylaş")
                }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .bottomLeading)
        .background {
            CoverBackground(seed: record.id)
                .overlay { CoverScrim() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    /// Ses varsa ve kayıt sürmüyorsa çalınabilir.
    private var canPlay: Bool {
        !isRecording && !record.audioDeleted && (record.status == .done || record.status == .failed || record.status == .interrupted)
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
            player.play(meetingID: record.id, urls: urls, startSec: startSec)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

/// Özet: senin görevlerin (işaretlenebilir), özet, bir bakışta, kim ne kadar konuştu, kararlar, konu akışı (dokununca
/// oradan çalar), diğer görevler, sözlük.
private struct MeetingSummary: View {
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    let store: PhoneStore
    let canPlay: Bool
    /// Not ve konuşmacı adları değiştirilebilir (kayıtta, işlenen ya da notu yazılan toplantıda değil).
    let isEditable: Bool
    let onNameSpeakers: @MainActor () -> Void
    let onEditMyNotes: @MainActor () -> Void
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        if let note = record.note {
            let mine: [NoteTask] = note.tasks.filter(\.isMine)
            let others: [NoteTask] = note.tasks.filter { !$0.isMine }
            let shares: [SpeakerShare] = speakerShares(paragraphs: paragraphs)
            let groups: SpeakerGroups = groupedSpeakers(shares: shares, speakerNames: record.speakerNames)
            VStack(alignment: .leading, spacing: 26) {
                if mine.isEmpty {
                    Label("Bu toplantıda sana düşen görev yok", systemImage: "checkmark.circle")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    section(title: "Senin görevlerin") {
                        ForEach(mine, id: \.trackingKey) { (task: NoteTask) in
                            PhoneTaskRow(record: record, task: task, showsMeeting: false) {
                                withAnimation(.smooth(duration: 0.25)) { store.toggleTask(meetingID: record.id, task: task) }
                            }
                        }
                    }
                }
                if let myNotes = record.myNotes {
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
                        Text(myNotes)
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
                if record.myNotes == nil && isEditable {
                    Button(action: onEditMyNotes) {
                        Label("Kendi notunu ekle", systemImage: "square.and.pencil")
                            .appFont(size: 14, weight: .medium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appearance.accent.color)
                }
                PhoneNoteEditBar(isWorking: store.regeneratingIDs.contains(record.id), isEnabled: isEditable) { (instruction: String) -> Void in
                    Task { await store.editNote(meetingID: record.id, instruction: instruction) }
                }
                Text(note.summary)
                    .readingText(size: 18, weight: .regular, lineSpacing: 6)
                    .textSelection(.enabled)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    PhoneStatTile(value: meetingDurationMinutes(record: record).map { String(localized: "\($0) dk") } ?? "–", label: "süre")
                    PhoneStatTile(value: "\(groups.major.count)", label: groups.minor.isEmpty ? "konuşmacı" : "konuşmacı (+\(groups.minor.count) kısa)")
                    PhoneStatTile(value: "\(note.decisions.count)", label: "karar")
                    PhoneStatTile(value: "\(mine.count)", label: "senin görevin")
                }
                if shares.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        // Adı verilebilecek konuşmacı varsa başlıkta "Ad ver" (transkript ve not adlarla görünür).
                        PhoneSectionHeader(
                            title: "Kim ne kadar konuştu",
                            actionTitle: isEditable && shares.contains(where: { $0.key.person != nil }) ? "Ad ver" : nil,
                            action: onNameSpeakers
                        )
                        ForEach(Array(groups.major.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerShare)) in
                            ShareRow(share: item.element, speakerNames: record.speakerNames)
                        }
                        // Az konuşanlar tek satırda; dokununca tek tek görünür (ad vermek için "Ad ver").
                        if !groups.minor.isEmpty {
                            MinorSpeakersRow(groups: groups, speakerNames: record.speakerNames)
                        }
                    }
                }
                if !note.decisions.isEmpty {
                    section(title: "Kararlar") {
                        ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(verbatim: "\(item.offset + 1)")
                                    .appFont(size: 13, weight: .semibold)
                                    .monospacedDigit()
                                    .foregroundStyle(appearance.accent.color)
                                    .frame(width: 18, alignment: .trailing)
                                Text(item.element)
                                    .readingText(size: 16, weight: .regular, lineSpacing: 3)
                            }
                        }
                    }
                }
                let marked: [TranscriptParagraph] = markedParagraphs
                if !marked.isEmpty {
                    section(title: "İşaretlediğin anlar") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(marked, id: \.id) { (paragraph: TranscriptParagraph) in
                                HighlightRow(paragraph: paragraph, speakerNames: record.speakerNames, canPlay: canPlay) {
                                    onPlay(paragraph.startSec)
                                }
                            }
                        }
                    }
                }
                if let outline = note.outline, !outline.isEmpty {
                    section(title: "Konu akışı") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(outline.enumerated()), id: \.offset) { (item: (offset: Int, element: OutlineItem)) in
                                OutlineRow(item: item.element, isLast: item.offset == outline.count - 1, canPlay: canPlay) {
                                    onPlay(item.element.startSec)
                                }
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    section(title: "Diğer görevler") {
                        ForEach(others, id: \.trackingKey) { (task: NoteTask) in
                            PhoneTaskRow(record: record, task: task, showsMeeting: false) {
                                withAnimation(.smooth(duration: 0.25)) { store.toggleTask(meetingID: record.id, task: task) }
                            }
                        }
                    }
                }
                if !note.glossary.isEmpty {
                    PhoneGlossarySection(glossary: note.glossary)
                }
            }
        } else {
            EmptyStateCard(symbol: "doc.text", title: "Bu toplantının notu yok", message: nil)
        }
    }

    /// İşaretli paragraflar (kayıtta "İşaretle" ya da transkriptte uzun basarak), zaman sırasıyla.
    private var markedParagraphs: [TranscriptParagraph] {
        let ids: Set<String> = highlightedParagraphIDs(paragraphs: paragraphs, highlights: record.highlights ?? [])
        return paragraphs.filter { ids.contains($0.id) }
    }

    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PhoneSectionHeader(title: title, actionTitle: nil, action: nil)
            content()
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
/// dokununca soluk liste. Bölümler kayıtta durur.
private struct SkippedLanguageNote: View {
    let record: MeetingRecord
    let segments: [StoredSegment]
    @State private var isExpanded: Bool = false

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
                    Text(verbatim: "\(timestamp(seconds: segment.startSec))  \(segment.person.flatMap { record.speakerNames[$0] } ?? speakerLabel(speaker: segment.speaker, person: segment.person)): \(segment.text)")
                        .appFont(size: 13, weight: .regular)
                        .italic()
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
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

/// Konu akışı satırı: solda saat ve ince dikey çizgi (zaman çizelgesi), sağda başlık ve tek cümle; dokununca çalar.
private struct OutlineRow: View {
    let item: OutlineItem
    let isLast: Bool
    let canPlay: Bool
    let onPlay: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").appFont(size: 8, weight: .bold)
                        Text(timestamp(seconds: item.startSec))
                            .appFont(size: 12, weight: .semibold)
                            .monospacedDigit()
                    }
                    .foregroundStyle(canPlay ? appearance.accent.color : Theme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((canPlay ? appearance.accent.color : Theme.muted).opacity(0.10), in: Capsule())
                    if !isLast {
                        Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 66)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).appFont(size: 15, weight: .semibold)
                    Text(item.summary)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                }
                .multilineTextAlignment(.leading)
                .padding(.bottom, isLast ? 0 : 16)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
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
                // Uzun basınca: işaretle (Mac'teki transkript işareti; not yenilenince öne çıkar) ve kopyala.
                .contextMenu {
                    let isHighlighted: Bool = highlighted.contains(paragraph.id)
                    Button(isHighlighted ? "İşareti kaldır" : "İşaretle", systemImage: isHighlighted ? "star.slash" : "star") {
                        onToggleHighlight(paragraph)
                    }
                    .disabled(!isEditable)
                    Button("Metni kopyala", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = paragraph.text
                    }
                }
                .id(paragraph.id)
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

/// İçe aktarma sürüyor: ince satır, dönen gösterge ve kısa açıklama.
private struct ImportProgressRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("İçe aktarılıyor… Bitince sunucuda işlenir; not hazır olunca burada görünür.")
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Fotoğraflar'dan kopyalanan video: kendi geçici klasöründe, özgün adıyla (toplantının başlığı dosya adından gelir).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { (received: ReceivedTransferredFile) throws -> PickedMovie in
            let folder: URL = FileManager.default.temporaryDirectory.appending(path: "PickedMovies/\(UUID().uuidString)", directoryHint: .isDirectory)
            let destination: URL = folder.appending(path: received.file.lastPathComponent, directoryHint: .notDirectory)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: received.file, to: destination)
            } catch {
                throw StorageError.writeFailed(path: destination.path, reason: error.localizedDescription)
            }
            return PickedMovie(url: destination)
        }
    }
}

/// İçe aktarılan videonun geçici kopyasını (klasörüyle) siler; silinemezse loglanır (geçici klasörü iOS zamanla temizler).
@MainActor
private func removePickedMovie(movie: PickedMovie) {
    do {
        try FileManager.default.removeItem(at: movie.url.deletingLastPathComponent())
    } catch {
        pickedMovieLogger.error("Geçici video kopyası silinemedi, hata: \(String(describing: error), privacy: .private)")
    }
}

private let pickedMovieLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MediaImport")
