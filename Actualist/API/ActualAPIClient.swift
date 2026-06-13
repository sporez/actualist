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
        queryItems: [URLQueryItem] = []
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
}

enum ActualAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int, String?)
    case decoding(String)
    case transport(URLError?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server URL is invalid."
        case .invalidResponse:
            "The server returned an invalid response."
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
