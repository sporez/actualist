import Foundation
import Security
@testable import Actualist

enum LocalFirstTestSyncError: Error, Equatable {
    case failed
}

actor RecordingSyncTransport: ActualSyncTransport {
    private var shouldFail = false
    private var delayNanoseconds: UInt64 = 0
    private var capturedMessageCounts: [Int] = []
    private var capturedSinceValues: [String] = []

    init(shouldFail: Bool = false, delayNanoseconds: UInt64 = 0) {
        self.shouldFail = shouldFail
        self.delayNanoseconds = delayNanoseconds
    }

    func sync(data: Data, token: String) async throws -> Data {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if shouldFail {
            throw LocalFirstTestSyncError.failed
        }

        let request = try ActualSync_SyncRequest(serializedBytes: data)
        capturedMessageCounts.append(request.messages.count)
        capturedSinceValues.append(request.since)

        var response = ActualSync_SyncResponse()
        response.messages = []
        return try response.serializedData()
    }

    func messageCounts() -> [Int] {
        capturedMessageCounts
    }

    func sinceValues() -> [String] {
        capturedSinceValues
    }
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
