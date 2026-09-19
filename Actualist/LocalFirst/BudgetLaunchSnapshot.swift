import Foundation

/// The materialized Budget projection used only for the first frame of a cold launch.
///
/// `schemaVersion` describes this serialized DTO. `projectionVersion` describes
/// the financial/presentation semantics that produced it. Either mismatch is a
/// cache miss; launch snapshots are never migrated.
struct BudgetLaunchSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentProjectionVersion = 1

    let schemaVersion: Int
    let projectionVersion: Int
    let revision: UInt64
    let localFileID: String
    let budgetID: String
    let groupID: String?
    let preferredCalendarMonth: String
    let displayedMonth: String
    let modeIdentity: BudgetModeIdentity
    let availableMonths: [String]
    let month: BudgetMonth
    let alerts: [BudgetMonthAlert]
    let currency: Currency
    let isTrackingBudget: Bool

    struct Currency: Codable, Equatable, Sendable {
        let code: String
        let decimalPlaces: Int
        let hideFraction: Bool

        init(_ currency: BudgetCurrency) {
            code = currency.code
            decimalPlaces = currency.decimalPlaces
            hideFraction = currency.hideFraction
        }

        var budgetCurrency: BudgetCurrency {
            BudgetCurrency(
                code: code,
                decimalPlaces: decimalPlaces,
                hideFraction: hideFraction
            )
        }
    }

    init?(
        revision: UInt64,
        localFileID: String,
        budgetID: String,
        groupID: String?,
        preferredCalendarMonth: String,
        loaded: LoadedBudgetMonth
    ) {
        guard let modeIdentity = loaded.modeIdentity else { return nil }
        schemaVersion = Self.currentSchemaVersion
        projectionVersion = Self.currentProjectionVersion
        self.revision = revision
        self.localFileID = localFileID
        self.budgetID = budgetID
        self.groupID = groupID
        self.preferredCalendarMonth = preferredCalendarMonth
        displayedMonth = loaded.selectedMonth
        self.modeIdentity = modeIdentity
        availableMonths = loaded.availableMonths
        month = loaded.month
        alerts = loaded.alerts
        currency = Currency(loaded.currency)
        isTrackingBudget = loaded.isTrackingBudget
    }

    func restoredMonth(
        revision currentRevision: UInt64,
        localFileID expectedLocalFileID: String,
        budgetID expectedBudgetID: String,
        groupID expectedGroupID: String?,
        preferredCalendarMonth currentPreferredCalendarMonth: String,
        modeIdentity currentModeIdentity: BudgetModeIdentity
    ) -> LoadedBudgetMonth? {
        guard schemaVersion == Self.currentSchemaVersion,
              projectionVersion == Self.currentProjectionVersion,
              revision == currentRevision,
              localFileID == expectedLocalFileID,
              budgetID == expectedBudgetID,
              groupID == expectedGroupID,
              preferredCalendarMonth == currentPreferredCalendarMonth,
              modeIdentity == currentModeIdentity,
              displayedMonth == month.month,
              isTrackingBudget == (month.trackingSummary != nil),
              isTrackingBudget == (modeIdentity.table == .tracking),
              availableMonths.contains(displayedMonth) || isTrackingBudget else {
            return nil
        }
        return LoadedBudgetMonth(
            modeIdentity: modeIdentity,
            availableMonths: availableMonths,
            selectedMonth: displayedMonth,
            month: month,
            alerts: alerts,
            currency: currency.budgetCurrency,
            isTrackingBudget: isTrackingBudget
        )
    }
}

struct BudgetLaunchSnapshotContext: Equatable, Sendable {
    let localFileID: String
    let budgetID: String
    let groupID: String?
    let preferredCalendarMonth: String
    let displayedMonth: String
}

struct BudgetLaunchRevisionRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let localFileID: String
    let revision: UInt64

    init(localFileID: String, revision: UInt64) {
        schemaVersion = Self.currentSchemaVersion
        self.localFileID = localFileID
        self.revision = revision
    }
}

/// One immutable per-budget handle. All revision and snapshot operations share
/// the manager-owned lock, making compare-and-write atomic with revision bumps.
struct BudgetLaunchSnapshotFiles: @unchecked Sendable {
    let localFileID: String
    let revisionURL: URL
    let snapshotURL: URL
    let access: BudgetLaunchSnapshotFileAccess

    func prepareRevision() throws -> UInt64 {
        try access.prepareRevision(
            localFileID: localFileID,
            revisionURL: revisionURL,
            snapshotURL: snapshotURL
        )
    }

    func readRevisionAndSnapshot() throws -> (revision: UInt64, snapshot: BudgetLaunchSnapshot?) {
        try access.readRevisionAndSnapshot(
            localFileID: localFileID,
            revisionURL: revisionURL,
            snapshotURL: snapshotURL
        )
    }

    @discardableResult
    func advanceRevision() throws -> UInt64 {
        try access.advanceRevision(
            localFileID: localFileID,
            revisionURL: revisionURL,
            snapshotURL: snapshotURL
        )
    }

    @discardableResult
    func writeSnapshot(_ snapshot: BudgetLaunchSnapshot, ifRevisionIs expectedRevision: UInt64) throws -> Bool {
        try access.writeSnapshot(
            snapshot,
            expectedRevision: expectedRevision,
            localFileID: localFileID,
            revisionURL: revisionURL,
            snapshotURL: snapshotURL
        )
    }
}

/// Filesystem implementation shared by every handle created by one
/// `BudgetFileManager`. The synchronous API is deliberate: `BudgetDatabase`
/// calls `advanceRevision` immediately before a SQLite mutation may commit.
final class BudgetLaunchSnapshotFileAccess: @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func prepareRevision(localFileID: String, revisionURL: URL, snapshotURL: URL) throws -> UInt64 {
        try withLock {
            if let record = try validRevisionRecord(at: revisionURL, localFileID: localFileID) {
                return record.revision
            }
            // A missing/corrupt authority can never validate an existing cache.
            try removeIfPresent(snapshotURL)
            let record = BudgetLaunchRevisionRecord(localFileID: localFileID, revision: 0)
            try write(record, to: revisionURL)
            return record.revision
        }
    }

    func readRevisionAndSnapshot(
        localFileID: String,
        revisionURL: URL,
        snapshotURL: URL
    ) throws -> (revision: UInt64, snapshot: BudgetLaunchSnapshot?) {
        try withLock {
            guard let record = try validRevisionRecord(at: revisionURL, localFileID: localFileID) else {
                try removeIfPresent(snapshotURL)
                let initial = BudgetLaunchRevisionRecord(localFileID: localFileID, revision: 0)
                try write(initial, to: revisionURL)
                return (initial.revision, nil)
            }
            guard fileManager.fileExists(atPath: snapshotURL.path) else {
                return (record.revision, nil)
            }
            do {
                let data = try Data(contentsOf: snapshotURL)
                return (record.revision, try JSONDecoder.actual.decode(BudgetLaunchSnapshot.self, from: data))
            } catch {
                try? removeIfPresent(snapshotURL)
                return (record.revision, nil)
            }
        }
    }

    func advanceRevision(localFileID: String, revisionURL: URL, snapshotURL: URL) throws -> UInt64 {
        try withLock {
            let record = try validRevisionRecord(at: revisionURL, localFileID: localFileID)
            if record == nil {
                try removeIfPresent(snapshotURL)
            }
            let current = record?.revision ?? 0
            guard current < UInt64.max else {
                throw LocalFirstError.invalidLocalWrite("launch revision exhausted")
            }
            let next = current + 1
            try write(BudgetLaunchRevisionRecord(localFileID: localFileID, revision: next), to: revisionURL)
            return next
        }
    }

    func writeSnapshot(
        _ snapshot: BudgetLaunchSnapshot,
        expectedRevision: UInt64,
        localFileID: String,
        revisionURL: URL,
        snapshotURL: URL
    ) throws -> Bool {
        try withLock {
            guard let record = try validRevisionRecord(at: revisionURL, localFileID: localFileID),
                  record.revision == expectedRevision,
                  snapshot.revision == expectedRevision,
                  snapshot.localFileID == localFileID else {
                return false
            }
            try write(snapshot, to: snapshotURL)
            return true
        }
    }

    private func validRevisionRecord(at url: URL, localFileID: String) throws -> BudgetLaunchRevisionRecord? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let record = try JSONDecoder.actual.decode(
                BudgetLaunchRevisionRecord.self,
                from: Data(contentsOf: url)
            )
            guard record.schemaVersion == BudgetLaunchRevisionRecord.currentSchemaVersion,
                  record.localFileID == localFileID else {
                return nil
            }
            return record
        } catch {
            return nil
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try JSONEncoder.actual.encode(value)
        try data.write(to: url, options: .atomic)
        try harden(url)
    }

    private func harden(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
