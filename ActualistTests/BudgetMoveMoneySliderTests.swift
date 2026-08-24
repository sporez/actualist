import Foundation
import Testing
@testable import Actualist

struct BudgetMoveMoneySliderTests {
    @Test func coverIntroAmountInterpolatesFromZeroToTheTarget() {
        #expect(BudgetMoveMoneyCoverIntro.amount(progress: 0, target: 7_693) == 0)
        #expect(BudgetMoveMoneyCoverIntro.amount(progress: 0.5, target: 7_693) == 3_847)
        #expect(BudgetMoveMoneyCoverIntro.amount(progress: 1, target: 7_693) == 7_693)
        #expect(BudgetMoveMoneyCoverIntro.amount(progress: -1, target: 7_693) == 0)
        #expect(BudgetMoveMoneyCoverIntro.amount(progress: 2, target: 7_693) == 7_693)
    }

    @Test func maximumAmountScalesAvailableByOneAndAQuarter() {
        #expect(BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 11_220, currentAmount: 0) == 14_025)
        #expect(BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 12_000, currentAmount: 0) == 15_000)
        #expect(BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 5_000, currentAmount: 0) == 6_250)
    }

    @Test func maximumAmountUsesCurrentOnlyAsAFloor() {
        #expect(BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 5_000, currentAmount: 7_693) == 7_693)
        #expect(BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 12_000, currentAmount: 7_693) == 15_000)
    }

    @Test func maximumAmountDoesNotGrowWhenCurrentEqualsTheCurrentMaximum() {
        let baseline = 11_220
        var current = 0
        var maximum = BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: baseline, currentAmount: current)
        #expect(maximum == 14_025)

        for _ in 0..<80 {
            current = maximum
            let next = BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: baseline, currentAmount: current)
            #expect(next == maximum)
            maximum = next
        }
    }

    @Test func maximumAmountUsesASmallFloorOnlyWhenThereIsNothingToScale() {
        #expect(
            BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 0, currentAmount: 0)
                == BudgetMoveMoneySliderMetrics.zeroAvailableMaximumAmount
        )
        #expect(BudgetMoveMoneySliderMetrics.maximumAmount(baselineAmount: 0, currentAmount: 500) == 500)
    }

    @Test func scaledAmountRoundsUpSoThereIsAlwaysHeadroom() {
        #expect(BudgetMoveMoneySliderMetrics.scaledAmount(1) == 2)
        #expect(BudgetMoveMoneySliderMetrics.scaledAmount(7_693) == 9_617)
        #expect(BudgetMoveMoneySliderMetrics.scaledAmount(0) == 0)
    }

    @Test func detentHoldsAtAvailableUntilTheNextGesture() {
        var detent = BudgetMoveMoneySliderDetent()
        detent.beginEditing(sliderID: "single", amount: 0, detentAmount: 11_220)

        #expect(detent.apply(proposedAmount: 5_000, detentAmount: 11_220) == 5_000)
        #expect(detent.bumpCount == 0)

        #expect(detent.apply(proposedAmount: 13_000, detentAmount: 11_220) == 11_220)
        #expect(detent.bumpCount == 1)
        #expect(detent.phase == .held)

        #expect(detent.apply(proposedAmount: 14_000, detentAmount: 11_220) == 11_220)
        #expect(detent.bumpCount == 1)

        detent.endEditing(amount: 11_220, detentAmount: 11_220)
        detent.beginEditing(sliderID: "single", amount: 11_220, detentAmount: 11_220)

        #expect(detent.apply(proposedAmount: 13_000, detentAmount: 11_220) == 13_000)
        #expect(detent.phase == .overshooting)
        #expect(detent.bumpCount == 1)
    }

    @Test func detentBumpHappensAtAvailableNotAtTheTrackEnd() {
        var detent = BudgetMoveMoneySliderDetent()
        detent.beginEditing(sliderID: "single", amount: 0, detentAmount: 11_220)

        #expect(detent.apply(proposedAmount: 11_219, detentAmount: 11_220) == 11_219)
        #expect(detent.bumpCount == 0)

        #expect(detent.apply(proposedAmount: 11_221, detentAmount: 11_220) == 11_220)
        #expect(detent.bumpCount == 1)

        #expect(detent.apply(proposedAmount: 14_025, detentAmount: 11_220) == 11_220)
        #expect(detent.bumpCount == 1)
    }

    @Test func detentDoesNotFireWhenThereIsNoAvailableAmount() {
        var detent = BudgetMoveMoneySliderDetent()
        detent.beginEditing(sliderID: "single", amount: 0, detentAmount: 0)

        #expect(detent.apply(proposedAmount: 2_000, detentAmount: 0) == 2_000)
        #expect(detent.bumpCount == 0)
    }

    @Test func detentDoesNotApplyOutsideADragGesture() {
        var detent = BudgetMoveMoneySliderDetent()

        #expect(detent.apply(proposedAmount: 13_000, detentAmount: 11_220) == 13_000)
        #expect(detent.bumpCount == 0)
        #expect(detent.phase == .overshooting)
    }

    @Test func switchingSlidersDoesNotInheritOvershootUnlock() {
        var detent = BudgetMoveMoneySliderDetent()
        detent.beginEditing(sliderID: "utilities", amount: 0, detentAmount: 4_000)
        #expect(detent.apply(proposedAmount: 5_000, detentAmount: 4_000) == 4_000)
        detent.endEditing(amount: 4_000, detentAmount: 4_000)

        detent.beginEditing(sliderID: "to-budget", amount: 0, detentAmount: 6_000)
        #expect(detent.apply(proposedAmount: 8_000, detentAmount: 6_000) == 6_000)
        #expect(detent.bumpCount == 2)
        #expect(detent.phase == .held)
    }

    @Test func draggingBackBelowAvailableRearmsTheDetent() {
        var detent = BudgetMoveMoneySliderDetent()
        detent.beginEditing(sliderID: "single", amount: 13_000, detentAmount: 11_220)
        #expect(detent.phase == .overshooting)

        #expect(detent.apply(proposedAmount: 8_000, detentAmount: 11_220) == 8_000)
        #expect(detent.phase == .below)

        #expect(detent.apply(proposedAmount: 13_000, detentAmount: 11_220) == 11_220)
        #expect(detent.phase == .held)
        #expect(detent.bumpCount == 1)
    }

    @Test func specMarksOvershootOnlyPastAPositiveDetent() {
        let overshooting = BudgetMoveMoneySliderSpec(amount: 13_000, detentAmount: 11_220, maximumAmount: 16_250)
        #expect(overshooting.isOvershooting)
        #expect(abs(overshooting.amountDollars - 130) < 0.001)

        let atDetent = BudgetMoveMoneySliderSpec(amount: 11_220, detentAmount: 11_220, maximumAmount: 14_025)
        #expect(atDetent.isOvershooting == false)

        let noDetent = BudgetMoveMoneySliderSpec(amount: 2_000, detentAmount: 0, maximumAmount: 2_500)
        #expect(noDetent.isOvershooting == false)
    }
}
