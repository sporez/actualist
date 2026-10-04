import Foundation

/// Import size caps (plan decision D6c). They bound memory and the time spent
/// on parse and match; a larger file is rejected before prepare is called.
enum TransactionCSVImportLimits {
    static let maxFileBytes = 10 * 1024 * 1024
    static let maxRows = 50_000
}

/// File read, parse, map and match stages that do not touch the store. Each is
/// `@concurrent` so a large file never runs on the main actor: this target's
/// approachable-concurrency setting would otherwise run a plain `nonisolated
/// async` function on its caller's actor.
enum TransactionCSVImportPipeline {
    /// Reads the file with security-scoped access held open for the whole
    /// read. The size is checked before any bytes are read, and again on the
    /// bytes in case the file grew in between.
    @concurrent
    static func readFile(
        at url: URL,
        maxBytes: Int = TransactionCSVImportLimits.maxFileBytes
    ) async throws -> Data {
        let secured = url.startAccessingSecurityScopedResource()
        defer {
            if secured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            throw TransactionCSVImportError.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else {
            throw TransactionCSVImportError.fileTooLarge
        }
        return data
    }

    /// Parse and all-or-nothing mapping. The row cap is checked on the parse
    /// result, before any row is mapped.
    @concurrent
    static func rows(
        from data: Data,
        options: TransactionCSVImportOptions,
        maxBytes: Int = TransactionCSVImportLimits.maxFileBytes,
        maxRows: Int = TransactionCSVImportLimits.maxRows
    ) async throws -> [TransactionCSVImportRow] {
        guard data.count <= maxBytes else {
            throw TransactionCSVImportError.fileTooLarge
        }
        let table = try TransactionCSVParser(
            options: TransactionCSVParser.Options(
                delimiter: options.delimiter,
                hasHeaderRow: options.hasHeaderRow
            )
        ).parse(data)
        guard table.rows.count <= maxRows else {
            throw TransactionCSVImportError.tooManyRows
        }
        return try TransactionCSVImportMapper.map(table)
    }

    @concurrent
    static func match(
        rows: [TransactionCSVImportRow],
        candidates: [TransactionCSVImportCandidate],
        context: TransactionCSVImportMatchContext
    ) async -> [TransactionCSVImportDisposition] {
        TransactionCSVImportMatcher.match(rows: rows, candidates: candidates, context: context)
    }
}
