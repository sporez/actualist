#if DEBUG
import Foundation

/// Where a read pauses after its database fetch and before its session check
/// and publication.
enum ReadPublicationSite: Sendable {
    case reportsDashboard, availableMonths, templateBrowser
    case categoryFeed, uncategorizedFeed, launchSeed, launchWarmupSyncStatus
}

/// Every optional test hook on `LocalFirstActualStore`. Debug builds only:
/// Release carries no hook property, type or awaited call site. The store holds
/// one optional instance (`testSeams`), created on first use. `reset()` keeps
/// it: reimport and reconnect call `reset()` mid-flow, and a test that parked
/// such a flow on a hook needs the hook to survive.
@MainActor
final class StoreTestSeams {
    /// Runs after a read's database fetch, before its session check and publication.
    var readPublicationHook: (@MainActor (ReadPublicationSite) async -> Void)?
    var budgetOpenSuspension: (@MainActor () async -> Void)?
    var launchWarmupSuspension: (@MainActor () async -> Void)?
    /// Runs after a transaction feed page is read and before it is published.
    var transactionFeedPageReadHook: TransactionFeedPageReadHook?
    var savedFilterBeforeCommitHook: SavedFilterMutationHook?
    var savedFilterAfterCommitHook: SavedFilterMutationHook?
    var rulesReadHook: RulesReadHook?
    /// Runs after the payee snapshot has been read and before it is published.
    var payeeSnapshotReadHook: PayeeSnapshotReadHook?
    var scheduleReadHook: ScheduleReadHook?
    var scheduleMutationBeforeCommitHook: ScheduleMutationHook?
    var scheduleMutationAfterCommitHook: ScheduleMutationHook?
    var scheduleMutationBeforeRefreshHook: ScheduleMutationRefreshHook?
    /// Runs after a Wallet import has built its messages and before they commit; `attempt` is 1 or 2.
    var walletImportBeforeCommitHook: WalletImportBeforeCommitHook?
    /// Runs after a user gesture has read its inputs and before its write
    /// transaction opens. Tests land a remote change here to prove the write
    /// builds from live rows rather than from the earlier read.
    var userActionBeforeCommitHook: UserActionBeforeCommitHook?
}

typealias TransactionFeedPageReadHook = @MainActor @Sendable (
    TransactionFeedCacheKey,
    String?,
    Int?,
    Int
) async throws -> Void
typealias SavedFilterMutationHook = @MainActor @Sendable () async -> Void
typealias RulesReadHook = @MainActor @Sendable (_ budgetID: String) async throws -> Void
typealias PayeeSnapshotReadHook = @MainActor @Sendable (_ budgetID: String) async -> Void
typealias ScheduleReadHook = @MainActor @Sendable (_ budgetID: String, _ today: String) async -> Void
typealias ScheduleMutationHook = @MainActor @Sendable () async -> Void
typealias ScheduleMutationRefreshHook = @MainActor @Sendable () async throws -> Void
typealias WalletImportBeforeCommitHook = @MainActor @Sendable (_ attempt: Int) async -> Void
typealias UserActionBeforeCommitHook = @MainActor @Sendable () async -> Void

extension LocalFirstActualStore {
    /// The hooks, created on first access. Call sites read `testSeams?` so an
    /// unused store never allocates them.
    var seams: StoreTestSeams {
        if let testSeams { return testSeams }
        let created = StoreTestSeams()
        testSeams = created
        return created
    }
}
#endif
