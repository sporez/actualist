import Foundation
import os

/// Cold-launch instrumentation.
///
/// Each interval answers one question about the launch path, so a regression
/// can be attributed to a stage rather than "launch feels slow". Signpost names
/// are compile-time constants and carry no budget, account, amount, or key
/// data: the timeline shows only stages and their durations.
///
/// Read the timeline with Instruments' "Points of Interest" track or
/// `log stream --signpost --predicate 'subsystem == "com.sporez.actualist"'`.
enum LaunchSignpost {
    static let signposter = OSSignposter(
        subsystem: "com.sporez.actualist",
        category: "launch"
    )

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        debugLog("begin", name)
        return signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
        debugLog("end", name)
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
        debugLog("event", name)
    }

    /// Mirrors signpost boundaries to stdout in Debug builds. CoreDevice can
    /// stream an app's console even when Instruments sees the paired phone as
    /// offline, so physical-device launch measurements remain available without
    /// weakening the production logging policy.
    private static func debugLog(_ boundary: StaticString, _ name: StaticString) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        print("[Actualist Launch] \(boundary) \(name) uptime=\(ProcessInfo.processInfo.systemUptime)")
        #endif
    }

    /// Times one launch stage and closes its interval even when the work throws
    /// or is cancelled. Main-actor bound: every launch stage that can suspend is
    /// app-state, session, or store work. Nonisolated callers use
    /// `begin`/`end` directly.
    @MainActor
    static func measure<T>(
        _ name: StaticString,
        _ work: () async throws -> T
    ) async rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try await work()
    }

    /// Synchronous work that cannot suspend, such as a file-hardening pass.
    static func measureSync<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = begin(name)
        defer { end(name, state) }
        return try work()
    }
}

/// Stage names for the launch timeline. Kept beside the instrumentation so the
/// recorded vocabulary stays one list.
enum LaunchStage {
    /// ActualistApp's first foreground task begins.
    static let foregroundSessionStart: StaticString = "foregroundSessionStart"
    /// Reading and opening the persisted selected budget.
    static let cachedBudgetRestore: StaticString = "cachedBudgetRestore"
    /// Cached metadata and encryption identity read.
    static let budgetMetadataLoad: StaticString = "budgetMetadataLoad"
    /// `BudgetFileManager.hardenCachedBudget` resource pass.
    static let budgetFileHardening: StaticString = "budgetFileHardening"
    /// `BudgetDatabase` construction, including compatibility preparation.
    static let budgetDatabaseInit: StaticString = "budgetDatabaseInit"
    /// One-time legacy schema/CRDT compatibility work inside the open.
    static let budgetDatabaseCompatibility: StaticString = "budgetDatabaseCompatibility"
    /// Available-month discovery during the initial snapshot.
    static let budgetAvailableMonths: StaticString = "budgetAvailableMonths"
    /// Envelope/tracking mode lookup used to choose the initial month.
    static let budgetModeLookup: StaticString = "budgetModeLookup"
    /// Budget category and balance reconstruction for one month.
    static let budgetMonthCalculation: StaticString = "budgetMonthCalculation"
    /// Currency metadata read for the initial snapshot.
    static let budgetSnapshotCurrency: StaticString = "budgetSnapshotCurrency"
    /// Cheap alert derivation for the initial snapshot.
    static let budgetAlertCalculation: StaticString = "budgetAlertCalculation"
    /// Storage-mode identity validation after the snapshot.
    static let budgetIdentityValidation: StaticString = "budgetIdentityValidation"
    /// The restored month snapshot the first Budget frame consumes.
    static let budgetSeedMonth: StaticString = "budgetSeedMonth"
    /// Sync checkpoint and pending-outbox diagnostic reads.
    static let syncStatusRestore: StaticString = "syncStatusRestore"
    /// In-memory sync client configuration.
    static let syncClientConfiguration: StaticString = "syncClientConfiguration"
    /// Setup transitioned to `.ready` with the restored database open.
    static let setupReady: StaticString = "setupReady"
    /// `AdaptiveBudgetSession.prepare` through a presentable context.
    static let sessionPrepare: StaticString = "sessionPrepare"
    /// Compact Budget model handed to the first frame.
    static let compactPresentation: StaticString = "compactPresentation"
    /// Wide (sidebar) workspace handed to the first frame.
    static let sidebarPresentation: StaticString = "sidebarPresentation"
    /// Complete post-presentation enrichment sequence.
    static let launchWarmup: StaticString = "launchWarmup"
    /// Account navigation/balance cache population.
    static let accountWarmup: StaticString = "accountWarmup"
    /// Payee-management snapshot population.
    static let payeeWarmup: StaticString = "payeeWarmup"
    /// Action-log diagnostic snapshot population.
    static let diagnosticWarmup: StaticString = "diagnosticWarmup"
    /// Notification authorization/badge preparation.
    static let notificationPreparation: StaticString = "notificationPreparation"
    /// Foreground CRDT sync after the local budget is presented.
    static let foregroundSync: StaticString = "foregroundSync"
}
