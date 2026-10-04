import Foundation

/// Normalized CSV import rows plus the pure mapping and reconcile-matching
/// stages. Contracts: `.artifacts/sprint-next/csv-import-oracle.md` (parse) and
/// `.artifacts/sprint-next/csv-apply-oracle.md` (apply). Pure value logic only;
/// no repository access and no message construction.
struct TransactionCSVImportRow: Identifiable, Hashable, Sendable {
    /// Stable review identity, one row per CSV data row in file order.
    let id: String
    /// 1-based CSV data row number, for review and error messages.
    let sourceLine: Int
    /// ISO `yyyy-MM-dd`, the only observed import date format.
    let dateText: String
    /// Calendar date at local noon, so downstream `actualDateValue` and
    /// `YearMonth` components match the file's calendar day.
    let date: Date
    /// Minor units. Positive is inflow; the sign carries direction.
    let amountMinorUnits: Int
    /// Trimmed payee text. Empty means a null payee, never an unnamed payee.
    let payeeName: String
    let notes: String?
    let categoryName: String?
    /// nil when the file carries no Cleared value for the row.
    let cleared: Bool?
    let importedID: String?
}

enum TransactionCSVImportRowError: Error, Equatable {
    case missingDate
    case unparseableDate(text: String)
    case unparseableAmount(text: String)
    case zeroAmount

    var message: String {
        switch self {
        case .missingDate:
            return "a date is required"
        case .unparseableDate(let text):
            return "the date \"\(text)\" is not an ISO yyyy-mm-dd date"
        case .unparseableAmount(let text):
            return "the amount \"\(text)\" is not a decimal number"
        case .zeroAmount:
            return "the amount is zero, and a transaction must have a non-zero amount"
        }
    }
}

enum TransactionCSVImportError: Error, Equatable {
    case invalidEncoding
    case invalidDelimiter
    case invalidRow(line: Int, reason: TransactionCSVImportRowError)
    /// A matched row changed after review, so nothing was written.
    case matchChanged(line: Int)

    var message: String {
        switch self {
        case .invalidEncoding:
            return "The file is not readable as UTF-8 text."
        case .invalidDelimiter:
            return "The file could not be split into columns."
        case .invalidRow(let line, let reason):
            return "Row \(line) could not be read because \(reason.message)."
        case .matchChanged(let line):
            return "Row \(line) matches a transaction that changed after review. Nothing was imported. Open the import again to review it."
        }
    }
}

/// Maps a parsed table onto normalized rows. All-or-nothing: the first invalid
/// row rejects the whole mapping, mirroring the apply oracle's contract that a
/// batch with any invalid row writes zero rows.
enum TransactionCSVImportMapper {
    /// Positional column order for headerless files. The import fixture's
    /// headerless case carries exactly this order; the fixture does not
    /// specify a headerless mapping beyond preserving positions.
    static let headerlessColumnOrder: [(header: String, index: Int)] = [
        ("Date", 0), ("Payee", 1), ("Notes", 2), ("Amount", 3),
    ]

    static func map(_ table: TransactionCSVParser.Table) throws -> [TransactionCSVImportRow] {
        var rows: [TransactionCSVImportRow] = []
        rows.reserveCapacity(table.rows.count)
        for (index, fields) in table.rows.enumerated() {
            let line = index + 1
            let id = "csv-row-\(index + 1)"

            let dateText: String?
            if table.headers != nil {
                dateText = table.value(header: "Date", in: fields)
            } else {
                dateText = table.value(at: headerlessColumnOrder[0].index, in: fields)
            }
            let trimmedDate = dateText.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let trimmedDate, !trimmedDate.isEmpty else {
                throw TransactionCSVImportError.invalidRow(line: line, reason: .missingDate)
            }
            guard let date = dayDate(fromISO: trimmedDate) else {
                throw TransactionCSVImportError.invalidRow(line: line, reason: .unparseableDate(text: trimmedDate))
            }

            let amountRaw: String?
            if table.headers != nil {
                amountRaw = table.value(header: "Amount", in: fields)
            } else {
                amountRaw = table.value(at: 3, in: fields)
            }
            // A missing or empty amount is 0 at the parse stage, not a
            // rejection (oracle case 5).
            let amountText = amountRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let amountMinorUnits: Int
            if amountText.isEmpty {
                amountMinorUnits = 0
            } else if let parsed = Self.amountMinorUnits(amountText) {
                amountMinorUnits = parsed
            } else {
                throw TransactionCSVImportError.invalidRow(line: line, reason: .unparseableAmount(text: amountText))
            }
            // The shared local-first transaction construction rejects
            // zero-amount simple writes, so a zero row can never apply; with
            // all-or-nothing semantics it rejects the batch here.
            guard amountMinorUnits != 0 else {
                throw TransactionCSVImportError.invalidRow(line: line, reason: .zeroAmount)
            }

            let payeeRaw: String?
            if table.headers != nil {
                payeeRaw = table.value(header: "Payee", in: fields)
            } else {
                payeeRaw = table.value(at: 1, in: fields)
            }
            let payeeName = payeeRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let notesRaw: String?
            if table.headers != nil {
                notesRaw = table.value(header: "Notes", in: fields)
            } else {
                notesRaw = table.value(at: 2, in: fields)
            }
            let notes = notesRaw.flatMap { $0.isEmpty ? nil : $0 }

            // Category and Cleared are only header-mapped; the headerless
            // positional order carries no such columns.
            let categoryName = table.value(header: "Category", in: fields)
                .flatMap { $0.isEmpty ? nil : $0 }
            let cleared = table.value(header: "Cleared", in: fields)
                .flatMap { Self.clearedValue($0) }

            let importedID = table.value(header: "imported_id", in: fields)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }

            rows.append(TransactionCSVImportRow(
                id: id,
                sourceLine: line,
                dateText: trimmedDate,
                date: date,
                amountMinorUnits: amountMinorUnits,
                payeeName: payeeName,
                notes: notes,
                categoryName: categoryName,
                cleared: cleared,
                importedID: importedID
            ))
        }
        return rows
    }

    /// Strict ISO `yyyy-MM-dd`. Other locale formats are not import dates.
    static func dayDate(fromISO text: String) -> Date? {
        let characters = Array(text)
        guard characters.count == 10,
              characters[4] == "-", characters[7] == "-",
              characters.indices.allSatisfy({ index in
                  index == 4 || index == 7 || characters[index].isNumber
              }),
              let year = Int(String(characters[0...3])),
              let month = Int(String(characters[5...6])),
              let day = Int(String(characters[8...9])) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let date = calendar.date(from: components) else {
            return nil
        }
        // Reject normalized overflow such as 2026-02-30.
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day ? date : nil
    }

    /// Decimal string → minor units with an optional leading sign. Positive
    /// amounts are inflow. More than two fraction digits cannot round-trip
    /// through integer minor units, so it is not accepted.
    static func amountMinorUnits(_ raw: String) -> Int? {
        var text = Substring(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        var sign = 1
        if text.hasPrefix("-") {
            sign = -1
            text.removeFirst()
        } else if text.hasPrefix("+") {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let wholeText: Substring
        let fractionText: Substring
        switch parts.count {
        case 1:
            wholeText = parts[0]
            fractionText = ""
        case 2:
            wholeText = parts[0]
            fractionText = parts[1]
        default:
            return nil
        }
        guard !wholeText.isEmpty,
              wholeText.allSatisfy(\.isNumber),
              fractionText.count <= 2,
              fractionText.allSatisfy(\.isNumber) else {
            return nil
        }
        guard let whole = Int(wholeText), whole <= (Int.max - 99) / 100 else {
            return nil
        }
        var fraction = 0
        if fractionText.count == 1 {
            fraction = (Int(fractionText) ?? 0) * 10
        } else if fractionText.count == 2 {
            fraction = Int(fractionText) ?? 0
        }
        return sign * (whole * 100 + fraction)
    }

    /// The exporter writes exactly these three spellings. Anything else
    /// carries no cleared information rather than a guessed state.
    static func clearedValue(_ raw: String) -> Bool? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "cleared", "reconciled": return true
        case "not cleared": return false
        default: return nil
        }
    }
}

// MARK: - Reconcile matching

/// An existing live row in the importing account, reduced to the fields the
/// reconcile tiers and fill semantics use.
struct TransactionCSVImportCandidate: Hashable, Sendable {
    let id: String
    let importedID: String?
    let payeeID: String?
    let categoryID: String?
    let notes: String?
    let cleared: Bool?
    let importedPayee: String?
    let amountMinorUnits: Int
    /// Normalized `yyyy-MM-dd`.
    let dateText: String
    let reconciled: Bool
    /// A split parent: its effective category stays null.
    let isParent: Bool
    /// Non-empty for a transfer leg, whose payee and category belong to the
    /// transfer graph.
    let transferID: String?
    /// The importing account is off budget, so rows carry no budget category.
    let accountOffBudget: Bool
}

struct TransactionCSVImportMatchContext: Sendable {
    /// Lowercased payee name → payee ID for live payees, transfer payees
    /// included; payee lookup is a case-insensitive exact string match.
    let payeeIDByName: [String: String]
    /// Payee IDs whose payee carries a transfer account. A row becomes a
    /// transfer only by resolving to one of these.
    let transferPayeeIDs: Set<String>
    /// Lowercased category name → category ID for live categories.
    let categoryIDByName: [String: String]
}

enum TransactionCSVImportDisposition: Hashable, Sendable {
    /// Unmatched row; inserted. `isTransfer` is true when the row resolved to
    /// a transfer payee, which is the only way a CSV row becomes a transfer.
    case insert(isTransfer: Bool)
    /// Matched row updated in place; the plan carries only the changing
    /// fields (nil = leave unchanged).
    case update(TransactionCSVImportUpdatePlan)
    /// Matched but nothing changed.
    case ignored
    /// Matched a reconciled existing row; skipped entirely, never inserted.
    case skippedReconciled
}

struct TransactionCSVImportUpdatePlan: Hashable, Sendable {
    let existingTransactionID: String
    var payeeID: String?
    var categoryID: String?
    var notes: String?
    var cleared: Bool?
    var importedPayee: String?
    var importedID: String?
}

/// Reconcile tiers from the apply oracle (pinned `sync.ts` 845–857, 960–973,
/// 979–988): (1) exact `imported_id` + account; (2) fuzzy with same resolved
/// payee, same integer amount, date within ±7 days; (3) fuzzy on amount + date
/// alone. One claim per existing row per batch; no self-dedup within the batch.
enum TransactionCSVImportMatcher {
    static let fuzzyDateWindowDays = 7

    static func match(
        rows: [TransactionCSVImportRow],
        candidates: [TransactionCSVImportCandidate],
        context: TransactionCSVImportMatchContext
    ) -> [TransactionCSVImportDisposition] {
        var claimed: Set<String> = []
        var dispositions: [TransactionCSVImportDisposition] = []
        dispositions.reserveCapacity(rows.count)

        for row in rows {
            let resolvedPayeeID = row.payeeName.isEmpty
                ? nil
                : context.payeeIDByName[row.payeeName.lowercased()]

            // Tier 1: exact imported_id (candidates are already account-scoped).
            // Upstream compares with SQL `imported_id = ?`, which is exact.
            if let importedID = row.importedID, !importedID.isEmpty,
               let candidate = candidates.first(where: {
                   !claimed.contains($0.id) && $0.importedID == importedID
               }) {
                claimed.insert(candidate.id)
                dispositions.append(disposition(row: row, candidate: candidate, resolvedPayeeID: resolvedPayeeID, context: context))
                continue
            }

            // Fuzzy pool: same integer amount, date inside the ±7-day window,
            // unclaimed, and strict-id checking skips candidates that carry
            // their own imported_id when the incoming row has one.
            let fuzzy = fuzzyCandidates(row: row, candidates: candidates, claimed: claimed)

            // Tier 2: same resolved payee.
            if let resolvedPayeeID,
               let candidate = fuzzy.first(where: { $0.candidate.payeeID == resolvedPayeeID }) {
                claimed.insert(candidate.candidate.id)
                dispositions.append(disposition(row: row, candidate: candidate.candidate, resolvedPayeeID: resolvedPayeeID, context: context))
                continue
            }
            // Tier 3: amount + date alone; a different payee still matches.
            if let nearest = fuzzy.first {
                claimed.insert(nearest.candidate.id)
                dispositions.append(disposition(row: row, candidate: nearest.candidate, resolvedPayeeID: resolvedPayeeID, context: context))
                continue
            }

            dispositions.append(.insert(isTransfer: resolvedPayeeID.map(context.transferPayeeIDs.contains) ?? false))
        }
        return dispositions
    }

    private static func fuzzyCandidates(
        row: TransactionCSVImportRow,
        candidates: [TransactionCSVImportCandidate],
        claimed: Set<String>
    ) -> [(candidate: TransactionCSVImportCandidate, distance: Int, order: Int)] {
        var matches: [(candidate: TransactionCSVImportCandidate, distance: Int, order: Int)] = []
        for (order, candidate) in candidates.enumerated() {
            guard !claimed.contains(candidate.id),
                  candidate.amountMinorUnits == row.amountMinorUnits,
                  let distance = ActualDateOnly.dayDistance(from: candidate.dateText, to: row.dateText),
                  abs(distance) <= fuzzyDateWindowDays else {
                continue
            }
            // strictIdChecking (default for import): when both rows have an
            // imported_id, only the exact tier applies.
            if row.importedID != nil && candidate.importedID != nil {
                continue
            }
            matches.append((candidate, abs(distance), order))
        }
        return matches.sorted {
            $0.distance == $1.distance ? $0.order < $1.order : $0.distance < $1.distance
        }
    }

    /// Fill semantics (`existing || trans`): the existing row's truthy value
    /// wins for payee/category/notes/cleared; `imported_payee` is overwritten
    /// with the file's payee text and `imported_id` only when the file has
    /// one. Date and amount are never updated (the import handler never sets
    /// `updateDates`). An unchanged match is ignored; a reconciled match is
    /// skipped entirely.
    private static func disposition(
        row: TransactionCSVImportRow,
        candidate: TransactionCSVImportCandidate,
        resolvedPayeeID: String?,
        context: TransactionCSVImportMatchContext
    ) -> TransactionCSVImportDisposition {
        guard !candidate.reconciled else {
            return .skippedReconciled
        }
        let resolvedCategoryID = row.categoryName.flatMap { context.categoryIDByName[$0.lowercased()] }
        let incomingImportedPayee = row.payeeName.isEmpty ? candidate.importedPayee : row.payeeName

        let mergedPayeeID = mergedPayeeID(
            candidate: candidate,
            resolvedPayeeID: resolvedPayeeID,
            transferPayeeIDs: context.transferPayeeIDs
        )
        // Transfer legs, split parents and off-budget rows never take a
        // budget category from the file (the Bank Sync rules, mistakes.md
        // 2026-09-16); every other row follows upstream `existing || trans`.
        let canFillCategory = candidate.transferID == nil && !candidate.isParent && !candidate.accountOffBudget
        let mergedCategoryID = isTruthy(candidate.categoryID) || !canFillCategory
            ? candidate.categoryID
            : normalized(resolvedCategoryID)
        let mergedNotes = isTruthy(candidate.notes) ? candidate.notes : normalized(row.notes)
        // A nil existing cleared (column absent) never changes.
        let mergedCleared: Bool? = candidate.cleared == nil
            ? nil
            : (candidate.cleared == true ? true : (row.cleared ?? false))
        let mergedImportedID = row.importedID ?? candidate.importedID

        var plan = TransactionCSVImportUpdatePlan(
            existingTransactionID: candidate.id,
            payeeID: nil,
            categoryID: nil,
            notes: nil,
            cleared: nil,
            importedPayee: nil,
            importedID: nil
        )
        var changed = false
        if mergedPayeeID != candidate.payeeID {
            plan.payeeID = mergedPayeeID
            changed = true
        }
        if mergedCategoryID != candidate.categoryID {
            plan.categoryID = mergedCategoryID
            changed = true
        }
        if mergedNotes != candidate.notes {
            plan.notes = mergedNotes
            changed = true
        }
        if let mergedCleared, candidate.cleared != mergedCleared {
            plan.cleared = mergedCleared
            changed = true
        }
        if incomingImportedPayee != candidate.importedPayee {
            plan.importedPayee = incomingImportedPayee
            changed = true
        }
        if mergedImportedID != candidate.importedID {
            plan.importedID = mergedImportedID
            changed = true
        }
        return changed ? .update(plan) : .ignored
    }

    /// Upstream fills a blank payee from the file. A transfer leg keeps its
    /// payee, and a transfer payee never lands on a non-transfer row because
    /// that would leave a half-transfer with no paired leg.
    private static func mergedPayeeID(
        candidate: TransactionCSVImportCandidate,
        resolvedPayeeID: String?,
        transferPayeeIDs: Set<String>
    ) -> String? {
        if isTruthy(candidate.payeeID) || candidate.transferID != nil {
            return candidate.payeeID
        }
        guard let resolved = normalized(resolvedPayeeID), !transferPayeeIDs.contains(resolved) else {
            return candidate.payeeID
        }
        return resolved
    }

    /// JS-truthiness for the fill semantics: empty strings and null do not
    /// count as existing values.
    private static func isTruthy(_ value: String?) -> Bool {
        value != nil && !value!.isEmpty
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
