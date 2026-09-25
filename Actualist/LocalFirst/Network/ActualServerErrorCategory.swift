import Foundation

/// No server-supplied string is retained in a public transport error. Actual's
/// observed account errors are mapped
/// by exact match; unknown text is deliberately not diagnostic material.
enum ActualServerErrorCategory: Sendable, Equatable, CaseIterable {
    case invalidPassword
    case sessionExpired
    case passwordAuthenticationDisabled
    case invalidHeader
    case unknown

    static func classify(reason: String?, details: String?) -> Self {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let details = details?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if reason == "unauthorized" || reason == "token-not-found" || details == "token-not-found" {
            return .sessionExpired
        }
        if reason == "invalid-password" { return .invalidPassword }
        if reason == "forbidden" && details == "password-auth-not-active" {
            return .passwordAuthenticationDisabled
        }
        if reason == "invalid-header" { return .invalidHeader }
        return .unknown
    }

    var description: String {
        switch self {
        case .invalidPassword: "The server password is incorrect."
        case .sessionExpired: "Your Actual session is no longer valid. Sign in again to resume syncing."
        case .passwordAuthenticationDisabled: "Password sign-in is not enabled on this Actual server."
        case .invalidHeader: "The Actual server rejected an HTTP header."
        case .unknown: "The Actual server rejected the request."
        }
    }
}
