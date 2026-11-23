import CoreGraphics
import SwiftUI
import Testing
@testable import AINotepadUI

@Suite struct LayoutSizingTests {
    @Test func fillingSizeTakesConcreteProposalsWithoutContent() {
        #expect(fillingSize(proposal: ProposedViewSize(width: 640, height: 480), contentSize: nil) == CGSize(width: 640, height: 480))
        #expect(fillingSize(proposal: .zero, contentSize: nil) == .zero)
        let infinite: CGSize = fillingSize(proposal: .infinity, contentSize: nil)
        #expect(infinite.width == .infinity && infinite.height == .infinity)
    }

    @Test func fillingSizeUsesContentOnlyForUnspecifiedDimensions() {
        let content: CGSize = CGSize(width: 300, height: 1200)
        #expect(fillingSize(proposal: ProposedViewSize(width: 640, height: nil), contentSize: content) == CGSize(width: 640, height: 1200))
        #expect(fillingSize(proposal: ProposedViewSize(width: nil, height: 480), contentSize: content) == CGSize(width: 300, height: 480))
        #expect(fillingSize(proposal: .unspecified, contentSize: content) == content)
    }

    @Test func askInputHeightKeepsBetweenOneAndMaxLines() {
        #expect(askInputHeight(usedHeight: 0, lineHeight: 18.4, maxLines: 6) == 19)
        #expect(askInputHeight(usedHeight: 55.2, lineHeight: 18.4, maxLines: 6) == 56)
        #expect(askInputHeight(usedHeight: 400, lineHeight: 18.4, maxLines: 6) == 111)
    }
}
