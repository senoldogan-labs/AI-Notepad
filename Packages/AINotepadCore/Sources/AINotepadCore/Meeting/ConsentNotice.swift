import Foundation

/// Kayıt başında katılımcılara söylenecek ya da yazılacak cümle, toplantının dilinde. Arayüz dilinden bağımsızdır
/// (cümle toplantıdakiler içindir), bu yüzden metin kataloğunda değil bu tablodadır. Tabloda olmayan dilde nil.
/// Saf fonksiyondur.
public func consentNoticeSentence(language: MeetingLanguage) -> String? {
    switch language {
    case .finnish: "Hei! Tallennan tämän kokouksen, jotta voin tehdä siitä muistiinpanot."
    case .english: "Hi! I'm recording this meeting so I can take notes."
    case .swedish: "Hej! Jag spelar in det här mötet för att kunna föra anteckningar."
    case .norwegian: "Hei! Jeg tar opp dette møtet slik at jeg kan ta notater."
    case .danish: "Hej! Jeg optager dette møde, så jeg kan tage noter."
    case .estonian: "Tere! Salvestan selle koosoleku, et saaksin märkmeid teha."
    case .german: "Hallo! Ich nehme dieses Meeting auf, um mir Notizen zu machen."
    case .dutch: "Hoi! Ik neem deze vergadering op zodat ik aantekeningen kan maken."
    case .french: "Bonjour ! J'enregistre cette réunion pour prendre des notes."
    case .spanish: "¡Hola! Estoy grabando esta reunión para tomar notas."
    case .portuguese: "Olá! Estou gravando esta reunião para fazer anotações."
    case .italian: "Ciao! Sto registrando questa riunione per prendere appunti."
    case .polish: "Cześć! Nagrywam to spotkanie, żeby robić notatki."
    case .turkish: "Merhaba! Not alabilmek için bu toplantıyı kaydediyorum."
    case .russian: "Здравствуйте! Я записываю эту встречу, чтобы делать заметки."
    case .ukrainian: "Привіт! Я записую цю зустріч, щоб робити нотатки."
    case .japanese: "こんにちは。メモを取るため、この会議を録音しています。"
    case .korean: "안녕하세요! 메모를 위해 이 회의를 녹음하고 있습니다."
    case .chinese: "大家好！我正在录制这次会议，以便做笔记。"
    default: nil
    }
}

/// Katılımcılara gösterilecek cümleler: toplantının dilinde (tabloda varsa) ve İngilizce (toplantı İngilizce değilse;
/// karma ekiplerde herkes anlasın). Saf fonksiyondur.
public func consentNoticeSentences(language: MeetingLanguage) -> [String] {
    let english: String = consentNoticeSentence(language: .english) ?? ""
    guard language != .english, let local = consentNoticeSentence(language: language) else {
        return [english]
    }
    return [local, english]
}
