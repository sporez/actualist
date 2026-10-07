import Foundation
import Testing
@testable import Actualist

/// Concurrency 5.5d (audit CA-19): parsing a large file stops when its task is cancelled.
struct TransactionCSVParserCancellationTests {
    @Test func aCancelledParseOfALargeFileStopsInsteadOfFinishing() async throws {
        var csv = "Date,Payee,Amount\n"
        for row in 0..<20_000 { csv += "2026-07-01,Payee \(row),-1.00\n" }
        let data = Data(csv.utf8)
        let go = TestLatch()
        let parse = Task {
            await go.wait()
            return try TransactionCSVParser().parse(data)
        }
        parse.cancel()
        go.trip()

        await #expect(throws: CancellationError.self) { _ = try await parse.value }
    }
}
