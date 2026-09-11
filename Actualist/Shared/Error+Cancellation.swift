import AuthenticationServices
import Foundation

extension Error {
    /// Cancellation ends an operation without producing a user-facing failure.
    /// Do not infer this from Task.isCancelled: a real write error still matters
    /// even if the caller was cancelled while the write was completing.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if case .cancelled? = self as? ActualOpenIDAuthenticationError { return true }
        if case .transport(.cancelled)? = self as? ActualAPIError { return true }
        let error = self as NSError
        return (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == ASWebAuthenticationSessionErrorDomain
                && error.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue)
    }

    var userFacingMessage: String? {
        isCancellation ? nil : localizedDescription
    }
}
