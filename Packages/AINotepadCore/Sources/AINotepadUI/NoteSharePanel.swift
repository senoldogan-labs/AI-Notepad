import AINotepadCore
import SwiftUI

/// "Bağlantıyla paylaş" panelinin iş durumu.
public enum NoteSharePanelStatus: Equatable, Sendable {
    case idle
    /// Bağlantı oluşturuluyor, liste yenileniyor ya da bağlantı kaldırılıyor.
    case working
    /// Son işlem başarısız; kullanıcıya gösterilecek metin.
    case failed(String)
}

/// Notu uçtan uca şifreli bağlantıyla paylaşma paneli (Mac'te toplantı sayfasının üstündeki kart, iPhone'da sayfa):
/// süre seçimi, isteğe bağlı transkript, "Bağlantı oluştur", bu toplantının bu cihazdaki bağlantıları (kopyala,
/// kaldır) ve tek satırlık gizlilik açıklaması. Durumu ve işleri çağıran verir; görünüm yalnızca çizer.
public struct NoteSharePanel: View {
    @Binding var expiry: NoteShareExpiry
    @Binding var includeTranscript: Bool
    let hasTranscript: Bool
    let links: [NoteShareLinkEntry]
    let status: NoteSharePanelStatus
    /// Az önce kopyalanan bağlantı ("Kopyalandı" görünür).
    let copiedShareID: String?
    let onCreate: @MainActor () -> Void
    let onCopy: @MainActor (NoteShareLinkEntry) -> Void
    let onRevoke: @MainActor (NoteShareLinkEntry) -> Void
    /// Kartın kapatma düğmesi (Mac); iPhone'da sayfanın kendi "Bitti"si vardır (nil).
    let onClose: (@MainActor () -> Void)?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(
        expiry: Binding<NoteShareExpiry>, includeTranscript: Binding<Bool>, hasTranscript: Bool, links: [NoteShareLinkEntry], status: NoteSharePanelStatus,
        copiedShareID: String?, onCreate: @escaping @MainActor () -> Void, onCopy: @escaping @MainActor (NoteShareLinkEntry) -> Void,
        onRevoke: @escaping @MainActor (NoteShareLinkEntry) -> Void, onClose: (@MainActor () -> Void)?
    ) {
        _expiry = expiry
        _includeTranscript = includeTranscript
        self.hasTranscript = hasTranscript
        self.links = links
        self.status = status
        self.copiedShareID = copiedShareID
        self.onCreate = onCreate
        self.onCopy = onCopy
        self.onRevoke = onRevoke
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label {
                    Text("BAĞLANTIYLA PAYLAŞ").tracking(DesignTokens.labelTracking)
                } icon: {
                    Image(systemName: "link")
                }
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                Spacer(minLength: 8)
                if let onClose {
                    Button("Kapat", systemImage: "xmark", action: onClose)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel("Bağlantıyla paylaşmayı kapat")
                }
            }
            Label {
                Text("Bağlantıya sahip olan herkes notu görebilir; biz göremeyiz.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock")
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    expiryPicker
                    transcriptToggle
                    Spacer(minLength: 8)
                    createButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    expiryPicker
                    transcriptToggle
                    createButton
                }
            }
            switch status {
            case .idle:
                EmptyView()
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Bekle…")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
            case .failed(let message):
                NoticeText(message, severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .textSelection(.enabled)
            }
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(links) { (entry: NoteShareLinkEntry) in
                        linkRow(entry: entry)
                        if entry.id != links.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            }
        }
    }

    private var expiryPicker: some View {
        Picker("Süre", selection: $expiry) {
            ForEach(NoteShareExpiry.allCases) { (choice: NoteShareExpiry) in
                Text("\(choice.rawValue) gün").tag(choice)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .appFont(size: 13, weight: .regular)
    }

    private var transcriptToggle: some View {
        Toggle("Transkripti ekle", isOn: $includeTranscript)
            .appFont(size: 13, weight: .regular)
            .disabled(!hasTranscript)
            .fixedSize()
    }

    private var createButton: some View {
        Button("Bağlantı oluştur", systemImage: "link.badge.plus", action: onCreate)
            .buttonStyle(.pillPrimary)
            .disabled(status == .working)
    }

    private func linkRow(entry: NoteShareLinkEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: shortLink(entry.link))
                    .appFont(size: 13, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.includesTranscript
                    ? String(localized: "\(entry.expiresAt.formatted(date: .abbreviated, time: .omitted)) tarihine kadar · transkriptli")
                    : String(localized: "\(entry.expiresAt.formatted(date: .abbreviated, time: .omitted)) tarihine kadar"))
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Button(copiedShareID == entry.shareID ? "Kopyalandı" : "Kopyala", systemImage: copiedShareID == entry.shareID ? "checkmark" : "doc.on.doc") {
                onCopy(entry)
            }
            .buttonStyle(.pill)
            Button("Bağlantıyı kaldır", systemImage: "trash") { onRevoke(entry) }
                .labelStyle(.iconOnly)
                .buttonStyle(.hoverPlain)
                .foregroundStyle(Theme.muted)
                .disabled(status == .working)
                .help(Text("Bağlantıyı kaldır"))
        }
        .padding(.vertical, 8)
    }

    /// Bağlantının kısa gösterimi: alan adı ve kimliğin başı (anahtar gösterilmez).
    private func shortLink(_ link: URL) -> String {
        let id: String = link.fragment()?.split(separator: ".").first.map(String.init) ?? ""
        return "\(link.host() ?? "")/s#\(id.prefix(8))…"
    }
}
