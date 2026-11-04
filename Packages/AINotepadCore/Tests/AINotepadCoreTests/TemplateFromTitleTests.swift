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
        "Riunione individuale con Aino", "One-to-one Marco", "Colloquio individuale",
        "Reunião individual", "Conversa individual com Ana", "Um-a-um com Ana",
        "Eén-op-één met Aino", "1-op-1 Aino", "Functioneringsgesprek",
        "田中さんと1on1", "1on1ミーティング", "ワンオンワン", "１on１", "1対1面談", "田中さんとの1:1",
        "원온원", "김 팀장과 1:1", "일대일 면담", "1:1면담",
        "一对一沟通", "1对1", "与李明的一对一",
    ])
    func oneOnOneTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .oneOnOne)
    }

    // Günlük durum toplantısı: standup, daily ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "Daily", "Team daily", "Daily Scrum", "Stand-up", "STANDUP", "Mobile standups", "Günlük toplantı",
        "Ekip günlük toplantısı", "Ayakta toplantı", "Tägliche Besprechung", "Pystypalaveri", "Päivittäinen palaveri",
        "Reunión diaria", "Point quotidien", "Mêlée quotidienne",
        "Stand-up del team", "Riunione quotidiana", "Riunione giornaliera",
        "Daily do time", "Reunião diária",
        "Dagstart", "Dagelijkse stand-up", "Dagelijks overleg",
        "朝会", "開発チーム朝会", "デイリースクラム", "朝礼",
        "데일리 스크럼", "데일리미팅", "스탠드업",
        "每日站会", "站会", "晨会",
    ])
    func standupTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .standup)
    }

    // Sprint planlama: "sprint planning", "sprint planlama", "planning poker" ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "Sprint planning", "Sprint Planning #42", "Planning poker", "Sprint planlaması", "Sprint-Planung",
        "Sprintplanung", "Sprinttisuunnittelu", "Sprintin suunnittelu", "Planificación del sprint",
        "Planification du sprint", "Iteration planning",
        "Pianificazione dello sprint", "Pianificazione sprint 12",
        "Planejamento da sprint", "Planejamento do Sprint 8",
        "Sprintplanning", "Sprintplanningsessie",
        "スプリント計画", "スプリント計画会議", "スプリントプランニング",
        "스프린트 계획", "스프린트 계획 회의", "스프린트계획", "스프린트 플래닝",
        "冲刺计划会", "迭代计划会议",
    ])
    func sprintPlanningTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .sprintPlanning)
    }

    // İş mülakatı: "interview", "mülakat", aday görüşmesi, "haastattelu", "entrevista", "entretien".
    @Test(arguments: [
        "Interview: Senior iOS developer", "Interview with Jane Doe", "Mülakat - Ali Yılmaz", "Aday görüşmesi",
        "Görüşme (aday: Ali)", "İş görüşmesi", "MULAKAT", "Vorstellungsgespräch", "Työhaastattelu", "Haastattelu: Aino",
        "Entrevista de trabajo", "Entretien d'embauche",
        "Colloquio di lavoro - Marco Rossi", "Colloqui di lavoro",
        "Entrevista de emprego", "Entrevista: Ana Souza",
        "Sollicitatiegesprek", "Sollicitatiegesprek Jan de Vries",
        "一次面接", "面接：山田太郎", "最終面接",
        "면접", "1차 면접", "면접 - 김민수", "채용 인터뷰",
        "面试", "技术面试：张伟", "产品经理面试",
    ])
    func interviewTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .interview)
    }

    // Müşteri görüşmesi: demo, sales call, customer, client, müşteri, discovery call ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "Acme demo", "Sales call with Acme", "Customer call", "Client kickoff", "Müşteri görüşmesi", "Müşteriyle toplantı",
        "Discovery call: Acme", "Kundentermin", "Asiakastapaaminen", "Reunión con cliente", "Rendez-vous client",
        "Customer interview", "Asiakashaastattelu",
        "Riunione con il cliente", "Call clienti Q3", "Riunione commerciale",
        "Reunião com cliente", "Reunião comercial", "Entrevista com cliente",
        "Klantgesprek", "Afspraak met klant", "Klanteninterview",
        "商談：ABC株式会社", "顧客ヒアリング", "客先訪問", "顧客インタビュー",
        "고객 미팅", "고객사 방문", "고객과 통화", "고객 면접",
        "客户会议", "拜访客户", "顾客回访", "客户面试",
    ])
    func clientTitles(title: String) {
        #expect(suggestedTemplate(title: title) == .client)
    }

    // Ders: "lecture", "ders", "seminer", "luento" ve diğer dillerdeki karşılıkları.
    @Test(arguments: [
        "Lecture 5: Graphs", "Ders: Makine öğrenmesi", "Fizik dersi", "Seminer", "Vorlesung Analysis", "Luento 3",
        "Luennolla", "Seminario de IA", "Cours de physique",
        "Lezione 4: Analisi", "Lezioni di fisica",
        "Aula de cálculo", "Aulas de inglês",
        "Hoorcollege statistiek", "Werkcollege 3",
        "講義：機械学習", "物理の授業", "AI講座", "セミナー",
        "강의 3주차", "물리학 강의", "영어 수업", "세미나",
        "人工智能讲座", "上课", "数学课堂",
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
        // İtalyanca: "colloquio" tek başına herhangi bir görüşmedir; "in corso" "sürmekte" demektir.
        "Riunione", "Colloquio con Marco", "Pianificazione Q3", "Demo interna", "Progetti in corso",
        "Intervista con la stampa", "Revisione dello sprint", "Riunione di squadra con cliente",
        // Portekizce: kullanıcı ve basın görüşmeleri, ekip içi demo.
        "Reunião", "Planejamento trimestral", "Entrevista com usuário", "Entrevista para a imprensa",
        "Demo interno do app", "Demo da equipe",
        // Felemenkçe: "college" İngilizcede de geçtiğinden tek başına ders sayılmaz.
        "Overleg", "College", "Interview met gebruikers", "Interview voor de pers", "Interne demo", "Planning Q3", "Klant daily",
        // Japonca: "対面接客" ve "インタビュー" mülakat değildir; ekip içi demo, belirsiz "面談" ve "計画".
        "定例会議", "対面接客研修", "ユーザーインタビュー", "面談", "Q3計画", "社内顧客向け説明", "チーム顧客レビュー",
        "朝会で面接の振り返り",
        // Korece: "일대일로" (Kuşak ve Yol), kullanıcı görüşmesi, ekip içi.
        "주간 회의", "일대일로 정책 논의", "사용자 면접", "내부 고객 리뷰", "팀 회의", "계획 회의",
        // Çince: "客户端" yazılım istemcisidir; "网站会议" ve "界面试用" "站会" ve "面试" değildir; "课程" belirsizdir.
        "周会", "客户端发布", "网站会议", "界面试用", "页面试点", "用户面试", "课程设计评审", "团队客户复盘", "冲刺评审",
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

    // Ad yazı türü değiştiği yerde sözcüklere bölündüğünden öbeğin her sözcüğü tek yazı türünde olmalı ("1on1ミーティング"
    // hiç eşleşmez); boşluksuz yazıdaki (Japonca, Çince) sözcük zaten her yerde eşleştiğinden "*" almaz.
    @Test func rulePhrasePartsUseOneScript() {
        let parts: [Substring] = templateTitleRules.flatMap { $0.phrases + $0.blockers }.flatMap { $0.split(separator: " ") }
        for part in parts {
            let scripts: Set<TitleScript> = Set(part.filter { $0 != "*" }.map { titleScript(character: $0) })
            #expect(scripts.count == 1, "karışık yazılı öbek sözcüğü: \(part)")
            #expect(!(scripts == [.spaceless] && part.hasSuffix("*")), "boşluksuz yazıda kök işareti: \(part)")
        }
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
