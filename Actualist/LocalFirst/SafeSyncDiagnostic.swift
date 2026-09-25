import Foundation

/// A controlled diagnostic projection, not a substring redactor. In particular,
/// opaque NSError/localizedDescription strings never become durable sync errors.
enum SafeSyncDiagnostic {
    static let previousFailure = "Previous sync attempt failed. Details are unavailable."
    static let genericFailure = "Sync could not complete. The changes remain on this device."

    static func description(for error: Error) -> String {
        if let error = error as? ActualAPIError { return error.localizedDescription }
        if let error = error as? LocalFirstError {
            switch error {
            case .budgetEncryptionChanged, .missingSyncToken, .remoteDataLimitExceeded,
                 .invalidEncryptedPayload, .unauthenticatedPlaintextEnvelope,
                 .syncUploadNotConfirmed:
                return error.localizedDescription
            default: break
            }
        }
        return genericFailure
    }

    static func eventMessage(_ message: String, outcome: LocalFirstSyncDebugEvent.Outcome) -> String {
        outcome == .failed ? storedError(message) : legacyEvent(outcome: outcome)
    }

    static func legacyEvent(outcome: LocalFirstSyncDebugEvent.Outcome) -> String {
        switch outcome {
        case .failed: previousFailure
        case .queued: "Previous local changes were queued."
        case .succeeded: "Previous sync attempt succeeded."
        }
    }

    /// Read/export boundary for error strings written by older versions. Only
    /// exact app-authored descriptions (or a canonical numeric HTTP status)
    /// can be retained; a substring match would leak unlabeled secrets.
    static func storedError(_ text: String?) -> String {
        guard let text else { return previousFailure }
        let known = [
            ActualAPIError.invalidURL.localizedDescription,
            ActualAPIError.redirectRefused.localizedDescription,
            ActualAPIError.invalidResponse.localizedDescription,
            ActualAPIError.decoding.localizedDescription,
            ActualAPIError.localNetworkDenied.localizedDescription,
            ActualAPIError.unsupportedAuthenticationMethod.localizedDescription,
            ActualAPIError.transport(.timedOut).localizedDescription,
            ActualAPIError.transport(.notConnectedToInternet).localizedDescription,
            ActualAPIError.transport(nil).localizedDescription,
            LocalFirstError.budgetEncryptionChanged.localizedDescription,
            LocalFirstError.missingSyncToken.localizedDescription,
            LocalFirstError.remoteDataLimitExceeded.localizedDescription,
            LocalFirstError.invalidEncryptedPayload.localizedDescription,
            LocalFirstError.unauthenticatedPlaintextEnvelope.localizedDescription,
            genericFailure,
            previousFailure
        ] + ActualServerErrorCategory.allCases.map(\.description)
          + ActualSyncRejectionReason.allCases.map {
              ActualAPIError.syncRejected(status: 400, reason: $0).localizedDescription
          }
        if known.contains(text) { return text }
        let prefix = "The server returned HTTP "
        if text.hasPrefix(prefix), text.hasSuffix("."),
           let status = Int(text.dropFirst(prefix.count).dropLast()),
           (100...599).contains(status), text == ActualAPIError.httpStatus(status).localizedDescription {
            return text
        }
        let uploadPrefix = "The Actual server did not confirm "
        if text.hasPrefix(uploadPrefix),
           let count = Int(text.dropFirst(uploadPrefix.count).prefix(while: { $0.isASCII && $0.isNumber })),
           (1...1_000_000).contains(count),
           text == LocalFirstError.syncUploadNotConfirmed(count).localizedDescription {
            return text
        }
        return previousFailure
    }

    static func backgroundMessage(_ text: String, succeeded: Bool?) -> String {
        switch text {
        case "Started", "Registered background task", "Failed to register background task",
             "Scheduled background refresh": return text
        default:
            if succeeded == false {
                let safe = storedError(text)
                return safe == previousFailure
                    ? "Previous background attempt failed. Details are unavailable."
                    : safe
            }
            return succeeded == true
                ? "Previous background task completed."
                : "Previous background task started."
        }
    }
}
