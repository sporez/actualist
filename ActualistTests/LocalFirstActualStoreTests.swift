import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

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
