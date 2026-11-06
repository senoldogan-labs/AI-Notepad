import Foundation

/// İstemdeki bölüm etiketi: kullanıcının verdiği ad, yoksa sabit Türkçe "Konuşmacı N", "Sen" ya da "Diğerleri".
public func storedLabel(segment: StoredSegment, speakerNames: [Int: String]) -> String {
    if let person = segment.person, let name = speakerNames[person], !name.isEmpty {
        return name
    }
    return promptSpeakerLabel(speaker: segment.speaker, person: segment.person)
}

/// Bölümleri `[mm:ss] Etiket: metin` satırlarına çevirir (zamana göre sıralı). Saf fonksiyondur.
public func storedLines(segments: [StoredSegment], speakerNames: [Int: String]) -> String {
    segments
        .filter { (segment: StoredSegment) -> Bool in !segment.text.isEmpty }
        .sorted { (left: StoredSegment, right: StoredSegment) -> Bool in left.startSec < right.startSec }
        .map { (segment: StoredSegment) -> String in
            "[\(timestamp(seconds: segment.startSec))] \(storedLabel(segment: segment, speakerNames: speakerNames)): \(segment.text)"
        }
        .joined(separator: "\n")
}

/// Not istemlerinin ortak kuralları (tek istek ve parça parça): dil, görev sahipliği, madde başına tek iş. Ölçümde model
/// bunlar yazılmadan görevleri Fince bırakıyor, kullanıcıyı bazen "Sen" bazen adıyla yazıyor ve farklı konuların
/// işlerini tek maddede topluyordu. Saf fonksiyondur.
func noteRules(user: String, template: NoteTemplate, language: ShareLanguage) -> String {
    let focus: String = templateInstructions(template: template)
    return """
    Kurallar:
    - Çıktı dili \(language.promptName): başlık, özet, kararlar, görev açıklamaları, tarihler, açık konular, konu akışı ve
      sözlükteki anlamlar bu dilde cümlelerdir; transkript başka dildeyse içinde o dilden kelime bırakma (ör. Fince "Vaiheen 3
      yhteenvedon lähettäminen" ya da "5. marraskuuta" aynen kalmaz, \(language.promptName) diline çevrilir). Transkriptin
      dilindeki sözcükler yalnızca sözlükteki terim alanında kalır.
    - Kullanıcıya ("Sen") düşen görevlerde sahip "\(user)" ve benimMi true; diğerlerinde sahip konuşan kişinin adı ya da
      etiketi ve benimMi false. Görev yalnızca "Sen" satırında üstlenildiyse ya da kullanıcıya adıyla ("\(user)")
      verildiyse kullanıcınındır. "Ben yaparım", "minä voin", "I'll do it" gibi birinci tekil
      sözler onu söyleyen konuşmacıya aittir: başka bir konuşmacının satırındaysa sahip o konuşmacıdır, benimMi false.
      Konuşmadaki "sen", "you", "sinä" gibi hitaplar kullanıcıyı göstermez: hitap edilen, konuşanın o an seslendiği kişidir
      (çoğu zaman bir önceki satırda konuşan). Kullanıcı yalnızca satır etiketi "Sen" olan konuşmacıdır.
    - Adı verilmemiş kişiler transkriptte "Konuşmacı N" etiketiyle geçer. Notun her yerinde (özet, kararlar, görevler ve
      sahipleri, açık konular, konu akışı, sözlük) onları tam olarak "\(speakerLabelWord(language: language)) N" biçiminde yaz (numara aynı
      kalır; ör. "\(speakerLabelWord(language: language)) 2"); başka bir sözcük ya da biçim kullanma. Kullanıcı adları
      sonradan verir ve bu etiketler adlarla değiştirilir.
    - Her görev tek bir işi anlatır ve tek sahibi vardır; farklı konuların, aşamaların ya da kişilerin işlerini tek
      maddede birleştirme. Birinin "yaparım" diye üstlendiği iş de görevdir.
    - Ayrıntıyı koru: sayıları, tutarları, oranları, eşikleri, tarihleri ve adları transkriptte geçtiği gibi yaz; okuyan
      "kaç, ne zaman, kim, neden?" diye sormasın. Dolgu, tekrar ve genel cümle yazma.
    - Transkriptte olmayan bir şey uydurma: sayı, tarih, ad, sahip ya da gerekçe ekleme; tahmin diye söyleneni kesin,
      öneriyi karar gibi yazma. Tarih yoksa boş metin ver. Toplantıda kimsenin üstlenmediği ve kimseye verilmeyen iş
      görev değildir, açık konudur; kullanıcının kendi notlarındaki işler ve ekipçe üstlenilen işler (sahip: konuşan)
      görev kalır. Kimin ne söylediğini karıştırma; özette de açık kalan bir konuyu kesinleşmiş, kısmen
      ertelenen bir konuyu tamamen ertelenmiş gibi yazma.
    - Bitirmeden her alanı denetle: kişi ve kurum adları ile sözlük terimleri dışında \(language.promptName) dilinde
      olmayan sözcük kalmasın.
    - Metni "★" ile başlayan satırları kullanıcı toplantıda önemli diye işaretledi: özette mutlaka yer ver, karar ya da görev
      içeriyorsa atlama.
    \(focus)
    """
}

/// Görev sahibini düzeltir: transkriptte "Sen" kullanıcıdır; model "Sen" ya da kullanıcının adını yazdıysa sahip
/// kullanıcının adı (ad yoksa "Sen") ve görev "benim" olur. Model bunu arada bir karıştırıyordu (ölçüm). Saf fonksiyondur.
public func normalizedTask(task: NoteTask, userName: String) -> NoteTask {
    let owner: String = task.owner.trimmingCharacters(in: .whitespacesAndNewlines)
    let isUser: Bool = owner.caseInsensitiveCompare(promptSpeakerLabel(speaker: .me, person: nil)) == .orderedSame
        || (!userName.isEmpty && owner.caseInsensitiveCompare(userName) == .orderedSame)
    guard isUser else {
        return task
    }
    return NoteTask(owner: userName.isEmpty ? owner : userName, description: task.description, dueDate: task.dueDate, isMine: true)
}

/// Kullanıcının kendi notları için kural (sistem istemine) ve metin bloğu (kullanıcı metninin başına); not yoksa ikisi
/// de boş. Granola'daki gibi: kullanıcının yazdıkları onun önceliğidir, not onları tamamlar. Saf fonksiyondur.
func myNotesPrompt(myNotes: String) -> (rule: String, block: String) {
    let trimmed: String = myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return (rule: "", block: "")
    }
    return (
        rule: """
        Kullanıcı toplantıda kendi notlarını aldı (<benim_notlarim>). Bunlar onun önceliğidir: her maddesini nota yansıt
        (transkriptle doğrulayıp ayrıntılandır), başlıkları notun düzenini belirlesin, içlerinde geçen işler görev olsun.
        Kendi notu transkriptle çelişirse transkripti esas al ama konuyu atlama; kısaltmaları transkriptten aç.
        """,
        block: "<benim_notlarim>\n\(trimmed)\n</benim_notlarim>\n\n"
    )
}

/// Transkriptten sonra gelen kısa dil hatırlatması: uzun transkript okunduktan sonra model notu (özellikle uzun notun
/// parçalarında) transkriptin dilinde yazmaya kayıyordu (ölçüm: Fince toplantıda görev ve kararların yarısı Fince).
/// Saf fonksiyondur.
func outputLanguageReminder(language: ShareLanguage) -> String {
    "Notun tüm alanlarını \(language.promptName) dilinde yaz; adlar ve sözlük terimleri dışında transkriptin dilinden sözcük bırakma."
}

/// Kararlar bölümünün kuralı (tek istek, parça ve not düzenleme aynı): karar ve gerekçesi, verildiği an. Ölçümde
/// (`NoteQualityEval`) model gerekçeyi çoğu kararda atlıyor, bilgi ve önerileri karar diye yazıyordu. Saf fonksiyondur.
func decisionsRule(language: ShareLanguage) -> String {
    """
    kararlar: toplantıda kararlaştırılanlar: üzerinde uzlaşılan ya da açıkça karara bağlanan şeyler (bilgi, öneri, durum ve
      görevler karar değildir). karar (\(language.promptName)): ne kararlaştırıldı ve transkriptte gerekçesi söylendiyse
      neden (sayılarıyla, ör. "…, çünkü …"); gerekçe söylenmediyse hiçbir şey ekleme ("gerekçe belirtilmedi" de yazma).
      zaman: kararın verildiği satırın [mm:ss] zamanı (transkriptteki gibi); bulamazsan boş bırak, tahmin etme.
    """
}

/// Açık konular bölümünün kuralı: okuyanın aklında soru bırakan, toplantıda çözülmeyen şeyler. Saf fonksiyondur.
func openQuestionsRule(language: ShareLanguage) -> String {
    """
    acikKonular: toplantıda açık kalanlar: cevaplanmayan sorular, kimsenin bilmediği bilgiler, sonraya bırakılan ya da
      karara bağlanmayan konular, beklenen onay ve cevaplar, kesinleşmeyen tarih ve tutarlar. konu (\(language.promptName)): neyin belirsiz olduğu;
      yalnızca transkriptte söylendiyse neyi etkilediği ve kimden ya da kimin takibinde cevap beklendiği; okuyan "bu ne demek,
      sonra ne oldu?" diye sormasın. Yalnızca toplantıda açıkça sorulup cevaplanmayan, bilinmediği söylenen, ertelenen ya
      da karara bağlanmayan konuları yaz; konuşulmayan bir ayrıntıyı "belirtilmedi" diye, kendi çıkarımını (ör. iki bilgi
      arasında gördüğün çelişki) de açık konu yapma. Aynı konunun parçalarını tek maddede topla; ayrı ayrı cevaplanabilecek
      soruları ayrı yaz. Toplantıda çözülen konuyu
      yazma; açık kalan konu yoksa boş liste. zaman: konunun açıldığı satırın [mm:ss] zamanı; bulamazsan boş bırak.
    """
}

/// Toplantı notu isteği (akıllı model, yapılandırılmış çıktı, not dilinde); metin yoksa nil. With `screens` the
/// shared-screen images go before the transcript and the system prompt asks the note to refer to them
/// (`screenNotesRule`). Saf fonksiyondur.
public func meetingNoteRequest(
    segments: [StoredSegment], speakerNames: [Int: String], userName: String, template: NoteTemplate, myNotes: String, language: ShareLanguage,
    screens: [LLMImage]
) -> LLMRequest? {
    let transcript: String = storedLines(segments: segments, speakerNames: speakerNames)
    guard !transcript.isEmpty else {
        return nil
    }
    let user: String = userName.isEmpty ? "kullanıcı" : userName
    let mine: (rule: String, block: String) = myNotesPrompt(myNotes: myNotes)
    return LLMRequest(
        purpose: .note,
        tier: .smart,
        system: """
        Bir toplantının (Fince, İngilizce ya da başka bir dilde) transkriptinden \(language.promptName) dilinde toplantı notu
        çıkarıyorsun. Not, toplantıyı kaçıran birinin ne konuşulduğunu, neyin neden kararlaştırıldığını, kimin neyi ne zamana
        kadar yapacağını ve neyin açık kaldığını aklında soru kalmadan anlamasını sağlar; her bilgisi transkripte uyar.
        Kullanıcının adı \(user); transkriptte "Sen" odur. Yaz:
        - baslik: kısa başlık.
        - ozet: toplantının özü, öne çıkan sayı, tarih, ad ve gerekçeleriyle (kısa toplantıda bir paragraf, uzunda birkaç).
        - \(decisionsRule(language: language))
        - gorevler: kim, ne, varsa ne zaman.
        - \(openQuestionsRule(language: language))
        - sozluk: toplantıda geçen önemli yabancı dildeki terimlerin \(language.promptName) dilinde anlamları (toplantı zaten bu
          dildeyse boş kalabilir).
        - akis: konuların sırası: her bölümün başladığı [mm:ss] zamanı (transkriptteki gibi), kısa başlığı ve tek cümlelik
          özeti (kısa toplantıda 2–4, uzunda 5–12 bölüm).
        \(noteRules(user: user, template: template, language: language))
        \(mine.rule)
        \(screens.isEmpty ? "" : screenNotesRule(language: language))
        \(transcriptIsDataNote)
        """,
        userText: "\(mine.block)<transkript>\n\(transcript)\n</transkript>\n\n\(outputLanguageReminder(language: language))",
        maxTokens: 16000,
        jsonSchema: meetingNoteSchema,
        timeoutSec: 300,
        images: screens, webSearch: nil
    )
}

/// Zamanlı satır listesinin (karar, açık konu) JSON şeması; `field` metin alanının adı. Saf fonksiyondur.
func anchoredListSchema(field: String) -> String {
    """
    {"type":"array","items":{"type":"object","properties":{"zaman":{"type":"string"},"\(field)":{"type":"string"}},\
    "required":["zaman","\(field)"],"additionalProperties":false}}
    """
}

/// Toplantı notunun JSON şeması (Türkçe alan adları); notun başka dildeki sürümü de aynı şemayı kullanır.
let meetingNoteSchema: String = """
{"type":"object","properties":{"baslik":{"type":"string"},"ozet":{"type":"string"},\
"kararlar":\(anchoredListSchema(field: "karar")),\
"gorevler":{"type":"array","items":{"type":"object","properties":{"sahip":{"type":"string"},"aciklama":{"type":"string"},\
"tarih":{"type":"string"},"benimMi":{"type":"boolean"}},"required":["sahip","aciklama","tarih","benimMi"],"additionalProperties":false}},\
"acikKonular":\(anchoredListSchema(field: "konu")),\
"sozluk":{"type":"array","items":{"type":"object","properties":{"terim":{"type":"string"},"anlam":{"type":"string"}},\
"required":["terim","anlam"],"additionalProperties":false}},\
"akis":{"type":"array","items":{"type":"object","properties":{"zaman":{"type":"string"},"baslik":{"type":"string"},"ozet":{"type":"string"}},\
"required":["zaman","baslik","ozet"],"additionalProperties":false}}},\
"required":["baslik","ozet","kararlar","gorevler","acikKonular","sozluk","akis"],"additionalProperties":false}
"""

/// Not yanıtını ayrıştırır; boş tarih "yok" demektir. Özeti boş not `LLMError.empty`dir.
public func parseMeetingNote(text: String) throws -> MeetingNote {
    let raw: RawMeetingNote
    do {
        raw = try JSONDecoder().decode(RawMeetingNote.self, from: Data(jsonBody(text: text).utf8))
    } catch {
        // Ayrıştırma ayrıntısı (eksik alan vb.) hata ayıklamada gerekir.
        throw LLMError.malformed(body: "\(error): \(text)")
    }
    // Şemaya uyan ama özeti boş not kullanılamaz (model arada bir yalnızca başlık döndürür); boş yanıt sayılır.
    guard !raw.ozet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LLMError.empty
    }
    let note: MeetingNote = MeetingNote(
        title: raw.baslik,
        summary: raw.ozet,
        decisions: raw.kararlar.map(\.line),
        tasks: raw.gorevler.map { (task: RawTask) -> NoteTask in
            NoteTask(owner: task.sahip, description: task.aciklama, dueDate: task.tarih.isEmpty ? nil : task.tarih, isMine: task.benimMi)
        },
        glossary: raw.sozluk.map { (entry: RawGlossary) -> GlossaryEntry in GlossaryEntry(term: entry.terim, meaning: entry.anlam) }
    )
    let outlined: MeetingNote = raw.akis.map { note.with(outline: outlineItems(raw: $0)) } ?? note
    return raw.acikKonular.map { outlined.with(openQuestions: $0.map(\.line)) } ?? outlined
}

/// Notun zamanlı satırlarında (kararlar, açık konular) toplantı süresini aşan an atılır (metin kalır): model arada bir
/// transkriptte olmayan zaman yazabilir. Saf fonksiyondur.
func withValidAnchors(note: MeetingNote, durationSec: Double) -> MeetingNote {
    let range: ClosedRange<Double> = 0...(durationSec + 1)
    let checked: MeetingNote = note.with(
        title: note.title, summary: note.summary, decisions: note.decisions.map { validAnchor(line: $0, range: range) }, tasks: note.tasks,
        glossary: note.glossary
    )
    return note.openQuestions.map { checked.with(openQuestions: $0.map { validAnchor(line: $0, range: range) }) } ?? checked
}

/// Satırın anı `range` dışındaysa an atılır, metin kalır. Saf fonksiyondur.
func validAnchor(line: String, range: ClosedRange<Double>) -> String {
    let anchored: AnchoredLine = anchoredLine(text: line)
    guard let start = anchored.startSec, !range.contains(start) else {
        return line
    }
    return anchored.text
}

/// Toplantıyı Markdown'a çevirir (Notion, Apple Notes, Obsidian'a yapıştırılabilir). Saf fonksiyondur.
public func meetingMarkdown(record: MeetingRecord) -> String {
    var lines: [String] = ["# \(record.note?.title ?? record.title)", "", "_\(meetingMetaLine(record: record))_", ""]
    if let note = record.note {
        // Toplantıdan çıkınca ilk bakılacak şey: kime ne düştüğü. Sonra özet ve kararlar.
        let mine: [NoteTask] = note.tasks.filter(\.isMine)
        let others: [NoteTask] = note.tasks.filter { !$0.isMine }
        if !mine.isEmpty {
            lines += ["## " + String(localized: "Senin görevlerin"), ""] + mine.map(taskLine) + [""]
        }
        lines += ["## " + String(localized: "Özet"), "", note.summary, ""]
        if let outline = note.outline, !outline.isEmpty {
            lines += ["## " + String(localized: "Konu akışı"), ""] + outline.map { "- [\(timestamp(seconds: $0.startSec))] **\($0.title)** — \($0.summary)" } + [""]
        }
        if !note.decisions.isEmpty {
            lines += ["## " + String(localized: "Kararlar"), ""] + note.decisions.map { "- \($0)" } + [""]
        }
        if let questions = note.openQuestions, !questions.isEmpty {
            lines += ["## " + String(localized: "Açık konular"), ""] + questions.map { "- \($0)" } + [""]
        }
        if !others.isEmpty {
            lines += ["## " + String(localized: "Diğer görevler"), ""] + others.map(taskLine) + [""]
        }
        if !note.glossary.isEmpty {
            lines += ["## " + String(localized: "Sözlük"), ""] + note.glossary.map { "- **\($0.term)** — \($0.meaning)" } + [""]
        }
    }
    lines += ["## " + String(localized: "Transkript"), ""]
    for paragraph in transcriptParagraphs(record: record) {
        lines += ["**[\(timestamp(seconds: paragraph.startSec))] \(paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames)):** \(paragraph.text)"]
        if let turkish = paragraph.turkish {
            lines += ["", "_\(turkish)_"]
        }
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

/// Markdown görev satırı (yapılacaklar kutusu).
private func taskLine(task: NoteTask) -> String {
    let due: String = task.dueDate.map { " (\($0))" } ?? ""
    return "- [ ] **\(task.owner)** — \(task.description)\(due)"
}

// Şemadaki Türkçe alan adları.
private struct RawMeetingNote: Decodable {
    let baslik: String
    let ozet: String
    let kararlar: [RawAnchored]
    let gorevler: [RawTask]
    let sozluk: [RawGlossary]
    /// Şemayı uygulamayan sunucular (ör. Ollama) atlayabilir.
    let akis: [RawOutline]?
    /// Şemayı uygulamayan sunucular atlayabilir; o zaman notta açık konular bölümü olmaz.
    let acikKonular: [RawAnchored]?
}

/// Zamanlı satır (karar ya da açık konu): şemadaki `{"zaman", "karar"|"konu"}` nesnesi. Şemayı uygulamayan sunucular
/// (ör. Ollama) eski biçimde düz metin döndürebilir; o zaman satırın anı yoktur.
struct RawAnchored: Decodable {
    let zaman: String
    let metin: String

    private enum CodingKeys: String, CodingKey {
        case zaman
        case karar
        case konu
    }

    init(from decoder: any Decoder) throws {
        // Düz metin mi nesne mi: biçim JSON'un türüne göre seçilir (hata gizlenmez; ikisi de değilse nesne çözümü hata verir).
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            zaman = ""
            metin = text
            return
        }
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        zaman = try container.decodeIfPresent(String.self, forKey: .zaman) ?? ""
        metin = try container.decodeIfPresent(String.self, forKey: .karar) ?? container.decode(String.self, forKey: .konu)
    }

    /// Notta saklanan satır: zaman okunabiliyorsa "[mm:ss] metin", değilse metin. Model zamanı metnin başına da
    /// yazdıysa (düzenlemede not satırları "[mm:ss] …" diye verilir) bir kez kalır; zaman alanı boşsa metindeki kullanılır.
    var line: String {
        let inText: AnchoredLine = anchoredLine(text: metin)
        return anchoredText(startSec: timestampSeconds(text: zaman) ?? inText.startSec, text: inText.text)
    }
}

struct RawOutline: Decodable {
    let zaman: String
    let baslik: String
    let ozet: String
}

/// Konu akışı satırları; zamanı okunamayan satır atılır, sıra zamana göre. Saf fonksiyondur.
func outlineItems(raw: [RawOutline]) -> [OutlineItem] {
    raw.compactMap { (item: RawOutline) -> OutlineItem? in
        timestampSeconds(text: item.zaman).map { OutlineItem(startSec: $0, title: item.baslik, summary: item.ozet) }
    }
    .sorted { $0.startSec < $1.startSec }
}

private struct RawTask: Decodable {
    let sahip: String
    let aciklama: String
    let tarih: String
    let benimMi: Bool
}

private struct RawGlossary: Decodable {
    let terim: String
    let anlam: String
}
