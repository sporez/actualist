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

    init(
        failurePoint: FailurePoint = .none,
        files: [ActualSyncRemoteFile] = [],
        token: String = "staged-token",
        downloadData: Data = Data()
    ) {
        self.failurePoint = failurePoint
        self.files = files
        self.token = token
        self.downloadData = downloadData
    }

    func loginMethods() async throws -> ActualLoginMethodsResponse {
        if failurePoint == .loginMethods {
            throw LocalFirstTestSyncError.failed
        }
        return try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self,
            from: Data(#"{"methods":["password"]}"#.utf8)
        )
    }

    func login(password: String) async throws -> ActualLoginResponse {
        if failurePoint == .login {
            throw LocalFirstTestSyncError.failed
        }
        return try JSONDecoder.actual.decode(
            ActualLoginResponse.self,
            from: Data(#"{"token":"\#(token)"}"#.utf8)
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

actor RecordingSyncTransport: ActualSyncTransport {
    private var remainingFailureCount = 0
    private var dropsUploadedMessages = false
    private var delayNanoseconds: UInt64 = 0
    private var capturedMessageCounts: [Int] = []
    private var capturedSinceValues: [String] = []
    private var serverMessagesByTimestamp: [String: ActualSync_MessageEnvelope] = [:]

    init(
        shouldFail: Bool = false,
        failureCount: Int = 0,
        dropsUploadedMessages: Bool = false,
        delayNanoseconds: UInt64 = 0
    ) {
        self.remainingFailureCount = shouldFail ? .max : max(0, failureCount)
        self.dropsUploadedMessages = dropsUploadedMessages
        self.delayNanoseconds = delayNanoseconds
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
            for message in request.messages {
                serverMessagesByTimestamp[message.timestamp] = message
            }
        }
        return try response.serializedData()
    }

    func messageCounts() -> [Int] {
        capturedMessageCounts
    }

    func sinceValues() -> [String] {
        capturedSinceValues
    }
}

struct FixedResponseSyncTransport: ActualSyncTransport {
    let responseData: Data

    func sync(data: Data, token: String) async throws -> Data {
        responseData
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

final class FakeKeychainBackend: KeychainBackend {
    var updateFailureStatus: OSStatus?
    var addFailureStatus: OSStatus?
    var deleteFailureStatus: OSStatus?
    var copyFailureStatus: OSStatus?

    private var items: [String: Data] = [:]

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
            let rows = items.keys.compactMap { key -> [String: Any]? in
                let parts = key.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
                guard parts.first == service, let account = parts.dropFirst().first else {
                    return nil
                }
                return [kSecAttrAccount as String: account]
            }
            guard !rows.isEmpty else {
                return errSecItemNotFound
            }
            result?.pointee = rows as AnyObject
            return errSecSuccess
        }

        guard returnsData, let account, let data = items[key(service: service, account: account)] else {
            return errSecItemNotFound
        }
        result?.pointee = data as AnyObject
        return errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        if let updateFailureStatus {
            return updateFailureStatus
        }
        let query = query as NSDictionary
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        let itemKey = key(service: service, account: account)
        guard items[itemKey] != nil else {
            return errSecItemNotFound
        }
        let attributes = attributes as NSDictionary
        if let data = attributes[kSecValueData as String] as? Data {
            items[itemKey] = data
        }
        return errSecSuccess
    }

    func add(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        if let addFailureStatus {
            return addFailureStatus
        }
        let query = query as NSDictionary
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        guard let data = query[kSecValueData as String] as? Data else {
            return errSecParam
        }
        items[key(service: service, account: account)] = data
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
