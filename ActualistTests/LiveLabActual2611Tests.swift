import Foundation
import GRDB
import Testing
@testable import Actualist

/// Opt-in live check of the Actual v26.11.0 parity fixes against the disposable
/// lab server and a real Actual client (the Node peer in
/// `scripts/parity/live-lab-interop/`, steps `v2611Seed` and `v2611Check`). Order:
/// `v2611Prepare()`, `run.sh v2611Seed`, `v2611Actualist()`, `v2611ClockDrift()`,
/// `run.sh v2611Check`. Needs the `LiveLab` variables and `ACTUAL_LAB_V2611=1`.
@Suite(.serialized, .enabled(if: LiveLab.isConfigured && ProcessInfo.processInfo.environment["ACTUAL_LAB_V2611"] == "1"))
@MainActor
struct LiveLabActual2611Tests {
    private func makeSignedInStore() async throws -> LocalFirstActualStore {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LiveLab2611-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = LiveLab.makeStore(root: root)
        _ = try await LiveLab.signIn(store)
        return store
    }

    private func createAndOpen(_ label: String, in store: LocalFirstActualStore) async throws -> (fileID: String, budget: ActualBudget) {
        let serverURL = try #require(LiveLab.url)
        let name = "Interop Check v2611 \(label) \(UUID().uuidString.prefix(6))"
        let creation = try await store.createNewBudget(named: name, serverURLString: serverURL)
        return (creation.fileID, try await open(creation.fileID, in: store))
    }

    private func open(_ fileID: String, in store: LocalFirstActualStore) async throws -> ActualBudget {
        let serverURL = try #require(LiveLab.url)
        let budget = try #require(try await store.loadBudgets(serverURLString: serverURL).first { $0.cloudFileId == fileID })
        try await store.openBudget(budget, serverURLString: serverURL)
        return budget
    }

    private func refresh(_ store: LocalFirstActualStore, _ budget: ActualBudget) async -> Error? {
        do {
            try await store.refresh(budgetID: budget.syncID, serverURLString: try #require(LiveLab.url))
            return nil
        } catch {
            return error
        }
    }

    private func dayMarker(_ database: BudgetDatabase) async -> String? {
        let url = await database.databaseURL.deletingLastPathComponent().appending(path: "metadata.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["lastScheduleRun"] as? String
    }

    // MARK: Main budget

    @Test func v2611Prepare() async throws {
        let store = try await makeSignedInStore()
        let (fileID, _) = try await createAndOpen("main", in: store)
        try LiveLab.writeHandoff("v2611.json", ["fileID": fileID])
    }

    @Test func v2611Actualist() async throws {
        let fileID = try #require(try LiveLab.readHandoff("v2611.json")["fileID"] as? String)
        let seed = try LiveLab.readHandoff("v2611-seed.json")
        let store = try await makeSignedInStore()
        let budget = try await open(fileID, in: store)
        #expect(await refresh(store, budget) == nil)
        let database = try store.requireDatabase(for: budget.syncID)
        let checkingID = try #require(seed["checkingID"] as? String)
        let today = ActualDateOnly.today()
        var result: [String: Any] = [:]

        // OP-88: the formula rule's split amounts, against Actual's own `rules-run`.
        let preview = try await store.previewRules(
            for: TransactionDraft(
                accountID: checkingID,
                date: try #require(ActualDateOnly.date(from: today, timeZone: .autoupdatingCurrent)),
                amountMinorUnits: -10_000, payeeID: nil, payeeName: "", categoryID: nil,
                notes: "Formula Check", cleared: false, isTransfer: false
            ),
            budgetID: budget.syncID
        )
        let formulaSplits = preview.splits.map(\.amountMinorUnits)
        result["formulaSplits"] = formulaSplits
        #expect(formulaSplits == seed["formulaSplits"] as? [Int])

        // OP-89: which stored row an equal-distance import matches, against Actual's dry-run import.
        let tiesID = try #require(seed["tiesID"] as? String)
        let tieDay = try #require(seed["tieDay"] as? String)
        let csv = "Date,Payee,Notes,Amount\n"
            + ["-25.00", "-35.00", "-45.00"].map { "\(tieDay),Interop Import,,\($0)" }.joined(separator: "\n") + "\n"
        let review = try await store.prepareTransactionCSVImport(TransactionCSVImportPreparationRequest(
            budgetID: budget.syncID, accountID: tiesID, data: Data(csv.utf8)
        ))
        var tieMatches: [String: String] = [:]
        for row in review.rows {
            if case .update(_, let existing) = row.outcome {
                tieMatches[String(row.row.amountMinorUnits)] = existing.id
            }
        }
        result["tieMatches"] = tieMatches
        #expect(tieMatches == seed["tieMatches"] as? [String: String])

        // OP-90: convert Actual's future split transaction; the peer posts the schedule.
        let splitParentID = try #require(seed["splitParentID"] as? String)
        let conversion = try await store.convertFutureTransaction(
            review: try await store.scheduleConversionReview(
                budgetID: budget.syncID, transactionID: splitParentID, asOfDayID: today
            )
        )
        result["convertedScheduleID"] = conversion.scheduleID
        #expect(await refresh(store, budget) == nil)

        // Same-day auto-post: after today's run, a new posting schedule due today still posts.
        result["markerBeforeCreate"] = await dayMarker(database) ?? NSNull()
        #expect(await dayMarker(database) == today)
        let identity = ScheduleCreateIdentity.make()
        _ = try await store.createSchedule(
            ScheduleCreateCommand(
                budgetID: budget.syncID,
                identity: identity,
                name: "Interop Same Day",
                definition: ScheduleDefinitionDraft(
                    accountID: checkingID, payeeMappingID: nil, amount: .exact(-1_234),
                    dateRule: .oneTime(dayID: today, operation: "is")
                ),
                postsTransaction: true,
                customUpcomingLength: nil,
                asOfDayID: today
            ),
            context: try store.scheduleMutationSessionContext(budgetID: budget.syncID)
        )
        result["markerAfterCreate"] = await dayMarker(database) ?? NSNull()
        let postedQuery = "SELECT COUNT(*) FROM transactions WHERE schedule = ? AND tombstone = 0"
        let queue = await database.queue
        result["postedBeforeRefresh"] = try await queue.read { try Int.fetchOne($0, sql: postedQuery, arguments: [identity.scheduleID]) ?? 0 }
        #expect(await refresh(store, budget) == nil)
        let posted = try await queue.read { try Int.fetchOne($0, sql: postedQuery, arguments: [identity.scheduleID]) ?? 0 }
        result["sameDayScheduleID"] = identity.scheduleID
        result["sameDayPosted"] = posted
        result["today"] = today
        #expect(posted == 1)
        // Automatic posting runs after a sync's pull, as Actual's sync listener does, so the posted
        // row uploads with the next sync.
        result["pendingAfterPostingSync"] = try await database.pendingLocalSyncMessageCount()
        #expect(await refresh(store, budget) == nil)
        #expect(try await database.pendingLocalSyncMessageCount() == 0)

        try LiveLab.writeHandoff("v2611-actualist.json", result)
    }

    // MARK: Server timestamp validation

    private func commitPayee(_ name: String, now: Date, to database: BudgetDatabase) async throws {
        _ = try await database.commitLocalSyncMessagesAndEnqueue([
            ActualSyncDecodedMessage(
                timestamp: "pending", dataset: "payees", row: UUID().uuidString, column: "name",
                serializedValue: "S:\(name)"
            )
        ], now: now)
    }

    /// A device clock ten minutes fast mints changes the server refuses; four minutes fast is
    /// inside the five-minute allowance. Each runs on its own budget, since the refused change
    /// stays queued.
    @Test func v2611ClockDrift() async throws {
        let store = try await makeSignedInStore()
        var result: [String: Any] = [:]

        let (farFileID, far) = try await createAndOpen("drift-far", in: store)
        let farDatabase = try store.requireDatabase(for: far.syncID)
        try await commitPayee("Drift Future", now: Date().addingTimeInterval(10 * 60), to: farDatabase)
        let farError = await refresh(store, far)
        result["farFileID"] = farFileID
        result["farError"] = farError.map { String(describing: $0) } ?? NSNull()
        #expect((farError as? LocalFirstError) == .clockDrift)
        #expect(store.syncStatus(budgetID: far.syncID)?.lastError == LocalFirstError.clockDrift.localizedDescription)
        // The refused change stays queued, and nothing else was lost.
        #expect(try await farDatabase.pendingLocalSyncMessageCount() == 1)

        let (nearFileID, near) = try await createAndOpen("drift-near", in: store)
        let nearDatabase = try store.requireDatabase(for: near.syncID)
        try await commitPayee("Drift Near", now: Date().addingTimeInterval(4 * 60), to: nearDatabase)
        let nearError = await refresh(store, near)
        result["nearFileID"] = nearFileID
        result["nearError"] = nearError.map { String(describing: $0) } ?? NSNull()
        #expect(nearError == nil)
        #expect(try await nearDatabase.pendingLocalSyncMessageCount() == 0)

        // A timestamp the server cannot parse, sent raw through the production sync client.
        let token = try #require(try store.keychain.readActualSyncToken())
        let labURL = try #require(LiveLab.url)
        let transport = ActualServerSyncClient(baseURL: try #require(URL(string: labURL)))
        do {
            _ = try await store.syncClient.pushAndPull(
                database: nearDatabase,
                client: transport,
                token: token,
                messages: [ActualSyncDecodedMessage(
                    timestamp: "not-a-timestamp", dataset: "payees", row: UUID().uuidString, column: "name",
                    serializedValue: "S:Drift Unreadable"
                )],
                sessionIsCurrent: { true }
            )
            result["invalidError"] = NSNull()
            Issue.record("the server accepted an unreadable timestamp")
        } catch {
            result["invalidError"] = String(describing: error)
            guard case .syncRejected(400, .invalidTimestamp)? = error as? ActualAPIError else {
                Issue.record("expected syncRejected(400, .invalidTimestamp), got \(error)")
                try LiveLab.writeHandoff("v2611-drift.json", result)
                return
            }
        }
        try LiveLab.writeHandoff("v2611-drift.json", result)
    }
}
