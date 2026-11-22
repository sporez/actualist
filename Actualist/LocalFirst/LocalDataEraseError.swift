import Foundation

/// The parts of Erase Local Data that failed. `runAll` runs every step even
/// after one throws, so a locked Keychain item does not leave the budget
/// files or the other credentials behind.
struct LocalDataEraseError: LocalizedError, Equatable {
    enum Part: Equatable, Sendable {
        case budgetFiles
        case syncToken
        case encryptionKeys
        case simpleFINAccess
        case customHeaders

        var title: String {
            switch self {
            case .budgetFiles: String(localized: "the downloaded budgets")
            case .syncToken: String(localized: "the server sign-in")
            case .encryptionKeys: String(localized: "the budget encryption keys")
            case .simpleFINAccess: String(localized: "the SimpleFIN access key")
            case .customHeaders: String(localized: "the custom headers")
            }
        }
    }

    let failedParts: [Part]

    var errorDescription: String? {
        let parts = ListFormatter.localizedString(byJoining: failedParts.map(\.title))
        return String(localized: "Erase Local Data could not remove \(parts). Try again.")
    }

    static func runAll(_ steps: [(part: Part, run: () throws -> Void)]) throws {
        var failed: [Part] = []
        for step in steps {
            do { try step.run() } catch { failed.append(step.part) }
        }
        guard failed.isEmpty else { throw LocalDataEraseError(failedParts: failed) }
    }
}
