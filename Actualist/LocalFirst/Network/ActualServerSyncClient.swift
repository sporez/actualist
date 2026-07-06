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
            let snippet = Self.sanitizedBodySnippet(data: data, contentType: "application/json")
            throw ActualAPIError.decoding("\(method) \(path): \(error.localizedDescription). Response: \(snippet)")
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

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let fileID {
            request.setValue(fileID, forHTTPHeaderField: "X-ACTUAL-FILE-ID")
        }
        if let body {
            request.httpBody = try JSONEncoder.actual.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        Self.debugLogRequest(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ActualAPIError.transport(error)
        } catch {
            throw ActualAPIError.transport(nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualAPIError.invalidResponse
        }
        Self.debugLogResponse(httpResponse, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.sanitizedBodySnippet(
                data: data,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
            )
            throw ActualAPIError.httpStatus(httpResponse.statusCode, message)
        }
        return data
    }

    private func binaryRequest(
        path: String,
        token: String,
        body: Data
    ) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")

        guard let url = components?.url else {
            throw ActualAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/actual-sync", forHTTPHeaderField: "Content-Type")
        request.setValue("application/actual-sync", forHTTPHeaderField: "Accept")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Self.debugLogRequest(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ActualAPIError.transport(error)
        } catch {
            throw ActualAPIError.transport(nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualAPIError.invalidResponse
        }
        Self.debugLogResponse(httpResponse, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.sanitizedBodySnippet(
                data: data,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type")
            )
            throw ActualAPIError.httpStatus(httpResponse.statusCode, message)
        }
        return data
    }

    private static func debugLogRequest(_ request: URLRequest) {
        #if DEBUG
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "<missing URL>"
        let headers = sanitizedHeaders(request.allHTTPHeaderFields ?? [:])
        let body = sanitizedBodySnippet(
            data: request.httpBody,
            contentType: request.value(forHTTPHeaderField: "Content-Type")
        )
        print("[Actualist LocalFirst] -> \(method) \(url)")
        print("[Actualist LocalFirst] -> headers: \(headers)")
        if body != "<empty>" {
            print("[Actualist LocalFirst] -> body: \(body)")
        }
        #endif
    }

    private static func debugLogResponse(_ response: HTTPURLResponse, data: Data) {
        #if DEBUG
        let url = response.url?.absoluteString ?? "<missing URL>"
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        let body = sanitizedBodySnippet(data: data, contentType: contentType)
        print("[Actualist LocalFirst] <- \(response.statusCode) \(url)")
        print("[Actualist LocalFirst] <- body: \(body)")
        #endif
    }

    private static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            if isSensitiveKey(pair.key) {
                result[pair.key] = "<redacted>"
            } else {
                result[pair.key] = pair.value
            }
        }
    }

    private static func sanitizedBodySnippet(data: Data?, contentType: String?) -> String {
        guard let data, !data.isEmpty else {
            return "<empty>"
        }

        let isText = contentType?.localizedCaseInsensitiveContains("json") == true
            || contentType?.localizedCaseInsensitiveContains("text") == true
            || data.count < 2_048
        guard isText else {
            return "<\(data.count) bytes>"
        }

        let sanitizedData = sanitizedJSONData(data) ?? data
        let text = String(data: sanitizedData, encoding: .utf8) ?? "<\(data.count) bytes, non-UTF8>"
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if let htmlMessage = readableHTMLMessage(from: singleLine) {
            return htmlMessage
        }
        if singleLine.count > 800 {
            return "\(singleLine.prefix(800))..."
        }
        return singleLine
    }

    private static func readableHTMLMessage(from text: String) -> String? {
        let lowercased = text.lowercased()
        guard lowercased.contains("<html")
            || lowercased.contains("<!doctype html")
            || lowercased.contains("<body")
            || lowercased.contains("<pre") else {
            return nil
        }

        let withoutTags = text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutTags.isEmpty else {
            return "HTML error response"
        }
        return withoutTags.count > 180 ? "\(withoutTags.prefix(180))..." : withoutTags
    }

    private static func sanitizedJSONData(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let sanitized = sanitizeJSONObject(object)
        return try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
    }

    private static func sanitizeJSONObject(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                if isSensitiveKey(pair.key) {
                    result[pair.key] = "<redacted>"
                } else {
                    result[pair.key] = sanitizeJSONObject(pair.value)
                }
            }
        }
        if let array = object as? [Any] {
            return array.map(sanitizeJSONObject)
        }
        return object
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized.contains("password")
            || normalized.contains("token")
            || normalized == "authorization"
            || normalized.contains("key")
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
    case httpStatus(Int, String?)
    case decoding(String)
    case transport(URLError?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server URL is invalid."
        case .invalidResponse:
            "The server returned an invalid response."
        case .missingTransactionID:
            "This transaction cannot be changed because the server did not provide its transaction ID."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                "The server returned HTTP \(status): \(message)"
            } else {
                "The server returned HTTP \(status)."
            }
        case .decoding(let message):
            "Actualist could not read the server response: \(message)"
        case .transport(let error):
            if error?.code == .timedOut {
                "The server did not respond. Check that this phone is on the same Wi-Fi as your Actual server and that the URL is correct."
            } else if error?.code == .notConnectedToInternet {
                "This device is not connected to the network."
            } else if let error {
                "Actualist could not reach the server: \(error.localizedDescription)"
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
