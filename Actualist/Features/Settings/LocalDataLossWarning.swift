import Foundation

/// The confirmation copy shared by every action that discards the local budget
/// copy (disconnect and erase, re-import).
enum LocalDataLossWarning {
    static func message(base: String, pendingChangeCount: Int) -> String {
        guard pendingChangeCount > 0 else {
            return "\(base) Your server data is not changed."
        }
        let subject = pendingChangeCount == 1 ? "1 local change has" : "\(pendingChangeCount) local changes have"
        return "\(base) Warning: \(subject) not been confirmed by the server and will be permanently lost."
    }
}
