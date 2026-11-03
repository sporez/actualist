import CoreGraphics
import Testing
@testable import Actualist

struct BudgetMoveMoneyFitTests {
    private let headerContent: CGFloat = 104
    private let card: CGFloat = 184

    private func fit(container: CGFloat, card: CGFloat? = nil, pad: Bool) -> BudgetMoveMoneyFit {
        BudgetMoveMoneyFit.resolve(
            containerHeight: container,
            cardHeight: card ?? self.card,
            headerContentHeight: headerContent,
            isNumberPadVisible: pad
        )
    }

    @Test func aSheetWhereTheCardFitsKeepsEveryRegularSize() {
        #expect(fit(container: 820, pad: true) == .regular)
        #expect(fit(container: 800, pad: true) == .regular)
        #expect(fit(container: 500, card: 100, pad: false) == .regular)
    }

    @Test func unmeasuredHeightsKeepTheRegularSizes() {
        #expect(BudgetMoveMoneyFit.resolve(containerHeight: 0, cardHeight: card, headerContentHeight: headerContent, isNumberPadVisible: true) == .regular)
        #expect(BudgetMoveMoneyFit.resolve(containerHeight: 600, cardHeight: 0, headerContentHeight: headerContent, isNumberPadVisible: true) == .regular)
        #expect(BudgetMoveMoneyFit.resolve(containerHeight: 600, cardHeight: card, headerContentHeight: 0, isNumberPadVisible: true) == .regular)
    }

    @Test func aSmallShortfallOnlyTrimsGreenAroundTheDirectionButton() {
        let result = fit(container: 790, pad: true)
        #expect(result.headerHeight == 322)
        #expect(result.headerTopInset == BudgetMoveMoneyFit.regular.headerTopInset)
        #expect(result.keypadKeyHeight == BudgetMoveMoneyFit.regular.keypadKeyHeight)
        #expect(result.keypadTopPadding == BudgetMoveMoneyFit.regular.keypadTopPadding)
    }

    @Test func aLargerShortfallShortensTheKeypadBeforeTheHeaderInset() {
        let result = fit(container: 700, pad: true)
        // 56 inset + 104 content + 70 for the direction button + 28 overlap.
        #expect(result.headerHeight == 258)
        #expect(result.keypadKeyHeight == 46)
        #expect(result.keypadTopPadding == 8)
        #expect(result.headerTopInset == 56)
        #expect(result.bottomReservedHeight(isNumberPadVisible: true) == 256)
    }

    @Test func theHeaderInsetShrinksLastAndStopsAtItsCompactValue() {
        let result = fit(container: 600, pad: true)
        #expect(result.keypadKeyHeight == 46)
        #expect(result.headerTopInset == 20)
        #expect(result.headerHeight == 222)

        let tiny = fit(container: 300, pad: true)
        #expect(tiny.headerTopInset == 20)
        #expect(tiny.headerHeight == 222)
    }

    @Test func withTheKeypadHiddenTheKeysKeepTheirSize() {
        let result = fit(container: 500, pad: false)
        #expect(result.keypadKeyHeight == BudgetMoveMoneyFit.regular.keypadKeyHeight)
        #expect(result.headerHeight == 256)
        #expect(result.headerTopInset == 54)
        #expect(result.bottomReservedHeight(isNumberPadVisible: false) == 78)
    }

    @Test func theCloseButtonFollowsTheHeaderInset() {
        #expect(BudgetMoveMoneyFit.regular.closeButtonTopInset == 54)
        #expect(fit(container: 600, pad: true).closeButtonTopInset == 18)
    }
}
