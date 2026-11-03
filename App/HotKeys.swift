import AINotepadCore
import AppKit
import Carbon.HIToolbox
import Observation
import os

private let hotKeyLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HotKeys")

/// Kısayol kaydı başarısız oldu (ör. başka bir uygulama aynı kısayolu kullanıyor).
enum HotKeyError: Error, Equatable {
    case handlerInstallFailed(status: Int32)
    case registrationFailed(keyCode: UInt32, status: Int32)
    case systemShortcutsUnreadable(status: Int32)
    /// Aynı kısayol etkin bir macOS sistem kısayolu (ör. giriş kaynağı değiştirme); sistem önce davranır.
    case conflictsWithSystemShortcut(keyCode: UInt32, modifiers: UInt32)
    /// Yalnızca ⇧ ya da değiştiricisiz harf: yazı yazarken tetiklenirdi.
    case unusableBinding(keyCode: UInt32, modifiers: UInt32)
    /// Aynı kısayol bu uygulamada başka bir eyleme atanmış.
    case duplicate(keyCode: UInt32, modifiers: UInt32)
}

/// Kısayolla tetiklenen eylemler.
enum ShortcutAction: String, CaseIterable {
    case record
    case toggleWindows
    /// Sesle yazma: basılı tutunca bas-konuş, kısa dokununca eller serbest (bkz. `DictationController`).
    case dictate

    var title: String {
        switch self {
        case .record: String(localized: "Kaydı başlat / durdur")
        case .toggleWindows: String(localized: "Ada ve paneli göster / gizle")
        case .dictate: String(localized: "Sesle yazma")
        }
    }

    var settingsKey: String {
        switch self {
        case .record: SettingsKey.recordShortcut
        case .toggleWindows: SettingsKey.windowsShortcut
        case .dictate: SettingsKey.dictateShortcut
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .record: defaultRecordBinding
        case .toggleWindows: defaultWindowsBinding
        case .dictate: defaultDictateBinding
        }
    }

    /// Kullanıcının seçmediği varsayılan kısayol çakışırsa eylem kısayolsuz kalır mı (menü uyarmaz): sesle yazma
    /// varsayılan açık; kullanıcı kurmadığı bir özellik için kırmızı uyarı görmesin, kısayolu Ayarlar › Sesle yazma'da seçer.
    var leavesConflictingDefaultUnset: Bool {
        switch self {
        case .record, .toggleWindows: false
        case .dictate: true
        }
    }
}

/// Eylemin kısayolu şu an kayıtlı olmalı mı: kayıt ve pencere kısayolları giriş kapısı açıkken; sesle yazma ayarı
/// açıksa her zaman (oturum yokken basılınca "giriş yap" gösterir). Saf fonksiyondur.
func isShortcutActive(action: ShortcutAction, signInRequired: Bool, voiceTypingEnabled: Bool) -> Bool {
    switch action {
    case .record, .toggleWindows: !signInRequired
    case .dictate: voiceTypingEnabled
    }
}

/// Kısayolun olay işleyicileri. Zaman: olayın anı (sistem açılışından beri saniye).
struct HotKeyHandlers {
    let onPress: @MainActor (Double) -> Void
    let onRelease: @MainActor (Double) -> Void
    /// Kısayol bırakıldı (kayıt kaldırıldı): basılıyken bırakma olayı artık gelmez, süren iş kapanmalı.
    let onUnbind: @MainActor () -> Void

    /// Yalnızca basılınca çalışan kısayol.
    static func pressOnly(perform: @escaping @MainActor () -> Void) -> HotKeyHandlers {
        HotKeyHandlers(
            onPress: { (_: Double) -> Void in perform() },
            onRelease: { (_: Double) -> Void in },
            onUnbind: {}
        )
    }
}

/// Uygulama öndeyken de değilken çalışan global kısayollar (Carbon; erişilebilirlik izni gerektirmez).
/// Her eylemin tek kısayolu vardır; yeniden atanınca eskisi bırakılır.
@MainActor
final class HotKeyCenter {
    /// 'AINP' imzası: kısayol olaylarını bu uygulamanınkilerle eşler.
    fileprivate nonisolated static let signature: OSType = 0x41494E50

    private struct Registration {
        let id: UInt32
        let binding: KeyBinding
        let reference: EventHotKeyRef
        let handlers: HotKeyHandlers
    }

    private var registrations: [ShortcutAction: Registration] = [:]
    /// Eller serbest dikte sürerken geçici Esc kaydı (değiştiricisiz; başka zaman Esc uygulamalara gider).
    private var escape: Registration?
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {}

    /// Eylemin kısayolunu kaydeder (varsa eskisini bırakır); tuşa basılınca ve bırakılınca işleyiciler ana aktörde
    /// çalışır. Kullanılamayan, sistem kısayoluyla çakışan ya da başka uygulamanın özel kaydettiği kısayolda hata
    /// fırlatır ve eski kısayol çalışmaya devam eder.
    func bind(action: ShortcutAction, binding: KeyBinding, handlers: HotKeyHandlers) throws {
        guard isUsableGlobalBinding(binding: binding) else {
            throw HotKeyError.unusableBinding(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
        if registrations.contains(where: { $0.key != action && $0.value.binding == binding }) {
            throw HotKeyError.duplicate(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
        if isTakenBySystem(keyCode: binding.keyCode, modifiers: binding.modifiers, systemShortcuts: try systemShortcuts()) {
            throw HotKeyError.conflictsWithSystemShortcut(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
        let previous: Registration? = registrations[action]
        // Zaten bu kısayolla kayıtlı: yalnızca eylem güncellenir (bırakıp yeniden kaydetmek kaybetme riski taşır).
        if let previous, previous.binding == binding {
            registrations[action] = Registration(id: previous.id, binding: binding, reference: previous.reference, handlers: handlers)
            return
        }
        let registration: Registration = try register(binding: binding, handlers: handlers)
        if let previous {
            unregister(registration: previous)
            previous.handlers.onUnbind()
        }
        registrations[action] = registration
        hotKeyLogger.info("Kısayol kaydedildi, eylem: \(action.rawValue, privacy: .public), tuş: \(binding.keyCode, privacy: .public), değiştirici: \(binding.modifiers, privacy: .public)")
    }

    /// Kısayolu Carbon'a kaydeder (özel kayıt: başka bir uygulama aynı kısayolu kullanıyorsa başarısız olur).
    private func register(binding: KeyBinding, handlers: HotKeyHandlers) throws -> Registration {
        try installHandlerIfNeeded()
        let id: UInt32 = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status: OSStatus = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            // Başka bir uygulama aynı kısayolu kullanıyorsa kayıt başarısız olsun (sessizce paylaşılmasın).
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyError.registrationFailed(keyCode: binding.keyCode, status: status)
        }
        return Registration(id: id, binding: binding, reference: reference, handlers: handlers)
    }

    /// Eylemin çalışan kısayolu.
    func binding(action: ShortcutAction) -> KeyBinding? {
        registrations[action]?.binding
    }

    /// Eylemin kısayolunu bırakır (kayıtlı değilse bir şey yapmaz); süren işi `onUnbind` kapatır.
    func unbind(action: ShortcutAction) {
        guard let registration = registrations[action] else {
            return
        }
        unregister(registration: registration)
        registration.handlers.onUnbind()
    }

    /// Esc'yi geçici olarak dinler (eller serbest dikte); zaten dinleniyorsa işleyici güncellenir. Başka bir uygulama Esc'yi
    /// özel kaydettiyse `registrationFailed`.
    func bindEscape(perform: @escaping @MainActor () -> Void) throws {
        let handlers: HotKeyHandlers = .pressOnly(perform: perform)
        if let escape {
            self.escape = Registration(id: escape.id, binding: escape.binding, reference: escape.reference, handlers: handlers)
            return
        }
        escape = try register(binding: KeyBinding(keyCode: UInt32(kVK_Escape), modifiers: 0), handlers: handlers)
    }

    /// Geçici Esc kaydını bırakır (Esc yeniden uygulamalara gider).
    func unbindEscape() {
        guard let escape else {
            return
        }
        let status: OSStatus = UnregisterEventHotKey(escape.reference)
        if status != noErr {
            hotKeyLogger.error("Esc kaydı bırakılamadı, durum: \(status, privacy: .public)")
        }
        self.escape = nil
    }

    /// Tüm kısayolları ve olay işleyicisini bırakır (uygulama kapanırken).
    func unregisterAll() {
        unbindEscape()
        for registration in registrations.values {
            unregister(registration: registration)
            registration.handlers.onUnbind()
        }
        registrations = [:]
        if let handler {
            let status: OSStatus = RemoveEventHandler(handler)
            if status != noErr {
                hotKeyLogger.error("Kısayol işleyicisi kaldırılamadı, durum: \(status, privacy: .public)")
            }
        }
        handler = nil
    }

    private func unregister(registration: Registration) {
        let status: OSStatus = UnregisterEventHotKey(registration.reference)
        if status != noErr {
            hotKeyLogger.error("Kısayol bırakılamadı, kimlik: \(registration.id, privacy: .public), durum: \(status, privacy: .public)")
        }
        registrations = registrations.filter { $0.value.id != registration.id }
    }

    /// Etkin/pasif tüm macOS sistem kısayolları.
    private func systemShortcuts() throws -> [SystemShortcut] {
        var list: Unmanaged<CFArray>?
        let status: OSStatus = CopySymbolicHotKeys(&list)
        guard status == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else {
            throw HotKeyError.systemShortcutsUnreadable(status: status)
        }
        return entries.compactMap { (entry: [String: Any]) -> SystemShortcut? in
            guard let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  let enabled = entry[kHISymbolicHotKeyEnabled as String] as? Bool
            else {
                return nil
            }
            return SystemShortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers), isEnabled: enabled)
        }
    }

    /// Kısayol olayı: `isPress` basma (değilse bırakma), `time` olayın anı (sistem açılışından beri saniye).
    fileprivate func fire(id: UInt32, isPress: Bool, time: Double) {
        guard let registration = registrations.values.first(where: { $0.id == id }) ?? escape.flatMap({ $0.id == id ? $0 : nil }) else {
            hotKeyLogger.error("Bilinmeyen kısayol kimliği: \(id, privacy: .public)")
            return
        }
        hotKeyLogger.info("Kısayol tetiklendi, kimlik: \(id, privacy: .public), basma: \(isPress, privacy: .public)")
        if isPress {
            registration.handlers.onPress(time)
        } else {
            registration.handlers.onRelease(time)
        }
    }

    private func installHandlerIfNeeded() throws {
        guard handler == nil else {
            return
        }
        // Basma ve bırakma: sesle yazmanın bas-konuşu bırakmayı bekler.
        var eventTypes: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status: OSStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else {
            throw HotKeyError.handlerInstallFailed(status: status)
        }
    }
}

/// Carbon kısayol geri çağrısı; ana iş parçacığında çağrılır. Başka imzalı olaylar bu uygulamanın değildir.
private let hotKeyCallback: EventHandlerUPP = { (_: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }
    var hotKeyID: EventHotKeyID = EventHotKeyID()
    let status: OSStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else {
        return status
    }
    guard hotKeyID.signature == HotKeyCenter.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let center: HotKeyCenter = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let isPress: Bool = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let time: Double = GetEventTime(event)
    MainActor.assumeIsolated {
        center.fire(id: hotKeyID.id, isPress: isPress, time: time)
    }
    return noErr
}

/// Kısayol başka bir kısayolla çakıştığı için mi kurulamadı (bu uygulamada, başka bir uygulamada ya da sistemde).
/// Saf fonksiyondur.
func isConflict(error: HotKeyError) -> Bool {
    switch error {
    case .duplicate, .registrationFailed, .conflictsWithSystemShortcut: true
    case .handlerInstallFailed, .systemShortcutsUnreadable, .unusableBinding: false
    }
}

/// Kısayolun kullanıcıya gösterilecek hata metni.
func shortcutErrorMessage(error: any Error, binding: KeyBinding) -> String {
    let name: String = keyBindingDisplay(binding: binding)
    switch error {
    case HotKeyError.conflictsWithSystemShortcut:
        return String(localized: "\(name) bir macOS sistem kısayolu; başka bir kısayol seç.")
    case HotKeyError.unusableBinding:
        return String(localized: "\(name) kullanılamaz: ⌃, ⌥ ya da ⌘ ile birlikte bir harf/rakam seç.")
    case HotKeyError.duplicate:
        return String(localized: "\(name) başka bir eyleme atanmış.")
    case HotKeyError.registrationFailed:
        return String(localized: "\(name) başka bir uygulamada kullanılıyor.")
    default:
        return String(localized: "\(name) kaydedilemedi.")
    }
}

/// Kısayolları ayarlardan kurar ve Ayarlar'dan değiştirir; hataları menüde gösterilmek üzere modele yazar.
@MainActor
@Observable
final class ShortcutController {
    private let hotKeys: HotKeyCenter
    private let model: AppModel
    private let actions: [ShortcutAction: HotKeyHandlers]
    /// Eylemin kısayolu şu an kayıtlı olmalı mı (giriş kapısı, sesle yazma ayarı; bkz. `isShortcutActive`).
    private let isActive: @MainActor (ShortcutAction) -> Bool
    /// Eylem başına son değiştirme hatası (Ayarlar'da gösterilir; eski kısayol çalışmaya devam ediyor olabilir).
    var errors: [ShortcutAction: String] = [:]
    /// Varsayılan kısayolu çakıştığı için atanmayan eylemler ve nedeni (`leavesConflictingDefaultUnset`); menü uyarmaz,
    /// yalnızca eylemin Ayarlar satırı gösterir.
    private(set) var unsetDefaults: [ShortcutAction: String] = [:]

    init(hotKeys: HotKeyCenter, model: AppModel, actions: [ShortcutAction: HotKeyHandlers], isActive: @escaping @MainActor (ShortcutAction) -> Bool) {
        self.hotKeys = hotKeys
        self.model = model
        self.actions = actions
        self.isActive = isActive
    }

    /// Uygulama kapanırken tüm kısayolları ve Carbon işleyicisini bırakır.
    func unregisterAll() {
        hotKeys.unregisterAll()
    }

    /// Etkin olması gereken eylemlerin kayıtlı (ya da varsayılan) kısayollarını kurar, diğerlerini bırakır. Açılışta,
    /// giriş kapısı ve sesle yazma ayarı değişince çağrılır.
    func sync() {
        for action in ShortcutAction.allCases {
            if !isActive(action) {
                hotKeys.unbind(action: action)
                errors[action] = nil
                unsetDefaults[action] = nil
            } else if action.leavesConflictingDefaultUnset, !hasStoredKeyBinding(key: action.settingsKey) {
                applyUnchosenDefault(action: action)
            } else {
                apply(action: action, binding: storedKeyBinding(key: action.settingsKey, fallback: action.defaultBinding))
            }
        }
        publish()
    }

    /// Ayarlarda gösterilen kısayol: varsayılanı çakıştığı için atanmadıysa nil, değilse `currentBinding`.
    func assignedBinding(action: ShortcutAction) -> KeyBinding? {
        unsetDefaults[action] == nil ? currentBinding(action: action) : nil
    }

    /// Çalışan kısayol; kurulamadıysa ya da eylem kapalıysa kayıtlı olan.
    func currentBinding(action: ShortcutAction) -> KeyBinding {
        hotKeys.binding(action: action) ?? storedKeyBinding(key: action.settingsKey, fallback: action.defaultBinding)
    }

    /// Yeni kısayolu dener; başarılıysa kaydeder. Başarısızsa eski kısayol çalışmaya devam eder. Eylem kapalıysa (sesle
    /// yazma kapalı) yalnızca diğer eylemlerle çakışma denetlenip saklanır; sistemle çakışma açılınca görünür.
    func change(action: ShortcutAction, binding: KeyBinding) {
        guard isActive(action) else {
            storeInactive(action: action, binding: binding)
            return
        }
        guard binding != hotKeys.binding(action: action) else {
            errors[action] = nil
            return
        }
        // Kapalı eylemin (ör. kapatılmış sesle yazma) saklı kısayolu da dolu sayılır: açılınca çakışmasın.
        let inactive: [KeyBinding] = ShortcutAction.allCases.filter { $0 != action && !isActive($0) }.map { currentBinding(action: $0) }
        guard !inactive.contains(binding) else {
            errors[action] = shortcutErrorMessage(error: HotKeyError.duplicate(keyCode: binding.keyCode, modifiers: binding.modifiers), binding: binding)
            return
        }
        apply(action: action, binding: binding)
        guard errors[action] == nil else {
            return
        }
        store(action: action, binding: binding)
        publish()
    }

    private func storeInactive(action: ShortcutAction, binding: KeyBinding) {
        guard isUsableGlobalBinding(binding: binding) else {
            errors[action] = shortcutErrorMessage(error: HotKeyError.unusableBinding(keyCode: binding.keyCode, modifiers: binding.modifiers), binding: binding)
            return
        }
        let others: [KeyBinding] = ShortcutAction.allCases.filter { $0 != action }.map { currentBinding(action: $0) }
        guard !others.contains(binding) else {
            errors[action] = shortcutErrorMessage(error: HotKeyError.duplicate(keyCode: binding.keyCode, modifiers: binding.modifiers), binding: binding)
            return
        }
        errors[action] = nil
        store(action: action, binding: binding)
    }

    private func store(action: ShortcutAction, binding: KeyBinding) {
        do {
            try storeKeyBinding(key: action.settingsKey, binding: binding)
        } catch {
            errors[action] = String(localized: "Kısayol kaydedilemedi: \(error.localizedDescription)")
        }
    }

    private func apply(action: ShortcutAction, binding: KeyBinding) {
        guard let handlers = actions[action] else {
            return
        }
        do {
            try hotKeys.bind(action: action, binding: binding, handlers: handlers)
            errors[action] = nil
            unsetDefaults[action] = nil
        } catch {
            hotKeyLogger.error("Kısayol kurulamadı, eylem: \(action.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errors[action] = shortcutErrorMessage(error: error, binding: binding)
        }
        publish()
    }

    /// Kullanıcının seçmediği varsayılan kısayolu kurar. Bu uygulamanın başka bir kısayoluyla, başka bir uygulamayla ya
    /// da bir sistem kısayoluyla çakışırsa eylem kısayolsuz kalır: hata yazılmaz (menü uyarmaz), neden yalnızca
    /// Ayarlar'da görünür (`unsetDefaults`).
    private func applyUnchosenDefault(action: ShortcutAction) {
        guard let handlers = actions[action] else {
            return
        }
        let binding: KeyBinding = action.defaultBinding
        do {
            try hotKeys.bind(action: action, binding: binding, handlers: handlers)
            errors[action] = nil
            unsetDefaults[action] = nil
        } catch let error as HotKeyError where isConflict(error: error) {
            hotKeyLogger.warning("Varsayılan kısayol çakışıyor, eylem kısayolsuz bırakıldı, eylem: \(action.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            errors[action] = nil
            unsetDefaults[action] = shortcutErrorMessage(error: error, binding: binding)
        } catch {
            hotKeyLogger.error("Kısayol kurulamadı, eylem: \(action.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errors[action] = shortcutErrorMessage(error: error, binding: binding)
        }
    }

    /// Menüdeki kırmızı satır: yalnızca etkin olup gerçekten çalışan kısayolu olmayan eylemler (değiştirme hatasında eski
    /// kısayol çalışıyorsa menü uyarmaz; hata Ayarlar'da görünür).
    private func publish() {
        let messages: [String] = ShortcutAction.allCases
            .filter { isActive($0) && hotKeys.binding(action: $0) == nil }
            .compactMap { errors[$0] }
        model.shortcutError = messages.isEmpty ? nil : String(localized: "Kısayol çalışmıyor: \(messages.joined(separator: " "))")
    }
}
