import CoreGraphics
import Foundation
import ImageIO

// Disk side of screen snapshots in notes: reads the meeting's snapshots, lets the pure selector (`ScreenNotes.swift`)
// choose, and encodes the chosen ones at their exact selected size. Nothing here decides cost.

/// Whether the note is written with the meeting's screen snapshots (Gistsmith setting "Use screen snapshots in notes").
public enum ScreenNotesPlan: Sendable, Equatable {
    /// Text only (setting off, iPhone, or a provider that does not take images).
    case off
    /// Key snapshots that the user did not untick go with the note request.
    case on
}

/// Snapshots the user unticked for notes; none when the file does not exist. Unreadable file: `readFailed`.
public func readScreenNoteExclusions(meetingDirectory: URL) throws -> Set<String> {
    let file: URL = screenSnapshotsDirectory(meetingDirectory: meetingDirectory).appending(path: screenNoteExclusionsFileName)
    guard FileManager.default.fileExists(atPath: file.path) else {
        return []
    }
    do {
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)))
    } catch {
        throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Saves the unticked snapshots (sorted, atomic); an empty set removes the file. Failure: `writeFailed`.
public func writeScreenNoteExclusions(meetingDirectory: URL, excluded: Set<String>) throws {
    let file: URL = screenSnapshotsDirectory(meetingDirectory: meetingDirectory).appending(path: screenNoteExclusionsFileName)
    do {
        if excluded.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }
        try JSONEncoder().encode(excluded.sorted()).write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Pixel size of an image file from its header (no decoding). Unreadable: `decodingFailed`.
public func screenImagePixelSize(file: URL) throws -> ScreenPixelSize {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0 else {
        throw ScreenImageError.decodingFailed(path: file.path)
    }
    return ScreenPixelSize(width: width, height: height)
}

/// JPEG qualities tried in order until the image fits the byte cap (the pixel size, and so the token cost, stays).
private let screenNoteJPEGQualities: [Double] = [0.7, 0.55, 0.4]

/// The image file redrawn at exactly `size` and encoded as JPEG within `maxBytes`; does not fit at any quality:
/// `encodingFailed`.
public func screenNoteJPEG(file: URL, size: ScreenPixelSize, maxBytes: Int) throws -> Data {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ScreenImageError.decodingFailed(path: file.path)
    }
    guard let context = CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw ScreenImageError.encodingFailed(reason: "CGContext \(size.width)x\(size.height)")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    guard let scaled = context.makeImage() else {
        throw ScreenImageError.encodingFailed(reason: "CGContext.makeImage \(size.width)x\(size.height)")
    }
    for quality in screenNoteJPEGQualities {
        let data: Data = try jpegData(image: scaled, quality: quality)
        if data.count <= maxBytes {
            return data
        }
    }
    throw ScreenImageError.encodingFailed(reason: "\(file.lastPathComponent) at \(size.width)x\(size.height) does not fit in \(maxBytes) bytes")
}

/// Edge of the thumbnail a fingerprint is computed from (the fingerprint itself is 32×20; a larger source measured the
/// same differences).
let screenNoteFingerprintSource: Int = 96

/// The note's screen images: the meeting's snapshots minus the unticked ones, chosen and sized by
/// `selectScreenNoteImages`, each preceded in the prompt by its time label. No snapshots: none. A snapshot that cannot be
/// read fails the note (`ScreenImageError`/`StorageError`) rather than silently writing it without screens.
public func screenNoteImages(record: MeetingRecord, meetingDirectory: URL, budget: ScreenNoteBudget, policy: ScreenSnapshotPolicy) throws -> [LLMImage] {
    let excluded: Set<String> = try readScreenNoteExclusions(meetingDirectory: meetingDirectory)
    let snapshots: [ScreenSnapshot] = try listScreenSnapshots(meetingDirectory: meetingDirectory).filter { !excluded.contains($0.id) }
    guard !snapshots.isEmpty else {
        return []
    }
    var sizes: [String: ScreenPixelSize] = [:]
    var fingerprints: [String: ScreenFingerprint] = [:]
    for snapshot in snapshots {
        let file: URL = screenSnapshotFile(meetingDirectory: meetingDirectory, snapshot: snapshot)
        sizes[snapshot.id] = try screenImagePixelSize(file: file)
        fingerprints[snapshot.id] = try screenFingerprint(image: try downscaledImage(file: file, maxPixelSize: screenNoteFingerprintSource))
    }
    let candidates: [ScreenNoteCandidate] = screenNoteCandidates(
        snapshots: snapshots, paragraphs: transcriptParagraphs(record: record), sizes: sizes, fingerprints: fingerprints, leadSec: policy.captureIntervalSec
    )
    return try selectScreenNoteImages(
        candidates: candidates, excludedIDs: excluded, budget: budget, cellDelta: screenNoteDuplicateCellDelta, duplicateFraction: screenNoteDuplicateFraction
    )
        .enumerated()
        .map { (item: (offset: Int, element: ScreenNoteSelection)) throws -> LLMImage in
            LLMImage(
                label: screenNoteLabel(index: item.offset, selection: item.element),
                jpeg: try screenNoteJPEG(
                    file: screenSnapshotFile(meetingDirectory: meetingDirectory, snapshot: item.element.snapshot), size: item.element.size,
                    maxBytes: budget.maxImageBytes
                )
            )
        }
}
