import Foundation

/// Builds every request sent to an Actual server and owns the one write of
/// the `X-ACTUAL-TOKEN` header, the shared URL joining and the same-origin
/// check, so a client cannot send credentials to another origin. Each client
/// still states its own timeout, content type and extra headers.
struct ActualServerRequestBuilder: Sendable {
    let baseURL: URL
    let customHeaders: HTTPHeaderFields
    let redirectDelegate: CustomHTTPHeaderRedirectDelegate

    init(baseURL: URL, customHeaders: HTTPHeaderFields) {
        self.baseURL = baseURL
        self.customHeaders = customHeaders
        redirectDelegate = CustomHTTPHeaderRedirectDelegate(baseURL: baseURL, fields: customHeaders)
    }

    /// Configured custom headers are applied first, so every header below
    /// replaces a custom header of the same name.
    func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        token: String? = nil,
        fileID: String? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval,
        body: Data? = nil,
        contentType: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL(path: path, queryItems: queryItems))
        customHeaders.apply(to: &request)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        }
        if let fileID {
            request.setValue(fileID, forHTTPHeaderField: "X-ACTUAL-FILE-ID")
        }
        if let body {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func endpointURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        if !queryItems.isEmpty {
            let existingQueryItems = components?.queryItems ?? []
            components?.queryItems = existingQueryItems + queryItems
        }
        guard let url = components?.url, redirectDelegate.permits(source: baseURL, destination: url) else {
            throw ActualAPIError.invalidURL
        }
        return url
    }
}
