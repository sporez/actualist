import CryptoKit
import Foundation

/// Reserved, versioned identity for the bundled demo budget.
///
/// Demo mode is derived from the already-persisted budget selection, so these
/// constants are the single source of truth for "is this the demo budget?".
/// `AppState.isDemoMode` is `settings.selectedLocalFirstFileID == DemoBudget.fileID`,
/// and `LocalFirstActualStore.isDemoBudgetActive` is set inside `openImportedBudget`
/// when `metadata.cloudFileID == DemoBudget.fileID`. Bump the `-vN` suffix when
/// the committed `DemoBudget.zip` changes; entry always reinstalls when the
/// on-disk fileID differs from the current constant, so an app update replaces
/// a stale demo dataset.
enum DemoBudget {
    /// Reserved cloud file ID / local budget ID for the demo budget.
    static let fileID = "actualist-demo-budget-v2"
    /// Reserved group ID (and therefore sync ID) for the demo budget.
    static let groupID = "actualist-demo-group-v1"
    /// Deterministic node ID for the demo budget's local CRDT clock.
    static let nodeID = "demo-node-00000001"
    /// Display name for the demo budget.
    static let name = "Demo Budget"

    /// Bundle resource name for the committed demo budget archive.
    static let archiveResourceName = "DemoBudget"
    static let archiveResourceExtension = "zip"

    /// SHA-256 of the committed `DemoBudget.zip`, for integrity logging and
    /// test assertions. Regenerate with
    /// `scripts/generate-demo-budget/generate_demo_budget.py` and update both
    /// this and `artifactByteCount` together.
    public static let artifactSHA256 =
        "d7e8830d7fcd5b4f062061cd21e40f3de8a62686125211b8f6fc32ef0734a108"
    /// Byte size of the committed `DemoBudget.zip`.
    public static let artifactByteCount = 8547
    /// Budget month the committed zip was generated against. Month notes and
    /// the latest assignments live here. Tests must not use `Date()`.
    static let fixtureMonth = "2026-08"

    /// The demo budget as a domain value, for populating `AppState.budgets`.
    static var budget: ActualBudget {
        ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: groupID,
            name: name,
            state: nil
        )
    }

    /// The deterministic import metadata used when installing the demo budget.
    /// No server URL, no encryption key, no token.
    static func metadata() -> LocalFirstBudgetMetadata {
        LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: groupID,
            budgetName: name,
            encryptionKeyID: nil,
            nodeID: nodeID
        )
    }

    /// The bundled demo budget archive, or `nil` if the resource is missing
    /// (e.g. a build that did not copy `DemoBudget.zip` into the app bundle).
    static func bundledArchiveData() throws -> Data {
        guard
            let url = Bundle.main.url(
                forResource: archiveResourceName,
                withExtension: archiveResourceExtension
            )
        else {
            throw LocalFirstError.missingImportedDatabase
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Integrity-checks the bundled archive against the committed constants.
    /// Used by diagnostics and tests; never fatal in production (a mismatch is
    /// logged, not thrown, by callers that want best-effort behavior).
    static func bundledArchiveMatchesCommittedDigest() -> Bool {
        guard let data = try? bundledArchiveData() else {
            return false
        }
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex == artifactSHA256 && data.count == artifactByteCount
    }
}
