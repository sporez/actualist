import Foundation

/// Normalized CSV import rows plus the pure mapping stage. Contracts:
/// `.artifacts/sprint-next/csv-import-oracle.md` (parse) and
/// `.artifacts/sprint-next/csv-apply-oracle.md` (apply). Matching and writing
/// are the shared import reconcile step (`BankSyncReconciliation`,
/// `importReconcileWrites`). Pure value logic only; no repository access and no
/// message construction.
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
    case fileTooLarge
    case tooManyRows
    case invalidRow(line: Int, reason: TransactionCSVImportRowError)
    /// A matched row changed after review, so nothing was written.
    case matchChanged(line: Int)
    /// A row the review would insert was imported by someone else after the
    /// review (same `imported_id`), so nothing was written.
    case reviewChanged
    /// A rule would move the row into another account. An import never writes
    /// outside its own account, so the whole file is refused.
    case unsupportedAccountMove(line: Int)

    var message: String {
        switch self {
        case .invalidEncoding:
            return "The file is not readable as UTF-8 text."
        case .invalidDelimiter:
            return "The file could not be split into columns."
        case .fileTooLarge:
            return "The file is larger than \(TransactionCSVImportLimits.maxFileBytes / (1024 * 1024)) MB, which is more than an import can take."
        case .tooManyRows:
            return "The file has more than \(TransactionCSVImportLimits.maxRows.formatted()) rows, which is more than an import can take."
        case .invalidRow(let line, let reason):
            return "Row \(line) could not be read because \(reason.message)."
        case .matchChanged(let line):
            return "Row \(line) matches a transaction that changed after review. Nothing was imported. Open the import again to review it."
        case .reviewChanged:
            return "This account changed after review. Nothing was imported. Open the import again to review it."
        case .unsupportedAccountMove(let line):
            return "A rule would move row \(line) to another account, which an import can't do. Nothing was imported."
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
