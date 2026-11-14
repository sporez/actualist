import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import Actualist

/// Table digest of a budget database in the form `scripts/parity/lib/table-digest.mjs` writes: every
/// table's live rows (`tombstone = 0` where the column exists), all columns, as one canonical JSON
/// line per row. Engine bookkeeping that differs between copies of one budget is left out.
struct PortableTableDigest {
    /// Table name to its canonical row lines, sorted.
    let tables: [String: [String]]

    /// The tables `table-digest.mjs` only counts: `messages_*`, `kvcache*`, `sqlite_*`, `actualist_*`.
    private static func isExcluded(_ name: String) -> Bool {
        ["messages_crdt", "messages_clock", "messages_pending", "kvcache", "kvcache_key"].contains(name)
            || name.hasPrefix("sqlite_") || name.hasPrefix("actualist_")
    }

    init(fixture digest: [String: Any]) throws {
        let tables = try OracleJSON.object(digest["tables"], "digest.tables")
        self.tables = try tables.mapValues { table in
            let lines = try OracleJSON.object(table, "digest table")["lines"] as? [String]
            return try #require(lines).sorted()
        }
    }

    init(databaseAt url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        tables = try queue.read { db in
            var tables: [String: [String]] = [:]
            // Listing every table has no Canonical Owner: SQLiteSchema answers per-table questions.
            for name in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            where !Self.isExcluded(name) {
                let live = try SQLiteSchema.columns(of: name, in: db).contains("tombstone") ? " WHERE tombstone = 0" : ""
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(name.quotedDatabaseIdentifier)\(live)")
                tables[name] = try rows.map(Self.line).sorted()
            }
            return tables
        }
    }

    /// `JSON.stringify(sorted [key, value] pairs)` as the Node digest writes it.
    private static func line(_ row: Row) throws -> String {
        let pairs = try row.columnNames.sorted().map { column -> String in
            let value: DatabaseValue = row[column]
            return "[\(jsonString(column)),\(try jsonValue(value))]"
        }
        return "[\(pairs.joined(separator: ","))]"
    }

    private static func jsonValue(_ value: DatabaseValue) throws -> String {
        switch value.storage {
        case .null: return "null"
        case .int64(let integer): return String(integer)
        case .double(let double):
            // sqlite3 -json prints 3.0 and JSON.parse/stringify turns it back into 3.
            return double.rounded() == double && abs(double) < 1e15 ? String(Int64(double)) : "\(double)"
        case .string(let text): return jsonString(text)
        case .blob: throw PortableArchiveReplayError.blobCell
        }
    }

    /// JSON.stringify's escaping: quotes, backslash and control characters only.
    private static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// One problem per difference: a missing or extra table, or per row the columns that differ
    /// (rows are matched by `id`, else by their whole line), as `table.column [id]: expected, actual`.
    func differences(from expected: PortableTableDigest, expectedName: String, actualName: String) -> [String] {
        var problems: [String] = []
        for name in Set(expected.tables.keys).union(tables.keys).sorted() {
            guard let want = expected.tables[name] else { problems.append("\(name): only in \(actualName)"); continue }
            guard let have = tables[name] else { problems.append("\(name): only in \(expectedName)"); continue }
            if want == have { continue }
            let wantRows = Self.rows(want)
            let haveRows = Self.rows(have)
            for key in Set(wantRows.keys).union(haveRows.keys).sorted() {
                switch (wantRows[key], haveRows[key]) {
                case (let left?, let right?):
                    for column in Set(left.keys).union(right.keys).sorted() where left[column] != right[column] {
                        problems.append("\(name).\(column) [\(key)]: \(expectedName) \(left[column] ?? "absent"), \(actualName) \(right[column] ?? "absent")")
                    }
                case (let left?, nil):
                    problems.append("\(name) [\(key)]: only in \(expectedName): \(left)")
                case (nil, let right?):
                    problems.append("\(name) [\(key)]: only in \(actualName): \(right)")
                case (nil, nil): break
                }
            }
        }
        return problems
    }

    private static func rows(_ lines: [String]) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for line in lines {
            // Lines are `[["column",value],...]`; the value text is compared as written.
            guard let data = line.data(using: .utf8),
                  let pairs = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { continue }
            var row: [String: String] = [:]
            for pair in pairs {
                guard let column = pair.first as? String else { continue }
                let value = pair.last.map { "\($0)" } ?? "null"
                row[column] = value
            }
            out[row["id"] ?? line, default: [:]] = row
        }
        return out
    }
}

enum PortableArchiveReplayError: Error {
    case blobCell
    case missingFile(String)
}

/// Imports and exports through the production portable code, without a server. Used by
/// `PortableArchiveOracleReplayTests`; the compared parts are documented in
/// `scripts/portable-archive-parity/README.md`.
@MainActor
enum PortableArchiveOracleReplay {
    static let domain = "PortableArchive"

    static func fixtureURL(_ name: String) throws -> URL {
        let url = try ParityOraclePin.fixtureURL(domain).appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PortableArchiveReplayError.missingFile(url.path)
        }
        return url
    }

    static func fixtureJSON(_ name: String) throws -> [String: Any] {
        try OracleJSON.object(OracleJSONFileCache.jsonObject(at: try fixtureURL(name)), name)
    }

    struct Imported {
        let bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle
        let creation: NewBudgetCreation
        var groupID: String { creation.groupID ?? "" }
    }

    /// The production import path (`importPortableBudget`: validate, sync reset, install, register)
    /// with an accepting registration transport instead of a server, then the open the app does.
    static func importArchive(at archiveURL: URL) async throws -> Imported {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let creation = try await bundle.store.importPortableBudget(
            archiveAt: archiveURL,
            serverURLString: "https://sync.example",
            token: "token",
            registrationTransport: PortableBudgetImportSyncResetTests.AcceptingRegistrationTransport(),
            identityGenerator: { "imported-file" }
        )
        let metadata = try #require(try bundle.fileManager.loadMetadata(fileID: creation.fileID))
        try await bundle.store.openImportedBudget(fileID: creation.fileID, metadata: metadata)
        return Imported(bundle: bundle, creation: creation)
    }

    static func digest(of imported: Imported) throws -> PortableTableDigest {
        try PortableTableDigest(databaseAt: try imported.bundle.fileManager.databaseURL(fileID: imported.creation.fileID))
    }

    /// The Accounts screen's balance per account id (all accounts, closed included).
    static func balances(of imported: Imported) async throws -> [String: Int] {
        try await imported.bundle.store.refreshAccountsWithBalances(budgetID: imported.groupID)
        return Dictionary(
            uniqueKeysWithValues: imported.bundle.store.accountDisplays(budgetID: imported.groupID)
                .map { ($0.id, $0.balance ?? Int.min) }
        )
    }

    /// Actualist's production export of the open imported budget.
    static func export(_ imported: Imported) async throws -> URL {
        imported.bundle.store.portableExportFiles = PortableExportFiles(
            temporaryDirectory: FileManager.default.temporaryDirectory
                .appending(path: "PortableArchiveReplay-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
        return try await imported.bundle.store.exportPortableBudgetArchive(budgetID: imported.groupID)
    }

    /// The database exactly as written in the ZIP, before any open.
    static func databaseURL(inArchive archiveURL: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PortableArchiveReplay-unzip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let entry = try #require(archive["db.sqlite"])
        let target = directory.appending(path: "db.sqlite")
        _ = try archive.extract(entry, to: target)
        return target
    }
}
