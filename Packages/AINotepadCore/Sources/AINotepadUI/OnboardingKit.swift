import AINotepadCore
import AVFoundation
import Observation
import os
import SwiftUI

// Karşılamanın (Mac ve iPhone) ortak parçaları: ilerleme çubuğu, izin kartı, takvimden sıradaki toplantılar, rehberli
// örnek toplantının oynatıcısı, görüşme sahnesi, koç işareti ve örnek notun önizlemesi. Adımların düzeni platformda
// (Mac `App/SetupPage.swift`, iPhone `iOS/PhoneOnboarding.swift`); adım mantığı `AINotepadCore/OnboardingFlow.swift`.

private let onboardingLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Onboarding")

// MARK: İlerleme

/// Karşılamanın ilerlemesi: her adım ince bir kapsül; geçilenler ve şimdiki vurgu renginde, sıradakiler soluk.
/// Durgundur; adım değişince kısa bir geçiş yapar.
public struct OnboardingProgress: View {
    let index: Int
    let count: Int
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { (step: Int) in
                Capsule()
                    .fill(step <= index ? appearance.accent.color : Theme.line)
                    .frame(width: step == index ? 26 : 14, height: 4)
            }
        }
        .animation(.smooth(duration: 0.3), value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Adım \(index + 1) / \(count)"))
    }
}

// MARK: Kart

/// Karşılamanın kartı: beyaz yüzey, ince çerçeve, çok hafif gölge; içindeki satırlar ince çizgilerle ayrılır.
public struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 18)
    }
}

/// Kart içindeki satırları ayıran ince çizgi (simge sütununun sağından başlar).
public struct OnboardingRowDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .padding(.leading, 66)
    }
}

// MARK: İzinler

/// Bir izin satırı: vurgu renginde simge, başlık ve neden gerektiği; sağda canlı durum ya da eylem — verildiyse "Etkin"
/// ve onay, sorulmadıysa "İzin ver", reddedildiyse "Ayarları aç", durumu görünmeyen izin istendiyse "Denetle".
public struct OnboardingPermissionRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let status: PermissionStatus
    let onRequest: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(
        symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, status: PermissionStatus,
        onRequest: @escaping @MainActor () -> Void, onOpenSettings: @escaping @MainActor () -> Void
    ) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.status = status
        self.onRequest = onRequest
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .animation(.smooth(duration: 0.25), value: status)
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .appFont(size: 12.5, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        switch permissionAction(status: status) {
        case .none:
            if status == .granted {
                // Vurgu rengi yalnız simgede: açık temada turuncu yazı 4.5:1 kontrastı tutturmaz.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(appearance.accent.color)
                    Text("Etkin")
                        .foregroundStyle(Theme.ink)
                }
                .appFont(size: 13, weight: .semibold)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("İzin verildi"))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Denetleniyor"))
            }
        case .request:
            Button("İzin ver", action: onRequest)
                .buttonStyle(.accentPill)
                .controlSize(.small)
        case .openSettings:
            HStack(spacing: 10) {
                if status == .denied {
                    Text("Kapalı")
                        .appFont(size: 12.5, weight: .medium)
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("İstendi")
                        .appFont(size: 12.5, weight: .medium)
                        .foregroundStyle(Theme.muted)
                }
                Button(status == .denied ? "Ayarları aç" : "Denetle", action: onOpenSettings)
                    .buttonStyle(.pill)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: Takvim

/// Takvimden bir sıradaki toplantı: solda gün ve saat, ortada başlık ve katılımcılar.
public struct OnboardingMeetingRow: View {
    let meeting: CalendarMeeting
    let now: Date

    public init(meeting: CalendarMeeting, now: Date) {
        self.meeting = meeting
        self.now = now
    }

    public var body: some View {
        let locale: Locale = interfaceLocale()
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: onboardingDayText(date: meeting.start, now: now, locale: locale))
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                Text(meeting.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
            }
            .frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: meeting.title)
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if !meeting.attendees.isEmpty {
                    Text(verbatim: meeting.attendees.prefix(3).joined(separator: ", ") + (meeting.attendees.count > 3 ? " +\(meeting.attendees.count - 3)" : ""))
                        .appFont(size: 12.5, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if meeting.joinURL != nil {
                Image(systemName: "video.fill")
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel(Text("Çevrim içi görüşme"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Toplantının günü: bugün, yarın ya da kısa hafta günü ve tarih (arayüz dilinde). Saf fonksiyondur.
public func onboardingDayText(date: Date, now: Date, locale: Locale) -> String {
    var calendar: Calendar = Calendar.current
    calendar.locale = locale
    if calendar.isDate(date, inSameDayAs: now) {
        return String(localized: "Bugün")
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
        return String(localized: "Yarın")
    }
    return date.formatted(Date.FormatStyle().weekday(.abbreviated).day().locale(locale))
}

// MARK: Örnek toplantı

/// Uygulama paketindeki örnek toplantı: zamanlı metin ve ses dosyası. Dosya yoksa ya da metin bozuksa hata.
public func loadBundledSampleMeeting(bundle: Bundle) throws -> (script: SampleMeetingScript, audioURL: URL) {
    guard let scriptURL = bundle.url(forResource: "sample-meeting", withExtension: "json") else {
        throw SampleMeetingError.resourceMissing(name: "sample-meeting.json")
    }
    guard let audioURL = bundle.url(forResource: "sample-meeting", withExtension: "m4a") else {
        throw SampleMeetingError.resourceMissing(name: "sample-meeting.m4a")
    }
    let data: Data
    do {
        data = try Data(contentsOf: scriptURL)
    } catch {
        throw SampleMeetingError.invalidScript(reason: error.localizedDescription)
    }
    return (script: try decodeSampleMeetingScript(data: data), audioURL: audioURL)
}

/// Örnek toplantının konuşmacıları (sentetik sesler; bkz. `App/SampleMeeting/CREDITS.md`).
public let sampleMeetingSpeakerNames: [Int: String] = [1: "Maya", 2: "Leo"]

/// Örnek toplantının önceden yazılmış notu (arayüz dilinde; sunucu ya da dil modeli yok): özet, karar, görevler
/// (biri kullanıcıya: "Sen" ya da adı), ana hatlar ve sözlük. Ana hatların zamanı metnin satırlarından gelir.
/// `language`: metinlerin çözüldüğü arayüz dili (notun dili olarak saklanır). Saf fonksiyondur (metinler katalogdan).
public func sampleMeetingNote(script: SampleMeetingScript, userName: String, language: ShareLanguage) -> MeetingNote {
    let trimmedName: String = userName.trimmingCharacters(in: .whitespacesAndNewlines)
    let startOf: (Int) -> Double = { (index: Int) -> Double in
        script.lines.indices.contains(index) ? script.lines[index].startSec : 0
    }
    return MeetingNote(
        title: String(localized: "Paylaşım akışı: yayın planı"),
        summary: String(localized: "Yeni paylaşım akışı salı günü planlandığı gibi yayına çıkıyor. Bağlantı önizlemeleri büyük toplantılarda hâlâ bozuluyor; bu yüzden özellik anahtarının arkasında kapalı kalıyor ve bir hafta sonra açılıyor. Sürüm notunda önizlemelerin yakında geleceği yazacak."),
        decisions: [
            String(localized: "Paylaşım salı günü, bağlantı önizlemeleri kapalı olarak yayına çıkar."),
            String(localized: "Önizlemeler yayından bir hafta sonra açılır."),
        ],
        tasks: [
            NoteTask(
                owner: trimmedName.isEmpty ? String(localized: "Sen") : trimmedName,
                description: String(localized: "Toplantının özetini ekibe gönder"), dueDate: String(localized: "Cuma"), isMine: true
            ),
            NoteTask(
                owner: "Leo", description: String(localized: "Büyük toplantılardaki önizleme hatasını düzelt ve deneme sürümünü gönder"),
                dueDate: String(localized: "Perşembe"), isMine: false
            ),
        ],
        glossary: [
            GlossaryEntry(term: String(localized: "Özellik anahtarı"), meaning: String(localized: "Bitmiş bir özelliği yeni sürüm çıkarmadan açıp kapatan ayar.")),
        ]
    )
    .with(outline: [
        OutlineItem(startSec: startOf(0), title: String(localized: "Yayının durumu"), summary: String(localized: "Akış hazır; önizlemeler büyük toplantılarda bozuluyor.")),
        OutlineItem(startSec: startOf(2), title: String(localized: "Karar"), summary: String(localized: "Salı önizlemeler kapalı yayın; bir hafta sonra açılır.")),
        OutlineItem(startSec: startOf(5), title: String(localized: "Sonraki adımlar"), summary: String(localized: "Leo perşembeye düzeltir; sen cumaya özeti gönderirsin.")),
    ])
    .with(language: language)
}

/// Örnek toplantıda "Ne kaçırdım?": önceden yazılmış özet (notun kararları ve kullanıcının görevi). Saf fonksiyondur.
public func sampleMissedSummary(note: MeetingNote) -> MissedSummary {
    MissedSummary(
        topic: String(localized: "Paylaşım akışının yayını: önizlemeler büyük toplantılarda hâlâ bozuluyor."),
        decisions: note.decisions,
        askedOfYou: note.tasks.filter(\.isMine).map(\.description)
    )
}

/// Örnek toplantının aşaması.
public enum SampleMeetingPhase: Sendable, Equatable {
    /// Henüz başlatılmadı.
    case ready
    case playing
    case paused
    /// Ses bitti (kullanıcı "Bitir"e basmadı).
    case ended
}

/// Örnek toplantının oynatıcısı: sesi çalar, konumu ~20/sn yayınlar (canlı metin `sampleMeetingTranscript` ile bu
/// konumdan üretilir). Ses açılamazsa kurulum hata fırlatır; çalma sistemin "Şimdi Çalınan" alanına bağlanmaz.
@MainActor
@Observable
public final class SampleMeetingPlayer {
    public let script: SampleMeetingScript
    public private(set) var elapsed: Double = 0
    public private(set) var phase: SampleMeetingPhase = .ready
    @ObservationIgnored private let player: AVAudioPlayer
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init(script: SampleMeetingScript, audioURL: URL) throws {
        self.script = script
        do {
            player = try AVAudioPlayer(contentsOf: audioURL)
        } catch {
            onboardingLogger.error("Örnek toplantının sesi açılamadı, dosya: \(audioURL.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            throw StorageError.readFailed(path: audioURL.path, reason: error.localizedDescription)
        }
        player.prepareToPlay()
    }

    /// Baştan ya da kaldığı yerden çalar. Ses başlatılamazsa hata (ör. iPhone'da ses oturumu açılamadı).
    public func play() throws {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            onboardingLogger.error("Örnek toplantı için ses oturumu açılamadı, hata: \(String(describing: error), privacy: .private)")
            throw error
        }
        #endif
        if phase == .ended {
            player.currentTime = 0
            elapsed = 0
        }
        guard player.play() else {
            onboardingLogger.error("Örnek toplantının sesi başlatılamadı, süre: \(self.player.duration, privacy: .public)")
            throw StorageError.readFailed(path: player.url?.path ?? "sample-meeting.m4a", reason: "AVAudioPlayer.play() false döndü")
        }
        phase = .playing
        startTicker()
    }

    /// Ses düzeyi (0...1).
    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    /// Konumu değiştirir (saniye; sesin içinde kalır).
    public func seek(to seconds: Double) {
        player.currentTime = min(max(0, seconds), player.duration)
        elapsed = player.currentTime
    }

    public func pause() {
        player.pause()
        ticker?.cancel()
        elapsed = player.currentTime
        if phase == .playing {
            phase = .paused
        }
    }

    /// Kullanıcı toplantıyı bitirdi ya da adımdan çıktı: ses durur.
    public func stop() {
        player.stop()
        ticker?.cancel()
        ticker = nil
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            onboardingLogger.warning("Örnek toplantının ses oturumu kapatılamadı, hata: \(String(describing: error), privacy: .private)")
        }
        #endif
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                if self.player.isPlaying {
                    self.elapsed = self.player.currentTime
                } else {
                    // Ses sona erdi (oynatıcı konumu başa sarar): metin tümüyle görünür kalır.
                    self.elapsed = self.script.durationSec
                    self.phase = .ended
                    return
                }
            }
        }
    }
}

// MARK: Görüşme sahnesi

/// Örnek toplantının görüşme sahnesi (gerçek bir görüntülü görüşme gibi): durağan pastel film zemin üstünde iki
/// katılımcı kutusu; konuşanın kutusunda beyaz halka ve ses çubukları. Üstte "Örnek toplantı" ve süre. Bulanık katman
/// yeniden çizilmez; çubuklar yalnız konuşan kutuda ve "Hareketi azalt" kapalıyken kıpırdar.
public struct SampleCallStage: View {
    let names: [Int: String]
    let speaking: Int?
    let elapsed: Double
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    public init(names: [Int: String], speaking: Int?, elapsed: Double, isLive: Bool) {
        self.names = names
        self.speaking = speaking
        self.elapsed = elapsed
        self.isLive = isLive
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isLive ? Color(red: 0.86, green: 0.2, blue: 0.2) : Color.black.opacity(0.35))
                        .frame(width: 7, height: 7)
                    Text("Örnek toplantı")
                        .appFont(size: 12, weight: .semibold)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.72), in: Capsule())
                Spacer(minLength: 8)
                Text(verbatim: sampleClockText(seconds: elapsed))
                    .appFont(size: 12, weight: .semibold)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.72), in: Capsule())
                    .accessibilityLabel(Text("Süre \(sampleClockText(seconds: elapsed))"))
            }
            .foregroundStyle(Color.black.opacity(0.78))
            Spacer(minLength: 14)
            HStack(spacing: 14) {
                ForEach(names.keys.sorted(), id: \.self) { (person: Int) in
                    tile(person: person, name: names[person] ?? "")
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .background { FilmGradient(seed: "gistsmith-ornek-toplanti", palette: .ocean) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .accessibilityElement(children: .contain)
    }

    private func tile(person: Int, name: String) -> some View {
        let isSpeaking: Bool = speaking == person
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            shape.fill(.white.opacity(isSpeaking ? 0.34 : 0.22))
            Text(verbatim: name.first.map { String($0) } ?? "?")
                .appFont(size: 30, weight: .medium)
                .foregroundStyle(personColor(person: person))
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Text(verbatim: name)
                    .appFont(size: 12, weight: .semibold)
                if isSpeaking {
                    SpeakingBars(elapsed: reduceMotion ? 0 : elapsed)
                }
            }
            .foregroundStyle(Color.black.opacity(0.78))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.white.opacity(0.78), in: Capsule())
            .padding(10)
        }
        .overlay(shape.strokeBorder(.white.opacity(isSpeaking ? 0.95 : 0), lineWidth: 2))
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: isSpeaking)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isSpeaking ? Text("\(name), konuşuyor") : Text(verbatim: name))
    }
}

/// Konuşanın üç ince ses çubuğu: boyları sesin konumundan (kare kare değil, oynatıcının konumuyla) değişir.
private struct SpeakingBars: View {
    let elapsed: Double

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { (bar: Int) in
                Capsule()
                    .frame(width: 2.5, height: 4 + 7 * abs(sin(elapsed * (5.1 + Double(bar) * 1.7) + Double(bar))))
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

/// "dk:sn" süre metni. Saf fonksiyondur.
public func sampleClockText(seconds: Double) -> String {
    let total: Int = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

// MARK: Koç işareti

/// Kısa yol gösterici balon: koyu zemin, açık yazı, ucu `edge` yönünde küçük bir ok (gösterdiği öğeye bakar).
public struct CoachMark: View {
    let text: LocalizedStringKey
    let symbol: String
    let edge: VerticalEdge

    public init(text: LocalizedStringKey, symbol: String, edge: VerticalEdge) {
        self.text = text
        self.symbol = symbol
        self.edge = edge
    }

    public var body: some View {
        VStack(spacing: 0) {
            if edge == .top {
                arrow.rotationEffect(.degrees(180))
            }
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .appFont(size: 12, weight: .semibold)
                    .accessibilityHidden(true)
                Text(text)
                    .appFont(size: 13, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.primary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
            if edge == .bottom {
                arrow
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var arrow: some View {
        Triangle()
            .fill(Theme.primary)
            .frame(width: 14, height: 7)
            .accessibilityHidden(true)
    }
}

/// Aşağı bakan üçgen (koç işaretinin oku).
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path: Path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: Not önizlemesi

/// Örnek notun önizlemesi (toplantı bitince): başlığın altında kullanıcının denemede yazdığı not, sonra kullanıcının
/// görevi, özet, kararlar, diğer görevler ve ana hatlar. Gerçek notun sırasıyla aynı: önce senin görevlerin.
public struct SampleNotePreview: View {
    let note: MeetingNote
    let myNotes: String
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(note: MeetingNote, myNotes: String) {
        self.note = note
        self.myNotes = myNotes
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: note.title)
                .appFont(size: 22, weight: .regular)
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            // Kullanıcının denemede yazdığı not en üstte: not onu öncelik sayar (koç işaretinin sözü).
            let trimmedNotes: String = myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNotes.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "pencil")
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(appearance.accent.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notundan")
                            .appFont(size: 12, weight: .semibold)
                            .foregroundStyle(Theme.muted)
                        Text(verbatim: trimmedNotes)
                            .appFont(size: 15, weight: .medium)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            let mine: [NoteTask] = note.tasks.filter(\.isMine)
            let others: [NoteTask] = note.tasks.filter { !$0.isMine }
            if !mine.isEmpty {
                section(title: "Senin görevlerin") {
                    ForEach(Array(mine.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                        taskRow(task: item.element, isMine: true)
                    }
                }
            }
            section(title: "Özet") {
                Text(verbatim: note.summary)
                    .appFont(size: 13.5, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            section(title: "Kararlar") {
                ForEach(Array(note.decisions.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .appFont(size: 11, weight: .semibold)
                            .foregroundStyle(Theme.muted)
                            .accessibilityHidden(true)
                        Text(verbatim: item.element)
                            .appFont(size: 13.5, weight: .regular)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !others.isEmpty {
                section(title: "Diğer görevler") {
                    ForEach(Array(others.enumerated()), id: \.offset) { (item: (offset: Int, element: NoteTask)) in
                        taskRow(task: item.element, isMine: false)
                    }
                }
            }
            if let outline = note.outline, !outline.isEmpty {
                section(title: "Akış") {
                    ForEach(Array(outline.enumerated()), id: \.offset) { (item: (offset: Int, element: OutlineItem)) in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: sampleClockText(seconds: item.element.startSec))
                                .appFont(size: 11.5, weight: .medium)
                                .foregroundStyle(Theme.muted)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: item.element.title)
                                    .appFont(size: 13, weight: .semibold)
                                    .foregroundStyle(Theme.ink)
                                Text(verbatim: item.element.summary)
                                    .appFont(size: 12.5, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func taskRow(task: NoteTask, isMine: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isMine ? "circle" : "circle.dashed")
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(isMine ? appearance.accent.color : Theme.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: task.description)
                    .appFont(size: 13.5, weight: isMine ? .medium : .regular)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: [task.owner, task.dueDate].compactMap { $0 }.joined(separator: " · "))
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, isMine ? 8 : 0)
        .padding(.horizontal, isMine ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isMine ? appearance.accent.color.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Toplantı adımında yazılan kendi notunun alanı: boşken soluk yer tutucu (macOS'ta `prompt:` odaksız alanda yazı
/// rengiyle çizildiği için kaplama). Mac ve iPhone aynı.
public struct SampleNotesField: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey

    public init(text: Binding<String>, placeholder: LocalizedStringKey) {
        self._text = text
        self.placeholder = placeholder
    }

    public var body: some View {
        TextField(text: $text, axis: .vertical) {
            Text(verbatim: "")
        }
        .textFieldStyle(.plain)
        .appFont(size: 14, weight: .regular)
        .lineLimit(3...6)
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardSurface(cornerRadius: 14)
        .accessibilityLabel(Text("Notlarım"))
    }
}
