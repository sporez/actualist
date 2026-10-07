import Foundation

/// Import size caps (plan decision D6c). They bound memory and the time spent
/// on parse and match; a larger file is rejected before prepare is called.
enum TransactionCSVImportLimits {
    static let maxFileBytes = 10 * 1024 * 1024
    static let maxRows = 50_000
}

/// File read, parse and map stages that do not touch the store. Each is
/// `@concurrent` to state that a large file never runs on the main actor. The
/// app target does not enable approachable concurrency (only the UI-test
/// target does), so a plain `nonisolated async` function would also leave the
/// caller's actor; the attribute keeps that true if the setting is ever added.
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
}
