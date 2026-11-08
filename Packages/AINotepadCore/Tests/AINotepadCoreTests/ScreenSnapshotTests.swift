import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AINotepadCore

/// Düz renkli bir alan ve isteğe bağlı bir dikdörtgen çizilmiş deneme görüntüsü (ekran yerine).
private func testImage(width: Int, height: Int, background: CGFloat, box: CGRect?) throws -> CGImage {
    let context: CGContext = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: background, green: background, blue: background, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let box {
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(box)
    }
    return try #require(context.makeImage())
}

/// Tek renkli parmak izi.
private func flat(_ value: UInt8) -> ScreenFingerprint {
    ScreenFingerprint(width: screenFingerprintWidth, height: screenFingerprintHeight, luma: Array(repeating: value, count: screenFingerprintWidth * screenFingerprintHeight))
}

/// İlk `cells` hücresi `value` olan, gerisi `base` parmak izi.
private func partly(base: UInt8, value: UInt8, cells: Int) -> ScreenFingerprint {
    let count: Int = screenFingerprintWidth * screenFingerprintHeight
    return ScreenFingerprint(width: screenFingerprintWidth, height: screenFingerprintHeight, luma: (0..<count).map { $0 < cells ? value : base })
}

private func paragraph(_ id: String, _ start: Double, _ end: Double, _ text: String) -> TranscriptParagraph {
    TranscriptParagraph(id: id, speaker: .others, person: 1, startSec: start, endSec: end, text: text, turkish: nil, translationFailed: false, words: [])
}

/// Bakışları 3 sn arayla kurallardan geçirir; saklananların zamanları. Yüzlerce karelik benzetimler saniyelerce CPU
/// tuttuğu için testlerde `offCooperativePool` içinde çalışır.
private func simulatedStores(frames: [ScreenFingerprint]) -> [Double] {
    let policy: ScreenSnapshotPolicy = screenSnapshotPolicy
    var state: ScreenSnapshotState = initialScreenSnapshotState(storedCount: 0)
    var stored: [Double] = []
    for (look, frame) in frames.enumerated() {
        let offset: Double = Double(look + 1) * policy.captureIntervalSec
        let decision: ScreenSnapshotDecision = screenSnapshotDecision(policy: policy, state: state, candidate: frame, offsetSec: offset)
        if decision == .store {
            stored.append(offset)
        }
        state = advancedScreenSnapshotState(policy: policy, state: state, candidate: frame, offsetSec: offset, stored: decision == .store)
    }
    return stored
}

/// Sabit bir sayıdan türeyen sözde rastgele parlaklık (videodaki hareket); her bakışta her hücre farklı.
private func noise(cell: Int, look: Int) -> UInt8 {
    UInt8(truncatingIfNeeded: (cell &* 2_654_435_761 &+ look &* 40_503) >> 7)
}

/// Bir slayt: üst şerit (başlık çubuğu) sabit, gövde her slaytta bütünüyle farklı desen.
private func slideFrame(_ slide: Int) -> ScreenFingerprint {
    ScreenFingerprint(width: screenFingerprintWidth, height: screenFingerprintHeight, luma: (0..<(screenFingerprintWidth * screenFingerprintHeight)).map { (cell: Int) -> UInt8 in
        cell < screenFingerprintWidth * 3 ? 230 : UInt8(((cell * 37 + slide * 101) % 7) * 30 + 20)
    })
}

/// İki parmak izinin ortası (geçiş efektinin yarısı).
private func blend(_ first: ScreenFingerprint, _ second: ScreenFingerprint) -> ScreenFingerprint {
    ScreenFingerprint(width: first.width, height: first.height, luma: zip(first.luma, second.luma).map { UInt8((Int($0.0) + Int($0.1)) / 2) })
}

/// Bölgedeki hücreler `value` ile boyanmış parmak izi.
private func painted(_ base: ScreenFingerprint, region: (x: ClosedRange<Int>, y: ClosedRange<Int>), value: (Int) -> UInt8) -> ScreenFingerprint {
    ScreenFingerprint(width: base.width, height: base.height, luma: base.luma.enumerated().map { (item: (offset: Int, element: UInt8)) -> UInt8 in
        let (x, y): (Int, Int) = (item.offset % base.width, item.offset / base.width)
        return region.x.contains(x) && region.y.contains(y) ? value(item.offset) : item.element
    })
}

/// Haber videosu: oynatıcıda her `cutLooks` bakışta değişen sahne, ortada konuşan yüz ve altta kayan yazı.
private func newsVideo(page: ScreenFingerprint, player: (x: ClosedRange<Int>, y: ClosedRange<Int>), look: Int, cutLooks: Int) -> ScreenFingerprint {
    let shot: Int = look / cutLooks
    let scene: ScreenFingerprint = painted(page, region: player) { UInt8((($0 * 13 + shot * 59) % 9) * 25 + 10) }
    let middleX: Int = (player.x.lowerBound + player.x.upperBound) / 2
    let face: (x: ClosedRange<Int>, y: ClosedRange<Int>) = (x: (middleX - 3)...(middleX + 3), y: (player.y.lowerBound + 2)...(player.y.lowerBound + 7))
    let withFace: ScreenFingerprint = painted(scene, region: face) { noise(cell: $0, look: look) }
    return painted(withFace, region: (x: player.x, y: player.y.upperBound...player.y.upperBound)) { noise(cell: $0, look: look) }
}

/// Kaydırılan belge: her satır kendi deseninde; `scroll` satır yukarı kaymış.
private func documentFrame(scroll: Int) -> ScreenFingerprint {
    ScreenFingerprint(width: screenFingerprintWidth, height: screenFingerprintHeight, luma: (0..<(screenFingerprintWidth * screenFingerprintHeight)).map { (cell: Int) -> UInt8 in
        let row: Int = cell / screenFingerprintWidth + scroll
        return UInt8(((row * 7 + (cell % screenFingerprintWidth) / 8 * 2) % 11) * 20 + 15)
    })
}

@Suite struct ScreenSnapshotTests {
    // Dosya adı kaydın başından geçen milisaniyeyi taşır; başka biçimdeki adlar ve yol parçaları görüntü sayılmaz.
    @Test func fileNamesRoundTripAndRejectOtherNames() {
        let snapshot: ScreenSnapshot = screenSnapshot(offsetSec: 12.4)
        #expect(snapshot.id == "screen-000012400" && snapshot.fileName == "screen-000012400.jpg")
        #expect(screenSnapshot(fileName: snapshot.fileName) == snapshot)
        #expect(screenSnapshot(id: "screen-000012400") == snapshot)
        for name in [".DS_Store", "screen-12400.jpg", "screen-000012400.png", "screen-00001240a.jpg", "../screen-000012400.jpg"] {
            #expect(screenSnapshot(fileName: name) == nil, "\(name)")
        }
        #expect(screenSnapshot(id: "../../etc/passwd") == nil)
    }

    // İlk bakışta beklenir (ekran durulmalı); durgun ve yeni ekran saklanır; az değişen, çabuk gelen ve hâlâ değişen
    // ekran saklanmaz; sınır dolunca durur.
    @Test func decisionStoresSettledMeaningfulChanges() {
        let policy: ScreenSnapshotPolicy = screenSnapshotPolicy
        let slideA: ScreenFingerprint = flat(40)
        let slideB: ScreenFingerprint = flat(200)
        var state: ScreenSnapshotState = initialScreenSnapshotState(storedCount: 0)
        #expect(screenSnapshotDecision(policy: policy, state: state, candidate: slideA, offsetSec: 3) == .unsettled)
        state = advancedScreenSnapshotState(policy: policy, state: state, candidate: slideA, offsetSec: 3, stored: false)
        #expect(screenSnapshotDecision(policy: policy, state: state, candidate: slideA, offsetSec: 6) == .store)
        state = advancedScreenSnapshotState(policy: policy, state: state, candidate: slideA, offsetSec: 6, stored: true)
        #expect(state.storedCount == 1 && state.lastStoredOffsetSec == 6)
        // İmleç ya da birkaç satır: hücrelerin %25'i değişti (yeni ekran için üçte biri gerekir).
        let edited: ScreenFingerprint = partly(base: 40, value: 200, cells: 160)
        state = advancedScreenSnapshotState(policy: policy, state: state, candidate: edited, offsetSec: 30, stored: false)
        #expect(screenSnapshotDecision(policy: policy, state: state, candidate: edited, offsetSec: 33) == .unchanged)
        // Slayt değişiyor (geçiş): önceki bakıştan çok farklı, beklenir.
        #expect(screenSnapshotDecision(policy: policy, state: state, candidate: slideB, offsetSec: 36) == .unsettled)
        state = advancedScreenSnapshotState(policy: policy, state: state, candidate: slideB, offsetSec: 36, stored: false)
        #expect(screenSnapshotDecision(policy: policy, state: state, candidate: slideB, offsetSec: 39) == .store)
        // Son saklanandan 20 sn geçmeden gelen yeni ekran beklenir.
        let recent: ScreenSnapshotState = ScreenSnapshotState(lastStored: slideA, lastStoredOffsetSec: 25, previousCapture: slideB, recentChanges: [], storedCount: 2)
        #expect(screenSnapshotDecision(policy: policy, state: recent, candidate: slideB, offsetSec: 39) == .tooSoon)
        let full: ScreenSnapshotState = ScreenSnapshotState(lastStored: slideA, lastStoredOffsetSec: 0, previousCapture: slideB, recentChanges: [], storedCount: policy.maxPerMeeting)
        #expect(screenSnapshotDecision(policy: policy, state: full, candidate: slideB, offsetSec: 600) == .capReached)
    }

    // Slayt destesi: 45 sn'de bir değişen 8 slaytın (biri geçiş efektli) her biri bir kez saklanır.
    @Test func keepsEverySlideOfADeck() async {
        let stored: [Double] = await offCooperativePool { () -> [Double] in
            let frames: [ScreenFingerprint] = (0..<(8 * 15)).map { (look: Int) -> ScreenFingerprint in
                let slide: Int = look / 15
                // 3. slayda geçişte bir bakış yarı yolda yakalanır (geçiş efekti).
                return look == 45 ? blend(slideFrame(2), slideFrame(3)) : slideFrame(slide)
            }
            return simulatedStores(frames: frames)
        }
        #expect(stored.count == 8, "\(stored)")
        #expect(zip(stored, stored.dropFirst()).allSatisfy { $1 - $0 >= screenSnapshotPolicy.minStoreIntervalSec })
    }

    // Görüşmede paylaşılan slaytlar ve köşede sürekli oynayan kamera kutusu: kutu yok sayılır, 75 sn'lik slaytların her
    // biri yine saklanır (öncekinden 60 sn sonra).
    @Test func keepsSlidesNextToALiveCameraTile() async {
        let stored: [Double] = await offCooperativePool { () -> [Double] in
            let frames: [ScreenFingerprint] = (0..<(6 * 25)).map { (look: Int) -> ScreenFingerprint in
                painted(slideFrame(look / 25), region: (x: 26...31, y: 0...4)) { noise(cell: $0, look: look) }
            }
            return simulatedStores(frames: frames)
        }
        #expect(stored.count == 6)
    }

    // Sayfanın bir bölümünde 9 dk oynayan haber videosu (konuşan yüz, kayan yazı, 15 sn'de bir kesme): sayfa bir kez
    // saklanır, video yeni görüntü üretmez.
    @Test func videoInPartOfTheScreenAddsNoSnapshots() async {
        let stored: [Double] = await offCooperativePool { () -> [Double] in
            let frames: [ScreenFingerprint] = (0..<180).map { (look: Int) -> ScreenFingerprint in
                newsVideo(page: slideFrame(0), player: (x: 4...23, y: 3...15), look: look, cutLooks: 5)
            }
            return simulatedStores(frames: frames)
        }
        #expect(stored.count <= 1)
    }

    // Tam ekran haber videosu (kesmeler 15 ve 30 sn'de bir): en fazla bir iki görüntü.
    @Test func fullScreenVideoAddsFewSnapshots() async {
        for cutLooks in [5, 10] {
            let stored: [Double] = await offCooperativePool { () -> [Double] in
                let frames: [ScreenFingerprint] = (0..<180).map { (look: Int) -> ScreenFingerprint in
                    newsVideo(page: flat(30), player: (x: 0...31, y: 0...19), look: look, cutLooks: cutLooks)
                }
                return simulatedStores(frames: frames)
            }
            #expect(stored.count <= 2, "kesme: \(cutLooks) bakış")
        }
    }

    // Kaydırma: belge kaydırılırken görüntü alınmaz; durunca yeni konum bir kez saklanır.
    @Test func scrollingIsKeptOnlyOnceSettled() async {
        let stored: [Double] = await offCooperativePool { () -> [Double] in
            let frames: [ScreenFingerprint] = (0..<60).map { (look: Int) -> ScreenFingerprint in
                // 10. bakıştan 18. bakışa dek her bakışta iki satır kayar, sonra durur.
                documentFrame(scroll: min(max(0, look - 10), 8) * 2)
            }
            return simulatedStores(frames: frames)
        }
        #expect(stored.count == 2, "\(stored)")
        #expect(stored.last.map { $0 > 18 * screenSnapshotPolicy.captureIntervalSec } ?? false)
    }

    // Boyutu farklı parmak izleri (ör. pencere değişti) tamamen değişmiş sayılır.
    @Test func mismatchedFingerprintsCountAsChanged() {
        let small: ScreenFingerprint = ScreenFingerprint(width: 2, height: 2, luma: [0, 0, 0, 0])
        #expect(changedFraction(from: small, to: flat(0), cellDelta: 18) == 1)
        #expect(changedFraction(from: flat(10), to: flat(20), cellDelta: 18) == 0)
    }

    // Gerçek görüntüden parmak izi: aynı ekran 0, slayt değişimi büyük, küçük bir ayrıntı küçük fark verir.
    @Test func fingerprintFromImagesSeparatesSlidesFromDetails() throws {
        let slide: CGImage = try testImage(width: 1440, height: 900, background: 0.95, box: nil)
        let nextSlide: CGImage = try testImage(width: 1440, height: 900, background: 0.95, box: CGRect(x: 100, y: 100, width: 1000, height: 600))
        let detail: CGImage = try testImage(width: 1440, height: 900, background: 0.95, box: CGRect(x: 700, y: 400, width: 30, height: 20))
        let base: ScreenFingerprint = try screenFingerprint(image: slide)
        #expect(base.luma.count == screenFingerprintWidth * screenFingerprintHeight)
        #expect(changedFraction(from: base, to: try screenFingerprint(image: slide), cellDelta: 18) == 0)
        #expect(changedFraction(from: base, to: try screenFingerprint(image: nextSlide), cellDelta: 18) > 0.4)
        #expect(changedFraction(from: base, to: try screenFingerprint(image: detail), cellDelta: 18) < 0.02)
    }

    // Her görüntü, ekrandayken (bakış aralığı kadar öne alınmış aralıkta) konuşulan paragraflarla eşlenir; sınırdaki
    // paragraf iki görüntüde de görünür; son görüntü toplantının sonuna dek sürer.
    @Test func linksSnapshotsToOverlappingParagraphs() {
        let snapshots: [ScreenSnapshot] = [screenSnapshot(offsetSec: 63), screenSnapshot(offsetSec: 3)]
        let paragraphs: [TranscriptParagraph] = [
            paragraph("a", 0, 10, "Tämä on aloitussivu."),
            paragraph("b", 50, 70, "Siirrytään hinnoitteluun."),
            paragraph("c", 80, 95, "Tämä painike on liian pieni."),
        ]
        let linked: [LinkedScreenSnapshot] = linkScreenSnapshots(snapshots: snapshots, paragraphs: paragraphs, leadSec: 3)
        #expect(linked.map(\.snapshot.offsetSec) == [3, 63])
        #expect(linked[0].startSec == 0 && linked[0].endSec == 60)
        #expect(linked[0].paragraphs.map(\.id) == ["a", "b"])
        #expect(linked[1].startSec == 60 && linked[1].endSec == nil)
        #expect(linked[1].paragraphs.map(\.id) == ["b", "c"])
        let excerpt: String = screenExcerpt(linked: linked[1], speakerNames: [1: "Mikko"], maxChars: 1000)
        #expect(excerpt == "[00:50] Mikko: Siirrytään hinnoitteluun.\n[01:20] Mikko: Tämä painike on liian pieni.")
        #expect(screenExcerpt(linked: linked[1], speakerNames: [:], maxChars: 10).count == 11)
    }

    // Görüşme penceresi seçimi: Zoom'un görüşme penceresi ana penceresine, görüşme sekmesi açık tarayıcı diğer
    // pencerelere tercih edilir; küçük, ekranda olmayan ve üst katmandaki pencereler atlanır; yoksa nil (ana ekran).
    @Test func picksTheMeetingWindow() {
        let zoomHome: ScreenWindowInfo = ScreenWindowInfo(windowID: 1, bundleID: "us.zoom.xos", title: "Zoom Workplace", width: 1200, height: 800, layer: 0, isOnScreen: true)
        let zoomMeeting: ScreenWindowInfo = ScreenWindowInfo(windowID: 2, bundleID: "us.zoom.xos", title: "Zoom Meeting", width: 1000, height: 700, layer: 0, isOnScreen: true)
        let meetTab: ScreenWindowInfo = ScreenWindowInfo(windowID: 3, bundleID: "com.google.Chrome", title: "Meet - abc-defg-hij", width: 1600, height: 1000, layer: 0, isOnScreen: true)
        let docsTab: ScreenWindowInfo = ScreenWindowInfo(windowID: 4, bundleID: "com.google.Chrome", title: "Roadmap - Google Docs", width: 1800, height: 1100, layer: 0, isOnScreen: true)
        let tinyFaceTime: ScreenWindowInfo = ScreenWindowInfo(windowID: 5, bundleID: "com.apple.FaceTime", title: "", width: 200, height: 150, layer: 0, isOnScreen: true)
        let floating: ScreenWindowInfo = ScreenWindowInfo(windowID: 6, bundleID: "us.zoom.xos", title: "Zoom Meeting", width: 1900, height: 1000, layer: 3, isOnScreen: true)
        #expect(meetingWindow(windows: [zoomHome, zoomMeeting, docsTab])?.windowID == 2)
        #expect(meetingWindow(windows: [zoomMeeting, meetTab, docsTab, floating])?.windowID == 3)
        #expect(meetingWindow(windows: [zoomHome, docsTab, tinyFaceTime, floating]) == nil)
    }

    // Yakalama boyutu uzun kenarda sınırlanır, oran korunur, küçük kaynak büyütülmez.
    @Test func captureSizeIsCapped() {
        #expect(screenCaptureSize(width: 3024, height: 1964, maxPixelSize: 1600) == (width: 1600, height: 1039))
        #expect(screenCaptureSize(width: 800, height: 600, maxPixelSize: 1600) == (width: 800, height: 600))
    }

    // Diskte: yazılan görüntüler sıralı listelenir (başka dosyalar atlanır), tek tek ve hepsi birden silinir; klasörü
    // olmayan toplantı boş liste verir.
    @Test func storesListsAndDeletesSnapshots() throws {
        let meeting: URL = try temporaryDirectory()
        #expect(try listScreenSnapshots(meetingDirectory: meeting).isEmpty)
        let image: CGImage = try testImage(width: 640, height: 400, background: 0.5, box: nil)
        let jpeg: Data = try jpegData(image: image, quality: 0.7)
        for offset in [65.0, 3.0, 20.5] {
            try writeScreenSnapshot(meetingDirectory: meeting, snapshot: screenSnapshot(offsetSec: offset), jpeg: jpeg)
        }
        try Data().write(to: screenSnapshotsDirectory(meetingDirectory: meeting).appending(path: ".DS_Store"))
        #expect(try listScreenSnapshots(meetingDirectory: meeting).map(\.offsetSec) == [3, 20.5, 65])
        try deleteScreenSnapshot(meetingDirectory: meeting, snapshot: screenSnapshot(offsetSec: 20.5))
        #expect(try listScreenSnapshots(meetingDirectory: meeting).map(\.offsetSec) == [3, 65])
        try deleteAllScreenSnapshots(meetingDirectory: meeting)
        #expect(!FileManager.default.fileExists(atPath: screenSnapshotsDirectory(meetingDirectory: meeting).path))
        #expect(try listScreenSnapshots(meetingDirectory: meeting).isEmpty)
    }

    // MCP'ye giden görüntü sınırı aşıyorsa sığana dek küçültülür; sığıyorsa dosya olduğu gibi gider.
    @Test func mcpImageIsSizeCapped() throws {
        let meeting: URL = try temporaryDirectory()
        let image: CGImage = try testImage(width: 1600, height: 1000, background: 0.3, box: CGRect(x: 10, y: 10, width: 800, height: 500))
        let jpeg: Data = try jpegData(image: image, quality: 1)
        let snapshot: ScreenSnapshot = screenSnapshot(offsetSec: 1)
        try writeScreenSnapshot(meetingDirectory: meeting, snapshot: snapshot, jpeg: jpeg)
        let file: URL = screenSnapshotFile(meetingDirectory: meeting, snapshot: snapshot)
        #expect(try screenImageForMCP(file: file, maxBytes: jpeg.count) == jpeg)
        let capped: Data = try screenImageForMCP(file: file, maxBytes: jpeg.count / 3)
        #expect(capped.count <= jpeg.count / 3 && capped.starts(with: [0xFF, 0xD8]))
    }

    // Fotoğraflar ekranlarla aynı klasörde `photo-` önekiyle durur: aynı milisaniyede çekilen ikinci fotoğraf bir sonraki
    // boş milisaniyeye yazılır, büyük fotoğraf küçültülür, konum gibi üst veri atılır; nottaki etiketi "Fotoğraf"tır.
    @Test func photosShareThePipelineWithScreens() throws {
        let meeting: URL = try temporaryDirectory()
        try writeScreenSnapshot(
            meetingDirectory: meeting, snapshot: screenSnapshot(offsetSec: 3), jpeg: try jpegData(image: try testImage(width: 64, height: 40, background: 0.5, box: nil), quality: 0.7)
        )
        let photo: Data = try jpegWithLocation(image: try testImage(width: 4000, height: 3000, background: 0.8, box: CGRect(x: 100, y: 100, width: 900, height: 600)))
        let first: ScreenSnapshot = try addMeetingPhoto(meetingDirectory: meeting, offsetSec: 12.4, imageData: photo)
        let second: ScreenSnapshot = try addMeetingPhoto(meetingDirectory: meeting, offsetSec: 12.4, imageData: photo)
        #expect(first.id == "photo-000012400" && second.id == "photo-000012401")
        #expect(first.kind == .photo && screenSnapshot(offsetSec: 3).kind == .screen)
        #expect(screenSnapshot(id: "photo-000012400") == first)
        #expect(try listScreenSnapshots(meetingDirectory: meeting).map(\.id) == ["screen-000003000", "photo-000012400", "photo-000012401"])
        let file: URL = screenSnapshotFile(meetingDirectory: meeting, snapshot: first)
        #expect(try screenImagePixelSize(file: file) == ScreenPixelSize(width: 1600, height: 1200))
        let source: CGImageSource = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties: [CFString: Any] = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(throws: ScreenImageError.self) { try addMeetingPhoto(meetingDirectory: meeting, offsetSec: 1, imageData: Data("not an image".utf8)) }
        let selection: ScreenNoteSelection = ScreenNoteSelection(snapshot: first, startSec: 12.4, endSec: 30, size: ScreenPixelSize(width: 10, height: 10), tokens: 1)
        #expect(screenNoteLabel(index: 1, selection: selection) == "Fotoğraf 2 [00:12–00:30]")
    }

    // Fotoğraf sınırı ekran görüntülerini saymaz; dolunca yenisi reddedilir.
    @Test func photoLimitCountsPhotosOnly() throws {
        let meeting: URL = try temporaryDirectory()
        let small: Data = try jpegData(image: try testImage(width: 8, height: 8, background: 0.5, box: nil), quality: 0.7)
        for index in 0..<maxPhotosPerMeeting {
            try writeScreenSnapshot(meetingDirectory: meeting, snapshot: photoSnapshot(offsetSec: Double(index), existing: []), jpeg: small)
        }
        try writeScreenSnapshot(meetingDirectory: meeting, snapshot: screenSnapshot(offsetSec: 999), jpeg: small)
        #expect(throws: MeetingPhotoError.limitReached(limit: maxPhotosPerMeeting)) {
            try addMeetingPhoto(meetingDirectory: meeting, offsetSec: 500, imageData: small)
        }
    }
}

/// Konum (GPS) üst verisi taşıyan JPEG: telefonun çektiği fotoğraf gibi.
private func jpegWithLocation(image: CGImage) throws -> Data {
    let data: NSMutableData = NSMutableData()
    let destination: CGImageDestination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 60.17, kCGImagePropertyGPSLongitude: 24.94],
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let source: CGImageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties: [CFString: Any] = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyGPSDictionary] != nil)
    return data as Data
}

@Suite struct MCPScreenToolTests {
    // Gerçek stdio döngüsü ve diskteki toplantı: araç listesinde ekran araçları; list_screens görüntüleri ekrandayken
    // konuşulanlarla verir; get_screen görüntüyü (base64 JPEG) ve alıntıyı döndürür; yanlış ve yol içeren kimlik reddedilir.
    @Test func stdioServerListsAndReturnsScreens() throws {
        let sessions: URL = try temporaryDirectory()
        let folder: URL = sessions.appending(path: "20261102-100000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: MeetingRecord = MeetingRecord(
            id: "20261102-100000", title: "Design review", startedAt: Date(timeIntervalSince1970: 1_793_000_000), endedAt: nil, language: .english,
            status: .done, failureMessage: nil, liveSegments: [],
            finalSegments: [
                stored("final-0", .others, 1, 5, "This is the onboarding frame."),
                stored("final-1", .others, 1, 70, "The pricing button is too small."),
            ],
            translations: [:], speakerNames: [1: "Elif"], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        try saveMeeting(record: record, directory: folder)
        let jpeg: Data = try jpegData(image: try testImage(width: 320, height: 200, background: 0.8, box: nil), quality: 0.7)
        try writeScreenSnapshot(meetingDirectory: folder, snapshot: screenSnapshot(offsetSec: 4), jpeg: jpeg)
        try writeScreenSnapshot(meetingDirectory: folder, snapshot: screenSnapshot(offsetSec: 66), jpeg: jpeg)

        let requests: [String] = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_screens","arguments":{"id":"20261102-100000"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_screen","arguments":{"id":"20261102-100000","screen":"screen-000066000"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_screen","arguments":{"id":"20261102-100000","screen":"../meeting"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_screens","arguments":{"id":"../x"}}}"#,
        ]
        let input: Pipe = Pipe()
        let output: Pipe = Pipe()
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        runMCPServer(input: input.fileHandleForReading, output: output.fileHandleForWriting, sessionsDirectories: [sessions], accessDenial: { nil }, version: "test", noteLanguage: .english, appName: "Gistsmith", userName: "")
        try output.fileHandleForWriting.close()
        let lines: [String] = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.count == 5)
        #expect(lines[0].contains("list_screens") && lines[0].contains("get_screen"))
        #expect(lines[1].contains("2 snapshots") && lines[1].contains("screen-000004000") && lines[1].contains("onboarding frame"))
        #expect(lines[1].contains("screen-000066000 — 01:03–end") && lines[1].contains("pricing button"))

        let response: [String: JSONValue] = try JSONDecoder().decode([String: JSONValue].self, from: Data(lines[2].utf8))
        guard case .object(let result) = response["result"], case .array(let content) = result["content"], content.count == 2,
              case .object(let text) = content[0], case .object(let image) = content[1],
              case .string(let excerpt) = text["text"], case .string(let base64) = image["data"] else {
            Issue.record("get_screen yanıtı beklenen biçimde değil: \(lines[2].prefix(300))")
            return
        }
        #expect(result["isError"] == .bool(false))
        #expect(excerpt.contains("Elif: The pricing button is too small.") && !excerpt.contains("onboarding"))
        #expect(image["type"] == .string("image") && image["mimeType"] == .string("image/jpeg"))
        #expect(Data(base64Encoded: base64) == jpeg)
        #expect(lines[3].contains(#""isError":true"#) && lines[3].contains("list_screens"))
        #expect(lines[4].contains(#""isError":true"#) && lines[4].contains("list_meetings"))
    }
}

#if os(macOS)
/// Gerçek ekran görüntüsü testi açık mı: Ekran Kaydı izni olan bir terminalde `AINOTEPAD_SCREEN_TESTS=1`.
private let screenTestsEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_SCREEN_TESTS"] == "1"

/// Sürecin şimdiye dek harcadığı işlemci süresi (kullanıcı + sistem, saniye).
private func processCPUSeconds() -> Double {
    var usage: rusage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let seconds: (timeval) -> Double = { (value: timeval) -> Double in Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

@Suite(.enabled(if: screenTestsEnabled), .serialized)
struct ScreenSnapshotCaptureTests {
    // Gerçek ScreenCaptureKit döngüsü 60 sn: ekran durulunca en az bir görüntü saklanır, JPEG'dir ve bakış ucuzdur
    // (ortalama işlemci kullanımı tek çekirdeğin %3'ünün altında). Görüntüler sonda silinir.
    @MainActor @Test func realCaptureLoopIsCheap() async throws {
        let meeting: URL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: meeting) }
        let recorder: ScreenSnapshotRecorder = ScreenSnapshotRecorder()
        var events: [ScreenSnapshotEvent] = []
        let wallStart: ContinuousClock.Instant = .now
        let cpuStart: Double = processCPUSeconds()
        try recorder.start(meetingDirectory: meeting, timeline: RecordingPauseGate(sampleRate: 16000, origin: .now), policy: screenSnapshotPolicy) { (event: ScreenSnapshotEvent) -> Void in
            events.append(event)
        }
        try await Task.sleep(for: .seconds(60))
        recorder.stop()
        let cpu: Double = processCPUSeconds() - cpuStart
        let wall: Double = (ContinuousClock.now - wallStart) / .seconds(1)
        let percent: Double = cpu / wall * 100
        let stored: [ScreenSnapshot] = try listScreenSnapshots(meetingDirectory: meeting)
        let bytes: [Int] = try stored.map { try Data(contentsOf: screenSnapshotFile(meetingDirectory: meeting, snapshot: $0)).count }
        print("Ekran görüntüsü ölçümü: CPU %\(String(format: "%.2f", percent)) (\(String(format: "%.2f", cpu)) sn / \(Int(wall)) sn), saklanan: \(stored.count), boyutlar: \(bytes)")
        #expect(!stored.isEmpty)
        #expect(events.allSatisfy { if case .stored = $0 { true } else { false } })
        #expect(try stored.allSatisfy { try Data(contentsOf: screenSnapshotFile(meetingDirectory: meeting, snapshot: $0)).starts(with: [0xFF, 0xD8]) })
        #expect(percent < 3)
    }
}
#endif
