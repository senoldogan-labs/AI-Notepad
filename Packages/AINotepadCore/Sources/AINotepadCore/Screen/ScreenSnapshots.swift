import Foundation

// Paylaşılan ekranın görüntüleri: kayıt sırasında ekran anlamlı değişince bir JPEG toplantının klasörüne
// (`Screens/`) yazılır. Dosya adı kaydın başından geçen süreyi taşır; ayrı bir dizin dosyası yoktur (tek görüntü silmek
// yalnızca dosyasını silmektir, yarım yazılmış dizin olmaz).

/// Toplantı klasöründe ekran görüntülerinin klasörü.
public let screenSnapshotsFolderName: String = "Screens"

/// Görüntü dosyalarının uzantısı (MCP istemcileri ve LLM'ler JPEG okur; HEIC okumaz).
public let screenSnapshotExtension: String = "jpg"

/// Dosya adının öneki: `screen-<kaydın başından milisaniye, 9 hane>.jpg`.
private let screenSnapshotPrefix: String = "screen-"

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
}

/// Kaydın başından geçen süreye göre görüntü (milisaniyeye yuvarlanır; sıralı dosya adı için 9 hane). Saf fonksiyondur.
public func screenSnapshot(offsetSec: Double) -> ScreenSnapshot {
    let milliseconds: Int = max(0, Int((offsetSec * 1000).rounded()))
    return ScreenSnapshot(id: screenSnapshotPrefix + String(format: "%09d", milliseconds), offsetSec: Double(milliseconds) / 1000)
}

/// Dosya adından görüntü; adı bu biçimde değilse nil (klasördeki başka dosyalar, ör. Finder'ın `.DS_Store`'u, atlanır).
/// Saf fonksiyondur.
public func screenSnapshot(fileName: String) -> ScreenSnapshot? {
    let suffix: String = ".\(screenSnapshotExtension)"
    guard fileName.hasPrefix(screenSnapshotPrefix), fileName.hasSuffix(suffix) else {
        return nil
    }
    let digits: Substring = fileName.dropFirst(screenSnapshotPrefix.count).dropLast(suffix.count)
    guard digits.count == 9, digits.allSatisfy(\.isASCII), let milliseconds = Int(digits), milliseconds >= 0 else {
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

/// Toplantının görüntüleri, zamana göre sıralı. Klasör yoksa (görüntü alınmamış) boş; okunamazsa `readFailed`.
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
    /// Son saklanandan en az bu oranda hücre değişmişse ekran yenidir.
    public let minChangedFraction: Double
    /// Bir önceki bakıştan bu orandan fazla hücre değiştiyse ekran hâlâ değişiyor (geçiş, kaydırma, video): beklenir.
    public let maxUnsettledFraction: Double
    /// Saklanan görüntünün uzun kenarı (piksel).
    public let maxPixelSize: Int
    /// JPEG kalitesi (0–1).
    public let jpegQuality: Double

    public init(
        captureIntervalSec: Double, minStoreIntervalSec: Double, maxPerMeeting: Int, cellDelta: Int, minChangedFraction: Double,
        maxUnsettledFraction: Double, maxPixelSize: Int, jpegQuality: Double
    ) {
        self.captureIntervalSec = captureIntervalSec
        self.minStoreIntervalSec = minStoreIntervalSec
        self.maxPerMeeting = maxPerMeeting
        self.cellDelta = cellDelta
        self.minChangedFraction = minChangedFraction
        self.maxUnsettledFraction = maxUnsettledFraction
        self.maxPixelSize = maxPixelSize
        self.jpegQuality = jpegQuality
    }
}

/// Uygulamanın kuralları: 3 sn'de bir bakılır; ekranın en az beşte biri değişip durulunca saklanır; en az 6 sn arayla,
/// toplantı başına en fazla 300 görüntü (2 saatlik toplantıda ortalama 24 sn'de bir). Görüntü en fazla 1600 piksel.
public let screenSnapshotPolicy: ScreenSnapshotPolicy = ScreenSnapshotPolicy(
    captureIntervalSec: 3, minStoreIntervalSec: 6, maxPerMeeting: 300, cellDelta: 18, minChangedFraction: 0.2,
    maxUnsettledFraction: 0.1, maxPixelSize: 1600, jpegQuality: 0.7
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

/// İki parmak izi arasında değişen hücrelerin oranı (0–1): parlaklığı `cellDelta`'dan fazla değişen hücreler. Boyutlar
/// farklıysa (pencere değişti) 1. Saf fonksiyondur.
public func changedFraction(from old: ScreenFingerprint, to new: ScreenFingerprint, cellDelta: Int) -> Double {
    guard old.width == new.width, old.height == new.height, old.luma.count == new.luma.count, !new.luma.isEmpty else {
        return 1
    }
    let changed: Int = zip(old.luma, new.luma).reduce(0) { (count: Int, pair: (UInt8, UInt8)) -> Int in
        abs(Int(pair.0) - Int(pair.1)) > cellDelta ? count + 1 : count
    }
    return Double(changed) / Double(new.luma.count)
}

/// Görüntü alma durumu: son saklanan, bir önceki bakış ve saklanan sayısı.
public struct ScreenSnapshotState: Sendable, Equatable {
    public let lastStored: ScreenFingerprint?
    public let lastStoredOffsetSec: Double?
    public let previousCapture: ScreenFingerprint?
    public let storedCount: Int

    public init(lastStored: ScreenFingerprint?, lastStoredOffsetSec: Double?, previousCapture: ScreenFingerprint?, storedCount: Int) {
        self.lastStored = lastStored
        self.lastStoredOffsetSec = lastStoredOffsetSec
        self.previousCapture = previousCapture
        self.storedCount = storedCount
    }
}

/// Kayıt başındaki durum; toplantıda daha önce saklanmış görüntüler varsa (ör. aynı klasöre devam) sayıları sınıra
/// dahildir. Saf fonksiyondur.
public func initialScreenSnapshotState(storedCount: Int) -> ScreenSnapshotState {
    ScreenSnapshotState(lastStored: nil, lastStoredOffsetSec: nil, previousCapture: nil, storedCount: storedCount)
}

/// Bir bakışın sonucu.
public enum ScreenSnapshotDecision: Sendable, Equatable {
    /// Ekran yeni ve durgun: saklanır.
    case store
    /// Son saklanandan anlamlı farkı yok.
    case unchanged
    /// Ekran hâlâ değişiyor (ya da ilk bakış): bir sonraki bakış beklenir.
    case unsettled
    /// Son saklanandan bu yana `minStoreIntervalSec` geçmedi.
    case tooSoon
    /// Toplantının sınırı doldu; kayıt boyunca başka görüntü alınmaz.
    case capReached
}

/// Yeni bakışın saklanıp saklanmayacağı: sınır doluysa hiç, ekran durulmamışsa bekle, son saklanandan yeterince farklı
/// ve yeterince zaman geçmişse sakla. Saf fonksiyondur.
public func screenSnapshotDecision(policy: ScreenSnapshotPolicy, state: ScreenSnapshotState, candidate: ScreenFingerprint, offsetSec: Double) -> ScreenSnapshotDecision {
    guard state.storedCount < policy.maxPerMeeting else {
        return .capReached
    }
    guard let previous = state.previousCapture,
          changedFraction(from: previous, to: candidate, cellDelta: policy.cellDelta) <= policy.maxUnsettledFraction else {
        return .unsettled
    }
    if let stored = state.lastStored, changedFraction(from: stored, to: candidate, cellDelta: policy.cellDelta) < policy.minChangedFraction {
        return .unchanged
    }
    if let storedAt = state.lastStoredOffsetSec, offsetSec - storedAt < policy.minStoreIntervalSec {
        return .tooSoon
    }
    return .store
}

/// Bakıştan sonraki durum: her bakış "bir önceki" olur; saklandıysa son saklanan da odur. Saf fonksiyondur.
public func advancedScreenSnapshotState(state: ScreenSnapshotState, candidate: ScreenFingerprint, offsetSec: Double, stored: Bool) -> ScreenSnapshotState {
    ScreenSnapshotState(
        lastStored: stored ? candidate : state.lastStored,
        lastStoredOffsetSec: stored ? offsetSec : state.lastStoredOffsetSec,
        previousCapture: candidate,
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
