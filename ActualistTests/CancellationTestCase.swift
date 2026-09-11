import AuthenticationServices
import Foundation
@testable import Actualist

enum CancellationTestCase: CaseIterable, Sendable {
    case swift, url, nsError, transport, openID, browser

    var error: any Error {
        switch self {
        case .swift: CancellationError()
        case .url: URLError(.cancelled)
        case .nsError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        case .transport: ActualAPIError.transport(.cancelled)
        case .openID: ActualOpenIDAuthenticationError.cancelled
        case .browser: NSError(domain: ASWebAuthenticationSessionErrorDomain,
                              code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue)
        }
    }
}
