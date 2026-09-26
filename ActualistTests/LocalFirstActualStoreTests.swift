import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

// Serialized internally so this large suite does not pile its resumptions
// onto the same main-actor queue as every other suite. Other suites stay
// eligible for parallel execution. This is not a universal test-count limit.
@Suite(.serialized)
@MainActor
struct LocalFirstActualStoreTests {
    enum ReimportFailureScenario: CaseIterable, Sendable {
        case midDownload
        case midDecrypt
        case midExtract
        case corruptArchive
        case wrongSchema
    }

    struct OpenedWritableStoreBundle {
        let store: LocalFirstActualStore
        let fileManager: BudgetFileManager
        let keychain: KeychainStore
        let budget: ActualBudget
    }
}
