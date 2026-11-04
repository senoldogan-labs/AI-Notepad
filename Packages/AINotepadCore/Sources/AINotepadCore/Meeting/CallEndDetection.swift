import Foundation

// Görüşme bitince kaydı bitirme: kullanım duvar saatiyle ücretlendirilir (abonelikte dakika, kendi anahtarlarında
// Deepgram); görüşme bittikten sonra unutulup açık kalan kayıt kullanıcının dakikalarını boşa harcar. Mac kayıt
// sırasında başka bir uygulamanın (Teams, Zoom, tarayıcı) mikrofonu kullanıp kullanmadığını izler; görüşme görüldükten
// sonra mikrofon bir süre sessiz kalırsa geri sayım başlar, iptal edilmezse kayıt "Bitir"e basılmış gibi biter.
// Yüz yüze kayıtta başka uygulama mikrofonu hiç kullanmadığından kayıt kendiliğinden bitmez.

/// Mikrofon girişini kullanan bir süreç (Core Audio süreç nesnesinden; bağımsız değer tipi).
public struct AudioInputProcess: Sendable, Equatable {
    public let pid: Int32
    /// Paket kimliği; Core Audio vermezse boş.
    public let bundleID: String

    public init(pid: Int32, bundleID: String) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Mikrofonu kendi sürecinde tutan macOS konuşma ve asistan servislerinin paket kimliği önekleri (küçük harf).
/// "Hey Siri"/"Siri'yi dinle", sistem diktesi, Ses Tanıma ve Sesle Denetim açıkken bu servisler mikrofonu sürekli ya da
/// aralıklı kullanır; görüşme sayılırlarsa görüşme hiç bitmemiş görünür ya da yüz yüze kayıtta yanlış geri sayım
/// başlar. Bu Mac'te Core Audio süreç listesinde "Siri'yi dinle" açıkken `com.apple.CoreSpeech` (corespeechd) girişi
/// kayıt yokken de sürekli kullanıyordu; `com.apple.assistantd`, `com.apple.Siri`, `com.apple.SiriNCService`,
/// `com.apple.accessibility.heard` (Ses Tanıma) ve `com.apple.universalaccessd` de listede görünür. Görüşme taşıyan
/// Apple süreçleri bilerek listede yok: FaceTime (`com.apple.FaceTime`, `com.apple.avconferenced`), Safari ve web
/// görüşmeleri (`com.apple.WebKit.GPU` mikrofonu web sayfası adına tutar), iPhone'dan aktarılan aramalar
/// (`com.apple.TelephonyUtilities`) ve Mesajlar.
public let systemSpeechBundlePrefixes: [String] = [
    "com.apple.corespeech",
    "com.apple.assistant",
    "com.apple.siri",
    "com.apple.speechrecognitioncore",
    "com.apple.speech",
    "com.apple.dictation",
    "com.apple.accessibility",
    "com.apple.universalaccessd",
]

/// Mikrofonu kullanan süreçlerden görüşmeye ait olanlar. Sayılmayanlar: bu uygulamanın kendisi (kayıt ve sesle yazma);
/// paket kimliği `excludedBundlePrefixes`'tan biriyle başlayanlar (büyük/küçük harf duyarsız; bkz.
/// `systemSpeechBundlePrefixes`); paket kimliği boş olanlar. Paketsiz süreçler bu Mac'te yalnız sistem servisleriydi
/// (systemstats, PerfPowerServices); görüşme uygulamalarının (Zoom, Teams, tarayıcılar, FaceTime) hepsinin paket
/// kimliği vardır. Paketsizi saymamak güvenli yöndür: en kötü durumda kayıt kendiliğinden bitmez, yanlış geri sayım
/// başlamaz. Saf fonksiyondur.
public func callInputProcesses(processes: [AudioInputProcess], ownPID: Int32, excludedBundlePrefixes: [String]) -> [AudioInputProcess] {
    let prefixes: [String] = excludedBundlePrefixes.map { $0.lowercased() }
    return processes.filter { (process: AudioInputProcess) -> Bool in
        let bundle: String = process.bundleID.lowercased()
        return process.pid != ownPID && !bundle.isEmpty && !prefixes.contains { bundle.hasPrefix($0) }
    }
}

/// Görüşme sonu algılamasının süreleri (saniye).
public struct CallEndRules: Sendable, Equatable {
    /// Başka bir uygulama mikrofonu en az bu kadar kesintisiz kullanırsa görüşme sayılır (Siri ya da kısa bir dikte
    /// görüşme sanılıp yüz yüze kayıt kendiliğinden bitmesin).
    public let confirmSec: Double
    /// Görüşmeden sonra mikrofon bu kadar kesintisiz boş kalırsa geri sayım başlar.
    public let quietSec: Double
    /// Geri sayımın süresi: bitince kayıt biter.
    public let countdownSec: Double

    public init(confirmSec: Double, quietSec: Double, countdownSec: Double) {
        self.confirmSec = confirmSec
        self.quietSec = quietSec
        self.countdownSec = countdownSec
    }

    /// Uygulamanın kullandığı süreler: 10 sn görüşme, 15 sn sessizlik, 30 sn geri sayım.
    public static let standard: CallEndRules = CallEndRules(confirmSec: 10, quietSec: 15, countdownSec: 30)
}

/// Bir kaydın görüşme sonu durumu.
public struct CallEndState: Sendable, Equatable {
    /// Bu kayıtta (ya da "Kayda devam et"ten sonra) başka bir uygulama mikrofonu görüşme süresince kullandı.
    public let callSeen: Bool
    /// Başka uygulamanın mikrofonu kesintisiz kullandığı sürenin başı; kullanmıyorsa nil.
    public let callInputSince: Date?
    /// Görüşmeden sonra mikrofonun kesintisiz boş kaldığı sürenin başı; görüşme sürüyorsa ya da hiç görülmediyse nil.
    public let quietSince: Date?
    /// Geri sayım sürüyorsa kaydın biteceği an.
    public let stopDeadline: Date?

    public init(callSeen: Bool, callInputSince: Date?, quietSince: Date?, stopDeadline: Date?) {
        self.callSeen = callSeen
        self.callInputSince = callInputSince
        self.quietSince = quietSince
        self.stopDeadline = stopDeadline
    }

    /// Kayıt başındaki durum; "Kayda devam et"ten sonra da buna dönülür: görülen görüşme unutulur, kayıt ancak yeni bir
    /// görüşme görülüp o da biterse yeniden geri sayar (toplantı yüz yüze sürüyor olabilir).
    public static let initial: CallEndState = CallEndState(callSeen: false, callInputSince: nil, quietSince: nil, stopDeadline: nil)
}

/// Bir ölçümden sonra yapılacak iş.
public enum CallEndAction: Sendable, Equatable {
    case none
    /// Görüşme bitti gibi: geri sayım başladı (uyarı ve bildirim gösterilir).
    case countdownStarted(deadline: Date)
    /// Görüşme uygulaması mikrofonu yeniden kullanıyor: geri sayım iptal (uyarı kalkar).
    case countdownCancelled
    /// Geri sayım bitti: kayıt "Bitir"e basılmış gibi bitirilir.
    case stop
}

/// Bir ölçümün sonucu: yeni durum ve yapılacak iş.
public struct CallEndStep: Sendable, Equatable {
    public let state: CallEndState
    public let action: CallEndAction

    public init(state: CallEndState, action: CallEndAction) {
        self.state = state
        self.action = action
    }
}

/// Görüşme sonu durum makinesi: `now` anındaki ölçüm (başka bir uygulama mikrofonu kullanıyor mu) durumu ilerletir.
/// Görüşme `confirmSec` boyunca görülmeden hiçbir şey olmaz; görüldükten sonra `quietSec` sessizlikte geri sayım başlar,
/// görüşme geri gelirse iptal olur, `countdownSec` dolunca kayıt biter. Saf fonksiyondur.
public func callEndStep(state: CallEndState, callInputActive: Bool, now: Date, rules: CallEndRules) -> CallEndStep {
    if callInputActive {
        let since: Date = state.callInputSince ?? now
        let next: CallEndState = CallEndState(
            callSeen: state.callSeen || now.timeIntervalSince(since) >= rules.confirmSec, callInputSince: since, quietSince: nil, stopDeadline: nil
        )
        return CallEndStep(state: next, action: state.stopDeadline == nil ? .none : .countdownCancelled)
    }
    guard state.callSeen else {
        return CallEndStep(state: .initial, action: .none)
    }
    if let deadline = state.stopDeadline {
        guard now >= deadline else {
            return CallEndStep(state: state, action: .none)
        }
        return CallEndStep(state: .initial, action: .stop)
    }
    let quietSince: Date = state.quietSince ?? now
    guard now.timeIntervalSince(quietSince) >= rules.quietSec else {
        return CallEndStep(state: CallEndState(callSeen: true, callInputSince: nil, quietSince: quietSince, stopDeadline: nil), action: .none)
    }
    let deadline: Date = now.addingTimeInterval(rules.countdownSec)
    return CallEndStep(
        state: CallEndState(callSeen: true, callInputSince: nil, quietSince: quietSince, stopDeadline: deadline),
        action: .countdownStarted(deadline: deadline)
    )
}

