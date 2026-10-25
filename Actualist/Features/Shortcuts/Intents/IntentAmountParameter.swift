import AppIntents

extension IntentParameter where Value == IntentCurrencyAmount {
    /// The parameter's amount, asking for it when Siri passed it empty
    /// (`ShortcutMoney.isMissing`).
    func valueAskingIfMissing(zeroIsMissing: Bool) async throws -> IntentCurrencyAmount {
        guard ShortcutMoney.isMissing(wrappedValue, zeroIsMissing: zeroIsMissing) else {
            return wrappedValue
        }
        return try await requestValue(IntentDialog("How much?"))
    }
}
