import AINotepadCore
import Foundation

// Öğrenci veri seti (`SeedPersona.lectures`): masaya konmuş iPhone'la kaydedilmiş dersler, bir seminer ve bir çalışma
// grubu; "students-lectures" özel ürün sayfasının çekimleri. Notlar "Ders / eğitim" şablonuyla yazılmış gibidir.

/// "Cognitive Psychology · Memory" dersinin başlangıcı (bugün sabah); sahne bu dersin notunu açar.
func memoryLectureStart(now: Date, calendar: Calendar) -> Date {
    seedDate(now: now, calendar: calendar, days: 0, hour: 8, minute: 15)
}

/// "Cognitive Psychology · Attention" dersinin başlangıcı (bir hafta önce); Sor cevabının ikinci kaynağı.
func attentionLectureStart(now: Date, calendar: Calendar) -> Date {
    seedDate(now: now, calendar: calendar, days: 7, hour: 8, minute: 15)
}

/// Dersler (yeniden eskiye). Saf fonksiyondur.
func lectureMeetings(now: Date, calendar: Calendar) -> [SeedMeeting] {
    [
        SeedMeeting(
            title: "Cognitive Psychology · Memory", startedAt: memoryLectureStart(now: now, calendar: calendar), minutes: 88,
            folder: "Cognitive Psychology", people: [1: "Dr. Novak", 2: "Jamie"], attendees: ["Dr. Hana Novak"],
            lines: [
                SeedLine(person: 1, start: 6, text: "Today we move from attention to memory: how information gets in, how it stays, and why we forget."),
                SeedLine(person: 1, start: 21, text: "Working memory holds about four chunks at a time. Baddeley's model splits it into a phonological loop, a visuospatial sketchpad and a central executive."),
                SeedLine(person: 2, start: 302, text: "Is the episodic buffer part of the same model?"),
                SeedLine(person: 1, start: 309, text: "Yes, Baddeley added it in 2000. It links working memory to long-term memory."),
                SeedLine(person: 1, start: 1460, text: "Ebbinghaus showed that we forget fastest in the first day. Spaced retrieval flattens that curve."),
                SeedLine(person: 1, start: 4980, text: "For the exam: the multiple-choice part covers chapters five to eight, and there is one essay question on working memory."),
                SeedLine(person: 1, start: 5010, text: "Read chapter seven before Thursday, and the lab report on the recall experiment is due on the twenty-first."),
            ],
            summary: "Working memory holds about four chunks and, in Baddeley's model, has a phonological loop, a visuospatial sketchpad, a central executive and (since 2000) an episodic buffer. Forgetting is fastest in the first day (Ebbinghaus); spaced retrieval slows it. The exam covers chapters 5 to 8 with one essay question on working memory.",
            decisions: [
                "Exam: multiple choice on chapters 5 to 8, plus one essay on working memory.",
                "The lab report on the recall experiment is due on the 21st.",
            ],
            tasks: [
                mine(description: "Read chapter 7 (pp. 210–245)", due: "Thursday"),
                mine(description: "Finish the recall experiment lab report", due: "The 21st"),
                mine(description: "Make flashcards for Baddeley's model", due: nil),
                mine(description: "Revise chapters 5 to 8 for the exam", due: "Before the exam"),
            ],
            glossary: [
                GlossaryEntry(term: "Working memory", meaning: "A short-term store that holds and manipulates about four chunks at a time."),
                GlossaryEntry(term: "Central executive", meaning: "The part of working memory that directs attention between the other parts."),
                GlossaryEntry(term: "Episodic buffer", meaning: "Links working memory to long-term memory; added to the model in 2000."),
                GlossaryEntry(term: "Spaced retrieval", meaning: "Recalling material at growing intervals to slow forgetting."),
            ],
            outline: [
                OutlineItem(startSec: 6, title: "Working memory", summary: "About four chunks; Baddeley's multi-component model."),
                OutlineItem(startSec: 302, title: "Episodic buffer", summary: "Added in 2000; links working and long-term memory."),
                OutlineItem(startSec: 1460, title: "Forgetting curve", summary: "Fastest loss in the first day; spaced retrieval helps."),
                OutlineItem(startSec: 4980, title: "Exam and deadlines", summary: "Chapters 5 to 8, one essay; lab report due on the 21st."),
            ],
            doneTasks: [],
            template: .lecture
        ),
        SeedMeeting(
            title: "Statistics II · Regression", startedAt: seedDate(now: now, calendar: calendar, days: 1, hour: 13, minute: 0), minutes: 75,
            folder: "Statistics II", people: [1: "Prof. Lindqvist"], attendees: ["Prof. Erik Lindqvist"],
            lines: [
                SeedLine(person: 1, start: 5, text: "Linear regression fits the line that minimises the squared errors."),
                SeedLine(person: 1, start: 840, text: "R squared tells you how much of the variance the model explains, not whether the model is right."),
                SeedLine(person: 1, start: 4300, text: "Problem set four is due next Monday. Use the housing data set from the course page."),
            ],
            summary: "Least-squares regression, how to read coefficients and why R² measures explained variance rather than correctness.",
            decisions: ["Problem set 4 uses the housing data set."],
            tasks: [mine(description: "Hand in problem set 4", due: "Monday")],
            glossary: [GlossaryEntry(term: "R²", meaning: "The share of the variance the model explains.")],
            outline: [OutlineItem(startSec: 5, title: "Least squares", summary: "The line that minimises squared errors.")],
            doneTasks: [],
            template: .lecture
        ),
        SeedMeeting(
            title: "Study group · Statistics", startedAt: seedDate(now: now, calendar: calendar, days: 2, hour: 17, minute: 0), minutes: 60,
            folder: "Statistics II", people: [1: "Jamie", 2: "Noor"], attendees: ["Jamie Lee", "Noor Haddad"],
            lines: [
                SeedLine(person: 1, start: 4, text: "Let's split problem set four: I take questions one and two."),
                SeedLine(person: 2, start: 12, text: "I'll do three, and we check the regression output together on Sunday."),
            ],
            summary: "The group split problem set 4 and meets again on Sunday to check the regression output.",
            decisions: ["Meet on Sunday to compare answers."],
            tasks: [mine(description: "Do questions 4 and 5 of the problem set", due: "Sunday")],
            glossary: [],
            outline: [OutlineItem(startSec: 4, title: "Problem set 4", summary: "Questions split three ways.")],
            doneTasks: [],
            template: .lecture
        ),
        SeedMeeting(
            title: "Research Methods seminar", startedAt: seedDate(now: now, calendar: calendar, days: 4, hour: 10, minute: 0), minutes: 90,
            folder: "Research Methods", people: [1: "Dr. Okoye", 2: "Noor"], attendees: ["Dr. Ada Okoye"],
            lines: [
                SeedLine(person: 1, start: 8, text: "A good research question is narrow enough to answer and broad enough to matter."),
                SeedLine(person: 2, start: 400, text: "Can we use a survey and interviews in the same project?"),
                SeedLine(person: 1, start: 410, text: "Yes, that's a mixed-methods design. Say why you need both."),
            ],
            summary: "How to narrow a research question, and when a mixed-methods design (survey plus interviews) is justified.",
            decisions: ["Proposals are due in week 9."],
            tasks: [mine(description: "Draft the research question for the proposal", due: "Week 9")],
            glossary: [GlossaryEntry(term: "Mixed methods", meaning: "Combining quantitative and qualitative data in one study.")],
            outline: [OutlineItem(startSec: 8, title: "Research questions", summary: "Narrow enough to answer, broad enough to matter.")],
            doneTasks: [],
            template: .lecture
        ),
        SeedMeeting(
            title: "Cognitive Psychology · Attention", startedAt: attentionLectureStart(now: now, calendar: calendar), minutes: 85,
            folder: "Cognitive Psychology", people: [1: "Dr. Novak"], attendees: ["Dr. Hana Novak"],
            lines: [
                SeedLine(person: 1, start: 6, text: "Attention is a filter. Broadbent put the filter early; Treisman showed it only weakens what we ignore."),
                SeedLine(person: 1, start: 5000, text: "A reminder about the midterm: no notes allowed, but you can bring a calculator. Past papers are on the course page."),
            ],
            summary: "Early-selection (Broadbent) and attenuation (Treisman) models of attention, and the cocktail-party effect. Midterm rules: no notes, calculators allowed; past papers are online.",
            decisions: ["Midterm: closed book, calculators allowed."],
            tasks: [
                mine(description: "Do two past exam papers", due: "Before the exam"),
                mine(description: "Summarise Treisman's attenuation model", due: nil),
            ],
            glossary: [GlossaryEntry(term: "Attenuation", meaning: "Treisman's idea that ignored input is weakened, not blocked.")],
            outline: [OutlineItem(startSec: 6, title: "Filter models", summary: "Broadbent's early filter versus Treisman's attenuation.")],
            doneTasks: ["Summarise Treisman's attenuation model"],
            template: .lecture
        ),
        SeedMeeting(
            title: "Microeconomics · Market failure", startedAt: seedDate(now: now, calendar: calendar, days: 8, hour: 14, minute: 0), minutes: 80,
            folder: "Microeconomics", people: [1: "Dr. Russo"], attendees: ["Dr. Paolo Russo"],
            lines: [
                SeedLine(person: 1, start: 5, text: "An externality is a cost or benefit that falls on someone outside the transaction."),
            ],
            summary: "Externalities, public goods and why markets under-supply them; Pigouvian taxes as one fix.",
            decisions: [],
            tasks: [mine(description: "Read the case study on carbon pricing", due: "Next lecture")],
            glossary: [GlossaryEntry(term: "Externality", meaning: "A cost or benefit that falls on someone outside the transaction.")],
            outline: [OutlineItem(startSec: 5, title: "Externalities", summary: "Costs and benefits outside the transaction.")],
            doneTasks: [],
            template: .lecture
        ),
    ]
}

/// Sınav sorusu ve iki dersten kaynaklı cevabı. Saf fonksiyondur.
func lectureAskConversation(now: Date, calendar: Calendar) -> AskConversation {
    let memoryStart: Date = memoryLectureStart(now: now, calendar: calendar)
    let attentionStart: Date = attentionLectureStart(now: now, calendar: calendar)
    let zone: TimeZone = calendar.timeZone
    let sources: [ArchivePassage] = [
        seedPassage(
            id: "seed-1", title: "Cognitive Psychology · Memory", start: memoryStart, kind: .transcript, startSec: 4980,
            text: "For the exam: the multiple-choice part covers chapters five to eight, and there is one essay question on working memory.",
            timeZone: zone
        ),
        seedPassage(
            id: "seed-2", title: "Cognitive Psychology · Memory", start: memoryStart, kind: .note, startSec: 0,
            text: "Working memory holds about four chunks and, in Baddeley's model, has a phonological loop, a visuospatial sketchpad, a central executive and an episodic buffer.",
            timeZone: zone
        ),
        seedPassage(
            id: "seed-3", title: "Cognitive Psychology · Attention", start: attentionStart, kind: .transcript, startSec: 5000,
            text: "No notes allowed, but you can bring a calculator. Past papers are on the course page.", timeZone: zone
        ),
    ]
    let answer: String = """
    Dr. Novak mentioned the exam in two lectures:

    - **Multiple choice on chapters 5 to 8**, plus **one essay question on working memory** [1].
    - For the essay, know Baddeley's model: the phonological loop, the visuospatial sketchpad, the central executive and the episodic buffer [2].
    - **No notes allowed**, but you can bring a calculator. Past papers are on the course page [3].
    """
    return seedAskConversation(
        question: "What did the lecturer say about the exam?", answer: answer, terms: ["exam", "essay", "chapters", "past papers"],
        sources: sources, now: now
    )
}
