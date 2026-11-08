import CoreGraphics
import Foundation
import ImageIO

// Photos the user takes during or after a meeting (whiteboard, slide, a sketch on paper): stored next to the screen
// snapshots (`Screens/photo-<ms>.jpg`), so the note, Ask, MCP and the Screens tab read them the same way.

/// At most this many photos per meeting (screens have their own cap, `ScreenSnapshotPolicy.maxPerMeeting`).
public let maxPhotosPerMeeting: Int = 60

/// Adding a photo failed.
public enum MeetingPhotoError: Error, Equatable {
    /// The meeting already has `maxPhotosPerMeeting` photos.
    case limitReached(limit: Int)
}

/// The photo as it is stored: upright (EXIF orientation applied), at most `maxPixelSize` on the long edge, re-encoded as
/// JPEG. Re-encoding from the decoded pixels drops the original's metadata (location, device, time), so no GPS position
/// leaves with the image. Unreadable data: `ScreenImageError.decodingFailed`.
public func meetingPhotoJPEG(imageData: Data, maxPixelSize: Int, quality: Double) throws -> Data {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          ] as CFDictionary) else {
        throw ScreenImageError.decodingFailed(path: "photo (\(imageData.count) bytes)")
    }
    return try jpegData(image: image, quality: quality)
}

/// Stores a photo in the meeting's folder at `offsetSec` on the recording's timeline (the moment it was taken; after the
/// meeting, its end) and returns it. Full: `MeetingPhotoError.limitReached`; unreadable image: `ScreenImageError`;
/// unwritable folder: `StorageError`.
public func addMeetingPhoto(meetingDirectory: URL, offsetSec: Double, imageData: Data) throws -> ScreenSnapshot {
    let existing: [ScreenSnapshot] = try listScreenSnapshots(meetingDirectory: meetingDirectory)
    guard existing.filter({ $0.kind == .photo }).count < maxPhotosPerMeeting else {
        throw MeetingPhotoError.limitReached(limit: maxPhotosPerMeeting)
    }
    let jpeg: Data = try meetingPhotoJPEG(imageData: imageData, maxPixelSize: screenSnapshotPolicy.maxPixelSize, quality: screenSnapshotPolicy.jpegQuality)
    let snapshot: ScreenSnapshot = photoSnapshot(offsetSec: offsetSec, existing: existing)
    try writeScreenSnapshot(meetingDirectory: meetingDirectory, snapshot: snapshot, jpeg: jpeg)
    return snapshot
}

/// Where on the recording's timeline a photo taken after the meeting goes: the end of the last thing said (it belongs to
/// the end of the meeting, not its start). No transcript: 0. Pure function.
public func photoOffsetAfterMeeting(record: MeetingRecord) -> Double {
    transcriptParagraphs(record: record).map(\.endSec).max() ?? 0
}

/// The user-facing text when a photo can't be added (Mac and iPhone).
public func meetingPhotoErrorMessage(error: any Error) -> String {
    switch error {
    case MeetingPhotoError.limitReached(let limit):
        String(localized: "Bu toplantıya en fazla \(limit) fotoğraf eklenebilir.")
    case is ScreenImageError:
        String(localized: "Fotoğraf okunamadı; başka bir görüntü dene.")
    default:
        String(localized: "Fotoğraf eklenemedi: \(userFacingMessage(error: error))")
    }
}
