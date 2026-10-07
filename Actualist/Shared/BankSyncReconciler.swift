import Foundation

/// Pure port of loot-core's bank-sync matcher
/// (`packages/loot-core/src/server/accounts/sync.ts` — `matchTransactions`
/// + the update stage of `reconcileTransactions`), for SimpleFIN downloads.
///
/// No I/O: callers hand in the normalized, rule-projected download
/// candidates and the account's live local rows. Bank Sync runs with
/// `ImportReconcileOptions.bankSync` (not strict) and does not rewrite dates
/// (no date cascade); CSV import runs the same reconcile with its own options.
///
/// Match-window contract: `existing` carries the account's live rows in the
/// ±7-day window (`v_transactions` semantics — valid split children
/// included, tombstones and invalid `is_child` rows without `parent_id`
/// excluded by the caller). Children referenced by a parent cascade are
/// looked up inside this list, so tombstoned children are never cascaded.
enum BankSyncReconciliation {
    // MARK: - Inputs

    /// One downloaded transaction after normalization and rule projection.
    struct Candidate: Equatable, Sendable {
        /// Bank's transaction id, destined for `financial_id`. Nil when the
        /// bridge did not supply one.
        var financialID: String?
        /// UTC calendar day, `YYYYMMDD`.
        var dayID: String
        var amountMinorUnits: Int
        /// Payee resolved by the caller against existing payees by name,
        /// case-insensitive, before matching. Not created here.
        var payeeID: String?
        /// Raw payee name from the download, kept so an insert can
        /// resolve-or-create the payee at apply time without a re-lookup.
        var payeeName: String?
        var notes: String?
        var categoryID: String?
        var cleared: Bool
        var importedPayee: String?
        var splits: [Split] = []
        var scheduleID: String? = nil
        /// False when the source never said whether the row is cleared (a CSV
        /// without a Cleared column). Matching treats it as not cleared, and an
        /// insert takes `ImportReconcileOptions.defaultCleared` instead
        /// (`trans.cleared ?? defaultCleared`, sync.ts).
        var clearedIsExplicit = true

        struct Split: Equatable, Sendable {
            var categoryID: String?
            var amountMinorUnits: Int
            var payeeID: SplitOptionalField<String> = .omitted
            var notes: SplitOptionalField<String> = .omitted
            var sortOrder: SplitOptionalField<Double> = .omitted
        }

        var isSplit: Bool { !splits.isEmpty }
    }

    /// One live local transaction row eligible for matching.
    struct Existing: Equatable, Sendable {
        let id: String
        let financialID: String?
        /// `YYYYMMDD`.
        let dayID: String
        let amountMinorUnits: Int
        let payeeID: String?
        let categoryID: String?
        let notes: String?
        let cleared: Bool
        /// Reconciled rows are locked: they match but never update and never
        /// cascade (loot-core skips updates for `match.reconciled`).
        let reconciled: Bool
        let importedPayee: String?
        let isParent: Bool
        let isChild: Bool
        let parentID: String?
        /// Paired transfer row id (`transferred_id` / `transfer_id`).
        let transferID: String?

        var isTransfer: Bool { transferID?.isEmpty == false }

        /// `v_transactions` validity: children must carry a parent id.
        var isValidCandidate: Bool { !isChild || parentID != nil }
    }

    // MARK: - Outputs

    /// The write planned onto one matched local row. Blank local fields are
    /// filled from the download; user-filled payee / category / notes win.
    /// Existing transfers and off-budget rows keep their category exactly,
    /// including nil. `financialID` and `importedPayee` are bank-owned.
    struct MatchedUpdate: Equatable, Sendable {
        let existingID: String
        let financialID: String?
        let payeeID: String?
        let categoryID: String?
        let importedPayee: String?
        let notes: String?
        let cleared: Bool
        /// Live split children of a matched split parent that receive the
        /// same cleared value. Travels with the parent match; not a separate
        /// review section.
        let childIDs: [String]
    }

    enum Entry: Equatable, Sendable {
        /// No local row matched; the candidate inserts as a new transaction
        /// (with split children when `isSplit`).
        case insert(Candidate)
        case update(MatchedUpdate)
        /// Matched but either reconciled (locked) or already identical.
        case unchanged(existingID: String)
        /// Exact bank ID was previously deleted; no local row may be written.
        case skippedDeleted(financialID: String)
    }

    struct Plan: Equatable, Sendable {
        let entries: [Entry]
        /// For each entry, the index in the `candidates` array it came from.
        /// Callers that must show one outcome per source row (CSV review) map
        /// entries back through it; entries are not in candidate order because
        /// deleted-id skips come first.
        let sources: [Int]

        var inserts: [Candidate] {
            entries.compactMap { if case .insert(let candidate) = $0 { return candidate }; return nil }
        }
    }

    // MARK: - Matcher

    /// `plan` off the main thread: the matcher is O(candidates x existing) and a
    /// large CSV or sync batch would otherwise block the UI. The plan is the
    /// same value `plan` returns.
    @concurrent
    static func planOffMain(
        candidates: [Candidate],
        existing: [Existing],
        suppressedFinancialIDs: Set<String>,
        accountIsOffBudget: Bool,
        transferPayeeIDs: Set<String>,
        options: ImportReconcileOptions
    ) async -> Plan {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        return plan(
            candidates: candidates,
            existing: existing,
            suppressedFinancialIDs: suppressedFinancialIDs,
            accountIsOffBudget: accountIsOffBudget,
            transferPayeeIDs: transferPayeeIDs,
            options: options
        )
    }

    /// loot-core three-pass match, in order: (1) `financial_id` equality,
    /// (2) same payee within ±7 days and the same amount across every
    /// candidate, (3) nearest remaining same-amount row in the window.
    /// A local row is claimed by at most one download. Children of a split
    /// parent matched by `financial_id` are reserved from both fuzzy passes
    /// for the whole batch, regardless of download order (loot-core 24deae7).
    static func plan(
        candidates: [Candidate],
        existing: [Existing],
        suppressedFinancialIDs: Set<String> = [],
        accountIsOffBudget: Bool = false,
        transferPayeeIDs: Set<String> = [],
        options: ImportReconcileOptions = .bankSync
    ) -> Plan {
        #if DEBUG
        MainThreadCallLog.record("reconcilePlan", key: candidates.compactMap(\.financialID).joined(separator: ","))
        #endif
        let epochDays = existing.map { epochDay(compact: $0.dayID) }
        // The fuzzy query only looks at rows of the candidate's amount, so index
        // them once instead of scanning every stored row per candidate (a
        // 50,000-row CSV against a busy account would otherwise be quadratic).
        let offsetsByAmount = Dictionary(grouping: existing.indices) { existing[$0].amountMinorUnits }
        var claimed = Set<String>()
        var exactMatchedParentIDs = Set<String>()

        // Pass 1 + fuzzy dataset construction (loot-core transactionsStep1).
        struct StepOne {
            let source: Int
            let candidate: Candidate
            var matchedID: String?
            var fuzzy: [Existing]?
        }
        var stepOne: [StepOne] = []
        var entries: [Entry] = []
        var sources: [Int] = []
        for (source, candidate) in candidates.enumerated() {
            var idMatch: Existing?
            if let financialID = candidate.financialID, !financialID.isEmpty {
                idMatch = existing.first {
                    $0.isValidCandidate && $0.financialID == financialID
                }
                if let idMatch {
                    claimed.insert(idMatch.id)
                    if idMatch.isParent { exactMatchedParentIDs.insert(idMatch.id) }
                } else if suppressedFinancialIDs.contains(financialID) {
                    entries.append(.skippedDeleted(financialID: financialID))
                    sources.append(source)
                    continue
                }
            }
            let fuzzy: [Existing]? = idMatch == nil
                ? fuzzyDataset(
                    for: candidate,
                    in: existing,
                    epochDays: epochDays,
                    strictIdChecking: options.strictIdChecking,
                    offsetsByAmount: offsetsByAmount
                )
                : nil
            stepOne.append(StepOne(source: source, candidate: candidate, matchedID: idMatch?.id, fuzzy: fuzzy))
        }

        func isReserved(_ row: Existing) -> Bool {
            row.parentID.map(exactMatchedParentIDs.contains) ?? false
        }

        // Pass 2: same payee (loot-core transactionsStep2).
        var matches: [Int: String] = [:]
        for (index, step) in stepOne.enumerated() {
            guard step.matchedID == nil, let fuzzy = step.fuzzy,
                  let payeeID = step.candidate.payeeID else { continue }
            guard let row = fuzzy.first(where: {
                !claimed.contains($0.id) && !isReserved($0) && $0.payeeID == payeeID
            }) else { continue }
            claimed.insert(row.id)
            matches[index] = row.id
        }

        // Pass 3: nearest remaining same-amount row (transactionsStep3).
        for (index, step) in stepOne.enumerated() where matches[index] == nil && step.matchedID == nil {
            guard let fuzzy = step.fuzzy else { continue }
            if let row = fuzzy.first(where: { !claimed.contains($0.id) && !isReserved($0) }) {
                claimed.insert(row.id)
                matches[index] = row.id
            }
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for (index, step) in stepOne.enumerated() {
            let candidate = step.candidate
            guard let matchID = step.matchedID ?? matches[index],
                  let row = existingByID[matchID] else {
                entries.append(.insert(
                    accountIsOffBudget ? withoutBudgetCategory(candidate) : candidate
                ))
                sources.append(step.source)
                continue
            }

            // Reconciled rows are locked: matched but never written.
            guard !row.reconciled else {
                entries.append(.unchanged(existingID: row.id))
                sources.append(step.source)
                continue
            }

            let existingNotes = row.notes?.isEmpty == false ? row.notes : nil
            // A row that never had a bank id or payee text (CSV) keeps what the
            // matched row already stores; see `isBankSyncAccount`.
            let keepsStoredIdentity = !options.isBankSyncAccount
            let update = MatchedUpdate(
                existingID: row.id,
                financialID: candidate.financialID ?? (keepsStoredIdentity ? row.financialID : nil),
                payeeID: mergedPayeeID(
                    existing: row,
                    candidate: candidate,
                    transferPayeeIDs: transferPayeeIDs
                ),
                categoryID: mergedCategoryID(
                    existing: row,
                    candidate: candidate,
                    accountIsOffBudget: accountIsOffBudget
                ),
                importedPayee: candidate.importedPayee ?? (keepsStoredIdentity ? row.importedPayee : nil),
                notes: existingNotes ?? candidate.notes,
                cleared: row.cleared || candidate.cleared,
                childIDs: childIDsForClearCascade(of: row, in: existing, cleared: row.cleared || candidate.cleared)
            )
            // loot-core hasFieldsChanged: a match that would write nothing is
            // reported as unchanged, not as an update.
            if update.financialID == row.financialID,
               update.payeeID == row.payeeID,
               update.categoryID == row.categoryID,
               update.importedPayee == row.importedPayee,
               update.notes == existingNotes,
               update.cleared == row.cleared {
                entries.append(.unchanged(existingID: row.id))
            } else {
                entries.append(.update(update))
            }
            sources.append(step.source)
        }
        return Plan(entries: entries, sources: sources)
    }

    /// loot-core fuzzy query: same amount, date within ±7 calendar days
    /// inclusive, sorted by day distance (stable). Without
    /// `strictIdChecking`, rows with a different or absent `financial_id` are
    /// still eligible; with it, a row that already has an id is skipped when
    /// the candidate has one too (`(imported_id IS NULL OR ? IS NULL)`).
    /// `offsetsByAmount` is an index of `existing` offsets per amount, in order.
    static func fuzzyDataset(
        for candidate: Candidate,
        in existing: [Existing],
        epochDays: [Int?],
        strictIdChecking: Bool = false,
        offsetsByAmount: [Int: [Int]]? = nil
    ) -> [Existing] {
        // A malformed day never falls inside the window (`dayDistance` is .max).
        guard let candidateDay = epochDay(compact: candidate.dayID) else { return [] }
        var matches: [(distance: Int, offset: Int)] = []
        let offsets = offsetsByAmount.map { $0[candidate.amountMinorUnits] ?? [] } ?? Array(existing.indices)
        for offset in offsets {
            let row = existing[offset]
            guard row.isValidCandidate, row.amountMinorUnits == candidate.amountMinorUnits,
                  let day = epochDays[offset] else { continue }
            if strictIdChecking, candidate.financialID?.isEmpty == false, row.financialID != nil { continue }
            let distance = abs(day - candidateDay)
            if distance <= 7 { matches.append((distance, offset)) }
        }
        matches.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.offset < $1.offset }
        return matches.map { existing[$0.offset] }
    }

    /// Epoch day of a `YYYYMMDD` id, parsed once per row by the caller.
    static func epochDay(compact dayID: String) -> Int? {
        let digits = Array(dayID)
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        return ActualDateOnly.epochDay("\(dayID.prefix(4))-\(dayID.dropFirst(4).prefix(2))-\(dayID.suffix(2))")
    }

    /// Split-parent cleared cascade: when a matched parent's cleared value
    /// changes, the same cleared value lands on its live children
    /// (`reconcileTransactions`). Tombstoned children are not present in the
    /// live row list and are therefore skipped.
    private static func childIDsForClearCascade(
        of row: Existing,
        in existing: [Existing],
        cleared: Bool
    ) -> [String] {
        guard row.isParent, row.cleared != cleared else { return [] }
        return existing
            .filter { $0.isChild && $0.parentID == row.id && $0.cleared != cleared }
            .map(\.id)
    }

    /// Existing transfers keep their payee. A rule must not turn a normal
    /// matched row into a half-transfer by filling a transfer payee with no pair.
    private static func mergedPayeeID(
        existing row: Existing,
        candidate: Candidate,
        transferPayeeIDs: Set<String>
    ) -> String? {
        if row.isTransfer {
            return row.payeeID
        }
        let proposed = row.payeeID ?? candidate.payeeID
        if let proposed, transferPayeeIDs.contains(proposed) {
            return row.payeeID
        }
        return proposed
    }

    /// Transfers keep their existing category, including nil. Off-budget
    /// accounts never take a budget category, matching Actual's insert strip
    /// (`batchUpdateTransactions`: off-budget rows should not have categories).
    /// Split parents stay uncategorized in the effective view.
    private static func mergedCategoryID(
        existing row: Existing,
        candidate: Candidate,
        accountIsOffBudget: Bool
    ) -> String? {
        if row.isTransfer || accountIsOffBudget {
            return row.categoryID
        }
        if row.isParent {
            return nil
        }
        return row.categoryID ?? candidate.categoryID
    }

    /// Actual clears category on every off-budget insert, including split children.
    private static func withoutBudgetCategory(_ candidate: Candidate) -> Candidate {
        var copy = candidate
        copy.categoryID = nil
        if !copy.splits.isEmpty {
            copy.splits = copy.splits.map { split in
                var split = split
                split.categoryID = nil
                return split
            }
        }
        return copy
    }

    // MARK: - Rule projection

    /// Projects one candidate through a rule preview *before* matching
    /// (loot-core runs rules on `transactionsStep1`). A delete-transaction
    /// rule drops the candidate (returns nil). Mirrors wallet import's
    /// preview application: rule-driven splits turn the candidate into a
    /// split parent.
    static func applyingRulePreview(
        _ preview: TransactionRulePreview,
        to candidate: Candidate,
        accountIsOffBudget: Bool = false
    ) -> Candidate? {
        if preview.deletesTransaction {
            return nil
        }
        var projected = candidate
        projected.payeeID = preview.payeeID ?? projected.payeeID
        projected.amountMinorUnits = preview.amountMinorUnits ?? projected.amountMinorUnits
        if let date = preview.date {
            projected.dayID = ActualDateOnly.dayID(from: date, timeZone: .autoupdatingCurrent)
                .replacingOccurrences(of: "-", with: "")
        }
        // Rule preview carries the final notes value, including `nil` when a
        // matching rule removes downloaded notes. Nil is not "no change".
        projected.notes = preview.notes
        projected.categoryID = preview.splits.isEmpty ? (preview.categoryID ?? projected.categoryID) : nil
        if let cleared = preview.cleared {
            projected.cleared = cleared
            projected.clearedIsExplicit = true
        }
        projected.scheduleID = preview.scheduleID ?? projected.scheduleID
        projected.splits = preview.splits.isEmpty
            ? projected.splits
            : preview.splits.map {
                .init(
                    categoryID: $0.categoryID,
                    amountMinorUnits: $0.amountMinorUnits,
                    payeeID: $0.payeeID,
                    notes: $0.notes,
                    sortOrder: $0.sortOrder
                )
            }
        return accountIsOffBudget ? withoutBudgetCategory(projected) : projected
    }

    /// loot-core `normalizeBankSyncTransactions`: imported notes are trimmed
    /// and every `#` is doubled so note-authored markers (`#template`,
    /// `#goal`, `#cleanup`) stay inert.
    static func escapedNotes(_ notes: String) -> String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "##")
    }

    // MARK: - Day math

    /// Timezone-free calendar-day distance between two `YYYYMMDD` strings.
    /// Malformed input returns `Int.max` so it can never fall inside the
    /// ±7-day window.
    static func dayDistance(_ a: String, _ b: String) -> Int {
        guard let distance = ActualDateOnly.dayDistance(fromCompact: a, toCompact: b) else { return .max }
        return abs(distance)
    }

    /// Today as a UTC `YYYYMMDD` string — the fallback day for an opening
    /// balance when the download had no dated candidates.
    static func todayDayID(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d%02d%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    // MARK: - Opening balance

    struct OpeningBalance: Equatable, Sendable {
        let amountMinorUnits: Int
        let dayID: String
    }

    /// First-apply balance subtracts only final planned inserts. Rule-suppressed
    /// and deleted downloads never affect the resulting account balance;
    /// a split contributes its parent amount once.
    static func openingBalance(
        currentBalanceMinorUnits: Int,
        inserts: [Candidate],
        earliestDayID: String?,
        accountHadLiveTransactions: Bool
    ) -> OpeningBalance? {
        guard !accountHadLiveTransactions else { return nil }
        let amount = currentBalanceMinorUnits - inserts.reduce(0) { $0 + $1.amountMinorUnits }
        guard amount != 0 else { return nil }
        return OpeningBalance(
            amountMinorUnits: amount,
            dayID: earliestDayID ?? todayDayID()
        )
    }
}
