import AINotepadCore
import AINotepadUI
import os
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Toplantı olarak içe aktarılacak dosyanın kaynağı (kayıt düğmesinin menüsünden ya da kitaplık sayfasından).
enum PhoneImportSource: Hashable {
    /// Dosyalar'dan ses ya da video.
    case files
    /// Fotoğraflar'dan video.
    case photos
    /// Telefon görüşmesinin notunu almanın yolları (iPhone'un arama kaydını paylaşmak, Mac'te konuşmak).
    case phoneCall
    #if CALL_CAPTURE_EXPERIMENT
    /// Deneysel: bu iPhone'daki görüşmeyi kaydet (yalnız `CALL_CAPTURE_EXPERIMENT` derlemesinde).
    case callCapture
    #endif
}

/// İçe aktarmanın arayüz durumu: istenen seçici, seçici ya da Fotoğraflar kopyası hatası ve kopyalama sürüyor mu. Ana
/// ekran ve kitaplık hatayı ve ilerlemeyi gösterir.
@MainActor
@Observable
final class PhoneImportState {
    /// Açılması istenen seçici; açılınca seçici kapanana dek kalır.
    var request: PhoneImportSource?
    var pickError: String?
    /// Fotoğraflar'dan seçilen videolar uygulamaya kopyalanıyor (dönüştürme ondan sonra başlar).
    var isLoadingVideos: Bool = false
    /// Açık sayfa (telefon görüşmesi rehberi) kapanınca açılacak seçici: sayfa kapanırken yeni sunum başlatılmaz.
    var afterSheet: PhoneImportSource?

    init(request: PhoneImportSource?) {
        self.request = request
    }
}

/// Seçicileri, telefon görüşmesi rehberini ve deneysel görüşme kaydı sayfasını kökten sunar: istek ana ekrandaki menüden
/// ya da kapanan kitaplık sayfasından gelir (sunum kökte olunca açık sayfaya bağlı kalmaz). Seçilen ve paylaşım sayfasından
/// gelen dosyalar kaydediciyle içe aktarılır.
struct PhoneImportHost: ViewModifier {
    let recorder: PhoneRecorder
    @Bindable var state: PhoneImportState
    @Environment(PhoneSharedFileInbox.self) private var sharedFiles: PhoneSharedFileInbox
    @State private var pickedVideos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: isRequested(source: .files), allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { (result: Result<[URL], any Error>) in
                switch result {
                case .success(let urls):
                    state.pickError = nil
                    Task { await recorder.importFiles(urls: urls) }
                case .failure(let error):
                    state.pickError = String(localized: "Dosya seçilemedi: \(userFacingMessage(error: error))")
                }
            }
            .photosPicker(isPresented: isRequested(source: .photos), selection: $pickedVideos, matching: .videos, photoLibrary: .shared())
            .sheet(isPresented: isRequested(source: .phoneCall), onDismiss: openAfterSheet) {
                PhoneCallGuideScreen { (source: PhoneImportSource) -> Void in
                    state.afterSheet = source
                    state.request = nil
                }
            }
            #if CALL_CAPTURE_EXPERIMENT
            .sheet(isPresented: isRequested(source: .callCapture)) {
                CallCaptureExperimentScreen(recorder: recorder, isRecording: recorder.phase != .idle)
            }
            #endif
            .onChange(of: pickedVideos) { (_: [PhotosPickerItem], items: [PhotosPickerItem]) in
                guard !items.isEmpty else {
                    return
                }
                pickedVideos = []
                importVideos(items: items)
            }
            // Paylaşım sayfasından gelen dosyalar (açılışta gelen kutusunda kalanlar da) toplantı olarak içe aktarılır; her
            // kopya kendi içe aktarması bitince silinir.
            .onChange(of: sharedFiles.pending, initial: true) { (_: [URL], urls: [URL]) in
                guard !urls.isEmpty else {
                    return
                }
                let taken: [URL] = sharedFiles.takePending()
                Task { await recorder.importSharedFiles(urls: taken) }
            }
            .onChange(of: sharedFiles.rejected, initial: true) { (_: [String], names: [String]) in
                guard !names.isEmpty else {
                    return
                }
                let taken: [String] = sharedFiles.takeRejected()
                state.pickError = String(localized: "Ses ya da video olmayan dosya içe aktarılmadı: \(taken.joined(separator: ", "))")
            }
    }

    /// Rehberde seçilen seçici, rehber kapandıktan sonra açılır.
    private func openAfterSheet() {
        guard let next = state.afterSheet else {
            return
        }
        state.afterSheet = nil
        state.request = next
    }

    /// Seçicinin açık olduğu bağ: istek bu kaynaksa açık; kapanınca istek silinir.
    private func isRequested(source: PhoneImportSource) -> Binding<Bool> {
        Binding<Bool>(
            get: { state.request == source },
            set: { (shown: Bool) -> Void in
                if !shown, state.request == source {
                    state.request = nil
                }
            }
        )
    }

    /// Fotoğraflar'dan seçilen videoları geçici klasöre kopyalar, toplantı olarak içe aktarır ve kopyaları siler.
    /// Kopyalanamayan video atlanır, nedeni ana ekranda ve kitaplıkta görünür.
    private func importVideos(items: [PhotosPickerItem]) {
        state.pickError = nil
        state.isLoadingVideos = true
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
            state.isLoadingVideos = false
            state.pickError = failures.isEmpty ? nil : String(localized: "Video alınamadı: \(failures.joined(separator: "; "))")
            await recorder.importFiles(urls: copies.map(\.url))
            for copy in copies {
                removePickedMovie(movie: copy)
            }
        }
    }
}

/// İçe aktarma menüsünün öğeleri: telefon görüşmesi rehberi, Dosyalar, Fotoğraflar ve (deneysel derlemede) görüşme kaydı.
struct PhoneImportMenuItems: View {
    let onSelect: @MainActor (PhoneImportSource) -> Void

    var body: some View {
        Section {
            Button { onSelect(.phoneCall) } label: {
                Label { Text("Telefon görüşmesi") } icon: { Image(systemName: "phone") }
            }
        }
        Section("Ses ya da video dosyası içe aktar") {
            Button("Dosyalar'dan seç", systemImage: "folder") { onSelect(.files) }
            Button("Fotoğraflar'dan video seç", systemImage: "photo.on.rectangle") { onSelect(.photos) }
        }
        #if CALL_CAPTURE_EXPERIMENT
        Section {
            Button { onSelect(.callCapture) } label: {
                Label { Text("Bu iPhone'daki görüşmeyi kaydet (deneysel)") } icon: { Image(systemName: "phone.badge.waveform") }
            }
        }
        #endif
    }
}

/// İçe aktarma sürüyor: ince satır, dönen gösterge ve kısa açıklama.
struct ImportProgressRow: View {
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
