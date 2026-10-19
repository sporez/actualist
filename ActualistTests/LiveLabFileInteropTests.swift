import Foundation
import GRDB
import Testing
@testable import Actualist

/// Opt-in ZIP and CSV interop against a disposable Actual server, driven by
/// `scripts/parity/live-lab-file-interop/run.sh`. Skipped unless the lab
/// variables are set and the Node peer has written `source.json` to the
/// handoff folder. Each test records what it did (counts, ids, errors) in a
/// handoff JSON file and copies the files it produced there; the Node peer
/// compares them with Actual's own results.
@Suite(.serialized, .enabled(if: LiveLabFileInterop.isPrepared))
struct LiveLabFileInteropTests {
    /// Phase A: open the source budget, export its ZIP and CSVs, then import
    /// Actual's own export ZIP through the production portable import.
    @MainActor
    @Test func exportFromActualistAndImportActualZip() async throws {
        let source = try LiveLab.readHandoff("source.json")
        let sourceFileID = try #require(source["fileID"] as? String)
        let csvAccounts = try LiveLabFileInterop.csvAccounts(source)
        let handoff = try #require(LiveLab.handoffDirectory)
        let serverURL = try #require(LiveLab.url)
        let root = try LiveLabFileInterop.storeRoot()
        try? FileManager.default.removeItem(at: root)
        let store = LiveLab.makeStore(root: root)
        let staged = try await LiveLab.signIn(store)
        var result: [String: Any] = [:]
        var errors: [String: String] = [:]

        do {
            let budget = try #require(staged.budgets.first { $0.cloudFileId == sourceFileID })
            try await store.openBudget(budget, serverURLString: serverURL)
            result["sourceAccounts"] = try await LiveLabFileInterop.accounts(of: store, budgetID: budget.syncID)
            try LiveLabFileInterop.snapshot(store, fileID: sourceFileID, to: "actualist-source.sqlite")

            do {
                let archive = try await store.exportPortableBudgetArchive(budgetID: budget.syncID)
                try LiveLabFileInterop.replace(handoff.appending(path: "actualist-export.zip"), with: archive)
                store.portableExportFiles.discard(archive)
            } catch {
                errors["zipExport"] = String(describing: error)
            }

            var csvExports: [[String: Any]] = []
            for account in csvAccounts {
                do {
                    let export = try await store.exportTransactionsCSV(TransactionCSVExportRequest(
                        budgetID: budget.syncID,
                        accountID: account.id,
                        query: TransactionFeedQuery()
                    ))
                    try export.data.write(to: handoff.appending(path: "actualist-\(account.key).csv"), options: .atomic)
                    csvExports.append([
                        "key": account.key,
                        "families": export.exportedFamilyCount,
                        "rows": export.exportedRowCount,
                    ])
                } catch {
                    errors["csvExport-\(account.key)"] = String(describing: error)
                }
            }
            result["csvExports"] = csvExports
        } catch {
            errors["openSource"] = String(describing: error)
        }

        do {
            let creation = try await store.importPortableBudget(
                archiveAt: handoff.appending(path: "actual-export.zip"),
                serverURLString: serverURL
            )
            // Written first so cleanup can delete the server file even if a
            // later step fails.
            try LiveLab.writeHandoff("imported.json", [
                "fileID": creation.fileID,
                "groupID": creation.groupID ?? "",
                "name": creation.budgetName,
            ])
            let budgets = try await store.loadBudgets(serverURLString: serverURL)
            let imported = try #require(budgets.first { $0.cloudFileId == creation.fileID })
            try await store.openBudget(imported, serverURLString: serverURL)
            result["importedAccounts"] = try await LiveLabFileInterop.accounts(of: store, budgetID: imported.syncID)
            try LiveLabFileInterop.snapshot(store, fileID: creation.fileID, to: "actualist-imported.sqlite")
        } catch {
            errors["zipImport"] = String(describing: error)
        }

        result["errors"] = errors
        try LiveLab.writeHandoff("swift-a.json", result)
        #expect(errors.isEmpty, "\(errors)")
    }

    /// Phase B: import Actual's CSV of each source account into a new account
    /// of the budget phase A imported, through the production prepare/apply
    /// path with every row accepted, then sync so the server copy has it.
    @MainActor
    @Test func importActualCSVIntoActualist() async throws {
        let source = try LiveLab.readHandoff("source.json")
        let csvAccounts = try LiveLabFileInterop.csvAccounts(source)
        let importedFileID = try #require(try LiveLab.readHandoff("imported.json")["fileID"] as? String)
        let handoff = try #require(LiveLab.handoffDirectory)
        let serverURL = try #require(LiveLab.url)
        let store = LiveLab.makeStore(root: try LiveLabFileInterop.storeRoot())
        let staged = try await LiveLab.signIn(store)
        let budget = try #require(staged.budgets.first { $0.cloudFileId == importedFileID })
        try await store.openBudget(budget, serverURLString: serverURL)

        var imports: [[String: Any]] = []
        var errors: [String: String] = [:]
        for account in csvAccounts {
            let name = "CSV Import \(account.key)"
            var record: [String: Any] = ["key": account.key, "accountName": name]
            do {
                try await store.createAccountAndRefresh(budgetID: budget.syncID, name: name, offbudget: account.offbudget)
                let accountID = try #require(
                    store.accountDisplays(budgetID: budget.syncID).first { $0.account.name == name }?.id
                )
                record["accountID"] = accountID
                let review = try await store.prepareTransactionCSVImport(TransactionCSVImportPreparationRequest(
                    budgetID: budget.syncID,
                    accountID: accountID,
                    data: try Data(contentsOf: handoff.appending(path: "actual-\(account.key).csv")),
                    options: TransactionCSVImportOptions()
                ))
                record["reviewRows"] = review.rows.count
                record["outcomes"] = Dictionary(grouping: review.rows, by: { "\($0.outcome.kind)" })
                    .mapValues(\.count)
                let applied = try await store.applyTransactionCSVImport(TransactionCSVImportApplyRequest(
                    budgetID: budget.syncID,
                    accountID: accountID,
                    sessionGeneration: review.sessionGeneration,
                    rows: review.rows
                ))
                record["inserted"] = applied.insertedCount
                record["updated"] = applied.updatedCount
            } catch {
                errors["csvImport-\(account.key)"] = String(describing: error)
                record["error"] = String(describing: error)
            }
            imports.append(record)
        }
        // The local result before sync, so the peer can tell import
        // differences from upload differences.
        do {
            try LiveLabFileInterop.snapshot(store, fileID: importedFileID, to: "actualist-csv.sqlite")
        } catch {
            errors["csvSnapshot"] = String(describing: error)
        }
        do {
            try await store.refresh(budgetID: budget.syncID, serverURLString: serverURL)
        } catch {
            errors["sync"] = String(describing: error)
        }
        try LiveLab.writeHandoff("swift-b.json", ["imports": imports, "errors": errors])
        #expect(errors.isEmpty, "\(errors)")
    }
}

enum LiveLabFileInterop {
    struct CSVAccount {
        let key: String
        let id: String
        let offbudget: Bool
    }

    static var isPrepared: Bool {
        guard LiveLab.isConfigured, let directory = LiveLab.handoffDirectory else { return false }
        return FileManager.default.fileExists(atPath: directory.appending(path: "source.json").path)
    }

    static func storeRoot() throws -> URL {
        try #require(LiveLab.handoffDirectory).appending(path: "swift-root", directoryHint: .isDirectory)
    }

    static func csvAccounts(_ source: [String: Any]) throws -> [CSVAccount] {
        let entries = try #require(source["csvAccounts"] as? [[String: Any]])
        return try entries.map { entry in
            CSVAccount(
                key: try #require(entry["key"] as? String),
                id: try #require(entry["id"] as? String),
                offbudget: entry["offbudget"] as? Bool ?? false
            )
        }
    }

    @MainActor
    static func accounts(of store: LocalFirstActualStore, budgetID: String) async throws -> [[String: Any]] {
        try await store.refreshAccountsWithBalances(budgetID: budgetID)
        return store.accountDisplays(budgetID: budgetID).map { display in
            [
                "id": display.account.id,
                "name": display.account.name,
                "offbudget": display.account.offbudget,
                "closed": display.account.closed,
                "balance": display.balance as Any,
            ]
        }
    }

    /// A consistent copy of the budget's local database, taken with
    /// `VACUUM INTO` so pending WAL pages are included.
    @MainActor
    static func snapshot(_ store: LocalFirstActualStore, fileID: String, to name: String) throws {
        let destination = try #require(LiveLab.handoffDirectory).appending(path: name)
        try? FileManager.default.removeItem(at: destination)
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(
            path: store.fileManager.databaseURL(fileID: fileID).path,
            configuration: configuration
        )
        try queue.inDatabase { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path])
        }
    }

    static func replace(_ destination: URL, with source: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
