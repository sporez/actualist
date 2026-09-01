import Foundation

/// Pure port of loot-core's bank-sync matcher
/// (`packages/loot-core/src/server/accounts/sync.ts` — `matchTransactions`
/// + the update stage of `reconcileTransactions`), for SimpleFIN downloads.
///
/// No I/O: callers hand in the normalized, rule-projected download
/// candidates and the account's live local rows. v1 runs with
/// `strictIdChecking: false` and does not rewrite dates (no date cascade).
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

        /// `v_transactions` validity: children must carry a parent id.
        var isValidCandidate: Bool { !isChild || parentID != nil }
    }

    // MARK: - Outputs

    /// The write planned onto one matched local row. Blank local fields are
    /// filled from the download; user-filled payee / category / notes win.
    /// `financialID` and `importedPayee` are bank-owned.
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
    }

    struct Plan: Equatable, Sendable {
        let entries: [Entry]

        var inserts: [Candidate] {
            entries.compactMap { if case .insert(let candidate) = $0 { return candidate }; return nil }
        }
    }

    // MARK: - Matcher

    /// loot-core three-pass match, in order: (1) `financial_id` equality,
    /// (2) same payee within ±7 days and the same amount across every
    /// candidate, (3) nearest remaining same-amount row in the window.
    /// A local row is claimed by at most one download.
    static func plan(candidates: [Candidate], existing: [Existing]) -> Plan {
        var claimed = Set<String>()

        // Pass 1 + fuzzy dataset construction (loot-core transactionsStep1).
        struct StepOne {
            let candidate: Candidate
            var matchedID: String?
            var fuzzy: [Existing]?
        }
        var stepOne: [StepOne] = []
        for candidate in candidates {
            var idMatch: Existing?
            if let financialID = candidate.financialID, !financialID.isEmpty {
                idMatch = existing.first {
                    $0.isValidCandidate && $0.financialID == financialID
                }
                if let idMatch {
                    claimed.insert(idMatch.id)
                }
            }
            let fuzzy: [Existing]? = idMatch == nil
                ? fuzzyDataset(for: candidate, in: existing)
                : nil
            stepOne.append(StepOne(candidate: candidate, matchedID: idMatch?.id, fuzzy: fuzzy))
        }

        // Pass 2: same payee (loot-core transactionsStep2).
        var matches: [Int: String] = [:]
        for (index, step) in stepOne.enumerated() {
            guard step.matchedID == nil, let fuzzy = step.fuzzy,
                  let payeeID = step.candidate.payeeID else { continue }
            guard let row = fuzzy.first(where: { !claimed.contains($0.id) && $0.payeeID == payeeID }) else { continue }
            claimed.insert(row.id)
            matches[index] = row.id
        }

        // Pass 3: nearest remaining same-amount row (transactionsStep3).
        for (index, step) in stepOne.enumerated() where matches[index] == nil && step.matchedID == nil {
            guard let fuzzy = step.fuzzy else { continue }
            if let row = fuzzy.first(where: { !claimed.contains($0.id) }) {
                claimed.insert(row.id)
                matches[index] = row.id
            }
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var entries: [Entry] = []
        for (index, step) in stepOne.enumerated() {
            let candidate = step.candidate
            guard let matchID = step.matchedID ?? matches[index],
                  let row = existingByID[matchID] else {
                entries.append(.insert(candidate))
                continue
            }

            // Reconciled rows are locked: matched but never written.
            guard !row.reconciled else {
                entries.append(.unchanged(existingID: row.id))
                continue
            }

            let existingNotes = row.notes?.isEmpty == false ? row.notes : nil
            // Split parents have a null category in the effective view. Filling
            // a blank parent category from the download would persist a category
            // on the parent, which Actual never does.
            let categoryID = row.isParent ? nil : (row.categoryID ?? candidate.categoryID)
            let update = MatchedUpdate(
                existingID: row.id,
                financialID: candidate.financialID,
                payeeID: row.payeeID ?? candidate.payeeID,
                categoryID: categoryID,
                importedPayee: candidate.importedPayee,
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
        }
        return Plan(entries: entries)
    }

    /// loot-core fuzzy query: same amount, date within ±7 calendar days
    /// inclusive, sorted by day distance (stable). `strictIdChecking` is
    /// false here, so rows with a different or absent `financial_id` are
    /// still eligible.
    private static func fuzzyDataset(for candidate: Candidate, in existing: [Existing]) -> [Existing] {
        existing
            .filter { row in
                row.isValidCandidate
                    && row.amountMinorUnits == candidate.amountMinorUnits
                    && abs(dayDistance(row.dayID, candidate.dayID)) <= 7
            }
            .enumerated()
            .sorted {
                let left = abs(dayDistance($0.element.dayID, candidate.dayID))
                let right = abs(dayDistance($1.element.dayID, candidate.dayID))
                if left != right { return left < right }
                return $0.offset < $1.offset
            }
            .map(\.element)
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

    // MARK: - Rule projection

    /// Projects one candidate through a rule preview *before* matching
    /// (loot-core runs rules on `transactionsStep1`). A delete-transaction
    /// rule drops the candidate (returns nil). Mirrors wallet import's
    /// preview application: rule-driven splits turn the candidate into a
    /// split parent.
    static func applyingRulePreview(_ preview: TransactionRulePreview, to candidate: Candidate) -> Candidate? {
        if preview.deletesTransaction {
            return nil
        }
        var projected = candidate
        projected.payeeID = preview.payeeID ?? projected.payeeID
        projected.amountMinorUnits = preview.amountMinorUnits ?? projected.amountMinorUnits
        // Rule preview carries the final notes value, including `nil` when a
        // matching rule removes downloaded notes. Nil is not "no change".
        projected.notes = preview.notes
        projected.categoryID = preview.splits.isEmpty ? (preview.categoryID ?? projected.categoryID) : nil
        projected.cleared = preview.cleared ?? projected.cleared
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
        return projected
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
        guard let first = dayNumber(a), let second = dayNumber(b) else {
            return .max
        }
        return abs(first - second)
    }

    /// Today as a UTC `YYYYMMDD` string — the fallback day for an opening
    /// balance when the download had no dated candidates.
    static func todayDayID(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d%02d%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Days since the civil epoch for a `YYYYMMDD` string, using Howard
    /// Hinnant's `days_from_civil` algorithm — no `Date`, no timezone.
    private static func dayNumber(_ dayID: String) -> Int? {
        let characters = Array(dayID)
        guard characters.count == 8, characters.allSatisfy(\.isNumber) else {
            return nil
        }
        let year = Int(dayID.prefix(4)) ?? 0
        let month = Int(dayID.dropFirst(4).prefix(2)) ?? 0
        let day = Int(dayID.suffix(2)) ?? 0
        guard (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let monthShift = month <= 2 ? month + 9 : month - 3
        let dayOfYear = (153 * monthShift + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // MARK: - Opening balance

    struct OpeningBalance: Equatable, Sendable {
        let amountMinorUnits: Int
        let dayID: String
    }

    /// First-apply opening balance for an account that had no live
    /// transactions before this run:
    /// `currentBalance − sum(all normalized provider candidates in the
    /// initial downloaded window)`. Deliberately sums every candidate —
    /// including ones a delete rule suppresses or a match adopts — because
    /// the bank balance reflects all of them. A zero opening balance is
    /// skipped. Returns nil when the account already had transactions.
    static func openingBalance(
        currentBalanceMinorUnits: Int,
        candidateAmounts: [Int],
        earliestDayID: String?,
        accountHadLiveTransactions: Bool
    ) -> OpeningBalance? {
        guard !accountHadLiveTransactions else { return nil }
        let amount = currentBalanceMinorUnits - candidateAmounts.reduce(0, +)
        guard amount != 0 else { return nil }
        return OpeningBalance(
            amountMinorUnits: amount,
            dayID: earliestDayID ?? todayDayID()
        )
    }
}
