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

/// Which file column feeds each transaction field. `nil` is JS `null`.
struct ImportFieldMapping: Equatable, Sendable {
    var date: String?
    var amount: String?
    var payee: String?
    var notes: String?
    var inOut: String?
    var category: String?
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
        return ImportFieldMapping(
            date: date, amount: amount, payee: payee, notes: notes, inOut: inOut, category: category
        )
    }

    /// `applyFieldMappings`: `transaction[target || field]`, so an unmapped or
    /// empty-named target reads the column named like the field itself.
    static func apply(_ mapping: ImportFieldMapping, to row: ImportSourceRow) -> MappedImportRow {
        func read(_ target: String?, _ field: String) -> String? {
            row.value(target.flatMap { $0.isEmpty ? nil : $0 } ?? field)
        }
        return MappedImportRow(
            date: read(mapping.date, "date"),
            amount: read(mapping.amount, "amount"),
            payeeName: read(mapping.payee, "payee_name"),
            notes: read(mapping.notes, "notes"),
            inOut: read(mapping.inOut, "inOut"),
            category: read(mapping.category, "category")
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
