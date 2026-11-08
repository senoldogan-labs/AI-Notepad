import AINotepadCore
import AINotepadUI
import Observation
import os
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

// Toplantıya fotoğraf: tahta, slayt ya da kâğıttaki kroki, kayıt sırasında ya da sonra. Kamera belge tarayıcıdır
// (VisionKit: kenarları bulur, perspektifi düzeltir, birden çok sayfa); Fotoğraflar'dan da seçilir. Fotoğraf
// toplantının `Screens/` klasörüne Mac'teki ekran görüntüleriyle aynı biçimde yazılır (bkz. MeetingPhotos.swift):
// "Notta fotoğrafları kullan" açıkken not ve Sor onu okur; toplantı sayfasının Ekranlar sekmesinde görünür. Konum gibi
// üst veri yazılmadan atılır; fotoğraflar bu iPhone'da kalır (eşitlenmez).

private let meetingPhotosLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MeetingPhotos")

extension PhoneSettingsKey {
    /// "Notta fotoğrafları kullan" (varsayılan kapalı): Mac'teki "Notlarda ekran görüntülerini kullan" ile aynı anahtar.
    static let screenNotes: String = "screenNotes.enabled"
}

/// Not yazılırken fotoğraflar gider mi (ayar açıksa).
func phoneScreenNotesPlan() -> ScreenNotesPlan {
    UserDefaults.standard.bool(forKey: PhoneSettingsKey.screenNotes) ? .on : .off
}

/// Sor'da fotoğraflar gider mi: ayar açıksa her toplantının klasörü verilir; `askScreenImages` yalnız okunan parçalar
/// konuşulurken çekilenleri açar.
@MainActor
func phoneAskScreensPlan(store: PhoneStore, records: [MeetingRecord]) throws -> ArchiveScreensPlan {
    switch phoneScreenNotesPlan() {
    case .off:
        return .off
    case .on:
        var directories: [String: URL] = [:]
        for record in records {
            directories[record.id] = try store.sessionDirectory(id: record.id)
        }
        return .on(meetingDirectories: directories)
    }
}

/// Kayıt sırasında çekilen fotoğrafın yeri: toplantı, klasörü ve kaydedilen sesin zaman çizgisindeki an.
struct LivePhotoTarget: Equatable {
    let meetingID: String
    let directory: URL
    let offsetSec: Double
}

/// Fotoğrafları sırayla toplantının klasörüne ekler (arka planda); eklenenler ve ilk hatanın metni.
func addPhotos(meetingID: String, directory: URL, offsetSec: Double, images: [Data]) async -> (added: [ScreenSnapshot], error: String?) {
    var added: [ScreenSnapshot] = []
    for data in images {
        let result: Result<ScreenSnapshot, any Error> = await runBlocking(qos: .userInitiated) { () -> Result<ScreenSnapshot, any Error> in
            Result { try addMeetingPhoto(meetingDirectory: directory, offsetSec: offsetSec, imageData: data) }
        }
        switch result {
        case .success(let snapshot):
            added.append(snapshot)
        case .failure(let error):
            meetingPhotosLogger.error("Fotoğraf eklenemedi, toplantı: \(meetingID, privacy: .public), bayt: \(data.count, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            return (added: added, error: meetingPhotoErrorMessage(error: error))
        }
    }
    return (added: added, error: nil)
}

// MARK: Çekme ve seçme

/// Açılacak fotoğraf kaynağı.
enum PhotoCaptureSource: Identifiable {
    /// Belge tarayıcı (kamera; kenar bulma ve perspektif düzeltme).
    case scanner
    /// Fotoğraflar'dan seçme.
    case library

    var id: Self { self }
}

/// "Fotoğraf ekle" menüsünün maddeleri: tara (kamera varsa) ve Fotoğraflar'dan seç.
struct PhotoCaptureMenuItems: View {
    @Binding var source: PhotoCaptureSource?

    var body: some View {
        Button("Tahtayı ya da slaytı tara", systemImage: "doc.viewfinder") { source = .scanner }
            // Simülatörde ve kamerasız aygıtta tarayıcı yok.
            .disabled(!VNDocumentCameraViewController.isSupported)
        Button("Fotoğraflar'dan seç", systemImage: "photo.on.rectangle") { source = .library }
    }
}

/// Seçilen kaynağı açar ve görüntülerin verisini (JPEG/HEIC) verir; okunamayan seçimin nedeni `onError`'a gider.
struct PhotoCaptureModifier: ViewModifier {
    @Binding var source: PhotoCaptureSource?
    let onImages: @MainActor ([Data]) -> Void
    let onError: @MainActor (String) -> Void
    @State private var pickerItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: Binding<Bool>(get: { source == .scanner }, set: { if !$0 { source = nil } })) {
                PhoneDocumentScanner { (pages: [Data]) -> Void in
                    source = nil
                    onImages(pages)
                } onFailure: { (message: String) -> Void in
                    source = nil
                    onError(message)
                }
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: Binding<Bool>(get: { source == .library }, set: { if !$0 { source = nil } }),
                selection: $pickerItems, maxSelectionCount: 10, matching: .images
            )
            .onChange(of: pickerItems) { (_: [PhotosPickerItem], items: [PhotosPickerItem]) in
                guard !items.isEmpty else {
                    return
                }
                pickerItems = []
                Task { await load(items: items) }
            }
    }

    private func load(items: [PhotosPickerItem]) async {
        var images: [Data] = []
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    onError(String(localized: "Fotoğraf okunamadı; başka bir görüntü dene."))
                    continue
                }
                images.append(data)
            } catch {
                meetingPhotosLogger.error("Seçilen fotoğraf okunamadı, hata: \(String(describing: error), privacy: .public)")
                onError(meetingPhotoErrorMessage(error: error))
            }
        }
        if !images.isEmpty {
            onImages(images)
        }
    }
}

extension View {
    /// Fotoğraf çekme ve seçme sayfaları (`PhotoCaptureModifier`).
    func photoCapture(source: Binding<PhotoCaptureSource?>, onImages: @escaping @MainActor ([Data]) -> Void, onError: @escaping @MainActor (String) -> Void) -> some View {
        modifier(PhotoCaptureModifier(source: source, onImages: onImages, onError: onError))
    }
}

/// VisionKit belge tarayıcısı: taranan her sayfa JPEG olarak döner (perspektifi düzeltilmiş).
struct PhoneDocumentScanner: UIViewControllerRepresentable {
    let onFinish: @MainActor ([Data]) -> Void
    let onFailure: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller: VNDocumentCameraViewController = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        private let onFinish: @MainActor ([Data]) -> Void
        private let onFailure: @MainActor (String) -> Void

        init(onFinish: @escaping @MainActor ([Data]) -> Void, onFailure: @escaping @MainActor (String) -> Void) {
            self.onFinish = onFinish
            self.onFailure = onFailure
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages: [Data] = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.9) }
            if pages.count < scan.pageCount {
                meetingPhotosLogger.error("Taranan sayfa JPEG'e çevrilemedi, sayfa: \(scan.pageCount, privacy: .public), çevrilen: \(pages.count, privacy: .public)")
                onFailure(String(localized: "Fotoğraf okunamadı; başka bir görüntü dene."))
            }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
            meetingPhotosLogger.error("Belge tarayıcı hata verdi, hata: \(String(describing: error), privacy: .public)")
            onFailure(String(localized: "Kamera açılamadı: \(userFacingMessage(error: error))"))
        }
    }
}

// MARK: Toplantı sayfası

/// Toplantının görüntüleri (fotoğraflar ve Mac'ten gelen değilse ekranlar), nottan çıkarılanlar ve son hata.
@MainActor
@Observable
final class PhoneMeetingImages {
    private(set) var snapshots: [ScreenSnapshot] = []
    private(set) var excluded: Set<String> = []
    private(set) var error: String?
    /// Fotoğraflar ekleniyor.
    private(set) var isAdding: Bool = false
    @ObservationIgnored private let thumbnails: NSCache<NSString, UIImage> = NSCache()

    /// Klasörden yeniden okur.
    func load(directory: URL) async {
        let result: Result<([ScreenSnapshot], Set<String>), any Error> = await runBlocking(qos: .userInitiated) { () -> Result<([ScreenSnapshot], Set<String>), any Error> in
            Result { (try listScreenSnapshots(meetingDirectory: directory), try readScreenNoteExclusions(meetingDirectory: directory)) }
        }
        switch result {
        case .success(let (list, exclusions)):
            snapshots = list
            excluded = prunedScreenNoteExclusions(excluded: exclusions, snapshots: list)
            error = nil
        case .failure(let failure):
            meetingPhotosLogger.error("Görüntüler okunamadı, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: failure), privacy: .private)")
            error = String(localized: "Ekran görüntüleri okunamadı: \(userFacingMessage(error: failure))")
        }
    }

    /// Fotoğrafları toplantının sonuna ekler.
    func add(meetingID: String, directory: URL, offsetSec: Double, images: [Data]) async {
        guard !images.isEmpty else {
            return
        }
        isAdding = true
        defer { isAdding = false }
        let result: (added: [ScreenSnapshot], error: String?) = await addPhotos(meetingID: meetingID, directory: directory, offsetSec: offsetSec, images: images)
        snapshots = (snapshots + result.added).sorted { $0.offsetSec < $1.offsetSec }
        error = result.error
    }

    /// Görüntüyü kalıcı siler (nottan çıkarma işareti de kalkar).
    func delete(directory: URL, snapshot: ScreenSnapshot) {
        do {
            try deleteScreenSnapshot(meetingDirectory: directory, snapshot: snapshot)
            snapshots.removeAll { $0 == snapshot }
            if excluded.contains(snapshot.id) {
                let pruned: Set<String> = prunedScreenNoteExclusions(excluded: excluded, snapshots: snapshots)
                try writeScreenNoteExclusions(meetingDirectory: directory, excluded: pruned)
                excluded = pruned
            }
            thumbnails.removeObject(forKey: snapshot.id as NSString)
            error = nil
        } catch {
            meetingPhotosLogger.error("Görüntü silinemedi, klasör: \(directory.lastPathComponent, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            self.error = String(localized: "Ekran görüntüsü silinemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Görüntüyü nota alır ya da çıkarır; seçim toplantının klasöründe saklanır.
    func toggleNote(directory: URL, snapshot: ScreenSnapshot) {
        let updated: Set<String> = toggledScreenNoteExclusion(excluded: excluded, snapshotID: snapshot.id)
        do {
            try writeScreenNoteExclusions(meetingDirectory: directory, excluded: updated)
            excluded = updated
            error = nil
        } catch {
            meetingPhotosLogger.error("Nota ekleme seçimi kaydedilemedi, hata: \(String(describing: error), privacy: .private)")
            self.error = String(localized: "Seçim kaydedilemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Küçük resim (önbellekli) ya da büyük hâli.
    func image(directory: URL, snapshot: ScreenSnapshot, maxPixelSize: Int) async throws -> UIImage {
        let key: NSString = "\(snapshot.id)-\(maxPixelSize)" as NSString
        if let cached = thumbnails.object(forKey: key) {
            return cached
        }
        let file: URL = screenSnapshotFile(meetingDirectory: directory, snapshot: snapshot)
        let image: CGImage = try await runBlocking(qos: .userInitiated) { () throws -> CGImage in
            try downscaledImage(file: file, maxPixelSize: maxPixelSize)
        }
        let result: UIImage = UIImage(cgImage: image)
        thumbnails.setObject(result, forKey: key)
        return result
    }

    /// Sayfadaki hatayı kaldırır ya da gösterir (çekme ve seçme hataları).
    func show(error message: String?) {
        error = message
    }
}

/// Toplantı sayfasının Ekranlar sekmesi (iPhone): görüntüler zaman sırasıyla, yanında o sırada konuşulanlar; dokununca
/// büyür, zamana dokununca ses oradan çalar. Fotoğraf eklenir, silinir, nota alınır ya da çıkarılır; ayar burada da
/// açılıp kapanır (Mac'teki Ekranlar sekmesinin karşılığı).
struct PhoneScreensPane: View {
    let record: MeetingRecord
    let paragraphs: [TranscriptParagraph]
    let directory: URL
    let images: PhoneMeetingImages
    let isEditable: Bool
    let canPlay: Bool
    @Binding var captureSource: PhotoCaptureSource?
    let onRegenerate: @MainActor () -> Void
    let onPlay: @MainActor (Double) -> Void
    @AppStorage(PhoneSettingsKey.screenNotes) private var usesPhotosInNotes: Bool = false
    @State private var expandedID: String?
    @State private var confirmingDeleteID: String?

    var body: some View {
        let linked: [LinkedScreenSnapshot] = linkScreenSnapshots(snapshots: images.snapshots, paragraphs: paragraphs, leadSec: screenSnapshotPolicy.captureIntervalSec)
        VStack(alignment: .leading, spacing: 14) {
            if let error = images.error {
                PhoneErrorList(messages: [error])
            }
            HStack(spacing: 8) {
                Text("\(linked.count) görüntü")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                if images.isAdding {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Menu {
                    PhotoCaptureMenuItems(source: $captureSource)
                } label: {
                    Label("Fotoğraf ekle", systemImage: "camera")
                        .appFont(size: 13, weight: .semibold)
                }
                .disabled(record.isSampleMeeting || images.isAdding)
            }
            Toggle(isOn: $usesPhotosInNotes) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notta fotoğrafları kullan")
                        .appFont(size: 14, weight: .medium)
                    Text("Notta en fazla 6, Sor'da en fazla 3 fotoğraf küçültülüp sunucumuz üzerinden Anthropic'e (Claude) gönderilir; sunucumuz saklamaz. Kapalıyken fotoğraflar bu iPhone'dan çıkmaz.")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if usesPhotosInNotes, record.note != nil, !linked.isEmpty {
                Button("Notu fotoğraflarla yenile", systemImage: "sparkles") { onRegenerate() }
                    .buttonStyle(.accentPill)
                    .controlSize(.small)
                    .disabled(!isEditable)
            }
            if linked.isEmpty {
                EmptyStateCard(
                    symbol: "camera.viewfinder", title: "Bu toplantıda görüntü yok",
                    message: "Tahtanın, slaytın ya da bir krokinin fotoğrafını ekle: notta o anda konuşulanlarla birlikte kullanılabilir. Kayıt sırasında üstteki kamera düğmesi de çeker."
                )
            } else {
                ForEach(linked) { (item: LinkedScreenSnapshot) in
                    row(item: item)
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: expandedID)
        .animation(.smooth(duration: 0.2), value: confirmingDeleteID)
    }

    private func row(item: LinkedScreenSnapshot) -> some View {
        let isExpanded: Bool = expandedID == item.id
        let isIncluded: Bool = !images.excluded.contains(item.id)
        return VStack(alignment: .leading, spacing: 8) {
            PhoneSnapshotImage(images: images, directory: directory, snapshot: item.snapshot, maxPixelSize: isExpanded ? screenSnapshotPolicy.maxPixelSize : 640)
                .frame(maxWidth: .infinity, maxHeight: isExpanded ? nil : 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { expandedID = isExpanded ? nil : item.id }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(item.snapshot.kind == .photo ? Text("Fotoğraf") : Text("Ekran görüntüsü"))
            HStack(spacing: 10) {
                Button {
                    onPlay(item.snapshot.offsetSec)
                } label: {
                    Label(timestamp(seconds: item.snapshot.offsetSec), systemImage: item.snapshot.kind == .photo ? "camera" : "rectangle.on.rectangle")
                        .appFont(size: 12, weight: .semibold)
                        .monospacedDigit()
                }
                .disabled(!canPlay)
                Spacer()
                if usesPhotosInNotes {
                    Button {
                        images.toggleNote(directory: directory, snapshot: item.snapshot)
                    } label: {
                        Label("Notta", systemImage: isIncluded ? "checkmark.circle.fill" : "circle")
                            .appFont(size: 12, weight: .medium)
                    }
                    .disabled(!isEditable)
                    .accessibilityAddTraits(isIncluded ? .isSelected : [])
                }
                if confirmingDeleteID == item.id {
                    Button("Sil", role: .destructive) {
                        images.delete(directory: directory, snapshot: item.snapshot)
                        confirmingDeleteID = nil
                    }
                    .appFont(size: 12, weight: .semibold)
                    Button("Vazgeç") { confirmingDeleteID = nil }
                        .appFont(size: 12, weight: .regular)
                } else {
                    Button {
                        confirmingDeleteID = item.id
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!isEditable)
                    .accessibilityLabel("Sil")
                }
            }
            .buttonStyle(.borderless)
            if let first = item.paragraphs.first {
                Text(first.text)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(isExpanded ? nil : 2)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Görüntünün küçük ya da büyük hâli; okunurken yer tutucu, okunamazsa neden.
private struct PhoneSnapshotImage: View {
    let images: PhoneMeetingImages
    let directory: URL
    let snapshot: ScreenSnapshot
    let maxPixelSize: Int
    @State private var image: UIImage?
    @State private var failed: Bool = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Label("Görüntü okunamadı", systemImage: "exclamationmark.triangle")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Theme.line.opacity(0.4)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: maxPixelSize) {
            do {
                image = try await images.image(directory: directory, snapshot: snapshot, maxPixelSize: maxPixelSize)
                failed = false
            } catch {
                meetingPhotosLogger.error("Görüntü okunamadı, görüntü: \(snapshot.id, privacy: .public), hata: \(String(describing: error), privacy: .public)")
                failed = true
            }
        }
    }
}

// MARK: Kısayollar ve Siri

/// iPhone'un arka ucu: toplantılar ve Sor yüklü hesabın oturumundan, açma gezinmeden.
@MainActor
final class PhoneMeetingIntentsBackend: MeetingIntentsBackend {
    private let sessions: PhoneSessionHost
    private let router: PhoneRouter
    private let account: HostedAccount

    init(sessions: PhoneSessionHost, router: PhoneRouter, account: HostedAccount) {
        self.sessions = sessions
        self.router = router
        self.account = account
    }

    func intentMeetings() async throws -> [MeetingRecord] {
        // Uygulama arka planda açıldıysa (Siri) hesabın adı ve toplantıları önce okunur.
        guard !account.requiresSignIn else {
            throw MeetingIntentError.notReady
        }
        let store: PhoneStore = sessions.session.store
        if !store.isLoaded {
            store.loadIdentity()
            await store.reloadAndWait()
        }
        return store.meetings
    }

    func intentUserName() -> String {
        sessions.session.store.userName
    }

    func openMeeting(id: String) {
        router.show(meetingID: id)
    }

    func askAcrossMeetings(question: String) async throws -> String {
        _ = try await intentMeetings()
        return try await sessions.session.ask.askForIntent(question: question)
    }
}
