import Foundation

enum UserFacingErrorText {
    static let genericFailure = "Something went wrong. Try again."

    /// Errors from these domains describe themselves for developers (SQL text,
    /// status codes), even though some bridge a localized description.
    static let developerOnlyDomains: Set<String> = [
        "GRDB.DatabaseError", NSOSStatusErrorDomain, NSPOSIXErrorDomain
    ]

    /// Foundation's own errors in these domains carry Apple-written text.
    static let systemWrittenDomains: Set<String> = [NSURLErrorDomain, NSCocoaErrorDomain]
}

extension Error {
    /// The one conversion from a thrown error to text a person reads; nil for
    /// cancellation. The app's own `LocalizedError` types describe themselves in
    /// plain words. Anything else that is not a Foundation URL or Cocoa error
    /// (SQLite, OSStatus, untyped Swift errors) gets a generic sentence.
    var userFacingMessage: String? {
        if isCancellation { return nil }
        let domain = (self as NSError).domain
        if UserFacingErrorText.developerOnlyDomains.contains(domain) {
            return UserFacingErrorText.genericFailure
        }
        if let description = (self as? LocalizedError)?.errorDescription {
            return description
        }
        if UserFacingErrorText.systemWrittenDomains.contains(domain) {
            return localizedDescription
        }
        return UserFacingErrorText.genericFailure
    }
}
