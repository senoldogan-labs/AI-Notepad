// Ekranlar sekmesinin tek görüntü satırı (yalnızca Mac: iPhone ekran görüntüsü almaz).
#if os(macOS)
import AINotepadCore
import AppKit
import SwiftUI

/// Satırın "Notta" işareti: işaretli mi ve şu an değiştirilebilir mi (not yazılırken değil).
public struct ScreenNoteChoice: Equatable, Sendable {
    public let isIncluded: Bool
    public let isEnabled: Bool

    public init(isIncluded: Bool, isEnabled: Bool) {
        self.isIncluded = isIncluded
        self.isEnabled = isEnabled
    }
}

/// Görüntüyü okuyan: görüntü ve en uzun kenarı (piksel); okunamazsa hata atar.
public typealias ScreenSnapshotImageLoader = @MainActor (ScreenSnapshot, Int) async throws -> NSImage

/// Satır bu genişlikten (pt) darsa küçük resim üstte tam genişlikte, aralık ve düğmeler altında tek satırda durur (yan
/// panel); genişse küçük resim solda, ayrıntılar sağda. Yan yana düzende ayrıntı sütunu en az ~300 pt kalır.
public let screenSnapshotRowWideMinWidth: CGFloat = 560

/// Küçük resmin genişliği (yan yana düzen) ve okunduğu boy (piksel).
let screenSnapshotThumbnailWidth: CGFloat = 240

/// Tek görüntü satırı: küçük resim (ya da büyümüş hâli), ekranda kaldığı aralık, eylemler ve konuşulanlar. Dar alanda
/// (`screenSnapshotRowWideMinWidth`) görüntü üstte, aralık tek satırda kalır.
public struct ScreenSnapshotRow: View {
    let item: LinkedScreenSnapshot
    let speakerNames: [Int: String]
    let isExpanded: Bool
    let isLocked: Bool
    let canPlay: Bool
    /// Nil when notes don't use screens (the tick is hidden).
    let noteChoice: ScreenNoteChoice?
    let isConfirmingDelete: Bool
    let thumbnailPixels: Int
    let fullPixels: Int
    let loadImage: ScreenSnapshotImageLoader
    let onToggleNote: @MainActor () -> Void
    let onToggleExpanded: @MainActor () -> Void
    let onPlay: @MainActor (Double) -> Void
    let onAskDelete: @MainActor () -> Void
    let onCancelDelete: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @State private var width: CGFloat = screenSnapshotRowWideMinWidth

    public init(
        item: LinkedScreenSnapshot, speakerNames: [Int: String], isExpanded: Bool, isLocked: Bool, canPlay: Bool, noteChoice: ScreenNoteChoice?,
        isConfirmingDelete: Bool, thumbnailPixels: Int, fullPixels: Int, loadImage: @escaping ScreenSnapshotImageLoader,
        onToggleNote: @escaping @MainActor () -> Void, onToggleExpanded: @escaping @MainActor () -> Void, onPlay: @escaping @MainActor (Double) -> Void,
        onAskDelete: @escaping @MainActor () -> Void, onCancelDelete: @escaping @MainActor () -> Void, onDelete: @escaping @MainActor () -> Void
    ) {
        self.item = item
        self.speakerNames = speakerNames
        self.isExpanded = isExpanded
        self.isLocked = isLocked
        self.canPlay = canPlay
        self.noteChoice = noteChoice
        self.isConfirmingDelete = isConfirmingDelete
        self.thumbnailPixels = thumbnailPixels
        self.fullPixels = fullPixels
        self.loadImage = loadImage
        self.onToggleNote = onToggleNote
        self.onToggleExpanded = onToggleExpanded
        self.onPlay = onPlay
        self.onAskDelete = onAskDelete
        self.onCancelDelete = onCancelDelete
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isExpanded {
                ScreenSnapshotImage(snapshot: item.snapshot, maxPixelSize: fullPixels, isSelected: true, loadImage: loadImage, onTap: onToggleExpanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                details
            } else if width < screenSnapshotRowWideMinWidth {
                ScreenSnapshotImage(snapshot: item.snapshot, maxPixelSize: thumbnailPixels, isSelected: false, loadImage: loadImage, onTap: onToggleExpanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                details
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ScreenSnapshotImage(snapshot: item.snapshot, maxPixelSize: thumbnailPixels, isSelected: false, loadImage: loadImage, onTap: onToggleExpanded)
                        .frame(width: screenSnapshotThumbnailWidth)
                    details
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in proxy.size.width } action: { (newWidth: CGFloat) in
            width = newWidth
        }
    }

    /// Aralık, eylemler ve konuşulanlar. Aralık ve "Notta" hiç kaydırılmaz (tek satır); sığmazsa önce boşluk daralır.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onPlay(item.startSec)
                } label: {
                    Label(rangeText, systemImage: canPlay ? "play.fill" : "clock")
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .foregroundStyle(appearance.accent.color)
                .disabled(!canPlay)
                .hoverHint(canPlay ? "Bu ekrandayken konuşulanları dinle" : "Bu toplantının sesi yok", alignment: .leading, edge: .bottom)
                Spacer(minLength: 8)
                if let noteChoice, !isConfirmingDelete {
                    Toggle("Notta", isOn: Binding<Bool>(get: { noteChoice.isIncluded }, set: { (_: Bool) -> Void in onToggleNote() }))
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                        .fixedSize()
                        .disabled(!noteChoice.isEnabled)
                        .hoverHint(
                            noteChoice.isEnabled
                                ? (noteChoice.isIncluded ? "Not yazılırken bu görüntü gönderilebilir; kaldırınca gönderilmez" : "Bu görüntü nota gönderilmez")
                                : "Not yazılırken değiştirilemez",
                            alignment: .trailing, edge: .bottom
                        )
                }
                if isConfirmingDelete {
                    Text("Silinsin mi?").foregroundStyle(NoticeSeverity.error.tint).lineLimit(1).fixedSize()
                    Button("Sil", role: .destructive) { onDelete() }
                        .fixedSize()
                    Button("Vazgeç") { onCancelDelete() }
                        .fixedSize()
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
                        (Text(verbatim: paragraphLabel(paragraph: paragraph, speakerNames: speakerNames) + "  ").foregroundStyle(Theme.ink).fontWeight(.medium)
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
struct ScreenSnapshotImage: View {
    let snapshot: ScreenSnapshot
    let maxPixelSize: Int
    let isSelected: Bool
    let loadImage: ScreenSnapshotImageLoader
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
                image = try await loadImage(snapshot, maxPixelSize)
                failure = nil
            } catch {
                failure = String(localized: "Görüntü okunamadı: \(userFacingMessage(error: error))")
            }
        }
    }
}
#endif
