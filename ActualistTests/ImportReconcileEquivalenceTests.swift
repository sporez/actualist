import Foundation
import Testing
@testable import Actualist

/// CSV matching cases on the shared reconciler (`BankSyncReconciliation.plan`),
/// the one reconcile CSV import and Bank Sync share (main-to-dev D4).
///
/// Phase 3.1 replayed every case of the CSV-only matcher through the shared
/// reconciler and found it agreed row for row, apart from the divergences below
/// (each right by upstream: pinned Actual v26.9.0,
/// `packages/loot-core/src/server/accounts/sync.ts`). Phase 3.5 deleted that
/// matcher; the cases it was replayed with stay here with their expected
/// outcomes.
///
/// Divergences from the deleted matcher (shared reconciler = upstream; the
/// matcher had no upstream source for its behavior):
/// - multi-pass: `matchTransactions` runs every exact-id match, then every
///   same-payee match, then every nearest match (sync.ts ~845-990). The CSV
///   matcher decided one row at a time, so an earlier row's lowest-fidelity
///   match could take a row a later row matches with higher fidelity.
/// - the exact imported_id match is `SELECT ... WHERE imported_id = ?` with no
///   claim check (sync.ts ~850), so it is not blocked by an earlier row's
///   fuzzy claim, and two rows sharing an id both match the stored row.
/// - a stored NULL `cleared` is `false` (`match.cleared === 1`, sync.ts ~700);
///   the matcher treated NULL as "never changes" (store-level test in
///   `TransactionCSVImportSharedStepTests`).
/// - an empty stored `notes` is falsy and equal to null in the change check
///   (`existing.notes || trans.notes || null`); the matcher reported a no-op
///   update.
/// - split children are matchable like any `v_transactions` row; the matcher
///   excluded them (`TransactionCSVImportStoreRulesTests`).
/// Option-gated divergences (ImportReconcileOptions): `strictIdChecking`
/// (sync.ts ~866 `(imported_id IS NULL OR ? IS NULL)`), `isBankSyncAccount`,
/// `reimportDeleted`, `defaultCleared` and `payeeNameNormalization`
/// (title case, sync.ts ~440-481).
struct ImportReconcileEquivalenceTests {
    // MARK: - Fixtures

    static let lookup = TransactionCSVImportLookup(
        payeeIDByName: [
            "sample market": "payee-a", "other market": "payee-b", "to savings": "payee-transfer",
            "alpha": "p-alpha", "beta": "p-beta", "gamma": "p-gamma",
        ],
        transferPayeeIDs: ["payee-transfer", "p-transfer"],
        categoryIDByName: ["groceries": "cat-groceries", "dining": "cat-dining"]
    )

    /// CSV defaults with the name spelling untouched: title case is checked
    /// on its own, so this isolates the matching behavior.
    static var parity: ImportReconcileOptions {
        var options = ImportReconcileOptions.csv
        options.payeeNameNormalization = .original
        return options
    }

    /// Fields a matched row would change; nil leaves the stored value.
    struct Fill: Equatable {
        var payeeID: String?
        var categoryID: String?
        var notes: String?
        var cleared: Bool?
        var importedPayee: String?
        var importedID: String?
    }

    enum Outcome: Equatable {
        case insert(isTransfer: Bool)
        case update(id: String?, Fill)
        case unchanged
        case reconciled
    }

    private func existing(
        id: String,
        importedID: String? = nil,
        payeeID: String? = "payee-a",
        categoryID: String? = nil,
        notes: String? = nil,
        cleared: Bool = false,
        importedPayee: String? = nil,
        amount: Int = 1_234,
        date: String = "2026-09-27",
        reconciled: Bool = false,
        isParent: Bool = false,
        transferID: String? = nil
    ) -> BankSyncReconciliation.Existing {
        BankSyncReconciliation.Existing(
            id: id,
            financialID: importedID,
            dayID: date.replacingOccurrences(of: "-", with: ""),
            amountMinorUnits: amount,
            payeeID: payeeID,
            // `bankSyncExistingRows` reads a split parent's category as nil.
            categoryID: isParent ? nil : categoryID,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            importedPayee: importedPayee,
            isParent: isParent,
            isChild: false,
            parentID: nil,
            transferID: transferID
        )
    }

    private func row(
        _ id: String,
        payee: String = "Sample Market",
        amount: Int = 1_234,
        date: String = "2026-09-27",
        importedID: String? = nil,
        notes: String? = nil,
        category: String? = nil,
        cleared: Bool? = nil
    ) -> TransactionCSVImportRow {
        TransactionCSVImportRow(
            id: id, sourceLine: 1, dateText: date,
            date: TransactionCSVImportMapper.dayDate(fromISO: date) ?? Date(timeIntervalSince1970: 0),
            amountMinorUnits: amount, payeeName: payee, notes: notes, categoryName: category,
            cleared: cleared, importedID: importedID
        )
    }

    // MARK: - The shared reconciler

    static func shared(
        _ rows: [TransactionCSVImportRow],
        _ existing: [BankSyncReconciliation.Existing],
        offBudget: Bool = false,
        options: ImportReconcileOptions = parity
    ) -> [Outcome] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let plan = BankSyncReconciliation.plan(
            candidates: TransactionCSVImportCandidates.candidates(rows: rows, lookup: lookup, options: options),
            existing: existing,
            accountIsOffBudget: offBudget,
            transferPayeeIDs: lookup.transferPayeeIDs,
            options: options
        )
        var outcomes = [Outcome?](repeating: nil, count: rows.count)
        for (entry, source) in zip(plan.entries, plan.sources) {
            switch entry {
            case .insert(let candidate):
                outcomes[source] = .insert(isTransfer: candidate.payeeID.map(lookup.transferPayeeIDs.contains) ?? false)
            case .update(let update):
                let stored = existingByID[update.existingID]
                outcomes[source] = .update(id: update.existingID, Fill(
                    payeeID: update.payeeID != stored?.payeeID ? update.payeeID : nil,
                    categoryID: update.categoryID != stored?.categoryID ? update.categoryID : nil,
                    notes: update.notes != stored?.notes ? update.notes : nil,
                    cleared: update.cleared != stored?.cleared ? update.cleared : nil,
                    importedPayee: update.importedPayee != stored?.importedPayee ? update.importedPayee : nil,
                    importedID: update.financialID != stored?.financialID ? update.financialID : nil
                ))
            case .unchanged(let id):
                outcomes[source] = existingByID[id]?.reconciled == true ? .reconciled : .unchanged
            case .skippedDeleted:
                Issue.record("CSV never suppresses a deleted id")
            }
        }
        return outcomes.compactMap { $0 }
    }

    private func expectOutcomes(
        _ rows: [TransactionCSVImportRow],
        _ stored: [BankSyncReconciliation.Existing],
        offBudget: Bool = false,
        _ expected: [Outcome],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(Self.shared(rows, stored, offBudget: offBudget) == expected, sourceLocation: sourceLocation)
    }

    private func fill(
        payee: String? = nil, category: String? = nil, notes: String? = nil,
        cleared: Bool? = nil, importedPayee: String? = nil, importedID: String? = nil
    ) -> Fill {
        Fill(payeeID: payee, categoryID: category, notes: notes, cleared: cleared,
             importedPayee: importedPayee, importedID: importedID)
    }

    // MARK: - TransactionCSVImportTests matcher cases

    @Test func exactImportedIDMatchesBeforeFuzzyTiers() {
        expectOutcomes(
            [row("r1", importedID: "bank-1")],
            [existing(id: "e1", importedID: "bank-1", importedPayee: "Sample Market")],
            [.unchanged]
        )
    }

    @Test func fuzzySamePayeeMatchesInsideSevenDayWindow() {
        expectOutcomes(
            [row("r1", date: "2026-09-27")],
            [existing(id: "e1", importedPayee: "Sample Market", date: "2026-09-20")],
            [.unchanged]
        )
    }

    @Test func fuzzyWindowRejectsEightDays() {
        expectOutcomes(
            [row("r1", date: "2026-09-27")],
            [existing(id: "e1", date: "2026-09-19")],
            [.insert(isTransfer: false)]
        )
    }

    @Test func lowestFidelityTierMatchesAmountAndDateDespiteDifferentPayee() {
        expectOutcomes(
            [row("r1", payee: "Different Payee", amount: -1_999, date: "2026-09-05")],
            [existing(id: "e1", importedPayee: "Fuzzy Market", amount: -1_999, date: "2026-09-02")],
            [.update(id: "e1", fill(importedPayee: "Different Payee"))]
        )
    }

    @Test func strictIDCheckingSkipsFuzzyAgainstCandidatesWithImportedID() {
        expectOutcomes(
            [row("r1", payee: "Other Market", importedID: "bank-2")],
            [
                existing(id: "e1", importedID: "bank-1"),
                existing(id: "e2", payeeID: "payee-b"),
            ],
            [.update(id: "e2", fill(importedPayee: "Other Market", importedID: "bank-2"))]
        )
    }

    @Test func oneExistingRowIsClaimedAtMostOncePerBatch() {
        expectOutcomes(
            [row("r1"), row("r2")],
            [existing(id: "e1", importedPayee: "Sample Market")],
            [.unchanged, .insert(isTransfer: false)]
        )
    }

    @Test func identicalRowsWithNoCandidateBothInsert() {
        expectOutcomes([row("r1"), row("r2")], [], [.insert(isTransfer: false), .insert(isTransfer: false)])
    }

    @Test func reconciledMatchIsSkippedEntirely() {
        expectOutcomes([row("r1")], [existing(id: "e1", reconciled: true)], [.reconciled])
    }

    @Test func transferPayeeRowsInsertAsTransfers() {
        expectOutcomes(
            [row("r1", payee: "To Savings", amount: -5_000, date: "2026-09-10")],
            [],
            [.insert(isTransfer: true)]
        )
    }

    // MARK: - TransactionCSVImportMatcherRulesTests

    @Test func ordinaryUncategorizedMatchStillTakesTheFileCategory() {
        expectOutcomes(
            [row("r1", amount: -1_234, category: "Groceries")],
            [existing(id: "e1", importedPayee: "Sample Market", amount: -1_234)],
            [.update(id: "e1", fill(category: "cat-groceries"))]
        )
    }

    @Test func transferLegGetsNoCategoryWrite() {
        expectOutcomes(
            [row("r1", amount: -1_234, category: "Groceries")],
            [existing(id: "e1", importedPayee: "Sample Market", amount: -1_234, transferID: "other-leg")],
            [.unchanged]
        )
    }

    @Test func splitParentGetsNoCategoryWrite() {
        expectOutcomes(
            [row("r1", amount: -1_234, category: "Groceries")],
            [existing(id: "e1", importedPayee: "Sample Market", amount: -1_234, isParent: true)],
            [.unchanged]
        )
    }

    @Test func offBudgetMatchGetsNoCategoryWrite() {
        expectOutcomes(
            [row("r1", amount: -1_234, category: "Groceries")],
            [existing(id: "e1", importedPayee: "Sample Market", amount: -1_234)],
            offBudget: true,
            [.unchanged]
        )
    }

    @Test func nilPayeeIsNotFilledWithATransferPayee() {
        expectOutcomes(
            [row("r1", payee: "To Savings", amount: -1_234)],
            [existing(id: "e1", payeeID: nil, importedPayee: "Sample Market", amount: -1_234)],
            [.update(id: "e1", fill(importedPayee: "To Savings"))]
        )
    }

    @Test func nilPayeeStillTakesAnOrdinaryPayee() {
        expectOutcomes(
            [row("r1", amount: -1_234)],
            [existing(id: "e1", payeeID: nil, importedPayee: "Sample Market", amount: -1_234)],
            [.update(id: "e1", fill(payee: "payee-a"))]
        )
    }

    @Test func transferLegWithNoPayeeKeepsItNil() {
        expectOutcomes(
            [row("r1", amount: -1_234)],
            [existing(id: "e1", payeeID: nil, importedPayee: nil, amount: -1_234, transferID: "other-leg")],
            [.update(id: "e1", fill(importedPayee: "Sample Market"))]
        )
    }

    @Test func importedIDMatchingIsCaseSensitive() {
        let stored = existing(id: "e1", importedID: "a1", importedPayee: "Sample Market", amount: -1_234)
        // Both rows carry an id, so strict checking also blocks the fuzzy
        // tiers: "A1" does not match "a1" at all (sync.ts `imported_id = ?`).
        expectOutcomes([row("r1", amount: -1_234, importedID: "A1")], [stored], [.insert(isTransfer: false)])
        expectOutcomes([row("r2", amount: -1_234, importedID: "a1")], [stored], [.unchanged])
    }

    // MARK: - Named divergences (shared reconciler = upstream)

    private func ids(_ outcomes: [Outcome]) -> [String?] {
        outcomes.map { if case .update(let id, _) = $0 { id } else { nil } }
    }

    @Test func divergenceMultiPassSamePayeeBeatsAnEarlierRowsNearestMatch() {
        let stored = [
            existing(id: "e1", importedPayee: "Sample Market"),
            existing(id: "e2", payeeID: "payee-b", importedPayee: "Sample Market"),
        ]
        let rows = [
            row("r1", payee: "Unknown Payee", notes: "n1"),
            row("r2", payee: "Sample Market", notes: "n2"),
        ]
        // The deleted matcher decided one row at a time: r1 took e1 by amount
        // and date, so r2 lost its same-payee match and took e2.
        // Upstream: all same-payee matches run before any nearest match.
        let new = Self.shared(rows, stored)
        #expect(ids(new) == ["e2", "e1"])
        #expect(new[1] == .update(id: "e1", fill(notes: "n2")))
    }

    @Test func divergenceExactIDMatchRunsBeforeAnyFuzzyClaim() {
        let stored = [existing(id: "e1", importedID: "bank-1", importedPayee: "Sample Market")]
        let rows = [row("r1", notes: "n1"), row("r2", importedID: "bank-1", notes: "n2")]
        // The deleted matcher let r1 claim e1 first, so r2's exact id found nothing.
        // Upstream: step 1 matches r2 to e1 before r1's fuzzy pass.
        #expect(Self.shared(rows, stored) == [
            .insert(isTransfer: false),
            .update(id: "e1", fill(notes: "n2")),
        ])
    }

    @Test func divergenceTwoRowsWithTheSameImportedIDBothMatchTheStoredRow() {
        let stored = [existing(id: "e1", importedID: "bank-1", importedPayee: "Sample Market")]
        let rows = [row("r1", importedID: "bank-1", notes: "n1"), row("r2", importedID: "bank-1", notes: "n2")]
        // The deleted matcher inserted the second row.
        #expect(Self.shared(rows, stored) == [
            .update(id: "e1", fill(notes: "n1")),
            .update(id: "e1", fill(notes: "n2")),
        ])
    }

    @Test func divergenceEmptyStoredNotesAreNoChange() {
        let stored = [existing(id: "e1", notes: "", importedPayee: "Sample Market")]
        let rows = [row("r1")]
        // The deleted matcher reported a no-op update here.
        #expect(Self.shared(rows, stored) == [.unchanged])
    }

    // MARK: - Option-gated divergences

    @Test func strictIdCheckingIsAnOption() {
        let stored = [existing(id: "e1", importedID: "bank-1", importedPayee: "Sample Market")]
        let rows = [row("r1", importedID: "bank-2")]
        #expect(Self.shared(rows, stored, options: Self.parity) == [.insert(isTransfer: false)])
        // Bank Sync's shipped profile is not strict: the fuzzy tier matches and
        // the stored id is replaced by the incoming one.
        var lenient = Self.parity
        lenient.strictIdChecking = false
        #expect(Self.shared(rows, stored, options: lenient) == [.update(id: "e1", fill(importedID: "bank-2"))])
    }

    @Test func aRowWithoutAnIdPlansAnUpdateThatClearsTheStoredIdentity() {
        let stored = [existing(id: "e1", importedID: "bank-1", importedPayee: "Bank Text")]
        let rows = [row("r1", payee: "")]
        // Upstream writes `imported_id: x || null` on every matched update;
        // the planner carries the absence and the apply decides (`isBankSyncAccount`).
        #expect(Self.shared(rows, stored, options: Self.parity) == [.update(id: "e1", fill())])
        var bank = Self.parity
        bank.isBankSyncAccount = true
        #expect(Self.shared(rows, stored, options: bank) == [.update(id: "e1", fill())])
    }

    @Test func defaultClearedAppliesOnlyWhenTheRowDoesNotSay() {
        let unspecified = TransactionCSVImportCandidates.candidate(
            for: row("r1"), lookup: Self.lookup, options: .csv
        )
        #expect(!unspecified.clearedIsExplicit)
        #expect(!unspecified.cleared)
        let explicit = TransactionCSVImportCandidates.candidate(
            for: row("r2", cleared: false), lookup: Self.lookup, options: .csv
        )
        #expect(explicit.clearedIsExplicit)
        #expect(!explicit.cleared)
    }

    @Test func csvMappingTitleCasesNewPayeesAndKeepsIsoDaysAsDayIDs() {
        let candidate = TransactionCSVImportCandidates.candidate(
            for: row("r1", payee: "NEW CORNER STORE", date: "2026-01-31", importedID: "ID-1"),
            lookup: Self.lookup,
            options: .csv
        )
        #expect(candidate.payeeName == "New Corner Store")
        #expect(candidate.importedPayee == "New Corner Store")
        #expect(candidate.payeeID == nil)
        #expect(candidate.dayID == "20260131")
        #expect(candidate.financialID == "ID-1")
        // An existing payee resolves by name, whatever the file's casing.
        let known = TransactionCSVImportCandidates.candidate(
            for: row("r2", payee: "SAMPLE MARKET"), lookup: Self.lookup, options: .csv
        )
        #expect(known.payeeID == "payee-a")
    }

    @Test func plansMapEntriesBackToTheirCandidates() {
        let options = Self.parity
        let rows = [row("r1", amount: 999), row("r2"), row("r3", amount: 55)]
        let plan = BankSyncReconciliation.plan(
            candidates: TransactionCSVImportCandidates.candidates(rows: rows, lookup: Self.lookup, options: options),
            existing: [existing(id: "e1", importedPayee: "Sample Market")],
            suppressedFinancialIDs: [],
            transferPayeeIDs: Self.lookup.transferPayeeIDs,
            options: options
        )
        #expect(plan.entries.count == 3)
        #expect(Set(plan.sources) == [0, 1, 2])
        let matched = zip(plan.entries, plan.sources).first { entry, _ in
            if case .unchanged = entry { return true }
            return false
        }
        #expect(matched?.1 == 1)
    }

    // MARK: - Randomized invariants

    private static func dayText(_ offset: Int) -> String {
        ActualScheduleRecurrence.dayID(from: Date(timeIntervalSince1970: Double(19_900 + offset) * 86_400))
    }

    /// The randomized fixture of the deleted matcher's equivalence suite,
    /// narrowed to what a stored row can hold (no empty-string ids). The account
    /// is on or off budget as a whole, as in the app.
    private static func fixture(seed: UInt64, rowCount: Int, existingCount: Int)
        -> (rows: [TransactionCSVImportRow], existing: [BankSyncReconciliation.Existing]) {
        var rng = SplitMix64(seed: seed)
        func pick<T>(_ values: [T]) -> T { values[Int.random(in: 0..<values.count, using: &rng)] }
        let amounts = [-1_234, -500, -500, 999, 0, 12_000]
        let payees = ["p-alpha", "p-beta", "p-gamma", "p-transfer", nil]
        let existing = (0..<existingCount).map { index -> BankSyncReconciliation.Existing in
            let day = Int.random(in: 0..<60, using: &rng)
            let broken = Int.random(in: 0..<25, using: &rng) == 0
            let isParent = Int.random(in: 0..<10, using: &rng) == 0
            return BankSyncReconciliation.Existing(
                id: "c-\(index)",
                financialID: Int.random(in: 0..<4, using: &rng) == 0 ? "imp-\(Int.random(in: 0..<6, using: &rng))" : nil,
                dayID: (broken ? pick(["20260230", "garbage", "", "2026105"]) : dayText(day))
                    .replacingOccurrences(of: "-", with: ""),
                amountMinorUnits: pick(amounts),
                payeeID: pick(payees),
                categoryID: isParent ? nil : pick([nil, "cat-groceries"]),
                notes: pick([nil, "note"]),
                cleared: pick([true, false]),
                reconciled: Int.random(in: 0..<8, using: &rng) == 0,
                importedPayee: pick([nil, "Alpha", "Beta"]),
                isParent: isParent,
                isChild: false,
                parentID: nil,
                transferID: Int.random(in: 0..<10, using: &rng) == 0 ? "xfer" : nil
            )
        }
        let rows = (0..<rowCount).map { index in
            let day = Int.random(in: -4..<66, using: &rng)
            return TransactionCSVImportRow(
                id: "r-\(index)",
                sourceLine: index + 1,
                dateText: dayText(day),
                date: Date(timeIntervalSince1970: Double(19_900 + day) * 86_400 + 43_200),
                amountMinorUnits: pick(amounts),
                payeeName: pick(["Alpha", "BETA", "Gamma", "To Savings", "Unknown", ""]),
                notes: pick([nil, "note", "other"]),
                categoryName: pick([nil, "Groceries", "Dining", "Nope"]),
                cleared: pick([nil, true, false]),
                importedID: Int.random(in: 0..<5, using: &rng) == 0 ? "imp-\(Int.random(in: 0..<7, using: &rng))" : nil
            )
        }
        return (rows, existing)
    }

    /// One row at a time there is nothing to claim, so each outcome must
    /// follow the tier order, the seven-day window, strict id checking and the
    /// fill rules (transfer, split and off-budget guards, reconciled lock).
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func everyRandomRowHonorsTheMatchingInvariants(seed: UInt64) {
        let offBudget = seed.isMultiple(of: 2)
        let data = Self.fixture(seed: seed, rowCount: 120, existingCount: 300)
        let byID = Dictionary(uniqueKeysWithValues: data.existing.map { ($0.id, $0) })
        var kinds: Set<String> = []
        for row in data.rows {
            let outcome = Self.shared([row], data.existing, offBudget: offBudget)[0]
            let rowDay = row.dateText.replacingOccurrences(of: "-", with: "")
            let exact = row.importedID.flatMap { id in data.existing.first { $0.financialID == id } }
            let eligible = data.existing.contains { stored in
                stored.amountMinorUnits == row.amountMinorUnits
                    && BankSyncReconciliation.dayDistance(stored.dayID, rowDay) <= 7
                    && !(row.importedID != nil && stored.financialID != nil)
            }
            switch outcome {
            case .insert:
                kinds.insert("insert")
                // An insert means no exact id and no eligible same-amount row in the window.
                #expect(exact == nil && !eligible, "seed \(seed) row \(row.id)")
            case .update(let id, let fill):
                kinds.insert("update")
                let stored = id.flatMap { byID[$0] }
                #expect(stored != nil && stored?.reconciled == false, "seed \(seed) row \(row.id)")
                if let stored {
                    // Guards: a transfer leg, split parent or off-budget row never takes a category;
                    // a transfer payee never lands on a non-transfer row; a stored payee is kept.
                    if stored.isTransfer || stored.isParent || offBudget {
                        #expect(fill.categoryID == nil, "seed \(seed) row \(row.id)")
                    }
                    if let payee = fill.payeeID {
                        #expect(stored.payeeID == nil && !stored.isTransfer
                            && !Self.lookup.transferPayeeIDs.contains(payee), "seed \(seed) row \(row.id)")
                    }
                    #expect(fill.categoryID == nil || stored.categoryID == nil, "seed \(seed) row \(row.id)")
                    #expect(fill.notes == nil || stored.notes == nil, "seed \(seed) row \(row.id)")
                }
            case .unchanged:
                kinds.insert("unchanged")
                #expect(exact != nil || eligible, "seed \(seed) row \(row.id)")
            case .reconciled:
                kinds.insert("reconciled")
                #expect(exact != nil || eligible, "seed \(seed) row \(row.id)")
            }
        }
        #expect(kinds.isSuperset(of: ["update", "unchanged", "reconciled"]), "seed \(seed) \(kinds)")
    }
}
