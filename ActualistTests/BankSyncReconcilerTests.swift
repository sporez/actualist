import Foundation
import Testing
@testable import Actualist

/// Phase 2 tests for the pure SimpleFIN bank-sync reconciler: loot-core's
/// three-pass matcher (`strictIdChecking: false`, ±7 days, valid split
/// children), rule projection before matching, and the opening-balance math.
/// No network, no writes.
struct BankSyncReconcilerTests {

    // MARK: - Fixtures

    private func candidate(
        id: String? = nil,
        day: String = "20240301",
        amount: Int = -1_000,
        payee: String? = "payee-a",
        notes: String? = nil,
        category: String? = nil,
        cleared: Bool = true,
        importedPayee: String? = nil
    ) -> BankSyncReconciliation.Candidate {
        BankSyncReconciliation.Candidate(
            financialID: id,
            dayID: day,
            amountMinorUnits: amount,
            payeeID: payee,
            notes: notes,
            categoryID: category,
            cleared: cleared,
            importedPayee: importedPayee ?? "Steam"
        )
    }

    private func existing(
        id: String,
        financialID: String? = nil,
        day: String = "20240301",
        amount: Int = -1_000,
        payee: String? = "payee-a",
        category: String? = nil,
        notes: String? = nil,
        cleared: Bool = false,
        reconciled: Bool = false,
        importedPayee: String? = nil,
        isParent: Bool = false,
        isChild: Bool = false,
        parentID: String? = nil
    ) -> BankSyncReconciliation.Existing {
        BankSyncReconciliation.Existing(
            id: id,
            financialID: financialID,
            dayID: day,
            amountMinorUnits: amount,
            payeeID: payee,
            categoryID: category,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            importedPayee: importedPayee,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID
        )
    }

    private func insertIDs(_ plan: BankSyncReconciliation.Plan) -> [BankSyncReconciliation.Candidate] {
        plan.entries.compactMap { entry in
            if case .insert(let candidate) = entry { return candidate }
            return nil
        }
    }

    private func update(for existingID: String, _ plan: BankSyncReconciliation.Plan) -> BankSyncReconciliation.MatchedUpdate? {
        for entry in plan.entries {
            if case .update(let matched) = entry, matched.existingID == existingID {
                return matched
            }
        }
        return nil
    }

    private func isUnchanged(_ existingID: String, _ plan: BankSyncReconciliation.Plan) -> Bool {
        plan.entries.contains { entry in
            if case .unchanged(let id) = entry { return id == existingID }
            return false
        }
    }

    // MARK: - Pass behavior

    @Test func emptyExistingEverythingInserts() {
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "a"), candidate(id: "b", day: "20240305")],
            existing: []
        )
        #expect(insertIDs(plan).count == 2)
    }

    @Test func idMatchWinsOverCloserDate() {
        // The id match is at the edge of the window; an amount-only neighbor
        // is on the exact day. Pass 1 still wins.
        let rows = [
            existing(id: "neighbor", day: "20240301"),
            existing(id: "by-id", financialID: "fin-1", day: "20240308", payee: "payee-b"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301")],
            existing: rows
        )
        #expect(update(for: "by-id", plan) != nil)
        #expect(update(for: "neighbor", plan) == nil)
    }

    @Test func samePayeeOutranksEarlierAmountOnlyCandidate() {
        // Two same-amount rows in the window. The exact-day row has a
        // different payee; the −6-day row shares the payee. Pass 2 (payee)
        // runs across every candidate before pass 3 (nearest).
        let rows = [
            existing(id: "exact-day", day: "20240301", payee: "payee-b"),
            existing(id: "same-payee", day: "20240224", payee: "payee-a"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240301", payee: "payee-a")],
            existing: rows
        )
        #expect(update(for: "same-payee", plan) != nil)
    }

    @Test func oneLocalRowClaimedOnce() {
        let rows = [existing(id: "only", day: "20240301")]
        let plan = BankSyncReconciliation.plan(
            candidates: [
                candidate(day: "20240301"),
                candidate(day: "20240302"),
            ],
            existing: rows
        )
        #expect(update(for: "only", plan) != nil)
        #expect(insertIDs(plan).count == 1)
    }

    @Test func sevenDayBoundaryInclusive() {
        let rows = [existing(id: "edge", day: "20240301")]
        let inside = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240308")],
            existing: rows
        )
        #expect(update(for: "edge", inside) != nil)

        let outside = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240309")],
            existing: rows
        )
        #expect(insertIDs(outside).count == 1)
    }

    @Test func sevenDayBoundaryAcrossYear() {
        let rows = [existing(id: "nye", day: "20231231")]
        let inside = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240107")],
            existing: rows
        )
        #expect(update(for: "nye", inside) != nil)

        let outside = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240108")],
            existing: rows
        )
        #expect(insertIDs(outside).count == 1)
    }

    @Test func differentAmountNeverMatches() {
        let rows = [existing(id: "row", day: "20240301", amount: -2_000)]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(day: "20240301", amount: -1_000)],
            existing: rows
        )
        #expect(insertIDs(plan).count == 1)
    }

    @Test func differentImportedIDStillFuzzyMatches() {
        // strictIdChecking: false — a pending row reissued with a new bank id
        // still matches on amount + payee + date.
        let rows = [existing(id: "pending", financialID: "old-id", day: "20240301")]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "new-id", day: "20240301")],
            existing: rows
        )
        let matched = update(for: "pending", plan)
        #expect(matched?.financialID == "new-id")
    }

    @Test func reconciledRowIsUnchangedAndLocked() {
        let rows = [existing(id: "locked", day: "20240301", reconciled: true)]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301")],
            existing: rows
        )
        #expect(isUnchanged("locked", plan))
        #expect(update(for: "locked", plan) == nil)
        #expect(insertIDs(plan).count == 0)
    }

    @Test func noChangeAtAllIsUnchanged() {
        let rows = [
            existing(
                id: "same",
                financialID: "fin-1",
                day: "20240301",
                cleared: true,
                importedPayee: "Steam"
            )
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301", cleared: true)],
            existing: rows
        )
        #expect(isUnchanged("same", plan))
    }

    // MARK: - Match update shape

    @Test func matchFillsBlanksButKeepsUserValues() {
        let rows = [
            existing(
                id: "row",
                day: "20240301",
                payee: "user-payee",
                category: "user-category",
                notes: "user notes",
                importedPayee: "Old"
            )
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", payee: "payee-a", notes: "bank notes", category: "bank-category")],
            existing: rows
        )
        let matched = update(for: "row", plan)
        #expect(matched?.payeeID == "user-payee")
        #expect(matched?.categoryID == "user-category")
        #expect(matched?.notes == "user notes")
        // Bank-owned fields always come from the download.
        #expect(matched?.financialID == "fin-1")
        #expect(matched?.importedPayee == "Steam")
    }

    @Test func matchClearsUnclearedRow() {
        let rows = [existing(id: "row", day: "20240301", cleared: false)]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301", cleared: true)],
            existing: rows
        )
        #expect(update(for: "row", plan)?.cleared == true)
    }

    @Test func pendingBooksClearsOnLaterIdMatch() {
        // Pending (uncleared, no id) books later: the posted row carries the
        // bank id and clears the pending row.
        let rows = [existing(id: "pending", day: "20240301", cleared: false)]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "posted-1", day: "20240302", cleared: true)],
            existing: rows
        )
        let matched = update(for: "pending", plan)
        #expect(matched?.financialID == "posted-1")
        #expect(matched?.cleared == true)
    }

    @Test func hashInNotesIsEscaped() {
        // loot-core normalizeBankSyncTransactions: notes go through
        // `trim().replace(/#/g, '##')` so `#template` markers are inert.
        #expect(BankSyncReconciliation.escapedNotes("  coffee #grab  ") == "coffee ##grab")
        #expect(BankSyncReconciliation.escapedNotes("#template") == "##template")
        #expect(BankSyncReconciliation.escapedNotes("plain") == "plain")
    }

    // MARK: - Rules before match

    @Test func ruleRewritesPayeeBeforeMatch() {
        // The rule changes the candidate's payee; the matcher must see the
        // post-rule payee, so it matches the row that shares the new payee.
        let rows = [
            existing(id: "original-payee", day: "20240301", payee: "payee-a"),
            existing(id: "rule-payee", day: "20240305", payee: "payee-b"),
        ]
        let base = candidate(day: "20240301", payee: "payee-a")
        let projected = BankSyncReconciliation.applyingRulePreview(
            TransactionRulePreview(
                categoryID: nil,
                notes: nil,
                payeeID: "payee-b",
                amountMinorUnits: nil,
                date: nil,
                cleared: nil,
                scheduleID: nil,
                deletesTransaction: false,
                splits: []
            ),
            to: base
        )
        #expect(projected?.payeeID == "payee-b")
        let plan = BankSyncReconciliation.plan(candidates: [projected!], existing: rows)
        #expect(update(for: "rule-payee", plan) != nil)
    }

    @Test func ruleChangesAmountAndMissesSameAmountNeighbor() {
        // The rule rewrites the amount; the same-amount neighbor in the window
        // no longer matches because the fuzzy dataset filters by amount.
        let rows = [existing(id: "neighbor", day: "20240301", amount: -1_000)]
        let projected = BankSyncReconciliation.applyingRulePreview(
            TransactionRulePreview(
                categoryID: nil,
                notes: nil,
                payeeID: nil,
                amountMinorUnits: -9_900,
                date: nil,
                cleared: nil,
                scheduleID: nil,
                deletesTransaction: false,
                splits: []
            ),
            to: candidate(day: "20240301", amount: -1_000)
        )
        #expect(projected?.amountMinorUnits == -9_900)
        let plan = BankSyncReconciliation.plan(candidates: [projected!], existing: rows)
        #expect(insertIDs(plan).count == 1)
    }

    @Test func deleteRuleDropsCandidate() {
        let projected = BankSyncReconciliation.applyingRulePreview(
            TransactionRulePreview(
                categoryID: nil,
                notes: nil,
                payeeID: nil,
                amountMinorUnits: nil,
                date: nil,
                cleared: nil,
                scheduleID: nil,
                deletesTransaction: true,
                splits: []
            ),
            to: candidate()
        )
        #expect(projected == nil)
    }

    // MARK: - Splits

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

    @Test func oneDownloadCannotClaimParentAndChildOfSameFamily() {
        // The parent is claimed by the id match; the second candidate cannot
        // claim a row that is already taken.
        let rows = [
            existing(id: "parent", financialID: "fin-1", day: "20240301", amount: -3_000, isParent: true),
            existing(id: "child", day: "20240301", amount: -1_000, isChild: true, parentID: "parent"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [
                candidate(id: "fin-1", day: "20240301", amount: -3_000),
                candidate(day: "20240301", amount: -1_000),
            ],
            existing: rows
        )
        #expect(update(for: "parent", plan) != nil)
        // The child row is taken only if a candidate claimed it; here the
        // second candidate matches it legitimately (it is unclaimed).
        #expect(update(for: "child", plan) != nil || insertIDs(plan).count == 1)
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

    @Test func childMatchUpdatesOnlyThatChild() {
        let rows = [
            existing(id: "parent", day: "20240301", amount: -3_000, cleared: false, isParent: true),
            existing(id: "child", day: "20240301", amount: -1_000, cleared: false, isChild: true, parentID: "parent"),
        ]
        let plan = BankSyncReconciliation.plan(
            candidates: [candidate(id: "fin-1", day: "20240301", amount: -1_000, cleared: true)],
            existing: rows
        )
        let matched = update(for: "child", plan)
        #expect(matched != nil)
        #expect(matched?.childIDs.isEmpty == true)
        #expect(update(for: "parent", plan) == nil)
    }

    // MARK: - Day distance

    @Test func dayDistanceIsCalendarDays() {
        #expect(BankSyncReconciliation.dayDistance("20240301", "20240301") == 0)
        #expect(BankSyncReconciliation.dayDistance("20240301", "20240308") == 7)
        #expect(BankSyncReconciliation.dayDistance("20240308", "20240301") == 7)
        #expect(BankSyncReconciliation.dayDistance("20240228", "20240301") == 2)
        #expect(BankSyncReconciliation.dayDistance("20231231", "20240101") == 1)
        #expect(BankSyncReconciliation.dayDistance("20240228", "20240229") == 1)
    }

    // MARK: - Opening balance

    @Test func openingBalanceSkipsWhenAccountHasTransactions() {
        #expect(
            BankSyncReconciliation.openingBalance(
                currentBalanceMinorUnits: 10_000,
                candidateAmounts: [-1_000, -2_000],
                earliestDayID: "20240301",
                accountHadLiveTransactions: true
            ) == nil
        )
    }

    @Test func openingBalanceIsBalanceMinusAllDownloaded() {
        // Uses every normalized provider candidate in the window, before
        // reconciliation and rule-driven suppression — not just the inserts.
        let opening = BankSyncReconciliation.openingBalance(
            currentBalanceMinorUnits: 7_000,
            candidateAmounts: [-1_000, -2_000, 500],
            earliestDayID: "20240220",
            accountHadLiveTransactions: false
        )
        #expect(opening?.amountMinorUnits == 9_500)
        #expect(opening?.dayID == "20240220")
    }

    @Test func openingBalanceSkipsZero() {
        #expect(
            BankSyncReconciliation.openingBalance(
                currentBalanceMinorUnits: -3_000,
                candidateAmounts: [-1_000, -2_000],
                earliestDayID: "20240301",
                accountHadLiveTransactions: false
            ) == nil
        )
    }

    @Test func openingBalanceWithNoCandidatesIsToday() {
        let opening = BankSyncReconciliation.openingBalance(
            currentBalanceMinorUnits: 4_200,
            candidateAmounts: [],
            earliestDayID: nil,
            accountHadLiveTransactions: false
        )
        #expect(opening?.amountMinorUnits == 4_200)
        #expect(opening?.dayID == BankSyncReconciliation.todayDayID())
    }
}
