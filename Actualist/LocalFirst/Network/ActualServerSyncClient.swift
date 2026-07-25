import Foundation

protocol ActualSyncTransport: Sendable {
    func sync(data: Data, token: String) async throws -> Data
}

actor ActualServerSyncClient: ActualSyncTransport {
    let baseURL: URL
    private let session: URLSession
    private let resourceLimits: LocalFirstResourceLimits

    init(
        baseURL: URL,
        session: URLSession = .shared,
        resourceLimits: LocalFirstResourceLimits = .standard
    ) {
        self.baseURL = baseURL
        self.session = session
        self.resourceLimits = resourceLimits
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

    func downloadUserFile(fileID: String, token: String, to destinationURL: URL) async throws {
        var request = try URLRequest(url: endpointURL(path: "/sync/download-user-file"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        addAuthorizationHeaders(to: &request, token: token)
        request.setValue(fileID, forHTTPHeaderField: "X-ACTUAL-FILE-ID")
        try await executeDownload(request, to: destinationURL)
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

        return try await execute(
            request,
            responseByteLimit: resourceLimits.maximumSyncResponseBytes
        )
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

        return try await execute(
            request,
            responseByteLimit: resourceLimits.maximumSyncResponseBytes
        )
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

    private func execute(_ request: URLRequest, responseByteLimit: Int? = nil) async throws -> Data {
        Self.debugLogRequest(request)

        let data: Data
        let response: URLResponse
        do {
            if let responseByteLimit {
                (data, response) = try await limitedData(
                    for: request,
                    maximumBytes: responseByteLimit
                )
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let error as LocalFirstError {
            throw error
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

    private func limitedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw LocalFirstError.remoteDataLimitExceeded
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumBytes))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw LocalFirstError.remoteDataLimitExceeded
            }
            data.append(byte)
        }
        return (data, response)
    }

    private func executeDownload(_ request: URLRequest, to destinationURL: URL) async throws {
        Self.debugLogRequest(request)

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destinationURL.path) {
            guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
                throw LocalFirstError.invalidDownloadedBudget
            }
        }
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        do {
            try handle.truncate(atOffset: 0)
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ActualAPIError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ActualAPIError.httpStatus(httpResponse.statusCode)
            }
            guard httpResponse.expectedContentLength <= 0
                    || httpResponse.expectedContentLength <= Int64(resourceLimits.maximumCompressedBudgetBytes) else {
                throw LocalFirstError.remoteDataLimitExceeded
            }

            var byteCount: UInt64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                let (nextByteCount, overflow) = byteCount.addingReportingOverflow(1)
                guard !overflow,
                      nextByteCount <= resourceLimits.maximumCompressedBudgetBytes else {
                    throw LocalFirstError.remoteDataLimitExceeded
                }
                byteCount = nextByteCount
                buffer.append(byte)
                if buffer.count == 64 * 1_024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
            try handle.synchronize()
            Self.debugLogResponse(httpResponse, byteCount: byteCount)
        } catch let error as LocalFirstError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch let error as ActualAPIError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch let error as URLError {
            try? fileManager.removeItem(at: destinationURL)
            throw ActualAPIError.transport(error.code)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw ActualAPIError.transport(nil)
        }
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

    private static func debugLogResponse(_ response: HTTPURLResponse, byteCount: UInt64) {
        #if DEBUG
        print("[Actualist LocalFirst] <- HTTP \(response.statusCode) (\(byteCount) bytes)")
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
