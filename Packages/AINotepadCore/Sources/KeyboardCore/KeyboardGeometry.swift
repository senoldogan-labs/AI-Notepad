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
    /// Kenar boşlukları.
    public let sideInset: CGFloat
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
/// satır) ortalanır ve kenar tuşlarının dokunma alanı satırın kenarına dek uzar. Saf fonksiyondur.
public func keyboardKeyFrames(rows: [[KeyboardKey]], metrics: KeyboardMetrics) -> [KeyboardKeyFrame] {
    guard !rows.isEmpty else {
        return []
    }
    let keysWidth: CGFloat = min(metrics.width - metrics.sideInset * 2, metrics.maximumKeysWidth)
    let originX: CGFloat = (metrics.width - keysWidth) / 2
    let widestUnits: Double = rows.map { (row: [KeyboardKey]) -> Double in row.reduce(0) { $0 + $1.widthUnits } }.max() ?? 1
    let unit: CGFloat = keysWidth / CGFloat(widestUnits)
    let rowPitch: CGFloat = (metrics.height - metrics.topInset - metrics.bottomInset) / CGFloat(rows.count)
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
            let frame: CGRect = CGRect(
                x: x + metrics.horizontalGap / 2, y: top + metrics.verticalGap / 2, width: width - metrics.horizontalGap, height: rowPitch - metrics.verticalGap
            )
            let hitLeft: CGFloat = keyIndex == 0 ? 0 : x
            let hitRight: CGFloat = keyIndex == row.count - 1 ? metrics.width : x + width
            let hitFrame: CGRect = CGRect(x: hitLeft, y: hitTop, width: hitRight - hitLeft, height: hitBottom - hitTop)
            frames.append(KeyboardKeyFrame(key: key, row: rowIndex, frame: frame, hitFrame: hitFrame))
            x += width
        }
    }
    return frames
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
