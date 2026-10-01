import Foundation

/// Installation-level identifiers shared by the app and its widget extension.
enum AppInstallationIdentity: String, CaseIterable, Sendable {
    case production = "com.sporez.actualist"
    case development = "com.sporez.actualist.dev"

    static let current: Self = {
        guard let identity = resolve(
            appIdentifier: Bundle.main.object(forInfoDictionaryKey: "ActualistAppIdentifier") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) else {
            // A missing Dev setting must never fall back to production's shared container.
            preconditionFailure("The app installation identity is missing or inconsistent.")
        }
        return identity
    }()

    static func resolve(appIdentifier: String?, bundleIdentifier: String?) -> Self? {
        guard let appIdentifier, let identity = Self(rawValue: appIdentifier),
              bundleIdentifier == identity.rawValue || bundleIdentifier == identity.widgetBundleIdentifier else {
            return nil
        }
        return identity
    }

    var appGroupIdentifier: String { "group.\(rawValue)" }
    var keychainService: String { rawValue }
    var urlScheme: String { rawValue }
    var backgroundTaskIdentifier: String { "\(rawValue).transactions.refresh" }
    var quickActionPrefix: String { "\(rawValue).quick-action." }
    var widgetBundleIdentifier: String { "\(rawValue).widgets" }
}
