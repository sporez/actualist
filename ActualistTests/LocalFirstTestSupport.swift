import Foundation
@testable import Actualist

enum LocalFirstTestSyncError: Error, Equatable {
    case failed
}

actor RecordingSyncTransport: ActualSyncTransport {
    private var shouldFail = false
    private var capturedMessageCounts: [Int] = []
    private var capturedSinceValues: [String] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func sync(data: Data, token: String) async throws -> Data {
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
