import AINotepadCore
import AINotepadUI
import Foundation
import os
import SwiftUI

/// Sesinden tanıma modelinin (SpeakerKit Pyannote, ~40 MB) bu iPhone'daki durumu.
enum PhoneVoiceModelState: Equatable {
    /// Henüz denetlenmedi ya da denetleniyor.
    case checking
    /// İndirilmedi (ya da yarım kaldı).
    case missing
    /// İndiriliyor; 0…1.
    case downloading(Double)
    case ready
    /// Denetlenemedi ya da indirilemedi; neden gösterilir.
    case failed(String)
}

/// Sesinden tanıma (Mac'teki gibi): adı verilen kişilerin ses izleri (`Voices.json`, hesabın klasöründe) ve ses izi
/// modeli. Ses izi biyometrik veridir: yalnız bu iPhone'da kalır ve sunucuya gitmez; `Voices.json` cihaz yedeğine de girmez
/// (toplantıdaki izler toplantı kaydıyla durur). Model hesaplar arasında ortaktır (`AppPaths.modelsDirectory`), yeniden
/// indirilebildiği için yedeğe girmez.
@MainActor
@Observable
final class PhoneVoices {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneVoices")
    /// Adı verilmiş kişilerin sesleri.
    private(set) var registered: [RegisteredVoice] = []
    /// Kayıtlı sesler okunamadı ya da yazılamadı.
    private(set) var registryError: String?
    private(set) var modelState: PhoneVoiceModelState = .checking
    /// Dosya okundu: okunamadıysa üzerine yazılmaz (boş listeyle eski sesler silinmesin; "Tümünü unut" yine siler).
    @ObservationIgnored private var registryLoaded: Bool = false
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    /// Kayıtlı sesleri okur (hesap yüklenince).
    func load() {
        do {
            let url: URL = try voicesFileURL()
            registered = try loadRegisteredVoices(url: url)
            registryLoaded = true
            registryError = nil
            // Önceki sürümlerde yazılmış dosya da yedeğin dışında kalsın.
            if FileManager.default.fileExists(atPath: url.path) {
                try excludeFromBackup(url: url)
            }
        } catch {
            Self.logger.error("Kayıtlı sesler okunamadı, hata: \(String(describing: error), privacy: .private)")
            registryError = userFacingMessage(error: error)
        }
    }

    /// Sesi unutur: bu kişi bundan sonra sesinden tanınmaz (verilmiş adlar toplantılarda kalır).
    func forget(name: String) {
        store(voices: registered.filter { $0.name != name })
    }

    /// Tüm sesleri unutur: dosya silinir (okunamıyor olsa da).
    func forgetAll() {
        do {
            let url: URL = try voicesFileURL()
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw StorageError.deleteFailed(path: url.path, reason: error.localizedDescription)
                }
            }
            registered = []
            registryLoaded = true
            registryError = nil
        } catch {
            Self.logger.error("Kayıtlı sesler silinemedi, hata: \(String(describing: error), privacy: .private)")
            registryError = userFacingMessage(error: error)
        }
    }

    /// Toplantıda konuşmacılara ad verildi (bkz. `voicesAfterNamingSpeakers`): düzeltilen adın izi eski addan geri alınır,
    /// sesinden tanıma açıksa adı verilen kişinin izi hatırlanır.
    func speakersRenamed(meetingID: String, previousNames: [Int: String], edits: [Int: String], voiceprints: [Int: Voiceprint]?) {
        let learned: [Int: Voiceprint] = phoneVoiceRecognitionEnabled() ? voiceprints ?? [:] : [:]
        let voices: [RegisteredVoice] = voicesAfterNamingSpeakers(
            voices: registered, meetingID: meetingID, previousNames: previousNames, edits: edits, voiceprints: learned, now: Date()
        )
        if voices != registered {
            store(voices: voices)
        }
    }

    /// Toplantı silindi: ondan öğrenilen izler geri alınır (biyometrik veri toplantıdan uzun yaşamasın).
    func meetingDeleted(meetingID: String) {
        let voices: [RegisteredVoice] = forgettingMeeting(voices: registered, meetingID: meetingID, now: Date())
        if voices != registered {
            store(voices: voices)
        }
    }

    /// Kişiler'de elle eklenen kişinin adı değişti: sesi yeni ada taşınır.
    func personRenamed(oldName: String, newName: String) {
        let voices: [RegisteredVoice] = renamingVoice(voices: registered, oldName: oldName, newName: newName)
        if voices != registered {
            store(voices: voices)
        }
    }

    /// Kişi Kişiler'den kaldırıldı: sesi de unutulur.
    func personRemoved(name: String) {
        let voices: [RegisteredVoice] = registered.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        if voices != registered {
            store(voices: voices)
        }
    }

    /// Toplantı işlenirken ses izi servisi; Ayarlar'da kapalıysa ya da model klasörü yoksa nil (işleme izsiz sürer).
    /// Model henüz yoksa işleme sırasında indirilir (Mac'teki gibi).
    func embedderIfEnabled() -> (any VoiceEmbedder)? {
        guard phoneVoiceRecognitionEnabled() else {
            return nil
        }
        do {
            return SpeakerKitVoiceEmbedder(modelsDirectory: try AppPaths.modelsDirectory())
        } catch {
            Self.logger.error("Ses izi için model klasörü alınamadı, hata: \(String(describing: error), privacy: .private)")
            registryError = userFacingMessage(error: error)
            return nil
        }
    }

    /// Modelin bu iPhone'da olup olmadığını denetler (ağ kullanılmaz). İndirme sürüyorsa dokunulmaz.
    func refreshModelState() async {
        guard downloadTask == nil else {
            return
        }
        modelState = .checking
        do {
            let directory: URL = try AppPaths.modelsDirectory()
            modelState = try await voiceModelIsDownloaded(modelsDirectory: directory) ? .ready : .missing
        } catch {
            Self.logger.error("Ses izi modeli denetlenemedi, hata: \(String(describing: error), privacy: .private)")
            modelState = .failed(userFacingMessage(error: error))
        }
    }

    /// Modeli indirir (ilerleme `modelState`'te); zaten iniyorsa yeni indirme başlatılmaz.
    func downloadModel() {
        guard downloadTask == nil else {
            return
        }
        modelState = .downloading(0)
        downloadTask = Task { [weak self] in
            do {
                let directory: URL = try AppPaths.modelsDirectory()
                try await downloadVoiceModel(modelsDirectory: directory) { [weak self] (fraction: Double) -> Void in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.modelState else {
                            return
                        }
                        self.modelState = .downloading(min(max(fraction, 0), 1))
                    }
                }
                try excludeFromBackup(url: directory)
                self?.modelState = .ready
                Self.logger.info("Ses izi modeli indirildi")
            } catch is CancellationError {
                self?.modelState = .missing
            } catch {
                Self.logger.error("Ses izi modeli indirilemedi, hata: \(String(describing: error), privacy: .private)")
                self?.modelState = .failed(userFacingMessage(error: error))
            }
            self?.downloadTask = nil
        }
    }

    /// Sürmekte olan indirmeyi durdurur (sesinden tanıma kapatıldı).
    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func store(voices: [RegisteredVoice]) {
        guard registryLoaded else {
            registryError = String(localized: "Kayıtlı sesler okunamadığı için değişiklik kaydedilmedi; Tümünü unut ile sıfırlayabilirsin.")
            return
        }
        do {
            let url: URL = try voicesFileURL()
            try saveRegisteredVoices(voices: voices, url: url)
            // Atomik yazma dosyayı yeniler: yedek dışı işareti her yazmada yeniden konur.
            try excludeFromBackup(url: url)
            registered = voices
            registryError = nil
        } catch {
            Self.logger.error("Kayıtlı sesler yazılamadı, hata: \(String(describing: error), privacy: .private)")
            registryError = userFacingMessage(error: error)
        }
    }
}

/// Sesinden tanıma açık mı (Ayarlar › Konuşmacılar; Mac'teki ayarla aynı ad, varsayılan kapalı).
func phoneVoiceRecognitionEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: PhoneSettingsKey.voiceRecognition)
}

/// Ayarlar › Sen ve konuşmacılar (Mac'teki aynı adlı grup): önce verilen satırlar (ad, tanıma sözlüğü), sonra sesinden
/// tanıma (açılınca model indirilir, ilerleme ve boyutuyla), modelin durumu ve tanınan seslerin listesi. Liste, ayar
/// kapalıyken de açılır (saklanan sesler her zaman silinebilsin).
struct PhoneVoiceSettingsSection<LeadingRows: View>: View {
    let voices: PhoneVoices
    let leadingRows: LeadingRows
    @AppStorage(PhoneSettingsKey.voiceRecognition) private var isEnabled: Bool = false

    init(voices: PhoneVoices, @ViewBuilder leadingRows: () -> LeadingRows) {
        self.voices = voices
        self.leadingRows = leadingRows()
    }

    var body: some View {
        Section {
            leadingRows
            Toggle(isOn: Binding<Bool>(
                get: { isEnabled },
                set: { (enabled: Bool) -> Void in
                    isEnabled = enabled
                    if enabled {
                        if voices.modelState != .ready {
                            voices.downloadModel()
                        }
                    } else {
                        voices.cancelDownload()
                    }
                }
            )) {
                PhoneSettingLabel(icon: "person.wave.2", title: Text("Konuşmacıları sesinden tanı"))
            }
            if isEnabled {
                modelRow
            }
            if let error = voices.registryError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(NoticeSeverity.attention.tint)
            }
            if !voices.registered.isEmpty || voices.registryError != nil {
                NavigationLink {
                    PhoneRecognizedVoicesScreen(voices: voices)
                } label: {
                    LabeledContent {
                        Text(verbatim: "\(voices.registered.count)")
                    } label: {
                        PhoneSettingLabel(icon: "person.crop.circle.badge.checkmark", title: Text("Tanınan sesler"))
                    }
                }
            }
        } header: {
            Text("Tanıma ve konuşmacılar")
        } footer: {
            Text("Ses izi (biyometrik veri) yalnız bu iPhone'da saklanır; ad verdiğin kişi sonraki toplantılarda sesinden tanınır. Başkalarının ses izini saklamadan önce onaylarını al.")
        }
        .task(id: isEnabled) {
            if isEnabled {
                await voices.refreshModelState()
            }
        }
    }

    @ViewBuilder private var modelRow: some View {
        switch voices.modelState {
        case .checking:
            LabeledContent {
                ProgressView()
            } label: {
                PhoneSettingLabel(icon: voiceModelIcon, title: Text("Ses modeli"))
            }
        case .missing:
            Button {
                voices.downloadModel()
            } label: {
                PhoneSettingLabel(icon: "arrow.down.circle", title: Text("Ses modelini indir (~\(voiceModelDownloadMegabytes) MB)"))
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent {
                    Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
                } label: {
                    PhoneSettingLabel(icon: voiceModelIcon, title: Text("Ses modeli indiriliyor"))
                }
                ProgressView(value: fraction)
                Text("~\(voiceModelDownloadMegabytes) MB; bir kez indirilir, kayıtlar bu iPhone'da işlenir.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        case .ready:
            LabeledContent {
                Text("Hazır · ~\(voiceModelDownloadMegabytes) MB")
            } label: {
                PhoneSettingLabel(icon: voiceModelIcon, title: Text("Ses modeli"))
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(NoticeSeverity.attention.tint)
                Button("Yeniden dene") { voices.downloadModel() }
            }
        }
    }
}

/// Ses izi modelinin satır simgesi (cihazda çalışan model).
private let voiceModelIcon: String = "cpu"

/// Tanınan sesler: her ses kaç dakikalık konuşmadan öğrenildiği ve son güncellenme günüyle; tek tek ya da hepsi
/// unutulur (hepsini unutmak sayfanın içinde iki adımla onaylanır, ayrı uyarı penceresi yok).
private struct PhoneRecognizedVoicesScreen: View {
    let voices: PhoneVoices
    @State private var confirmForgetAll: Bool = false

    var body: some View {
        PhoneGroupedList {
            if let error = voices.registryError {
                Section {
                    PhoneErrorList(messages: [error])
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                if voices.registered.isEmpty {
                    Text("Kayıtlı ses yok.")
                        .foregroundStyle(Theme.muted)
                }
                ForEach(voices.registered, id: \.name) { (voice: RegisteredVoice) in
                    HStack(spacing: 12) {
                        PersonAvatar(name: voice.name, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: voice.name)
                                .appFont(size: 16, weight: .medium)
                            Text("\(max(1, Int((voice.voiceprint.seconds / 60).rounded()))) dk konuşmadan · \(voice.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale())))")
                                .appFont(size: 12, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        Button("Unut", role: .destructive) { voices.forget(name: voice.name) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Unut: \(voice.name)"))
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Unutulan kişi bundan sonra sesinden tanınmaz; toplantılarda verilmiş adı kalır.")
            }
            if !voices.registered.isEmpty || voices.registryError != nil {
                Section {
                    if confirmForgetAll {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tüm sesler unutulsun mu? Toplantılardaki adlar kalır.")
                                .appFont(size: 14, weight: .medium)
                            HStack(spacing: 10) {
                                Button("Tümünü unut", role: .destructive) {
                                    voices.forgetAll()
                                    confirmForgetAll = false
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(NoticeSeverity.error.systemLabelFill)
                                Button("Vazgeç") { confirmForgetAll = false }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button("Tümünü unut", role: .destructive) { confirmForgetAll = true }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: confirmForgetAll)
        .navigationTitle("Tanınan sesler")
        .navigationBarTitleDisplayMode(.inline)
    }
}
