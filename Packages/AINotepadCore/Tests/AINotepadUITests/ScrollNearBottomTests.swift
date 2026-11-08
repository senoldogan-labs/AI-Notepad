import CoreGraphics
import Testing
@testable import AINotepadUI

/// macOS 14'teki "sona yakın mı" hesabı, macOS 15'in `ScrollGeometry` hesabıyla aynı sonucu verir.
@Suite struct ScrollNearBottomTests {
    /// İçerik 1000 pt, alan 400 pt: `contentOffset.y + 400 >= 1000 - eşik` ile `içeriğin alt kenarı <= 400 + eşik` aynı.
    @Test func matchesScrollGeometryRule() {
        let contentHeight: CGFloat = 1000
        let visibleHeight: CGFloat = 400
        for threshold in [CGFloat(60), 120] {
            for offset in stride(from: CGFloat(0), through: 600, by: 10) {
                let byGeometry: Bool = offset + visibleHeight >= contentHeight - threshold
                let contentBottom: CGFloat = contentHeight - offset
                #expect(
                    isScrollContentNearBottom(contentBottom: contentBottom, visibleHeight: visibleHeight, threshold: threshold) == byGeometry,
                    "offset: \(offset), threshold: \(threshold)"
                )
            }
        }
    }
}
