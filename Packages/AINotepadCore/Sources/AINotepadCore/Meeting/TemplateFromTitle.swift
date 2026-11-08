import Foundation

/// Toplantı adından not şablonu türü seçme kuralı: adda `phrases`'tan biri geçiyorsa ve `blockers`'tan hiçbiri
/// geçmiyorsa tür `kind`'dir. Öbekler adın sözcükleri üzerinde eşleşir (bkz. `titleContainsPhrase`): sözcükler küçük
/// harfli ve aksansızdır ("mülakat" → "mulakat", "ı" → "i"); "*" ile biten sözcük kök olarak ekli hâlleriyle de eşleşir
/// ("mulakat*" → "mülakatı", "mülakatlar"). Japonca ve Çince ad sözcükleri boşlukla ayırmadığından Çince karakterli ya
/// da kanalı öbek sözcüğü adın sözcüğünün herhangi bir yerinde geçmesiyle eşleşir ("面接" → "一次面接"); Korece
/// sözcükleri boşlukla ayırdığından Latin yazısındaki gibi eşleşir ("면접*" → "면접을").
struct TemplateTitleRule: Sendable {
    let kind: NoteTemplateKind
    let phrases: [String]
    let blockers: [String]
}

/// Toplantı adı kuralları (Türkçe, İngilizce, Almanca, Fince, İspanyolca, Fransızca, İtalyanca, Portekizce,
/// Felemenkçe, Japonca, Korece, Çince). Temkinlidir: yanlış şablon kaçırılan şablondan kötüdür; belirsiz sözcükler
/// ("planning", "sales", "training", "discovery", Felemenkçe ve İngilizce "college", Çince "课程") tek başına
/// eşleşmez, başka türe işaret eden bağlam (ör. "customer interview" kullanıcı araştırmasıdır, iş mülakatı değil)
/// kuralı durdurur. Japonca ve Çince sözcük başka sözcüklerin birleşiminde de geçebildiğinden ("対面接客" içinde
/// "面接", "网站会议" içinde "站会") bilinen birleşimler kuralı durdurur.
let templateTitleRules: [TemplateTitleRule] = [
    TemplateTitleRule(
        kind: .sprintPlanning,
        phrases: [
            "sprint planning*", "sprintplanning*", "planning poker", "iteration planning*",
            "sprint planlama*",
            "sprintplanung*", "sprint planung*",
            "sprinttisuunnittelu*", "sprintsuunnittelu*", "sprintin suunnittelu*", "sprint suunnittelu*",
            "planificacion del sprint", "planificacion de sprint", "planificacion sprint",
            "planification du sprint", "planification de sprint", "planning du sprint", "planning de sprint",
            "pianificazione dello sprint", "pianificazione della sprint", "pianificazione sprint",
            "planejamento da sprint", "planejamento do sprint", "planejamento de sprint", "planejamento sprint",
            "スプリント計画", "スプリントプランニング",
            "스프린트 계획*", "스프린트계획*", "스프린트 플래닝*", "스프린트플래닝*",
            "冲刺计划", "冲刺规划", "迭代计划", "迭代规划",
        ],
        blockers: []
    ),
    TemplateTitleRule(
        kind: .standup,
        phrases: [
            "standup*", "stand up", "daily",
            "gunluk toplanti*", "gunluk durum toplanti*", "ayakta toplanti*",
            "tagliche besprechung*", "morgenrunde*",
            "pystypalaveri*", "paivapalaveri*", "paivittainen palaveri*", "aamupalaveri*",
            "reunion diaria", "reunion de seguimiento diaria",
            "point quotidien", "reunion quotidienne", "melee quotidienne",
            "riunione quotidiana", "riunione giornaliera",
            "reuniao diaria",
            "dagstart*", "dagelijks overleg", "dagelijkse overleg",
            "朝会", "朝礼", "デイリー", "スタンドアップ",
            "데일리*", "스탠드업*", "일일 스크럼*",
            "站会", "站立会", "晨会",
        ],
        // "网站会议" (web sitesi toplantısı) ve "车站会..." (istasyon) günlük durum toplantısı değildir.
        blockers: ["网站", "车站"]
    ),
    TemplateTitleRule(
        kind: .oneOnOne,
        phrases: [
            "1 on 1", "1on1", "1o1", "one on one", "one to one",
            "birebir*", "bire bir", "teke tek",
            "einzelgesprach*", "mitarbeitergesprach*",
            "kahdenkeskinen*", "kahden kesken", "kehityskeskustelu*",
            "uno a uno", "reunion individual",
            "tete a tete", "entretien individuel", "entretien annuel", "point individuel",
            "riunione individuale", "colloquio individuale", "incontro individuale",
            "reuniao individual", "conversa individual", "um a um",
            "een op een", "1 op 1", "1op1", "functioneringsgesprek*",
            "ワンオンワン", "1 対 1",
            // "일대일로" (Kuşak ve Yol) birebir değildir; bu yüzden "일대일" ek almadan eşleşir.
            "원온원*", "일대일", "일대일 면담*",
            "一对一", "1 对 1",
        ],
        blockers: []
    ),
    TemplateTitleRule(
        kind: .interview,
        phrases: [
            "interview*",
            "mulakat*", "aday gorusme*", "gorusme aday", "is gorusme*",
            "vorstellungsgesprach*", "bewerbungsgesprach*",
            "haastattelu*", "tyohaastattelu*", "rekrytointihaastattelu*",
            "entrevista*",
            "entretien*",
            "colloquio di lavoro", "colloqui di lavoro",
            "sollicitatiegesprek*",
            "面接",
            "면접*", "채용 인터뷰*",
            "面试",
        ],
        // Müşteri, kullanıcı, basın ve araştırma görüşmeleri iş mülakatı değildir; Fransızca "entretien individuel /
        // annuel" birebir görüşmedir. "対面接客" (yüz yüze müşteri hizmeti), "界面试用" (arayüz denemesi) ve "页面试点"
        // (sayfa pilotu) içinde "面接" / "面试" geçer ama mülakat değildir.
        blockers: [
            "customer*", "client*", "user*", "press", "media", "podcast", "research*", "exit", "expert*",
            "musteri*", "kullanici*", "basin", "medya", "arastirma*",
            "kunde*", "nutzer*", "presse",
            "asiakas*", "kayttaja*", "lehdisto*",
            "cliente*", "usuario*", "prensa",
            "utilisateur*", "individuel", "annuel",
            "clienti", "utent*", "stampa",
            "imprensa", "pesquisa",
            "klant*", "gebruiker*", "pers", "onderzoek*",
            "顧客", "ユーザー", "接客",
            "고객*", "사용자*", "유저*",
            "顾客", "客户", "用户", "界面试", "页面试",
        ]
    ),
    TemplateTitleRule(
        kind: .client,
        phrases: [
            "client", "clients", "clientele", "customer*", "demo", "demos", "sales call*", "sales demo*", "sales pitch*", "discovery call*",
            "discovery meeting*",
            "musteri*", "satis gorusme*",
            "kunde*", "verkaufsgesprach*",
            "asiakas*", "myyntineuvottelu*",
            "cliente*", "llamada de ventas", "reunion comercial",
            "rendez vous commercial", "appel commercial",
            "clienti", "riunione commerciale", "chiamata commerciale",
            "reuniao comercial",
            "klant*", "verkoopgesprek*",
            "商談", "顧客", "客先",
            "고객*",
            "顾客", "客户",
        ],
        // Ekip içi demo ve sprint demosu müşteri görüşmesi değildir; Çince "客户端" yazılımın istemcisidir.
        blockers: [
            "internal", "team", "sprint", "ic", "dahili", "ekip*", "intern", "interne", "sisainen", "tiimi*", "interno",
            "interna", "internos", "internas", "interni", "squadra", "equipe",
            "社内", "内部", "チーム", "スプリント",
            "내부*", "팀*", "스프린트*",
            "团队", "冲刺", "客户端",
        ]
    ),
    TemplateTitleRule(
        kind: .lecture,
        phrases: [
            "lecture*", "seminar*",
            "ders*", "seminer*",
            "vorlesung*",
            "luento*", "luenno*", "seminaari*",
            "clase", "clases", "seminario*",
            "cours", "seminaire*",
            "lezione", "lezioni",
            "aula", "aulas",
            "hoorcollege*", "werkcollege*",
            "講義", "授業", "講座", "セミナー",
            "강의*", "수업*", "세미나*",
            "讲座", "讲课", "上课", "课堂",
        ],
        // Fransızca "en cours" "sürmekte" demektir.
        blockers: ["en cours"]
    ),
]

/// Toplantı adının gösterdiği not şablonu türü; ad bir türü açıkça göstermiyorsa ya da birden çok türe işaret ediyorsa
/// nil (kullanıcının varsayılan şablonu kalır). Büyük/küçük harf ve aksan fark etmez ("MÜLAKAT", "Mulakat"). "1:1" ve
/// "1-1" yalnızca tek başına yazıldığında birebir görüşmedir (tarih ya da saat parçası değilse). Saf fonksiyondur.
public func suggestedTemplate(title: String) -> NoteTemplateKind? {
    let folded: String = foldedTitle(title: title)
    let words: [String] = titleWords(folded: folded)
    let ruleKinds: [NoteTemplateKind] = templateTitleRules.filter { (rule: TemplateTitleRule) -> Bool in
        rule.phrases.contains { titleContainsPhrase(words: words, phrase: $0) }
            && !rule.blockers.contains { titleContainsPhrase(words: words, phrase: $0) }
    }.map(\.kind)
    let kinds: Set<NoteTemplateKind> = Set(ruleKinds + (hasOneOnOneNumerals(folded: folded) ? [.oneOnOne] : []))
    guard kinds.count == 1 else {
        return nil
    }
    return kinds.first
}

/// Yeni toplantının şablonu, toplantı adına göre: ad bir türü gösteriyorsa (bkz. `suggestedTemplate`) o tür, adından
/// seçildiği işaretiyle. Kendi şablonu seçili kullanıcının yönergesi geçersiz kılınmaz; ad bir tür göstermiyorsa ya da
/// gösterdiği tür zaten varsayılansa varsayılan şablon aynen döner. Saf fonksiyondur.
public func templateForTitle(title: String, defaultTemplate: NoteTemplate) -> NoteTemplate {
    guard defaultTemplate.kind != .custom, let kind = suggestedTemplate(title: title), kind != defaultTemplate.kind else {
        return defaultTemplate
    }
    return NoteTemplate(kind: kind, customInstructions: defaultTemplate.customInstructions, chosenFromTitle: true)
}

/// Karşılaştırma için ad: küçük harf, aksansız; Türkçe noktasız "ı" da "i" olur ("İ" katlamada "i"ye döner).
func foldedTitle(title: String) -> String {
    title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .replacingOccurrences(of: "ı", with: "i")
}

/// Sözcük eşleşmesi bakımından yazı türü: Çince karakter ve kana sözcükleri boşluksuz yazılır, Hangul (Korece)
/// boşlukla ayrılır; diğer her şey (Latin yazısı, rakamlar) `other`'dır.
enum TitleScript: Sendable, Equatable {
    case spaceless
    case hangul
    case other
}

/// Karakterin yazı türü, ilk Unicode skalerinin bloğuna göre.
func titleScript(character: Character) -> TitleScript {
    guard let scalar = character.unicodeScalars.first else {
        return .other
    }
    switch scalar.value {
    case 0x3005...0x3007, 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
        0xFF66...0xFF9F, 0x20000...0x3134F:
        return .spaceless
    case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF:
        return .hangul
    default:
        return .other
    }
}

/// Katlanmış adın sözcükleri: harf ve rakam dışındaki her karakter ayırır ("stand-up" → "stand", "up"); yazı türü
/// değiştiği yerde de sözcük biter ("田中さんと1on1" → "田中さんと", "1on1").
private func titleWords(folded: String) -> [String] {
    folded.split { (character: Character) -> Bool in !(character.isLetter || character.isNumber) }
        .flatMap { (word: Substring) -> [String] in
            word.reduce(into: [String]()) { (parts: inout [String], character: Character) in
                if let last = parts.last?.last, titleScript(character: last) == titleScript(character: character) {
                    parts[parts.count - 1].append(character)
                } else {
                    parts.append(String(character))
                }
            }
        }
}

/// Öbeğin sözcükleri adda sırayla ve bitişik geçiyor mu; "*" ile biten sözcük önek olarak, boşluksuz yazıdaki
/// (Japonca, Çince) sözcük adın sözcüğünün içinde herhangi bir yerde eşleşir.
private func titleContainsPhrase(words: [String], phrase: String) -> Bool {
    let parts: [Substring] = phrase.split(separator: " ")
    guard !parts.isEmpty, words.count >= parts.count else {
        return false
    }
    return (0...(words.count - parts.count)).contains { (start: Int) -> Bool in
        zip(words[start..<(start + parts.count)], parts).allSatisfy { (pair: (String, Substring)) -> Bool in
            titleWordMatches(word: pair.0, part: pair.1)
        }
    }
}

/// Adın tek sözcüğü öbeğin tek sözcüğüyle eşleşiyor mu (bkz. `titleContainsPhrase`).
private func titleWordMatches(word: String, part: Substring) -> Bool {
    if part.hasSuffix("*") {
        return word.hasPrefix(part.dropLast())
    }
    if let first = part.first, titleScript(character: first) == .spaceless {
        return word.contains(part)
    }
    return word == part
}

/// Adda tek başına "1:1" ya da "1-1" var mı; tarih, saat ya da sürüm parçası ("2027-1-1", "11:15", "v1.1-1") sayılmaz.
private func hasOneOnOneNumerals(folded: String) -> Bool {
    let characters: [Character] = Array(folded)
    guard characters.count >= 3 else {
        return false
    }
    return (0...(characters.count - 3)).contains { (start: Int) -> Bool in
        characters[start] == "1" && (characters[start + 1] == ":" || characters[start + 1] == "-") && characters[start + 2] == "1"
            && isNumeralBoundary(characters: characters, index: start - 1, step: -1)
            && isNumeralBoundary(characters: characters, index: start + 3, step: 1)
    }
}

/// `index`'teki komşu "1:1"i bir sayı dizisinin parçası yapmıyor mu: komşu yok, Japonca, Çince ya da Korece harf
/// ("田中さんと1:1", "1:1면담"), ya da harf/rakam değil ve sayı ayırıcısıysa (".:-/,") ötesinde (`step` yönünde) rakam yok.
private func isNumeralBoundary(characters: [Character], index: Int, step: Int) -> Bool {
    guard characters.indices.contains(index) else {
        return true
    }
    let neighbor: Character = characters[index]
    if neighbor.isLetter && titleScript(character: neighbor) != .other {
        return true
    }
    if neighbor.isLetter || neighbor.isNumber {
        return false
    }
    guard ".:-/,".contains(neighbor) else {
        return true
    }
    let beyond: Int = index + step
    return !(characters.indices.contains(beyond) && characters[beyond].isNumber)
}
