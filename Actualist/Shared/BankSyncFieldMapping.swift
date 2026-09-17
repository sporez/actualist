import Foundation

/// Constrained raw provider values preserved through SimpleFIN transport so
/// per-account custom mappings can resolve arbitrary configured field names.
/// Nested objects stay nested; `extra` is flattened one level by
/// `SimpleFINRawFields` so SimpleFIN extra keys are mappable.
enum SimpleFINRawValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case number(Double)
    case bool(Bool)
    case object([String: SimpleFINRawValue])
    case array([SimpleFINRawValue])
    case null

    /// Scalar lookup used by custom mapping. Objects and arrays are not
    /// stringified — those keys cannot be date/payee/notes sources.
    var scalarString: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .number(let value):
            if value.rounded() == value, let exact = Int64(exactly: value) {
                return String(exact)
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object, .array, .null:
            return nil
        }
    }

    var unixSeconds: Int64? {
        switch self {
        case .int(let value):
            return value
        case .number(let value):
            return Int64(value)
        case .string(let value):
            if let intValue = Int64(value) {
                return intValue
            }
            if let doubleValue = Double(value) {
                return Int64(doubleValue)
            }
            return FlexibleUnixSeconds.unixSeconds(fromDay: value)
        case .bool, .object, .array, .null:
            return nil
        }
    }
}

extension SimpleFINRawValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: SimpleFINRawValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SimpleFINRawValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }
}

/// Top-level provider fields plus flattened `extra` keys. Canonical aliases
/// (`date`, `payeeName`, `notes`) are seeded at mapping time, not here, so a
/// custom mapping can still point at a different source for those fields.
struct SimpleFINRawFields: Equatable, Sendable {
    var values: [String: SimpleFINRawValue]

    init(_ values: [String: SimpleFINRawValue] = [:]) {
        var values = values
        if case .object(let extra) = values["extra"] {
            for (key, value) in extra where values[key] == nil {
                values[key] = value
            }
        }
        self.values = values
    }

    subscript(_ key: String) -> SimpleFINRawValue? {
        values[key]
    }
}

extension SimpleFINRawFields: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values: [String: SimpleFINRawValue] = [:]
        values.reserveCapacity(container.allKeys.count)
        for key in container.allKeys {
            values[key.stringValue] = try container.decodeIfPresent(
                SimpleFINRawValue.self,
                forKey: key
            ) ?? .null
        }
        self.init(values)
    }
}

/// Actual `custom-sync-mapping.ts` for Bank Sync downloads. Parse failures
/// are configuration errors; callers fail the account rather than defaulting.
enum BankSyncFieldMapping {
    struct Mappings: Equatable, Sendable {
        var payment: [String: String]?
        var deposit: [String: String]?

        static let defaults = Mappings(
            payment: ["date": "date", "payee": "payeeName", "notes": "notes"],
            deposit: ["date": "date", "payee": "payeeName", "notes": "notes"]
        )

        func side(forAmountMinorUnits amount: Int) -> [String: String]? {
            amount <= 0 ? payment : deposit
        }
    }

    struct Resolved: Equatable, Sendable {
        var dateUnixSeconds: Int64?
        var payeeName: String?
        var notes: String?
    }

    enum ParseError: Error, Equatable {
        case invalid
    }

    /// Actual `mappingsFromString` throws on invalid JSON. Non-object roots,
    /// non-object sides, and non-string field values also fail closed.
    static func parse(_ json: String) throws -> Mappings {
        guard let data = json.data(using: .utf8) else {
            throw ParseError.invalid
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError.invalid
        }
        guard let root = object as? [String: Any] else {
            throw ParseError.invalid
        }
        func side(_ key: String) throws -> [String: String]? {
            guard let raw = root[key] else { return nil }
            guard let inner = raw as? [String: Any] else {
                throw ParseError.invalid
            }
            var mapped: [String: String] = [:]
            for (field, value) in inner {
                guard let string = value as? String else {
                    throw ParseError.invalid
                }
                mapped[field] = string
            }
            return mapped
        }
        return Mappings(
            payment: try side("payment"),
            deposit: try side("deposit")
        )
    }

    /// loot-core `normalizeBankSyncTransactions` mapping:
    /// `date` / `payee` fall back to canonical fields; `notes` does not.
    /// Hash escaping applies only to imported provider notes that survive
    /// `sync-import-notes-*`.
    static func resolve(
        transaction: SimpleFINRemoteTransaction,
        amountMinorUnits: Int,
        mappings: Mappings,
        importNotes: Bool
    ) -> Resolved? {
        guard let side = mappings.side(forAmountMinorUnits: amountMinorUnits) else {
            return nil
        }
        var raw = transaction.rawFields.values
        if raw["date"] == nil, let seconds = transaction.dateUnixSeconds {
            raw["date"] = .int(seconds)
        }
        if raw["payeeName"] == nil, let name = transaction.payeeName {
            raw["payeeName"] = .string(name)
        }
        if raw["notes"] == nil, let notes = transaction.notes {
            raw["notes"] = .string(notes)
        }

        let dateUnixSeconds = side["date"].flatMap { raw[$0]?.unixSeconds }
            ?? transaction.dateUnixSeconds
        let payeeName = side["payee"].flatMap { raw[$0]?.scalarString }
            ?? transaction.payeeName
        let mappedNotes = side["notes"].flatMap { raw[$0]?.scalarString }
        let notes: String?
        if importNotes, let mappedNotes {
            let escaped = BankSyncReconciliation.escapedNotes(mappedNotes)
            notes = escaped.isEmpty ? nil : escaped
        } else {
            notes = nil
        }
        return Resolved(
            dateUnixSeconds: dateUnixSeconds,
            payeeName: payeeName,
            notes: notes
        )
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
