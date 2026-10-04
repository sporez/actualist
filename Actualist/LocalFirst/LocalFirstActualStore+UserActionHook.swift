import Foundation

/// Runs after a user gesture has read its inputs and before its write
/// transaction opens. Tests land a remote change here to prove the write
/// builds from live rows rather than from the earlier read.
typealias UserActionBeforeCommitHook = @MainActor @Sendable () async -> Void
