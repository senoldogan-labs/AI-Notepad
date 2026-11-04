import Foundation

/// Kısayol kaydedicisinin olayları. `Action` uygulamanın kısayol eylemidir (ör. kayıt, sesle yazma).
public enum ShortcutRecordingEvent<Action: Hashable & Sendable>: Equatable, Sendable {
    /// Eylemin kaydedici düğmesine tıklandı (zaten kaydediyorsa durdurur).
    case tapped(Action)
    /// Eylemin kaydedicisi ekrandan kalktı (Ayarlar sayfası değişti, pencere kapandı).
    case disappeared(Action)
    /// Pencere odağı kaybetti ya da uygulama arka plana geçti.
    case focusLost
    /// Kayıt sürerken bir tuş bileşimine basıldı.
    case keyPressed(KeyBinding)
}

/// Geçişin yan etkileri; sırayla uygulanır.
public enum ShortcutRecordingEffect<Action: Hashable & Sendable>: Equatable, Sendable {
    /// Uygulamanın global kısayollarını askıya al: basılan bileşim kısayolu tetiklemesin, kaydediciye ulaşsın.
    case suspendHotKeys
    /// Askıdaki global kısayolları yeniden kur.
    case resumeHotKeys
    /// Basılan bileşimi eyleme atamayı dene (kısayollar yeniden kurulduktan sonra; çakışma denetimi gerçek kayıtlarla).
    case assign(Action, KeyBinding)
}

/// Kısayol kaydedicisinin durumu: aynı anda en çok bir eylem kaydedilir; kaydedilirken global kısayollar askıdadır.
public struct ShortcutRecordingState<Action: Hashable & Sendable>: Equatable, Sendable {
    /// Kaydedilen eylem; nil ise kaydedici kapalı ve kısayollar çalışıyor.
    public let recording: Action?

    public init(recording: Action?) {
        self.recording = recording
    }
}

/// Geçişin sonucu: yeni durum ve uygulanacak yan etkiler.
public struct ShortcutRecordingTransition<Action: Hashable & Sendable>: Equatable, Sendable {
    public let state: ShortcutRecordingState<Action>
    public let effects: [ShortcutRecordingEffect<Action>]

    public init(state: ShortcutRecordingState<Action>, effects: [ShortcutRecordingEffect<Action>]) {
        self.state = state
        self.effects = effects
    }
}

/// Esc'nin sanal tuş kodu (`kVK_Escape`): kaydı iptal eder, hiçbir zaman kısayol olarak atanmaz.
public let escapeKeyCode: UInt32 = 0x35

/// Kaydedicinin durum makinesi. Askıya alma yalnızca kapalıdan kayda geçişte, yeniden kurma yalnızca kayıttan kapalıya
/// geçişte üretilir: her askıya almanın tam bir yeniden kurması vardır, kısayollar askıda kalamaz. Esc (değiştiricili de)
/// kaydı iptal eder; başka bir tuş önce kısayolları yeniden kurar, sonra atanır. Saf fonksiyondur.
public func shortcutRecordingTransition<Action: Hashable & Sendable>(
    state: ShortcutRecordingState<Action>,
    event: ShortcutRecordingEvent<Action>
) -> ShortcutRecordingTransition<Action> {
    let idle: ShortcutRecordingState<Action> = ShortcutRecordingState(recording: nil)
    let unchanged: ShortcutRecordingTransition<Action> = ShortcutRecordingTransition(state: state, effects: [])
    switch event {
    case .tapped(let action):
        guard let recording = state.recording else {
            return ShortcutRecordingTransition(state: ShortcutRecordingState(recording: action), effects: [.suspendHotKeys])
        }
        // Aynı düğmeye yeniden tıklamak kaydı durdurur; başka bir eylemin düğmesi kaydı ona geçirir (kısayollar askıda kalır).
        guard recording != action else {
            return ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys])
        }
        return ShortcutRecordingTransition(state: ShortcutRecordingState(recording: action), effects: [])
    case .disappeared(let action):
        guard state.recording == action else {
            return unchanged
        }
        return ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys])
    case .focusLost:
        guard state.recording != nil else {
            return unchanged
        }
        return ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys])
    case .keyPressed(let binding):
        guard let recording = state.recording else {
            return unchanged
        }
        guard binding.keyCode != escapeKeyCode else {
            return ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys])
        }
        return ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys, .assign(recording, binding)])
    }
}

/// Eyleme atanmış kısayol (çakışma denetimi için).
public struct AssignedShortcut<Action: Hashable & Sendable>: Equatable, Sendable {
    public let action: Action
    public let binding: KeyBinding

    public init(action: Action, binding: KeyBinding) {
        self.action = action
        self.binding = binding
    }
}

/// Basılan bileşim eyleme atanabilir mi.
public enum ShortcutChoice<Action: Hashable & Sendable>: Equatable, Sendable {
    /// Eylemin zaten çalışan kısayolu: hiçbir şey değişmez.
    case unchanged
    /// Uygulamanın başka bir eylemine atanmış: çalınmaz, çakışma gösterilir.
    case taken(by: Action)
    /// Uygulama içinde boş (sistemle ve başka uygulamalarla çakışma kayıtta denetlenir).
    case available
}

/// Basılan bileşimi eylemin çalışan kısayoluyla (`current`, yoksa nil) ve diğer eylemlerin atanmış kısayollarıyla
/// karşılaştırır. `others` içinde eylemin kendisi varsa yok sayılır. Saf fonksiyondur.
public func shortcutChoice<Action: Hashable & Sendable>(
    action: Action,
    pressed: KeyBinding,
    current: KeyBinding?,
    others: [AssignedShortcut<Action>]
) -> ShortcutChoice<Action> {
    if pressed == current {
        return .unchanged
    }
    if let owner = others.first(where: { $0.action != action && $0.binding == pressed }) {
        return .taken(by: owner.action)
    }
    return .available
}
