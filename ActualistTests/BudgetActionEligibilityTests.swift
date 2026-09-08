import Testing
@testable import Actualist

@Suite("Budget action eligibility")
struct BudgetActionEligibilityTests {
    @Test("tracking allows direct assignment for income and expense")
    func trackingDirectAssignment() {
        #expect(BudgetActionEligibility.allows(.directAssignment(isIncome: false), in: .tracking))
        #expect(BudgetActionEligibility.allows(.directAssignment(isIncome: true), in: .tracking))
    }

    @Test("tracking refuses envelope-only money actions")
    func trackingRefusesEnvelopeActions() {
        #expect(!BudgetActionEligibility.allows(.moveMoney, in: .tracking))
        #expect(!BudgetActionEligibility.allows(.coverOverspending, in: .tracking))
        #expect(!BudgetActionEligibility.allows(.holdForNextMonth, in: .tracking))
    }

    @Test("tracking allows expense carryover and refuses income carryover")
    func trackingCarryover() {
        #expect(BudgetActionEligibility.allows(.carryover(isIncome: false), in: .tracking))
        #expect(!BudgetActionEligibility.allows(.carryover(isIncome: true), in: .tracking))
    }

    @Test("tracking keeps template actions supported")
    func trackingTemplate() {
        #expect(BudgetActionEligibility.allows(.template, in: .tracking))
    }

    @Test("envelope actions remain compatible with existing behavior")
    func envelopeCompatibility() {
        let actions: [BudgetActionEligibility.Action] = [
            .directAssignment(isIncome: false),
            .directAssignment(isIncome: true),
            .moveMoney,
            .coverOverspending,
            .holdForNextMonth,
            .carryover(isIncome: false),
            .carryover(isIncome: true),
            .template
        ]

        for action in actions {
            #expect(BudgetActionEligibility.allows(action, in: .envelope))
        }
    }
}
