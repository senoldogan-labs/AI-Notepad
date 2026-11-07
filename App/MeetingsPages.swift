import AINotepadCore
import AINotepadUI
import AppKit
import os
import SwiftUI

private let meetingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Meetings")

// MARK: Liste

/// Toplantı listesi (ana pencerenin Toplantılar bölümünde solda): arama, süzgeç ve tarihe göre gruplu (Bugün, Dün,
/// Önceki 7 gün, aylar) yeniden eskiye liste.
struct MeetingsListPage: View {
    let model: AppModel
    /// Açık toplantı (satırı vurgulanır).
    let selectedID: String?
    /// Üst çubuktaki arama.
    let query: String
    /// Kenar çubuğunda seçilen klasör; nil hepsi.
    let folder: String?
    let onClearFolder: @MainActor () -> Void
    let onOpen: @MainActor (String) -> Void
    /// Toplu silmeden sonra (açık toplantı silindiyse sayfa kapanır).
    let onDeleted: @MainActor (Set<String>) -> Void
    /// "Seç" modu: satırlara tıklamak toplantıyı açmaz, işaretler.
    @State private var isSelecting: Bool = false
    @State private var checked: Set<String> = []
    @State private var isConfirmingDelete: Bool = false
    @State private var deleteErrors: [String] = []
    @State private var listFilter: MeetingListFilter = .all
    /// Notlardaki konuşmacı etiketleri adlarla; adı kullanıcının adı olan konuşmacının görevleri onundur.
    private var userName: String { model.userName }

    var body: some View {
        // Satırlar notu konuşmacı adlarıyla gösterir (başlık, görev sayısı); süzgeç saklı kayıtlara uygulanır, sıra korunur.
        let shownIDs: Set<String> = Set(filterMeetings(
            records: filterMeetings(records: meetingsInFolder(records: model.meetings, folder: folder), query: query),
            listFilter: listFilter, userName: userName
        ).map(\.id))
        let visible: [MeetingRecord] = model.namedMeetings(userName: userName).filter { shownIDs.contains($0.id) }
        let sections: [MeetingSection] = meetingSections(records: visible, now: Date(), calendar: .current, locale: interfaceLocale())
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.s) {
                if let folder {
                    Button {
                        onClearFolder()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                            Text(folder).lineLimit(1)
                            Image(systemName: "xmark").appFont(size: 9, weight: .bold)
                        }
                        .appFont(size: 12, weight: .medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.soft, in: Capsule())
                    }
                    .buttonStyle(.hoverCapsule)
                    .hoverHint("Tüm toplantılar", alignment: .leading, edge: .bottom)
                }
                Text(query.isEmpty ? String(localized: "\(visible.count) toplantı") : String(localized: "\(visible.count) sonuç"))
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                if model.importingCount > 0 {
                    ProgressView().controlSize(.small)
                }
                Button("İçe aktar", systemImage: "square.and.arrow.down.on.square") { chooseMediaToImport(model: model) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.pill)
                    .controlSize(.small)
                    .hoverHint("Ses ya da video dosyasından toplantı (sürükleyip bırakabilirsin)", alignment: .trailing, edge: .bottom)
                if !model.meetings.isEmpty {
                    Button(isSelecting ? "Bitti" : "Seç") { setSelecting(!isSelecting) }
                        .buttonStyle(.pill)
                        .controlSize(.small)
                        .hoverHint("Birden çok toplantıyı seçip sil", alignment: .trailing, edge: .bottom)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.m)
            .padding(.vertical, DesignTokens.Spacing.s)
            if !model.meetings.isEmpty {
                PillPicker(selection: $listFilter, options: [
                    (MeetingListFilter.all, "Hepsi"), (MeetingListFilter.myTasks, "Görevlerim"), (MeetingListFilter.problems, "Hatalı"),
                ])
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.bottom, DesignTokens.Spacing.s)
            }
            if let error = model.importError {
                NoticeText(error, severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .padding(.horizontal, DesignTokens.Spacing.m)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Hiç toplantı yokken bu liste gösterilmez (bkz. `MeetingsFirstRun`); burada yalnızca süzülmüş boş sonuçlar.
            if visible.isEmpty {
                emptyResult
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { (section: MeetingSection) in
                            Text(interfaceUppercased(text: section.title))
                                .appFont(size: 11, weight: .semibold)
                                .tracking(DesignTokens.labelTracking)
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, DesignTokens.Spacing.m)
                                .padding(.top, section.id == sections.first?.id ? DesignTokens.Spacing.xs : DesignTokens.Spacing.m)
                                .padding(.bottom, DesignTokens.Spacing.xs)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.meetings) { (record: MeetingRecord) in
                                row(record: record)
                                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.s)
                    .animation(.snappy(duration: 0.3), value: visible.map(\.id))
                }
            }
            if isSelecting {
                selectionBar(visible: visible)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !model.visibleLoadFailures.isEmpty {
                NoticeText("\(model.visibleLoadFailures.count) toplantı okunamadı: \(model.visibleLoadFailures.map(\.folder).joined(separator: ", "))", severity: .error)
                    .appFont(size: 11, weight: .regular)
                    .padding(DesignTokens.Spacing.m)
            }
        }
        .animation(.smooth(duration: 0.25), value: isSelecting)
        .animation(.smooth(duration: 0.25), value: isConfirmingDelete)
    }

    /// Görünen toplantı yokken: süzgeç açıksa "Hepsini göster", boş klasörde "Tüm toplantılar", aramada başka kelime.
    @ViewBuilder
    private var emptyResult: some View {
        if listFilter != .all {
            QuietEmptyState(symbol: "line.3.horizontal.decrease", title: "Eşleşen toplantı yok", message: nil) {
                Button("Hepsini göster") { listFilter = .all }
                    .buttonStyle(.pill)
                    .controlSize(.small)
            }
        } else if query.isEmpty, folder != nil {
            QuietEmptyState(symbol: "folder", title: "Bu klasör boş", message: "Toplantı sayfasındaki \"Klasöre taşı\" ile buraya ekle.") {
                Button("Tüm toplantılar") { onClearFolder() }
                    .buttonStyle(.pill)
                    .controlSize(.small)
            }
        } else {
            QuietEmptyState(symbol: "magnifyingglass", title: "Eşleşen toplantı yok", message: "Başka bir kelimeyle ara.") {
                EmptyView()
            }
        }
    }

    /// Satır: seç modunda işaret kutusu ve tıklayınca işaretleme (kayıttaki/işlenen toplantı seçilemez); değilse açma.
    @ViewBuilder
    private func row(record: MeetingRecord) -> some View {
        let isProcessing: Bool = model.processingMeetingIDs.contains(record.id)
        if isSelecting {
            let isChecked: Bool = checked.contains(record.id)
            Button {
                toggle(id: record.id)
            } label: {
                HStack(spacing: DesignTokens.Spacing.s) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .appFont(size: 16, weight: .regular)
                        .foregroundStyle(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.leading, DesignTokens.Spacing.s)
                    MeetingRow(record: record, isProcessing: isProcessing, isSelected: isChecked)
                }
            }
            .buttonStyle(.hoverPlain)
            .disabled(model.isLocked(meetingID: record.id))
        } else {
            Button {
                onOpen(record.id)
            } label: {
                MeetingRow(record: record, isProcessing: isProcessing, isSelected: record.id == selectedID)
            }
            .buttonStyle(.hoverPlain)
            .contextMenu {
                Button("Aç", systemImage: "arrow.up.right") { onOpen(record.id) }
                Button("Markdown olarak kopyala", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meetingMarkdown(record: record), forType: .string)
                }
                Divider()
                // Çöp Sepeti'ne taşır: Finder'dan geri alınabilir. Seç modu kapalıyken alt çubuk yoktur: hata sağ alttaki
                // bildirimde görünür; silinen toplantı açıksa sayfası kapanır.
                Button("Çöp Sepeti'ne taşı", systemImage: "trash", role: .destructive) {
                    if let error = model.deleteMeeting(meetingID: record.id) {
                        ToastCenter.shared.show(kind: .warning, title: error, detail: nil, action: nil)
                    } else {
                        onDeleted([record.id])
                    }
                }
                .disabled(model.isLocked(meetingID: record.id))
            }
        }
    }

    /// Seç modunun alt çubuğu: tümünü seç, sayı, sil; silmede satır içi onay. Yalnızca görünen işaretli toplantılar
    /// sayılır ve silinir/taşınır: arama, klasör ya da süzgeç değişince gizlenen işaretliler işlemden çıkar.
    private func selectionBar(visible: [MeetingRecord]) -> some View {
        let selectable: Set<String> = Set(visible.map(\.id).filter { !model.isLocked(meetingID: $0) })
        let effective: Set<String> = checked.intersection(Set(visible.map(\.id)))
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            ForEach(deleteErrors, id: \.self) { (error: String) in
                NoticeText(error, severity: .error).appFont(size: 11, weight: .regular)
            }
            if isConfirmingDelete {
                Text("\(effective.count) toplantı (metin, not ve ses) Çöp Sepeti'ne taşınsın mı?")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(NoticeSeverity.error.tint)
                HStack(spacing: DesignTokens.Spacing.s) {
                    Button("Sil", role: .destructive) { deleteChecked(ids: effective) }
                    Button("Vazgeç") { isConfirmingDelete = false }
                }
            } else {
                HStack(spacing: DesignTokens.Spacing.s) {
                    Button(effective.isSuperset(of: selectable) && !selectable.isEmpty ? "Seçimi kaldır" : "Tümünü seç") {
                        checked = effective.isSuperset(of: selectable) ? [] : selectable
                    }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                    Text("\(effective.count) seçili")
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Menu {
                        ForEach(model.folders) { (item: FolderSummary) in
                            Button(item.name, systemImage: "folder") { model.moveMeetings(ids: effective, to: item.name) }
                        }
                        Divider()
                        Button("Klasörden çıkar", systemImage: "folder.badge.minus") { model.moveMeetings(ids: effective, to: nil) }
                    } label: {
                        Label("Klasöre taşı", systemImage: "folder")
                    }
                    .fixedSize()
                    .disabled(effective.isEmpty)
                    Button("Sil", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        .disabled(effective.isEmpty)
                }
            }
        }
        .controlSize(.small)
        .padding(DesignTokens.Spacing.m)
        .pageBackground()
        .overlay(alignment: .top) { Divider() }
    }

    private func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        checked = []
        isConfirmingDelete = false
        deleteErrors = []
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

    /// Verilen (görünen ve işaretli) toplantıları siler; silinemeyenler işaretli kalır, hataları alt çubukta görünür.
    private func deleteChecked(ids: Set<String>) {
        withAnimation(.snappy(duration: 0.3)) {
            deleteErrors = model.deleteMeetings(meetingIDs: ids)
            let remaining: Set<String> = Set(model.meetings.map(\.id))
            onDeleted(ids.subtracting(remaining))
            checked = ids.intersection(remaining)
            isConfirmingDelete = false
            if deleteErrors.isEmpty {
                isSelecting = false
            }
        }
    }
}

/// Gönderim durumu satırı (kanal ya da görev aracı). Gönderilirken kâğıt uçak sakince nabız atar; sonuç (gitti ya da
/// hata) süresi dolunca model durumu kaldırır (`showSendState`) ve satır yumuşakça kaybolur.
private struct SendStatusLine: View {
    let state: WebhookSendState?
    let sending: LocalizedStringKey
    let sent: LocalizedStringKey

    var body: some View {
        Group {
            if let state {
                line(state: state).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: state)
    }

    @ViewBuilder
    private func line(state: WebhookSendState) -> some View {
        switch state {
        case .sending:
            Label {
                Text(sending)
            } icon: {
                Image(systemName: "paperplane").symbolEffect(.pulse)
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(.secondary)
        case .sent:
            Label(sent, systemImage: "checkmark.circle").appFont(size: 12, weight: .regular).foregroundStyle(.secondary)
        case .done(let summary):
            Label(summary, systemImage: "checkmark.circle")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            NoticeText(message, severity: .attention).appFont(size: 12, weight: .regular)
        }
    }
}

/// Dışa aktarma hatasının kullanıcı metni: boş dosya adı kalmadıysa ne yapılacağını söyler. Saf fonksiyondur.
private func exportFailureMessage(error: any Error) -> String {
    if case ExportFileError.allNamesTaken = error {
        return String(localized: "İndirilenler'de bu adla 999 dosya var; eskilerini silip yeniden dene.")
    }
    return userFacingMessage(error: error)
}

/// Liste satırı: başlık, tarih, süre, durum ve varsa senin görev sayın.
struct MeetingRow: View {
    let record: MeetingRecord
    let isProcessing: Bool
    let isSelected: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.note?.title ?? record.title)
                    .appFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                // Tek metin, tek satır: dar listede tarih, süre ve durum ayrı sütunlara bölünüp alt alta kaymaz.
                infoLine
                    .appFont(size: 11, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            let mine: Int = record.note?.tasks.filter(\.isMine).count ?? 0
            if mine > 0 {
                // Görev simgesi (yıldız favori gibi okunuyordu); kenar çubuğundaki Görevlerim ile aynı.
                Label("\(mine)", systemImage: "checkmark.circle")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(.tint)
                    .hoverHint("Sana düşen görev sayısı", alignment: .trailing, edge: .bottom)
            }
            Image(systemName: "chevron.right")
                .appFont(size: 10, weight: .semibold)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.vertical, DesignTokens.Spacing.s)
        .background(
            isSelected ? Theme.selected : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    /// "tarih · süre · durum" tek metin olarak; hata durumu kırmızı.
    private var infoLine: Text {
        var line: AttributedString = AttributedString(record.startedAt.formatted(interfaceDate(date: .abbreviated)))
        if let minutes = meetingDurationMinutes(record: record) {
            line += AttributedString(" · " + String(localized: "\(minutes) dk"))
        }
        if let status = statusText(record: record, isProcessing: isProcessing) {
            var part: AttributedString = AttributedString(" · " + status)
            if record.status == .failed {
                part.foregroundColor = NoticeSeverity.error.tint
            }
            line += part
        }
        return Text(line)
    }
}

/// Arayüz dilinde tarih + saat biçimi.
private func interfaceDate(date: Date.FormatStyle.DateStyle) -> Date.FormatStyle {
    Date.FormatStyle(date: date, time: .shortened).locale(interfaceLocale())
}

/// Liste ve ayrıntıda gösterilen durum; tamamlanmışsa nil.
private func statusText(record: MeetingRecord, isProcessing: Bool) -> String? {
    if isProcessing {
        return String(localized: "Not hazırlanıyor…")
    }
    switch record.status {
    case .recording: return String(localized: "Kayıtta")
    case .processing: return String(localized: "Not hazırlanıyor…")
    case .done: return nil
    case .failed: return String(localized: "Hata")
    case .interrupted: return String(localized: "Yarıda kaldı")
    case .queued: return String(localized: "İşlenmeyi bekliyor")
    }
}

// MARK: Ayrıntı

/// Toplantı sayfasının sekmeleri.
private enum MeetingTab: String {
    case summary
    case transcript
    /// Kayıt sırasında saklanan ekran görüntüleri (yalnızca görüntüsü olan toplantıda görünür).
    case screens
}

/// Dışa aktarmanın sonucu: başarılar sağ alttaki kısa bildirimde (bkz. `ToastCenter`), hatalar ve onaylar sayfada satır
/// içinde (açılır pencere yok).
private enum ExportStatus: Equatable {
    case none
    case saved(URL)
    case copied
    /// Başka bir hedefe gönderildi (Apple Notlar, klasör): kısa onay metni.
    case done(String)
    case failed(String)
    /// "Toplantıyı sil"e basıldı: satır içi onay bekleniyor (ayrı uyarı penceresi yok).
    case confirmDelete
    /// "Sesi sil"e basıldı: ses kalıcı silinir, satır içi onay bekleniyor.
    case confirmDeleteAudio
}

/// Toplantının mesajını (hata ya da bilgi) toplantısıyla birlikte izlemek için.
private struct RecordMessageKey: Equatable {
    let recordID: String
    let message: String?
}

/// Seçili toplantının sayfası: önce sana düşen görevler, sonra özet, kararlar, diğer görevler, sözlük,
/// konuşmacı adları ve paragraflı transkript (zaman damgasından çalma).
struct MeetingDetailPage: View {
    let model: AppModel
    let player: MeetingAudioPlayer
    let record: MeetingRecord
    /// Toplantı silinince (sayfa artık gösterilemez) çağrılır.
    let onDeleted: @MainActor () -> Void
    /// Tarifi bu toplantıya uygular (Sor sayfasında açılır).
    let onRunRecipe: @MainActor (Recipe) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @State private var export: ExportStatus = .none
    @State private var tab: MeetingTab = .summary
    /// Alttaki çubuğun transkript çekmecesi açık.
    @State private var isTranscriptOpen: Bool = false
    /// Çekmecede kayılacak ve vurgulanacak paragraf (not maddesinin kaynağından gelinince).
    @State private var transcriptFocusID: String?
    /// Özetin gösterildiği dil (saklanır: bütün toplantılarda ve yeniden açılışta sürer); boşsa notun yazıldığı dil.
    @AppStorage(SettingsKey.meetingNoteDisplayLanguage) private var shownNoteLanguage: String = ""

    /// Özetin gösterildiği dil: nil asıl not (yazıldığı dilde), değilse paylaşım sürümü. Seçilen dil notun yazıldığı
    /// dilse asıl not gösterilir.
    private var noteLanguage: ShareLanguage? {
        get {
            ShareLanguage(rawValue: shownNoteLanguage).flatMap { (language: ShareLanguage) -> ShareLanguage? in
                language == record.note?.writtenLanguage ? nil : language
            }
        }
        nonmutating set {
            shownNoteLanguage = newValue?.rawValue ?? ""
        }
    }
    /// Başlık düzenleniyor (çift tıklama ya da "Yeniden adlandır").
    @State private var isRenaming: Bool = false
    @State private var draftTitle: String = ""
    @FocusState private var titleFocused: Bool
    /// Takip e-postası kartı açık: taslağın ilk dili (sayfada seçili not dili); kapalıyken nil.
    @State private var followUpLanguage: ShareLanguage?
    /// "Bağlantıyla paylaş" kartı açık (abonelik sürümü; takip e-postası kartıyla aynı anda açılmaz).
    @State private var sharingWithLink: Bool = false

    private var isProcessing: Bool {
        model.processingMeetingIDs.contains(record.id)
    }

    /// Kayıtta ya da işlemede: değiştiren eylemler kapalı.
    private var isLocked: Bool {
        model.isLocked(meetingID: record.id)
    }

    var body: some View {
        // Paragraflar burada bir kez hesaplanır: çalma sırasında (saniyede 10 güncelleme) yeniden süzülmez.
        let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    // İpuçları kapağın altındaki satırların üstünde çizilsin (birbirine girmesin).
                    hero(paragraphs: paragraphs, proxy: proxy).zIndex(1)
                    exportLine
                        .transition(.move(edge: .top).combined(with: .opacity))
                        // Başarılar sağ alttaki kısa bildirimde (3 sn) görünür, satırda kalmaz; hatalar ve onaylar satırda.
                        .onChange(of: export) { (_: ExportStatus, status: ExportStatus) in
                            announceSuccess(status: status)
                        }
                        // Yalnızca aynı toplantıda mesaj değişince (başka toplantıya geçince eski mesajı çıkmasın).
                        .onChange(of: RecordMessageKey(recordID: record.id, message: record.failureMessage)) { (old: RecordMessageKey, new: RecordMessageKey) in
                            if old.recordID == new.recordID {
                                announceRecordMessage(message: new.message, kind: .warning)
                            }
                        }
                        .onChange(of: RecordMessageKey(recordID: record.id, message: record.notice)) { (old: RecordMessageKey, new: RecordMessageKey) in
                            if old.recordID == new.recordID {
                                announceRecordMessage(message: new.message, kind: .info)
                            }
                        }
                    statusLines
                    if let language = followUpLanguage, let note = record.note {
                        FollowUpEmailCard(model: model, record: record, noteLanguage: note.writtenLanguage, initialLanguage: language) {
                            withAnimation(.smooth(duration: 0.25)) { followUpLanguage = nil }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    #if HOSTED_EDITION
                    if sharingWithLink, record.note != nil {
                        NoteShareCard(record: record, language: noteLanguage) {
                            withAnimation(.smooth(duration: 0.25)) { sharingWithLink = false }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    #endif
                    // Sekmeler ve notun dili tek satırda: dil, iş arkadaşlarına göndermek için notun başka dildeki sürümü.
                    HStack(spacing: 10) {
                        let hasScreens: Bool = !(model.screenSnapshots.snapshots[record.id] ?? []).isEmpty || tab == .screens
                        let tabs: [(value: MeetingTab, title: LocalizedStringKey)] = hasScreens
                            ? [(.summary, "Özet"), (.transcript, "Transkript"), (.screens, "Ekranlar")]
                            : [(.summary, "Özet"), (.transcript, "Transkript")]
                        UnderlineTabs(selection: $tab, options: tabs)
                        if tab == .summary, let note = record.note {
                            noteLanguageMenu(original: note.writtenLanguage)
                        }
                    }
                    Group {
                    switch tab {
                    case .summary:
                        if let note = record.note {
                            if let language = noteLanguage {
                                // Dil değişince durum (hata, deneme) sıfırlansın.
                                SharedNoteSection(
                                    model: model, record: record, note: note, language: language, paragraphs: paragraphs, canPlay: !playableAudio.isEmpty,
                                    onPlay: { (startSec: Double) -> Void in play(from: startSec) },
                                    onClip: { (paragraph: TranscriptParagraph) -> Void in exportClip(paragraph: paragraph) },
                                    onNameSpeakers: { () -> Void in tab = .transcript },
                                    onJump: { (paragraph: TranscriptParagraph) -> Void in jump(to: paragraph) },
                                    onAskSource: askAboutLine
                                )
                                .id(language)
                            } else {
                                SummaryTab(
                                    model: model, note: note, sourceNote: note, record: record, paragraphs: paragraphs, canPlay: !playableAudio.isEmpty,
                                    onPlay: { (startSec: Double) -> Void in play(from: startSec) },
                                    onClip: { (paragraph: TranscriptParagraph) -> Void in exportClip(paragraph: paragraph) },
                                    onNameSpeakers: { () -> Void in tab = .transcript },
                                    onJump: { (paragraph: TranscriptParagraph) -> Void in jump(to: paragraph) },
                                    onAskSource: askAboutLine
                                )
                            }
                        } else {
                            if isProcessing {
                                QuietEmptyCard(symbol: "hourglass", title: "Not hazırlanıyor…", message: "Bitince özet, kararlar ve görevler burada görünür.")
                            } else {
                                QuietEmptyCard(symbol: "doc.text", title: "Bu toplantının notu yok", message: "\"Notu yenile\" ile not yeniden yazılabilir.")
                            }
                        }
                    case .transcript:
                        let spans: [SpeakerSpan] = speakerSpans(paragraphs: paragraphs)
                        let totalSec: Double = paragraphs.map(\.endSec).max() ?? 0
                        if !spans.isEmpty, totalSec > 0 {
                            SpeakerTimeline(
                                spans: spans, totalSec: totalSec, player: player, meetingID: record.id, canPlay: !playableAudio.isEmpty,
                                onSeek: { (startSec: Double) -> Void in play(from: startSec) }
                            )
                            .frame(maxWidth: 820, alignment: .leading)
                        }
                        SpeakerChips(model: model, record: record, isLocked: isLocked, onPlay: { (startSec: Double) -> Void in play(from: startSec) })
                        let skipped: [StoredSegment] = skippedLanguageSegments(record: record)
                        if !skipped.isEmpty, let language = record.fixedLanguage {
                            SkippedLanguageSection(
                                record: record, segments: skipped, language: language, canPlay: !playableAudio.isEmpty,
                                onPlay: { (startSec: Double) -> Void in play(from: startSec) }
                            )
                            .frame(maxWidth: 820, alignment: .leading)
                        }
                        if paragraphs.isEmpty {
                            QuietEmptyCard(symbol: "text.bubble", title: "Bu toplantının metni yok", message: "Kayıt sırasında konuşma algılanmadı.")
                        }
                        TranscriptSection(
                            record: record, paragraphs: paragraphs, player: player, proxy: proxy,
                            canPlay: !playableAudio.isEmpty,
                            onPlay: { (startSec: Double) -> Void in play(from: startSec) },
                            canEdit: !isLocked,
                            onToggleHighlight: { (paragraph: TranscriptParagraph) -> Void in model.toggleHighlight(meetingID: record.id, paragraph: paragraph) },
                            onClip: { (paragraph: TranscriptParagraph) -> Void in exportClip(paragraph: paragraph) },
                            onRetryTranslation: { () -> Void in model.retryTranscriptTranslations(meetingID: record.id) }
                        )
                        .frame(maxWidth: 820, alignment: .leading)
                    case .screens:
                        ScreenSnapshotsSection(
                            model: model, record: record, paragraphs: paragraphs, isLocked: isLocked, canPlay: !playableAudio.isEmpty,
                            onPlay: { (startSec: Double) -> Void in play(from: startSec) }
                        )
                    }
                    }
                    // Sekme değişince içerik yumuşakça geçer.
                    .id(tab)
                    .transition(.opacity)
                    .environment(\.noteSourceAutoOpenText, demoOpenSourceText)
                }
                .animation(.smooth(duration: 0.25), value: tab)
                .animation(.smooth(duration: 0.25), value: export)
                .animation(.smooth(duration: 0.25), value: followUpLanguage)
                .animation(.smooth(duration: 0.25), value: sharingWithLink)
                .animation(.smooth(duration: 0.3), value: model.speakerReviews[record.id])
                .padding(DesignTokens.Spacing.l)
                // Geniş ana pencerede içerik okunur genişlikte kalır ve ortalanır: liste gizlenince sağda büyük boşluk
                // kalmasın (panelde etkisiz).
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            // Altta yüzen "Bir şey sor" çubuğu ve üstünde açılan transkript çekmecesi (içerik altından kayar).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar(paragraphs: paragraphs)
            }
        }
        .onChange(of: tab) { (_: MeetingTab, selected: MeetingTab) -> Void in
            model.meetingPageTabs[record.id] = selected.rawValue
        }
        // Toplantının ekran görüntüleri klasöründen okunur ("Ekranlar" sekmesi yalnızca görüntü varsa görünür).
        .task(id: record.id) {
            await model.refreshScreenSnapshots(meetingID: record.id)
        }
        .onAppear {
            // Sayfa başka bölüme geçip dönünce yeniden kurulur: kaldığı yerden açılır. Bu toplantı çalıyorsa transkript
            // (çalan paragrafa gidilir), değilse son açık sekme; ilk açılışta not varsa özet, yoksa transkript.
            if player.meetingID == record.id {
                tab = .transcript
            } else if let raw = model.meetingPageTabs[record.id], let saved = MeetingTab(rawValue: raw) {
                tab = saved
            } else {
                tab = record.note == nil ? .transcript : .summary
            }
            // "--not-dili fi|en": özeti paylaşım dilinde açar (görsel kontrol için).
            if let index = CommandLine.arguments.firstIndex(of: "--not-dili"), CommandLine.arguments.indices.contains(index + 1) {
                noteLanguage = ShareLanguage(rawValue: CommandLine.arguments[index + 1])
            }
            // "--cal <saniye>": transkripti açıp oradan çalar (görsel kontrol ve ölçüm için); yalnızca ilk açılışta, sayfa
            // her açıldığında yeniden başlatmaz.
            if !model.launchPlaybackStarted, let index = CommandLine.arguments.firstIndex(of: "--cal"),
               CommandLine.arguments.indices.contains(index + 1), let startSec = Double(CommandLine.arguments[index + 1]) {
                model.launchPlaybackStarted = true
                play(from: startSec)
            }
            #if DEBUG
            // Görsel kontrol sahnesi "not-transkript": çekmece Fiyat konusunun ilk sözünde açık.
            if (try? demoScene(arguments: CommandLine.arguments)) == .noteTranscript {
                transcriptFocusID = paragraphs.first { $0.startSec >= 600 }?.id
                isTranscriptOpen = true
            }
            // "--test-paylas": "Bağlantıyla paylaş…"ı açar (kabul testi; yalnız Debug). Pencere öne gelince açılsın diye
            // kısa bir gecikmeyle.
            if CommandLine.arguments.contains("--test-paylas") {
                Task {
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    shareViaLink()
                }
            }
            #endif
        }
    }

    /// Altta yüzen çubuk: Sor'un okuyabileceği toplantıda (kayıtta ya da işlenirken değil; bkz. `isMentionableMeeting`)
    /// "Bir şey sor" ve transkript çekmecesi. Canlı kayıt panelindeki sayfa da aynı çubuğu gösterir; kayıt süren toplantıda
    /// çubuk yok.
    @ViewBuilder
    private func bottomBar(paragraphs: [TranscriptParagraph]) -> some View {
        if isMentionableMeeting(record: record) {
            VStack(spacing: 8) {
                if isTranscriptOpen {
                    TranscriptDrawer(
                        paragraphs: paragraphs, speakerNames: record.speakerNames, focusID: transcriptFocusID, canPlay: !playableAudio.isEmpty,
                        onPlay: { (startSec: Double) -> Void in playInPlace(from: startSec) },
                        onClose: { isTranscriptOpen = false }
                    )
                    .frame(height: 360)
                    .frame(maxWidth: 700)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                MeetingAskBar(
                    exchanges: model.meetingAsk.exchanges(meetingID: record.id), isAnswering: model.meetingAsk.isAnswering(meetingID: record.id),
                    quickActions: record.note == nil ? [] : meetingQuickActions(recipes: model.recipes), recipes: model.recipes,
                    isEditingNote: isProcessing, isTranscriptOpen: isTranscriptOpen,
                    onAsk: { (question: String, recipeTitle: String?) -> Void in
                        model.askAboutMeeting(meetingID: record.id, question: question, recipeTitle: recipeTitle)
                    },
                    onQuickAction: { (action: MeetingQuickAction) -> Void in run(action: action) },
                    onStop: { model.meetingAsk.stop(meetingID: record.id) },
                    onClear: { model.meetingAsk.clear(meetingID: record.id) },
                    onRegenerate: { model.regenerateMeetingAnswer(meetingID: record.id) },
                    onOpenSource: { (passage: ArchivePassage) -> Void in openSource(passage: passage, paragraphs: paragraphs) },
                    onSaveRecipe: { (question: String) -> Void in model.saveRecipe(question: question) },
                    onToggleTranscript: {
                        transcriptFocusID = nil
                        isTranscriptOpen.toggle()
                    }
                )
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            // Çubuğun arkasında zemine durgun geçiş: altından kayan not çubukla panel arasında görünmesin.
            .background(alignment: .bottom) {
                LinearGradient(stops: [.init(color: Theme.background.opacity(0), location: 0), .init(color: Theme.background, location: 0.35)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 100)
                    .allowsHitTesting(false)
            }
            .animation(.smooth(duration: 0.25), value: isTranscriptOpen)
        }
    }

    /// Hazır eylem: tarif bu sayfada sorulur, "Notu uzat" notu yeniden yazar.
    private func run(action: MeetingQuickAction) {
        switch action.kind {
        case .ask(let prompt, let recipeTitle):
            model.askAboutMeeting(meetingID: record.id, question: prompt, recipeTitle: recipeTitle)
        case .editNote(let instruction):
            model.editNote(meetingID: record.id, instruction: instruction)
        }
    }

    /// Not maddesinin kaynak kutusundaki "Sor": maddenin toplantıda nasıl konuşulduğunu bu toplantıya sorar.
    private func askAboutLine(text: String) {
        model.askAboutMeeting(
            meetingID: record.id, question: String(localized: "Notta \"\(text)\" yazıyor. Bu toplantıda nasıl konuşuldu: kim ne dedi, neden bu sonuca varıldı?"),
            recipeTitle: nil
        )
    }

    /// Cevaptaki kaynak: transkript parçasıysa çekmecede o ana gidilir; not parçası Özet'i gösterir.
    private func openSource(passage: ArchivePassage, paragraphs: [TranscriptParagraph]) {
        guard passage.kind == .transcript, let paragraph = paragraphs.last(where: { $0.startSec <= passage.startSec + 0.5 }) ?? paragraphs.first else {
            tab = .summary
            return
        }
        jump(to: paragraph)
    }

    /// Kaynaktan transkriptte o ana gider: çekmece açılır, paragrafa kayıp vurgular; ses varsa oradan çalar (sekme
    /// değişmez, not görünür kalır).
    private func jump(to paragraph: TranscriptParagraph) {
        transcriptFocusID = paragraph.id
        isTranscriptOpen = true
        playInPlace(from: paragraph.startSec)
    }

    /// Sekmeyi değiştirmeden verilen andan çalar (ses yoksa bir şey yapmaz).
    private func playInPlace(from startSec: Double) {
        let urls: [URL] = playableAudio
        guard !urls.isEmpty else {
            return
        }
        player.play(record: record, urls: urls, startSec: startSec)
    }

    /// Görsel kontrol sahnesi "not-kaynak"ta kaynak kutusu açılacak madde (özetin ilk cümlesi); başka durumda nil.
    private var demoOpenSourceText: String? {
        #if DEBUG
        guard (try? demoScene(arguments: CommandLine.arguments)) == .noteSource, let summary = record.note?.summary else {
            return nil
        }
        return noteSummaryBullets(summary: summary).first
        #else
        return nil
        #endif
    }

    /// İşleniyor, hata ve uyarı satırları.
    @ViewBuilder
    private var statusLines: some View {
        if isProcessing || record.status == .processing {
            HStack(spacing: DesignTokens.Spacing.s) {
                ProgressView().controlSize(.small)
                Text(model.finalPassRunsOnThisMac(engine: record.engine)
                    ? "Konuşmacılar Mac'te ayrılıyor ve not hazırlanıyor…"
                    : "Kaydın tamamı işleniyor ve not hazırlanıyor…")
                    .foregroundStyle(.secondary)
            }
            .appFont(size: 12, weight: .regular)
        }
        // Notu duran toplantıda hata ve bilgi son işlemle ilgilidir (not yenilenemedi, ses yeniden yazıya dökülmedi):
        // sağ altta kısa bildirim olarak çıkar (bkz. `announceRecordMessage`), sayfada kalmaz. Notu olmayan toplantıda
        // hata kalıcıdır, burada görünür.
        if record.note == nil, let message = record.failureMessage {
            NoticeText(message, severity: .error)
                .appFont(size: 12, weight: .regular)
                .textSelection(.enabled)
        }
        SendStatusLine(state: model.webhookStates[record.id], sending: "Kanala gönderiliyor…", sent: "Not kanala gönderildi")
        SendStatusLine(state: model.trackerStates[record.id], sending: "Görevler açılıyor…", sent: "Görevler gönderildi")
        if record.status == .queued {
            // Çevrimdışı kaydedildi ya da içe aktarıldı: ses bu Mac'te; sunucuda işlenir (ya da neden yazar).
            NoticeCard(
                severity: .info,
                title: Text("İşlenmeyi bekliyor"),
                detail: record.notice.map { Text(verbatim: $0) },
                onDismiss: nil
            ) {
                #if HOSTED_EDITION
                Button("Şimdi dene") { Task { await model.runOfflineQueue() } }
                    .buttonStyle(.pill)
                    .disabled(model.isBusy)
                #endif
            }
        } else if record.note == nil, let notice = record.notice {
            NoticeText(notice, severity: .info)
                .appFont(size: 12, weight: .regular)
        }
    }

    /// Notu duran toplantıda son işlemin yeni uyarısı ya da bilgisi sağ altta kısa bildirim olarak gösterilir (yalnızca
    /// değişince; toplantıyı her açışta yeniden çıkmaz).
    private func announceRecordMessage(message: String?, kind: ToastKind) {
        guard record.note != nil, let message else {
            return
        }
        ToastCenter.shared.show(kind: kind, title: message, detail: nil, action: nil)
    }

    /// Toplantıyı verilen andan iki kayıt birlikte çalar ve transkripte geçer (kelimeler vurgulansın).
    private func play(from startSec: Double) {
        let urls: [URL] = playableAudio
        guard !urls.isEmpty else {
            return
        }
        tab = .transcript
        player.play(record: record, urls: urls, startSec: startSec)
    }

    /// Sakin başlık (Granola gibi): üst satırda küçük pastel kutu ve sağda "Dinle" ile "⋯", büyük başlık, sonra tek satır
    /// bilgi çipleri (şablon, tarih, süre, konuşmacı sayısı, klasör, dil) ve sana düşen görev varsa vurgu renginde sayısı
    /// (tıklayınca nottaki görevlere gider). Tarifler alttaki "Bir şey sor" çubuğunda ve "⋯"de.
    private func hero(paragraphs: [TranscriptParagraph], proxy: ScrollViewProxy) -> some View {
        // Kısa konuşmalar (bkz. `groupedSpeakers`) konuşmacı sayısına girmez.
        let speakers: [SpeakerShare] = groupedSpeakers(shares: speakerShares(paragraphs: paragraphs), speakerNames: record.speakerNames).major
        let mine: Int = (record.note?.tasks ?? []).filter(\.isMine).count
        let speakerNamesLine: String = speakers.prefix(6).map { speakerName(key: $0.key, speakerNames: record.speakerNames) }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.s) {
                // Toplantıya özgü durgun pastel kutu (kartlardaki kapakla aynı gradyan; canlandırılmaz).
                CoverImage(seed: record.id)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Spacer(minLength: DesignTokens.Spacing.s)
                listenButton
                shareMenu
                moreMenu
            }
            Group {
                if isRenaming {
                    TextField("Toplantı adı", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit { finishRename() }
                        .onExitCommand { isRenaming = false }
                        .onChange(of: titleFocused) { (_: Bool, focused: Bool) in
                            if !focused {
                                finishRename()
                            }
                        }
                } else {
                    Text(record.note?.title ?? record.title)
                        .lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                        .onTapGesture(count: 2) { startRename() }
                        .hoverHint("Yeniden adlandırmak için çift tıkla", alignment: .leading, edge: .bottom)
                }
            }
            .appFont(size: 30, weight: .semibold)
            .tracking(-0.8)
            .padding(.top, 14)
            HStack(alignment: .center, spacing: 10) {
                let chips: MeetingInfoChips = MeetingInfoChips(chips: meetingInfoChips(record: record, speakers: speakers.count, locale: interfaceLocale()))
                if speakerNamesLine.isEmpty {
                    chips
                } else {
                    // Konuşanların adları üstüne gelince ve VoiceOver'da.
                    chips
                        .hoverHint(verbatim: speakerNamesLine, alignment: .leading, edge: .bottom)
                        .accessibilityHint(Text(verbatim: speakerNamesLine))
                }
                if mine > 0 {
                    // Sana düşen görevler: tek vurgu; tıklayınca nottaki görevlere gider.
                    Button(String(localized: "Sana \(mine) görev")) {
                        reveal(anchor: .myTasks, proxy: proxy)
                    }
                    .buttonStyle(.plain)
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .linkPointer(isEnabled: true)
                    .hoverHint("Sana düşen görevlere git", alignment: .leading, edge: .bottom)
                    .fixedSize()
                }
            }
            .padding(.top, 12)
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Notun dili: asıl not (yazıldığı dil, `original`), sık kullanılan Fince ve İngilizce, sonra diğer diller. Asıl
    /// notun dili paylaşım dili olarak yinelenmez. Adlar arayüz dilinde (kapaktaki dil çipiyle aynı: Türkçe arayüzde
    /// "İngilizce").
    private func noteLanguageMenu(original: ShareLanguage) -> some View {
        let choices: ShareLanguageChoices = shareLanguageChoices(original: original)
        return Menu {
            Button(original.interfaceName) { noteLanguage = nil }
            ForEach(choices.featured, id: \.self) { (language: ShareLanguage) in
                Button(language.interfaceName) { noteLanguage = language }
            }
            Divider()
            Menu("Diğer diller") {
                ForEach(choices.others, id: \.self) { (language: ShareLanguage) in
                    Button(language.interfaceName) { noteLanguage = language }
                }
            }
        } label: {
            Label {
                Text(verbatim: (noteLanguage ?? original).interfaceName)
            } icon: {
                Image(systemName: "globe")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.pill)
        .fixedSize()
        .hoverHint("Notu iş arkadaşların için 30'dan fazla dilden birine çevir", alignment: .trailing, edge: .bottom)
    }

    /// Kapaktaki görev bağlantısından nottaki bölüme gider: başka sekmedeyse önce Özet'e geçer, bölüm çizilince kaydırır.
    private func reveal(anchor: MeetingNoteAnchor, proxy: ScrollViewProxy) {
        let needsSwitch: Bool = tab != .summary
        tab = .summary
        Task { @MainActor in
            if needsSwitch {
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    // Sayfa kapandı (görev iptal): kaydırılacak bölüm yok.
                    return
                }
            }
            withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    /// Baştan dinle; bu toplantı çalıyorsa duraklat/sürdür.
    @ViewBuilder
    private var listenButton: some View {
        if !playableAudio.isEmpty {
            let isPlayingThis: Bool = player.meetingID == record.id && player.isPlaying
            Button(isPlayingThis ? "Duraklat" : "Dinle", systemImage: isPlayingThis ? "pause.fill" : "play.fill") {
                if player.meetingID == record.id {
                    player.togglePause()
                } else {
                    play(from: 0)
                }
            }
            .buttonStyle(.pillPrimary)
            .hoverHint("Baştan dinle; çalan kelime renklenir", alignment: .leading, edge: .bottom)
        }
    }

    /// Başlıktaki "Paylaş": notu paylaşmanın bütün yolları tek yerde (önceden "⋯ › Gönder"in altındaydı): bağlantıyla,
    /// kanala (Slack, Teams…), e-postayla, Markdown kopyası ve sistemin paylaşım seçicisi.
    private var shareMenu: some View {
        Menu {
            linkShareButton
            channelMenu
            Button("E-postayla gönder", systemImage: "envelope") { emailNote() }
                .disabled(record.note == nil)
            Button("Markdown olarak kopyala", systemImage: "doc.on.doc") { copyMarkdown() }
            if let text = displayedShareText {
                Divider()
                ShareLink(item: text, subject: Text(record.note?.title ?? record.title)) {
                    Label("Diğer uygulamalarla paylaş…", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Label("Paylaş", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.pill)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHint("Bağlantı, kanal, e-posta ya da kopya", alignment: .trailing, edge: .bottom)
    }

    /// "Bağlantıyla paylaş…": abonelikte uçtan uca şifreli bağlantı kartı, geliştirici sürümünde iCloud PDF bağlantısı.
    @ViewBuilder
    private var linkShareButton: some View {
        #if HOSTED_EDITION
        // Uçtan uca şifreli bağlantı: kart sayfanın üstünde açılır (süre, transkript, bağlantılar).
        Button("Bağlantıyla paylaş…", systemImage: "link") {
            withAnimation(.smooth(duration: 0.25)) {
                followUpLanguage = nil
                sharingWithLink = true
            }
        }
        .disabled(record.note == nil || record.isSampleMeeting)
        #else
        Button("Bağlantıyla paylaş…", systemImage: "link") { shareViaLink() }
        #endif
    }

    /// Ayarlardaki kanallara (Slack, Teams, Discord, Zapier…) gönderim: her hedefe ayrı ayrı ya da hepsine; gönderilmiş
    /// hedef işaretli.
    private var channelMenu: some View {
        Menu("Kanala gönder", systemImage: "paperplane") {
            if model.destinations.isEmpty {
                Text("Ayarlar › Bağlantılar'dan kanal ekle")
            } else {
                ForEach(model.destinations) { (destination: NoteDestination) in
                    let sent: Bool = wasSent(record: record, destination: destination)
                    Button {
                        Task { await model.sendNote(meetingID: record.id, destinationIDs: [destination.id]) }
                    } label: {
                        Label(
                            "\(destinationName(destination: destination)) · \(destinationDetail(destination: destination))",
                            systemImage: sent ? "checkmark" : "paperplane"
                        )
                    }
                }
                if model.destinations.count > 1 {
                    Divider()
                    Button("Hepsine gönder") {
                        Task { await model.sendNote(meetingID: record.id, destinationIDs: model.destinations.map(\.id)) }
                    }
                }
            }
        }
        .disabled(record.note == nil || model.webhookStates[record.id] == .sending)
    }

    /// "⋯" menüsü: sık kullanılanlar üstte (takip e-postası, notu yenile, tarif), dışa aktarma ve gönderme alt
    /// menülerde, yönetim ve silme en altta. Paylaşma yolları başlıktaki "Paylaş"ta.
    private var moreMenu: some View {
        Menu {
            // Nottan takip e-postası: kart sayfanın üstünde açılır (taslak düzenlenir, kopyalanır ya da Mail'de açılır).
            Button("Takip e-postası yaz", systemImage: "envelope.badge") {
                withAnimation(.smooth(duration: 0.25)) {
                    sharingWithLink = false
                    followUpLanguage = noteLanguage ?? record.note?.writtenLanguage
                }
            }
            .disabled(record.note == nil || isLocked)
            // Notu yeniden yazar (konuşmacı adlarıyla).
            Button("Notu yenile", systemImage: "sparkles") { model.regenerateNote(meetingID: record.id) }
                .disabled(isLocked)
            // Tarif Sor sayfasında bu toplantıya uygulanır (alttaki çubuktan uygulanınca cevap bu sayfada açılır).
            Menu("Sor'da tarif uygula", systemImage: "wand.and.stars") {
                ForEach(model.recipes) { (recipe: Recipe) in
                    Button(recipe.title, systemImage: recipe.symbol) { onRunRecipe(recipe) }
                }
            }
            .disabled(record.note == nil)
            Divider()
            Menu("Dışa aktar", systemImage: "square.and.arrow.down") {
                exportItems
            }
            Menu("Gönder", systemImage: "paperplane") {
                sendItems
            }
            Divider()
            manageItems
        } label: {
            // Simge düğmeleriyle aynı genişlikte daire.
            Image(systemName: "ellipsis").frame(width: 16, height: 16)
        }
        .menuStyle(.button)
        .buttonStyle(.pill)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Diğer işlemler")
        .hoverHint("Dışa aktar, gönder ve diğer işlemler", alignment: .trailing, edge: .bottom)
    }

    /// Dosya olarak dışa aktarma (seçili not dilinde): PDF, Markdown, Word, web sayfası, transkriptin düz metni, SRT
    /// altyazısı ve seçili klasöre Markdown.
    @ViewBuilder
    private var exportItems: some View {
        let hasTranscript: Bool = !(record.finalSegments.isEmpty && record.liveSegments.isEmpty)
        Button("PDF olarak kaydet", systemImage: "doc.richtext") { exportPDF() }
        Button("Markdown olarak kaydet", systemImage: "square.and.arrow.down") { exportMarkdown() }
        Button("Word (DOCX) olarak kaydet", systemImage: "doc.text") { exportDOCX() }
        Button("Web sayfası olarak kaydet", systemImage: "globe") { exportHTML() }
            .disabled(record.note == nil)
        Divider()
        Button("Transkripti metin olarak kaydet (TXT)", systemImage: "text.alignleft") { exportTranscriptText() }
            .disabled(!hasTranscript)
        Button("Altyazı olarak kaydet (SRT)", systemImage: "captions.bubble") { exportSRT() }
            .disabled(!hasTranscript)
        Divider()
        Button("Klasöre Markdown kaydet", systemImage: "folder") {
            // Klasör henüz seçilmediyse hata yerine seçim penceresi açılır; seçilince hemen yazılır.
            if model.markdownFolder.isEmpty {
                guard let folder = pickMarkdownFolder() else {
                    return
                }
                model.setMarkdownFolder(path: folder.path)
            }
            if let error = model.exportToFolder(meetingID: record.id) {
                export = .failed(error)
            } else {
                export = .done(String(localized: "Seçili klasöre Markdown olarak yazıldı."))
            }
        }
        .disabled(record.note == nil)
    }

    /// Notu başka yere gönderir: PDF paylaşımı (abonelikte), görev araçları (Linear, Jira) ve Apple Notlar. Bağlantı,
    /// kanal ve e-posta başlıktaki "Paylaş"ta.
    @ViewBuilder
    private var sendItems: some View {
        #if HOSTED_EDITION
        // Abonelik sürümünde iCloud yok: PDF geçici klasörden paylaşım seçicisiyle (Mail, AirDrop, Mesajlar…).
        Button("PDF olarak paylaş…", systemImage: "square.and.arrow.up") { sharePDF() }
        #endif
        // Görevleri Linear ya da Jira'da iş olarak açar. Araç adı iki noktadan sonra: Türkçe ek ada göre değişir ("Jira'ya").
        Menu("Görevleri gönder", systemImage: "checklist") {
            if model.taskTrackers.isEmpty {
                Text("Ayarlar › Bağlantılar › Görev araçları'ndan Linear ya da Jira bağla")
            } else {
                ForEach(model.taskTrackers) { (tracker: TaskTracker) in
                    Button("Bana düşenleri gönder: \(tracker.service.displayName)") {
                        Task { await model.sendTasks(meetingID: record.id, trackerID: tracker.id, scope: .mine) }
                    }
                    Button("Tüm görevleri gönder: \(tracker.service.displayName)") {
                        Task { await model.sendTasks(meetingID: record.id, trackerID: tracker.id, scope: .all) }
                    }
                }
            }
        }
        .disabled((record.note?.tasks ?? []).isEmpty || model.trackerStates[record.id] == .sending)
        Button("Apple Notlar'a gönder", systemImage: "note.text") {
            Task {
                if let error = await model.sendToAppleNotes(meetingID: record.id) {
                    export = .failed(error)
                } else {
                    export = .done(String(localized: "Notlar'daki \"\(appName)\" klasörüne yazıldı."))
                }
            }
        }
        .disabled(record.note == nil)
    }

    /// Yönetim: yeniden işleme ve silme (kilitliyken kapalı); silme satır içinde onay ister.
    @ViewBuilder
    private var manageItems: some View {
        Menu("Klasöre taşı") {
            ForEach(model.folders) { (item: FolderSummary) in
                Button {
                    model.moveMeetings(ids: [record.id], to: item.name)
                } label: {
                    if record.folder?.caseInsensitiveCompare(item.name) == .orderedSame {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
            if model.folders.isEmpty {
                Text("Önce kenar çubuğunda \"+\" ile klasör oluştur")
            }
            if record.folder != nil {
                Divider()
                Button("Klasörden çıkar", systemImage: "folder.badge.minus") { model.moveMeetings(ids: [record.id], to: nil) }
            }
        }
        .disabled(isLocked)
        Menu("Şablonla yeniden yaz") {
            ForEach(NoteTemplateKind.allCases, id: \.self) { (kind: NoteTemplateKind) in
                Button {
                    model.regenerateNote(meetingID: record.id, template: NoteTemplate(kind: kind, customInstructions: UserDefaults.standard.string(forKey: SettingsKey.customTemplate) ?? ""))
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
        .disabled(isLocked)
        noteVersionItems
        Button("Yeniden adlandır", systemImage: "pencil") { startRename() }
            .disabled(isLocked)
        // Örnek toplantı (karşılamadaki deneme) işlenmez: sesi sunucuya gitmez, kullanıma yazılmaz.
        // Başka cihazdan eşitlenen toplantının sesi o cihazda: burada işlenemez ve silinemez.
        Button("Tekrar işle", systemImage: "arrow.clockwise") { model.reprocess(meetingID: record.id) }
            .disabled(isLocked || record.audioDeleted || record.isSampleMeeting || isRecordedElsewhere)
        Divider()
        Button("Sesi sil", systemImage: "speaker.slash", role: .destructive) {
            export = .confirmDeleteAudio
        }
        .disabled(isLocked || record.audioDeleted || isRecordedElsewhere)
        Button("Toplantıyı sil", systemImage: "trash", role: .destructive) { export = .confirmDelete }
            .disabled(isLocked)
    }

    /// Notun önceki sürümleri: son değişikliği geri al ve sürüm listesi (tarih ve neden); geri yükleme de geri alınabilir.
    @ViewBuilder
    private var noteVersionItems: some View {
        if let versions = record.noteHistory, let latest = versions.first {
            Button("Geri al (\(latest.reason))", systemImage: "arrow.uturn.backward") {
                model.restoreNoteVersion(meetingID: record.id, index: 0)
            }
            .disabled(isLocked)
            Menu("Önceki sürümler", systemImage: "clock.arrow.circlepath") {
                Section("Değişiklikten önceki not") {
                    ForEach(Array(versions.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteVersion)) in
                        Button(noteVersionTitle(version: item.element, locale: interfaceLocale())) {
                            model.restoreNoteVersion(meetingID: record.id, index: item.offset)
                        }
                    }
                }
            }
            .disabled(isLocked)
        }
    }

    /// Paylaşılacak metin: seçili dildeki not (paylaşım sürümü henüz yoksa asıl not); not yoksa nil.
    private var displayedShareText: String? {
        guard let note = record.note else {
            return nil
        }
        if let language = noteLanguage, let shared = record.sharedNotes?[language.rawValue] {
            return shareText(record: record, note: shared, language: language)
        }
        return shareText(record: record, note: note, language: nil)
    }

    private func startRename() {
        guard !isLocked else {
            return
        }
        draftTitle = record.note?.title ?? record.title
        isRenaming = true
        titleFocused = true
    }

    private func finishRename() {
        guard isRenaming else {
            return
        }
        isRenaming = false
        if draftTitle != (record.note?.title ?? record.title) {
            model.renameMeeting(meetingID: record.id, title: draftTitle)
        }
    }

    /// Dışa aktarılan kayıt: seçili dilde paylaşım notu varsa not onunla değişir (PDF, Markdown ve kopya da ekranda
    /// görünen dilde çıkar; önceden hep Türkçe çıkıyordu).
    private var shownRecord: MeetingRecord {
        guard let language = noteLanguage, let shared = record.sharedNotes?[language.rawValue] else {
            return record
        }
        return record.with(note: shared)
    }

    /// Başarı durumunu sağ alttaki kısa bildirime taşır ve satırı temizler; diğer durumlara dokunmaz.
    private func announceSuccess(status: ExportStatus) {
        switch status {
        case .saved(let url):
            ToastCenter.shared.show(kind: .success, title: String(localized: "İndirilenler'e kaydedildi"), detail: url.lastPathComponent, action: .revealInFinder(url))
        case .copied:
            ToastCenter.shared.show(kind: .success, title: String(localized: "Markdown panoya kopyalandı"), detail: nil, action: nil)
        case .done(let message):
            ToastCenter.shared.show(kind: .success, title: message, detail: nil, action: nil)
        case .none, .failed, .confirmDelete, .confirmDeleteAudio:
            return
        }
        export = .none
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meetingMarkdown(record: shownRecord), forType: .string)
        recordFeatureUsage(feature: .export(.copyMarkdown))
        export = .copied
    }

    /// Notu Mail'de yeni ileti olarak açar (konu toplantı adı, gövde seçili dildeki not); alıcıları kullanıcı seçer.
    private func emailNote() {
        guard let text = displayedShareText, let service = NSSharingService(named: .composeEmail) else {
            export = .failed(String(localized: "Mail açılamadı: Mac'te ayarlı bir e-posta hesabı yok."))
            return
        }
        service.subject = shownRecord.note?.title ?? record.title
        service.perform(withItems: [text])
        recordFeatureUsage(feature: .export(.email))
    }

    @ViewBuilder
    private var exportLine: some View {
        switch export {
        case .none:
            if record.audioDeleted {
                Text("Ses dosyaları silindi; metin ve not duruyor.")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(.secondary)
            } else if isRecordedElsewhere {
                Text("Başka bir cihazında kaydedildi; sesi o cihazda kalır.")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(.secondary)
            }
        case .saved, .copied, .done:
            // Sağ alttaki bildirimde gösterilir (bkz. `announceSuccess`).
            EmptyView()
        case .failed(let message):
            NoticeText(message, severity: .error)
                .appFont(size: 11, weight: .regular)
        case .confirmDeleteAudio:
            HStack(spacing: DesignTokens.Spacing.s) {
                Label("Ses kalıcı olarak silinsin mi? Metin ve not kalır; geri alınamaz.", systemImage: "speaker.slash")
                    .foregroundStyle(NoticeSeverity.error.tint)
                Button("Sesi sil", role: .destructive) {
                    // Yalnızca bu toplantının çalması durur; başka toplantı dinleniyorsa sürer.
                    if player.meetingID == record.id {
                        player.stop()
                    }
                    model.deleteAudio(meetingID: record.id)
                    export = .none
                }
                Button("Vazgeç") { export = .none }
            }
            .appFont(size: 11, weight: .regular)
            .controlSize(.small)
        case .confirmDelete:
            HStack(spacing: DesignTokens.Spacing.s) {
                Label("Toplantı (metin, not ve ses) Çöp Sepeti'ne taşınsın mı?", systemImage: "trash")
                    .foregroundStyle(NoticeSeverity.error.tint)
                Button("Sil", role: .destructive) {
                    // Dosyalar taşınmadan önce bu toplantının çalması durur; başka toplantı dinleniyorsa sürer.
                    if player.meetingID == record.id {
                        player.stop()
                    }
                    if let error = model.deleteMeeting(meetingID: record.id) {
                        export = .failed(error)
                    } else {
                        onDeleted()
                    }
                }
                Button("Vazgeç") { export = .none }
            }
            .appFont(size: 11, weight: .regular)
            .controlSize(.small)
        }
    }

    private func exportPDF() {
        export = saveExport(format: .pdf, fileExtension: "pdf") { (url: URL) throws -> Void in
            try meetingPDF(record: shownRecord).write(to: url, options: .atomic)
        }
    }

    /// Notu (seçili dilde) PDF olarak geçici klasöre yazar ve paylaşım seçicisini açar (abonelik sürümü: iCloud yok).
    /// Geçici dosyayı sistem temizler.
    private func sharePDF() {
        let pdf: Data
        do {
            pdf = try meetingPDF(record: shownRecord)
        } catch {
            meetingsLogger.error("Paylaşılacak PDF oluşturulamadı, hata: \(String(describing: error), privacy: .private)")
            export = .failed(userFacingMessage(error: error))
            return
        }
        let title: String = shownRecord.note?.title ?? record.title
        let startedAt: Date = record.startedAt
        do {
            let directory: URL = FileManager.default.temporaryDirectory.appending(path: "paylasim-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url: URL = try exportFileURL(directory: directory, title: title, startedAt: startedAt, fileExtension: "pdf")
            try pdf.write(to: url, options: .atomic)
            guard let view = NSApp.keyWindow?.contentView else {
                export = .failed(String(localized: "Paylaşım penceresi açılamadı; uygulamayı öne getirip yeniden dene."))
                return
            }
            // Seçici pencerenin sağ üstünde, "⋯" düğmesinin yakınında açılır.
            let anchor: NSRect = NSRect(x: view.bounds.maxX - 80, y: view.isFlipped ? 90 : view.bounds.maxY - 90, width: 1, height: 1)
            NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
            recordFeatureUsage(feature: .export(.pdfShare))
        } catch {
            meetingsLogger.error("PDF paylaşılamadı, hata: \(String(describing: error), privacy: .private)")
            export = .failed(userFacingMessage(error: StorageError.writeFailed(path: "PDF", reason: error.localizedDescription)))
        }
    }

    /// Notu (seçili dilde) PDF olarak iCloud Drive'daki AI-Notepad klasörüne (`Documents/Shared`) koyar ve paylaşım
    /// seçicisini açar: iCloud'un "Ortak çalış / Bağlantıyı kopyala" seçeneği ya da başka bir servis. iCloud yoksa
    /// dosya başka yere yazılmaz, hata gösterilir. Dosya önce geçici klasöre yazılıp iCloud'a taşınır (`setUbiquitous`).
    private func shareViaLink() {
        let pdf: Data
        do {
            pdf = try meetingPDF(record: shownRecord)
        } catch {
            meetingsLogger.error("Paylaşılacak PDF oluşturulamadı, hata: \(String(describing: error), privacy: .private)")
            export = .failed(userFacingMessage(error: error))
            return
        }
        let title: String = shownRecord.note?.title ?? record.title
        let startedAt: Date = record.startedAt
        Task {
            do {
                let url: URL = try await runBlocking(qos: .userInitiated) { () throws -> URL in
                    let destination: URL = try exportFileURL(directory: try AppPaths.cloudSharedDirectory(), title: title, startedAt: startedAt, fileExtension: "pdf")
                    let temporary: URL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf", directoryHint: .notDirectory)
                    do {
                        try pdf.write(to: temporary, options: .atomic)
                        try FileManager.default.setUbiquitous(true, itemAt: temporary, destinationURL: destination)
                    } catch {
                        throw StorageError.writeFailed(path: destination.path, reason: error.localizedDescription)
                    }
                    return destination
                }
                guard let view = NSApp.keyWindow?.contentView else {
                    export = .failed(String(localized: "Paylaşım penceresi açılamadı; PDF iCloud Drive'da: \(url.lastPathComponent)"))
                    return
                }
                // Seçici pencerenin sağ üstünde, "⋯" düğmesinin yakınında açılır.
                let anchor: NSRect = NSRect(x: view.bounds.maxX - 80, y: view.isFlipped ? 90 : view.bounds.maxY - 90, width: 1, height: 1)
                NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
                recordFeatureUsage(feature: .export(.linkShare))
                export = .done(String(localized: "PDF iCloud Drive'a kaydedildi: \(url.lastPathComponent)"))
            } catch {
                meetingsLogger.error("Bağlantıyla paylaşılamadı, hata: \(String(describing: error), privacy: .private)")
                export = .failed(userFacingMessage(error: error))
            }
        }
    }

    /// Paragrafın sesini (iki kayıt karışık) M4A klip olarak İndirilenler'e kaydeder: paylaşılabilir an.
    private func exportClip(paragraph: TranscriptParagraph) {
        let sources: [URL] = playableAudio
        guard !sources.isEmpty else {
            return
        }
        let title: String = audioClipTitle(meetingTitle: record.note?.title ?? record.title, startSec: paragraph.startSec)
        Task {
            do {
                let downloads: URL = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let url: URL = try exportFileURL(directory: downloads, title: title, startedAt: record.startedAt, fileExtension: "m4a")
                let range: (start: Double, end: Double) = clipRange(startSec: paragraph.startSec, endSec: paragraph.endSec)
                try await exportAudioClip(sources: sources, startSec: range.start, endSec: range.end, destination: url)
                recordFeatureUsage(feature: .export(.audioClip))
                export = .saved(url)
            } catch {
                meetingsLogger.error("Klip kaydedilemedi, hata: \(String(describing: error), privacy: .private)")
                export = .failed(exportFailureMessage(error: error))
            }
        }
    }

    /// Paylaşılabilir tek dosyalık web sayfası (seçili not dilinde) İndirilenler'e.
    private func exportHTML() {
        guard let note = record.note else {
            return
        }
        let shown: (note: MeetingNote, language: ShareLanguage?) = noteLanguage.flatMap { (language: ShareLanguage) -> (note: MeetingNote, language: ShareLanguage?)? in
            record.sharedNotes?[language.rawValue].map { (note: $0, language: language) }
        } ?? (note: note, language: nil)
        export = saveExport(format: .html, fileExtension: "html") { (url: URL) throws -> Void in
            try Data(meetingHTML(record: record, note: shown.note, language: shown.language, appName: appName).utf8).write(to: url, options: .atomic)
        }
    }

    private func exportMarkdown() {
        export = saveExport(format: .markdown, fileExtension: "md") { (url: URL) throws -> Void in
            try Data(meetingMarkdown(record: shownRecord).utf8).write(to: url, options: .atomic)
        }
    }

    /// Notu ve transkripti (seçili not dilinde) Word belgesi olarak İndirilenler'e kaydeder.
    private func exportDOCX() {
        export = saveExport(format: .docx, fileExtension: "docx") { (url: URL) throws -> Void in
            try meetingDOCX(record: shownRecord).write(to: url, options: .atomic)
        }
    }

    /// Transkripti düz metin (`[mm:ss] Ad: metin`) olarak İndirilenler'e kaydeder.
    private func exportTranscriptText() {
        export = saveExport(format: .transcriptText, fileExtension: "txt") { (url: URL) throws -> Void in
            try Data(transcriptText(record: record).utf8).write(to: url, options: .atomic)
        }
    }

    /// Transkripti SRT altyazısı olarak İndirilenler'e kaydeder (videoya eklenebilir).
    private func exportSRT() {
        export = saveExport(format: .srt, fileExtension: "srt") { (url: URL) throws -> Void in
            try Data(transcriptSRT(record: record).utf8).write(to: url, options: .atomic)
        }
    }

    /// Dosyayı İndirilenler'e (aynı ad varsa numaralı) yazar; başarılıysa biçimi kullanım istatistiğine işlenir.
    private func saveExport(format: TelemetryExportFormat, fileExtension: String, write: (URL) throws -> Void) -> ExportStatus {
        do {
            let downloads: URL = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let url: URL = try exportFileURL(directory: downloads, title: record.note?.title ?? record.title, startedAt: record.startedAt, fileExtension: fileExtension)
            do {
                try write(url)
            } catch {
                throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
            }
            recordFeatureUsage(feature: .export(format))
            return .saved(url)
        } catch {
            meetingsLogger.error("Dışa aktarılamadı, uzantı: \(fileExtension, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return .failed(exportFailureMessage(error: error))
        }
    }

    /// Başka cihazdan eşitlenen toplantı (sesi o cihazda).
    private var isRecordedElsewhere: Bool {
        model.meetingsRecordedElsewhere.contains(record.id)
    }

    /// Çalınabilir kayıtlar ("Sen" ve "Diğerleri"): ses silinmediyse, toplantı kayıtta/işlemede değilse (dosya
    /// yazılıyor olabilir) ve şu an kayıt yapılmıyorsa (çalınan ses mikrofona girip yeni kayda karışmasın).
    private var playableAudio: [URL] {
        guard !record.audioDeleted, !isLocked, !model.isRecording else {
            return []
        }
        do {
            let directory: URL = try model.sessionDirectory(id: record.id)
            return [Speaker.others, Speaker.me].compactMap { meetingAudioURL(directory: directory, speaker: $0) }
        } catch {
            meetingsLogger.error("Toplantı klasörü alınamadı, kimlik: \(record.id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return []
        }
    }
}

/// Özet sekmesi bir belge gibi okunur: not bölümleri (görevler, konu akışı, kararlar…), büyük yazılı özet, kendi
/// notların ve not düzenleme; sonda kapalı "Ayrıntılar"da konuşma payları ve sözlük. Okunur genişlikte tek sütun.
private struct SummaryTab: View {
    let model: AppModel
    /// Gösterilen not: asıl not ya da başka dildeki sürümü (`SharedNoteSection`).
    let note: MeetingNote
    /// Asıl not: görevlerin tamamlanma ve anımsatıcı durumu onun görevlerine bağlıdır (çeviride görev metni değişir).
    let sourceNote: MeetingNote
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    /// Ses var: konu akışındaki zamana tıklayınca oradan çalar.
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    /// İşaretlenen anı ses klibi olarak kaydeder.
    let onClip: @MainActor (TranscriptParagraph) -> Void
    /// Konuşmacılara ad vermek için Transkript'e geçer (konuşmacı çipleri orada).
    let onNameSpeakers: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// Kendi notları yazılıyor (henüz notu yokken "Kendi notun" düğmesiyle açılır).
    @State private var isEditingMyNotes: Bool = false
    /// Konuşma payında kısa konuşmaların tek tek satırları açık.
    @State private var showsMinorSpeakers: Bool = false
    /// Maddenin kaynağından transkriptte o ana gider (çekmece açılır, ses varsa oradan çalar).
    let onJump: @MainActor (TranscriptParagraph) -> Void
    /// Kaynak kutusundaki "Sor": maddenin nasıl konuşulduğunu bu toplantıya sorar.
    let onAskSource: @MainActor (String) -> Void

    var body: some View {
        main.frame(maxWidth: 820, alignment: .leading)
    }

    private var main: some View {
        // Gösterilen görev asıl görevle sırayla eşleşir (`parseSharedNote` sayıyı ve sahipliği korur).
        let pairs: [TaskPair] = zip(note.tasks, sourceNote.tasks).map { (pair: (NoteTask, NoteTask)) -> TaskPair in
            TaskPair(shown: pair.0, source: pair.1)
        }
        let mine: [TaskPair] = pairs.filter(\.source.isMine)
        let myNotes: String = record.myNotes ?? ""
        let isLocked: Bool = model.isLocked(meetingID: record.id)
        let markedIDs: Set<String> = highlightedParagraphIDs(paragraphs: paragraphs, highlights: record.highlights ?? [])
        let marked: [TranscriptParagraph] = paragraphs.filter { markedIDs.contains($0.id) }
        let outline: [OutlineItem] = note.outline ?? []
        return VStack(alignment: .leading, spacing: 30) {
            if mine.isEmpty {
                // Yüz yüze toplantıda kullanıcı da "Konuşmacı N": hangisi olduğunu seçince görevleri ona düşer.
                UserSpeakerPrompt(record: record, userName: model.userName, isLocked: isLocked) { (person: Int, name: String) -> Void in
                    model.nameUserSpeaker(meetingID: record.id, person: person, name: name)
                }
            }
            // Not bir belge gibi: başlıklar ve maddeler; her maddenin kaynağı üstüne gelince sağdaki büyüteçte.
            noteBlock(title: "Özet") {
                ForEach(Array(noteSummaryBullets(summary: note.summary).enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                    bullet(text: item.element, anchorSec: nil) {
                        Text(item.element)
                    }
                }
            }
            .id(MeetingNoteAnchor.sections)
            if !pairs.isEmpty {
                tasksSection(pairs: pairs)
                    .id(MeetingNoteAnchor.myTasks)
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
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.element.title)
                                        .fontWeight(.semibold)
                                    Text(item.element.summary)
                                        .foregroundStyle(Theme.ink.opacity(0.8))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
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
            // Kendi notların (varsa ya da yazılırken) ve notu sorarak düzenleme tek grupta; "Kendi notun" düzenleme
            // alanının içinde küçük bir düğme.
            VStack(alignment: .leading, spacing: 10) {
                if !myNotes.isEmpty || isEditingMyNotes {
                    MyNotesCard(notes: myNotes, isLocked: isLocked, isEditing: $isEditingMyNotes) { (text: String) -> Void in
                        model.saveMyNotes(meetingID: record.id, text: text)
                    }
                }
                NoteEditBar(
                    isWorking: model.processingMeetingIDs.contains(record.id),
                    canAddMyNotes: myNotes.isEmpty && !isEditingMyNotes && !isLocked,
                    onAddMyNotes: { withAnimation(.smooth(duration: 0.2)) { isEditingMyNotes = true } }
                ) { (instruction: String) -> Void in
                    model.editNote(meetingID: record.id, instruction: instruction)
                }
            }
            details(isLocked: isLocked)
        }
        // Özet sekmesi transkriptle aynı metin ayarlarını kullanır (Ayarlar › Görünüm); başlıklar kendi yazı tipinde.
        .font(appearance.bodyFont)
        .lineSpacing(appearance.lineSpacing + 2)
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

    /// Kaynağı gösterilebilen nokta işaretli madde.
    private func bullet<Content: View>(text: String, anchorSec: Double?, @ViewBuilder content: @escaping () -> Content) -> some View {
        sourceRow(text: text, anchorSec: anchorSec) {
            NoteBulletDot()
        } content: {
            content()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Karar ya da açık konu maddesi: metin ve (varsa) sağda konuşulduğu an; kaynak aranırken o an öne geçer.
    private func anchoredBullet(line: AnchoredLine) -> some View {
        bullet(text: line.text, anchorSec: line.startSec) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(line.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let start = line.startSec {
                    NoteTimeChip(startSec: start, canPlay: canPlay, onPlay: onPlay)
                }
            }
        }
    }

    /// Kaynağı gösterilebilen not satırı (bkz. `NoteSourceRow`): kaynaklar kutu açılınca bulunur.
    private func sourceRow<Leading: View, Content: View>(
        text: String, anchorSec: Double?, @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        NoteSourceRow(
            text: text, anchorSec: anchorSec, paragraphs: paragraphs, outline: sourceNote.outline ?? [],
            speakerNames: record.speakerNames, canPlay: canPlay, onJump: onJump, onAsk: { onAskSource(text) },
            leading: leading, content: content
        )
    }

    /// Görevler: önce senin görevlerin, sonra diğerleri (tamamlananlar grubun sonunda); her görevin kaynağı da gösterilir.
    private func tasksSection(pairs: [TaskPair]) -> some View {
        let open: [TaskPair] = pairs.filter { !isTaskDone(record: record, task: $0.source) }
        let ordered: [TaskPair] = open + pairs.filter { isTaskDone(record: record, task: $0.source) }
        let mine: [TaskPair] = ordered.filter(\.source.isMine)
        let others: [TaskPair] = ordered.filter { !$0.source.isMine }
        let doneMine: Int = mine.filter { isTaskDone(record: record, task: $0.source) }.count
        return noteBlock(title: "Görevler") {
            if !mine.isEmpty {
                taskGroupLabel(title: "Senin görevlerin", detail: String(localized: "\(doneMine)/\(mine.count) tamamlandı"), tint: appearance.accent.color)
                ForEach(mine, id: \.source.trackingKey) { (pair: TaskPair) in
                    taskRow(pair: pair)
                }
            }
            if !others.isEmpty {
                taskGroupLabel(title: "Diğer görevler", detail: nil, tint: Theme.muted)
                    .padding(.top, mine.isEmpty ? 0 : 10)
                ForEach(others, id: \.source.trackingKey) { (pair: TaskPair) in
                    taskRow(pair: pair)
                }
            }
        }
    }

    /// Görev grubunun küçük etiketi ("Senin görevlerin · 1/3 tamamlandı").
    private func taskGroupLabel(title: LocalizedStringKey, detail: String?, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(tint)
            if let detail {
                Text(verbatim: "· \(detail)")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    /// Görev satırı; görev kimliğiyle: liste değişince (ör. tamamlanınca) satır durumu (Anımsatıcılar hatası) başka göreve
    /// geçmesin.
    private func taskRow(pair: TaskPair) -> some View {
        sourceRow(text: pair.source.description, anchorSec: nil) {
            EmptyView()
        } content: {
            TaskRow(model: model, record: record, task: pair.source, shown: pair.shown)
        }
        .id(pair.source.trackingKey)
    }

    /// İşaretlediğin anlar: zamanı (tıklayınca oradan çalar), konuşmacısı ve sözü; sağ tıkla ses klibi.
    private func momentsSection(marked: [TranscriptParagraph]) -> some View {
        ForEach(marked) { (paragraph: TranscriptParagraph) in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button {
                    onPlay(paragraph.startSec)
                } label: {
                    Label(timestamp(seconds: paragraph.startSec), systemImage: "bookmark.fill")
                        .appFont(size: 12, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(appearance.accent.color)
                }
                .buttonStyle(.hoverPlain)
                .disabled(!canPlay)
                VStack(alignment: .leading, spacing: 2) {
                    Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames))
                        .appFont(size: 12, weight: .semibold)
                    Text(paragraph.turkish ?? paragraph.text)
                        .font(appearance.secondaryFont)
                        .lineLimit(3)
                        .foregroundStyle(Theme.ink.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Klip olarak kaydet (ses)", systemImage: "waveform") { onClip(paragraph) }
                    .disabled(!canPlay)
            }
        }
    }

    /// Notun sonundaki az kullanılan bilgiler: konuşma payları ve sözlük, kapalı "Ayrıntılar"da. Adı verilmemiş
    /// konuşmacı varsa ad verme bağlantısı bölümün dışında da görünür (görevlerin kime düştüğü adlara bağlı).
    @ViewBuilder
    private func details(isLocked: Bool) -> some View {
        let groups: SpeakerGroups = groupedSpeakers(shares: speakerShares(paragraphs: paragraphs), speakerNames: record.speakerNames)
        let hasSpeakers: Bool = !groups.major.isEmpty || !groups.minor.isEmpty
        let unnamed: Bool = hasUnnamedSpeakers(shares: groups.major + groups.minor, speakerNames: record.speakerNames)
        if hasSpeakers || !note.glossary.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if unnamed, !isLocked {
                    Button("Konuşmacılara ad ver", systemImage: "person.text.rectangle") { onNameSpeakers() }
                        .buttonStyle(.plain)
                        .foregroundStyle(appearance.accent.color)
                        .appFont(size: 13, weight: .medium)
                        .linkPointer(isEnabled: true)
                        .hoverHint("Transkriptte konuşmacılara ad ver; not adlarla yeniden yazılabilir", alignment: .leading, edge: .bottom)
                }
                MeetingDetailsDisclosure(
                    summary: ([hasSpeakers ? String(localized: "Konuşma payları") : nil, note.glossary.isEmpty ? nil : String(localized: "Sözlük")])
                        .compactMap { $0 }
                        .joined(separator: " · ")
                ) {
                    if hasSpeakers {
                        talkShare(groups: groups)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                    if !note.glossary.isEmpty {
                        GlossaryList(glossary: note.glossary)
                    }
                }
            }
        }
    }

    /// Kim ne kadar konuştu: harf rozeti, ad, pay çubuğu ve yüzde. Kısa konuşmalar (bkz. `groupedSpeakers`) tek satırda
    /// toplanır; tıklayınca tek tek görünür.
    private func talkShare(groups: SpeakerGroups) -> some View {
        asideCard {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups.major, id: \.key) { (share: SpeakerShare) in
                    shareRow(
                        avatar: SpeakerAvatar(text: avatarText(key: share.key, speakerNames: record.speakerNames), color: speakerColor(key: share.key), size: 24),
                        name: speakerName(key: share.key, speakerNames: record.speakerNames), seconds: share.seconds, fraction: share.fraction,
                        color: speakerColor(key: share.key)
                    )
                }
                if !groups.minor.isEmpty {
                    Button {
                        showsMinorSpeakers.toggle()
                    } label: {
                        shareRow(
                            avatar: SpeakerAvatar(text: "…", color: Color.gray, size: 24),
                            name: String(localized: "Kısa konuşmalar (\(groups.minor.count))"), seconds: groups.minorSeconds,
                            fraction: groups.minorFraction, color: Color.gray
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHint(showsMinorSpeakers ? "Kısa konuşmaları gizle" : "Az konuşan kişileri tek tek göster", alignment: .leading, edge: .bottom)
                    if showsMinorSpeakers {
                        ForEach(groups.minor, id: \.key) { (share: SpeakerShare) in
                            shareRow(
                                avatar: SpeakerAvatar(text: avatarText(key: share.key, speakerNames: record.speakerNames), color: speakerColor(key: share.key), size: 20),
                                name: speakerName(key: share.key, speakerNames: record.speakerNames), seconds: share.seconds, fraction: share.fraction,
                                color: speakerColor(key: share.key)
                            )
                            .padding(.leading, 14)
                        }
                    }
                }
            }
            .animation(.smooth(duration: 0.2), value: showsMinorSpeakers)
        }
    }

    /// Konuşma payı satırı: ad ve yüzde üstte, pay çubuğu altta tam genişlikte (dar yan sütunda ad kesilmez).
    private func shareRow(avatar: SpeakerAvatar, name: String, seconds: Double, fraction: Double, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .appFont(size: 13, weight: .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: shareMinutesText(seconds: seconds))
                        .appFont(size: 11, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .frame(width: 44, alignment: .trailing)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
                        .appFont(size: 12, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(width: 38, alignment: .trailing)
                }
                // Pay çubuğu kişinin renginde (gradyanla hafif derinlik).
                GeometryReader { (proxy: GeometryProxy) in
                    Capsule()
                        .fill(Theme.soft)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(4, proxy.size.width * fraction))
                        }
                }
                .frame(height: 6)
            }
        }
    }

    /// Yan sütun kartı: düz kart yüzeyinde içerik (başlık etiketi yok; içerik kendini anlatır).
    private func asideCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }
}

/// Notu sorarak düzenle: tek satır istek ("özeti kısalt", "görevlere tarih ekle") ve hazır öneri hapları; düzenlenirken
/// parıltılı "Not düzenleniyor…".
private struct NoteEditBar: View {
    let isWorking: Bool
    /// Henüz kendi notu yok: alanın sağında "Kendi notun" düğmesi görünür.
    let canAddMyNotes: Bool
    let onAddMyNotes: @MainActor () -> Void
    let onEdit: @MainActor (String) -> Void
    @State private var instruction: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    /// Hazır istekler (kaynak dilde; gösterilirken ve gönderilirken arayüz diline çevrilir).
    private let suggestions: [String] = ["Özeti kısalt", "Görevlere tarih ekle", "Kararları gerekçeleriyle yaz", "Daha resmi yaz"]

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isWorking ? "sparkles" : "wand.and.stars")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: isWorking)
                TextField(isWorking ? "Not düzenleniyor…" : "Notu değiştir: \"özeti kısalt\", \"görevlere tarih ekle\"…", text: $instruction)
                    .textFieldStyle(.plain)
                    .appFont(size: 13, weight: .regular)
                    .focused($isFocused)
                    .disabled(isWorking)
                    .onSubmit(send)
                if !instruction.isEmpty, !isWorking {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .appFont(size: 11, weight: .bold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 24, height: 24)
                            .background(Theme.primary, in: Circle())
                    }
                    .buttonStyle(.hoverCapsule)
                    .accessibilityLabel("Notu düzenle")
                } else if canAddMyNotes, instruction.isEmpty {
                    Button("Kendi notun", systemImage: "square.and.pencil", action: onAddMyNotes)
                        .appFont(size: 12, weight: .medium)
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                        .fixedSize()
                        .hoverHint("Kendi notunu yaz; not onu öncelik sayıp yeniden yazılır", alignment: .trailing, edge: .bottom)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.card, in: shape)
            .overlay(shape.strokeBorder(isFocused ? appearance.accent.color.opacity(0.45) : Theme.line))
            if isFocused, instruction.isEmpty, !isWorking {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(suggestions, id: \.self) { (suggestion: String) in
                        Button {
                            onEdit(String(localized: String.LocalizationValue(suggestion)))
                        } label: {
                            Text(LocalizedStringKey(suggestion))
                                .appFont(size: 12, weight: .medium)
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.soft, in: Capsule())
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: isFocused)
    }

    private func send() {
        guard !isWorking else {
            return
        }
        onEdit(instruction)
        instruction = ""
        isFocused = false
    }
}

/// "Senin notların": kullanıcının toplantıda yazdıkları (not bunları öncelik saydı). Düzenlenebilir; "Kaydet ve notu
/// yeniden yaz" notu yeni notlarla baştan yazar. Not yokken düzenleme alanındaki "Kendi notun" düğmesiyle açılır.
private struct MyNotesCard: View {
    let notes: String
    let isLocked: Bool
    @Binding var isEditing: Bool
    let onSave: @MainActor (String) -> Void
    @State private var draft: String = ""
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label {
                    Text("SENİN NOTLARIN").tracking(DesignTokens.labelTracking)
                } icon: {
                    Image(systemName: "square.and.pencil")
                }
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                Spacer()
                if isEditing {
                    Button("Vazgeç") { withAnimation(.smooth(duration: 0.2)) { isEditing = false } }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                    Button("Kaydet ve notu yeniden yaz") {
                        onSave(draft)
                        withAnimation(.smooth(duration: 0.2)) { isEditing = false }
                    }
                    .buttonStyle(.pillPrimary)
                    .controlSize(.small)
                    // Toplantı işlenirken kayıt reddedilir: taslak kaybolmasın, düğme beklesin.
                    .disabled(isLocked)
                    .hoverHint(isLocked ? "Toplantı işleniyor; bitince kaydedebilirsin" : "Notu bu notlarla yeniden yazar", alignment: .trailing, edge: .bottom)
                } else {
                    Button("Düzenle", systemImage: "pencil") {
                        draft = notes
                        withAnimation(.smooth(duration: 0.2)) { isEditing = true }
                    }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                    .disabled(isLocked)
                }
            }
            .appFont(size: 12, weight: .medium)
            if isEditing {
                TextEditor(text: $draft)
                    .appFont(size: 14, weight: .regular)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90, maxHeight: 220)
            } else {
                Text(notes)
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accent.color.opacity(0.04), in: shape)
        .overlay(alignment: .leading) {
            // Sol kenarda vurgu çizgisi: bu metin kullanıcının kendi yazdığı.
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                .fill(appearance.accent.color.opacity(0.7))
                .frame(width: 3)
        }
        .overlay(shape.strokeBorder(Theme.line))
    }
}

/// "Ayrıntılar"daki sözlük: solda terim sağda anlamı olan, ince çizgilerle ayrılmış liste (dar panelde terim anlamının
/// üstünde).
private struct GlossaryList: View {
    let glossary: [GlossaryEntry]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(glossary.enumerated()), id: \.offset) { (item: (offset: Int, element: GlossaryEntry)) in
                if item.offset > 0 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                // Genişte yan yana, dar panelde alt alta.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        term(entry: item.element).frame(width: 200, alignment: .leading)
                        meaning(entry: item.element).frame(minWidth: 240, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        term(entry: item.element)
                        meaning(entry: item.element)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .cardSurface(cornerRadius: 14)
        .accessibilityLabel(Text("Sözlük"))
        .accessibilityElement(children: .contain)
    }

    private func term(entry: GlossaryEntry) -> some View {
        Text(entry.term)
            .font(appearance.readingFont(size: appearance.textSize, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func meaning(entry: GlossaryEntry) -> some View {
        Text(entry.meaning)
            .font(appearance.readingFont(size: appearance.textSize, weight: .regular))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Konuşmacılardan biri hâlâ "Konuşmacı N" (adı verilmemiş) mi. Saf fonksiyondur.
private func hasUnnamedSpeakers(shares: [SpeakerShare], speakerNames: [Int: String]) -> Bool {
    shares.contains { (share: SpeakerShare) -> Bool in
        guard let person = share.key.person else {
            return false
        }
        return (speakerNames[person] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Toplantı notunun sonunda kapalı başlayan "Ayrıntılar" (konuşma payları, sözlük); kapalıyken içindekiler soluk tek
/// satırda. Sistemin açılır bölümü: VoiceOver "genişletildi/daraltıldı" diye okur. Açık/kapalı tercihi bütün toplantılar
/// için hatırlanır.
private struct MeetingDetailsDisclosure<Content: View>: View {
    /// Kapalıyken başlığın yanında: içindekiler ("Konuşma payları · Sözlük").
    let summary: String
    @ViewBuilder let content: () -> Content
    @AppStorage(SettingsKey.meetingDetailsExpanded) private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding<Bool>(
            get: { isExpanded },
            set: { (value: Bool) -> Void in withAnimation(.smooth(duration: 0.3)) { isExpanded = value } }
        )) {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            // Başlığın tamamı tıklanır (yalnız üçgen değil).
            Button {
                withAnimation(.smooth(duration: 0.3)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Ayrıntılar")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    if !isExpanded, !summary.isEmpty {
                        Text(verbatim: summary)
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Ayrıntılar"))
            .accessibilityHint(Text(verbatim: summary))
        }
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// Notun başka dildeki sürümü: yoksa (ya da eski, eksik bölümlü sürümse) hazırlanır (ilerleme, hata ve yeniden dene);
/// varsa asıl notla aynı düzende (`SummaryTab`) gösterilir. Kopyalama, paylaşma ve dışa aktarma kapaktaki eylemlerdedir
/// (seçili dilde çıkar).
private struct SharedNoteSection: View {
    let model: AppModel
    let record: MeetingRecord
    let note: MeetingNote
    let language: ShareLanguage
    let paragraphs: [TranscriptParagraph]
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    let onClip: @MainActor (TranscriptParagraph) -> Void
    /// Konuşmacılara ad vermek için Transkript'e geçer.
    let onNameSpeakers: @MainActor () -> Void
    /// Bkz. `SummaryTab.onJump` ve `onAskSource`.
    let onJump: @MainActor (TranscriptParagraph) -> Void
    let onAskSource: @MainActor (String) -> Void
    @State private var error: String?
    @State private var attempt: Int = 0

    /// Gösterilecek çeviri: saklı ve asıl notun tüm bölümlerini taşıyorsa.
    private var shared: MeetingNote? {
        sharedNoteVersion(record: record, language: language)
    }

    var body: some View {
        Group {
            if let shared {
                SummaryTab(
                    model: model, note: shared, sourceNote: note, record: record, paragraphs: paragraphs, canPlay: canPlay,
                    onPlay: onPlay, onClip: onClip, onNameSpeakers: onNameSpeakers, onJump: onJump, onAskSource: onAskSource
                )
            } else if let error {
                VStack(alignment: .leading, spacing: 8) {
                    EmptyStateCard(symbol: "exclamationmark.triangle", title: "Çeviri yapılamadı", message: "\(error)")
                    Button("Yeniden dene", systemImage: "arrow.clockwise") {
                        self.error = nil
                        attempt += 1
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(language.interfaceName) sürümü hazırlanıyor…")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 8)
            }
        }
        // Not yeniden yazılınca ya da kilit kalkınca yeniden denenir (aksi halde bekleme göstergesi takılı kalırdı).
        .task(id: "\(language.rawValue)-\(attempt)-\(shared == nil)-\(note.summary.hashValue)-\(model.isLocked(meetingID: record.id))") {
            // Toplantı işlenirken çevrilmez: sonuç zaten saklanamaz (istek boşa gider); kilit kalkınca görev yeniden çalışır.
            guard shared == nil, error == nil, !model.isLocked(meetingID: record.id) else {
                return
            }
            error = await model.generateSharedNote(meetingID: record.id, language: language)
        }
    }
}

/// Takip e-postası: notun özetinden, kararlarından ve görevlerinden yazılan taslak sayfada satır içinde (açılır pencere
/// yok). Yazılırken ilerleme, olmazsa neden ve "Yeniden dene"; hazır olunca konu ve gövde düzenlenir, "Kopyala" ya da
/// "Mail'de aç" (alıcılar bağlı takvim etkinliğinin katılımcıları). Dil değişince taslak o dilde yeniden yazılır.
private struct FollowUpEmailCard: View {
    let model: AppModel
    let record: MeetingRecord
    /// Notun yazıldığı dil (dil menüsünün başında).
    let noteLanguage: ShareLanguage
    let onClose: @MainActor () -> Void
    @State private var language: ShareLanguage
    @State private var phase: FollowUpEmailPhase = .drafting
    @State private var subject: String = ""
    @State private var text: String = ""
    @State private var attempt: Int = 0
    /// Kopyalama ya da Mail'de açma olmadı: neden kartta.
    @State private var actionError: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    init(model: AppModel, record: MeetingRecord, noteLanguage: ShareLanguage, initialLanguage: ShareLanguage, onClose: @escaping @MainActor () -> Void) {
        self.model = model
        self.record = record
        self.noteLanguage = noteLanguage
        self.onClose = onClose
        _language = State(initialValue: initialLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label {
                    Text("TAKİP E-POSTASI").tracking(DesignTokens.labelTracking)
                } icon: {
                    Image(systemName: "envelope")
                }
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                Spacer(minLength: 8)
                languageMenu
                Button("Kapat", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("Takip e-postasını kapat")
            }
            Text("Notun özetinden, kararlarından ve görevlerinden katılımcılara kısa bir takip e-postası yazılır; notta olmayan bilgi eklenmez. Göndermeden önce burada düzenleyebilirsin.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            switch phase {
            case .drafting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Takip e-postası yazılıyor…")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 6)
            case .failed(let message):
                NoticeText(String(localized: "Takip e-postası yazılamadı: \(message)"), severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .textSelection(.enabled)
                Button("Yeniden dene", systemImage: "arrow.clockwise") { attempt += 1 }
                    .buttonStyle(.pill)
            case .ready:
                TextField("Konu", text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .appFont(size: 13, weight: .medium)
                TextEditor(text: $text)
                    .appFont(size: 13, weight: .regular)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180, maxHeight: 360)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                HStack(spacing: DesignTokens.Spacing.s) {
                    Button("Mail'de aç", systemImage: "envelope") { openInMail() }
                        .buttonStyle(.pillPrimary)
                    Button("Kopyala", systemImage: "doc.on.doc") { copy() }
                        .buttonStyle(.pill)
                    Spacer(minLength: 8)
                    Button("Yeniden yaz", systemImage: "arrow.clockwise") { attempt += 1 }
                        .buttonStyle(.pill)
                }
                if let actionError {
                    NoticeText(actionError, severity: .error)
                        .appFont(size: 12, weight: .regular)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 820, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        // Dil değişince ya da yeniden istenince taslak baştan yazılır; kart kapanınca istek iptal edilir.
        .task(id: "\(language.rawValue)-\(attempt)") {
            phase = .drafting
            actionError = nil
            switch await model.draftFollowUpEmail(meetingID: record.id, language: language) {
            case .drafted(let draft):
                subject = draft.subject
                text = draft.body
                phase = .ready
            case .subscriptionRequired:
                // Abonelik teklifi açıldı: kart kapanır.
                onClose()
            case .cancelled:
                return
            case .failed(let message):
                phase = .failed(message)
            }
        }
    }

    /// Taslağın dili: notun dili, sık kullanılan Fince ve İngilizce, sonra diğer diller.
    private var languageMenu: some View {
        let choices: ShareLanguageChoices = shareLanguageChoices(original: noteLanguage)
        return Menu {
            Button(noteLanguage.interfaceName) { language = noteLanguage }
            ForEach(choices.featured, id: \.self) { (choice: ShareLanguage) in
                Button(choice.interfaceName) { language = choice }
            }
            Divider()
            Menu("Diğer diller") {
                ForEach(choices.others, id: \.self) { (choice: ShareLanguage) in
                    Button(choice.interfaceName) { language = choice }
                }
            }
        } label: {
            Label {
                Text(verbatim: language.interfaceName)
            } icon: {
                Image(systemName: "globe")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.pill)
        .fixedSize()
        .disabled(phase == .drafting)
        .accessibilityLabel("Takip e-postasının dili")
    }

    /// Konu ve gövdeyi panoya kopyalar (ilk satır konu).
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(subject)\n\n\(text)", forType: .string)
        actionError = nil
        ToastCenter.shared.show(kind: .success, title: String(localized: "Takip e-postası kopyalandı"), detail: nil, action: nil)
    }

    /// Taslağı varsayılan e-posta uygulamasında yeni ileti olarak açar; alıcılar bağlı takvim etkinliğinin katılımcıları
    /// (yoksa boş, kullanıcı yazar).
    private func openInMail() {
        let draft: FollowUpEmailDraft = FollowUpEmailDraft(subject: subject, body: text)
        guard let url = followUpMailtoURL(draft: draft, recipients: model.followUpRecipients(meetingID: record.id)) else {
            actionError = String(localized: "Mail açılamadı: taslak e-posta bağlantısına çevrilemedi. \"Kopyala\" ile yapıştırabilirsin.")
            return
        }
        guard NSWorkspace.shared.open(url) else {
            actionError = String(localized: "Mail açılamadı: Mac'te ayarlı bir e-posta uygulaması yok. \"Kopyala\" ile yapıştırabilirsin.")
            return
        }
        actionError = nil
    }
}

/// Takip e-postası kartının durumu.
private enum FollowUpEmailPhase: Equatable {
    case drafting
    case ready
    case failed(String)
}

/// Konu akışında bir bölüm: solda zaman (ses varsa tıklayınca oradan çalar) ve dikey çizgi, sağda başlık ve özet.
/// "01", "02": karar numarası. Saf fonksiyondur.
private func decisionNumber(index: Int) -> String {
    index + 1 < 10 ? "0\(index + 1)" : "\(index + 1)"
}

/// Görev kartı: sahibinin harf rozeti, iş, altında sahibinin adı ve varsa tarih çipi. Ad işin önünde ("Alex — …")
/// yinelenmez: rozet yanında okunmayı zorlaştırıyordu.
/// Özet sekmesinde bir görev: ekranda yazılan (çeviri olabilir) ve durumu taşıyan asıl görev.
private struct TaskPair {
    let shown: NoteTask
    let source: NoteTask
}

/// Görev satırı (ince çizgili listede): tamamlandı kutusu, iş, altında sahibinin küçük rozeti ve adı, varsa tarih;
/// sağda Anımsatıcılar zili. Tamamlanan görevin üstü çizilir.
private struct TaskRow: View {
    let model: AppModel
    let record: MeetingRecord
    /// Asıl nottaki görev: tamamlanma ve anımsatıcı buna bağlıdır.
    let task: NoteTask
    /// Ekranda yazılan görev: asıl görev ya da başka dildeki karşılığı.
    let shown: NoteTask
    @State private var isHovering: Bool = false

    var body: some View {
        let isDone: Bool = isTaskDone(record: record, task: task)
        // Kendi görevinde sahip (kendi adın) yazılmaz: grubun başlığı söylüyor.
        let showsOwner: Bool = !task.isMine
        HStack(alignment: .top, spacing: 12) {
            TaskCheckbox(isDone: isDone) { model.toggleTask(meetingID: record.id, task: task) }
                .disabled(model.isLocked(meetingID: record.id))
            VStack(alignment: .leading, spacing: 5) {
                Text(shown.description)
                    .strikethrough(isDone, color: Theme.muted)
                    .foregroundStyle(isDone ? Theme.muted : Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if showsOwner || task.dueDate != nil {
                    HStack(spacing: 6) {
                        if showsOwner {
                            SpeakerAvatar(text: ownerInitial(owner: shown.owner), color: ownerColor(task: task, speakerNames: record.speakerNames), size: 18)
                                .accessibilityHidden(true)
                            Text(verbatim: shown.owner)
                                .appFont(size: 12, weight: .medium)
                                .foregroundStyle(Theme.muted)
                        }
                        if task.dueDate != nil {
                            if showsOwner {
                                Text(verbatim: "·").foregroundStyle(Theme.muted)
                            }
                            // Son gün asıl notun tarihinden toplantı gününe göre çözülür, arayüz dilinde göreli.
                            TaskDueText(record: record, task: task, size: 12)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Zil yalnız anımsatıcı eklendiyse ya da fare satırdayken (her satırda sürekli durunca gürültüydü).
            ReminderButton(model: model, record: record, task: task)
                .opacity(isHovering || isTaskReminded(record: record, task: task) ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { (hovering: Bool) -> Void in isHovering = hovering }
        .animation(.smooth(duration: 0.2), value: isDone)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contextMenu {
            // Yalnız elle eklenen görev silinir; nottan gelen görev notun parçasıdır.
            if task.isAdded == true {
                Button("Görevi sil", systemImage: "trash", role: .destructive) {
                    model.removeAddedTask(meetingID: record.id, task: task)
                }
                .disabled(model.isLocked(meetingID: record.id))
            }
        }
    }
}

/// Görevin tamamlandı kutusu: boş daire / dolu onay; el imleci, basınca küçülür.
struct TaskCheckbox: View {
    let isDone: Bool
    let onToggle: @MainActor () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .appFont(size: 17, weight: .regular)
                .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.muted))
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.hoverPlain)
        .hoverHint(isDone ? "Yapılmadı olarak işaretle" : "Yapıldı olarak işaretle", alignment: .leading, edge: .bottom)
        .accessibilityLabel(isDone ? Text("Yapıldı") : Text("Yapılmadı"))
    }
}

/// Görevi Apple Anımsatıcılar'a ekleyen zil düğmesi; eklendiyse dolu zil (yeniden eklenmez), hata altında görünür.
struct ReminderButton: View {
    let model: AppModel
    let record: MeetingRecord
    let task: NoteTask
    @State private var isAdding: Bool = false
    @State private var error: String?

    var body: some View {
        let reminded: Bool = isTaskReminded(record: record, task: task)
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                isAdding = true
                Task {
                    error = await model.addToReminders(meetingID: record.id, task: task)
                    isAdding = false
                }
            } label: {
                Group {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: reminded ? "bell.badge.fill" : "bell")
                            .foregroundStyle(reminded ? NoticeSeverity.attention.tint : Theme.muted)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.hoverPlain)
            // İşlenirken eklenen anımsatıcı işaretlenemezdi; tekrar eklenmesin diye kapalı.
            .disabled(reminded || isAdding || model.isLocked(meetingID: record.id))
            .hoverHint(reminded ? "Anımsatıcılar'da" : "Anımsatıcılar'a ekle", alignment: .trailing, edge: .bottom)
            if let error {
                NoticeText(error, severity: .error)
                    .appFont(size: 11, weight: .regular)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Görev sahibinin rozet harfi: "Konuşmacı 2" → "2", "Aino" → "A". Saf fonksiyondur.
private func ownerInitial(owner: String) -> String {
    if let number = speakerNumber(owner: owner) {
        return "\(number)"
    }
    return owner.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
}

/// Not numaralı konuşmacı etiketi yazdıysa (tek sözcük ve sayı: "Konuşmacı 2", not başka dildeyse "Speaker 2",
/// "Puhuja 2") numarası. Saf fonksiyondur.
private func speakerNumber(owner: String) -> Int? {
    guard let match = owner.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\p{L}+\s+(\d{1,3})/) else {
        return nil
    }
    return Int(match.1)
}

/// Görev sahibinin rengi: sen mavi, adı verilmiş ya da numaralı konuşmacı kendi rengi, diğerleri addan sabit bir renk.
/// Saf fonksiyondur.
private func ownerColor(task: NoteTask, speakerNames: [Int: String]) -> Color {
    if task.isMine {
        return DesignTokens.meSpeakerColor
    }
    if let person = speakerNumber(owner: task.owner)
        ?? speakerNames.first(where: { $0.value.caseInsensitiveCompare(task.owner) == .orderedSame })?.key {
        return personColor(person: person)
    }
    let hash: Int = task.owner.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    return personColor(person: hash % DesignTokens.personPalette.count + 1)
}

/// Konuşmacının rengi: numaralı kişi kendi rengi, "Sen" mavi, ayrılmamış "Diğerleri" gri. Saf fonksiyondur.
private func speakerColor(key: SpeakerKey) -> Color {
    switch (key.speaker, key.person) {
    case (_, .some(let person)): personColor(person: person)
    case (.me, nil): DesignTokens.meSpeakerColor
    case (.others, nil): Color.gray
    }
}

/// Konuşmacının görünen adı: verilen ad, yoksa "Konuşmacı N", "Sen" ya da "Diğerleri". Saf fonksiyondur.
private func speakerName(key: SpeakerKey, speakerNames: [Int: String]) -> String {
    if let person = key.person, let name = speakerNames[person], !name.isEmpty {
        return name
    }
    return speakerLabel(speaker: key.speaker, person: key.person)
}

/// Konuşma payının dakikası, ör. "12 dk"; bir dakikanın altı "<1 dk" (yukarı yuvarlanıp 1 dk görünmez). Saf fonksiyondur.
private func shareMinutesText(seconds: Double) -> String {
    seconds < 60 ? String(localized: "<1 dk") : String(localized: "\(Int((seconds / 60).rounded())) dk")
}

/// Rozet harfi: adın baş harfi, adsız numaralı kişide numara, "Sen"/"Diğerleri"nde etiketin baş harfi. Saf fonksiyondur.
private func avatarText(key: SpeakerKey, speakerNames: [Int: String]) -> String {
    if let person = key.person, speakerNames[person]?.isEmpty ?? true {
        return "\(person)"
    }
    return speakerName(key: key, speakerNames: speakerNames).first.map { String($0).uppercased() } ?? "?"
}

/// Renkli daire içinde beyaz harf (konuşmacı ve görev sahibi rozeti).
private struct SpeakerAvatar: View {
    let text: String
    let color: Color
    let size: CGFloat

    var body: some View {
        // Sade rozet: konuşmacı rengi yalnızca soluk zeminde ve yazıda (dolu renkli daireler sayfayı fazla renklendiriyordu).
        Text(text)
            .appFont(size: size * 0.42, weight: .semibold)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            // Opak: kapaktaki gradyanın üstünde de okunur.
            .background(Circle().fill(color.opacity(0.15)).background(Circle().fill(Theme.card)))
    }
}

/// Başlık kartındaki konuşmacı zaman çizgisi: kim ne zaman konuştu; çalarken okuma çizgisi; tıklayınca oradan çalar.
private struct SpeakerTimeline: View {
    let spans: [SpeakerSpan]
    let totalSec: Double
    let player: MeetingAudioPlayer
    let meetingID: String
    let canPlay: Bool
    let onSeek: @MainActor (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { (proxy: GeometryProxy) in
                let width: CGFloat = proxy.size.width
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.soft)
                        ForEach(Array(spans.enumerated()), id: \.offset) { (item: (offset: Int, element: SpeakerSpan)) in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(speakerColor(key: item.element.key))
                                .frame(width: max(2, width * (item.element.endSec - item.element.startSec) / totalSec))
                                .offset(x: width * item.element.startSec / totalSec)
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                    // Konumu yalnızca bu küçük görünüm okur: konuşmacı şeritleri her güncellemede yeniden çizilmez.
                    Playhead(player: player, meetingID: meetingID, width: width, totalSec: totalSec)
                }
                .frame(width: width, height: 14)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { (location: CGPoint) -> Void in
                    if canPlay {
                        onSeek(totalSec * min(1, max(0, location.x / width)))
                    }
                }
                .pointerStyle(canPlay ? .link : nil)
            }
            .frame(height: 14)
            HStack(spacing: DesignTokens.Spacing.s) {
                Text(verbatim: timestamp(seconds: 0))
                Spacer(minLength: 0)
                if canPlay {
                    Text("Kim ne zaman konuştu")
                        .lineLimit(1)
                        .hoverHint("Tıkla, oradan çal", alignment: .center, edge: .bottom)
                } else {
                    Text("Kim ne zaman konuştu")
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(verbatim: timestamp(seconds: totalSec))
            }
            .appFont(size: 11, weight: .regular)
            .monospacedDigit()
            .opacity(0.75)
        }
    }
}

/// Konuşmacılar transkriptin başında çip olarak: tıklayınca ad verme ya da başka konuşmacıyla birleştirme (ayırma aynı
/// kişiyi ikiye böldüyse); yanında akıllı modelin ad/birleştirme önerileri ("Gözden geçir").
private struct SpeakerChips: View {
    let model: AppModel
    let record: MeetingRecord
    let isLocked: Bool
    let onPlay: @MainActor (Double) -> Void
    /// Kısa konuşmaların çipleri açık.
    @State private var showsMinor: Bool = false

    var body: some View {
        // Gösterilen transkriptle aynı bölüm kümesi. Az konuşanlar (bkz. `groupedSpeakers`) tek "Kısa konuşmalar (N)"
        // çipinde toplanır; açınca kendi çipleriyle ad verilir ya da birleştirilir.
        let persons: [Int] = Array(Set(meetingSegments(record: record).compactMap(\.person))).sorted()
        let minor: [Int] = groupedSpeakers(shares: speakerShares(record: record), speakerNames: record.speakerNames).minor
            .compactMap(\.key.person)
            .filter { persons.contains($0) }
        let major: [Int] = persons.filter { !minor.contains($0) }
        if !persons.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.s) {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(major, id: \.self) { (person: Int) in
                            SpeakerChip(model: model, record: record, person: person, others: persons.filter { $0 != person })
                                .disabled(isLocked)
                        }
                        if !minor.isEmpty {
                            minorToggle(count: minor.count)
                        }
                        if showsMinor {
                            ForEach(minor, id: \.self) { (person: Int) in
                                SpeakerChip(model: model, record: record, person: person, others: persons.filter { $0 != person })
                                    .disabled(isLocked)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Gözden geçir", systemImage: "sparkles") {
                        model.reviewSpeakers(meetingID: record.id)
                    }
                    .controlSize(.small)
                    .disabled(isLocked || model.speakerReviews[record.id] == .loading)
                    .hoverHint("Transkripti okuyup ad ve birleştirme önerir", alignment: .trailing, edge: .bottom)
                }
                if let state = model.speakerReviews[record.id] {
                    SpeakerReviewCard(model: model, record: record, state: state, isLocked: isLocked, onPlay: onPlay)
                }
            }
        }
    }

    /// "Kısa konuşmalar (N)" çipi: az konuşanların çiplerini açar/kapatır (konuşmacı çipiyle aynı görünüm).
    private func minorToggle(count: Int) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { showsMinor.toggle() }
        } label: {
            HStack(spacing: 8) {
                SpeakerAvatar(text: "…", color: Color.gray, size: 24)
                Text("Kısa konuşmalar (\(count))")
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Image(systemName: showsMinor ? "chevron.up" : "chevron.down")
                    .appFont(size: 9, weight: .semibold)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
        }
        .buttonStyle(.hoverCapsule)
        .fixedSize()
        .hoverHint(showsMinor ? "Kısa konuşmaları gizle" : "Az konuşan kişileri tek tek göster", alignment: .leading, edge: .bottom)
    }
}

/// Sabit toplantı dilinden başka dilde olduğu için transkriptten, nottan ve Sor'dan atlanan bölümler: tek satır
/// ("Başka dilde N bölüm atlandı") ve isteyene soluk liste (zamanına tıklayınca oradan çalar). Bölümler kayıtta durur.
private struct SkippedLanguageSection: View {
    let record: MeetingRecord
    let segments: [StoredSegment]
    let language: MeetingLanguage
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundStyle(Theme.muted)
                Text("Başka dilde \(segments.count) bölüm atlandı")
                    .foregroundStyle(Theme.muted)
                    .hoverHint("Toplantı dili \(meetingLanguageName(language: language)) seçildi: başka dildeki konuşma transkripte, nota ve Sor'a girmez.", alignment: .leading, edge: .bottom)
                Button(isExpanded ? "Gizle" : "Göster") {
                    withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
                }
                .buttonStyle(.link)
            }
            .appFont(size: 12, weight: .regular)
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segments, id: \.key) { (segment: StoredSegment) in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button(timestamp(seconds: segment.startSec)) {
                                onPlay(segment.startSec)
                            }
                            .buttonStyle(.link)
                            .disabled(!canPlay)
                            .monospacedDigit()
                            Text(verbatim: "\(speakerName(key: SpeakerKey(speaker: segment.speaker, person: segment.person), speakerNames: record.speakerNames)): \(segment.text)")
                                .italic()
                                .foregroundStyle(Theme.muted)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .appFont(size: 12, weight: .regular)
                .padding(.leading, 20)
                .transition(.opacity)
            }
        }
    }
}

/// Konuşmacı çipi: rozet ve ad; tıklayınca menü (ad ver, birleştir). Ad verirken çip yazı alanına döner: Enter kaydeder,
/// Esc vazgeçer, odaktan çıkınca kaydedilir.
private struct SpeakerChip: View {
    let model: AppModel
    let record: MeetingRecord
    let person: Int
    let others: [Int]
    @State private var isEditing: Bool = false
    @State private var name: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        let key: SpeakerKey = SpeakerKey(speaker: .others, person: person)
        let current: String = record.speakerNames[person] ?? ""
        Group {
            if isEditing {
                HStack(spacing: 8) {
                    SpeakerAvatar(text: avatarText(key: key, speakerNames: record.speakerNames), color: speakerColor(key: key), size: 24)
                    TextField("Ad (ör. Aino)", text: $name)
                        .textFieldStyle(.plain)
                        .appFont(size: 13, weight: .medium)
                        .frame(width: 140)
                        .focused($isFocused)
                        .onSubmit { commit() }
                        .onExitCommand { isEditing = false }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.ink))
                .onAppear { isFocused = true }
                .onChange(of: isFocused) { (_: Bool, focused: Bool) in
                    if !focused, isEditing {
                        commit()
                    }
                }
            } else {
                Menu {
                    Button(current.isEmpty ? "Ad ver…" : "Adı değiştir…", systemImage: "pencil") {
                        name = current
                        isEditing = true
                    }
                    if !others.isEmpty {
                        Menu("Şununla birleştir") {
                            ForEach(others, id: \.self) { (target: Int) in
                                Button(speakerName(key: SpeakerKey(speaker: .others, person: target), speakerNames: record.speakerNames)) {
                                    model.mergeSpeakers(meetingID: record.id, from: person, into: target)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        SpeakerAvatar(text: avatarText(key: key, speakerNames: record.speakerNames), color: speakerColor(key: key), size: 24)
                        Text(speakerName(key: key, speakerNames: record.speakerNames))
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(Theme.ink)
                        Image(systemName: "chevron.down")
                            .appFont(size: 9, weight: .semibold)
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 12)
                    .padding(.vertical, 4)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                }
                .menuStyle(.button)
                .buttonStyle(.hoverCapsule)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverHint("Ad ver ya da başka konuşmacıyla birleştir", alignment: .leading, edge: .bottom)
            }
        }
        .animation(.smooth(duration: 0.2), value: isEditing)
    }

    private func commit() {
        isEditing = false
        model.renameSpeaker(meetingID: record.id, person: person, name: name)
    }
}

/// Konuşmacı incelemesinin önerileri: her biri tek tıkla uygulanır ya da reddedilir; şüpheli anlara tıklayınca
/// oradan çalınır. Öneri uygulanınca not eski adlarla kaldığı için "Notu yenile" sunulur.
private struct SpeakerReviewCard: View {
    let model: AppModel
    let record: MeetingRecord
    let state: SpeakerReviewState
    let isLocked: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Label("Konuşmacı önerileri", systemImage: "sparkles")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Button("Kapat", systemImage: "xmark") { model.closeSpeakerReview(meetingID: record.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(.secondary)
                    .hoverHint("Önerileri kapat", alignment: .trailing, edge: .bottom)
            }
            content
        }
        .padding(DesignTokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: DesignTokens.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Transkript okunuyor…").foregroundStyle(.secondary)
            }
            .appFont(size: 12, weight: .regular)
        case .failed(let message):
            NoticeText(message, severity: .error)
                .appFont(size: 12, weight: .regular)
                .textSelection(.enabled)
        case .ready(let review, let applied):
            ForEach(review.names) { (suggestion: SpeakerNameSuggestion) in
                suggestionRow(
                    title: Text("\(label(person: suggestion.person)) → \(suggestion.name)"),
                    reason: suggestion.reason,
                    onAccept: { model.acceptNameSuggestion(meetingID: record.id, suggestion: suggestion) },
                    onDismiss: { model.dismissNameSuggestion(meetingID: record.id, suggestion: suggestion) }
                )
            }
            ForEach(review.merges) { (suggestion: SpeakerMergeSuggestion) in
                suggestionRow(
                    title: Text("\(label(person: suggestion.from)) ile \(label(person: suggestion.into)) aynı kişi"),
                    reason: suggestion.reason,
                    onAccept: { model.acceptMergeSuggestion(meetingID: record.id, suggestion: suggestion) },
                    onDismiss: { model.dismissMergeSuggestion(meetingID: record.id, suggestion: suggestion) }
                )
            }
            if !review.suspicious.isEmpty {
                Text("KONTROL ET")
                    .appFont(size: 11, weight: .semibold)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(.secondary)
                    .padding(.top, DesignTokens.Spacing.xs)
                ForEach(review.suspicious) { (passage: SuspiciousPassage) in
                    suspiciousRow(passage: passage)
                }
            }
            if !review.hasPendingSuggestions && review.suspicious.isEmpty && applied == 0 {
                Label("Öneri yok: transkriptte ad ya da birleştirme için yeterli ipucu bulunamadı.", systemImage: "lightbulb")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(.secondary)
            }
            if applied > 0 {
                HStack(spacing: DesignTokens.Spacing.s) {
                    Text("Not eski adlarla yazıldı.")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(.secondary)
                    Button("Notu yenile", systemImage: "sparkles") { model.regenerateNote(meetingID: record.id) }
                        .controlSize(.small)
                        .disabled(isLocked)
                }
                .padding(.top, DesignTokens.Spacing.xs)
            }
        }
    }

    /// Konuşmacının şu anki adı ve numarası: "Aino (Konuşmacı 2)" ya da "Konuşmacı 2".
    private func label(person: Int) -> String {
        let number: String = speakerLabel(speaker: .others, person: person)
        return record.speakerNames[person].map { "\($0) (\(number))" } ?? number
    }

    private func suggestionRow(title: Text, reason: String, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(appearance.bodyFont.weight(.medium))
                Text(reason)
                    .font(appearance.secondaryFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Uygula", systemImage: "checkmark", action: onAccept)
                .labelStyle(.iconOnly)
                .buttonStyle(.pillPrimary)
                .controlSize(.small)
                .disabled(isLocked)
                .hoverHint("Öneriyi uygula", alignment: .trailing, edge: .bottom)
            Button("Reddet", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .hoverHint("Öneriyi reddet", alignment: .trailing, edge: .bottom)
        }
    }

    @ViewBuilder
    private func suspiciousRow(passage: SuspiciousPassage) -> some View {
        let row: some View = HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.s) {
            Text(passage.time)
                .appFont(size: 11, weight: .regular).monospacedDigit()
                .foregroundStyle(.tint)
            Text(passage.note)
                .font(appearance.secondaryFont)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let seconds = timestampSeconds(text: passage.time), !record.audioDeleted {
            Button { onPlay(seconds) } label: { row }
                .buttonStyle(.hoverPlain)
                .hoverHint("Bu andan dinle", alignment: .leading, edge: .bottom)
        } else {
            row
        }
    }
}

/// Ses varsa konuşma satırı tıklanabilir: hover'da soluk zemin ve sağ üstte çal düğmesi, el imleci; yoksa düz metin
/// (tıklanabilir görünmesin).
private struct PlayableTurn: ViewModifier {
    let canPlay: Bool
    let onTap: @MainActor () -> Void
    @State private var isHovering: Bool = false

    func body(content: Content) -> some View {
        if canPlay {
            content
                .background(isHovering ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isHovering {
                        Image(systemName: "play.fill")
                            .appFont(size: 10, weight: .semibold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 28, height: 28)
                            .background(Theme.primary, in: Circle())
                            .padding(10)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { onTap() }
                .onHover { (hovering: Bool) -> Void in isHovering = hovering }
                .pointerStyle(.link)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Buradan dinle")
        } else {
            content
        }
    }
}

/// Paragraflı transkript (aynı konuşmacının art arda bölümleri tek paragraf, yankı süzülmüş); altında çevirisi.
/// Çalarken şarkı sözü gibi akar: çalan paragrafta söylenen kelimeler parlak, o anki kelime vurgu renginde, gelecek
/// kelimeler soluk; çalan paragraf ortaya kaydırılır. Paragrafa tıklayınca oradan çalar.
private struct TranscriptSection: View {
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    let player: MeetingAudioPlayer
    let proxy: ScrollViewProxy
    /// Ses var (silinmemiş, kayıtta değil): paragrafa tıklayınca oradan çalar.
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    /// İşaret eklenip kaldırılabilir (kayıtta/işlemede değil).
    let canEdit: Bool
    let onToggleHighlight: @MainActor (TranscriptParagraph) -> Void
    /// Paragrafın sesini klip olarak kaydeder (sağ tık).
    let onClip: @MainActor (TranscriptParagraph) -> Void
    /// Toplantı sonu çevirisi yapılamayan parçaları yeniden çevirir ("Çeviri alınamadı · Tekrar dene").
    let onRetryTranslation: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    /// Çalan paragraf: konum her güncellendiğinde değil, yalnızca paragraf değişince yazılır (tüm transkript saniyede
    /// onlarca kez yeniden çizilmesin; kelime vurgusu yalnızca çalan paragrafın içinde güncellenir).
    @State private var activeID: String?

    var body: some View {
        let markedIDs: Set<String> = highlightedParagraphIDs(paragraphs: paragraphs, highlights: record.highlights ?? [])
        LazyVStack(alignment: .leading, spacing: 2) {
            if player.errorMeetingID == record.id, let error = player.errorMessage {
                NoticeText(error, severity: .error).appFont(size: 11, weight: .regular)
            }
            ForEach(Array(paragraphs.enumerated()), id: \.element.id) { (item: (offset: Int, element: TranscriptParagraph)) in
                let paragraph: TranscriptParagraph = item.element
                let key: SpeakerKey = SpeakerKey(speaker: paragraph.speaker, person: paragraph.person)
                // Aynı konuşmacı sürüyorsa rozet ve ad tekrar edilmez (sohbet gibi).
                let continues: Bool = item.offset > 0
                    && SpeakerKey(speaker: paragraphs[item.offset - 1].speaker, person: paragraphs[item.offset - 1].person) == key
                let isActive: Bool = activeID == paragraph.id
                HStack(alignment: .top, spacing: 12) {
                    if continues {
                        Color.clear.frame(width: 32, height: 1)
                    } else {
                        SpeakerAvatar(text: avatarText(key: key, speakerNames: record.speakerNames), color: speakerColor(key: key), size: 32)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !continues {
                                Text(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames))
                                    .appFont(size: 13, weight: .semibold)
                            }
                            Text(timestamp(seconds: paragraph.startSec))
                                .appFont(size: 12, weight: .regular)
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                            let marked: Bool = markedIDs.contains(paragraph.id)
                            Button {
                                onToggleHighlight(paragraph)
                            } label: {
                                Image(systemName: marked ? "bookmark.fill" : "bookmark")
                                    .appFont(size: 11, weight: .medium)
                                    .foregroundStyle(marked ? appearance.accent.color : Theme.muted.opacity(0.6))
                            }
                            .buttonStyle(.hoverPlain)
                            .disabled(!canEdit)
                            .hoverHint(marked ? "İşareti kaldır" : "Önemli olarak işaretle (notta öne çıkar)", alignment: .leading, edge: .bottom)
                        }
                        Group {
                            if isActive, !paragraph.words.isEmpty {
                                KaraokeParagraph(words: paragraph.words, player: player, accent: appearance.accent.color)
                            } else {
                                Text(paragraph.text)
                            }
                        }
                        .font(appearance.bodyFont)
                        .lineSpacing(appearance.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        if let turkish = paragraph.turkish {
                            Text(turkish)
                                .font(appearance.secondaryFont)
                                .lineSpacing(appearance.lineSpacing)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
                                .padding(.top, 2)
                        }
                        if paragraph.translationFailed {
                            Button(action: onRetryTranslation) {
                                Label("Çeviri alınamadı · Tekrar dene", systemImage: "arrow.clockwise")
                                    .appFont(size: 12, weight: .medium)
                            }
                            .buttonStyle(.hoverPlain)
                            .foregroundStyle(NoticeSeverity.attention.tint)
                            .disabled(!canEdit)
                            .padding(.top, 2)
                        }
                    }
                    // Çal düğmesi metnin üstüne binmesin.
                    .padding(.trailing, canPlay ? 30 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, continues ? 6 : 12)
                .padding(.horizontal, 10)
                .background(isActive ? Theme.soft : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.easeOut(duration: 0.25), value: isActive)
                .modifier(PlayableTurn(canPlay: canPlay) { onPlay(paragraph.startSec) })
                .contextMenu {
                    Button("Klip olarak kaydet (ses)", systemImage: "waveform") { onClip(paragraph) }
                        .disabled(!canPlay)
                    Button("Metni kopyala", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(paragraph.text, forType: .string)
                    }
                }
                .id(paragraph.id)
            }
        }
        .background {
            PlaybackFollower(player: player, meetingID: record.id, paragraphs: paragraphs) { (id: String?) -> Void in
                activeID = id
                // Çalan paragraf değişince görünür alanın üst üçte birine kaydır (şarkı sözü gibi); alttaki oynatıcı
                // paragrafın sonunu örtmesin.
                if let id, player.isPlaying {
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
                }
            }
        }
    }
}

/// Konuşmacı şeridinde çalma konumunu gösteren çizgi.
private struct Playhead: View {
    let player: MeetingAudioPlayer
    let meetingID: String
    let width: CGFloat
    let totalSec: Double

    var body: some View {
        if player.meetingID == meetingID {
            Capsule()
                .fill(Theme.ink)
                .frame(width: 3, height: 14)
                .shadow(color: .black.opacity(0.35), radius: 2)
                .offset(x: width * min(1, max(0, Double(player.currentSecond) / totalSec)) - 1.5)
        }
    }
}

/// Çalan toplantının oynatıcısı (ana pencerenin ve panelin altında): sayfa değişse de ses sürer ve oynatıcı görünür.
/// Toplantı silinir ya da sesi silinirse (saklama süresi) çalma durur.
struct PlayerDock: View {
    let model: AppModel
    let player: MeetingAudioPlayer
    /// Toplantı başlığına tıklanınca o toplantıyı açar.
    let onOpen: @MainActor (String) -> Void

    var body: some View {
        // Bu gövde yalnızca çalan toplantı değişince yeniden hesaplanır; konum güncellemeleri çubuğun içinde kalır.
        let record: MeetingRecord? = player.meetingID.flatMap { (id: String) -> MeetingRecord? in model.meetings.first { $0.id == id } }
        Group {
            if let record, !record.audioDeleted {
                NowPlayingBar(
                    player: player, paragraphs: transcriptParagraphs(record: record), speakerNames: record.speakerNames,
                    title: record.note?.title ?? record.title, onOpen: { onOpen(record.id) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.3), value: record?.id)
        .onChange(of: player.meetingID.map { (id: String) -> Bool in record?.audioDeleted ?? true }) { (_: Bool?, gone: Bool?) in
            if gone == true {
                player.stop()
            }
        }
    }
}

/// Spotify tarzı çalma çubuğu: toplantı başlığı (tıklayınca açılır), çalan konuşmacı ve sözü, konum çubuğu ve
/// süreler, 10 sn geri / oynat-duraklat / 10 sn ileri, hız ve kapat.
private struct NowPlayingBar: View {
    let player: MeetingAudioPlayer
    let paragraphs: [TranscriptParagraph]
    let speakerNames: [Int: String]
    let title: String
    let onOpen: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        // Saniyede bir yeterli: çubuk, süreler ve çalan konuşmacının sözü (kelime vurgusu transkriptte).
        let time: Double = Double(player.currentSecond)
        let current: TranscriptParagraph? = paragraphs.last { $0.startSec <= time }
        VStack(spacing: 8) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        // Durağan simge (çalarken vurgu renginde, duraklatılınca soluk): sürekli sembol animasyonu her karede
                        // pencereyi yeniden çizdiriyor ve ana iş parçacığı çizim sunucusunu beklerken saniyeler boyunca
                        // bloke oluyordu (ölçüm: zamanın %45'i); süre ve kelime vurgusu takılıyordu.
                        Image(systemName: "waveform")
                            .foregroundStyle(player.isPlaying ? appearance.accent.color : Theme.muted)
                        Text(title)
                            .appFont(size: 12, weight: .semibold)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("Toplantıyı aç", alignment: .leading, edge: .top)
                Spacer(minLength: DesignTokens.Spacing.s)
                Button {
                    player.cycleRate()
                } label: {
                    Text(rateText(rate: player.rate))
                        .appFont(size: 11, weight: .semibold)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.soft, in: Capsule())
                }
                .buttonStyle(.hoverCapsule)
                .hoverHint("Çalma hızı", alignment: .trailing, edge: .top)
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 11, weight: .semibold)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(.secondary)
                .hoverHint("Çalmayı kapat", alignment: .trailing, edge: .top)
            }
            HStack(spacing: DesignTokens.Spacing.s) {
                if let current {
                    Circle()
                        .fill(speakerColor(key: SpeakerKey(speaker: current.speaker, person: current.person)))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(paragraphLabel(paragraph: current, speakerNames: speakerNames))
                            .appFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                        Text(current.turkish ?? current.text)
                            .appFont(size: 12, weight: .regular)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 2) {
                Slider(
                    value: Binding<Double>(get: { Double(player.currentSecond) }, set: { (value: Double) -> Void in player.seek(to: value) }),
                    in: 0...max(player.duration, 0.1)
                )
                .controlSize(.small)
                .tint(appearance.accent.color)
                .accessibilityLabel("Konum")
                HStack {
                    Text(timestamp(seconds: time))
                    Spacer()
                    Text("-" + timestamp(seconds: max(0, player.duration - time)))
                }
                .appFont(size: 10, weight: .regular)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 28) {
                Button {
                    player.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10").appFont(size: 17, weight: .medium)
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("10 sn geri", alignment: .center, edge: .top)
                Button {
                    player.togglePause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .appFont(size: 17, weight: .bold)
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(appearance.accent.color, in: Circle())
                }
                .buttonStyle(.hoverCapsule)
                .accessibilityLabel(player.isPlaying ? "Duraklat" : "Oynat")
                Button {
                    player.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10").appFont(size: 17, weight: .medium)
                }
                .buttonStyle(.hoverPlain)
                .hoverHint("10 sn ileri", alignment: .center, edge: .top)
            }
        }
        .padding(DesignTokens.Spacing.m)
        .cardSurface(cornerRadius: 18)
        .padding(.horizontal, DesignTokens.Spacing.m)
        .padding(.bottom, DesignTokens.Spacing.m)
    }
}

/// "1×", "1,25×" (arayüz diline göre ondalık ayırıcı).
private func rateText(rate: Float) -> String {
    Double(rate).formatted(.number.precision(.fractionLength(0...2)).locale(interfaceLocale())) + "×"
}
