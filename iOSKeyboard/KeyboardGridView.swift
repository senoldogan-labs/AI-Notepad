import KeyboardCore
import UIKit

/// Izgaranın denetleyiciye bildirdiği tuş işleri.
@MainActor
protocol KeyboardGridDelegate: AnyObject {
    func gridInsert(character: String)
    func gridDeleteBackward(wholeWord: Bool)
    func gridShift()
    func gridSpace()
    func gridReturn()
    func gridPage(_ page: KeyboardPage)
    func gridEmoji()
    func gridMicrophone()
    func gridLanguage()
    func gridMoveCursor(offset: Int)
    func gridKeyDown()
    /// Küre tuşu: sistemin klavye listesini açan hedefin bağlanacağı düğme.
    func gridAttachGlobe(button: UIButton)
}

/// Büyük harf durumu.
enum KeyboardShiftState: Equatable {
    case off
    case once
    case locked
}

/// Izgaranın çizim girdisi.
struct KeyboardGridModel: Equatable {
    let rows: [[KeyboardKey]]
    let language: KeyboardLanguage
    let page: KeyboardPage
    let shift: KeyboardShiftState
    let returnTitle: String?
    let returnIsProminent: Bool
    let isDark: Bool
    let isLandscape: Bool
    let isMicrophoneActive: Bool
}

/// Tuş ızgarası: dokunuşları UIKit'te kendisi işler (SwiftUI hareketleri hızlı yazımda dokunuş kaçırır). Harf tuşu
/// basılınca büyütülmüş önizleme gösterir ve bırakınca yazar; yeni bir parmak inerken basılı harf hemen yazılır
/// (çoklu dokunuş sırası). Uzun basış aksanlı harfleri, silme basılı tutulunca hızlanarak (sonra kelime kelime)
/// silmeyi, boşlukta yatay kaydırma imleci taşımayı açar.
@MainActor
final class KeyboardGridView: UIView {
    weak var delegate: KeyboardGridDelegate?
    private(set) var model: KeyboardGridModel?
    private var frames: [KeyboardKeyFrame] = []
    private var capViews: [UIView] = []
    private var globeButton: UIButton?
    private var touches: [ObjectIdentifier: ActiveTouch] = [:]
    private let popup: KeyPopupView = KeyPopupView()
    private var deleteTimer: Timer?
    private var deleteRepeats: Int = 0
    private var longPressTimer: Timer?

    private struct ActiveTouch {
        var keyFrame: KeyboardKeyFrame
        let start: CGPoint
        var committed: Bool
        var alternates: [String]
        var selectedAlternate: Int?
        var cursorAnchorX: CGFloat?
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        popup.isHidden = true
        addSubview(popup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(model: KeyboardGridModel) {
        guard model != self.model else {
            return
        }
        self.model = model
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let model else {
            return
        }
        let landscape: Bool = model.isLandscape
        let metrics: KeyboardMetrics = KeyboardMetrics(
            width: bounds.width, height: bounds.height, horizontalGap: 6, verticalGap: landscape ? 7 : 11, sideInset: 3, topInset: 2,
            bottomInset: 2, maximumKeysWidth: landscape ? 720 : 640
        )
        frames = keyboardKeyFrames(rows: model.rows, metrics: metrics)
        capViews.forEach { $0.removeFromSuperview() }
        globeButton?.removeFromSuperview()
        globeButton = nil
        capViews = frames.map { (keyFrame: KeyboardKeyFrame) -> UIView in
            let cap: UIView = makeCap(keyFrame: keyFrame, model: model)
            insertSubview(cap, belowSubview: popup)
            return cap
        }
        if let globe = frames.first(where: { $0.key.kind == .globe }) {
            let button: UIButton = UIButton(type: .custom)
            button.frame = globe.hitFrame
            button.accessibilityLabel = String(localized: "Sonraki klavye")
            addSubview(button)
            delegate?.gridAttachGlobe(button: button)
            globeButton = button
        }
    }

    // MARK: Çizim

    private func makeCap(keyFrame: KeyboardKeyFrame, model: KeyboardGridModel) -> UIView {
        let cap: UIView = UIView(frame: keyFrame.frame)
        cap.layer.cornerRadius = 8
        cap.layer.cornerCurve = .continuous
        cap.layer.shadowColor = UIColor.black.cgColor
        cap.layer.shadowOpacity = model.isDark ? 0 : 0.3
        cap.layer.shadowOffset = CGSize(width: 0, height: 1)
        cap.layer.shadowRadius = 0
        cap.backgroundColor = capColor(kind: keyFrame.key.kind, model: model, pressed: false)
        cap.isUserInteractionEnabled = false
        cap.isAccessibilityElement = true
        cap.accessibilityTraits = .keyboardKey
        let label: UILabel = UILabel(frame: cap.bounds)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.textAlignment = .center
        label.textColor = model.isDark ? .white : .black
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        switch keyFrame.key.kind {
        case .character(let character):
            let shown: String = model.page == .letters && model.shift != .off ? keyboardUppercased(character, language: model.language) : character
            label.text = shown
            label.font = .systemFont(ofSize: model.page == .letters && character.first?.isLetter == true ? 25 : 22, weight: .regular)
            cap.accessibilityLabel = shown
            cap.addSubview(label)
        case .space:
            label.text = model.rows.count > 0 && model.page == .letters ? model.language.endonym : String(localized: "boşluk")
            label.font = .systemFont(ofSize: 16)
            cap.accessibilityLabel = String(localized: "boşluk")
            cap.addSubview(label)
        case .returnKey:
            if let title = model.returnTitle {
                label.text = title
                label.font = .systemFont(ofSize: 16, weight: .medium)
                if model.returnIsProminent {
                    label.textColor = .white
                }
                cap.addSubview(label)
                cap.accessibilityLabel = title
            } else {
                addSymbol(name: "return", to: cap, model: model)
                cap.accessibilityLabel = String(localized: "satır başı")
            }
        case .page(let page):
            label.text = switch page {
            case .letters: "ABC"
            case .numbers: "123"
            case .symbols: "#+="
            }
            label.font = .systemFont(ofSize: 16)
            cap.addSubview(label)
            cap.accessibilityLabel = label.text
        case .shift:
            let symbol: String = switch model.shift {
            case .off: "shift"
            case .once: "shift.fill"
            case .locked: "capslock.fill"
            }
            addSymbol(name: symbol, to: cap, model: model)
            cap.accessibilityLabel = String(localized: "büyük harf")
            if model.shift != .off {
                cap.accessibilityTraits.insert(.selected)
            }
        case .delete:
            addSymbol(name: "delete.left", to: cap, model: model)
            cap.accessibilityLabel = String(localized: "sil")
        case .globe:
            addSymbol(name: "globe", to: cap, model: model)
            cap.accessibilityLabel = String(localized: "Sonraki klavye")
        case .emoji:
            addSymbol(name: "face.smiling", to: cap, model: model)
            cap.accessibilityLabel = String(localized: "Emoji")
        case .microphone:
            addSymbol(name: model.isMicrophoneActive ? "mic.fill" : "mic", to: cap, model: model)
            cap.accessibilityLabel = String(localized: "Sesle yaz")
        case .language:
            label.text = model.language.rawValue.uppercased()
            label.font = .systemFont(ofSize: 15, weight: .medium)
            cap.addSubview(label)
            cap.accessibilityLabel = String(localized: "Klavye dili: \(model.language.endonym)")
        }
        return cap
    }

    private func addSymbol(name: String, to cap: UIView, model: KeyboardGridModel) {
        let view: UIImageView = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)))
        view.tintColor = model.returnIsProminent && name == "return" ? .white : (model.isDark ? .white : .black)
        view.contentMode = .center
        view.frame = cap.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cap.addSubview(view)
    }

    private func capColor(kind: KeyboardKeyKind, model: KeyboardGridModel, pressed: Bool) -> UIColor {
        let isCharacter: Bool
        switch kind {
        case .character, .space:
            isCharacter = true
        case .returnKey:
            if model.returnIsProminent {
                return pressed ? UIColor.systemBlue.withAlphaComponent(0.7) : .systemBlue
            }
            isCharacter = false
        case .shift:
            isCharacter = model.shift != .off
        default:
            isCharacter = false
        }
        let normal: UIColor =
            isCharacter
            ? (model.isDark ? UIColor(white: 0.42, alpha: 1) : .white)
            : (model.isDark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1))
        let highlighted: UIColor =
            isCharacter
            ? (model.isDark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1))
            : (model.isDark ? UIColor(white: 0.42, alpha: 1) : .white)
        return pressed ? highlighted : normal
    }

    private func setPressed(_ keyFrame: KeyboardKeyFrame, pressed: Bool) {
        guard let model, let index = frames.firstIndex(of: keyFrame), index < capViews.count else {
            return
        }
        capViews[index].backgroundColor = capColor(kind: keyFrame.key.kind, model: model, pressed: pressed)
    }

    // MARK: Dokunuşlar

    override func touchesBegan(_ newTouches: Set<UITouch>, with event: UIEvent?) {
        for touch in newTouches {
            // Çoklu dokunuş sırası: önceki parmak hâlâ bastığı harfi bırakmadıysa harfi şimdi yazılır.
            commitPendingCharacters()
            let point: CGPoint = touch.location(in: self)
            guard let keyFrame = keyboardKeyFrame(at: point, frames: frames) else {
                continue
            }
            touches[ObjectIdentifier(touch)] = ActiveTouch(
                keyFrame: keyFrame, start: point, committed: false, alternates: [], selectedAlternate: nil, cursorAnchorX: nil
            )
            keyDown(keyFrame: keyFrame, touch: touch)
        }
    }

    override func touchesMoved(_ movedTouches: Set<UITouch>, with event: UIEvent?) {
        for touch in movedTouches {
            let id: ObjectIdentifier = ObjectIdentifier(touch)
            guard var active = touches[id] else {
                continue
            }
            let point: CGPoint = touch.location(in: self)
            switch active.keyFrame.key.kind {
            case .space:
                if active.cursorAnchorX == nil, abs(point.x - active.start.x) > 12 {
                    active.cursorAnchorX = point.x
                }
                if let anchor = active.cursorAnchorX {
                    let steps: Int = Int((point.x - anchor) / 9)
                    if steps != 0 {
                        delegate?.gridMoveCursor(offset: steps)
                        active.cursorAnchorX = anchor + CGFloat(steps) * 9
                    }
                }
            case .character:
                if !active.alternates.isEmpty {
                    active.selectedAlternate = popup.alternateIndex(at: convert(point, to: popup))
                    popup.select(index: active.selectedAlternate)
                } else if !active.committed, let other = keyboardKeyFrame(at: point, frames: frames), other != active.keyFrame,
                          case .character = other.key.kind {
                    // Parmak başka harfe kaydı: önizleme ve yazılacak harf onunla değişir.
                    setPressed(active.keyFrame, pressed: false)
                    active.keyFrame = other
                    setPressed(other, pressed: true)
                    showPopup(for: other)
                    restartLongPress(touch: touch)
                }
            default:
                break
            }
            touches[id] = active
        }
    }

    override func touchesEnded(_ endedTouches: Set<UITouch>, with event: UIEvent?) {
        for touch in endedTouches {
            guard let active = touches.removeValue(forKey: ObjectIdentifier(touch)) else {
                continue
            }
            keyUp(active: active)
        }
    }

    override func touchesCancelled(_ cancelledTouches: Set<UITouch>, with event: UIEvent?) {
        for touch in cancelledTouches {
            guard let active = touches.removeValue(forKey: ObjectIdentifier(touch)) else {
                continue
            }
            finishVisuals(active: active)
        }
    }

    private func keyDown(keyFrame: KeyboardKeyFrame, touch: UITouch) {
        delegate?.gridKeyDown()
        setPressed(keyFrame, pressed: true)
        switch keyFrame.key.kind {
        case .character:
            showPopup(for: keyFrame)
            restartLongPress(touch: touch)
        case .delete:
            delegate?.gridDeleteBackward(wholeWord: false)
            deleteRepeats = 0
            deleteTimer?.invalidate()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] (_: Timer) in
                MainActor.assumeIsolated {
                    self?.startDeleteRepeat()
                }
            }
        case .shift:
            delegate?.gridShift()
        default:
            break
        }
    }

    private func keyUp(active: ActiveTouch) {
        finishVisuals(active: active)
        switch active.keyFrame.key.kind {
        case .character(let character):
            guard !active.committed else {
                return
            }
            if !active.alternates.isEmpty {
                if let index = active.selectedAlternate, index < active.alternates.count {
                    delegate?.gridInsert(character: active.alternates[index])
                }
            } else {
                delegate?.gridInsert(character: character)
            }
        case .space:
            if active.cursorAnchorX == nil {
                delegate?.gridSpace()
            }
        case .returnKey:
            delegate?.gridReturn()
        case .page(let page):
            delegate?.gridPage(page)
        case .emoji:
            delegate?.gridEmoji()
        case .microphone:
            delegate?.gridMicrophone()
        case .language:
            delegate?.gridLanguage()
        case .delete, .shift, .globe:
            break
        }
    }

    private func finishVisuals(active: ActiveTouch) {
        setPressed(active.keyFrame, pressed: false)
        switch active.keyFrame.key.kind {
        case .delete:
            deleteTimer?.invalidate()
            deleteTimer = nil
        case .character:
            longPressTimer?.invalidate()
            longPressTimer = nil
            if !touches.values.contains(where: { if case .character = $0.keyFrame.key.kind { true } else { false } }) {
                popup.isHidden = true
            }
        default:
            break
        }
    }

    /// Basılı harfleri hemen yazar (yeni parmak indi); bırakılınca ikinci kez yazılmaz.
    private func commitPendingCharacters() {
        for (id, active) in touches {
            guard case .character(let character) = active.keyFrame.key.kind, !active.committed, active.alternates.isEmpty else {
                continue
            }
            delegate?.gridInsert(character: character)
            var committed: ActiveTouch = active
            committed.committed = true
            touches[id] = committed
            setPressed(active.keyFrame, pressed: false)
        }
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func restartLongPress(touch: UITouch) {
        longPressTimer?.invalidate()
        let id: ObjectIdentifier = ObjectIdentifier(touch)
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] (_: Timer) in
            MainActor.assumeIsolated {
                self?.showAlternates(touchID: id)
            }
        }
    }

    private func showAlternates(touchID: ObjectIdentifier) {
        guard var active = touches[touchID], !active.committed, case .character(let character) = active.keyFrame.key.kind, let model else {
            return
        }
        let raw: [String] = keyboardAlternates(character: character, language: model.language)
        guard !raw.isEmpty else {
            return
        }
        let uppercase: Bool = model.page == .letters && model.shift != .off
        let alternates: [String] = raw.map { uppercase ? keyboardUppercased($0, language: model.language) : $0 }
        active.alternates = alternates
        active.selectedAlternate = 0
        touches[touchID] = active
        popup.showAlternates(alternates, above: active.keyFrame.frame, in: bounds, isDark: model.isDark)
    }

    private func showPopup(for keyFrame: KeyboardKeyFrame) {
        guard let model, case .character(let character) = keyFrame.key.kind, keyFrame.row < 3 else {
            popup.isHidden = true
            return
        }
        let shown: String = model.page == .letters && model.shift != .off ? keyboardUppercased(character, language: model.language) : character
        popup.showPreview(shown, above: keyFrame.frame, isDark: model.isDark)
    }

    private func startDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] (_: Timer) in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.deleteRepeats += 1
                // Bir süre sonra kelime kelime siler (sistem klavyesindeki gibi).
                self.delegate?.gridDeleteBackward(wholeWord: self.deleteRepeats > 14)
            }
        }
    }
}

/// Harf önizlemesi ve aksan seçenekleri kutusu.
@MainActor
final class KeyPopupView: UIView {
    private let label: UILabel = UILabel()
    private var optionLabels: [UILabel] = []
    private var isDark: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        isUserInteractionEnabled = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 34)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func showPreview(_ text: String, above keyFrame: CGRect, isDark: Bool) {
        apply(isDark: isDark)
        optionLabels.forEach { $0.removeFromSuperview() }
        optionLabels = []
        let width: CGFloat = max(keyFrame.width + 16, 48)
        frame = CGRect(x: keyFrame.midX - width / 2, y: keyFrame.minY - 58, width: width, height: 56)
        label.isHidden = false
        label.frame = bounds
        label.text = text
        isHidden = false
        superview?.bringSubviewToFront(self)
    }

    func showAlternates(_ options: [String], above keyFrame: CGRect, in container: CGRect, isDark: Bool) {
        apply(isDark: isDark)
        label.isHidden = true
        optionLabels.forEach { $0.removeFromSuperview() }
        let cell: CGFloat = 36
        let width: CGFloat = cell * CGFloat(options.count) + 8
        let x: CGFloat = min(max(container.minX + 2, keyFrame.midX - cell / 2 - 4), container.maxX - width - 2)
        frame = CGRect(x: x, y: keyFrame.minY - 56, width: width, height: 52)
        optionLabels = options.enumerated().map { (index: Int, option: String) -> UILabel in
            let cellLabel: UILabel = UILabel(frame: CGRect(x: 4 + CGFloat(index) * cell, y: 6, width: cell, height: 40))
            cellLabel.text = option
            cellLabel.textAlignment = .center
            cellLabel.font = .systemFont(ofSize: 24)
            cellLabel.textColor = isDark ? .white : .black
            cellLabel.layer.cornerRadius = 6
            cellLabel.clipsToBounds = true
            addSubview(cellLabel)
            return cellLabel
        }
        select(index: 0)
        isHidden = false
        superview?.bringSubviewToFront(self)
    }

    /// Noktanın üstündeki seçenek; kutunun dışında kalan dokunuş en yakın uçtakini seçer, çok aşağıdaysa seçim yok.
    func alternateIndex(at point: CGPoint) -> Int? {
        guard !optionLabels.isEmpty, point.y < bounds.maxY + 70 else {
            return nil
        }
        let index: Int = Int((point.x - 4) / 36)
        return min(max(index, 0), optionLabels.count - 1)
    }

    func select(index: Int?) {
        for (offset, option) in optionLabels.enumerated() {
            let selected: Bool = offset == index
            option.backgroundColor = selected ? .systemBlue : .clear
            option.textColor = selected ? .white : (isDark ? .white : .black)
        }
    }

    private func apply(isDark: Bool) {
        self.isDark = isDark
        backgroundColor = isDark ? UIColor(white: 0.42, alpha: 1) : .white
        label.textColor = isDark ? .white : .black
    }
}
