import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

// MARK: Ayar

/// Ayarlar › Genel: "Paylaşılan ekranın görüntülerini al" (varsayılan kapalı). Açılınca Ekran Kaydı izni istenir; izin
/// yoksa nedeni ve Sistem Ayarları düğmesi satırın içinde görünür (ayrı pencere yok).
struct ScreenSnapshotSettingsRow: View {
    @AppStorage(SettingsKey.screenSnapshots) private var enabled: Bool = false
    #if HOSTED_EDITION
    /// "Notlarda ekran görüntülerini kullan" açıksa görüntülerin birkaçı nota ve Sor'a gider; metin bunu söyler.
    @AppStorage(SettingsKey.screenNotes) private var usesScreensInNotes: Bool = false
    #endif
    @State private var hasPermission: Bool = hasScreenCapturePermission()

    var body: some View {
        SettingsRow(icon: "rectangle.dashed.badge.record", title: Text("Paylaşılan ekranın görüntülerini al")) {
            #if HOSTED_EDITION
            if usesScreensInNotes {
                SettingsMoreText(
                    summary: Text("Ekran anlamlı değişince bir görüntü saklanır; birkaçı nota ve Sor'a gider."),
                    details: Text("Çevrimiçi görüşme kaydında ekrana birkaç saniyede bir bakılır; içerik anlamlı değişince (slayt, tasarım, sayfa) bir görüntü saklanır ve o sırada konuşulanlarla eşlenir. Görüşme penceresi (Zoom, Meet, Teams…) bulunursa yalnızca o, yoksa ana ekran alınır; bu uygulamanın pencereleri hiç alınmaz. Görüntüler bu Mac'te toplantının klasöründe saklanır. \"Notlarda ekran görüntülerini kullan\" açık olduğu için not yazılırken ve Sor'da birkaçı küçültülüp sunucumuza, oradan da Anthropic'e (Claude) gönderilir; bağladığın MCP istemcisi (ör. Claude, Cursor) de okuyabilir. Toplantı silinince görüntüleri de silinir.")
                )
            } else {
                SettingsMoreText(
                    summary: Text("Ekran anlamlı değişince bir görüntü saklanır; yapay zekâya gönderilmez."),
                    details: Text("Çevrimiçi görüşme kaydında ekrana birkaç saniyede bir bakılır; içerik anlamlı değişince (slayt, tasarım, sayfa) bir görüntü saklanır ve o sırada konuşulanlarla eşlenir. Görüşme penceresi (Zoom, Meet, Teams…) bulunursa yalnızca o, yoksa ana ekran alınır; bu uygulamanın pencereleri hiç alınmaz. Görüntüler bu Mac'te toplantının klasöründe kalır ve yapay zekâya gönderilmez; yalnızca bağladığın MCP istemcisi (ör. Claude, Cursor) okuyabilir. Toplantı silinince görüntüleri de silinir.")
                )
            }
            #else
            SettingsMoreText(
                summary: Text("Ekran anlamlı değişince bir görüntü saklanır; yapay zekâya gönderilmez."),
                details: Text("Çevrimiçi görüşme kaydında ekrana birkaç saniyede bir bakılır; içerik anlamlı değişince (slayt, tasarım, sayfa) bir görüntü saklanır ve o sırada konuşulanlarla eşlenir. Görüşme penceresi (Zoom, Meet, Teams…) bulunursa yalnızca o, yoksa ana ekran alınır; bu uygulamanın pencereleri hiç alınmaz. Görüntüler toplantının klasöründe kalır (iCloud eşitlemesi açıksa toplantıyla eşitlenir) ve yapay zekâya gönderilmez; yalnızca bağladığın MCP istemcisi (ör. Claude, Cursor) okuyabilir. Toplantı silinince görüntüleri de silinir.")
            )
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
        SettingsRow(icon: "photo.on.rectangle", title: Text("Notlarda ekran görüntülerini kullan")) {
            SettingsMoreText(
                summary: Text("Notta ve Sor'da birkaç ekran görüntüsü Anthropic'e (Claude) gönderilir."),
                details: Text("Not yazılırken toplantının en çok konuşulan en fazla 6 ekran görüntüsü küçültülüp notla birlikte sunucumuza, oradan da Anthropic'e (Claude) gönderilir; not ekrana atıf yapabilir (ör. \"Fiyatlandırma slaytında, 12:40\"). Sor'da da okunan transkript parçaları konuşulurken ekranda olan en fazla 3 görüntü soruyla aynı yoldan gider; cevabın altında kaç görüntü okunduğu yazar. Sunucumuz görüntüleri saklamaz ve loglamaz; Anthropic onları transkriptle aynı koşullarla işler. Bir görüntüyü toplantının Ekranlar sekmesinden nottan çıkarabilirsin (Sor'a da gitmez). Kapalıyken görüntüler bu Mac'ten çıkmaz.")
            )
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
                            item: item, speakerNames: record.speakerNames, isExpanded: expandedID == item.id, isLocked: isLocked, canPlay: canPlay,
                            noteChoice: showsNoteChoice
                                ? ScreenNoteChoice(
                                    isIncluded: !(model.screenSnapshots.noteExclusions[record.id] ?? []).contains(item.id),
                                    isEnabled: !model.processingMeetingIDs.contains(record.id)
                                )
                                : nil,
                            isConfirmingDelete: confirmation == .one(item.id), thumbnailPixels: screenThumbnailPixels,
                            fullPixels: screenSnapshotPolicy.maxPixelSize,
                            loadImage: { (snapshot: ScreenSnapshot, maxPixelSize: Int) async throws -> NSImage in
                                try await model.screenSnapshotImage(meetingID: record.id, snapshot: snapshot, maxPixelSize: maxPixelSize)
                            },
                            onToggleNote: { model.toggleScreenNoteExclusion(meetingID: record.id, snapshot: item.snapshot) },
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
                Text("Not yazılırken \"Notta\" işaretli görüntülerden en çok konuşulan en fazla 6'sı sunucumuza ve Anthropic'e gönderilir; Sor da okuduğu parçalar konuşulurken ekranda olan en fazla 3'ünü gönderir. İşaretini kaldırdığın görüntü ikisine de gönderilmez. Seçim bir sonraki notta ve soruda geçerli olur.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

