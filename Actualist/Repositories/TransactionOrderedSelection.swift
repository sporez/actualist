import Foundation

/// Tap order is authoritative; a physical row can be selected only once even
/// when a refreshed projection gives that row a different family identity.
struct TransactionOrderedSelection: Equatable, Sendable {
    private(set) var identities: [TransactionSelectionIdentity]

    init(_ identities: [TransactionSelectionIdentity] = []) {
        var seen = Set<String>()
        self.identities = identities.filter { seen.insert($0.transactionID).inserted }
    }

    mutating func toggle(_ identity: TransactionSelectionIdentity) {
        if let index = identities.firstIndex(where: { $0.transactionID == identity.transactionID }) {
            identities.remove(at: index)
        } else {
            identities.append(identity)
        }
    }
}
