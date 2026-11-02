import Foundation

/// Ekran görüntüsü araçlarının adları (toplantının klasörünü okurlar; diğer araçlar yalnızca kayıtları).
let mcpScreenToolNames: Set<String> = ["list_screens", "get_screen"]

/// `list_screens`'in bir sayfasındaki en fazla görüntü.
let mcpScreensPageSize: Int = 40

/// `list_screens`'te görüntü başına transkript alıntısının en uzun hâli (karakter).
let mcpScreenListExcerptChars: Int = 1_500

/// `get_screen`'de transkript alıntısının en uzun hâli (karakter).
let mcpScreenExcerptChars: Int = 6_000

/// Araç sonucunun bir içerik parçası.
enum MCPContent: Equatable {
    case text(String)
    /// Base64'e çevrilmeden önceki görüntü verisi ve türü.
    case image(Data, mimeType: String)
}

/// Aracın sonucu: içerik parçaları ve hata mı (MCP `isError`).
struct MCPToolOutput: Equatable {
    let content: [MCPContent]
    let isError: Bool
}

/// Yalnızca metin döndüren aracın sonucu. Saf fonksiyondur.
func textOutput(_ output: (text: String, isError: Bool)) -> MCPToolOutput {
    MCPToolOutput(content: [.text(output.text)], isError: output.isError)
}

/// İçerik parçasının MCP JSON'u (görüntü base64). Saf fonksiyondur.
func contentJSON(_ content: MCPContent) -> JSONValue {
    switch content {
    case .text(let text):
        .object(["type": .string("text"), "text": .string(text)])
    case .image(let data, let mimeType):
        .object(["type": .string("image"), "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)])
    }
}

/// Toplantının bulunduğu klasör: klasör listesinde toplantının adını taşıyan ilk klasör; hiçbirinde yoksa nil.
func existingMeetingDirectory(sessionsDirectories: [URL], meetingID: String) -> URL? {
    sessionsDirectories
        .map { $0.appending(path: meetingID, directoryHint: .isDirectory) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

/// Ekran görüntüsü aracını çalıştırır: toplantı kimliği önce kayıtlarda aranır (istemcinin verdiği değer doğrudan yola
/// girmez), görüntü kimliği biçimi denetlenir. Saf değildir: görüntü klasörünü okur.
func callScreenTool(name: String, arguments: [String: JSONValue], records: [MeetingRecord], meetingDirectory: (String) -> URL?) -> MCPToolOutput {
    guard case .string(let meetingID) = arguments["id"] else {
        return textOutput(("id is required", true))
    }
    guard let record = records.first(where: { $0.id == meetingID }) else {
        return textOutput(("No meeting with id \(meetingID). Use list_meetings.", true))
    }
    guard let directory = meetingDirectory(record.id) else {
        return textOutput(("Meeting \(meetingID) has no folder on this Mac.", true))
    }
    let snapshots: [ScreenSnapshot]
    do {
        snapshots = try listScreenSnapshots(meetingDirectory: directory)
    } catch {
        return textOutput(("Screens of meeting \(meetingID) could not be read: \(error)", true))
    }
    let linked: [LinkedScreenSnapshot] = linkScreenSnapshots(
        snapshots: snapshots, paragraphs: transcriptParagraphs(record: record), leadSec: screenSnapshotPolicy.captureIntervalSec
    )
    switch name {
    case "list_screens":
        let offset: Int = if case .number(let value) = arguments["offset"], value.isFinite { Int(min(max(value, 0), 100_000)) } else { 0 }
        return textOutput((screenListText(record: record, linked: linked, offset: offset), false))
    case "get_screen":
        guard case .string(let screenID) = arguments["screen"], let wanted = screenSnapshot(id: screenID),
              let match = linked.first(where: { $0.snapshot == wanted }) else {
            return textOutput(("No such screen in meeting \(meetingID). Use list_screens for the screen ids.", true))
        }
        let image: Data
        do {
            image = try screenImageForMCP(file: screenSnapshotFile(meetingDirectory: directory, snapshot: match.snapshot), maxBytes: mcpScreenMaxBytes)
        } catch {
            return textOutput(("Screen \(screenID) could not be read: \(error)", true))
        }
        let excerpt: String = screenExcerpt(linked: match, speakerNames: record.speakerNames, maxChars: mcpScreenExcerptChars)
        return MCPToolOutput(
            content: [.text("\(screenHeading(linked: match))\n\(excerpt.isEmpty ? "(no speech while this was on screen)" : excerpt)"), .image(image, mimeType: "image/jpeg")],
            isError: false
        )
    default:
        return textOutput(("Unknown tool: \(name)", true))
    }
}

/// Görüntünün başlık satırı: kimlik ve ekranda kaldığı aralık. Saf fonksiyondur.
private func screenHeading(linked: LinkedScreenSnapshot) -> String {
    "## \(linked.snapshot.id) — \(timestamp(seconds: linked.startSec))–\(linked.endSec.map { timestamp(seconds: $0) } ?? "end")"
}

/// `list_screens` metni: toplantı, açıklama ve bir sayfa görüntü (başlık ve alıntı); sonraki sayfa varsa nasıl
/// isteneceği. Saf fonksiyondur.
func screenListText(record: MeetingRecord, linked: [LinkedScreenSnapshot], offset: Int) -> String {
    guard !linked.isEmpty else {
        return "Meeting \(record.id) has no screen snapshots (screen snapshots were off, nothing was shared, or they were deleted)."
    }
    let page: ArraySlice<LinkedScreenSnapshot> = linked.dropFirst(offset).prefix(mcpScreensPageSize)
    let header: String = "Screens of \"\(record.note?.title ?? record.title)\" (id: \(record.id)): \(linked.count) snapshots. Times are offsets from the start of the recording; each was on screen until the next one. Use get_screen with a screen id to see the image."
    let blocks: [String] = page.map { (item: LinkedScreenSnapshot) -> String in
        let excerpt: String = screenExcerpt(linked: item, speakerNames: record.speakerNames, maxChars: mcpScreenListExcerptChars)
        return "\(screenHeading(linked: item))\n\(excerpt.isEmpty ? "(no speech while this was on screen)" : excerpt)"
    }
    let shown: Int = offset + page.count
    let more: [String] = shown < linked.count ? ["\(linked.count - shown) more: call list_screens with offset \(shown)."] : []
    return ([header] + blocks + more).joined(separator: "\n\n")
}
