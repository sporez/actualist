import Testing
@testable import Actualist

struct ScrollDirectedExpansionTests {
    @Test func startsExpanded() {
        #expect(ScrollDirectedExpansion().isExpanded)
    }

    @Test func firstDownwardMoveCollapses() {
        var expansion = ScrollDirectedExpansion()

        expansion.update(previousOffset: 40, offset: 41, maxOffset: 400)

        #expect(!expansion.isExpanded)
    }

    @Test func firstUpwardMoveExpands() {
        var expansion = ScrollDirectedExpansion(isExpanded: false)

        expansion.update(previousOffset: 80, offset: 79, maxOffset: 400)

        #expect(expansion.isExpanded)
    }

    @Test func subPixelJitterDoesNotFlip() {
        var expansion = ScrollDirectedExpansion(isExpanded: false)

        expansion.update(previousOffset: 40, offset: 40.4, maxOffset: 400)

        #expect(!expansion.isExpanded)
    }

    @Test func topOfContentAlwaysExpands() {
        var expansion = ScrollDirectedExpansion(isExpanded: false)

        expansion.update(previousOffset: 18, offset: -4, maxOffset: 400)

        #expect(expansion.isExpanded)
    }

    @Test func equalOffsetsDoNotFlip() {
        var expansion = ScrollDirectedExpansion(isExpanded: false)

        expansion.update(previousOffset: 40, offset: 40, maxOffset: 400)

        #expect(!expansion.isExpanded)
    }

    @Test func unscrollableContentStaysExpanded() {
        var expansion = ScrollDirectedExpansion()

        expansion.update(previousOffset: 0, offset: 8, maxOffset: 0)

        #expect(expansion.isExpanded)
    }

    @Test func bottomOverscrollStaysCollapsed() {
        var expansion = ScrollDirectedExpansion(isExpanded: false)

        expansion.update(previousOffset: 400, offset: 428, maxOffset: 400)

        #expect(!expansion.isExpanded)
    }

    @Test func bottomRubberBandRecoveryDoesNotExpand() {
        var expansion = ScrollDirectedExpansion(isExpanded: false)

        expansion.update(previousOffset: 428, offset: 406, maxOffset: 400)

        #expect(!expansion.isExpanded)
    }

    @Test func scrollingUpFromSettledBottomExpands() {
        var expansion = ScrollDirectedExpansion(isExpanded: false)

        expansion.update(previousOffset: 400, offset: 399, maxOffset: 400)

        #expect(expansion.isExpanded)
    }
}
