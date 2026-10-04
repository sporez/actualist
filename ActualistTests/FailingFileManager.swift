import Foundation
import Synchronization
@testable import Actualist

/// Injected through `BudgetFileManager(fileManager:)` to fail chosen moves and
/// deletes while every other operation reaches the real file system.
final class FailingFileManager: FileManager {
    struct Rules {
        var failMove: (@Sendable (_ source: URL, _ destination: URL) -> Bool)?
        var failRemove: (@Sendable (_ url: URL) -> Bool)?
    }

    let rules = Mutex(Rules())

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if rules.withLock({ $0.failMove?(srcURL, dstURL) ?? false }) {
            throw LocalFirstTestSyncError.failed
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    override func removeItem(at URL: URL) throws {
        if rules.withLock({ $0.failRemove?(URL) ?? false }) {
            throw LocalFirstTestSyncError.failed
        }
        try super.removeItem(at: URL)
    }

    /// The staged workspace directory is named `<hash>.reimport-<uuid>`.
    static func isStagedSwap(_ source: URL) -> Bool {
        source.lastPathComponent.contains(".reimport-")
    }

    static func isBackupRestore(_ source: URL) -> Bool {
        source.pathComponents.contains(".ReimportBackups")
    }
}
