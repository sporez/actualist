import Foundation

/// Pure CSV text parser. Mirrors pinned Actual 26.9.0 `parseFile`'s
/// `csv-parse/sync` option set (`bom: true`, `quote: '"'`, `trim: true`,
/// `relax_column_count: true`, `skip_empty_lines: true`) with caller-provided
/// `delimiter` and `hasHeaderRow` (`.artifacts/sprint-next/csv-import-oracle.md`).
/// It performs no field mapping, no date or amount interpretation, and no row
/// validation; those live in the import mapping stage. No repository access.
struct TransactionCSVParser {
    struct Options: Sendable {
        var delimiter: String
        var hasHeaderRow: Bool

        init(delimiter: String = ",", hasHeaderRow: Bool = true) {
            self.delimiter = delimiter
            self.hasHeaderRow = hasHeaderRow
        }
    }

    struct Table: Equatable, Sendable {
        /// Trimmed header names when the file was parsed with a header row.
        let headers: [String]?
        /// Data rows. Relaxed column counts mean a row may hold fewer fields
        /// than the header (missing fields) or more than the header (extras
        /// are truncated to the header width).
        let rows: [[String]]

        /// Header-keyed lookup. A missing header or a short row yields nil,
        /// matching the parse oracle's "absent key" observation.
        func value(header: String, in row: [String]) -> String? {
            guard let headers,
                  let index = headers.firstIndex(where: { $0.caseInsensitiveCompare(header) == .orderedSame }),
                  index < row.count else {
                return nil
            }
            return row[index]
        }

        /// Positional lookup for headerless files; missing fields yield nil.
        func value(at index: Int, in row: [String]) -> String? {
            index < row.count ? row[index] : nil
        }
    }

    enum ParseError: Error, Equatable {
        case invalidEncoding
        case invalidDelimiter
    }

    private let options: Options

    init(options: Options = Options()) {
        self.options = options
    }

    func parse(_ data: Data) throws -> Table {
        guard options.delimiter.count == 1, let delimiter = options.delimiter.first else {
            throw ParseError.invalidDelimiter
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw ParseError.invalidEncoding
        }
        // `bom: true`: a leading UTF-8 BOM is stripped, not kept in the first
        // header or field.
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return try parse(text: text, delimiter: delimiter)
    }

    private func parse(text: String, delimiter: Character) throws -> Table {
        var rows: [[String]] = []
        var fields: [String] = []
        var field = String()
        var fieldWasQuoted = false
        var inQuotes = false

        func endField() {
            let value = fieldWasQuoted ? field : field.trimmingCharacters(in: .whitespacesAndNewlines)
            fields.append(value)
            field = String()
            fieldWasQuoted = false
        }

        func endRecord() {
            endField()
            // `skip_empty_lines: true`: blank lines are dropped, not rejected
            // (oracle case 7).
            guard !(fields.count == 1 && fields[0].isEmpty) else {
                fields = []
                return
            }
            rows.append(fields)
            fields = []
        }

        var scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    // RFC escaping: `""` inside a quoted field is one quote.
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                    } else {
                        inQuotes = false
                        index += 1
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                    index += 1
                }
                continue
            }
            if scalar == "\"", field.isEmpty, !fieldWasQuoted {
                inQuotes = true
                fieldWasQuoted = true
                index += 1
                continue
            }
            if Character(scalar) == delimiter {
                endField()
                index += 1
                continue
            }
            if scalar == "\n" {
                endRecord()
                index += 1
                continue
            }
            if scalar == "\r" {
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    endRecord()
                    index += 2
                } else {
                    // A lone CR is field content; the exporter quotes it.
                    field.unicodeScalars.append(scalar)
                    index += 1
                }
                continue
            }
            field.unicodeScalars.append(scalar)
            index += 1
        }
        if !field.isEmpty || fieldWasQuoted || !fields.isEmpty {
            endRecord()
        }

        if options.hasHeaderRow {
            guard let headers = rows.first else {
                return Table(headers: [], rows: [])
            }
            return Table(
                headers: headers,
                rows: rows.dropFirst().map { row in
                    // `relax_column_count`: extra values are silently dropped;
                    // short rows keep only the fields they have.
                    row.count > headers.count ? Array(row.prefix(headers.count)) : row
                }
            )
        }
        return Table(headers: nil, rows: rows)
    }
}
