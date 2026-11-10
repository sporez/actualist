import Foundation

/// Every setting a CSV import reads. `saved(preferences:accountID:fileName:)`
/// is how Actual's import modal starts (pinned v26.11.0,
/// `ImportTransactionsModal.tsx` state set-up and `parse`): from the
/// account's synced preferences, falling back to defaults and guesses.
struct ImportSettings: Equatable, Sendable {
    /// Where the column mapping comes from.
    enum MappingSource: Equatable, Sendable {
        /// No saved mapping: `getInitialMappings` guesses from the file.
        case guess
        case saved(ImportFieldMapping)
        /// The saved mapping is not JSON Actual can parse, or is `null`.
        /// Actual's modal throws while parsing and never shows the file.
        case unreadable
    }

    var delimiter = ","
    /// A `TextDecoder` label, or `auto` (`decodeCsvBytes`).
    var encoding = "auto"
    var hasHeaderRow = true
    var skipStartLines = 0
    var skipEndLines = 0
    var mapping = MappingSource.guess
    /// The saved `parse-date` value, or `nil` to guess from the first row.
    var savedDateFormat: String?
    var inOutMode = false
    var outValue = ""
    var flipAmount = false
    /// The modal's multiplier text; empty means 1. Never saved.
    var multiplier = ""

    /// The synced preference keys the modal reads for a CSV on this account.
    /// `import-notes-<account>-csv` is saved by Actual but never read (import
    /// notes always start on), so it is not here.
    static func preferenceKeys(accountID: String) -> [String] {
        [
            "csv-delimiter-\(accountID)", "csv-encoding-\(accountID)", "csv-has-header-\(accountID)",
            "csv-skip-start-lines-\(accountID)", "csv-skip-end-lines-\(accountID)",
            "csv-in-out-mode-\(accountID)", "csv-out-value-\(accountID)",
            "csv-mappings-\(accountID)", "parse-date-\(accountID)-csv", "flip-amount-\(accountID)-csv",
        ]
    }

    /// The modal's starting state from the account's synced preferences
    /// (values as Actual stores them: strings, or absent).
    static func saved(preferences: [String: String], accountID: String, fileName: String) -> ImportSettings {
        func pref(_ key: String) -> String? { preferences[key] }
        // `prefs[key] || fallback`: an empty string falls back too.
        func truthy(_ key: String) -> String? { pref(key).flatMap { $0.isEmpty ? nil : $0 } }
        var settings = ImportSettings()
        // `filename.endsWith('.tsv')` is case-sensitive.
        settings.delimiter = truthy("csv-delimiter-\(accountID)") ?? (fileName.hasSuffix(".tsv") ? "\t" : ",")
        settings.encoding = truthy("csv-encoding-\(accountID)") ?? "auto"
        // `parseInt(pref, 10) || 0`; parseFile clamps negatives later.
        settings.skipStartLines = pref("csv-skip-start-lines-\(accountID)").flatMap(JavaScriptText.parseInt) ?? 0
        settings.skipEndLines = pref("csv-skip-end-lines-\(accountID)").flatMap(JavaScriptText.parseInt) ?? 0
        // `String(pref) === 'true'` and `String(pref) !== 'false'`.
        settings.inOutMode = pref("csv-in-out-mode-\(accountID)") == "true"
        settings.outValue = pref("csv-out-value-\(accountID)") ?? ""
        settings.hasHeaderRow = pref("csv-has-header-\(accountID)") != "false"
        settings.flipAmount = pref("flip-amount-\(accountID)-csv") == "true"
        settings.savedDateFormat = truthy("parse-date-\(accountID)-csv")
        if let json = truthy("csv-mappings-\(accountID)") {
            settings.mapping = mappingSource(json: json)
        }
        return settings
    }

    /// The date format the import uses: the saved one when set (an unknown
    /// value is `null`, which `parseDate` reads as `mm dd yyyy`), else the
    /// guess from the first row.
    func dateFormat(guessing guess: () -> ImportDateFormat) -> ImportDateFormat {
        guard let savedDateFormat else { return guess() }
        return ImportDateFormat(rawValue: savedDateFormat) ?? .mmDDyyyy
    }

    /// `JSON.parse(pref)`. Only `null` (and invalid JSON) breaks Actual's
    /// modal; any other non-object reads like a mapping with no fields.
    private static func mappingSource(json: String) -> MappingSource {
        guard let value = JavaScriptJSONValue.parse(json) else {
            return .unreadable
        }
        switch value {
        case .null:
            return .unreadable
        case .object(let members):
            var targets: [ImportField: ImportMappingTarget] = [:]
            for field in ImportField.allCases {
                guard let member = members[field.rawValue] else { continue }
                targets[field] = member.mappingTarget
            }
            return .saved(ImportFieldMapping(targets))
        case .bool, .number, .string, .array:
            return .saved(ImportFieldMapping())
        }
    }
}

extension JavaScriptJSONValue {
    /// A mapping value as a property key (`String(value)`) with its JS
    /// truthiness.
    var mappingTarget: ImportMappingTarget {
        switch self {
        case .null:
            return .null
        case .bool(let value):
            return .key(value ? "true" : "false", isTruthy: value)
        case .number(let value):
            return .key(JavaScriptText.numberToString(value), isTruthy: value != 0 && !value.isNaN)
        case .string(let value):
            return .column(value)
        case .array(let values):
            // `String([a, b])` joins with commas; an array is always truthy.
            return .key(values.map(\.arrayElementString).joined(separator: ","), isTruthy: true)
        case .object:
            return .key("[object Object]", isTruthy: true)
        }
    }

    private var arrayElementString: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return JavaScriptText.numberToString(value)
        case .string(let value): return value
        case .array(let values): return values.map(\.arrayElementString).joined(separator: ",")
        case .object: return "[object Object]"
        }
    }
}
