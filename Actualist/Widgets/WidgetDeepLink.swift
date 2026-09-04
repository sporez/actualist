import Foundation

enum WidgetDeepLink: Equatable, Sendable {
    case category(id: String, month: String)
    case account(id: String)
    case quickAction(WidgetQuickAction)

    static let scheme = "com.sporez.actualist"
    static let categoryHost = "category"

    static func url(_ destination: WidgetDeepLink) -> URL {
        switch destination {
        case .account(let id):
            var components = URLComponents()
            components.scheme = scheme
            components.host = "account"
            components.path = "/\(id)"
            return components.url ?? URL(string: "\(scheme)://account")!
        case .quickAction(let action):
            return URL(string: "\(scheme)://action/\(action.rawValue)")!
        case .category(let id, let month):
            var components = URLComponents()
            components.scheme = scheme
            components.host = categoryHost
            components.path = "/\(id)"
            components.queryItems = [URLQueryItem(name: "month", value: month)]
            return components.url ?? URL(string: "\(scheme)://\(categoryHost)")!
        }
    }

    static func parse(_ url: URL) -> WidgetDeepLink? {
        guard url.scheme == scheme else { return nil }
        if url.host == "account" {
            let parts = url.path.split(separator: "/")
            guard parts.count == 1, url.query == nil, url.fragment == nil else { return nil }
            return .account(id: String(parts[0]))
        }
        if url.host == "action" {
            let parts = url.path.split(separator: "/")
            guard parts.count == 1, url.query == nil, url.fragment == nil,
                  let action = WidgetQuickAction(rawValue: String(parts[0])) else { return nil }
            return .quickAction(action)
        }
        guard url.host == categoryHost else {
            return nil
        }
        let id = url.path.split(separator: "/").map(String.init).first ?? ""
        guard !id.isEmpty else {
            return nil
        }
        let month = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "month" })?
            .value
        guard let month, WidgetMonthID.isCanonical(month) else {
            return nil
        }
        return .category(id: id, month: month)
    }
}
