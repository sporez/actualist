import Foundation

protocol ActualSyncTransport: Sendable {
    func sync(data: Data, token: String) async throws -> Data
}

actor ActualServerSyncClient: ActualSyncTransport {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func loginMethods() async throws -> ActualLoginMethodsResponse {
        try await request(path: "/account/login-methods", method: "GET")
    }

    func login(password: String) async throws -> ActualLoginResponse {
        try await request(
            path: "/account/login",
            method: "POST",
            body: LoginPayload(password: password)
        )
    }

    func listUserFiles(token: String) async throws -> [ActualSyncRemoteFile] {
        let response: ActualUserFilesResponse = try await request(
            path: "/sync/list-user-files",
            method: "GET",
            token: token
        )
        var seenFileIDs = Set<String>()
        return response.files
            .map { file in
                guard file.groupID == nil, let groupID = response.groupID else {
                    return file
                }
                return ActualSyncRemoteFile(
                    fileID: file.fileID,
                    groupID: groupID,
                    name: file.name,
                    deleted: file.deleted,
                    encryptKeyID: file.encryptKeyID,
                    requiresEncryptionPassword: file.requiresEncryptionPassword
                )
            }
            .filter { !$0.deleted }
            .filter { file in
                seenFileIDs.insert(file.fileID).inserted
            }
    }

    func userFileInfo(fileID: String, token: String) async throws -> ActualSyncRemoteFile? {
        let response: ActualUserFileInfoResponse = try await request(
            path: "/sync/get-user-file-info",
            method: "GET",
            token: token,
            fileID: fileID
        )
        return response.file
    }

    func downloadUserFile(fileID: String, token: String) async throws -> Data {
        try await rawRequest(
            path: "/sync/download-user-file",
            method: "GET",
            token: token,
            fileID: fileID
        )
    }

    func userKey(fileID: String, token: String) async throws -> ActualUserKeyResponse {
        try await request(
            path: "/sync/user-get-key",
            method: "POST",
            token: token,
            fileID: fileID,
            body: UserKeyPayload(fileId: fileID)
        )
    }

    func sync(data: Data, token: String) async throws -> Data {
        try await binaryRequest(
            path: "/sync/sync",
            token: token,
            body: data
        )
    }

    private func request<Value: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        token: String? = nil,
        fileID: String? = nil,
        body: (any Encodable)? = nil
    ) async throws -> Value {
        let data = try await rawRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            token: token,
            fileID: fileID,
            body: body
        )
        do {
            return try JSONDecoder.actual.decode(Value.self, from: data)
        } catch {
            throw ActualAPIError.decoding
        }
    }

    private func rawRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        token: String? = nil,
        fileID: String? = nil,
        body: (any Encodable)? = nil
    ) async throws -> Data {
        var request = try URLRequest(url: endpointURL(path: path, queryItems: queryItems))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            addAuthorizationHeaders(to: &request, token: token)
        }
        if let fileID {
            request.setValue(fileID, forHTTPHeaderField: "X-ACTUAL-FILE-ID")
        }
        if let body {
            request.httpBody = try JSONEncoder.actual.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        return try await execute(request)
    }

    private func binaryRequest(
        path: String,
        token: String,
        body: Data
    ) async throws -> Data {
        var request = try URLRequest(url: endpointURL(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/actual-sync", forHTTPHeaderField: "Content-Type")
        request.setValue("application/actual-sync", forHTTPHeaderField: "Accept")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        addAuthorizationHeaders(to: &request, token: token)

        return try await execute(request)
    }

    private func endpointURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        if !queryItems.isEmpty {
            let existingQueryItems = components?.queryItems ?? []
            components?.queryItems = existingQueryItems + queryItems
        }

        guard let url = components?.url else {
            throw ActualAPIError.invalidURL
        }
        return url
    }

    private func addAuthorizationHeaders(to request: inout URLRequest, token: String) {
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        Self.debugLogRequest(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ActualAPIError.transport(error.code)
        } catch {
            throw ActualAPIError.transport(nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualAPIError.invalidResponse
        }
        Self.debugLogResponse(httpResponse, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ActualAPIError.httpStatus(httpResponse.statusCode)
        }
        return data
    }

    private static func debugLogRequest(_ request: URLRequest) {
        #if DEBUG
        let method = request.httpMethod ?? "GET"
        let byteCount = request.httpBody?.count ?? 0
        print("[Actualist LocalFirst] -> \(method) request (\(byteCount) bytes)")
        #endif
    }

    private static func debugLogResponse(_ response: HTTPURLResponse, data: Data) {
        #if DEBUG
        print("[Actualist LocalFirst] <- HTTP \(response.statusCode) (\(data.count) bytes)")
        #endif
    }

    private struct LoginPayload: Encodable {
        let password: String
    }

    private struct UserKeyPayload: Encodable {
        let fileId: String
    }
}

/// Errors surfaced by the Actual sync server over HTTP (login, file listing, CRDT sync).
enum ActualAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case missingTransactionID
    case httpStatus(Int)
    case decoding
    case transport(URLError.Code?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server URL is invalid."
        case .invalidResponse:
            "The server returned an invalid response."
        case .missingTransactionID:
            "This transaction cannot be changed because the server did not provide its transaction ID."
        case .httpStatus(let status):
            "The server returned HTTP \(status)."
        case .decoding:
            "Actualist could not read the server response."
        case .transport(let code):
            if code == .timedOut {
                "The server did not respond. Check that this phone is on the same Wi-Fi as your Actual server and that the URL is correct."
            } else if code == .notConnectedToInternet {
                "This device is not connected to the network."
            } else {
                "Actualist could not reach the server."
            }
        }
    }
}

extension JSONDecoder {
    static var actual: JSONDecoder {
        JSONDecoder()
    }
}

extension JSONEncoder {
    static var actual: JSONEncoder {
        JSONEncoder()
    }
}
