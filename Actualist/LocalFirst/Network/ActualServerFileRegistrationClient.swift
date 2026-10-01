import Foundation

/// Wire seam for registering one new budget file with an Actual server.
/// Auth is per call: every method takes the session token explicitly and no
/// credential, key, or file identity is held between calls.
protocol ActualFileRegistrationTransport: Sendable {
    /// `POST /sync/upload-user-file`. `groupID` is only sent after a previous
    /// step recovered one; a brand-new registration uploads without it.
    /// `encryptMeta` is sent as `X-ACTUAL-ENCRYPT-META` for encrypted archives.
    func uploadUserFile(
        fileID: String,
        name: String,
        groupID: String?,
        encryptMeta: ActualEncryptedMetadata?,
        bytes: Data,
        token: String
    ) async throws -> ActualUploadUserFileResponse

    /// `POST /sync/user-create-key`. The file must already exist on the
    /// server (an upload must have landed first — the endpoint answers
    /// `file-not-found` otherwise). Throws unless the response is `status: ok`.
    func createUserKey(
        fileID: String,
        keyID: String,
        keySalt: String,
        testContent: String,
        token: String
    ) async throws
}

/// Actual's upload handler answers `{ status: 'ok', groupId }` for a new file
/// and a re-upload alike. The body is advisory: a lost or unreadable response
/// reconciles through list-user-files with the known file ID instead of
/// failing the registration.
struct ActualUploadUserFileResponse: Decodable, Sendable {
    let groupID: String?

    init(groupID: String?) {
        self.groupID = groupID
    }

    enum CodingKeys: String, CodingKey {
        case groupID = "groupId"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let groupID = try container.decodeIfPresent(String.self, forKey: .groupID) {
            self.groupID = groupID
            return
        }
        if let data = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .data) {
            groupID = try data.decodeIfPresent(String.self, forKey: .groupID)
        } else {
            groupID = nil
        }
    }
}

struct ActualUserCreateKeyPayload: Equatable, Codable, Sendable {
    let fileId: String
    let keyId: String
    let keySalt: String
    let testContent: String
}

struct ActualUserCreateKeyStatusResponse: Decodable, Sendable {
    let status: String?
}

enum ActualFileRegistrationError: LocalizedError, Equatable {
    case emptyRegistrationInput
    /// `/sync/user-create-key` did not answer `status: ok`.
    case keyRegistrationNotConfirmed
    /// The upload never became confirmable: no response group, no singular
    /// list row for the known file ID, and a same-ID retry did not land.
    case uploadUnconfirmed
    /// list-user-files returned more than one live row for the known file ID.
    case registrationAmbiguous
    /// The file stored on the server was encrypted with a different key than
    /// this registration uses; registering the new key would corrupt it.
    case encryptionKeyMismatch

    var errorDescription: String? {
        switch self {
        case .emptyRegistrationInput:
            "The budget archive, name, or file ID was empty, so registration was refused."
        case .keyRegistrationNotConfirmed:
            "The Actual server did not confirm the budget's encryption key. The budget was not registered."
        case .uploadUnconfirmed:
            "The Actual server did not confirm the new budget upload. Nothing was registered; the same budget can be registered again."
        case .registrationAmbiguous:
            "The Actual server returned conflicting records for the new budget ID, so registration was refused."
        case .encryptionKeyMismatch:
            "The Actual server already stores this budget under a different encryption key, so registration was refused."
        }
    }
}

/// Dedicated wire client for registering a new budget file with an Actual
/// server (`/sync/upload-user-file` and `/sync/user-create-key`). Kept out of
/// `ActualServerSyncClient`, which is already at its responsibility limit;
/// shares auth-at-call-time only.
actor ActualServerFileRegistrationClient: ActualFileRegistrationTransport {
    let baseURL: URL
    let customHeaders: HTTPHeaderFields
    private let session: URLSession
    private let redirectDelegate: CustomHTTPHeaderRedirectDelegate

    init(
        baseURL: URL,
        customHeaders: HTTPHeaderFields = .empty,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.customHeaders = customHeaders
        self.redirectDelegate = CustomHTTPHeaderRedirectDelegate(baseURL: baseURL, fields: customHeaders)
        self.session = session ?? URLSession(configuration: ActualServerSyncClient.secureSessionConfiguration())
    }

    func uploadUserFile(
        fileID: String,
        name: String,
        groupID: String?,
        encryptMeta: ActualEncryptedMetadata?,
        bytes: Data,
        token: String
    ) async throws -> ActualUploadUserFileResponse {
        var request = try URLRequest(url: endpointURL(path: "/sync/upload-user-file"))
        customHeaders.apply(to: &request)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = bytes
        request.setValue("application/encrypted-file", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue(fileID, forHTTPHeaderField: "X-ACTUAL-FILE-ID")
        request.setValue(Self.encodedHeaderName(name), forHTTPHeaderField: "X-ACTUAL-NAME")
        request.setValue("2", forHTTPHeaderField: "X-ACTUAL-FORMAT")
        if let groupID {
            request.setValue(groupID, forHTTPHeaderField: "X-ACTUAL-GROUP-ID")
        }
        if let encryptMeta {
            let metaJSON = try JSONEncoder.actual.encode(encryptMeta)
            request.setValue(
                String(decoding: metaJSON, as: UTF8.self),
                forHTTPHeaderField: "X-ACTUAL-ENCRYPT-META"
            )
        }

        let data = try await execute(request)
        if let serverError = ActualServerSyncClient.structuredAPIError(from: data) {
            throw serverError
        }
        return (try? JSONDecoder.actual.decode(ActualUploadUserFileResponse.self, from: data))
            ?? ActualUploadUserFileResponse(groupID: nil)
    }

    func createUserKey(
        fileID: String,
        keyID: String,
        keySalt: String,
        testContent: String,
        token: String
    ) async throws {
        var request = try URLRequest(url: endpointURL(path: "/sync/user-create-key"))
        customHeaders.apply(to: &request)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.httpBody = try JSONEncoder.actual.encode(ActualUserCreateKeyPayload(
            fileId: fileID,
            keyId: keyID,
            keySalt: keySalt,
            testContent: testContent
        ))

        let data = try await execute(request)
        // A 2xx answer is judged only by the endpoint's `status` field. The
        // generic structured-error mapping would shadow the dedicated
        // registration error for bodies like `{"status":"error"}`, making an
        // unconfirmed key look like a generic server rejection.
        let response = try? JSONDecoder.actual.decode(ActualUserCreateKeyStatusResponse.self, from: data)
        guard response?.status?.lowercased() == "ok" else {
            throw ActualFileRegistrationError.keyRegistrationNotConfirmed
        }
    }

    /// Matches JavaScript `encodeURIComponent`, whose inverse Actual applies
    /// to `X-ACTUAL-NAME` server-side with `decodeURIComponent`: only
    /// `A-Z a-z 0-9 - _ . ! ~ * ' ( )` stay literal; everything else is
    /// percent-encoded as UTF-8.
    nonisolated static func encodedHeaderName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    private func endpointURL(path: String) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components?.url,
              redirectDelegate.permits(source: baseURL, destination: url) else {
            throw ActualAPIError.invalidURL
        }
        return url
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: redirectDelegate)
        } catch where error.isCancellation {
            throw CancellationError()
        } catch let error as URLError {
            throw ActualAPIError.transport(error.code)
        } catch {
            throw ActualAPIError.transport(nil)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualAPIError.invalidResponse
        }
        if redirectDelegate.refuses(httpResponse) { throw ActualAPIError.redirectRefused }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ActualServerSyncClient.apiError(statusCode: httpResponse.statusCode, data: data)
        }
        return data
    }
}

/// One new-file registration input. `bytes` are the archive bytes to upload —
/// already encrypted when `encryption` is set. `fileID` is the caller's known
/// identity, minted once; nothing in the registration flow ever replaces it.
struct ActualBudgetFileRegistrationInput: Sendable {
    let fileID: String
    let name: String
    let bytes: Data
    let encryption: Encryption?

    struct Encryption: Sendable {
        let keyID: String
        let keySalt: String
        let testContent: String
        let encryptMeta: ActualEncryptedMetadata
    }
}

/// What a confirmed registration recorded. `fileID` is always the caller's
/// known ID — a lost upload response never mints a second identity.
struct ActualBudgetFileRegistrationReceipt: Equatable, Sendable {
    let fileID: String
    let groupID: String?
    let encryptionKeyID: String?
}

/// Drives one registration: upload under the caller's known file ID, recover
/// a lost or unreadable upload response through the existing list-user-files
/// path, then — for encrypted archives — register the key. The receipt is
/// only returned after `/sync/user-create-key` answers `status: ok`; a
/// failed upload never reports a registered budget.
struct ActualBudgetFileRegistrationFlow: Sendable {
    let transport: any ActualFileRegistrationTransport
    /// The existing list-user-files path, used only to reconcile a lost or
    /// unreadable upload response for the known file ID.
    let listUserFiles: @Sendable (_ token: String) async throws -> [ActualSyncRemoteFile]
    /// The existing get-user-file-info path. The list endpoint does not
    /// return the uploaded encrypt-meta, so this confirms a recovered file's
    /// stored bytes were encrypted with this registration's key.
    let userInfo: @Sendable (_ fileID: String, _ token: String) async throws -> ActualSyncRemoteFile?

    func register(
        _ input: ActualBudgetFileRegistrationInput,
        token: String
    ) async throws -> ActualBudgetFileRegistrationReceipt {
        guard !input.fileID.isEmpty, !input.name.isEmpty, !input.bytes.isEmpty else {
            throw ActualFileRegistrationError.emptyRegistrationInput
        }

        let groupID = try await confirmedGroupID(for: input, token: token)
        if let encryption = input.encryption {
            try await transport.createUserKey(
                fileID: input.fileID,
                keyID: encryption.keyID,
                keySalt: encryption.keySalt,
                testContent: encryption.testContent,
                token: token
            )
        }
        return ActualBudgetFileRegistrationReceipt(
            fileID: input.fileID,
            groupID: groupID,
            encryptionKeyID: input.encryption?.keyID
        )
    }

    private func confirmedGroupID(
        for input: ActualBudgetFileRegistrationInput,
        token: String
    ) async throws -> String? {
        do {
            let response = try await upload(input, groupID: nil, token: token)
            if let groupID = response.groupID { return groupID }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Lost or refused response. The known file ID stays the only
            // identity; reconcile through the list path instead of minting
            // a second one.
        }
        return try await recoverGroupID(for: input, token: token)
    }

    /// Mirrors the registration oracle: list by the known file ID and require
    /// a singular live row; with no row, retry the upload once under the same
    /// ID (a `file-has-reset` rejection means the first attempt landed) and
    /// list again. Anything else refuses to invent an identity.
    private func recoverGroupID(
        for input: ActualBudgetFileRegistrationInput,
        token: String
    ) async throws -> String? {
        if let recovered = try await recoveryFromList(for: input, token: token) {
            return recovered
        }

        do {
            let response = try await upload(input, groupID: nil, token: token)
            if let groupID = response.groupID { return groupID }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A refused retry still leaves the final list to decide.
        }
        guard let recovered = try await recoveryFromList(for: input, token: token) else {
            throw ActualFileRegistrationError.uploadUnconfirmed
        }
        return recovered
    }

    private func recoveryFromList(
        for input: ActualBudgetFileRegistrationInput,
        token: String
    ) async throws -> String? {
        let files = try await listUserFiles(token)
        let liveByID = files.filter { !$0.deleted && $0.fileID == input.fileID }
        switch liveByID.count {
        case 0:
            return nil
        case 1:
            guard let groupID = liveByID[0].groupID else {
                throw ActualFileRegistrationError.uploadUnconfirmed
            }
            try await confirmStoredEncryption(
                recoveredFileID: input.fileID,
                input: input,
                token: token
            )
            return groupID
        default:
            throw ActualFileRegistrationError.registrationAmbiguous
        }
    }

    /// A recovered file keeps the caller's identity only when the bytes
    /// already stored on the server match this registration's encryption
    /// inputs. Re-registering a different key over stored bytes it cannot
    /// open would corrupt the budget, so a mismatch refuses instead.
    private func confirmStoredEncryption(
        recoveredFileID: String,
        input: ActualBudgetFileRegistrationInput,
        token: String
    ) async throws {
        guard let info = try await userInfo(recoveredFileID, token) else {
            return
        }
        guard info.encryptMeta?.keyID == input.encryption?.keyID else {
            throw ActualFileRegistrationError.encryptionKeyMismatch
        }
    }

    private func upload(
        _ input: ActualBudgetFileRegistrationInput,
        groupID: String?,
        token: String
    ) async throws -> ActualUploadUserFileResponse {
        try await transport.uploadUserFile(
            fileID: input.fileID,
            name: input.name,
            groupID: groupID,
            encryptMeta: input.encryption?.encryptMeta,
            bytes: input.bytes,
            token: token
        )
    }
}
