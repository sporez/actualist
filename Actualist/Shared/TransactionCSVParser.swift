import Foundation

/// Pure CSV text parser: a port of what Actual's import does to a CSV file
/// (pinned v26.11.0 `parseFile` → `parseCSV`): `decodeCsvBytes` and the
/// skip-lines step (`ImportFileDecoding`), then `csv-parse` 7.0.3 with
/// `bom: true`, `quote: '"'`, `trim: true`, `relax_column_count: true`,
/// `skip_empty_lines: true`, and the caller's `delimiter` and header choice. The `file-import` oracle
/// replays it. It performs no field mapping, no date or amount
/// interpretation, and no row validation; those live in the import mapping
/// stage. No repository access.
///
/// csv-parse matches bytes; this matches Unicode scalars. Every token it
/// looks for (quote, delimiter, line endings, the trim characters) is a whole
/// UTF-8 sequence, and none starts with a continuation byte, so both find the
/// same tokens.
struct TransactionCSVParser {
    struct Options: Sendable {
        var delimiter: String
        var hasHeaderRow: Bool
        /// A `TextDecoder` label, or `auto`.
        var encoding: String
        var skipStartLines: Int
        var skipEndLines: Int

        init(
            delimiter: String = ",",
            hasHeaderRow: Bool = true,
            encoding: String = "auto",
            skipStartLines: Int = 0,
            skipEndLines: Int = 0
        ) {
            self.delimiter = delimiter
            self.hasHeaderRow = hasHeaderRow
            self.encoding = encoding
            self.skipStartLines = skipStartLines
            self.skipEndLines = skipEndLines
        }
    }

    struct Table: Equatable, Sendable {
        /// Header names when the file was parsed with a header row.
        let headers: [String]?
        /// Data rows. A row may hold fewer fields than the header (missing
        /// fields); fields past the header width are dropped, as
        /// `relax_column_count` does with `columns: true`.
        let rows: [[String]]

        /// Positional lookup; missing fields yield nil.
        func value(at index: Int, in row: [String]) -> String? {
            index < row.count ? row[index] : nil
        }
    }

    /// csv-parse refuses these files; Actual's import then shows
    /// "Failed parsing" and imports nothing.
    enum ParseError: Error, Equatable {
        case invalidDelimiter
        case unsupportedEncoding(String)
        /// More lines to skip than the file has.
        case skipsTooManyLines
        /// `INVALID_OPENING_QUOTE`: a quote after other text in a field.
        case invalidOpeningQuote(line: Int)
        /// `CSV_INVALID_CLOSING_QUOTE`: a closing quote followed by text.
        case invalidClosingQuote(line: Int)
        /// `CSV_NON_TRIMABLE_CHAR_AFTER_CLOSING_QUOTE`
        case textAfterClosingQuote(line: Int)
        /// `CSV_QUOTE_NOT_CLOSED`
        case quoteNotClosed(line: Int)

        var message: String {
            switch self {
            case .invalidDelimiter:
                return "the column separator is not a single character."
            case .unsupportedEncoding(let label):
                return "the text encoding \"\(label)\" is not one Actual's import offers."
            case .skipsTooManyLines:
                return "it has fewer lines than the import is set to skip."
            case .invalidOpeningQuote(let line):
                return "line \(line) has a quote mark after other text in a field."
            case .invalidClosingQuote(let line), .textAfterClosingQuote(let line):
                return "line \(line) has text right after a closing quote mark."
            case .quoteNotClosed:
                return "a quote mark is never closed before the end of the file."
            }
        }
    }

    private let options: Options

    init(options: Options = Options()) {
        self.options = options
    }

    func parse(_ data: Data) throws -> Table {
        let delimiterScalars = Array(options.delimiter.unicodeScalars)
        guard delimiterScalars.count == 1 else {
            throw ParseError.invalidDelimiter
        }
        var scalars: [Unicode.Scalar]
        do {
            scalars = try ImportFileDecoding.skipLines(
                ImportFileDecoding.decode([UInt8](data), encoding: options.encoding),
                start: options.skipStartLines,
                end: options.skipEndLines
            )
        } catch ImportFileDecoding.DecodingError.unsupportedEncoding(let label) {
            throw ParseError.unsupportedEncoding(label)
        } catch ImportFileDecoding.DecodingError.skipsTooManyLines {
            throw ParseError.skipsTooManyLines
        }
        // csv-parse's `bom: true` drops one more leading BOM.
        if scalars.first == "\u{FEFF}" {
            scalars.removeFirst()
        }
        var reader = CSVRecordReader(scalars: scalars, delimiter: delimiterScalars[0])
        var records = try reader.read()
        guard options.hasHeaderRow else {
            return Table(headers: nil, rows: records)
        }
        guard !records.isEmpty else {
            return Table(headers: [], rows: [])
        }
        let headers = records.removeFirst()
        return Table(
            headers: headers,
            rows: records.map { $0.count > headers.count ? Array($0.prefix(headers.count)) : $0 }
        )
    }
}

/// csv-parse 7.0.3's `parse` loop (`lib/api/index.js`) for the options above.
private struct CSVRecordReader {
    let scalars: [Unicode.Scalar]
    let delimiter: Unicode.Scalar

    private var position = 0
    private var field: [Unicode.Scalar] = []
    private var record: [String] = []
    private var records: [[String]] = []
    private var quoting = false
    private var wasQuoting = false
    private var escaping = false
    /// Undiscovered until the first line ending outside quotes; that ending
    /// (`\r\n`, `\n` or `\r`) is then the only record delimiter.
    private var recordDelimiter: [Unicode.Scalar] = []
    /// `info.lines`, for error messages.
    private var line = 1
    private var wasRowDelimiter = false

    init(scalars: [Unicode.Scalar], delimiter: Unicode.Scalar) {
        self.scalars = scalars
        self.delimiter = delimiter
    }

    mutating func read() throws -> [[String]] {
        var iterations = 0
        while position < scalars.count {
            // A large file must stop promptly when its import is cancelled.
            iterations += 1
            if iterations % 8_192 == 0 { try Task.checkCancellation() }
            try step()
            position += 1
        }
        if quoting {
            throw TransactionCSVParser.ParseError.quoteNotClosed(line: line)
        }
        // A last line with no characters is not a record.
        if wasQuoting || !record.isEmpty || !field.isEmpty {
            endField()
            endRecord()
        }
        return records
    }

    private mutating func step() throws {
        if wasRowDelimiter {
            line += 1
            wasRowDelimiter = false
        }
        if !quoting, recordDelimiter.isEmpty {
            discoverRecordDelimiter(at: position)
        }
        let scalar = scalars[position]
        if scalar == "\r" || scalar == "\n" {
            wasRowDelimiter = true
        }
        if escaping {
            // The quote after an escaping quote is ordinary text.
            escaping = false
        } else {
            if quoting, scalar == "\"", position + 1 < scalars.count, scalars[position + 1] == "\"" {
                escaping = true
                return
            }
            if scalar == "\"" {
                if quoting {
                    let next = position + 1
                    // `!nextChr` is also true for a NUL byte.
                    let closes = next >= scalars.count
                        || scalars[next].value == 0
                        || scalars[next] == delimiter
                        || isRecordDelimiterAfterQuote(at: next)
                        || JavaScriptText.isWhitespace(scalars[next])
                    guard closes else {
                        throw TransactionCSVParser.ParseError.invalidClosingQuote(line: line)
                    }
                    quoting = false
                    wasQuoting = true
                    return
                }
                guard field.isEmpty else {
                    throw TransactionCSVParser.ParseError.invalidOpeningQuote(line: line)
                }
                quoting = true
                return
            }
            if !quoting {
                let delimiterLength = recordDelimiterLength(at: position)
                if delimiterLength > 0 {
                    // `skip_empty_lines`: a line with nothing kept is skipped.
                    if !(!wasQuoting && record.isEmpty && field.isEmpty) {
                        endField()
                        endRecord()
                    }
                    position += delimiterLength - 1
                    return
                }
                if scalar == delimiter {
                    endField()
                    return
                }
            }
        }
        // `trim: true`: leading trim characters of an unquoted field are
        // skipped, and after a closing quote only trim characters may follow.
        let keepsLeading = quoting || !field.isEmpty || !JavaScriptText.isWhitespace(scalar)
        if keepsLeading, !wasQuoting {
            field.append(scalar)
        } else if !JavaScriptText.isWhitespace(scalar) {
            throw TransactionCSVParser.ParseError.textAfterClosingQuote(line: line)
        } else if keepsLeading, UTF8.width(scalar) > 1 {
            // csv-parse steps over a trim character byte by byte here (it
            // skips the whole sequence only while the field is empty), so the
            // second byte of a multi-byte one, such as NBSP, is not a trim
            // byte and the file is refused.
            throw TransactionCSVParser.ParseError.textAfterClosingQuote(line: line)
        }
    }

    /// `__autoDiscoverRecordDelimiter`: `\r\n`, then `\n`, then `\r`.
    private mutating func discoverRecordDelimiter(at index: Int) {
        guard index < scalars.count else { return }
        if scalars[index] == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" {
            recordDelimiter = ["\r", "\n"]
        } else if scalars[index] == "\n" {
            recordDelimiter = ["\n"]
        } else if scalars[index] == "\r" {
            recordDelimiter = ["\r"]
        }
    }

    /// After a closing quote, an undiscovered record delimiter is discovered
    /// here, as csv-parse does.
    private mutating func isRecordDelimiterAfterQuote(at index: Int) -> Bool {
        if recordDelimiter.isEmpty {
            discoverRecordDelimiter(at: index)
            return !recordDelimiter.isEmpty && recordDelimiterLength(at: index) > 0
        }
        return recordDelimiterLength(at: index) > 0
    }

    private func recordDelimiterLength(at index: Int) -> Int {
        guard !recordDelimiter.isEmpty, index + recordDelimiter.count <= scalars.count else { return 0 }
        return scalars[index..<(index + recordDelimiter.count)].elementsEqual(recordDelimiter) ? recordDelimiter.count : 0
    }

    /// `__onField`: an unquoted field loses trailing whitespace
    /// (`trimRight`).
    private mutating func endField() {
        var value = field[...]
        if !wasQuoting {
            while let last = value.last, JavaScriptText.isWhitespace(last) {
                value = value.dropLast()
            }
        }
        record.append(JavaScriptText.string(value))
        field = []
        wasQuoting = false
    }

    private mutating func endRecord() {
        records.append(record)
        record = []
    }
}
