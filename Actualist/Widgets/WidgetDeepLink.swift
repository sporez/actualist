import Foundation

enum WidgetDeepLink: Equatable, Sendable {
    case category(id: String, month: String)

    static let scheme = "com.sporez.actualist"
    static let categoryHost = "category"

    static func url(_ destination: WidgetDeepLink) -> URL {
        switch destination {
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
        guard url.scheme == scheme, url.host == categoryHost else {
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
