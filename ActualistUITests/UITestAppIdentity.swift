import Foundation

enum UITestAppIdentity {
    private final class BundleMarker: NSObject {}

    static var appIdentifier: String {
        get throws { try requiredInfoValue(forKey: "ActualistAppIdentifier") }
    }

    static var appDisplayName: String {
        get throws { try requiredInfoValue(forKey: "ActualistAppDisplayName") }
    }

    private static func requiredInfoValue(forKey key: String) throws -> String {
        let bundle = Bundle(for: BundleMarker.self)
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            throw ConfigurationError.missingInfoValue(key: key, bundleURL: bundle.bundleURL)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            throw ConfigurationError.invalidInfoValue(key: key, value: value, bundleURL: bundle.bundleURL)
        }
        return trimmed
    }

    private enum ConfigurationError: LocalizedError {
        case missingInfoValue(key: String, bundleURL: URL)
        case invalidInfoValue(key: String, value: String, bundleURL: URL)

        var errorDescription: String? {
            switch self {
            case .missingInfoValue(let key, let bundleURL):
                "UI test bundle at \(bundleURL.path) is missing required Info value \(key)."
            case .invalidInfoValue(let key, let value, let bundleURL):
                "UI test bundle at \(bundleURL.path) has invalid Info value \(key)=\(value)."
            }
        }
    }
}
