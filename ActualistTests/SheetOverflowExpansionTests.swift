import CoreGraphics
import SwiftUI
import Testing
@testable import Actualist

struct SheetOverflowExpansionTests {
    private typealias Fit = SheetOverflowExpansion.Fit

    @Test func contentThatFitsAtMediumDoesNotGrow() {
        var expansion = SheetOverflowExpansion()

        expansion.record(Fit(contentHeight: 407, containerHeight: 419.67), at: .medium)

        #expect(!expansion.isGrowing)
    }

    @Test func contentWithinRoundingOfTheContainerDoesNotGrow() {
        var expansion = SheetOverflowExpansion()

        expansion.record(Fit(contentHeight: 300.4, containerHeight: 300), at: .medium)

        #expect(!expansion.isGrowing)
    }

    @Test func overflowAtMediumGrows() {
        var expansion = SheetOverflowExpansion()

        expansion.record(Fit(contentHeight: 112, containerHeight: 252.67), at: .medium)
        expansion.record(Fit(contentHeight: 407, containerHeight: 252.67), at: .medium)

        #expect(expansion.isGrowing)
    }

    @Test func unmeasuredContainerDoesNotGrow() {
        var expansion = SheetOverflowExpansion()

        expansion.record(Fit(contentHeight: 407, containerHeight: 0), at: .medium)

        #expect(!expansion.isGrowing)
    }

    @Test func ownRequestsWhileGrowingDoNotSettle() {
        var expansion = SheetOverflowExpansion()
        expansion.record(Fit(contentHeight: 538, containerHeight: 374), at: .medium)

        expansion.detentDidChange(to: .large)
        expansion.detentDidChange(to: .medium)
        expansion.record(Fit(contentHeight: 538, containerHeight: 374), at: .medium)

        #expect(expansion.isGrowing)
    }

    @Test func growingEndsWhenTheContainerGrows() {
        var expansion = SheetOverflowExpansion()
        expansion.record(Fit(contentHeight: 538, containerHeight: 374), at: .medium)

        expansion.record(Fit(contentHeight: 538, containerHeight: 716), at: .large)

        #expect(!expansion.isGrowing)
    }

    @Test func neverGrowsAgainAfterReachingLarge() {
        var expansion = SheetOverflowExpansion()
        expansion.record(Fit(contentHeight: 538, containerHeight: 374), at: .medium)
        expansion.record(Fit(contentHeight: 538, containerHeight: 716), at: .large)

        expansion.detentDidChange(to: .medium)
        expansion.record(Fit(contentHeight: 538, containerHeight: 374), at: .medium)

        #expect(!expansion.isGrowing)
    }

    @Test func userDraggingToLargeFirstMeansItNeverGrows() {
        var expansion = SheetOverflowExpansion()
        expansion.record(Fit(contentHeight: 200, containerHeight: 374), at: .medium)

        expansion.detentDidChange(to: .large)
        expansion.detentDidChange(to: .medium)
        expansion.record(Fit(contentHeight: 538, containerHeight: 374), at: .medium)

        #expect(!expansion.isGrowing)
    }

    @Test func givingUpSettles() {
        var expansion = SheetOverflowExpansion()
        expansion.record(Fit(contentHeight: 538, containerHeight: 374), at: .medium)

        expansion.stopGrowing()
        expansion.record(Fit(contentHeight: 538, containerHeight: 374), at: .medium)

        #expect(!expansion.isGrowing)
    }

    @Test func overflowAtLargeDoesNotStartGrowing() {
        var expansion = SheetOverflowExpansion()

        expansion.record(Fit(contentHeight: 900, containerHeight: 716), at: .large)

        #expect(!expansion.isGrowing)
    }
}
