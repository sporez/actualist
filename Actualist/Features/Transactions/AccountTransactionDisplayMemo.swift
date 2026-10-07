import Foundation

/// Cheap identity of a loaded feed page. The page is a large `Hashable` value;
/// comparing it deeply on every render is what made the feed stutter (see
/// `AccountTransactionFeedGroups`). The store replaces a page by building new
/// arrays, so the transactions buffer address plus the scalar counters tell
/// two pages apart. The memo retains the page it compared against, so a freed
/// buffer's address can never be reused while the memo still holds the old one.
private struct AccountTransactionPageIdentity: Equatable {
    let transactionsBuffer: UnsafeRawPointer?
    let transactionCount: Int
    let balance: Int?
    let nextOffset: Int
    let reachedEnd: Bool
    let nameCounts: [Int]

    init?(_ page: LoadedAccountTransactions?) {
        guard let page else { return nil }
        transactionsBuffer = page.transactions.withUnsafeBufferPointer {
            $0.baseAddress.map(UnsafeRawPointer.init)
        }
        transactionCount = page.transactions.count
        balance = page.balance
        nextOffset = page.nextOffset
        reachedEnd = page.reachedEnd
        nameCounts = [page.accountNames.count, page.categoryNames.count, page.payeeNames.count]
    }
}

/// Everything the display state depends on besides the (fixed) scope.
private struct AccountTransactionDisplayKey: Equatable {
    let loaded: AccountTransactionPageIdentity?
    let activePage: AccountTransactionPageIdentity?
    let statusFilter: TransactionStatusFilter
    let query: String
    let pendingNewTransactionIDs: Set<String>
    let privacyModeEnabled: Bool
    let currency: BudgetCurrency
    let dayID: String
    let supportsScheduleAuthoring: Bool

    init(_ projection: AccountTransactionFeedProjection) {
        loaded = AccountTransactionPageIdentity(projection.loaded)
        activePage = AccountTransactionPageIdentity(projection.activePage)
        statusFilter = projection.statusFilter
        query = projection.query
        pendingNewTransactionIDs = projection.pendingNewTransactionIDs
        privacyModeEnabled = projection.privacyModeEnabled
        currency = projection.currency
        dayID = projection.scheduleConversionDayID
        supportsScheduleAuthoring = projection.supportsScheduleAuthoring
    }
}

/// Memoizes the feed display state so a re-render with unchanged inputs does
/// not re-project every row. Owned by `AccountTransactionsViewModel`.
struct AccountTransactionDisplayMemo {
    private var key: AccountTransactionDisplayKey?
    private var state: AccountTransactionsDisplayState?
    /// Retains the pages the key was built from (see the identity note above).
    private var retainedPages: [LoadedAccountTransactions] = []
    /// Test seam: how many times the display state was actually projected.
    private(set) var projectionCount = 0

    mutating func displayState(for projection: AccountTransactionFeedProjection) -> AccountTransactionsDisplayState {
        let newKey = AccountTransactionDisplayKey(projection)
        if newKey == key, let state { return state }
        let projected = projection.displayState
        projectionCount += 1
        key = newKey
        state = projected
        retainedPages = [projection.loaded, projection.activePage].compactMap { $0 }
        return projected
    }
}
