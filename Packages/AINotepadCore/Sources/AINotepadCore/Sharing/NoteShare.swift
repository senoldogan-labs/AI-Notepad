import CryptoKit
import Foundation

// Notu bağlantıyla paylaşma (uçtan uca şifreli). Gönderen not sayfasının gördüğü bölümleri tek bir JSON yüküne yazar,
// yükü sıkıştırıp paylaşıma özgü rastgele anahtarla AES-256-GCM ile şifreler ve sunucuya yalnızca şifreli metni yükler
// (`server/src/shares.ts`). Anahtar yalnızca bağlantının `#` parçasındadır (`https://gistsmith.com/s#<kimlik>.<anahtar>`);
// tarayıcı bu parçayı hiçbir sunucuya göndermez. Sitenin paylaşım sayfası (`web/src/client/share.ts`) aynı biçimi açar;
// iki taraf `NoteShareVectorTests` ve `web/src/lib/share-crypto.test.ts` içindeki ortak test vektörüyle denetlenir.

/// Paylaşılan notun yükü (sürüm 1). Metinler gönderende biçimlenir (tarih, süre, bölüm başlıkları); sayfa çeviri
/// bilmez, yalnızca gösterir. Boş dizi o bölümün gösterilmeyeceği demektir.
public struct SharedNotePayload: Sendable, Equatable, Codable {
    /// Biçim sürümü; sayfa tanımadığı sürümü açmaz.
    public let v: Int
    /// Notun dili (BCP 47; sayfanın `lang`'ı).
    public let lang: String
    /// Sağdan sola yazılan dil (Arapça, İbranice, Farsça).
    public let rtl: Bool
    public let title: String
    /// Tarih ve süre ("6 Kasım 2026 10:00 · 32 dk").
    public let subtitle: String
    public let headings: SharedNoteHeadings
    public let summary: String
    public let outline: [SharedOutlineItem]
    public let decisions: [String]
    public let openQuestions: [String]
    public let tasks: [SharedTask]
    public let glossary: [SharedGlossaryEntry]
    /// Transkript yalnızca kullanıcı "Transkripti ekle"yi seçtiyse; değilse nil.
    public let transcript: [SharedTranscriptParagraph]?
}

/// Bölüm başlıkları (notun dilinde; asıl notta arayüz dilinde).
public struct SharedNoteHeadings: Sendable, Equatable, Codable {
    public let summary: String
    public let outline: String
    public let decisions: String
    public let openQuestions: String
    public let tasks: String
    public let glossary: String
    public let transcript: String
}

/// Konu akışında bir bölüm.
public struct SharedOutlineItem: Sendable, Equatable, Codable {
    public let time: String
    public let title: String
    public let summary: String
}

/// Bir görev.
public struct SharedTask: Sendable, Equatable, Codable {
    public let owner: String
    public let description: String
    public let due: String?
}

/// Sözlükte bir terim.
public struct SharedGlossaryEntry: Sendable, Equatable, Codable {
    public let term: String
    public let meaning: String
}

/// Transkriptte bir paragraf.
public struct SharedTranscriptParagraph: Sendable, Equatable, Codable {
    public let time: String
    public let speaker: String
    public let text: String
}

/// Paylaşım yükünün biçim sürümü.
public let sharedNotePayloadVersion: Int = 1

/// Notun tarih ve süre satırı: paylaşım dilinde (`language`) o dilin yerel ayarıyla ve evrensel "min", asıl notta
/// arayüz dilinde ve "dk". Web sayfası dışa aktarımı ve paylaşılan not aynı satırı gösterir. Saf fonksiyondur.
public func noteDateLine(record: MeetingRecord, language: ShareLanguage?) -> String {
    let locale: Locale = language.map { Locale(identifier: $0.rawValue) } ?? interfaceLocale()
    let date: String = record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(locale))
    let minutes: String = meetingDurationMinutes(record: record).map { (value: Int) -> String in
        language == nil ? " · " + String(localized: "\(value) dk") : " · \(value) min"
    } ?? ""
    return date + minutes
}

/// Seçili paylaşım dilinin (`language`) çevirisi henüz yok: paylaşılan not asıl dilde gider; kullanıcıya söylenmelidir.
/// Asıl not (nil) ya da notu olmayan kayıt için false. Saf fonksiyondur.
public func isShareTranslationMissing(record: MeetingRecord, language: ShareLanguage?) -> Bool {
    guard let language, record.note != nil else {
        return false
    }
    return record.sharedNotes?[language.rawValue] == nil
}

/// Notun paylaşım yükü: başlık, tarih, özet, konu akışı, kararlar, açık konular, görevler (sahibi ve tarihiyle),
/// sözlük ve isteğe bağlı transkript (`transcript`; konuşmacı adları toplantı sayfasındakiyle aynı). Ses, ekran
/// görüntüleri ve kişisel işaretler (görevin bitti işareti, "Sen") girmez. `language` paylaşım dili (başlıklar o dilde);
/// nil ise asıl not. Saf fonksiyondur.
public func sharedNotePayload(record: MeetingRecord, note: MeetingNote, language: ShareLanguage?, transcript: [TranscriptParagraph]?) -> SharedNotePayload {
    let headings: NoteHeadings = noteHeadings(language: language)
    let pageLanguage: ShareLanguage = language ?? note.writtenLanguage
    return SharedNotePayload(
        v: sharedNotePayloadVersion,
        lang: pageLanguage.rawValue,
        rtl: pageLanguage.isRightToLeft,
        title: note.title,
        subtitle: noteDateLine(record: record, language: language),
        headings: SharedNoteHeadings(
            summary: headings.summary, outline: headings.outline, decisions: headings.decisions, openQuestions: headings.openQuestions,
            tasks: headings.tasks, glossary: headings.glossary, transcript: String(localized: "Transkript")
        ),
        summary: note.summary,
        outline: (note.outline ?? []).map { SharedOutlineItem(time: timestamp(seconds: $0.startSec), title: $0.title, summary: $0.summary) },
        decisions: note.decisions,
        openQuestions: note.openQuestions ?? [],
        tasks: note.tasks.map { SharedTask(owner: $0.owner, description: $0.description, due: $0.dueDate) },
        glossary: note.glossary.map { SharedGlossaryEntry(term: $0.term, meaning: $0.meaning) },
        transcript: transcript.map { (paragraphs: [TranscriptParagraph]) -> [SharedTranscriptParagraph] in
            paragraphs.map { (paragraph: TranscriptParagraph) -> SharedTranscriptParagraph in
                SharedTranscriptParagraph(
                    time: timestamp(seconds: paragraph.startSec),
                    speaker: paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames),
                    text: paragraph.text
                )
            }
        }
    )
}

// MARK: - Şifreleme

/// Paylaşım bloğunun biçim işareti (`GSS1`); sunucu (`server/src/shares.ts` `shareBlobMagic`) ve sayfa denetler.
public let noteShareMagic: String = "GSS1"
/// Paylaşım kimliğinin bayt sayısı (base64url'de 22 karakter).
let noteShareIDBytes: Int = 16
private let noteShareNonceBytes: Int = 12
private let noteShareTagBytes: Int = 16
/// Sunucunun kabul ettiği en büyük blok (`server/src/shares.ts` `shareMaxBytes`, `ServerParityTests`): transkriptli
/// 4 saatlik toplantı sıkıştırılınca ~0,7 MB.
public let noteShareMaxBytes: Int = 1_048_576

/// Bir hesabın en çok etkin bağlantısı (`server/src/shares.ts` `shareMaxActivePerUser`).
public let noteShareMaxActiveLinks: Int = 50

/// Bağlantının ömrü (sunucunun `shareExpiryDays` listesi).
public enum NoteShareExpiry: Int, Sendable, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    public var id: Int { rawValue }
}

/// Paylaşım bloğu oluşturulamadı ya da açılamadı.
public enum NoteShareError: Error, Sendable, Equatable {
    /// Şifreli not sunucunun sınırından büyük (çoğunlukla uzun transkript yüzünden).
    case tooLarge(byteCount: Int)
    /// Blok kısa ya da `GSS1` ile başlamıyor.
    case malformedBlob(byteCount: Int)
    /// Kimlik doğrulama başarısız: yanlış anahtar, değişmiş blok ya da başka kimliğin bloğu.
    case authenticationFailed
    /// Bağlantı paylaşım bağlantısı değil ya da anahtarı eksik.
    case invalidLink
    /// Yük tanınmayan bir sürümde.
    case unsupportedVersion(version: Int)
}

/// Bir paylaşımın sırrı: rastgele kimlik (sunucuya gider) ve rastgele 256 bit anahtar (yalnızca bağlantıda).
public struct NoteShareSecret: Sendable, Equatable {
    /// 16 rastgele bayt, base64url (22 karakter).
    public let shareID: String
    let key: SymmetricKey

    init(shareID: String, key: SymmetricKey) {
        self.shareID = shareID
        self.key = key
    }

    /// Anahtarın base64url biçimi (43 karakter; bağlantının parçası).
    public var keyText: String {
        key.withUnsafeBytes { base64URLEncoded(Data($0)) }
    }

    public static func == (lhs: NoteShareSecret, rhs: NoteShareSecret) -> Bool {
        lhs.shareID == rhs.shareID && lhs.keyText == rhs.keyText
    }
}

/// Yeni paylaşım için taze kimlik ve anahtar (sistemin güvenli rastgele üreteci). Her paylaşımın anahtarı tek bir
/// şifrelemede kullanılır; aynı anahtarla iki nonce olmadığı için nonce tekrarı olamaz.
public func newNoteShareSecret() -> NoteShareSecret {
    var generator: SystemRandomNumberGenerator = SystemRandomNumberGenerator()
    let idBytes: Data = Data((0..<noteShareIDBytes).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    return NoteShareSecret(shareID: base64URLEncoded(idBytes), key: SymmetricKey(size: .bits256))
}

/// Bağlantıdaki kimlik ve anahtardan sır; biçim tutmazsa `invalidLink`. Saf fonksiyondur.
public func noteShareSecret(shareID: String, keyText: String) throws -> NoteShareSecret {
    guard isNoteShareID(shareID), let keyData = base64URLDecoded(keyText), keyData.count == 32 else {
        throw NoteShareError.invalidLink
    }
    return NoteShareSecret(shareID: shareID, key: SymmetricKey(data: keyData))
}

/// Paylaşım kimliğinin biçimi: 22 base64url karakteri (16 bayt). Saf fonksiyondur.
public func isNoteShareID(_ text: String) -> Bool {
    text.count == 22 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
}

/// Ek doğrulama verisi: biçim işareti ve paylaşım kimliği. Blok başka kimliğe taşınırsa açılmaz.
private func noteShareAAD(shareID: String) -> Data {
    Data((noteShareMagic + shareID).utf8)
}

/// Yükü şifreli bloğa çevirir: `GSS1` ‖ nonce (12) ‖ şifreli metin ‖ etiket (16). Şifreli metin, kanonik JSON'un
/// ham DEFLATE (RFC 1951; tarayıcıda `DecompressionStream("deflate-raw")`) sıkıştırmasıdır. `nonce` nil ise rastgele
/// (yalnızca test vektörü sabit nonce verir). Sunucu sınırını aşan blok `tooLarge`.
public func sealNoteShare(payload: SharedNotePayload, secret: NoteShareSecret, nonce: AES.GCM.Nonce?) throws -> Data {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json: Data = try encoder.encode(payload)
    let compressed: Data = try (json as NSData).compressed(using: .zlib) as Data
    let sealed: AES.GCM.SealedBox = try AES.GCM.seal(compressed, using: secret.key, nonce: nonce ?? AES.GCM.Nonce(), authenticating: noteShareAAD(shareID: secret.shareID))
    let blob: Data = Data(noteShareMagic.utf8) + Data(sealed.nonce) + sealed.ciphertext + sealed.tag
    guard blob.count <= noteShareMaxBytes else {
        throw NoteShareError.tooLarge(byteCount: blob.count)
    }
    return blob
}

/// Şifreli bloğu açar ve yükü okur (testler ve ortak vektör için; uygulama kendi paylaşımını açmaz). Saf fonksiyondur.
public func openNoteShare(blob: Data, secret: NoteShareSecret) throws -> SharedNotePayload {
    let header: Int = noteShareMagic.utf8.count
    guard blob.count >= header + noteShareNonceBytes + noteShareTagBytes, blob.prefix(header) == Data(noteShareMagic.utf8) else {
        throw NoteShareError.malformedBlob(byteCount: blob.count)
    }
    let body: Data = blob.dropFirst(header)
    let compressed: Data
    do {
        let box: AES.GCM.SealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: body.prefix(noteShareNonceBytes)),
            ciphertext: body.dropFirst(noteShareNonceBytes).dropLast(noteShareTagBytes),
            tag: body.suffix(noteShareTagBytes)
        )
        compressed = try AES.GCM.open(box, using: secret.key, authenticating: noteShareAAD(shareID: secret.shareID))
    } catch {
        throw NoteShareError.authenticationFailed
    }
    let json: Data = try (compressed as NSData).decompressed(using: .zlib) as Data
    let payload: SharedNotePayload = try JSONDecoder().decode(SharedNotePayload.self, from: json)
    guard payload.v == sharedNotePayloadVersion else {
        throw NoteShareError.unsupportedVersion(version: payload.v)
    }
    return payload
}

// MARK: - Bağlantı

/// Paylaşım sayfasının adresi (anahtar `#` parçasında). `siteOrigin`: `https://gistsmith.com` (yerelde
/// `http://localhost:8788`). Saf fonksiyondur.
public func noteShareLink(siteOrigin: URL, secret: NoteShareSecret) -> URL {
    var components: URLComponents = URLComponents()
    components.scheme = siteOrigin.scheme
    components.host = siteOrigin.host()
    components.port = siteOrigin.port
    components.path = "/s"
    components.fragment = "\(secret.shareID).\(secret.keyText)"
    guard let url = components.url else {
        preconditionFailure("Paylaşım bağlantısı kurulamadı: \(siteOrigin.absoluteString)")
    }
    return url
}

/// Bağlantıdan sır: `/s#<kimlik>.<anahtar>`; değilse `invalidLink`. Saf fonksiyondur.
public func noteShareSecret(link: URL) throws -> NoteShareSecret {
    guard link.path() == "/s", let fragment = link.fragment() else {
        throw NoteShareError.invalidLink
    }
    let parts: [Substring] = fragment.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        throw NoteShareError.invalidLink
    }
    return try noteShareSecret(shareID: String(parts[0]), keyText: String(parts[1]))
}

/// base64url, dolgusuz. Saf fonksiyondur.
func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Dolgusuz base64url çözümü; geçersizse nil. Saf fonksiyondur.
func base64URLDecoded(_ text: String) -> Data? {
    guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
        return nil
    }
    let standard: String = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
}
