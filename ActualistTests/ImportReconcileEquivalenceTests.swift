import Foundation
import Testing
@testable import Actualist

/// Main-to-dev Phase 3.1: every case of the CSV-only matcher
/// (`TransactionCSVImportMatcherRulesTests`, `...MatcherEquivalenceTests` and
/// the matcher cases of `TransactionCSVImportTests`) replayed through the
/// shared reconciler (`BankSyncReconciliation.plan`) that Bank Sync uses.
///
/// Both sides run in-process. A case either produces the same outcome on both,
/// or it is one of the named divergences below, each with the upstream source
/// that makes the shared reconciler right (pinned Actual v26.9.0,
/// `packages/loot-core/src/server/accounts/sync.ts`).
///
/// Divergences (shared = upstream; the CSV-only matcher had no upstream source):
/// - multi-pass: `matchTransactions` runs every exact-id match, then every
///   same-payee match, then every nearest match (sync.ts ~845-990). The CSV
///   matcher decided one row at a time, so an earlier row's lowest-fidelity
///   match could take a row a later row matches with higher fidelity.
/// - the exact imported_id match is `SELECT ... WHERE imported_id = ?` with no
///   claim check (sync.ts ~850), so it is not blocked by an earlier row's
///   fuzzy claim, and two rows sharing an id both match the stored row.
/// - a stored NULL `cleared` is `false` (`match.cleared === 1`, sync.ts ~700);
///   the CSV matcher treated NULL as "never changes".
/// - an empty stored `notes` is falsy and equal to null in the change check
///   (`existing.notes || trans.notes || null`); the CSV matcher reported a
///   no-op update.
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

    private static var legacyContext: TransactionCSVImportMatchContext {
        TransactionCSVImportMatchContext(
            payeeIDByName: lookup.payeeIDByName,
            transferPayeeIDs: lookup.transferPayeeIDs,
            categoryIDByName: lookup.categoryIDByName
        )
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
        cleared: Bool? = false,
        importedPayee: String? = nil,
        amount: Int = 1_234,
        date: String = "2026-09-27",
        reconciled: Bool = false,
        isParent: Bool = false,
        transferID: String? = nil,
        offBudget: Bool = false
    ) -> TransactionCSVImportCandidate {
        TransactionCSVImportCandidate(
            id: id, importedID: importedID, payeeID: payeeID, categoryID: categoryID, notes: notes,
            cleared: cleared, importedPayee: importedPayee, amountMinorUnits: amount, dateText: date,
            reconciled: reconciled, isParent: isParent, transferID: transferID, accountOffBudget: offBudget
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

    // MARK: - The two sides

    private static func legacy(
        _ rows: [TransactionCSVImportRow],
        _ candidates: [TransactionCSVImportCandidate]
    ) -> [Outcome] {
        TransactionCSVImportMatcher.match(rows: rows, candidates: candidates, context: legacyContext).map {
            switch $0 {
            case .insert(let isTransfer): .insert(isTransfer: isTransfer)
            case .update(let plan):
                .update(id: plan.existingTransactionID, Fill(
                    payeeID: plan.payeeID, categoryID: plan.categoryID, notes: plan.notes,
                    cleared: plan.cleared, importedPayee: plan.importedPayee, importedID: plan.importedID
                ))
            case .ignored: .unchanged
            case .skippedReconciled: .reconciled
            }
        }
    }

    private static func sharedExisting(_ candidate: TransactionCSVImportCandidate) -> BankSyncReconciliation.Existing {
        BankSyncReconciliation.Existing(
            id: candidate.id,
            financialID: candidate.importedID,
            dayID: candidate.dateText.replacingOccurrences(of: "-", with: ""),
            amountMinorUnits: candidate.amountMinorUnits,
            payeeID: candidate.payeeID,
            // `bankSyncExistingRows` reads a split parent's category as nil.
            categoryID: candidate.isParent ? nil : candidate.categoryID,
            notes: candidate.notes,
            cleared: candidate.cleared ?? false,
            reconciled: candidate.reconciled,
            importedPayee: candidate.importedPayee,
            isParent: candidate.isParent,
            isChild: false,
            parentID: nil,
            transferID: candidate.transferID
        )
    }

    static func shared(
        _ rows: [TransactionCSVImportRow],
        _ candidates: [TransactionCSVImportCandidate],
        offBudget: Bool = false,
        options: ImportReconcileOptions = parity
    ) -> [Outcome] {
        let existing = candidates.map(sharedExisting)
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

    /// Asserts the CSV-only matcher and the shared reconciler agree on `expected`.
    private func expectSame(
        _ rows: [TransactionCSVImportRow],
        _ candidates: [TransactionCSVImportCandidate],
        offBudget: Bool = false,
        _ expected: [Outcome],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let old = Self.legacy(rows, candidates.map { $0.withOffBudget(offBudget) })
        let new = Self.shared(rows, candidates, offBudget: offBudget)
        #expect(old == expected, "legacy matcher", sourceLocation: sourceLocation)
        #expect(new == expected, "shared reconciler", sourceLocation: sourceLocation)
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
        expectSame(
            [row("r1", importedID: "bank-1")],
            [existing(id: "e1", importedID: "bank-1", importedPayee: "Sample Market")],
            [.unchanged]
        )
    }

    @Test func fuzzySamePayeeMatchesInsideSevenDayWindow() {
        expectSame(
            [row("r1", date: "2026-09-27")],
            [existing(id: "e1", importedPayee: "Sample Market", date: "2026-09-20")],
            [.unchanged]
        )
    }

    @Test func fuzzyWindowRejectsEightDays() {
        expectSame(
            [row("r1", date: "2026-09-27")],
            [existing(id: "e1", date: "2026-09-19")],
            [.insert(isTransfer: false)]
        )
    }

    @Test func lowestFidelityTierMatchesAmountAndDateDespiteDifferentPayee() {
        expectSame(
            [row("r1", payee: "Different Payee", amount: -1_999, date: "2026-09-05")],
            [existing(id: "e1", importedPayee: "Fuzzy Market", amount: -1_999, date: "2026-09-02")],
            [.update(id: "e1", fill(importedPayee: "Different Payee"))]
        )
    }

    @Test func strictIDCheckingSkipsFuzzyAgainstCandidatesWithImportedID() {
        expectSame(
            [row("r1", payee: "Other Market", importedID: "bank-2")],
            [
                existing(id: "e1", importedID: "bank-1"),
                existing(id: "e2", payeeID: "payee-b"),
            ],
            [.update(id: "e2", fill(importedPayee: "Other Market", importedID: "bank-2"))]
        )
    }

    @Test func oneExistingRowIsClaimedAtMostOncePerBatch() {
        expectSame(
            [row("r1"), row("r2")],
            [existing(id: "e1", importedPayee: "Sample Market")],
            [.unchanged, .insert(isTransfer: false)]
        )
    }

    @Test func identicalRowsWithNoCandidateBothInsert() {
        expectSame([row("r1"), row("r2")], [], [.insert(isTransfer: false), .insert(isTransfer: false)])
    }

    @Test func reconciledMatchIsSkippedEntirely() {
        expectSame([row("r1")], [existing(id: "e1", reconciled: true)], [.reconciled])
    }

    @Test func transferPayeeRowsInsertAsTransfers() {
        expectSame(
            [row("r1", payee: "To Savings", amount: -5_000, date: "2026-09-10")],
            [],
            [.insert(isTransfer: true)]
        )
    }

    // MARK: - TransactionCSVImportMatcherRulesTests

    @Test func ordinaryUncategorizedMatchStillTakesTheFileCategory() {
        expectSame(
            [row("r1", amount: -1_234, category: "Groceries")],
            [existing(id: "e1", importedPayee: "Sample Market", amount: -1_234)],
            [.update(id: "e1", fill(category: "cat-groceries"))]
        )
    }

    @Test func transferLegGetsNoCategoryWrite() {
        expectSame(
            [row("r1", amount: -1_234, category: "Groceries")],
            [existing(id: "e1", importedPayee: "Sample Market", amount: -1_234, transferID: "other-leg")],
            [.unchanged]
        )
    }

    @Test func splitParentGetsNoCategoryWrite() {
        expectSame(
            [row("r1", amount: -1_234, category: "Groceries")],
            [existing(id: "e1", importedPayee: "Sample Market", amount: -1_234, isParent: true)],
            [.unchanged]
        )
    }

    @Test func offBudgetMatchGetsNoCategoryWrite() {
        expectSame(
            [row("r1", amount: -1_234, category: "Groceries")],
            [existing(id: "e1", importedPayee: "Sample Market", amount: -1_234, offBudget: true)],
            offBudget: true,
            [.unchanged]
        )
    }

    @Test func nilPayeeIsNotFilledWithATransferPayee() {
        expectSame(
            [row("r1", payee: "To Savings", amount: -1_234)],
            [existing(id: "e1", payeeID: nil, importedPayee: "Sample Market", amount: -1_234)],
            [.update(id: "e1", fill(importedPayee: "To Savings"))]
        )
    }

    @Test func nilPayeeStillTakesAnOrdinaryPayee() {
        expectSame(
            [row("r1", amount: -1_234)],
            [existing(id: "e1", payeeID: nil, importedPayee: "Sample Market", amount: -1_234)],
            [.update(id: "e1", fill(payee: "payee-a"))]
        )
    }

    @Test func transferLegWithNoPayeeKeepsItNil() {
        expectSame(
            [row("r1", amount: -1_234)],
            [existing(id: "e1", payeeID: nil, importedPayee: nil, amount: -1_234, transferID: "other-leg")],
            [.update(id: "e1", fill(importedPayee: "Sample Market"))]
        )
    }

    @Test func importedIDMatchingIsCaseSensitive() {
        let stored = existing(id: "e1", importedID: "a1", importedPayee: "Sample Market", amount: -1_234)
        // Both rows carry an id, so strict checking also blocks the fuzzy
        // tiers: "A1" does not match "a1" at all (sync.ts `imported_id = ?`).
        expectSame([row("r1", amount: -1_234, importedID: "A1")], [stored], [.insert(isTransfer: false)])
        expectSame([row("r2", amount: -1_234, importedID: "a1")], [stored], [.unchanged])
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
        // Legacy, one row at a time: r1 takes e1 by amount and date, so r2
        // loses its same-payee match and takes e2.
        #expect(ids(Self.legacy(rows, stored)) == ["e1", "e2"])
        // Upstream: all same-payee matches run before any nearest match.
        let new = Self.shared(rows, stored)
        #expect(ids(new) == ["e2", "e1"])
        #expect(new[1] == .update(id: "e1", fill(notes: "n2")))
    }

    @Test func divergenceExactIDMatchRunsBeforeAnyFuzzyClaim() {
        let stored = [existing(id: "e1", importedID: "bank-1", importedPayee: "Sample Market")]
        let rows = [row("r1", notes: "n1"), row("r2", importedID: "bank-1", notes: "n2")]
        // Legacy: r1 claims e1 first, so r2's exact id finds nothing.
        #expect(Self.legacy(rows, stored) == [
            .update(id: "e1", fill(notes: "n1")),
            .insert(isTransfer: false),
        ])
        // Upstream: step 1 matches r2 to e1 before r1's fuzzy pass.
        #expect(Self.shared(rows, stored) == [
            .insert(isTransfer: false),
            .update(id: "e1", fill(notes: "n2")),
        ])
    }

    @Test func divergenceTwoRowsWithTheSameImportedIDBothMatchTheStoredRow() {
        let stored = [existing(id: "e1", importedID: "bank-1", importedPayee: "Sample Market")]
        let rows = [row("r1", importedID: "bank-1", notes: "n1"), row("r2", importedID: "bank-1", notes: "n2")]
        #expect(Self.legacy(rows, stored) == [
            .update(id: "e1", fill(notes: "n1")),
            .insert(isTransfer: false),
        ])
        #expect(Self.shared(rows, stored) == [
            .update(id: "e1", fill(notes: "n1")),
            .update(id: "e1", fill(notes: "n2")),
        ])
    }

    @Test func divergenceStoredNullClearedIsNotCleared() {
        let stored = [existing(id: "e1", cleared: nil, importedPayee: "Sample Market")]
        let rows = [row("r1", cleared: true)]
        #expect(Self.legacy(rows, stored) == [.unchanged])
        #expect(Self.shared(rows, stored) == [.update(id: "e1", fill(cleared: true))])
    }

    @Test func divergenceEmptyStoredNotesAreNoChange() {
        let stored = [existing(id: "e1", notes: "", importedPayee: "Sample Market")]
        let rows = [row("r1")]
        #expect(Self.legacy(rows, stored) == [.update(id: "e1", fill())])
        #expect(Self.shared(rows, stored) == [.unchanged])
    }

    // MARK: - Option-gated divergences

    @Test func strictIdCheckingIsAnOption() {
        let stored = [existing(id: "e1", importedID: "bank-1", importedPayee: "Sample Market")]
        let rows = [row("r1", importedID: "bank-2")]
        #expect(Self.legacy(rows, stored) == [.insert(isTransfer: false)])
        #expect(Self.shared(rows, stored, options: Self.parity) == [.insert(isTransfer: false)])
        // Bank Sync's shipped profile is not strict: the fuzzy tier matches and
        // the stored id is replaced by the incoming one.
        var lenient = Self.parity
        lenient.strictIdChecking = false
        #expect(Self.shared(rows, stored, options: lenient) == [.update(id: "e1", fill(importedID: "bank-2"))])
    }

    @Test func aRowWithoutAnIdKeepsTheStoredIdentityUnlessItIsABankSyncAccount() {
        let stored = [existing(id: "e1", importedID: "bank-1", importedPayee: "Bank Text")]
        let rows = [row("r1", payee: "")]
        #expect(Self.legacy(rows, stored) == [.unchanged])
        #expect(Self.shared(rows, stored, options: Self.parity) == [.unchanged])
        // Upstream would write null over both; `isBankSyncAccount` keeps that
        // reading for the one caller whose rows always carry both.
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
            existing: [Self.sharedExisting(existing(id: "e1", importedPayee: "Sample Market"))],
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

    // MARK: - Single-row replay of the legacy equivalence fixtures

    private static func dayText(_ offset: Int) -> String {
        ActualScheduleRecurrence.dayID(from: Date(timeIntervalSince1970: Double(19_900 + offset) * 86_400))
    }

    /// The randomized fixture of `TransactionCSVImportMatcherEquivalenceTests`,
    /// narrowed to what a stored row can hold (no empty-string ids, a non-null
    /// cleared). The account is on or off budget as a whole, as in the app.
    private static func fixture(seed: UInt64, rowCount: Int, candidateCount: Int, offBudget: Bool)
        -> (rows: [TransactionCSVImportRow], candidates: [TransactionCSVImportCandidate]) {
        var rng = SplitMix64(seed: seed)
        func pick<T>(_ values: [T]) -> T { values[Int.random(in: 0..<values.count, using: &rng)] }
        let amounts = [-1_234, -500, -500, 999, 0, 12_000]
        let payees = ["p-alpha", "p-beta", "p-gamma", "p-transfer", nil]
        let candidates = (0..<candidateCount).map { index in
            let day = Int.random(in: 0..<60, using: &rng)
            let broken = Int.random(in: 0..<25, using: &rng) == 0
            return TransactionCSVImportCandidate(
                id: "c-\(index)",
                importedID: Int.random(in: 0..<4, using: &rng) == 0 ? "imp-\(Int.random(in: 0..<6, using: &rng))" : nil,
                payeeID: pick(payees),
                categoryID: pick([nil, "cat-groceries"]),
                notes: pick([nil, "note"]),
                cleared: pick([true, false]),
                importedPayee: pick([nil, "Alpha", "Beta"]),
                amountMinorUnits: pick(amounts),
                dateText: broken ? pick(["2026-02-30", "garbage", "", "2026-1-05"]) : dayText(day),
                reconciled: Int.random(in: 0..<8, using: &rng) == 0,
                isParent: Int.random(in: 0..<10, using: &rng) == 0,
                transferID: Int.random(in: 0..<10, using: &rng) == 0 ? "xfer" : nil,
                accountOffBudget: offBudget
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
        return (rows, candidates)
    }

    /// One row at a time there is nothing to claim, so tier order, the
    /// seven-day window, fill rules, transfer, split and off-budget handling
    /// must agree exactly; contention is the named multi-pass divergence.
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func everyLegacyFixtureRowAgreesOnItsOwn(seed: UInt64) {
        let data = Self.fixture(seed: seed, rowCount: 120, candidateCount: 300, offBudget: seed.isMultiple(of: 2))
        let offBudget = seed.isMultiple(of: 2)
        var kinds: Set<String> = []
        for row in data.rows {
            let old = Self.legacy([row], data.candidates)
            let new = Self.shared([row], data.candidates, offBudget: offBudget)
            #expect(old == new, "seed \(seed) row \(row.id)")
            switch new.first {
            case .insert: kinds.insert("insert")
            case .update: kinds.insert("update")
            case .unchanged: kinds.insert("unchanged")
            case .reconciled: kinds.insert("reconciled")
            case nil: break
            }
        }
        #expect(kinds.isSuperset(of: ["update", "unchanged", "reconciled"]), "seed \(seed) \(kinds)")
    }
}

private extension TransactionCSVImportCandidate {
    func withOffBudget(_ value: Bool) -> TransactionCSVImportCandidate {
        TransactionCSVImportCandidate(
            id: id, importedID: importedID, payeeID: payeeID, categoryID: categoryID, notes: notes,
            cleared: cleared, importedPayee: importedPayee, amountMinorUnits: amountMinorUnits,
            dateText: dateText, reconciled: reconciled, isParent: isParent, transferID: transferID,
            accountOffBudget: value
        )
    }
}
