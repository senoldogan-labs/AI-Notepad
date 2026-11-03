import Foundation
import Testing
@testable import AINotepadCore

/// Fince toplantıda Fince, İngilizce ve İsveççe cümleler (NaturalLanguage cihazda, gerçek algılama).
private let finnishSentence: String = "Tänään puhumme projektin aikataulusta ja seuraavista askeleista tiimin kanssa."
private let englishSentence: String = "We should finalize the budget before the end of the quarter, right?"
private let swedishSentence: String = "Vi måste bestämma oss för vilken leverantör vi ska välja innan fredag."

/// Her toplantı dilinde toplantıda geçebilecek bir cümle (tedarikçi kararı).
private let sampleSentences: [MeetingLanguage: String] = [
    .finnish: finnishSentence,
    .english: englishSentence,
    .swedish: swedishSentence,
    .norwegian: "Vi må bestemme oss for hvilken leverandør vi skal velge før fredag neste uke.",
    .danish: "Vi skal beslutte, hvilken leverandør vi vælger, inden fredag i næste uge.",
    .estonian: "Täna arutame projekti ajakava ja järgmisi samme koos meeskonnaga.",
    .german: "Wir müssen uns bis Freitag entscheiden, welchen Lieferanten wir wählen.",
    .dutch: "We moeten voor vrijdag beslissen welke leverancier we gaan kiezen.",
    .french: "Nous devons décider avant vendredi quel fournisseur nous allons choisir.",
    .spanish: "Tenemos que decidir antes del viernes qué proveedor vamos a elegir.",
    .portuguese: "Precisamos decidir até sexta-feira qual fornecedor vamos escolher.",
    .italian: "Dobbiamo decidere entro venerdì quale fornitore scegliere per il progetto.",
    .polish: "Musimy zdecydować do piątku, którego dostawcę wybierzemy do projektu.",
    .czech: "Musíme se do pátku rozhodnout, kterého dodavatele si vybereme.",
    .slovak: "Musíme sa do piatku rozhodnúť, ktorého dodávateľa si vyberieme.",
    .hungarian: "Péntekig el kell döntenünk, melyik beszállítót választjuk a projekthez.",
    .romanian: "Trebuie să decidem până vineri ce furnizor vom alege pentru proiect.",
    .bulgarian: "Трябва да решим до петък кой доставчик ще изберем за проекта.",
    .croatian: "Moramo do petka odlučiti kojeg ćemo dobavljača izabrati za projekt.",
    .greek: "Πρέπει να αποφασίσουμε μέχρι την Παρασκευή ποιον προμηθευτή θα επιλέξουμε.",
    .latvian: "Mums līdz piektdienai jāizlemj, kuru piegādātāju mēs izvēlēsimies projektam.",
    .lithuanian: "Iki penktadienio turime nuspręsti, kurį tiekėją pasirinksime projektui.",
    .russian: "Нам нужно до пятницы решить, какого поставщика мы выберем для проекта.",
    .ukrainian: "Нам потрібно до п'ятниці вирішити, якого постачальника ми оберемо для проєкту.",
    .turkish: "Cuma gününe kadar proje için hangi tedarikçiyi seçeceğimize karar vermeliyiz.",
    .arabic: "يجب أن نقرر قبل يوم الجمعة أي مورد سنختار لهذا المشروع.",
    .hebrew: "עלינו להחליט עד יום שישי איזה ספק נבחר עבור הפרויקט.",
    .persian: "ما باید تا جمعه تصمیم بگیریم که کدام تامین کننده را برای این پروژه انتخاب کنیم.",
    .hindi: "हमें शुक्रवार तक तय करना होगा कि इस परियोजना के लिए हम कौन सा आपूर्तिकर्ता चुनेंगे।",
    .chinese: "我们需要在星期五之前决定为这个项目选择哪一家供应商，然后再讨论预算。",
    .japanese: "金曜日までに、このプロジェクトでどの業者を選ぶかを決める必要があります。",
    .korean: "금요일까지 이 프로젝트에 어떤 공급업체를 선택할지 결정해야 합니다.",
    .indonesian: "Kita harus memutuskan sebelum hari Jumat pemasok mana yang akan kita pilih.",
    .vietnamese: "Chúng ta cần quyết định trước thứ Sáu sẽ chọn nhà cung cấp nào cho dự án.",
    .thai: "เราต้องตัดสินใจภายในวันศุกร์ว่าจะเลือกผู้จัดหาสินค้ารายใดสำหรับโครงการนี้",
]

private func segment(key: String, person: Int?, startSec: Double, text: String) -> StoredSegment {
    StoredSegment(key: key, speaker: .others, person: person, startSec: startSec, endSec: startSec + 5, text: text, words: nil)
}

private func meeting(segments: [StoredSegment], fixedLanguage: MeetingLanguage?) -> MeetingRecord {
    MeetingRecord(
        id: "20261030-100000", title: "Palaveri", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil,
        language: .finnish, status: .done, failureMessage: nil, liveSegments: [], finalSegments: labelingSpokenLanguages(segments: segments),
        translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
    .with(fixedLanguage: fixedLanguage)
}

@Suite struct SpokenLanguageTests {
    @Test func detectsLongSentencesConfidently() {
        #expect(confidentSpokenLanguage(text: finnishSentence) == "fi")
        #expect(confidentSpokenLanguage(text: englishSentence) == "en")
        #expect(confidentSpokenLanguage(text: swedishSentence) == "sv")
        // Norveççe NaturalLanguage'te "nb"; toplantı dili kodu "no".
        #expect(confidentSpokenLanguage(text: "Vi må bestemme oss for hvilken leverandør vi skal velge før fredag neste uke.") == "no")
    }

    // Kısa sözler, ad ve kısaltma dizileri, sayılar algılanmaz: toplantı dilinde sayılır.
    @Test func shortOrAmbiguousTextIsNotDetected() {
        #expect(confidentSpokenLanguage(text: "Okei, joo.") == nil)
        #expect(confidentSpokenLanguage(text: "I think so too.") == nil)
        #expect(confidentSpokenLanguage(text: "Microsoft Teams Q3 2026 OKR KPI") == nil)
        #expect(confidentSpokenLanguage(text: "12 34 56 78 90 11 22") == nil)
        #expect(letterWordCount(text: "Q3 2026 on 15 % parempi") == 3)
    }

    @Test func otherLanguageRule() {
        #expect(!isOtherLanguage(spokenLanguage: nil, meetingLanguage: .finnish))
        #expect(!isOtherLanguage(spokenLanguage: "fi", meetingLanguage: .finnish))
        #expect(isOtherLanguage(spokenLanguage: "sv", meetingLanguage: .finnish))
        #expect(isOtherLanguage(spokenLanguage: "en", meetingLanguage: .finnish))
        // Yazılı biçimi çok yakın diller birbirinin yerine algılanabilir: başka dil sayılmaz.
        #expect(!isOtherLanguage(spokenLanguage: "da", meetingLanguage: .norwegian))
        #expect(!isOtherLanguage(spokenLanguage: "zh", meetingLanguage: .chinese))
    }

    // Sabit Fince toplantıda uzun İngilizce ve İsveççe bölümler atlanır; kısa İngilizce söz ve Fince kalır. Atlanan
    // bölümün konuşmacısı konuşmacı sayılmaz; kayıttaki bölümler silinmez.
    @Test func fixedLanguageSkipsOtherLanguageSegments() {
        let segments: [StoredSegment] = [
            segment(key: "final-0", person: 1, startSec: 0, text: finnishSentence),
            segment(key: "final-1", person: 2, startSec: 10, text: englishSentence),
            segment(key: "final-2", person: 1, startSec: 20, text: "Okei, thanks."),
            segment(key: "final-3", person: 3, startSec: 30, text: swedishSentence),
            segment(key: "final-4", person: 1, startSec: 40, text: "Kiitos kaikille, nähdään ensi viikolla taas samaan aikaan."),
        ]
        let fixed: MeetingRecord = meeting(segments: segments, fixedLanguage: .finnish)
        #expect(meetingSegments(record: fixed).map(\.key) == ["final-0", "final-2", "final-4"])
        #expect(skippedLanguageSegments(record: fixed).map(\.key) == ["final-1", "final-3"])
        #expect(fixed.finalSegments.count == 5)
        #expect(Set(speakerShares(record: fixed).map(\.key)) == [SpeakerKey(speaker: .others, person: 1)])
        #expect(!transcriptText(record: fixed).contains("budget"))
        // Otomatik dilde hiçbir şey atlanmaz.
        let automatic: MeetingRecord = meeting(segments: segments, fixedLanguage: nil)
        #expect(meetingSegments(record: automatic).count == 5)
        #expect(skippedLanguageSegments(record: automatic).isEmpty)
        // İngilizce sabit toplantıda Fince ve İsveççe atlanır.
        let english: MeetingRecord = meeting(segments: segments, fixedLanguage: .english)
        #expect(skippedLanguageSegments(record: english).map(\.key) == ["final-0", "final-3", "final-4"])
    }

    // Canlı bölümün dili kesinleştiğinde algılanır ve saklanan bölümle birlikte yazılır; "Sen" kopyası ve kişi
    // değişikliği dili korur.
    @Test func liveSegmentsCarryDetectedLanguage() {
        let id: SegmentID = SegmentID(speaker: .others, index: 3)
        let live: LiveSegment = LiveSegment(id: id, startSec: 1, endSec: 4, text: englishSentence, isFinal: true, failureMessage: nil, person: 2)
        let stored: [StoredSegment] = storedSegments(transcript: [live], spokenLanguages: [id: "en"])
        #expect(stored.map(\.spokenLanguage) == ["en"])
        #expect(stored.first?.asMe().spokenLanguage == "en")
        #expect(stored.first?.with(person: 5).spokenLanguage == "en")
    }

    // Kayıt sürerken: sabit dilde başka dildeki bölümler soluk, başka dildeki birim çevrilmez; Otomatikte hiçbiri.
    @Test func liveRulesFollowFixedLanguage() {
        let finnish: SegmentID = SegmentID(speaker: .others, index: 0)
        let swedish: SegmentID = SegmentID(speaker: .others, index: 1)
        let languages: [SegmentID: String] = [finnish: "fi", swedish: "sv"]
        #expect(otherLanguageSegmentIDs(spokenLanguages: languages, fixedLanguage: .finnish) == [swedish])
        #expect(otherLanguageSegmentIDs(spokenLanguages: languages, fixedLanguage: nil).isEmpty)
        let unit: TranslationUnit = TranslationUnit(coveredIDs: [], carrierID: swedish, text: swedishSentence, startSec: 0, endSec: 5)
        #expect(isOtherLanguageUnit(unit: unit, fixedLanguage: .finnish))
        #expect(!isOtherLanguageUnit(unit: unit, fixedLanguage: .swedish))
        #expect(!isOtherLanguageUnit(unit: unit, fixedLanguage: nil))
    }

    // Her toplantı dilinde gerçek bir cümle, o dil sabitken başka dil sayılmaz (bölüm de çeviri birimi de). NaturalLanguage
    // Estonca, Letonca, Litvanca ve Farsçayı tanıyamaz (başka dil sanar); bu dillerde süzme yapılmaz.
    @Test(arguments: MeetingLanguage.allCases)
    func ownLanguageSentenceIsNotOtherLanguage(language: MeetingLanguage) throws {
        let sentence: String = try #require(sampleSentences[language], "Örnek cümle yok: \(language.rawValue)")
        let detected: String? = confidentSpokenLanguage(text: sentence)
        #expect(!isOtherLanguage(spokenLanguage: detected, meetingLanguage: language), "algılanan: \(detected ?? "yok")")
        // Süzülen dillerde cümle gerçekten algılanır (süzme o dilde işe yarıyor).
        if !undetectableMeetingLanguages.contains(language) {
            #expect(detected != nil)
        }
        let id: SegmentID = SegmentID(speaker: .others, index: 0)
        let unit: TranslationUnit = TranslationUnit(coveredIDs: [], carrierID: id, text: sentence, startSec: 0, endSec: 5)
        #expect(!isOtherLanguageUnit(unit: unit, fixedLanguage: language))
        let record: MeetingRecord = meeting(segments: [segment(key: "final-0", person: 1, startSec: 0, text: sentence)], fixedLanguage: language)
        #expect(meetingSegments(record: record).map(\.key) == ["final-0"])
    }

    // Tanınamayan toplantı dilinde başka dilde sanılan cümle de, gerçekten başka dildeki cümle de atlanmaz; tanınan
    // dillerde süzme sürer.
    @Test func undetectableMeetingLanguagesSkipNothing() {
        #expect(!isOtherLanguage(spokenLanguage: "fi", meetingLanguage: .estonian))
        #expect(!isOtherLanguage(spokenLanguage: "en", meetingLanguage: .latvian))
        #expect(!isOtherLanguage(spokenLanguage: "pl", meetingLanguage: .lithuanian))
        #expect(!isOtherLanguage(spokenLanguage: "ar", meetingLanguage: .persian))
        #expect(isOtherLanguage(spokenLanguage: "en", meetingLanguage: .polish))
    }

    // Dil bölümle birlikte saklanır; dil alanı olmayan eski kayıtlar okunur.
    @Test func spokenLanguageRoundTripsAndOldJSONDecodes() throws {
        let labeled: StoredSegment = segment(key: "final-0", person: 1, startSec: 0, text: swedishSentence).with(spokenLanguage: "sv")
        let decoded: StoredSegment = try JSONDecoder().decode(StoredSegment.self, from: try JSONEncoder().encode(labeled))
        #expect(decoded == labeled)
        let old: Data = Data(#"{"key":"others-0","speaker":"others","person":1,"startSec":0,"endSec":2,"text":"Hei"}"#.utf8)
        #expect(try JSONDecoder().decode(StoredSegment.self, from: old).spokenLanguage == nil)
        let record: MeetingRecord = meeting(segments: [labeled], fixedLanguage: .finnish)
        #expect(try JSONDecoder().decode(MeetingRecord.self, from: try JSONEncoder().encode(record)).fixedLanguage == .finnish)
    }
}
