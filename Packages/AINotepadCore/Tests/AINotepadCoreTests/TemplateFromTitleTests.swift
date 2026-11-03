import Foundation
import Testing
@testable import AINotepadCore

/// Toplantı adından not şablonu: çok dilli anahtar sözcükler, temkinli eşleşme ve kullanıcının seçiminin korunması.
@Suite struct TemplateFromTitleTests {
    // Birebir görüşme: "1:1", "1-1", "one on one", "birebir" ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "1:1 Aino / Senol", "Senol <> Aino 1-1", "Weekly 1:1", "1on1 with Mikko", "One-on-one: Mikko", "1 on 1",
        "Birebir görüşme", "BİREBİR", "Aino ile bire bir", "Einzelgespräch mit Aino", "Mitarbeitergespräch",
        "Kahdenkeskinen Ainon kanssa", "Kehityskeskustelu", "Reunión uno a uno", "Tête-à-tête avec Aino",
        "Entretien annuel", "Entretien individuel", "1:1: Aino",
    ])
    func oneOnOneTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .oneOnOne)
    }

    // Günlük durum toplantısı: standup, daily ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "Daily", "Team daily", "Daily Scrum", "Stand-up", "STANDUP", "Mobile standups", "Günlük toplantı",
        "Ekip günlük toplantısı", "Ayakta toplantı", "Tägliche Besprechung", "Pystypalaveri", "Päivittäinen palaveri",
        "Reunión diaria", "Point quotidien", "Mêlée quotidienne",
    ])
    func standupTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .standup)
    }

    // Sprint planlama: "sprint planning", "sprint planlama", "planning poker" ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "Sprint planning", "Sprint Planning #42", "Planning poker", "Sprint planlaması", "Sprint-Planung",
        "Sprintplanung", "Sprinttisuunnittelu", "Sprintin suunnittelu", "Planificación del sprint",
        "Planification du sprint", "Iteration planning",
    ])
    func sprintPlanningTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .sprintPlanning)
    }

    // İş mülakatı: "interview", "mülakat", aday görüşmesi, "haastattelu", "entrevista", "entretien".
    @Test(arguments: [
        "Interview: Senior iOS developer", "Interview with Jane Doe", "Mülakat - Ali Yılmaz", "Aday görüşmesi",
        "Görüşme (aday: Ali)", "İş görüşmesi", "MULAKAT", "Vorstellungsgespräch", "Työhaastattelu", "Haastattelu: Aino",
        "Entrevista de trabajo", "Entretien d'embauche",
    ])
    func interviewTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .interview)
    }

    // Müşteri görüşmesi: demo, sales call, customer, client, müşteri, discovery call ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "Acme demo", "Sales call with Acme", "Customer call", "Client kickoff", "Müşteri görüşmesi", "Müşteriyle toplantı",
        "Discovery call: Acme", "Kundentermin", "Asiakastapaaminen", "Reunión con cliente", "Rendez-vous client",
        "Customer interview", "Asiakashaastattelu",
    ])
    func clientTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .client)
    }

    // Ders: "lecture", "ders", "seminer", "luento" ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "Lecture 5: Graphs", "Ders: Makine öğrenmesi", "Fizik dersi", "Seminer", "Vorlesung Analysis", "Luento 3",
        "Luennolla", "Seminario de IA", "Cours de physique",
    ])
    func lectureTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .lecture)
    }

    // Temkinli: tür göstermeyen, belirsiz ya da birden çok türe işaret eden adlar ve 1:1'e benzeyen tarih ve saatler
    // şablon seçmez.
    @Test(arguments: [
        "", "Toplantı", "Meeting", "Weekly sync", "Planning", "Q3 planning", "Sales team weekly", "Discovery",
        "Training", "Sprint review", "Sprint demo", "Internal demo", "Team demo", "Retro",
        "User interview", "UX research interview", "Press interview", "Podcast interview", "Exit interview",
        "Projet en cours", "Demographics review", "Democracy talk", "Clientless VPN",
        "Release 2027-1-1", "Release 1-1-2027", "Kickoff 11:15", "v1.1-1 rollout", "Q1-1 review", "1:10 sync",
        "Daily customer call", "1:1 interview prep", "Sprint planning standup",
    ])
    func ambiguousTitlesKeepDefault(title: String) {
        #expect(suggestedTemplate(title: title) == nil)
    }

    // Kural sözcükleri katlanmış biçimde yazılmalı (küçük harf, aksansız); yoksa hiç eşleşmezler.
    @Test func rulePhrasesAreFolded() {
        let phrases: [String] = templateTitleRules.flatMap { $0.phrases + $0.blockers }
        for phrase in phrases {
            #expect(foldedTitle(title: phrase) == phrase, "katlanmamış öbek: \(phrase)")
        }
        // Türkçe büyük "İ" ve noktasız "ı" "i" olur.
        #expect(foldedTitle(title: "İŞ GÖRÜŞMESİ ılık") == "is gorusmesi ilik")
    }

    // Adın türü seçilir ve işaretlenir; kendi şablonu, aynı tür ve tür göstermeyen ad varsayılanı aynen bırakır.
    @Test func templateForTitleKeepsExplicitChoices() {
        let general: NoteTemplate = .general
        let chosen: NoteTemplate = templateForTitle(title: "Sprint planning", defaultTemplate: general)
        #expect(chosen == NoteTemplate(kind: .sprintPlanning, customInstructions: "", chosenFromTitle: true))
        #expect(chosen.displayName.contains(NoteTemplateKind.sprintPlanning.displayName) && chosen.displayName != NoteTemplateKind.sprintPlanning.displayName)
        let custom: NoteTemplate = NoteTemplate(kind: .custom, customInstructions: "Riskleri ayrı say.")
        #expect(templateForTitle(title: "1:1 Aino", defaultTemplate: custom) == custom)
        let oneOnOne: NoteTemplate = NoteTemplate(kind: .oneOnOne, customInstructions: "")
        #expect(templateForTitle(title: "Birebir", defaultTemplate: oneOnOne) == oneOnOne)
        #expect(templateForTitle(title: "Weekly sync", defaultTemplate: oneOnOne) == oneOnOne)
        #expect(oneOnOne.displayName == NoteTemplateKind.oneOnOne.displayName)
    }

    // Eski kayıtlardaki şablon (işaretsiz) aynen okunur; yeni işaret ve yeni türler saklanıp geri okunur.
    @Test func templateCodableIsBackwardCompatible() throws {
        let old: NoteTemplate = try JSONDecoder().decode(NoteTemplate.self, from: Data(#"{"kind":"client","customInstructions":""}"#.utf8))
        #expect(old == NoteTemplate(kind: .client, customInstructions: ""))
        #expect(old.chosenFromTitle == nil)
        let plainJSON: String = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!plainJSON.contains("chosenFromTitle"))
        let chosen: NoteTemplate = NoteTemplate(kind: .standup, customInstructions: "", chosenFromTitle: true)
        #expect(try JSONDecoder().decode(NoteTemplate.self, from: try JSONEncoder().encode(chosen)) == chosen)
    }

    // Yeni şablonların yönergesi not istemine girer.
    @Test func newTemplatesHaveInstructions() {
        let standup: String = templateInstructions(template: NoteTemplate(kind: .standup, customInstructions: ""))
        #expect(standup.contains("stand-up") && standup.contains("engel"))
        let sprint: String = templateInstructions(template: NoteTemplate(kind: .sprintPlanning, customInstructions: ""))
        #expect(sprint.contains("sprint planlama") && sprint.contains("kapasite"))
    }
}
