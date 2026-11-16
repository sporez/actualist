import Foundation

enum EntityName {
    /// Trimmed, non-empty display name; `label` names the thing in the error
    /// ("category", "category group", "payee", "account group").
    static func validatedName(_ name: String, label: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalFirstError.invalidLocalWrite("\(label) name cannot be empty") }
        return trimmed
    }
}
