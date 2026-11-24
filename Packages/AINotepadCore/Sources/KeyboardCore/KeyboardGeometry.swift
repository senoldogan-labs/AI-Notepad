import CoreGraphics
import Foundation

/// Tuş alanının ölçüleri.
public struct KeyboardMetrics: Sendable, Hashable {
    /// Tuşların yerleştiği alan (öneri çubuğunun altı).
    public let width: CGFloat
    public let height: CGFloat
    /// Tuşlar arası yatay ve dikey boşluk.
    public let horizontalGap: CGFloat
    public let verticalGap: CGFloat
    /// Side margin outside the outermost keys' half gaps (a key's cap starts `sideInset + horizontalGap / 2` in).
    public let sideInset: CGFloat
    /// From the top edge to the first row's caps and from the last row's caps to the bottom edge.
    public let topInset: CGFloat
    public let bottomInset: CGFloat
    /// Geniş ekranda (ör. açılmış iPhone Duo) tuşlar bu genişliği aşmaz, ortalanır.
    public let maximumKeysWidth: CGFloat

    public init(
        width: CGFloat, height: CGFloat, horizontalGap: CGFloat, verticalGap: CGFloat, sideInset: CGFloat, topInset: CGFloat, bottomInset: CGFloat,
        maximumKeysWidth: CGFloat
    ) {
        self.width = width
        self.height = height
        self.horizontalGap = horizontalGap
        self.verticalGap = verticalGap
        self.sideInset = sideInset
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.maximumKeysWidth = maximumKeysWidth
    }
}

/// Bir tuşun ekrandaki yeri: çizilen kutu (`frame`) ve dokunuşu kabul ettiği alan (`hitFrame`; aradaki boşlukları da
/// kapsar, böylece iki tuşun arasına düşen dokunuş boşa gitmez).
public struct KeyboardKeyFrame: Sendable, Hashable {
    public let key: KeyboardKey
    public let row: Int
    public let frame: CGRect
    public let hitFrame: CGRect

    public init(key: KeyboardKey, row: Int, frame: CGRect, hitFrame: CGRect) {
        self.key = key
        self.row = row
        self.frame = frame
        self.hitFrame = hitFrame
    }
}

/// Satırları alana yerleştirir. Bir birimin genişliği en geniş satırdan bulunur; daha kısa satırlar (ör. 9 harfli orta
/// satır) ortalanır ve kenar tuşlarının dokunma alanı satırın kenarına dek uzar. As on the iPhone's own keyboard, the gap
/// under a row belongs to that row's keys (a finger lands a little below the key it aims at), the first row's touch area
/// reaches the top edge and the last row's the bottom edge, so no touch falls between keys. Saf fonksiyondur.
public func keyboardKeyFrames(rows: [[KeyboardKey]], metrics: KeyboardMetrics) -> [KeyboardKeyFrame] {
    guard !rows.isEmpty else {
        return []
    }
    let keysWidth: CGFloat = min(metrics.width - metrics.sideInset * 2, metrics.maximumKeysWidth)
    let originX: CGFloat = (metrics.width - keysWidth) / 2
    let widestUnits: Double = rows.map { (row: [KeyboardKey]) -> Double in row.reduce(0) { $0 + $1.widthUnits } }.max() ?? 1
    let unit: CGFloat = keysWidth / CGFloat(widestUnits)
    let rowPitch: CGFloat = (metrics.height - metrics.topInset - metrics.bottomInset + metrics.verticalGap) / CGFloat(rows.count)
    let capHeight: CGFloat = rowPitch - metrics.verticalGap
    var frames: [KeyboardKeyFrame] = []
    for (rowIndex, row) in rows.enumerated() {
        let rowUnits: Double = row.reduce(0) { $0 + $1.widthUnits }
        let rowWidth: CGFloat = CGFloat(rowUnits) * unit
        var x: CGFloat = originX + (keysWidth - rowWidth) / 2
        let top: CGFloat = metrics.topInset + CGFloat(rowIndex) * rowPitch
        let hitTop: CGFloat = rowIndex == 0 ? 0 : top
        let hitBottom: CGFloat = rowIndex == rows.count - 1 ? metrics.height : top + rowPitch
        for (keyIndex, key) in row.enumerated() {
            let width: CGFloat = CGFloat(key.widthUnits) * unit
            let frame: CGRect = CGRect(x: x + metrics.horizontalGap / 2, y: top, width: width - metrics.horizontalGap, height: capHeight)
            let hitLeft: CGFloat = keyIndex == 0 ? 0 : x
            let hitRight: CGFloat = keyIndex == row.count - 1 ? metrics.width : x + width
            let hitFrame: CGRect = CGRect(x: hitLeft, y: hitTop, width: hitRight - hitLeft, height: hitBottom - hitTop)
            frames.append(KeyboardKeyFrame(key: key, row: rowIndex, frame: frame, hitFrame: hitFrame))
            x += width
        }
    }
    return frames
}

/// The key sizes of one orientation: cap height, the gaps between caps, and the margins around them.
public struct KeyboardKeyStyle: Sendable, Hashable {
    public let capHeight: CGFloat
    public let rowGap: CGFloat
    public let horizontalGap: CGFloat
    public let sideInset: CGFloat
    /// From the suggestion bar to the first row's caps.
    public let topInset: CGFloat
    /// From the last row's caps to the keyboard's bottom edge.
    public let bottomInset: CGFloat
    /// Wide screens (an opened iPhone Duo) keep the keys at most this wide, centred.
    public let maximumKeysWidth: CGFloat

    public init(
        capHeight: CGFloat, rowGap: CGFloat, horizontalGap: CGFloat, sideInset: CGFloat, topInset: CGFloat, bottomInset: CGFloat,
        maximumKeysWidth: CGFloat
    ) {
        self.capHeight = capHeight
        self.rowGap = rowGap
        self.horizontalGap = horizontalGap
        self.sideInset = sideInset
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.maximumKeysWidth = maximumKeysWidth
    }
}

/// Portrait keys as the iPhone's own keyboard draws them on iOS 26 (measured in the iPhone 17 Simulator, iOS 26.5):
/// caps 43 pt tall on a 54 pt row pitch, 6 pt apart, 6 pt from the screen edges, 8 pt below the suggestion bar. iOS
/// leaves 17 pt of its own under a third-party keyboard, so 3 pt under the last row puts the space bar where the
/// system keyboard has it.
public let keyboardPortraitKeyStyle: KeyboardKeyStyle = KeyboardKeyStyle(
    capHeight: 43, rowGap: 11, horizontalGap: 6, sideInset: 3, topInset: 8, bottomInset: 3, maximumKeysWidth: 640
)

/// Landscape keys as the iPhone's own keyboard draws them on iOS 26 (iPhone 17 Simulator, iOS 26.5): caps 27.3 pt tall
/// on a 35.3 pt row pitch, 9 pt apart, about 6 pt inside the safe area, 6 pt below the bar; the last row ends 4 pt
/// above the keyboard's edge, where iOS leaves room for the Home indicator.
public let keyboardLandscapeKeyStyle: KeyboardKeyStyle = KeyboardKeyStyle(
    capHeight: 27.3, rowGap: 8, horizontalGap: 9, sideInset: 1, topInset: 6, bottomInset: 4, maximumKeysWidth: 720
)

/// The height `rows` rows of keys take in `style`: margins, caps and the gaps between them. Pure function.
public func keyboardKeysHeight(style: KeyboardKeyStyle, rows: Int) -> CGFloat {
    let count: CGFloat = CGFloat(max(rows, 1))
    return style.topInset + count * style.capHeight + (count - 1) * style.rowGap + style.bottomInset
}

/// The metrics for `rows` rows of keys in a `width` × `height` area. With the height `style` asks for (or more) the
/// caps keep their size and the extra goes to them; with less (Spotlight, a small iPhone) the rows share what there is
/// and the gaps get smaller (`keyboardRowGap`) instead of keys clipping. Pure function.
public func keyboardMetrics(width: CGFloat, height: CGFloat, rows: Int, style: KeyboardKeyStyle) -> KeyboardMetrics {
    let count: CGFloat = CGFloat(max(rows, 1))
    let rowPitch: CGFloat = (height - style.topInset - style.bottomInset + style.rowGap) / count
    let rowGap: CGFloat = rowPitch >= style.capHeight + style.rowGap ? style.rowGap : keyboardRowGap(rowPitch: rowPitch, preferred: style.rowGap)
    return KeyboardMetrics(
        width: width, height: height, horizontalGap: style.horizontalGap, verticalGap: rowGap, sideInset: style.sideInset, topInset: style.topInset,
        bottomInset: style.bottomInset, maximumKeysWidth: style.maximumKeysWidth
    )
}

/// The caps' height in `metrics` for `rows` rows. Pure function.
public func keyboardCapHeight(metrics: KeyboardMetrics, rows: Int) -> CGFloat {
    (metrics.height - metrics.topInset - metrics.bottomInset - CGFloat(max(rows, 1) - 1) * metrics.verticalGap) / CGFloat(max(rows, 1))
}

/// Noktaya düşen tuş: önce dokunma alanı, yoksa merkezi en yakın tuş. Saf fonksiyondur.
public func keyboardKeyFrame(at point: CGPoint, frames: [KeyboardKeyFrame]) -> KeyboardKeyFrame? {
    if let hit = frames.first(where: { $0.hitFrame.contains(point) }) {
        return hit
    }
    return frames.min { (lhs: KeyboardKeyFrame, rhs: KeyboardKeyFrame) -> Bool in
        squaredDistance(lhs.frame, point) < squaredDistance(rhs.frame, point)
    }
}

private func squaredDistance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
    let dx: CGFloat = rect.midX - point.x
    let dy: CGFloat = rect.midY - point.y
    return dx * dx + dy * dy
}

/// The suggestion bar's height: room for its 36 pt controls with a margin above them, so they do not touch the
/// keyboard's rounded top edge. The same in both orientations, like the iPhone's own suggestion bar (44 pt).
public let keyboardTopBarPreferredHeight: CGFloat = 44

/// The suggestion bar's height when iOS gives the keyboard `available` points instead of the `preferred` height it asked
/// for: it shrinks in proportion (at least 40 pt) so the keys keep their share. Before the first layout (`available`
/// 0) and with enough room it is the preferred bar height. Pure function.
public func keyboardTopBarHeight(available: CGFloat, preferredKeyboard: CGFloat, preferredBar: CGFloat) -> CGFloat {
    guard available > 0, preferredKeyboard > 0, available < preferredKeyboard else {
        return preferredBar
    }
    return max(40, (preferredBar * available / preferredKeyboard).rounded())
}

/// The gap between key rows for rows `rowPitch` apart: the preferred gap, smaller when the keys get short (at most a
/// fifth of the pitch, at least 3 pt), so a squeezed keyboard keeps usable keys instead of clipping them. Pure function.
public func keyboardRowGap(rowPitch: CGFloat, preferred: CGFloat) -> CGFloat {
    max(3, min(preferred, (rowPitch * 0.2).rounded()))
}

/// How much a key's label shrinks on a key `keyHeight` points tall: full size from 27 pt (landscape keys are 27.3, as
/// on the iPhone's own keyboard), down to 60 % on shorter keys.
/// Pure function.
public func keyboardKeyLabelScale(keyHeight: CGFloat) -> CGFloat {
    min(1, max(0.6, keyHeight / 27))
}
