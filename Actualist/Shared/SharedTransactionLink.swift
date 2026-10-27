import Foundation

/// A link that opens one transaction in the recipient's Actualist.
///
/// The transaction ID rides in the fragment, which a browser never sends to
/// the web server. The link holds no budget ID: the app looks the transaction
/// up in the budget that is open.
struct SharedTransactionLink: Equatable, Sendable {
    enum Form: Equatable, Sendable {
        /// `https://actualist.app/t#<id>`. Dev uses `/dev/t`, so the two
        /// installs never claim each other's links.
        case universal
        /// `<app scheme>://transaction#<id>`, which works before the website
        /// serves the app association file.
        case appScheme
    }

    static let universalHost = "actualist.app"
    static let appSchemeHost = "transaction"
    private static let maximumIDLength = 128
    private static let idCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
    )

    let transactionID: String

    init?(transactionID: String) {
        guard !transactionID.isEmpty,
              transactionID.count <= Self.maximumIDLength,
              transactionID.unicodeScalars.allSatisfy(Self.idCharacters.contains) else { return nil }
        self.transactionID = transactionID
    }

    func url(_ form: Form, installation: AppInstallationIdentity = .current) -> URL {
        var components = URLComponents()
        switch form {
        case .universal:
            components.scheme = "https"
            components.host = Self.universalHost
            components.path = Self.universalPath(for: installation)
        case .appScheme:
            components.scheme = installation.urlScheme
            components.host = Self.appSchemeHost
        }
        components.fragment = transactionID
        guard let url = components.url else {
            preconditionFailure("A validated transaction ID always forms a URL.")
        }
        return url
    }

    static func parse(_ url: URL, installation: AppInstallationIdentity = .current) -> SharedTransactionLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.user == nil,
              components.password == nil, components.port == nil,
              let fragment = components.fragment else { return nil }
        switch (components.scheme?.lowercased(), components.host?.lowercased()) {
        case ("https", universalHost):
            guard components.path == universalPath(for: installation) else { return nil }
        case (installation.urlScheme, appSchemeHost):
            guard components.path.isEmpty else { return nil }
        default:
            return nil
        }
        return SharedTransactionLink(transactionID: fragment)
    }

    private static func universalPath(for installation: AppInstallationIdentity) -> String {
        switch installation {
        case .production: "/t"
        case .development: "/dev/t"
        }
    }
}

/// What the open budget holds for a shared transaction ID.
enum SharedTransactionLookup: Equatable, Sendable {
    /// The live transaction to edit; a split child resolves to its parent.
    case found(ActualTransaction)
    /// A row with this ID exists, but it (or its split parent) was deleted.
    case deleted
    /// No row with this ID on this device.
    case missing
}
