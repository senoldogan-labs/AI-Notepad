import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

// MARK: Ayar

/// Ayarlar › Genel: "Paylaşılan ekranın görüntülerini al" (varsayılan kapalı). Açılınca Ekran Kaydı izni istenir; izin
/// yoksa nedeni ve Sistem Ayarları düğmesi satırın içinde görünür (ayrı pencere yok).
struct ScreenSnapshotSettingsRow: View {
    @AppStorage(SettingsKey.screenSnapshots) private var enabled: Bool = false
    @State private var hasPermission: Bool = hasScreenCapturePermission()

    var body: some View {
        SettingsRow(title: Text("Paylaşılan ekranın görüntülerini al")) {
            #if HOSTED_EDITION
            Text("Çevrimiçi görüşme kaydında ekrana birkaç saniyede bir bakılır; içerik anlamlı değişince (slayt, tasarım, sayfa) bir görüntü saklanır ve o sırada konuşulanlarla eşlenir. Görüşme penceresi (Zoom, Meet, Teams…) bulunursa yalnızca o, yoksa ana ekran alınır; bu uygulamanın pencereleri hiç alınmaz. Görüntüler bu Mac'te toplantının klasöründe kalır ve yapay zekâya gönderilmez; yalnızca bağladığın MCP istemcisi (ör. Claude, Cursor) okuyabilir. Toplantı silinince görüntüleri de silinir.")
            #else
            Text("Çevrimiçi görüşme kaydında ekrana birkaç saniyede bir bakılır; içerik anlamlı değişince (slayt, tasarım, sayfa) bir görüntü saklanır ve o sırada konuşulanlarla eşlenir. Görüşme penceresi (Zoom, Meet, Teams…) bulunursa yalnızca o, yoksa ana ekran alınır; bu uygulamanın pencereleri hiç alınmaz. Görüntüler toplantının klasöründe kalır (iCloud eşitlemesi açıksa toplantıyla eşitlenir) ve yapay zekâya gönderilmez; yalnızca bağladığın MCP istemcisi (ör. Claude, Cursor) okuyabilir. Toplantı silinince görüntüleri de silinir.")
            #endif
            if enabled, !hasPermission {
                VStack(alignment: .leading, spacing: 6) {
                    NoticeText("Ekran Kaydı izni gerekli. İzin verdikten sonra uygulamayı yeniden aç.", severity: .attention)
                    Button("Sistem Ayarları'nı aç") { openPrivacySettings(anchor: "Privacy_ScreenCapture") }
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
        } control: {
            Toggle("Paylaşılan ekranın görüntülerini al", isOn: Binding<Bool>(
                get: { enabled },
                set: { (isOn: Bool) -> Void in
                    enabled = isOn
                    // İlk açılışta macOS kendi izin penceresini açar; reddedilmişse satırdaki düğme Sistem Ayarları'na götürür.
                    hasPermission = isOn && !hasScreenCapturePermission() ? requestScreenCapturePermission() : hasScreenCapturePermission()
                }
            ))
            .settingsToggle()
        }
        .onAppear { hasPermission = hasScreenCapturePermission() }
        #if DEBUG
        .background(DemoScrollIntoView())
        #endif
    }
}

#if HOSTED_EDITION
/// Settings › General: "Notlarda ekran görüntülerini kullan" (off by default, separate from taking snapshots). The text
/// says what leaves the Mac and to whom; the per-meeting choice is on the meeting's Screens tab.
struct ScreenNotesSettingsRow: View {
    @AppStorage(SettingsKey.screenNotes) private var enabled: Bool = false
    @AppStorage(SettingsKey.screenSnapshots) private var takesSnapshots: Bool = false

    var body: some View {
        SettingsRow(title: Text("Notlarda ekran görüntülerini kullan")) {
            Text("Not yazılırken toplantının en çok konuşulan en fazla 6 ekran görüntüsü küçültülüp notla birlikte sunucumuza, oradan da Anthropic'e (Claude) gönderilir; not ekrana atıf yapabilir (ör. \"Fiyatlandırma slaytında, 12:40\"). Sunucumuz görüntüleri saklamaz ve loglamaz; Anthropic onları transkriptle aynı koşullarla işler. Bir görüntüyü toplantının Ekranlar sekmesinden nottan çıkarabilirsin. Kapalıyken görüntüler bu Mac'ten çıkmaz.")
            if enabled, !takesSnapshots {
                NoticeText("Görüntü alınması için \"Paylaşılan ekranın görüntülerini al\" da açık olmalı.", severity: .attention)
                    .padding(.top, 4)
            }
        } control: {
            Toggle("Notlarda ekran görüntülerini kullan", isOn: $enabled)
                .settingsToggle()
        }
    }
}
#endif

// MARK: Toplantı sayfası

/// Silme onayı beklenen öğe (satır içi; ayrı uyarı penceresi yok).
private enum ScreenDeleteConfirmation: Equatable {
    case none
    case one(String)
    case all
}

/// Toplantı sayfasının "Ekranlar" sekmesi: kayıt sırasında saklanan ekran görüntüleri zaman sırasıyla; her birinin
/// yanında ekrandayken konuşulanlar. Görüntüye tıklayınca satırda büyür; zamana tıklayınca ses oradan çalar. Görüntüler
/// tek tek ya da hepsi birden silinebilir.
struct ScreenSnapshotsSection: View {
    let model: AppModel
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    /// Kayıtta ya da işlemede: silme kapalı.
    let isLocked: Bool
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @State private var expandedID: String?
    @State private var confirmation: ScreenDeleteConfirmation = .none
    #if HOSTED_EDITION
    @AppStorage(SettingsKey.screenNotes) private var usesScreensInNotes: Bool = false
    #endif

    /// Whether the rows show the "use in note" tick (Gistsmith with the setting on).
    private var showsNoteChoice: Bool {
        #if HOSTED_EDITION
        usesScreensInNotes
        #else
        false
        #endif
    }

    var body: some View {
        let snapshots: [ScreenSnapshot] = model.screenSnapshots.snapshots[record.id] ?? []
        let linked: [LinkedScreenSnapshot] = linkScreenSnapshots(snapshots: snapshots, paragraphs: paragraphs, leadSec: screenSnapshotPolicy.captureIntervalSec)
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            if let error = model.screenSnapshots.errors[record.id] {
                NoticeText(error, severity: .error).appFont(size: 12, weight: .regular)
            }
            if linked.isEmpty {
                QuietEmptyCard(
                    symbol: "rectangle.on.rectangle", title: "Bu toplantıda ekran görüntüsü yok",
                    message: "Ayarlar › Genel'de \"Paylaşılan ekranın görüntülerini al\" açıkken, çevrimiçi görüşmede ekran değişince görüntüsü burada konuşulanlarla birlikte görünür."
                )
            } else {
                header(count: linked.count)
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                    ForEach(linked) { (item: LinkedScreenSnapshot) in
                        ScreenSnapshotRow(
                            model: model, record: record, item: item, isExpanded: expandedID == item.id, isLocked: isLocked, canPlay: canPlay,
                            noteChoice: showsNoteChoice
                                ? ScreenNoteChoice(
                                    isIncluded: !(model.screenSnapshots.noteExclusions[record.id] ?? []).contains(item.id),
                                    isEnabled: !model.processingMeetingIDs.contains(record.id)
                                )
                                : nil,
                            onToggleNote: { model.toggleScreenNoteExclusion(meetingID: record.id, snapshot: item.snapshot) },
                            isConfirmingDelete: confirmation == .one(item.id),
                            onToggleExpanded: { expandedID = expandedID == item.id ? nil : item.id },
                            onPlay: onPlay,
                            onAskDelete: { confirmation = .one(item.id) },
                            onCancelDelete: { confirmation = .none },
                            onDelete: {
                                model.deleteScreenSnapshot(meetingID: record.id, snapshot: item.snapshot)
                                confirmation = .none
                            }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .animation(.smooth(duration: 0.25), value: expandedID)
        .animation(.smooth(duration: 0.2), value: confirmation)
    }

    /// Sayı, açıklama ve "Hepsini sil" (satır içi onaylı).
    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Text("\(count) ekran görüntüsü")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                if confirmation == .all {
                    Label("Bu toplantının bütün ekran görüntüleri kalıcı silinsin mi?", systemImage: "trash")
                        .foregroundStyle(NoticeSeverity.error.tint)
                    Button("Hepsini sil", role: .destructive) {
                        expandedID = nil
                        model.deleteAllScreenSnapshots(meetingID: record.id)
                        confirmation = .none
                    }
                    Button("Vazgeç") { confirmation = .none }
                } else {
                    Button("Hepsini sil", systemImage: "trash") { confirmation = .all }
                        .disabled(isLocked)
                        .hoverHint(isLocked ? "Kayıt ve işleme bitince silinebilir" : "Ekran görüntülerini kalıcı siler; metin, not ve ses kalır", alignment: .trailing, edge: .bottom)
                }
            }
            .appFont(size: 12, weight: .regular)
            .controlSize(.small)
            Text("Her görüntü ekran değiştiğinde saklandı; yanında o ekrandayken konuşulanlar var. Bağladığın MCP istemcisi (ör. Claude) aynı eşleşmeyi list_screens ve get_screen ile okur.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if showsNoteChoice {
                Text("Not yazılırken \"Notta\" işaretli görüntülerden en çok konuşulan en fazla 6'sı sunucumuza ve Anthropic'e gönderilir; işaretini kaldırdığın görüntü gönderilmez. Seçim bir sonraki notta geçerli olur.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The row's "use in note" tick: whether it is ticked and whether it can change now (not while the note is written).
private struct ScreenNoteChoice: Equatable {
    let isIncluded: Bool
    let isEnabled: Bool
}

/// Tek görüntü satırı: küçük resim (ya da büyümüş hâli), ekranda kaldığı aralık ve konuşulanlar.
private struct ScreenSnapshotRow: View {
    let model: AppModel
    let record: MeetingRecord
    let item: LinkedScreenSnapshot
    let isExpanded: Bool
    let isLocked: Bool
    let canPlay: Bool
    /// Nil when notes don't use screens (the tick is hidden).
    let noteChoice: ScreenNoteChoice?
    let onToggleNote: @MainActor () -> Void
    let isConfirmingDelete: Bool
    let onToggleExpanded: @MainActor () -> Void
    let onPlay: @MainActor (Double) -> Void
    let onAskDelete: @MainActor () -> Void
    let onCancelDelete: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isExpanded {
                ScreenSnapshotImage(model: model, meetingID: record.id, snapshot: item.snapshot, maxPixelSize: screenSnapshotPolicy.maxPixelSize, isSelected: true, onTap: onToggleExpanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                details
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ScreenSnapshotImage(model: model, meetingID: record.id, snapshot: item.snapshot, maxPixelSize: screenThumbnailPixels, isSelected: false, onTap: onToggleExpanded)
                        .frame(width: 240)
                    details
                }
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }

    /// Aralık, eylemler ve konuşulanlar.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onPlay(item.startSec)
                } label: {
                    Label(rangeText, systemImage: canPlay ? "play.fill" : "clock")
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(appearance.accent.color)
                .disabled(!canPlay)
                .hoverHint(canPlay ? "Bu ekrandayken konuşulanları dinle" : "Bu toplantının sesi yok", alignment: .leading, edge: .bottom)
                Spacer(minLength: 8)
                if let noteChoice, !isConfirmingDelete {
                    Toggle("Notta", isOn: Binding<Bool>(get: { noteChoice.isIncluded }, set: { (_: Bool) -> Void in onToggleNote() }))
                        .toggleStyle(.checkbox)
                        .disabled(!noteChoice.isEnabled)
                        .hoverHint(
                            noteChoice.isEnabled
                                ? (noteChoice.isIncluded ? "Not yazılırken bu görüntü gönderilebilir; kaldırınca gönderilmez" : "Bu görüntü nota gönderilmez")
                                : "Not yazılırken değiştirilemez",
                            alignment: .trailing, edge: .bottom
                        )
                }
                if isConfirmingDelete {
                    Text("Silinsin mi?").foregroundStyle(NoticeSeverity.error.tint)
                    Button("Sil", role: .destructive) { onDelete() }
                    Button("Vazgeç") { onCancelDelete() }
                } else {
                    Button(isExpanded ? "Küçült" : "Büyüt", systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") { onToggleExpanded() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .hoverHint(isExpanded ? "Küçült" : "Büyüt", alignment: .trailing, edge: .bottom)
                    Button("Görüntüyü sil", systemImage: "trash") { onAskDelete() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .disabled(isLocked)
                        .hoverHint(isLocked ? "Kayıt ve işleme bitince silinebilir" : "Bu görüntüyü kalıcı siler", alignment: .trailing, edge: .bottom)
                }
            }
            .appFont(size: 12, weight: .medium)
            .controlSize(.small)
            if item.paragraphs.isEmpty {
                Text("Bu ekrandayken konuşma yok.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            } else {
                let shown: [TranscriptParagraph] = isExpanded ? item.paragraphs : Array(item.paragraphs.prefix(3))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(shown) { (paragraph: TranscriptParagraph) in
                        (Text(verbatim: paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames) + "  ").foregroundStyle(Theme.ink).fontWeight(.medium)
                            + Text(verbatim: paragraph.text).foregroundStyle(Theme.ink))
                            .appFont(size: 13, weight: .regular)
                            .lineLimit(isExpanded ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if shown.count < item.paragraphs.count {
                        Text("+\(item.paragraphs.count - shown.count) paragraf daha")
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "01:03 – 02:10" (son görüntüde yalnızca başı).
    private var rangeText: String {
        guard let end = item.endSec else {
            return timestamp(seconds: item.startSec)
        }
        return "\(timestamp(seconds: item.startSec)) – \(timestamp(seconds: end))"
    }
}

/// Görüntü: arka planda okunur; okunurken yer tutucu, okunamazsa nedeni. Tıklayınca büyür ya da küçülür.
private struct ScreenSnapshotImage: View {
    let model: AppModel
    let meetingID: String
    let snapshot: ScreenSnapshot
    let maxPixelSize: Int
    let isSelected: Bool
    let onTap: @MainActor () -> Void
    @State private var image: NSImage?
    @State private var failure: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Button {
            onTap()
        } label: {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Theme.soft
                        if let failure {
                            NoticeText(failure, severity: .error)
                                .appFont(size: 11, weight: .regular)
                                .padding(8)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .aspectRatio(16 / 10, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? appearance.accent.color.opacity(0.6) : Theme.line, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Ekran görüntüsü, \(timestamp(seconds: snapshot.offsetSec))"))
        .task(id: "\(snapshot.id)-\(maxPixelSize)") {
            do {
                image = try await model.screenSnapshotImage(meetingID: meetingID, snapshot: snapshot, maxPixelSize: maxPixelSize)
                failure = nil
            } catch {
                failure = String(localized: "Görüntü okunamadı: \(userFacingMessage(error: error))")
            }
        }
    }
}
