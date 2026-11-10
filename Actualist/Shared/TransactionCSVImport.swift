import Foundation

/// One transaction as Actual's import step (`importTransactions`) receives it,
/// plus its place in the file for review. The CSV mapper builds these the way
/// Actual's import modal does; matching and writing are the shared import
/// reconcile step (`BankSyncReconciliation`, `importReconcileWrites`). Pure
/// value logic only; no repository access and no message construction.
struct TransactionCSVImportRow: Identifiable, Hashable, Sendable {
    /// Stable review identity, one row per CSV data row in file order.
    let id: String
    /// 1-based CSV data row number, for review and error messages.
    let sourceLine: Int
    /// ISO `yyyy-MM-dd`.
    let dateText: String
    /// Minor units. Positive is inflow; the sign carries direction.
    let amountMinorUnits: Int
    /// Trimmed payee text. Empty means a null payee, never an unnamed payee.
    let payeeName: String
    let notes: String?
    /// The category text as the file has it; matched to a category by
    /// `ImportCategoryMatcher`.
    let categoryName: String?
    /// The CSV mapper always sends `true` (Actual's "Clear transactions on
    /// import", on by default). `nil` only for other import sources that do
    /// not say.
    let cleared: Bool?
    /// Never set by the CSV mapper: Actual's modal sends no import ID for a
    /// CSV. Other `importTransactions` callers may.
    let importedID: String?
    /// The file has a Payee cell and it is exactly empty. Upstream stores that
    /// as an empty imported payee; an absent or whitespace-only cell is null.
    var payeeCellWasEmpty = false
    /// The amount cell had text that does not read as an amount. Actual
    /// imports such a row as 0; the review points it out.
    var amountUnreadable = false
}

enum TransactionCSVImportRowError: Error, Equatable {
    case missingDate
    case unparseableDate(text: String, format: ImportDateFormat)

    var message: String {
        switch self {
        case .missingDate:
            return "a date is required"
        case .unparseableDate(let text, let format):
            return "the date \"\(text)\" does not match the date format \(format.label)"
        }
    }
}

enum TransactionCSVImportError: Error, Equatable {
    case invalidDelimiter
    /// The file is not CSV that Actual's parser reads; nothing is imported.
    case unreadableFile(TransactionCSVParser.ParseError)
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
        case .invalidDelimiter:
            return "The file could not be split into columns."
        case .unreadableFile(let reason):
            return "The file could not be read as CSV: \(reason.message) Nothing was imported."
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
            return "A rule would move row \(line) to another account, which an import cannot do. Nothing was imported."
        }
    }
}

/// Maps a parsed table onto import rows the way Actual's import modal does
/// with its default settings (pinned v26.11.0, `ImportTransactionsModal.tsx`
/// `parse`, `getImportPreview` and `onImport`): guess the columns and the
/// date format from the first row, order the rows as the preview does, then
/// read each row. All-or-nothing: a row whose date does not read rejects the
/// file, as Actual's import does.
enum TransactionCSVImportMapper {
    struct Result: Equatable, Sendable {
        /// In the order Actual imports them.
        let rows: [TransactionCSVImportRow]
        let dateFormat: ImportDateFormat
        /// Actual's order for these rows is engine-defined (see
        /// `previewOrder`); the rows keep file order.
        let orderIsEngineDefined: Bool
    }

    static func map(_ table: TransactionCSVParser.Table) throws -> Result {
        let sources = ImportFieldMappingRules.sourceRows(from: table)
        let mapping = ImportFieldMappingRules.initialMappings(sources) ?? ImportFieldMapping()
        let dateFormat = ImportDateParsing.initialDateFormat(
            rowCount: sources.count,
            firstDateValue: mapping.date.flatMap { sources.first?.value($0) },
            hasDateColumn: mapping.date != nil
        )
        let mapped = sources.map { ImportFieldMappingRules.apply(mapping, to: $0) }

        // Actual stops at the first unreadable date in its import order. Any
        // such row fails the whole file, so report the first one in the file.
        var dates: [String] = []
        dates.reserveCapacity(mapped.count)
        for (index, row) in mapped.enumerated() {
            guard let date = ImportDateParsing.parseDate(row.date, format: dateFormat) else {
                let reason: TransactionCSVImportRowError = row.date.map {
                    .unparseableDate(text: $0, format: dateFormat)
                } ?? .missingDate
                throw TransactionCSVImportError.invalidRow(line: index + 1, reason: reason)
            }
            dates.append(date)
        }

        let order = previewOrder(sources, dateFormat: dateFormat)
        let rows = (order ?? Array(sources.indices)).map { index in
            let row = mapped[index]
            return TransactionCSVImportRow(
                id: "csv-row-\(index + 1)",
                sourceLine: index + 1,
                dateText: dates[index],
                amountMinorUnits: ImportAmountParsing.singleColumnMinorUnits(row.amount),
                payeeName: row.payeeName.map(JavaScriptText.trim) ?? "",
                notes: row.notes.flatMap { $0.isEmpty ? nil : $0 },
                categoryName: row.category,
                cleared: true,
                importedID: nil,
                payeeCellWasEmpty: row.payeeName == "",
                amountUnreadable: row.amount.map {
                    !JavaScriptText.trim($0).isEmpty && ImportAmountParsing.looselyParseAmount($0) == nil
                } ?? false
            )
        }
        return Result(rows: rows, dateFormat: dateFormat, orderIsEngineDefined: order == nil)
    }

    /// The preview's sort (`getImportPreview`): newest first by the RAW column
    /// named exactly `date`, not the mapped date column, and stable. When that
    /// column reads for some rows but not others, Actual's comparator is
    /// inconsistent and V8's resulting order is engine-defined, so this
    /// returns `nil`.
    private static func previewOrder(_ sources: [ImportSourceRow], dateFormat: ImportDateFormat) -> [Int]? {
        let keys = sources.map { ImportDateParsing.parseDate($0.value("date"), format: dateFormat) }
        let readable = keys.filter { $0 != nil }.count
        guard readable == 0 || readable == keys.count else { return nil }
        return Array(sources.indices).sorted { lhs, rhs in
            let left = keys[lhs] ?? ""
            let right = keys[rhs] ?? ""
            // ISO days compare correctly as text; ties keep file order.
            return left != right ? left > right : lhs < rhs
        }
    }
}
