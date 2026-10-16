import Foundation

/// The confirmation copy shared by every action that discards the local budget
/// copy (disconnect and erase, re-import).
enum LocalDataLossWarning {
    static func message(base: String, pendingChangeCount: Int) -> String {
        guard pendingChangeCount > 0 else {
            return "\(base) Your server data is not changed."
        }
        let subject = pendingChangeCount == 1 ? "1 change has" : "\(pendingChangeCount) changes have"
        return "\(base) \(subject) not uploaded to the server yet and will be lost."
    }
}
