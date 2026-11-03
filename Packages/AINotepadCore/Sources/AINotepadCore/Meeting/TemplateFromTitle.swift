import Foundation

/// Toplantı adından not şablonu türü seçme kuralı: adda `phrases`'tan biri geçiyorsa ve `blockers`'tan hiçbiri
/// geçmiyorsa tür `kind`'dir. Öbekler adın sözcükleri üzerinde eşleşir (bkz. `titleContainsPhrase`): sözcükler küçük
/// harfli ve aksansızdır ("mülakat" → "mulakat", "ı" → "i"); "*" ile biten sözcük kök olarak ekli hâlleriyle de eşleşir
/// ("mulakat*" → "mülakatı", "mülakatlar").
struct TemplateTitleRule: Sendable {
    let kind: NoteTemplateKind
    let phrases: [String]
    let blockers: [String]
}

/// Toplantı adı kuralları (Türkçe, İngilizce, Almanca, Fince, İspanyolca, Fransızca). Temkinlidir: yanlış şablon
/// kaçırılan şablondan kötüdür; belirsiz sözcükler ("planning", "sales", "training", "discovery") tek başına
/// eşleşmez, başka türe işaret eden bağlam (ör. "customer interview" kullanıcı araştırmasıdır, iş mülakatı değil)
/// kuralı durdurur.
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
        ],
        blockers: []
    ),
    TemplateTitleRule(
        kind: .standup,
        phrases: [
            "standup*", "stand up", "daily",
            "gunluk toplanti*", "gunluk durum toplanti*", "ayakta toplanti*",
            "tagliche besprechung*", "morgenrunde*",
            "pystypalaveri*", "paivittainen palaveri*", "aamupalaveri*",
            "reunion diaria", "reunion de seguimiento diaria",
            "point quotidien", "reunion quotidienne", "melee quotidienne",
        ],
        blockers: []
    ),
    TemplateTitleRule(
        kind: .oneOnOne,
        phrases: [
            "1 on 1", "1on1", "1o1", "one on one", "one to one",
            "birebir*", "bire bir", "teke tek",
            "einzelgesprach*", "mitarbeitergesprach*",
            "kahdenkeskinen*", "kehityskeskustelu*",
            "uno a uno", "reunion individual",
            "tete a tete", "entretien individuel", "entretien annuel", "point individuel",
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
        ],
        // Müşteri, kullanıcı, basın ve araştırma görüşmeleri iş mülakatı değildir; Fransızca "entretien individuel /
        // annuel" birebir görüşmedir.
        blockers: [
            "customer*", "client*", "user*", "press", "media", "podcast", "research*", "exit", "expert*",
            "musteri*", "kullanici*", "basin", "medya", "arastirma*",
            "kunde*", "nutzer*", "presse",
            "asiakas*", "kayttaja*", "lehdisto*",
            "cliente*", "usuario*", "prensa",
            "utilisateur*", "individuel", "annuel",
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
        ],
        // Ekip içi demo ve sprint demosu müşteri görüşmesi değildir.
        blockers: [
            "internal", "team", "sprint", "ic", "dahili", "ekip*", "intern", "interne", "sisainen", "tiimi*", "interno",
            "interna", "internos", "internas",
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

/// Katlanmış adın sözcükleri: harf ve rakam dışındaki her karakter ayırır ("stand-up" → "stand", "up").
private func titleWords(folded: String) -> [String] {
    folded.split { (character: Character) -> Bool in !(character.isLetter || character.isNumber) }.map(String.init)
}

/// Öbeğin sözcükleri adda sırayla ve bitişik geçiyor mu; "*" ile biten sözcük önek olarak eşleşir.
private func titleContainsPhrase(words: [String], phrase: String) -> Bool {
    let parts: [Substring] = phrase.split(separator: " ")
    guard !parts.isEmpty, words.count >= parts.count else {
        return false
    }
    return (0...(words.count - parts.count)).contains { (start: Int) -> Bool in
        zip(words[start..<(start + parts.count)], parts).allSatisfy { (pair: (String, Substring)) -> Bool in
            pair.1.hasSuffix("*") ? pair.0.hasPrefix(pair.1.dropLast()) : pair.0 == pair.1
        }
    }
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

/// `index`'teki komşu "1:1"i bir sayı dizisinin parçası yapmıyor mu: komşu yok, ya da harf/rakam değil ve sayı
/// ayırıcısıysa (".:-/,") ötesinde (`step` yönünde) rakam yok.
private func isNumeralBoundary(characters: [Character], index: Int, step: Int) -> Bool {
    guard characters.indices.contains(index) else {
        return true
    }
    let neighbor: Character = characters[index]
    if neighbor.isLetter || neighbor.isNumber {
        return false
    }
    guard ".:-/,".contains(neighbor) else {
        return true
    }
    let beyond: Int = index + step
    return !(characters.indices.contains(beyond) && characters[beyond].isNumber)
}
