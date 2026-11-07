import AINotepadCore
import Foundation

// Görüşme veri seti (`SeedPersona.interviews`): yüz yüze kullanıcı araştırması görüşmeleri ve bir işe alım görüşmesi;
// "interviews-research" özel ürün sayfasının çekimleri. Görüşmeyi yapan kullanıcıdır (konuşmacı nil).

/// Sara'yla görüşmenin başlangıcı (bugün sabah); sahne bu görüşmenin notunu açar.
func saraInterviewStart(now: Date, calendar: Calendar) -> Date {
    seedDate(now: now, calendar: calendar, days: 0, hour: 8, minute: 30)
}

/// Tom'la görüşmenin başlangıcı (iki gün önce).
func tomInterviewStart(now: Date, calendar: Calendar) -> Date {
    seedDate(now: now, calendar: calendar, days: 2, hour: 15, minute: 0)
}

/// Priya'yla görüşmenin başlangıcı (dört gün önce).
func priyaInterviewStart(now: Date, calendar: Calendar) -> Date {
    seedDate(now: now, calendar: calendar, days: 4, hour: 11, minute: 0)
}

/// Görüşmeler (yeniden eskiye). Saf fonksiyondur.
func interviewMeetings(now: Date, calendar: Calendar) -> [SeedMeeting] {
    [
        SeedMeeting(
            title: "User interview · Sara (P5)", startedAt: saraInterviewStart(now: now, calendar: calendar), minutes: 48,
            folder: "Pricing study", people: [1: "Sara"], attendees: ["Sara Nilsson"],
            lines: [
                SeedLine(person: nil, start: 4, text: "Thanks for meeting in person. Walk me through the last time you planned a trip with friends."),
                SeedLine(person: 1, start: 12, text: "We had a group chat with forty messages and nobody knew who had paid for what."),
                SeedLine(person: 1, start: 610, text: "Honestly, I'd pay for it if one person pays and everyone else just joins for free."),
                SeedLine(person: nil, start: 622, text: "What would feel like a fair price for that person?"),
                SeedLine(person: 1, start: 630, text: "Per trip, maybe five euros. A monthly subscription would put me off; we only travel twice a year."),
                SeedLine(person: 1, start: 1500, text: "The shared expense list is the part I'd actually use every day of the trip."),
            ],
            summary: "Sara plans two group trips a year and loses track of who paid for what in the group chat. She would pay about €5 per trip if one person pays and the others join free, and a monthly subscription would put her off. The shared expense list is the feature she would use daily.",
            decisions: ["Pricing: per-trip price, payer only (Sara's preference)."],
            tasks: [
                mine(description: "Add Sara's quotes to the pricing synthesis", due: "Today"),
                mine(description: "Send Sara the thank-you voucher", due: "Tomorrow"),
                theirs(owner: "Lena", description: "Prototype a per-trip checkout", due: "Next week"),
            ],
            glossary: [
                GlossaryEntry(term: "P5", meaning: "Participant 5 in the pricing study."),
                GlossaryEntry(term: "Payer-only model", meaning: "One person pays; the rest of the group joins free."),
            ],
            outline: [
                OutlineItem(startSec: 4, title: "Last group trip", summary: "Forty-message chat; nobody knew who had paid."),
                OutlineItem(startSec: 610, title: "Pricing", summary: "About €5 per trip, paid by one person; no subscription."),
                OutlineItem(startSec: 1500, title: "Most useful feature", summary: "The shared expense list, used every day."),
            ],
            doneTasks: [],
            template: .custom
        ),
        SeedMeeting(
            title: "User interview · Tom (P4)", startedAt: tomInterviewStart(now: now, calendar: calendar), minutes: 41,
            folder: "Pricing study", people: [1: "Tom"], attendees: ["Tom Becker"],
            lines: [
                SeedLine(person: 1, start: 9, text: "I organise the ski trip every year, so I'm the one chasing people for money."),
                SeedLine(person: 1, start: 720, text: "A yearly plan would be fine for me, because I organise trips all the time. Ten, maybe fifteen euros a year."),
            ],
            summary: "Tom organises trips often and would accept a yearly plan at €10 to €15. He is the person who chases others for money.",
            decisions: [],
            tasks: [mine(description: "Tag Tom's quotes in the synthesis board", due: nil)],
            glossary: [],
            outline: [OutlineItem(startSec: 720, title: "Pricing", summary: "Yearly plan at €10 to €15 is acceptable.")],
            doneTasks: ["Tag Tom's quotes in the synthesis board"],
            template: .custom
        ),
        SeedMeeting(
            title: "User interview · Priya (P3)", startedAt: priyaInterviewStart(now: now, calendar: calendar), minutes: 52,
            folder: "Pricing study", people: [1: "Priya"], attendees: ["Priya Raman"],
            lines: [
                SeedLine(person: 1, start: 7, text: "We use a spreadsheet. It works until someone forgets to update it."),
                SeedLine(person: 1, start: 900, text: "If everyone has to pay, half the group won't install it. That's the deal-breaker."),
            ],
            summary: "Priya's group uses a spreadsheet that drifts out of date. Making every member pay is a deal-breaker: half the group would not install the app.",
            decisions: [],
            tasks: [mine(description: "Check spreadsheet import with Priya's template", due: "Friday")],
            glossary: [],
            outline: [OutlineItem(startSec: 900, title: "Pricing", summary: "Charging every member is a deal-breaker.")],
            doneTasks: [],
            template: .custom
        ),
        SeedMeeting(
            title: "Candidate interview · iOS engineer", startedAt: seedDate(now: now, calendar: calendar, days: 5, hour: 14, minute: 0), minutes: 55,
            folder: "Hiring", people: [1: "Daniel"], attendees: ["Daniel Okafor"],
            lines: [
                SeedLine(person: nil, start: 5, text: "Tell me about an app you shipped that you're proud of."),
                SeedLine(person: 1, start: 14, text: "I rebuilt the offline sync for a travel app; crash reports dropped by sixty percent."),
                SeedLine(person: 1, start: 2900, text: "I could start in January, with a four-week notice period."),
            ],
            summary: "Daniel rebuilt offline sync for a travel app and cut crashes by 60%. Strong on SwiftUI and testing; less experience with server work. He can start in January after a four-week notice period.",
            decisions: ["Move Daniel to the final round."],
            tasks: [
                mine(description: "Write the interview scorecard", due: "Today"),
                theirs(owner: "Maria", description: "Schedule the final round", due: "Next week"),
            ],
            glossary: [],
            outline: [OutlineItem(startSec: 14, title: "Offline sync project", summary: "Crashes down 60% after the rebuild.")],
            doneTasks: [],
            template: .interview
        ),
        SeedMeeting(
            title: "User interview · Marco (P2)", startedAt: seedDate(now: now, calendar: calendar, days: 6, hour: 10, minute: 0), minutes: 38,
            folder: "Pricing study", people: [1: "Marco"], attendees: ["Marco Bianchi"],
            lines: [
                SeedLine(person: 1, start: 6, text: "I only care that it splits costs in different currencies."),
            ],
            summary: "Marco travels abroad and needs splitting across currencies; price was not a concern for him.",
            decisions: [],
            tasks: [],
            glossary: [],
            outline: [OutlineItem(startSec: 6, title: "Currencies", summary: "Splitting across currencies is a must.")],
            doneTasks: [],
            template: .custom
        ),
        SeedMeeting(
            title: "User interview · Aino (P1)", startedAt: seedDate(now: now, calendar: calendar, days: 8, hour: 13, minute: 30), minutes: 44,
            folder: "Pricing study", people: [1: "Aino"], attendees: ["Aino Laine"],
            lines: [
                SeedLine(person: 1, start: 6, text: "I would try it if the first trip is free."),
            ],
            summary: "Aino would try the app if the first trip is free; she plans one or two trips a year.",
            decisions: [],
            tasks: [],
            glossary: [],
            outline: [OutlineItem(startSec: 6, title: "Trial", summary: "A free first trip would get her to try it.")],
            doneTasks: [],
            template: .custom
        ),
    ]
}

/// Fiyat sorusu ve üç görüşmeden kaynaklı cevabı. Saf fonksiyondur.
func interviewAskConversation(now: Date, calendar: Calendar) -> AskConversation {
    let sara: Date = saraInterviewStart(now: now, calendar: calendar)
    let tom: Date = tomInterviewStart(now: now, calendar: calendar)
    let priya: Date = priyaInterviewStart(now: now, calendar: calendar)
    let zone: TimeZone = calendar.timeZone
    let sources: [ArchivePassage] = [
        seedPassage(
            id: "seed-1", title: "User interview · Sara (P5)", start: sara, kind: .transcript, startSec: 630,
            text: "Per trip, maybe five euros. A monthly subscription would put me off; we only travel twice a year.", timeZone: zone
        ),
        seedPassage(
            id: "seed-2", title: "User interview · Priya (P3)", start: priya, kind: .transcript, startSec: 900,
            text: "If everyone has to pay, half the group won't install it. That's the deal-breaker.", timeZone: zone
        ),
        seedPassage(
            id: "seed-3", title: "User interview · Tom (P4)", start: tom, kind: .transcript, startSec: 720,
            text: "A yearly plan would be fine for me, because I organise trips all the time. Ten, maybe fifteen euros a year.", timeZone: zone
        ),
    ]
    let answer: String = """
    Three participants talked about pricing, and they agree on one thing: **only the organiser should pay.**

    - **Sara (P5):** about €5 per trip; "a monthly subscription would put me off" [1].
    - **Priya (P3):** charging every member is a deal-breaker; "half the group won't install it" [2].
    - **Tom (P4):** organises trips often, so a **yearly plan at €10 to €15** is fine [3].

    Occasional travellers lean towards per-trip pricing; frequent organisers accept a yearly plan.
    """
    return seedAskConversation(
        question: "What did participants say about pricing?", answer: answer, terms: ["pricing", "pay", "subscription", "per trip"],
        sources: sources, now: now
    )
}
