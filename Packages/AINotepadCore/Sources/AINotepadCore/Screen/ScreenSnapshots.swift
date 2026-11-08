import Foundation

// Paylaşılan ekranın görüntüleri: kayıt sırasında ekran anlamlı değişince bir JPEG toplantının klasörüne
// (`Screens/`) yazılır. Kullanıcının toplantıda ya da sonradan çektiği fotoğraflar (tahta, slayt, kroki) da aynı klasörde
// aynı biçimde durur (`photo-` önekiyle): notta, Sor'da, MCP'de ve Ekranlar sekmesinde ekran görüntüleriyle aynı yoldan
// gider. Dosya adı kaydın başından geçen süreyi taşır; ayrı bir dizin dosyası yoktur (tek görüntü silmek yalnızca
// dosyasını silmektir, yarım yazılmış dizin olmaz).

/// Toplantı klasöründe ekran görüntülerinin klasörü.
public let screenSnapshotsFolderName: String = "Screens"

/// Görüntü dosyalarının uzantısı (MCP istemcileri ve LLM'ler JPEG okur; HEIC okumaz).
public let screenSnapshotExtension: String = "jpg"

/// Dosya adının öneki: `screen-<kaydın başından milisaniye, 9 hane>.jpg`.
private let screenSnapshotPrefix: String = "screen-"
/// Kullanıcının çektiği fotoğrafın öneki: `photo-<kaydın başından milisaniye, 9 hane>.jpg`.
private let photoSnapshotPrefix: String = "photo-"

/// Görüntünün kaynağı.
public enum ScreenSnapshotKind: Sendable, Equatable {
    /// Kayıt sırasında paylaşılan ekrandan kendiliğinden alındı (Mac).
    case screen
    /// Kullanıcı kamerayla çekti ya da fotoğraflardan ekledi (tahta, slayt, kroki).
    case photo
}

/// Toplantıda saklanmış bir ekran görüntüsü.
public struct ScreenSnapshot: Sendable, Equatable, Hashable, Identifiable {
    /// Dosya adının uzantısız hâli (`screen-000012400`); MCP'de görüntünün kimliği.
    public let id: String
    /// Kaydın başından geçen süre (transkriptin zaman çizgisiyle aynı).
    public let offsetSec: Double

    public init(id: String, offsetSec: Double) {
        self.id = id
        self.offsetSec = offsetSec
    }

    /// Diskteki dosya adı.
    public var fileName: String {
        "\(id).\(screenSnapshotExtension)"
    }

    /// Ekrandan mı alındı, kullanıcı mı çekti (kimliğin önekinden).
    public var kind: ScreenSnapshotKind {
        id.hasPrefix(photoSnapshotPrefix) ? .photo : .screen
    }
}

/// Kaydın başından geçen süreye göre görüntü (milisaniyeye yuvarlanır; sıralı dosya adı için 9 hane). Saf fonksiyondur.
public func screenSnapshot(offsetSec: Double) -> ScreenSnapshot {
    let milliseconds: Int = max(0, Int((offsetSec * 1000).rounded()))
    return ScreenSnapshot(id: screenSnapshotPrefix + String(format: "%09d", milliseconds), offsetSec: Double(milliseconds) / 1000)
}

/// Kaydın başından geçen süredeki fotoğraf; o milisaniyede başka fotoğraf varsa (art arda taranan sayfalar) ilk boş
/// milisaniye. Saf fonksiyondur.
public func photoSnapshot(offsetSec: Double, existing: [ScreenSnapshot]) -> ScreenSnapshot {
    let taken: Set<String> = Set(existing.map(\.id))
    var milliseconds: Int = max(0, Int((offsetSec * 1000).rounded()))
    while taken.contains(photoSnapshotPrefix + String(format: "%09d", milliseconds)) {
        milliseconds += 1
    }
    return ScreenSnapshot(id: photoSnapshotPrefix + String(format: "%09d", milliseconds), offsetSec: Double(milliseconds) / 1000)
}

/// Dosya adından görüntü (`screen-` ya da `photo-`); adı bu biçimde değilse nil (klasördeki başka dosyalar, ör. Finder'ın
/// `.DS_Store`'u, atlanır). Saf fonksiyondur.
public func screenSnapshot(fileName: String) -> ScreenSnapshot? {
    let suffix: String = ".\(screenSnapshotExtension)"
    guard let prefix = [screenSnapshotPrefix, photoSnapshotPrefix].first(where: { fileName.hasPrefix($0) }), fileName.hasSuffix(suffix) else {
        return nil
    }
    let digits: Substring = fileName.dropFirst(prefix.count).dropLast(suffix.count)
    guard digits.count == 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let milliseconds = Int(digits), milliseconds >= 0 else {
        return nil
    }
    return ScreenSnapshot(id: String(fileName.dropLast(suffix.count)), offsetSec: Double(milliseconds) / 1000)
}

/// Kimliğin (`screen-000012400`) görüntüsü; biçim yanlışsa nil (MCP'den gelen kimlik dosya yoluna girmeden denetlenir:
/// `../` gibi değerler reddedilir). Saf fonksiyondur.
public func screenSnapshot(id: String) -> ScreenSnapshot? {
    screenSnapshot(fileName: "\(id).\(screenSnapshotExtension)")
}

/// Toplantının görüntü klasörü (oluşturulmaz). Saf fonksiyondur.
public func screenSnapshotsDirectory(meetingDirectory: URL) -> URL {
    meetingDirectory.appending(path: screenSnapshotsFolderName, directoryHint: .isDirectory)
}

/// Görüntünün dosyası. Saf fonksiyondur.
public func screenSnapshotFile(meetingDirectory: URL, snapshot: ScreenSnapshot) -> URL {
    screenSnapshotsDirectory(meetingDirectory: meetingDirectory).appending(path: snapshot.fileName)
}

/// Toplantının görüntüleri (ekran ve fotoğraf), zamana göre sıralı. Klasör yoksa (görüntü alınmamış) boş; okunamazsa `readFailed`.
public func listScreenSnapshots(meetingDirectory: URL) throws -> [ScreenSnapshot] {
    let directory: URL = screenSnapshotsDirectory(meetingDirectory: meetingDirectory)
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return []
    }
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
        throw StorageError.readFailed(path: directory.path, reason: error.localizedDescription)
    }
    return names.compactMap { screenSnapshot(fileName: $0) }.sorted { $0.offsetSec < $1.offsetSec }
}

/// Görüntüyü (JPEG) toplantının klasörüne atomik yazar; klasör yoksa oluşturur. Yazılamazsa `writeFailed`.
public func writeScreenSnapshot(meetingDirectory: URL, snapshot: ScreenSnapshot, jpeg: Data) throws {
    let directory: URL = screenSnapshotsDirectory(meetingDirectory: meetingDirectory)
    let file: URL = screenSnapshotFile(meetingDirectory: meetingDirectory, snapshot: snapshot)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Tek görüntüyü kalıcı siler. Silinemezse `deleteFailed`.
public func deleteScreenSnapshot(meetingDirectory: URL, snapshot: ScreenSnapshot) throws {
    try coordinatedRemoveItem(at: screenSnapshotFile(meetingDirectory: meetingDirectory, snapshot: snapshot))
}

/// Toplantının bütün görüntülerini (klasörüyle) kalıcı siler; klasör yoksa bir şey yapmaz. Silinemezse `deleteFailed`.
public func deleteAllScreenSnapshots(meetingDirectory: URL) throws {
    let directory: URL = screenSnapshotsDirectory(meetingDirectory: meetingDirectory)
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return
    }
    try coordinatedRemoveItem(at: directory)
}

// MARK: Ne zaman saklanır

/// Görüntü alma kuralları: ne sıklıkla bakılır, ne zaman saklanır, en fazla kaç tane.
public struct ScreenSnapshotPolicy: Sendable, Equatable {
    /// İki bakış arası (ekran bu aralıkla küçük boyda yakalanıp karşılaştırılır).
    public let captureIntervalSec: Double
    /// İki saklanan görüntü arasındaki en kısa süre.
    public let minStoreIntervalSec: Double
    /// Toplantı başına en fazla görüntü (diski ve MCP çıktısını sınırlar).
    public let maxPerMeeting: Int
    /// Parmak izi hücresinin "değişti" sayılması için gereken en küçük parlaklık farkı (0–255).
    public let cellDelta: Int
    /// Son saklanandan (hareketli bölge dışında) en az bu oranda hücre değişmişse ekran yenidir.
    public let minChangedFraction: Double
    /// Bir önceki bakıştan (hareketli bölge dışında) bu orandan fazla hücre değiştiyse ekran hâlâ değişiyor: beklenir.
    public let maxUnsettledFraction: Double
    /// Hareketli hücrelerin arandığı son bakış sayısı (şimdiki dahil).
    public let busyWindowLooks: Int
    /// Bir hücre son `busyWindowLooks` bakışın en az bu kadarında değiştiyse hareketlidir (video, kayan yazı, konuşan
    /// yüz). Slayt geçişi bir hücreyi en fazla iki bakışta değiştirir; bu yüzden üçtür.
    public let busyMinChanges: Int
    /// Ekranda hareketli bölge yokken: son `busyWindowLooks` bakışta (hareketli bölge dışında) en az bu kadar ayrı
    /// değişim olduysa ekran oynuyor (art arda çevrilen sayfalar): durulması beklenir.
    public let motionMinEvents: Int
    /// Hareketli bölge varken (ekranda video oynuyor) değişimlerin sayıldığı son bakış sayısı; bu bakışlar hafızada
    /// tutulur.
    public let videoMotionWindowLooks: Int
    /// Hareketli bölge varken: son `videoMotionWindowLooks` bakışta en az bu kadar ayrı değişim olduysa (videodaki
    /// kesmeler) ekran oynuyor sayılır.
    public let videoMotionMinEvents: Int
    /// Saklanan görüntünün uzun kenarı (piksel).
    public let maxPixelSize: Int
    /// JPEG kalitesi (0–1).
    public let jpegQuality: Double

    public init(
        captureIntervalSec: Double, minStoreIntervalSec: Double, maxPerMeeting: Int, cellDelta: Int, minChangedFraction: Double,
        maxUnsettledFraction: Double, busyWindowLooks: Int, busyMinChanges: Int, motionMinEvents: Int, videoMotionWindowLooks: Int,
        videoMotionMinEvents: Int, maxPixelSize: Int, jpegQuality: Double
    ) {
        self.captureIntervalSec = captureIntervalSec
        self.minStoreIntervalSec = minStoreIntervalSec
        self.maxPerMeeting = maxPerMeeting
        self.cellDelta = cellDelta
        self.minChangedFraction = minChangedFraction
        self.maxUnsettledFraction = maxUnsettledFraction
        self.busyWindowLooks = busyWindowLooks
        self.busyMinChanges = busyMinChanges
        self.motionMinEvents = motionMinEvents
        self.videoMotionWindowLooks = videoMotionWindowLooks
        self.videoMotionMinEvents = videoMotionMinEvents
        self.maxPixelSize = maxPixelSize
        self.jpegQuality = jpegQuality
    }
}

/// Uygulamanın kuralları:
/// - 3 sn'de bir bakılır (32×20 hücrelik gri parmak izi; hücre parlaklığı 18'den fazla değişirse "değişti").
/// - Son 30 sn'de (10 bakış) en az 3 kez değişen hücreler hareketlidir (konuşan yüz, kayan yazı, oynayan video,
///   kaydırılan sayfa). Bunlar iki hücre çevresiyle genişletilip her kümenin dikdörtgenine tamamlanır (gömülü video
///   oynatıcısı, görüşmedeki kamera kutusu) ve bütün karşılaştırmalarda sayılmaz.
/// - Ekranın (tüm hücrelere göre) en az üçte biri son saklanandan farklıysa ve son bakıştan bu yana %10'dan azı
///   değiştiyse saklanır; şu durumlarda beklenir: ekranda hareketli bölge yokken son 30 sn'de 3 ayrı değişim (hızla
///   çevrilen sayfalar), varken son 60 sn'de 2 ayrı değişim (videodaki kesmeler). Art arda değişen bakışlar tek değişim
///   sayılır (geçiş efekti olan slayt da bir kez değişmiştir).
/// - İki görüntü arası en az 20 sn; toplantı başına en fazla 120 görüntü (2 saatte ortalama dakikada bir).
/// 9 dakikalık bir haber videosu eski kurallarla (%20, 6 sn, hareket maskesi yok, 300 sınır) 24 görüntü vermişti.
/// Ekranda kamera kutusu varken bir slayt, öncekinden 60 sn sonra ya da ekranda kaldığı 60 sn dolunca saklanır.
/// Görüntü en fazla 1600 piksel.
public let screenSnapshotPolicy: ScreenSnapshotPolicy = ScreenSnapshotPolicy(
    captureIntervalSec: 3, minStoreIntervalSec: 20, maxPerMeeting: 120, cellDelta: 18, minChangedFraction: 0.33,
    maxUnsettledFraction: 0.1, busyWindowLooks: 10, busyMinChanges: 3, motionMinEvents: 3, videoMotionWindowLooks: 20,
    videoMotionMinEvents: 2, maxPixelSize: 1600, jpegQuality: 0.7
)

/// Ekranın küçültülmüş gri parmak izi (değişim karşılaştırması için; ör. 32×20 hücre, satır satır parlaklık).
public struct ScreenFingerprint: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let luma: [UInt8]

    public init(width: Int, height: Int, luma: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
    }
}

/// Parmak izinin genişliği ve yüksekliği (16:10; geniş ekranda da hücreler yaklaşık karedir).
public let screenFingerprintWidth: Int = 32
public let screenFingerprintHeight: Int = 20

/// İki parmak izi aynı boyutta mı (değilse pencere değişmiştir; hücreler karşılaştırılamaz). Saf fonksiyondur.
func comparableFingerprints(_ old: ScreenFingerprint, _ new: ScreenFingerprint) -> Bool {
    old.width == new.width && old.height == new.height && old.luma.count == new.luma.count && !new.luma.isEmpty
}

/// Hücre hücre değişti mi: parlaklığı `cellDelta`'dan fazla değişenler true. Boyutlar farklıysa hepsi true. Saf
/// fonksiyondur.
func changedCells(from old: ScreenFingerprint, to new: ScreenFingerprint, cellDelta: Int) -> [Bool] {
    guard comparableFingerprints(old, new) else {
        return Array(repeating: true, count: new.luma.count)
    }
    return zip(old.luma, new.luma).map { abs(Int($0.0) - Int($0.1)) > cellDelta }
}

/// İki parmak izi arasında değişen hücrelerin oranı (0–1): parlaklığı `cellDelta`'dan fazla değişen hücreler. Boyutlar
/// farklıysa (pencere değişti) 1. Saf fonksiyondur.
public func changedFraction(from old: ScreenFingerprint, to new: ScreenFingerprint, cellDelta: Int) -> Double {
    guard comparableFingerprints(old, new) else {
        return 1
    }
    return maskedFraction(changed: changedCells(from: old, to: new, cellDelta: cellDelta), ignored: Array(repeating: false, count: new.luma.count))
}

/// Yok sayılmayan değişmiş hücrelerin tüm hücrelere oranı (payda hep tüm ekran: maskeli büyük bir video kalan küçük
/// değişimi büyütmez). Saf fonksiyondur.
func maskedFraction(changed: [Bool], ignored: [Bool]) -> Double {
    guard !changed.isEmpty, changed.count == ignored.count else {
        return changed.isEmpty ? 0 : 1
    }
    let counted: Int = zip(changed, ignored).filter { $0.0 && !$0.1 }.count
    return Double(counted) / Double(changed.count)
}

/// Hareketli bölge: son bakışlarda (`recentChanges`, her biri bir bakışın hücre değişimleri) en az `minChanges` kez
/// değişen hücreler, `busyGrowCells` hücre çevresiyle genişletilip her bağlı kümenin (8 komşu) dikdörtgenine tamamlanır. Konuşan
/// yüzle altındaki kayan yazı böylece tek oynatıcı dikdörtgeni olur; videodaki kesmeler o dikdörtgenin içinde kalır.
/// Saf fonksiyondur.
/// Hareketli hücrelerin genişletildiği çevre (hücre): yüzle altındaki kayan yazı arasındaki boşluğu kapatır.
let busyGrowCells: Int = 2

func busyRegion(recentChanges: [[Bool]], width: Int, height: Int, minChanges: Int) -> [Bool] {
    let count: Int = width * height
    let looks: [[Bool]] = recentChanges.filter { $0.count == count }
    let busy: [Bool] = (0..<count).map { (cell: Int) -> Bool in
        looks.reduce(0) { $0 + ($1[cell] ? 1 : 0) } >= minChanges
    }
    guard busy.contains(true) else {
        return busy
    }
    let grown: [Bool] = (0..<count).map { (cell: Int) -> Bool in
        let (x, y): (Int, Int) = (cell % width, cell / width)
        return (max(0, y - busyGrowCells)...min(height - 1, y + busyGrowCells)).contains { (row: Int) -> Bool in
            (max(0, x - busyGrowCells)...min(width - 1, x + busyGrowCells)).contains { busy[row * width + $0] }
        }
    }
    // Bağlı kümeler ve dikdörtgenleri.
    var label: [Int] = Array(repeating: -1, count: count)
    var boxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
    for seed in 0..<count where grown[seed] && label[seed] < 0 {
        var stack: [Int] = [seed]
        label[seed] = boxes.count
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int) = (seed % width, seed / width, seed % width, seed / width)
        while let cell = stack.popLast() {
            let (x, y): (Int, Int) = (cell % width, cell / width)
            box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            for row in max(0, y - 1)...min(height - 1, y + 1) {
                for column in max(0, x - 1)...min(width - 1, x + 1) where grown[row * width + column] && label[row * width + column] < 0 {
                    label[row * width + column] = boxes.count
                    stack.append(row * width + column)
                }
            }
        }
        boxes.append(box)
    }
    return (0..<count).map { (cell: Int) -> Bool in
        let (x, y): (Int, Int) = (cell % width, cell / width)
        return boxes.contains { x >= $0.minX && x <= $0.maxX && y >= $0.minY && y <= $0.maxY }
    }
}

/// Görüntü alma durumu: son saklanan, bir önceki bakış, son bakışların hücre değişimleri ve saklanan sayısı.
public struct ScreenSnapshotState: Sendable, Equatable {
    public let lastStored: ScreenFingerprint?
    public let lastStoredOffsetSec: Double?
    public let previousCapture: ScreenFingerprint?
    /// Son bakışların (en fazla `videoMotionWindowLooks - 1`, eskiden yeniye) bir öncekine göre hücre değişimleri; önceki
    /// bakışı olmayan bakış eklenmez.
    public let recentChanges: [[Bool]]
    public let storedCount: Int

    public init(lastStored: ScreenFingerprint?, lastStoredOffsetSec: Double?, previousCapture: ScreenFingerprint?, recentChanges: [[Bool]], storedCount: Int) {
        self.lastStored = lastStored
        self.lastStoredOffsetSec = lastStoredOffsetSec
        self.previousCapture = previousCapture
        self.recentChanges = recentChanges
        self.storedCount = storedCount
    }
}

/// Kayıt başındaki durum; toplantıda daha önce saklanmış görüntüler varsa (ör. aynı klasöre devam) sayıları sınıra
/// dahildir. Saf fonksiyondur.
public func initialScreenSnapshotState(storedCount: Int) -> ScreenSnapshotState {
    ScreenSnapshotState(lastStored: nil, lastStoredOffsetSec: nil, previousCapture: nil, recentChanges: [], storedCount: storedCount)
}

/// Duraklatma boyunca ekran değişmiş olabilir: bir önceki bakış ve hareket geçmişi unutulur, sürdürünce önce durulması
/// beklenir. Saf fonksiyondur.
public func pausedScreenSnapshotState(state: ScreenSnapshotState) -> ScreenSnapshotState {
    ScreenSnapshotState(
        lastStored: state.lastStored, lastStoredOffsetSec: state.lastStoredOffsetSec, previousCapture: nil, recentChanges: [], storedCount: state.storedCount
    )
}

/// Bir ekran görüntüsü alma çalıştırmasının durumu: yalnızca `running` iken görüntü yazılır.
public enum ScreenCaptureRunState: Sendable, Equatable {
    case running
    case paused
    /// Kayıt bitti; çalıştırma bir daha başlamaz (yeni kayıt yeni çalıştırma açar).
    case stopped
}

/// Çalıştırmaya gelen olaylar (kayıt duraklatıldı, sürdü, bitti).
public enum ScreenCaptureRunEvent: Sendable, Equatable {
    case pause
    case resume
    case stop
}

/// Çalıştırmanın sonraki durumu: durduktan sonra duraklatma ya da sürdürme onu yeniden başlatmaz. Saf fonksiyondur.
public func screenCaptureRunTransition(state: ScreenCaptureRunState, event: ScreenCaptureRunEvent) -> ScreenCaptureRunState {
    switch (state, event) {
    case (.stopped, _), (_, .stop):
        return .stopped
    case (_, .pause):
        return .paused
    case (_, .resume):
        return .running
    }
}

/// Bir bakışın sonucu.
public enum ScreenSnapshotDecision: Sendable, Equatable {
    /// Ekran yeni ve durgun: saklanır.
    case store
    /// Son saklanandan (hareketli bölge dışında) anlamlı farkı yok.
    case unchanged
    /// Ekran hâlâ değişiyor (ya da ilk bakış): bir sonraki bakış beklenir.
    case unsettled
    /// Ekran son bakışlarda sık sık değişti (kesmeli video, art arda çevrilen sayfalar): durulması beklenir.
    case moving
    /// Son saklanandan bu yana `minStoreIntervalSec` geçmedi.
    case tooSoon
    /// Toplantının sınırı doldu; kayıt boyunca başka görüntü alınmaz.
    case capReached
}

/// Bu bakışla birlikte son bakışların hücre değişimleri (en fazla `videoMotionWindowLooks`). Saf fonksiyondur.
private func lookChanges(policy: ScreenSnapshotPolicy, state: ScreenSnapshotState, candidate: ScreenFingerprint) -> [[Bool]] {
    guard let previous = state.previousCapture, comparableFingerprints(previous, candidate) else {
        return Array(state.recentChanges.suffix(max(0, policy.videoMotionWindowLooks - 1)))
    }
    return Array((state.recentChanges + [changedCells(from: previous, to: candidate, cellDelta: policy.cellDelta)]).suffix(policy.videoMotionWindowLooks))
}

/// Ayrı değişimlerin sayısı: art arda değişen bakışlar (`moving` true) tek değişimdir. Saf fonksiyondur.
func motionEvents(moving: [Bool]) -> Int {
    zip([false] + moving, moving).filter { !$0.0 && $0.1 }.count
}

/// Yeni bakışın saklanıp saklanmayacağı: sınır doluysa hiç; ekran durulmamışsa ya da son bakışlarda sık değiştiyse
/// (hareketli bölge varken daha uzun bir pencerede, daha az değişimle) bekle; son saklanandan yeterince farklı ve yeterince zaman geçmişse sakla. Hareketli bölge (`busyRegion`) bütün
/// karşılaştırmalarda yok sayılır. Saf fonksiyondur.
public func screenSnapshotDecision(policy: ScreenSnapshotPolicy, state: ScreenSnapshotState, candidate: ScreenFingerprint, offsetSec: Double) -> ScreenSnapshotDecision {
    guard state.storedCount < policy.maxPerMeeting else {
        return .capReached
    }
    guard let previous = state.previousCapture, comparableFingerprints(previous, candidate) else {
        return .unsettled
    }
    let looks: [[Bool]] = lookChanges(policy: policy, state: state, candidate: candidate)
    let busy: [Bool] = busyRegion(
        recentChanges: Array(looks.suffix(policy.busyWindowLooks)), width: candidate.width, height: candidate.height, minChanges: policy.busyMinChanges
    )
    let current: [Bool] = changedCells(from: previous, to: candidate, cellDelta: policy.cellDelta)
    guard maskedFraction(changed: current, ignored: busy) <= policy.maxUnsettledFraction else {
        return .unsettled
    }
    let hasVideo: Bool = busy.contains(true)
    let window: [[Bool]] = Array(looks.suffix(hasVideo ? policy.videoMotionWindowLooks : policy.busyWindowLooks))
    let events: Int = motionEvents(moving: window.map { maskedFraction(changed: $0, ignored: busy) > policy.maxUnsettledFraction })
    guard events < (hasVideo ? policy.videoMotionMinEvents : policy.motionMinEvents) else {
        return .moving
    }
    if let stored = state.lastStored, comparableFingerprints(stored, candidate),
       maskedFraction(changed: changedCells(from: stored, to: candidate, cellDelta: policy.cellDelta), ignored: busy) < policy.minChangedFraction {
        return .unchanged
    }
    if let storedAt = state.lastStoredOffsetSec, offsetSec - storedAt < policy.minStoreIntervalSec {
        return .tooSoon
    }
    return .store
}

/// Bakıştan sonraki durum: her bakış "bir önceki" olur ve hücre değişimi hareket geçmişine girer; saklandıysa son
/// saklanan da odur. Pencere değiştiyse (boyut farklı) hareket geçmişi sıfırlanır. Saf fonksiyondur.
public func advancedScreenSnapshotState(
    policy: ScreenSnapshotPolicy, state: ScreenSnapshotState, candidate: ScreenFingerprint, offsetSec: Double, stored: Bool
) -> ScreenSnapshotState {
    let resized: Bool = state.previousCapture.map { !comparableFingerprints($0, candidate) } ?? false
    let changes: [[Bool]] = resized ? [] : Array(lookChanges(policy: policy, state: state, candidate: candidate).suffix(max(0, policy.videoMotionWindowLooks - 1)))
    return ScreenSnapshotState(
        lastStored: stored ? candidate : state.lastStored,
        lastStoredOffsetSec: stored ? offsetSec : state.lastStoredOffsetSec,
        previousCapture: candidate,
        recentChanges: changes,
        storedCount: stored ? state.storedCount + 1 : state.storedCount
    )
}

// MARK: Transkriptle eşleme

/// Görüntü ve ekrandayken konuşulanlar.
public struct LinkedScreenSnapshot: Sendable, Equatable, Identifiable {
    public let snapshot: ScreenSnapshot
    /// Ekranda olduğu sanılan aralığın başı (saklanmadan biraz önce görünmeye başlamıştır; bkz. `leadSec`).
    public let startSec: Double
    /// Sonraki görüntünün başı; son görüntüde nil (toplantının sonuna dek).
    public let endSec: Double?
    /// Bu aralıkla kesişen transkript paragrafları (aralık sınırındaki paragraf iki görüntüde de görünür).
    public let paragraphs: [TranscriptParagraph]

    public var id: String {
        snapshot.id
    }
}

/// Her görüntüyü ekrandayken konuşulan paragraflarla eşler. Görüntü ekran durulduktan sonra saklandığı için aralıklar
/// `leadSec` kadar öne alınır (ekran saklanmadan önce de görünüyordu); aralık sonraki görüntünün başında biter.
/// Paragraf aralıkla kesişiyorsa eşlenir. Saf fonksiyondur.
public func linkScreenSnapshots(snapshots: [ScreenSnapshot], paragraphs: [TranscriptParagraph], leadSec: Double) -> [LinkedScreenSnapshot] {
    let sorted: [ScreenSnapshot] = snapshots.sorted { $0.offsetSec < $1.offsetSec }
    let starts: [Double] = sorted.map { max(0, $0.offsetSec - leadSec) }
    return sorted.indices.map { (index: Int) -> LinkedScreenSnapshot in
        let start: Double = starts[index]
        let end: Double? = index + 1 < starts.count ? starts[index + 1] : nil
        let overlapping: [TranscriptParagraph] = paragraphs.filter { (paragraph: TranscriptParagraph) -> Bool in
            paragraph.endSec >= start && end.map { paragraph.startSec < $0 } ?? true
        }
        return LinkedScreenSnapshot(snapshot: sorted[index], startSec: start, endSec: end, paragraphs: overlapping)
    }
}

/// Eşlenen paragrafların düz metni: `[mm:ss] Ad: metin` satırları; `maxChars`'ı aşan kısım "…" ile kesilir (MCP çıktısı
/// sınırlı kalsın). Saf fonksiyondur.
public func screenExcerpt(linked: LinkedScreenSnapshot, speakerNames: [Int: String], maxChars: Int) -> String {
    let text: String = linked.paragraphs
        .map { "[\(timestamp(seconds: $0.startSec))] \(paragraphLabel(paragraph: $0, speakerNames: speakerNames)): \($0.text)" }
        .joined(separator: "\n")
    guard text.count > maxChars else {
        return text
    }
    return String(text.prefix(maxChars)) + "…"
}
