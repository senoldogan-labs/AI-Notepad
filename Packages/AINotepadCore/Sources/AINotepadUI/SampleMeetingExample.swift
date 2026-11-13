import AINotepadCore
import SwiftUI

/// Giriş yapmadan örnek: giriş kapısından (Mac ve iPhone) açılan, örnek toplantının salt okunur not sayfası. Uygulamayla
/// gelen örnek toplantı (`App/SampleMeeting/`) bellekte okunur: önceden yazılmış not (`sampleMeetingNote`), sesi
/// dinleme ve transkript. Diske ya da hesaba hiçbir şey yazılmaz, sunucuya ya da dil modeline gidilmez, kullanım ve
/// telemetri sayılmaz. En alttaki ana düğme giriş kapısına döner (`onSignIn`); girişten sonra karşılama bugünkü gibi
/// sürer (örnek toplantı orada hesaba saklanır).
public struct SampleMeetingExample: View {
    let onSignIn: @MainActor () -> Void
    @State private var player: SampleMeetingPlayer?
    @State private var note: MeetingNote?
    @State private var problem: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(onSignIn: @escaping @MainActor () -> Void) {
        self.onSignIn = onSignIn
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let problem {
                        NoticeText(problem, severity: .error)
                            .appFont(size: 14, weight: .regular)
                    }
                    if let player, let note {
                        listenRow(player: player)
                        SampleNotePreview(note: note, myNotes: "")
                            .padding(18)
                            .cardSurface(cornerRadius: 20)
                        transcript(player: player)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            Button {
                player?.stop()
                onSignIn()
            } label: {
                Text("Hesap aç ya da giriş yap")
                    .appFont(size: 16, weight: .semibold)
                    .foregroundStyle(Theme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.primary, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(Theme.background)
        .task { load() }
        .onDisappear { player?.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Örnek toplantı")
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                .textCase(.uppercase)
            Text("Bir dakikalık örnek toplantıdan yazılan not. Hiçbir şey kaydedilmez; kendi toplantıların giriş yapınca böyle not olur.")
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sesi dinleme: çal/duraklat ve geçen süre / toplam süre.
    private func listenRow(player: SampleMeetingPlayer) -> some View {
        let isPlaying: Bool = player.phase == .playing
        return HStack(spacing: 12) {
            Button {
                togglePlayback(player: player)
            } label: {
                Label(isPlaying ? "Duraklat" : "Dinle", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(appearance.accent.color.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Text(verbatim: "\(sampleClockText(seconds: player.elapsed)) / \(sampleClockText(seconds: player.script.durationSec))")
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(Theme.muted)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    /// Transkript: konuşmacı adı, zaman ve satır; ses çalarken konuşulan satır vurgulanır.
    private func transcript(player: SampleMeetingPlayer) -> some View {
        let isListening: Bool = player.phase == .playing || player.phase == .paused
        return VStack(alignment: .leading, spacing: 12) {
            Text("Transkript")
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(player.script.lines.enumerated()), id: \.offset) { (item: (offset: Int, element: SampleMeetingLine)) in
                let line: SampleMeetingLine = item.element
                let isCurrent: Bool = isListening && player.elapsed >= line.startSec && player.elapsed < line.endSec
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: sampleMeetingSpeakerNames[line.person] ?? "\(line.person)")
                            .appFont(size: 12.5, weight: .semibold)
                            .foregroundStyle(Theme.ink)
                        Text(verbatim: sampleClockText(seconds: line.startSec))
                            .appFont(size: 11.5, weight: .medium)
                            .foregroundStyle(Theme.muted)
                            .monospacedDigit()
                    }
                    Text(verbatim: line.text)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isCurrent ? appearance.accent.color.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Örnek toplantıyı uygulama paketinden belleğe okur; not arayüz dilinde, kullanıcı adı yok ("Sen").
    private func load() {
        guard player == nil else {
            return
        }
        do {
            let bundled: (script: SampleMeetingScript, audioURL: URL) = try loadBundledSampleMeeting(bundle: .main)
            player = try SampleMeetingPlayer(script: bundled.script, audioURL: bundled.audioURL)
            note = sampleMeetingNote(
                script: bundled.script, userName: "", language: defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations)
            )
        } catch {
            problem = String(localized: "Örnek toplantı açılamadı: \(userFacingMessage(error: error))")
        }
    }

    private func togglePlayback(player: SampleMeetingPlayer) {
        if player.phase == .playing {
            player.pause()
            return
        }
        do {
            try player.play()
        } catch {
            problem = String(localized: "Örnek toplantı açılamadı: \(userFacingMessage(error: error))")
        }
    }
}
