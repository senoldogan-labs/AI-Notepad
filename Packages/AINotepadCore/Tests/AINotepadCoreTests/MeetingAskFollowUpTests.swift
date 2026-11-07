import Foundation
import Testing
@testable import AINotepadCore

private let askedAt: Date = Date(timeIntervalSince1970: 1_792_000_000)

/// Bitmiş bir tur: verilen toplantılara sorulmuş.
private func turn(question: String, scope: [String]) -> AskConversationTurn {
    AskConversationTurn(
        id: UUID(), question: question, scopeMeetingIDs: scope, scopeTitles: scope, recipeTitle: nil, startedAt: askedAt,
        finishedAt: askedAt.addingTimeInterval(5), terms: [], readPassages: [], readScreens: nil, answer: "Cevap.", sources: [],
        webSources: nil, webQueries: nil, webSearchNotice: nil
    )
}

/// Turları verilen anda güncellenmiş sohbet.
private func chat(turns: [AskConversationTurn], at offset: TimeInterval) -> AskConversation {
    askConversation(existing: nil, id: UUID(), turns: turns, now: askedAt.addingTimeInterval(offset))
}

/// Toplantı sayfasının sohbeti: turlarının hepsi yalnız o toplantıya sorulmuş en yeni sohbet; arşive ya da birden çok
/// toplantıya sorulan sohbet sayfaya gelmez.
@Test func meetingPageResumesTheNewestChatAskedOnlyAboutThatMeeting() {
    let older: AskConversation = chat(turns: [turn(question: "Kim ne dedi?", scope: ["a"])], at: 0)
    let newer: AskConversation = chat(turns: [turn(question: "Karar?", scope: ["a"])], at: 60)
    let mixed: AskConversation = chat(turns: [turn(question: "Karar?", scope: ["a"]), turn(question: "Ya diğeri?", scope: ["a", "b"])], at: 120)
    let archive: AskConversation = chat(turns: [turn(question: "Bu hafta?", scope: [])], at: 180)
    let all: [AskConversation] = [older, archive, mixed, newer]
    #expect(latestMeetingConversation(conversations: all, meetingID: "a")?.id == newer.id)
    #expect(latestMeetingConversation(conversations: all, meetingID: "b") == nil)
    #expect(latestMeetingConversation(conversations: [chat(turns: [], at: 0)], meetingID: "a") == nil)
}

/// Devam soruları: cevap bitince en çok üç tane, notun içeriğine göre; sorulmuş olan yinelenmez; cevap akarken ya da
/// sohbet boşken yok.
@Test func followUpSuggestionsComeFromTheNoteAndSkipAskedOnes() {
    let note: MeetingNote = MeetingNote(
        title: "Weekly", summary: "Beta.", decisions: ["Beta opens."], tasks: [NoteTask(owner: "Elif", description: "Fix", dueDate: nil, isMine: false)],
        glossary: []
    )
    let first: [String] = meetingFollowUpSuggestions(note: note, askedQuestions: ["Kararlar?"], lastAnswerFinished: true)
    #expect(first.count == meetingFollowUpLimit)
    #expect(first.contains(String(localized: "Bu kararlara nasıl varıldı?")))
    let afterAsking: [String] = meetingFollowUpSuggestions(note: note, askedQuestions: ["Kararlar?", first[0]], lastAnswerFinished: true)
    #expect(!afterAsking.contains(first[0]))
    #expect(afterAsking.count == meetingFollowUpLimit)
    #expect(meetingFollowUpSuggestions(note: note, askedQuestions: ["Kararlar?"], lastAnswerFinished: false).isEmpty)
    #expect(meetingFollowUpSuggestions(note: note, askedQuestions: [], lastAnswerFinished: true).isEmpty)
    // Kararsız, açık konusuz, görevsiz notta yalnız iki genel öneri.
    let bare: MeetingNote = MeetingNote(title: "T", summary: "S.", decisions: [], tasks: [], glossary: [])
    #expect(meetingFollowUpSuggestions(note: bare, askedQuestions: ["?"], lastAnswerFinished: true).count == 2)
}
