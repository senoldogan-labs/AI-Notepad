import Foundation
import Testing
@testable import AINotepadCore

@Suite struct AskScreensTests {
    // Ranking: the snapshots overlapping the read passages longest win; at most 3 and 1,350 visual tokens whatever the
    // input; a near-identical screen goes once; the result keeps the passages' order; no overlap, no image.
    @Test func selectionPrefersOverlapAndStaysWithinTheBudget() {
        let candidates: [AskScreenCandidate] = (0..<12).map { (index: Int) -> AskScreenCandidate in
            AskScreenCandidate(
                meetingID: index < 6 ? "a" : "b", meetingTitle: index < 6 ? "A" : "B",
                candidate: screenCandidate(index: index, speechChars: 100, width: 3200, height: 2000, fingerprint: seededFingerprint(seed: index)),
                overlapSec: [0, 5, 40, 12, 40, 3, 30, 0, 1, 2, 4, 6][index]
            )
        }
        let chosen: [AskScreenSelection] = selectAskScreens(
            candidates: candidates, budget: askScreenBudget, cellDelta: screenNoteDuplicateCellDelta, duplicateFraction: screenNoteDuplicateFraction
        )
        #expect(chosen.map(\.selection.startSec) == [20, 40, 60])
        #expect(chosen.map(\.meetingID) == ["a", "a", "b"])
        #expect(chosen.reduce(0) { $0 + $1.selection.tokens } <= 1_350)
        #expect(askScreenBudget.maxTotalTokens <= 1_400 && askScreenBudget.maxImages == 3)
        // The same screen shown again (same fingerprint) is sent once: the next best one takes its place.
        let repeated: [AskScreenCandidate] = candidates.enumerated().map { (item: (offset: Int, element: AskScreenCandidate)) -> AskScreenCandidate in
            guard item.offset == 4 else {
                return item.element
            }
            return AskScreenCandidate(
                meetingID: "a", meetingTitle: "A",
                candidate: screenCandidate(index: 4, speechChars: 100, width: 3200, height: 2000, fingerprint: seededFingerprint(seed: 2)), overlapSec: 40
            )
        }
        let deduplicated: [AskScreenSelection] = selectAskScreens(
            candidates: repeated, budget: askScreenBudget, cellDelta: screenNoteDuplicateCellDelta, duplicateFraction: screenNoteDuplicateFraction
        )
        #expect(deduplicated.map(\.selection.startSec) == [20, 30, 60])
        let none: [AskScreenCandidate] = candidates.map { AskScreenCandidate(meetingID: $0.meetingID, meetingTitle: $0.meetingTitle, candidate: $0.candidate, overlapSec: 0) }
        #expect(selectAskScreens(candidates: none, budget: askScreenBudget, cellDelta: screenNoteDuplicateCellDelta, duplicateFraction: screenNoteDuplicateFraction).isEmpty)
    }

    // From disk: for one read transcript passage, only snapshots on screen while it was spoken go, at most 3, within the
    // token and byte caps, labelled with the meeting and time; unticked ones never go; a note passage, a meeting
    // without a folder or the plan off give none.
    @Test func imagesFollowTheReadPassages() throws {
        let meeting: URL = try temporaryDirectory()
        let record: MeetingRecord = screenNotesMeeting(seconds: 1_900)
        for index in 0..<31 {
            try writeTestSlide(meetingDirectory: meeting, offsetSec: Double(index) * 60 + 5, index: index, width: 1600, height: 1000)
        }
        let transcript: [ArchivePassage] = archivePassages(records: [record]).filter { $0.kind == .transcript }
        let read: ArchivePassage = transcript[2]
        let span: (start: Double, end: Double) = try #require(transcriptPassageSpans(record: record, passageIDs: [read.id]).first)
        let overlapping: [AskScreenSpan] = askScreenSpans(record: record, passageIDs: [read.id], snapshots: try listScreenSnapshots(meetingDirectory: meeting), leadSec: 3)
        #expect(overlapping.count > 3)
        #expect(overlapping.allSatisfy { $0.startSec < span.end && $0.endSec > span.start })
        // The best overlapping one is unticked for notes: it does not go to Ask either.
        let unticked: ScreenSnapshot = try #require(overlapping.max { $0.overlapSec < $1.overlapSec }?.snapshot)
        try writeScreenNoteExclusions(meetingDirectory: meeting, excluded: [unticked.id])
        let plan: ArchiveScreensPlan = .on(meetingDirectories: [record.id: meeting])
        let images: [LLMImage] = try askScreenImages(records: [record], passages: [read], plan: plan, budget: askScreenBudget, policy: screenSnapshotPolicy)
        #expect(images.count == 3)
        var tokens: Int = 0
        for image in images {
            let size: ScreenPixelSize = try jpegPixelSize(image.jpeg)
            tokens += screenVisualTokens(width: size.width, height: size.height)
            #expect(image.jpeg.count <= askScreenBudget.maxImageBytes)
            #expect(image.label.hasPrefix("Ekran ") && image.label.contains("\"m\""))
        }
        #expect(tokens <= askScreenBudget.maxTotalTokens)
        #expect(!images.contains { $0.label.contains("[\(timestamp(seconds: max(0, unticked.offsetSec - 3)))–") })
        #expect(try askScreenImages(records: [record], passages: [read], plan: .off, budget: askScreenBudget, policy: screenSnapshotPolicy).isEmpty)
        #expect(try askScreenImages(records: [record], passages: [read], plan: .on(meetingDirectories: [:]), budget: askScreenBudget, policy: screenSnapshotPolicy).isEmpty)
        let note: ArchivePassage = ArchivePassage(
            id: "m-note", meetingID: "m", meetingTitle: "m", meetingDate: record.startedAt, kind: .note, startSec: 0, text: "Özet: …"
        )
        #expect(try askScreenImages(records: [record], passages: [note], plan: plan, budget: askScreenBudget, policy: screenSnapshotPolicy).isEmpty)
    }

    // The answer request carries the images and the screen rule only when there are images.
    @Test func answerRequestCarriesScreensOnlyWhenGiven() {
        let image: LLMImage = LLMImage(label: "Ekran 1 · \"m\" [00:00–01:00]", jpeg: Data([0xFF, 0xD8]))
        let with: LLMRequest = archiveAnswerRequest(
            question: "Slaytta ne vardı?", passages: [], screens: [image], history: [], userName: "", now: Date(timeIntervalSince1970: 0), language: .turkish, webSearch: false
        )
        let without: LLMRequest = archiveAnswerRequest(
            question: "Slaytta ne vardı?", passages: [], screens: [], history: [], userName: "", now: Date(timeIntervalSince1970: 0), language: .turkish, webSearch: false
        )
        #expect(with.images == [image] && with.purpose == .askAnswer && with.system.contains("ekranın birkaç görüntüsü"))
        #expect(without.images.isEmpty && !without.system.contains("ekranın birkaç görüntüsü"))
    }
}
