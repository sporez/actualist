import Foundation

struct TransactionCSVExportRequest: Sendable {
    let budgetID: String
    let accountID: String
    let query: TransactionFeedQuery
}

struct TransactionCSVExport: Equatable, Sendable {
    let suggestedFilename: String
    let data: Data
    let exportedFamilyCount: Int
    let exportedRowCount: Int
}

@MainActor
protocol TransactionCSVExportRepositoryProtocol: AnyObject {
    func exportTransactionsCSV(_ request: TransactionCSVExportRequest) async throws -> TransactionCSVExport
}

struct TransactionCSVExportRow: Hashable, Sendable {
    let id: String
    let familyID: String
    let accountName: String
    let date: String
    let payeeName: String
    let notes: String?
    let categoryGroupName: String
    let categoryName: String
    let amountMinorUnits: Int
    let isCleared: Bool
    let isReconciled: Bool
    let isParent: Bool
    let isChild: Bool
}
