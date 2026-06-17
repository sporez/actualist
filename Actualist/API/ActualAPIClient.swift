import Foundation

struct ActualAPIClient: Sendable {
    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared

    func budgets() async throws -> [ActualBudget] {
        try await get("/budgets")
    }

    func budgetMonth(budgetID: String, month: String) async throws -> BudgetMonth {
        try await get("/budgets/\(budgetID)/months/\(month)")
    }

    func budgetMonthAlerts(budgetID: String, month: String) async throws -> APIBudgetMonthAlerts {
        try await get("/budgets/\(budgetID)/months/\(month)/alerts")
    }

    func updateBudgetMonthCategory(
        budgetID: String,
        month: String,
        categoryID: String,
        budgeted: Int
    ) async throws -> APIGeneralResponseMessage {
        try await request(
            path: "/budgets/\(budgetID)/months/\(month)/categories/\(categoryID)",
            method: "PATCH",
            body: APIBudgetMonthCategoryUpdatePayload(budgeted: budgeted)
        )
    }

    func budgetMonths(budgetID: String) async throws -> [String] {
        try await get("/budgets/\(budgetID)/months")
    }

    func accounts(budgetID: String) async throws -> [ActualAccount] {
        try await get("/budgets/\(budgetID)/accounts")
    }

    func balance(budgetID: String, accountID: String) async throws -> Int {
        try await get("/budgets/\(budgetID)/accounts/\(accountID)/balance")
    }

    func transactions(budgetID: String, accountID: String) async throws -> [ActualTransaction] {
        try await get(
            "/budgets/\(budgetID)/accounts/\(accountID)/transactions",
            queryItems: [URLQueryItem(name: "since_date", value: "1900-01-01")]
        )
    }

    func payees(budgetID: String) async throws -> [ActualPayee] {
        try await get("/budgets/\(budgetID)/payees")
    }

    func categories(budgetID: String) async throws -> [ActualCategory] {
        try await get("/budgets/\(budgetID)/categories")
    }

    func createTransaction(
        budgetID: String,
        draft: TransactionDraft
    ) async throws -> APITransactionBatchUpdateResult {
        let payload = APITransactionBatchUpdatePayload(
            added: [
                Self.transactionPayload(
                    from: draft,
                    id: UUID().uuidString
                )
            ]
        )

        let response: APIDataResponse<APITransactionBatchUpdateResult> = try await request(
            path: "/budgets/\(budgetID)/transactions/batch-update",
            method: "POST",
            body: payload
        )
        return response.data
    }

    func updateTransaction(
        budgetID: String,
        transactionID: String,
        draft: TransactionDraft
    ) async throws -> APITransactionBatchUpdateResult {
        let payload = APITransactionBatchUpdatePayload(
            added: [],
            updated: [
                Self.transactionPayload(
                    from: draft,
                    id: transactionID
                )
            ]
        )

        let response: APIDataResponse<APITransactionBatchUpdateResult> = try await request(
            path: "/budgets/\(budgetID)/transactions/batch-update",
            method: "POST",
            body: payload
        )
        return response.data
    }

    func deleteTransaction(
        budgetID: String,
        transaction: ActualTransaction
    ) async throws -> APITransactionBatchUpdateResult {
        let payload = APITransactionBatchUpdatePayload(
            added: [],
            updated: [],
            deleted: [try Self.transactionPayload(from: transaction)]
        )

        let response: APIDataResponse<APITransactionBatchUpdateResult> = try await request(
            path: "/budgets/\(budgetID)/transactions/batch-update",
            method: "POST",
            body: payload
        )
        return response.data
    }

    func runTransactionRules(
        budgetID: String,
        draft: TransactionDraft
    ) async throws -> TransactionRulePreview {
        let payload = APITransactionRulesRunPayload(
            transaction: Self.transactionPayload(
                from: draft,
                id: "actualist-preview-\(UUID().uuidString)"
            )
        )

        let response: APIDataResponse<APITransactionRulePreview> = try await request(
            path: "/budgets/\(budgetID)/rules/run",
            method: "POST",
            body: payload
        )

        return TransactionRulePreview(
            categoryID: response.data.category,
            notes: response.data.notes
        )
    }

    private func get<Value: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Value {
        let response: APIDataResponse<Value> = try await request(path: path, method: "GET", queryItems: queryItems)
        return response.data
    }

    private func request<Value: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: (any Encodable)? = nil
    ) async throws -> Value {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        if !queryItems.isEmpty {
            let existingQueryItems = components?.queryItems ?? []
            components?.queryItems = existingQueryItems + queryItems
        }

        guard let url = components?.url else {
            throw ActualAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder.actual.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ActualAPIError.transport(error)
        } catch {
            throw ActualAPIError.transport(nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualAPIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverMessage = (try? JSONDecoder().decode(APIGeneralError.self, from: data).error)
            throw ActualAPIError.httpStatus(httpResponse.statusCode, serverMessage)
        }

        do {
            return try JSONDecoder.actual.decode(Value.self, from: data)
        } catch {
            throw ActualAPIError.decoding(error.localizedDescription)
        }
    }

    private static func formattedTransactionDate(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private static func transactionPayload(
        from draft: TransactionDraft,
        id: String?
    ) -> APITransactionDraft {
        APITransactionDraft(
            id: id,
            account: draft.accountID,
            date: formattedTransactionDate(draft.date),
            amount: draft.amountMinorUnits,
            payee: draft.payeeID,
            payeeName: draft.payeeID == nil ? draft.payeeName : nil,
            category: draft.categoryID,
            notes: draft.notes,
            cleared: draft.cleared
        )
    }

    private static func transactionPayload(
        from transaction: ActualTransaction
    ) throws -> APITransactionDraft {
        guard let id = transaction.id else {
            throw ActualAPIError.missingTransactionID
        }

        return APITransactionDraft(
            id: id,
            account: transaction.account,
            date: transaction.date,
            amount: transaction.amount ?? 0,
            payee: transaction.payee,
            payeeName: transaction.payee == nil ? transaction.payeeName : nil,
            category: transaction.category,
            notes: transaction.notes,
            cleared: transaction.cleared?.boolValue ?? false
        )
    }
}

enum ActualAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case missingTransactionID
    case httpStatus(Int, String?)
    case decoding(String)
    case transport(URLError?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server URL is invalid."
        case .invalidResponse:
            "The server returned an invalid response."
        case .missingTransactionID:
            "This transaction cannot be changed because the API did not provide its transaction ID."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                "The server returned HTTP \(status): \(message)"
            } else {
                "The server returned HTTP \(status)."
            }
        case .decoding(let message):
            "Actualist could not read the API response: \(message)"
        case .transport(let error):
            if error?.code == .timedOut {
                "The server did not respond. Check that this phone is on the same Wi-Fi as your Actual server and that the URL is correct."
            } else if error?.code == .notConnectedToInternet {
                "This device is not connected to the network."
            } else if let error {
                "Actualist could not reach the server: \(error.localizedDescription)"
            } else {
                "Actualist could not reach the server."
            }
        }
    }
}

private struct APIGeneralError: Decodable {
    let error: String
}

extension JSONDecoder {
    static var actual: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}

extension JSONEncoder {
    static var actual: JSONEncoder {
        JSONEncoder()
    }
}
