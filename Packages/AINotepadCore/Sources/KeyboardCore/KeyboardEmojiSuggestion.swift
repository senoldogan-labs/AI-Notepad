import Foundation

/// Emoji for a typed word, from two small keyword tables (English and Turkish; one line per emoji: the emoji, then its
/// keywords). Kept to a few hundred words because the keyboard extension has a tight memory limit. Emoji are drawn by
/// the system font; nothing here is an image.
private let keyboardEmojiKeywordsEnglish: String = """
😀 happy smile grin
😂 lol lmao funny haha
🤣 rofl
😊 blush
😍 adore crush
🥰 loving
😘 kiss kisses
😭 sob crying cry
😢 sad tear
😡 angry mad
😱 scream shocked
😴 sleep sleepy tired zzz
🤔 thinking hmm
😎 cool sunglasses
🥳 party celebrate
🤯 mindblown
🙄 eyeroll
😅 phew
🤗 hug hugs
🙏 pray please thanks thankyou
👍 thumbsup approve ok
👎 thumbsdown dislike
👏 clap applause bravo
🙌 hooray praise
💪 strong muscle
👋 hello hi wave bye
👀 eyes look watching
🔥 fire hot lit
✨ sparkle sparkles magic
💯 hundred
❤️ love heart
💔 heartbreak broken
💙 blue
💚 green
💜 purple
🖤 black
🎉 congrats congratulations tada
🎂 birthday cake
🎁 gift present
🎈 balloon
🎵 music song
🎧 headphones
🎤 microphone karaoke sing
🎬 movie film cinema
🎮 game gaming
⚽ soccer football
🏀 basketball
🎾 tennis
🏆 trophy winner champion win
🍕 pizza
🍔 burger hamburger
🍟 fries
🌭 hotdog
🌮 taco
🍣 sushi
🍜 noodles ramen
🍝 pasta spaghetti
🥗 salad
🍞 bread
🧀 cheese
🥚 egg
🍳 breakfast
🍎 apple
🍌 banana
🍓 strawberry
🍉 watermelon
🍇 grapes
🍋 lemon
🍑 peach
🥑 avocado
🍫 chocolate
🍪 cookie
🍩 donut doughnut
🍦 icecream
🍰 dessert
🍿 popcorn
☕ coffee
🍵 tea
🍺 beer
🍷 wine
🍸 cocktail
🥂 cheers toast champagne
💧 water drop
🐶 dog puppy
🐱 cat kitty
🐭 mouse
🐰 bunny rabbit
🦊 fox
🐻 bear
🐼 panda
🐯 tiger
🦁 lion
🐸 frog
🐵 monkey
🐔 chicken
🐧 penguin
🐦 bird
🦄 unicorn
🐝 bee
🦋 butterfly
🐢 turtle
🐍 snake
🐙 octopus
🐬 dolphin
🐳 whale
🦈 shark
🌹 rose
🌸 blossom flower
🌻 sunflower
🌲 tree
🌴 palm
🍀 clover luck lucky
🌍 world earth
☀️ sun sunny
🌙 moon
⭐ star
☁️ cloud
🌧️ rain rainy
⛈️ storm thunder
❄️ snow cold winter
🌈 rainbow
🏠 home house
🚗 car
🚕 taxi
🚌 bus
🚆 train
✈️ plane airplane flight
🚀 rocket launch
🚲 bike bicycle
⛵ boat sailing
🏖️ beach vacation
🏝️ island
⛰️ mountain
📱 phone iphone mobile
💻 laptop computer
⌚ watch
📷 camera photo
📚 books
📖 book reading
✏️ pencil
📝 memo notes
📅 calendar
⏰ alarm
💡 idea lightbulb
🔑 key
🔒 lock secure
💰 money cash
💸 spending
💳 credit
🎓 graduation graduate
💼 work briefcase business
📈 growth
🧠 brain smart
💩 poop
👻 ghost
💀 skull
🤖 robot
👽 alien
🎃 halloween pumpkin
🎄 christmas
🎅 santa
🇹🇷 turkey
🇺🇸 usa america
🇬🇧 britain
✅ done check
❌ cross wrong
⚠️ warning
❓ question
❗ important
🚫 forbidden
💬 chat message
📞 call
📧 email
🛒 shopping cart
🛏️ bed
🚿 shower
🧹 cleaning
🧸 teddy
🩺 doctor
💊 pill medicine
🏥 hospital
🏫 school
⏳ waiting
💤 nap
🌅 sunrise
🌃 night
🌊 wave ocean sea
🔔 bell notification
🤝 handshake deal
🤞 fingers crossed
✌️ peace victory
🤷 shrug idk
🤦 facepalm
🙈 shy
🥺 pleading
😋 yummy delicious
🤤 drooling
🤒 sick ill
🤧 sneeze
🥶 freezing
🥵 sweating
😇 angel
😈 devil
"""

private let keyboardEmojiKeywordsTurkish: String = """
😀 mutlu gülümseme
😂 komik gülmek kahkaha
🤣 yerlerdeyim
😊 memnun
😍 hayran
🥰 sevgi
😘 öpücük
😭 ağlamak
😢 üzgün gözyaşı
😡 kızgın sinirli
😱 şok korku
😴 uyku uykulu yorgun
🤔 düşünmek hmm
😎 havalı
🥳 kutlama parti
🙄 sıkıcı
🤗 sarılmak kucaklama
🙏 lütfen teşekkürler sağol dua
👍 tamam onay beğen
👎 beğenmedim
👏 alkış bravo
🙌 yaşasın
💪 güçlü kas
👋 merhaba selam hoşçakal
👀 bakmak
🔥 ateş yangın
✨ parıltı sihir
💯 yüz
❤️ aşk kalp sevgi
💔 kırık
🎉 tebrikler
🎂 doğumgünü pasta
🎁 hediye
🎈 balon
🎵 müzik şarkı
🎧 kulaklık
🎤 mikrofon
🎬 film sinema
🎮 oyun
⚽ futbol
🏀 basketbol
🎾 tenis
🏆 kupa şampiyon
🍕 pizza
🍔 hamburger
🍟 patates
🌭 sosisli
🌮 tako
🍣 suşi
🍜 çorba makarna
🍝 spagetti
🥗 salata
🍞 ekmek
🧀 peynir
🥚 yumurta
🍳 kahvaltı
🍎 elma
🍌 muz
🍓 çilek
🍉 karpuz
🍇 üzüm
🍋 limon
🍑 şeftali
🥑 avokado
🍫 çikolata
🍪 kurabiye bisküvi
🍩 çörek
🍦 dondurma
🍰 tatlı
🍿 patlamışmısır
☕ kahve
🍵 çay
🍺 bira
🍷 şarap
🥂 şerefe
💧 su damla
🐶 köpek
🐱 kedi
🐭 fare
🐰 tavşan
🦊 tilki
🐻 ayı
🐼 panda
🐯 kaplan
🦁 aslan
🐸 kurbağa
🐵 maymun
🐔 tavuk
🐧 penguen
🐦 kuş
🦄 tekboynuz
🐝 arı
🦋 kelebek
🐢 kaplumbağa
🐍 yılan
🐙 ahtapot
🐬 yunus
🐳 balina
🌹 gül
🌸 çiçek
🌻 ayçiçeği
🌲 ağaç
🌴 palmiye
🍀 yonca şans
🌍 dünya
☀️ güneş güneşli
🌙 ay
⭐ yıldız
☁️ bulut
🌧️ yağmur
⛈️ fırtına
❄️ kar soğuk kış
🌈 gökkuşağı
🏠 ev
🚗 araba
🚕 taksi
🚌 otobüs
🚆 tren
✈️ uçak uçuş
🚀 roket
🚲 bisiklet
⛵ tekne
🏖️ plaj tatil
🏝️ ada
⛰️ dağ
📱 telefon
💻 bilgisayar dizüstü
⌚ saat
📷 kamera fotoğraf
📚 kitaplar
📖 kitap okumak
✏️ kalem
📝 not
📅 takvim
⏰ alarm
💡 fikir ampul
🔑 anahtar
🔒 kilit
💰 para
💳 kart
🎓 mezuniyet
💼 iş çanta
📈 büyüme
🧠 beyin
💩 kaka
👻 hayalet
💀 kafatası
🤖 robot
👽 uzaylı
🎃 cadılarbayramı balkabağı
🎄 noel
🎅 noelbaba
🇹🇷 türkiye
✅ tamamlandı
❌ yanlış
⚠️ uyarı
❓ soru
❗ önemli
🚫 yasak
💬 sohbet mesaj
📞 arama
📧 eposta
🛒 alışveriş
🛏️ yatak
🚿 duş
🧹 temizlik
🩺 doktor
💊 ilaç hap
🏥 hastane
🏫 okul
⏳ bekleme
🌅 gündoğumu
🌃 gece
🌊 dalga deniz
🔔 zil bildirim
🤝 anlaşma el sıkışma
🤞 şans
✌️ barış zafer
🤷 bilmiyorum
🤦 yüzüme
🙈 utangaç
🥺 yalvarma
😋 lezzetli nefis
🤒 hasta
🥶 donmak üşümek
🥵 sıcak bunalmak
😇 melek
😈 şeytan
"""

private func keyboardEmojiTable(text: String) -> [String: String] {
    var table: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts: [Substring] = line.split(separator: " ")
        guard let emoji = parts.first else {
            continue
        }
        for keyword in parts.dropFirst() where table[String(keyword)] == nil {
            table[String(keyword)] = String(emoji)
        }
    }
    return table
}

private let keyboardEmojiTableEnglish: [String: String] = keyboardEmojiTable(text: keyboardEmojiKeywordsEnglish)
private let keyboardEmojiTableTurkish: [String: String] = keyboardEmojiTable(text: keyboardEmojiKeywordsTurkish)

/// The emoji for a typed word: the language's own table first (Turkish has one), then English, which applies in every
/// language. Whole word only, ignoring case (Turkish rules in Turkish: "AŞK" is "aşk"). Nil when there is none. Pure
/// function.
public func keyboardEmojiSuggestion(word: String, language: KeyboardLanguage) -> String? {
    guard word.count >= 2 else {
        return nil
    }
    let lowered: String = word.lowercased(with: language.casingLocale)
    if language == .turkish, let emoji = keyboardEmojiTableTurkish[lowered] {
        return emoji
    }
    return keyboardEmojiTableEnglish[lowered]
}

/// The suggestion bar with the emoji in its last slot: the bar holds three, so the emoji replaces the third item,
/// unless that item is the pending autocorrection (which must stay visible; then the bar is unchanged). Pure function.
public func keyboardSuggestionsAddingEmoji(_ suggestions: KeyboardSuggestions, emoji: String) -> KeyboardSuggestions {
    let kept: [KeyboardSuggestion] = Array(suggestions.items.prefix(2))
    if suggestions.items.count > 2, let correction = suggestions.autocorrection, !kept.contains(where: { $0.text == correction }) {
        return suggestions
    }
    return KeyboardSuggestions(items: kept + [KeyboardSuggestion(text: emoji, kind: .emoji)], autocorrection: suggestions.autocorrection)
}

/// A ":word" being typed (Settings › Keyboard, "Emoji shortcodes"): the letters after the colon and how many characters
/// the colon and letters take before the cursor.
public struct KeyboardEmojiShortcode: Sendable, Hashable {
    public let query: String
    public let length: Int

    public init(query: String, length: Int) {
        self.query = query
        self.length = length
    }
}

/// The shortcode right before the cursor: a colon that starts a word (at the start of the text, after whitespace or an
/// opening bracket or quote; so not in "10:30", "https://" or "a:b") followed by at least two letters. Nil otherwise.
/// Pure function.
public func keyboardEmojiShortcode(contextBefore: String) -> KeyboardEmojiShortcode? {
    let letters: String = String(contextBefore.reversed().prefix { $0.isLetter }.reversed())
    guard letters.count >= 2 else {
        return nil
    }
    let beforeLetters: Substring = contextBefore.dropLast(letters.count)
    guard beforeLetters.last == ":" else {
        return nil
    }
    let beforeColon: Character? = beforeLetters.dropLast().last
    if let beforeColon, !beforeColon.isWhitespace, !"([{\"'“‘".contains(beforeColon) {
        return nil
    }
    return KeyboardEmojiShortcode(query: letters, length: letters.count + 1)
}

/// The emoji whose keyword starts with `query`, best first: a keyword that is exactly the query, then the language's own
/// keywords (Turkish has a table; English applies in every language), then shorter keywords, then alphabetical. One
/// entry per emoji, at most `limit`. Ignores case (Turkish rules in Turkish). Pure function.
public func keyboardEmojiShortcodeMatches(query: String, language: KeyboardLanguage, limit: Int) -> [String] {
    let lowered: String = query.lowercased(with: language.casingLocale)
    guard !lowered.isEmpty else {
        return []
    }
    let tables: [[String: String]] = language == .turkish
        ? [keyboardEmojiTableTurkish, keyboardEmojiTableEnglish] : [keyboardEmojiTableEnglish]
    var candidates: [(exact: Bool, group: Int, keyword: String, emoji: String)] = []
    for (group, table) in tables.enumerated() {
        for (keyword, emoji) in table where keyword.hasPrefix(lowered) {
            candidates.append((keyword == lowered, group, keyword, emoji))
        }
    }
    candidates.sort { (a: (exact: Bool, group: Int, keyword: String, emoji: String), b: (exact: Bool, group: Int, keyword: String, emoji: String)) -> Bool in
        if a.exact != b.exact {
            return a.exact
        }
        if a.group != b.group {
            return a.group < b.group
        }
        if a.keyword.count != b.keyword.count {
            return a.keyword.count < b.keyword.count
        }
        return a.keyword < b.keyword
    }
    var result: [String] = []
    for candidate in candidates where !result.contains(candidate.emoji) {
        result.append(candidate.emoji)
        if result.count == limit {
            break
        }
    }
    return result
}
