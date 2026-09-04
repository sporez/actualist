import Foundation
import Security
@testable import Actualist

enum LocalFirstTestSyncError: Error, Equatable {
    case failed
}

actor StubConnectionTransport: ActualServerConnectionTransport {
    enum FailurePoint: Sendable, Equatable {
        case none
        case loginMethods
        case login
        case listBudgets
        case download
    }

    let failurePoint: FailurePoint
    let files: [ActualSyncRemoteFile]
    let token: String
    let downloadData: Data
    let openIDAuthorizationURL: URL
    let loginMethodsData: Data
    private(set) var capturedOpenIDReturnURL: URL?
    private(set) var capturedFirstTimeLoginPassword: String?

    init(
        failurePoint: FailurePoint = .none,
        files: [ActualSyncRemoteFile] = [],
        token: String = "staged-token",
        downloadData: Data = Data(),
        openIDAuthorizationURL: URL = URL(string: "https://identity.example/authorize")!,
        loginMethodsData: Data = Data(#"{"methods":["password"]}"#.utf8)
    ) {
        self.failurePoint = failurePoint
        self.files = files
        self.token = token
        self.downloadData = downloadData
        self.openIDAuthorizationURL = openIDAuthorizationURL
        self.loginMethodsData = loginMethodsData
    }

    func loginMethods() async throws -> ActualLoginMethodsResponse {
        if failurePoint == .loginMethods {
            throw LocalFirstTestSyncError.failed
        }
        return try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self,
            from: loginMethodsData
        )
    }

    func loginWithPassword(password: String) async throws -> ActualLoginResponse {
        if failurePoint == .login {
            throw LocalFirstTestSyncError.failed
        }
        return try JSONDecoder.actual.decode(
            ActualLoginResponse.self,
            from: Data(#"{"token":"\#(token)"}"#.utf8)
        )
    }

    func beginOpenIDLogin(
        returnURL: URL,
        firstTimeLoginPassword: String?
    ) async throws -> ActualOpenIDStartResponse {
        if failurePoint == .login {
            throw LocalFirstTestSyncError.failed
        }
        capturedOpenIDReturnURL = returnURL
        capturedFirstTimeLoginPassword = firstTimeLoginPassword
        return try JSONDecoder.actual.decode(
            ActualOpenIDStartResponse.self,
            from: Data(#"{"data":{"returnUrl":"\#(openIDAuthorizationURL.absoluteString)"}}"#.utf8)
        )
    }

    func listUserFiles(token: String) async throws -> [ActualSyncRemoteFile] {
        if failurePoint == .listBudgets {
            throw LocalFirstTestSyncError.failed
        }
        return files
    }

    func userFileInfo(fileID: String, token: String) async throws -> ActualSyncRemoteFile? {
        files.first { $0.fileID == fileID }
    }

    func downloadUserFile(fileID: String, token: String, to destinationURL: URL) async throws {
        if failurePoint == .download {
            try downloadData.prefix(max(1, downloadData.count / 2)).write(to: destinationURL)
            throw LocalFirstTestSyncError.failed
        }
        try downloadData.write(to: destinationURL)
    }

    func userKey(fileID: String, token: String) async throws -> ActualUserKeyResponse {
        throw LocalFirstTestSyncError.failed
    }
}

/// Connection transport with per-method error injection and call recording.
/// Use `error:` to fail every method (replacing `FailingConnectionTransport`),
/// or `methodErrors:` to fail one call while serving files/download data.
actor ConfigurableConnectionTransport: ActualServerConnectionTransport {
    enum Method: String, Sendable, Equatable, Hashable {
        case loginMethods
        case loginWithPassword
        case beginOpenIDLogin
        case listUserFiles
        case userFileInfo
        case downloadUserFile
        case userKey
    }

    private let defaultError: ActualAPIError?
    private let methodErrors: [Method: ActualAPIError]
    private let files: [ActualSyncRemoteFile]
    private let downloadData: Data
    private let writePartialPrefixBeforeThrowingDownloadError: Bool
    private let userKeyResponse: ActualUserKeyResponse?
    private let token: String
    private let loginMethodsData: Data
    private var recorded: [Method] = []

    init(
        error: ActualAPIError? = nil,
        methodErrors: [Method: ActualAPIError] = [:],
        files: [ActualSyncRemoteFile] = [],
        downloadData: Data = Data(),
        writePartialPrefixBeforeThrowingDownloadError: Bool = false,
        userKeyResponse: ActualUserKeyResponse? = nil,
        token: String = "staged-token",
        loginMethodsData: Data = Data(#"{"methods":["password"]}"#.utf8)
    ) {
        self.defaultError = error
        self.methodErrors = methodErrors
        self.files = files
        self.downloadData = downloadData
        self.writePartialPrefixBeforeThrowingDownloadError = writePartialPrefixBeforeThrowingDownloadError
        self.userKeyResponse = userKeyResponse
        self.token = token
        self.loginMethodsData = loginMethodsData
    }

    func recordedMethods() -> [Method] {
        recorded
    }

    private func record(_ method: Method) throws {
        recorded.append(method)
        if let error = methodErrors[method] ?? defaultError {
            throw error
        }
    }

    func loginMethods() async throws -> ActualLoginMethodsResponse {
        try record(.loginMethods)
        return try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self,
            from: loginMethodsData
        )
    }

    func loginWithPassword(password: String) async throws -> ActualLoginResponse {
        try record(.loginWithPassword)
        return try JSONDecoder.actual.decode(
            ActualLoginResponse.self,
            from: Data(#"{"token":"\(token)"}"#.utf8)
        )
    }

    func beginOpenIDLogin(
        returnURL: URL,
        firstTimeLoginPassword: String?
    ) async throws -> ActualOpenIDStartResponse {
        try record(.beginOpenIDLogin)
        return try JSONDecoder.actual.decode(
            ActualOpenIDStartResponse.self,
            from: Data(#"{"data":{"returnUrl":"https://identity.example/authorize"}}"#.utf8)
        )
    }

    func listUserFiles(token: String) async throws -> [ActualSyncRemoteFile] {
        try record(.listUserFiles)
        return files
    }

    func userFileInfo(fileID: String, token: String) async throws -> ActualSyncRemoteFile? {
        try record(.userFileInfo)
        return files.first { $0.fileID == fileID }
    }

    func downloadUserFile(fileID: String, token: String, to destinationURL: URL) async throws {
        recorded.append(.downloadUserFile)
        if let error = methodErrors[.downloadUserFile] ?? defaultError {
            if writePartialPrefixBeforeThrowingDownloadError {
                try downloadData.prefix(max(1, downloadData.count / 2)).write(to: destinationURL)
            }
            throw error
        }
        try downloadData.write(to: destinationURL)
    }

    func userKey(fileID: String, token: String) async throws -> ActualUserKeyResponse {
        try record(.userKey)
        if let userKeyResponse {
            return userKeyResponse
        }
        throw LocalFirstTestSyncError.failed
    }
}

actor RecordingSyncTransport: ActualSyncTransport {
    private var remainingFailureCount = 0
    private var dropsUploadedMessages = false
    private var delayNanoseconds: UInt64 = 0
    private var capturedMessageCounts: [Int] = []
    private var capturedSinceValues: [String] = []
    private var serverMessagesByTimestamp: [String: ActualSync_MessageEnvelope] = [:]
    private let lostResponseAtCall: Int?

    init(
        shouldFail: Bool = false,
        failureCount: Int = 0,
        dropsUploadedMessages: Bool = false,
        delayNanoseconds: UInt64 = 0,
        lostResponseAtCall: Int? = nil
    ) {
        self.remainingFailureCount = shouldFail ? .max : max(0, failureCount)
        self.dropsUploadedMessages = dropsUploadedMessages
        self.delayNanoseconds = delayNanoseconds
        self.lostResponseAtCall = lostResponseAtCall
    }

    func sync(data: Data, token: String) async throws -> Data {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if remainingFailureCount > 0 {
            remainingFailureCount -= 1
            throw LocalFirstTestSyncError.failed
        }

        let request = try ActualSync_SyncRequest(serializedBytes: data)
        capturedMessageCounts.append(request.messages.count)
        capturedSinceValues.append(request.since)

        var response = ActualSync_SyncResponse()
        response.messages = serverMessagesByTimestamp.values
            .filter { $0.timestamp > request.since }
            .sorted { $0.timestamp < $1.timestamp }
        if !dropsUploadedMessages {
            // Actual 26.9.0 uses INSERT OR IGNORE: retries retain the first envelope.
            for message in request.messages where serverMessagesByTimestamp[message.timestamp] == nil {
                serverMessagesByTimestamp[message.timestamp] = message
            }
        }
        if capturedMessageCounts.count == lostResponseAtCall {
            throw LocalFirstTestSyncError.failed
        }
        return try response.serializedData()
    }

    func messageCounts() -> [Int] {
        capturedMessageCounts
    }

    func sinceValues() -> [String] {
        capturedSinceValues
    }

    func seedServerMessages(_ messages: [ActualSyncDecodedMessage]) throws {
        for message in messages {
            let envelope = try LocalFirstSyncMessageBuilder.envelope(for: message)
            serverMessagesByTimestamp[envelope.timestamp] = envelope
        }
    }
}

actor AuthenticationFailureSyncTransport: ActualSyncTransport {
    func sync(data: Data, token: String) async throws -> Data {
        throw ActualAPIError.serverRejected(
            status: 401,
            reason: "unauthorized",
            details: "token-not-found"
        )
    }
}

struct FixedResponseSyncTransport: ActualSyncTransport {
    let responseData: Data

    func sync(data: Data, token: String) async throws -> Data {
        responseData
    }
}

final class PlaintextEnvelopeAuditRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [PlaintextEnvelopeAuditEvent] = []

    func record(_ event: PlaintextEnvelopeAuditEvent) {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
    }

    func events() -> [PlaintextEnvelopeAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

final class ResourceLimitURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body: Data
        switch request.url?.host {
        case "small-download.example":
            body = Data("small".utf8)
        default:
            body = Data(repeating: 0x41, count: 9)
        }
        var headers = ["Content-Type": "application/octet-stream"]
        if request.url?.host == "small-download.example" {
            headers["Content-Length"] = String(body.count)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CredentialStorageURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body: Data
        if request.url?.path.hasSuffix("/sync/list-user-files") == true {
            body = Data(#"{"status":"ok","data":[]}"#.utf8)
        } else {
            body = Data(#"{"status":"ok","methods":["password"]}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Cache-Control": "public, max-age=3600",
                "Content-Type": "application/json",
                "Set-Cookie": "actual_session=sensitive; Path=/; Secure; HttpOnly"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CredentialHeaderURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let hasExpectedToken = request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "sensitive-token"
        let hasNoBearerToken = request.value(forHTTPHeaderField: "Authorization") == nil
        let statusCode = hasExpectedToken && hasNoBearerToken ? 200 : 400
        let body = Data(#"{"status":"ok","data":[]}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Test-only. Mutated from the test's single cooperative thread, never shared
// with production code or a second test at the same time.
final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    var updateFailureStatus: OSStatus?
    var addFailureStatus: OSStatus?
    var deleteFailureStatus: OSStatus?
    var copyFailureStatus: OSStatus?
    private(set) var updateCallCount = 0

    private var items: [String: [String: Any]] = [:]

    func storedItemAttributes(service: String) -> [[String: Any]] {
        items.values.filter {
            ($0[kSecAttrService as String] as? String) == service
        }
    }

    func resetUpdateCallCount() {
        updateCallCount = 0
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        if let copyFailureStatus {
            return copyFailureStatus
        }
        let query = query as NSDictionary
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String
        let returnsAttributes = (query[kSecReturnAttributes as String] as? Bool) == true
        let returnsData = (query[kSecReturnData as String] as? Bool) == true

        if returnsAttributes {
            let rows = items.values.compactMap { item -> [String: Any]? in
                guard (item[kSecAttrService as String] as? String) == service,
                      account == nil || (item[kSecAttrAccount as String] as? String) == account else {
                    return nil
                }
                var attributes = item
                attributes[kSecValueData as String] = nil
                return attributes
            }
            guard !rows.isEmpty else {
                return errSecItemNotFound
            }
            let returnsAll = query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String
            if returnsAll {
                result?.pointee = rows as NSArray
            } else {
                result?.pointee = rows[0] as NSDictionary
            }
            return errSecSuccess
        }

        guard returnsData,
              let account,
              let item = items[key(service: service, account: account)],
              let data = item[kSecValueData as String] as? Data else {
            return errSecItemNotFound
        }
        result?.pointee = data as AnyObject
        return errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        updateCallCount += 1
        if let updateFailureStatus {
            return updateFailureStatus
        }
        let query = query as NSDictionary
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String
        let matchingKeys = items.compactMap { itemKey, item -> String? in
            guard (item[kSecAttrService as String] as? String) == service,
                  account == nil || (item[kSecAttrAccount as String] as? String) == account else {
                return nil
            }
            return itemKey
        }
        guard !matchingKeys.isEmpty else {
            return errSecItemNotFound
        }

        let attributes = attributes as NSDictionary
        var updatedItems = items
        for itemKey in matchingKeys {
            guard var item = updatedItems[itemKey] else {
                return errSecItemNotFound
            }
            for (key, value) in attributes {
                guard let key = key as? String else {
                    continue
                }
                item[key] = value
            }
            updatedItems[itemKey] = item
        }
        items = updatedItems
        return errSecSuccess
    }

    func add(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        if let addFailureStatus {
            return addFailureStatus
        }
        let query = query as NSDictionary
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        guard query[kSecValueData as String] is Data,
              query[kSecAttrAccessible as String] != nil else {
            return errSecParam
        }
        let itemKey = key(service: service, account: account)
        guard items[itemKey] == nil else {
            return errSecDuplicateItem
        }
        items[itemKey] = query as? [String: Any] ?? [:]
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        if let deleteFailureStatus {
            return deleteFailureStatus
        }
        let query = query as NSDictionary
        let service = query[kSecAttrService as String] as? String ?? ""
        guard let account = query[kSecAttrAccount as String] as? String else {
            let matchingKeys = items.keys.filter { $0.hasPrefix("\(service)\u{1f}") }
            guard !matchingKeys.isEmpty else {
                return errSecItemNotFound
            }
            matchingKeys.forEach { items[$0] = nil }
            return errSecSuccess
        }

        let itemKey = key(service: service, account: account)
        guard items.removeValue(forKey: itemKey) != nil else {
            return errSecItemNotFound
        }
        return errSecSuccess
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{1f}\(account)"
    }
}
