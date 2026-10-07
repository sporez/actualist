import Foundation
import Testing
@testable import Actualist

struct BudgetFileManagerDownloadStagingTests {
    private func makeFileManager() -> BudgetFileManager {
        BudgetFileManager(
            applicationSupportURL: FileManager.default.temporaryDirectory
                .appending(path: "DownloadStaging-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
    }

    @Test func concurrentStagingsForOneFileIDStaySeparate() throws {
        let fileManager = makeFileManager()
        let first = try fileManager.prepareDownloadStaging(fileID: "file-1")
        try Data("first".utf8).write(to: first)
        let second = try fileManager.prepareDownloadStaging(fileID: "file-1")
        try Data("second".utf8).write(to: second)

        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data("first".utf8))
        #expect(try Data(contentsOf: second) == Data("second".utf8))

        fileManager.cleanupDownloadStaging(at: first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        fileManager.cleanupDownloadStaging(at: second)
    }

    @Test func sweepRemovesStaleStagingFilesOnly() throws {
        let fileManager = makeFileManager()
        let leftover = try fileManager.prepareDownloadStaging(fileID: "file-1")
        let directory = try fileManager.budgetDirectory(fileID: "file-1")
        let unrelated = directory.appending(path: "db.sqlite")
        try Data("db".utf8).write(to: unrelated)

        fileManager.sweepStaleDownloadStaging(fileID: "file-1")

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
