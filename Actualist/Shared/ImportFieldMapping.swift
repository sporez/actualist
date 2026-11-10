import Foundation

/// One parsed file row as Actual's import modal sees it. `csv-parse` with
/// `columns: true` defines one property per header (a repeated header keeps
/// its first position and its last value; `__proto__` is an ordinary key),
/// and a headerless file gives an array keyed `"0"`, `"1"`, …
/// `Object.entries` lists integer-like keys first, ascending, then the rest
/// in insertion order.
struct ImportSourceRow: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let key: String
        let value: String
    }

    /// In `Object.entries` order.
    let entries: [Entry]

    /// `transaction[key]`, own properties only.
    func value(_ key: String) -> String? {
        entries.first { JavaScriptText.identical($0.key, key) }?.value
    }
}

/// A field Actual's mapping can name, with the key `applyFieldMappings`
/// writes for it.
enum ImportField: String, CaseIterable, Sendable {
    case date, amount, payee, notes, inOut, category, outflow, inflow

    var transactionKey: String { self == .payee ? "payee_name" : rawValue }
}

/// One value of Actual's mapping object: `null`, or a property key with its
/// JS truthiness. `applyFieldMappings` reads `transaction[target || field]`,
/// so a falsy key (`""`, `0`) falls back to the field's own name, while the
/// date-format guess (`mappings.date == null`) still uses it.
enum ImportMappingTarget: Equatable, Sendable {
    case null
    case key(String, isTruthy: Bool)

    static func column(_ name: String) -> ImportMappingTarget {
        .key(name, isTruthy: !name.isEmpty)
    }
}

/// Actual's column mapping. A field missing from `targets` is missing from
/// the mapping object, so `applyFieldMappings` leaves it undefined.
struct ImportFieldMapping: Equatable, Sendable {
    var targets: [ImportField: ImportMappingTarget]

    init(_ targets: [ImportField: ImportMappingTarget] = [:]) {
        self.targets = targets
    }

    /// `!!(mappings.outflow || mappings.inflow)`: separate outflow and
    /// inflow columns.
    var isSplit: Bool {
        [ImportField.outflow, .inflow].contains { field in
            if case .key(_, true) = targets[field] { return true }
            return false
        }
    }

    /// The key `transaction[mappings.date]` reads when `mappings.date` is
    /// neither null nor missing.
    var dateLookupKey: String? {
        if case .key(let key, _) = targets[.date] { return key }
        return nil
    }
}

/// A row after `applyFieldMappings`: each field's raw text, or `nil` for JS
/// `undefined`.
struct MappedImportRow: Equatable, Sendable {
    var date: String?
    var amount: String?
    var payeeName: String?
    var notes: String?
    var inOut: String?
    var category: String?
    var outflow: String?
    var inflow: String?
}

/// Ports of the import modal's column handling (pinned Actual v26.11.0):
/// `getInitialMappings` (`ImportTransactionsModal.tsx`), `applyFieldMappings`
/// and `parseCategoryFields` (`utils.ts`). The `file-import` oracle replays
/// each one.
enum ImportFieldMappingRules {
    /// The records `parseFile` returns, in their `Object.entries` order.
    static func records(from table: TransactionCSVParser.Table) -> [ImportSourceRow] {
        table.rows.map { fields in
            guard let headers = table.headers else {
                return ImportSourceRow(entries: fields.enumerated().map {
                    ImportSourceRow.Entry(key: String($0.offset), value: $0.element)
                })
            }
            var entries: [ImportSourceRow.Entry] = []
            for (index, field) in fields.enumerated() where index < headers.count {
                set(headers[index], to: field, in: &entries)
            }
            let indexed = entries.compactMap { entry in arrayIndex(entry.key).map { (entry, $0) } }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
            return ImportSourceRow(entries: indexed + entries.filter { arrayIndex($0.key) == nil })
        }
    }

    /// Those records after the modal's `parse` step: it sets `trx_id` to the
    /// row index (replacing a file column of that name; otherwise the last
    /// key) and `selected` to `true`, a boolean, so a file column named
    /// `selected` no longer reads as text.
    static func sourceRows(from table: TransactionCSVParser.Table) -> [ImportSourceRow] {
        records(from: table).enumerated().map { rowIndex, record in
            var entries = record.entries
            set("trx_id", to: String(rowIndex), in: &entries)
            entries.removeAll { JavaScriptText.identical($0.key, "selected") }
            return ImportSourceRow(entries: entries)
        }
    }

    /// `Object.defineProperty(obj, key, …)`: an existing key keeps its
    /// position and takes the new value.
    private static func set(_ key: String, to value: String, in entries: inout [ImportSourceRow.Entry]) {
        if let existing = entries.firstIndex(where: { JavaScriptText.identical($0.key, key) }) {
            entries[existing] = ImportSourceRow.Entry(key: entries[existing].key, value: value)
        } else {
            entries.append(ImportSourceRow.Entry(key: key, value: value))
        }
    }

    /// Keys the modal adds to or removes from each row before guessing
    /// (`stripCsvImportTransaction`).
    private static let previewKeys: [String] = [
        "existing", "ignored", "selected", "selected_merge", "trx_id", "tombstone",
    ]

    /// `getInitialMappings`: guesses each field's column from the first row,
    /// by header name and then by value shape. `nil` for no rows (`{}`).
    static func initialMappings(_ rows: [ImportSourceRow]) -> ImportFieldMapping? {
        guard let first = rows.first else { return nil }
        let fields = first.entries.filter { entry in
            !previewKeys.contains { JavaScriptText.identical($0, entry.key) }
        }
        func named(_ needle: String) -> String? {
            fields.first { JavaScriptText.lowercasedContains($0.key, asciiNeedle: needle) }?.key
        }
        func firstKey(excluding excluded: [String?]) -> String? {
            fields.first { field in
                !excluded.contains { $0.map { JavaScriptText.identical($0, field.key) } ?? false }
            }?.key
        }
        let date = named("date") ?? fields.first { looksLikeDate($0.value) }?.key
        let amount = named("amount") ?? fields.first { looksLikeAmount($0.value) }?.key
        let category = named("category")
        let payee = named("payee") ?? firstKey(excluding: [date, amount, category])
        let notes = named("notes") ?? firstKey(excluding: [date, amount, category, payee])
        let inOut = firstKey(excluding: [date, amount, payee, notes])
        func target(_ key: String?) -> ImportMappingTarget { key.map(ImportMappingTarget.column) ?? .null }
        return ImportFieldMapping([
            .date: target(date), .amount: target(amount), .payee: target(payee),
            .notes: target(notes), .inOut: target(inOut), .category: target(category),
        ])
    }

    /// `applyFieldMappings`: `transaction[target || field]` for each field in
    /// the mapping, so a null or falsy target reads the column named like the
    /// field itself, and a field missing from the mapping stays undefined.
    static func apply(_ mapping: ImportFieldMapping, to row: ImportSourceRow) -> MappedImportRow {
        func read(_ field: ImportField) -> String? {
            switch mapping.targets[field] {
            case nil:
                return nil
            case .key(let key, true):
                return row.value(key)
            case .null, .key(_, false):
                return row.value(field.transactionKey)
            }
        }
        return MappedImportRow(
            date: read(.date),
            amount: read(.amount),
            payeeName: read(.payee),
            notes: read(.notes),
            inOut: read(.inOut),
            category: read(.category),
            outflow: read(.outflow),
            inflow: read(.inflow)
        )
    }

    /// `getInitialDateFormat(transactions, mappings)`.
    static func initialDateFormat(_ rows: [ImportSourceRow], mapping: ImportFieldMapping) -> ImportDateFormat {
        ImportDateParsing.initialDateFormat(
            rowCount: rows.count,
            firstDateValue: mapping.dateLookupKey.flatMap { rows.first?.value($0) },
            hasDateColumn: mapping.dateLookupKey != nil
        )
    }

    /// `/^\d+[-/]\d+[-/]\d+$/`
    private static func looksLikeDate(_ value: String) -> Bool {
        var groups = 0
        var digitsInGroup = 0
        for scalar in value.unicodeScalars {
            if JavaScriptText.isDigit(scalar) {
                digitsInGroup += 1
            } else if (scalar == "-" || scalar == "/"), digitsInGroup > 0, groups < 2 {
                groups += 1
                digitsInGroup = 0
            } else {
                return false
            }
        }
        return groups == 2 && digitsInGroup > 0
    }

    /// `/^-?[.,\d]+$/`
    private static func looksLikeAmount(_ value: String) -> Bool {
        var scalars = Substring(value).unicodeScalars[...]
        if scalars.first == "-" { scalars = scalars.dropFirst() }
        return !scalars.isEmpty && scalars.allSatisfy { JavaScriptText.isDigit($0) || $0 == "." || $0 == "," }
    }

    /// A canonical array index (`"0"`, or no leading zero, below 2^32 − 1).
    private static func arrayIndex(_ key: String) -> UInt64? {
        let scalars = Array(key.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 10, scalars.allSatisfy(JavaScriptText.isDigit),
              scalars.count == 1 || scalars[0] != "0",
              let value = UInt64(key), value < 4_294_967_295 else {
            return nil
        }
        return value
    }
}

/// `parseCategoryFields`: the first category, in Actual's category list
/// order, whose name equals the text exactly (case-sensitive) and whose id
/// does not.
struct ImportCategoryMatcher: Sendable {
    struct Category: Equatable, Sendable {
        let id: String
        let name: String
    }

    private let idsByName: [[UInt32]: [String]]

    /// `categories` in Actual's `useCategories().list` order.
    init(categories: [Category]) {
        var idsByName: [[UInt32]: [String]] = [:]
        for category in categories {
            idsByName[JavaScriptText.exactKey(category.name), default: []].append(category.id)
        }
        self.idsByName = idsByName
    }

    func categoryID(forText text: String?) -> String? {
        guard let text else { return nil }
        return idsByName[JavaScriptText.exactKey(text)]?.first { !JavaScriptText.identical($0, text) }
    }
}
