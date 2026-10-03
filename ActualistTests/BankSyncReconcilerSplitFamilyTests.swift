import Foundation
import Testing
@testable import Actualist

/// Split-family matching in the bank-sync reconciler: valid children as fuzzy
/// candidates, children reserved by an exact-matched parent (loot-core
/// 24deae7), and parent clear cascades.
struct BankSyncReconcilerSplitFamilyTests: BankSyncReconcilerFixtures {
    @Test func validSplitChildCanBeFuzzyMatched() {
        // A split child is a valid match candidate (v_transactions semantics).
        let rows = [
            existing(id: "parent", day: "20240301", amount: -3_000, isParent: true),
            existing(id: "child", day: "20240301", amount: -1_000, isChild: true, parentID: "parent"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240301", amount: -1_000)],
            existing: rows
        )
        #expect(update(for: "child", plan) != nil)
    }

    @Test func invalidChildIsNotACandidate() {
        // is_child without parent_id is not in v_transactions.
        let rows = [
            existing(id: "broken", day: "20240301", isChild: true, parentID: nil)
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240301")],
            existing: rows
        )
        #expect(insertIDs(plan).count == 1)
    }

    private var splitFamily: [BankSyncReconciliation.Existing] {
        [
            existing(id: "parent", financialID: "fin-1", day: "20240301", amount: -3_000, isParent: true),
            existing(id: "child", day: "20240301", amount: -1_000, isChild: true, parentID: "parent"),
        ]
    }

    @Test func exactMatchedParentReservesChildFromFuzzyPassTwo() {
        // Pass 2 (same payee) would take the child; the exact-matched parent
        // reserves it, so the second download inserts (loot-core 24deae7).
        let second = candidate(day: "20240301", amount: -1_000, payee: "payee-a")
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301", amount: -3_000), second],
            existing: splitFamily
        )
        #expect(plan.entries.count == 2)
        #expect(update(for: "parent", plan) != nil)
        #expect(update(for: "child", plan) == nil)
        #expect(insertIDs(plan) == [second])
    }

    @Test func exactMatchedParentReservesChildFromFuzzyPassThree() {
        // Different payee skips pass 2; pass 3 must also skip the child.
        let second = candidate(day: "20240301", amount: -1_000, payee: "payee-b")
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301", amount: -3_000), second],
            existing: splitFamily
        )
        #expect(plan.entries.count == 2)
        #expect(update(for: "child", plan) == nil)
        #expect(insertIDs(plan) == [second])
    }

    @Test func childReservationDoesNotDependOnDownloadOrder() {
        // Exact matches resolve for the whole batch before either fuzzy pass,
        // so a child-matching download listed first is still reserved.
        let first = candidate(day: "20240301", amount: -1_000)
        let plan = BankSyncReconciliation.plan(
            candidates: [first, candidate(id: "fin-1", day: "20240301", amount: -3_000)],
            existing: splitFamily
        )
        #expect(plan.entries.count == 2)
        #expect(update(for: "parent", plan) != nil)
        #expect(update(for: "child", plan) == nil)
        #expect(insertIDs(plan) == [first])
    }

    @Test func childStaysMatchableWhenParentWasNotExactMatched() {
        // Parent has no financial_id, so nothing is reserved.
        let rows = [
            existing(id: "parent", day: "20240301", amount: -3_000, isParent: true),
            existing(id: "child", day: "20240301", amount: -1_000, isChild: true, parentID: "parent"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301", amount: -3_000), candidate(day: "20240301", amount: -1_000)],
            existing: rows
        )
        #expect(update(for: "parent", plan) != nil)
        #expect(update(for: "child", plan) != nil)
        #expect(insertIDs(plan).isEmpty)
    }

    @Test func fuzzyMatchedParentDoesNotReserveChildren() {
        // Upstream only reserves on an exact (id) match; a fuzzy-matched
        // parent leaves its children eligible. Passes before and after.
        let rows = [
            existing(id: "parent", day: "20240301", amount: -3_000, isParent: true),
            existing(id: "child", day: "20240301", amount: -1_000, isChild: true, parentID: "parent"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240301", amount: -3_000), candidate(day: "20240301", amount: -1_000)],
            existing: rows
        )
        #expect(update(for: "parent", plan) != nil)
        #expect(update(for: "child", plan) != nil)
    }

    @Test func parentClearCascadePlansClearedOntoLiveChildren() {
        let rows = [
            existing(id: "parent", day: "20240301", amount: -3_000, cleared: false, isParent: true),
            existing(id: "child-1", day: "20240301", amount: -1_000, cleared: false, isChild: true, parentID: "parent"),
            existing(id: "child-2", day: "20240301", amount: -2_000, cleared: false, isChild: true, parentID: "parent"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301", amount: -3_000, cleared: true)],
            existing: rows
        )
        let matched = update(for: "parent", plan)
        #expect(matched?.cleared == true)
        #expect(Set(matched?.childIDs ?? []) == ["child-1", "child-2"])
    }

    @Test func reconciledParentDoesNotCascade() {
        let rows = [
            existing(id: "parent", day: "20240301", amount: -3_000, cleared: false, reconciled: true, isParent: true),
            existing(id: "child-1", day: "20240301", amount: -1_000, cleared: false, isChild: true, parentID: "parent"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301", amount: -3_000, cleared: true)],
            existing: rows
        )
        #expect(isUnchanged("parent", plan))
        #expect(update(for: "child-1", plan) == nil)
    }
}
