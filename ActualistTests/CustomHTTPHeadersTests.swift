import Foundation
import Security
import Testing
@testable import Actualist

struct CustomHTTPHeadersTests {
    @Test(arguments: ["Authorization", "X-Actual-Password", "CF-Access-Client-Id", "CF-Access-Client-Secret", "X-Authentik-Token", "X-Authelia", "!#$%&'*+-.^_`|~09AZaz"])
    func allowedNames(_ name: String) throws {
        let rows = try HTTPHeaderFields.validate([.init(name: " \(name) ", value: "  meaningful spaces  ")])
        #expect(rows[0].name == name)
        #expect(rows[0].value == "  meaningful spaces  ")
    }

    @Test(arguments: ["", " ", "bad name", "bad:name", "héad", "bad\r\nname"])
    func invalidNames(_ name: String) {
        #expect(throws: CustomHTTPHeaderError.invalidName) {
            try HTTPHeaderFields.validate([.init(name: name, value: "secret")])
        }
    }

    @Test(arguments: ["\r", "\n", "\0", "\t", "\u{7f}", "\u{85}"])
    func injection(_ value: String) {
        #expect(throws: CustomHTTPHeaderError.invalidValue) {
            try HTTPHeaderFields.validate([.init(name: "X-Test", value: "a\(value)b")])
        }
    }

    @Test(arguments: Array(HTTPHeaderFields.reservedNames))
    func reserved(_ name: String) {
        #expect(throws: CustomHTTPHeaderError.reservedName) {
            try HTTPHeaderFields.validate([.init(name: name.uppercased(), value: "secret")])
        }
    }

    @Test func duplicate() {
        #expect(throws: CustomHTTPHeaderError.duplicateName) {
            try HTTPHeaderFields.validate([.init(name: "X-Test", value: "1"), .init(name: "x-test", value: "2")])
        }
    }

    @Test func originAndRedirectBoundaries() throws {
        let url = URL(string: "https://EXAMPLE.com/a")!
        let endpoint = try EndpointCustomHTTPHeaders(url: url, headers: [.init(name: "Authorization", value: "secret")])
        let fields = try HTTPHeaderFields(endpoint: endpoint)
        for text in ["https://example.com/b", "https://example.com:443/"] {
            let destination = URL(string: text)!
            #expect(endpoint.applies(to: destination))
            #expect(fields.initialBrowserHeaders(for: destination)["Authorization"] == "secret")
            var request = URLRequest(url: destination)
            fields.apply(to: &request)
            request.setValue("actual-token", forHTTPHeaderField: "X-ACTUAL-TOKEN")
            let redirected = fields.redirectRequest(request, from: url)
            #expect(redirected.value(forHTTPHeaderField: "Authorization") == "secret")
            #expect(redirected.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "actual-token")
        }
        for text in ["https://other.example", "http://example.com", "https://example.com:444"] {
            let destination = URL(string: text)!
            #expect(!endpoint.applies(to: destination))
            #expect(fields.initialBrowserHeaders(for: destination).isEmpty)
            var request = URLRequest(url: destination)
            request.setValue("secret", forHTTPHeaderField: "Authorization")
            #expect(fields.redirectRequest(request, from: url).value(forHTTPHeaderField: "Authorization") == nil)
            request.url = url
            #expect(fields.redirectRequest(request, from: destination).value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test func apiRedirectOriginIsIndependentOfCustomHeaders() throws {
        let base = URL(string: "https://EXAMPLE.com/prefix")!
        let policy = CustomHTTPHeaderRedirectDelegate(baseURL: base, fields: .empty)
        #expect(policy.permits(source: base, destination: URL(string: "https://example.com:443/other")))
        for destination in [
            "http://example.com/", "https://example.com:444/", "https://other.example/",
            "https://user@example.com/", "file:///private/secret", "https://example.com:0/"
        ] {
            #expect(!policy.permits(source: base, destination: URL(string: destination)))
        }
        #expect(!policy.permits(source: nil, destination: base))
        #expect(!policy.permits(source: base, destination: nil))
        #expect(!policy.permits(source: URL(string: "https://other.example"), destination: base))
        let invalid = CustomHTTPHeaderRedirectDelegate(baseURL: URL(fileURLWithPath: "/private/file"), fields: .empty)
        #expect(!invalid.permits(source: base, destination: base))
        let response = HTTPURLResponse(url: base, statusCode: 307, httpVersion: nil,
            headerFields: ["Location": "https://other.example/"])!
        #expect(policy.refuses(response))
        let same = HTTPURLResponse(url: base, statusCode: 308, httpVersion: nil,
            headerFields: ["Location": "/another-path"])!
        #expect(!policy.refuses(same))
    }

    @Test @MainActor func keychainAtomicIsolationEraseAndBackgroundAccessibility() throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(service: UUID().uuidString, account: "token", backend: backend)
        let primary = try EndpointCustomHTTPHeaders(url: URL(string: "https://primary.example")!, headers: [.init(name: "X-Primary", value: "primary-secret")])
        let fallback = try EndpointCustomHTTPHeaders(url: URL(string: "https://fallback.example")!, headers: [.init(name: "X-Fallback", value: "fallback-secret")])
        let configuration = CustomHTTPHeaderConfiguration(primary: primary, fallback: fallback)
        try keychain.saveCustomHTTPHeaders(configuration)
        #expect(try keychain.readCustomHTTPHeaders() == configuration)
        try keychain.saveActualSyncToken("actual-token")
        try keychain.promoteAllItemsForBackgroundRefresh()
        try keychain.removeCustomHTTPHeaders()
        try keychain.saveCustomHTTPHeaders(configuration)
        #expect(backend.storedItemAttributes(service: keychain.service).allSatisfy {
            $0[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        })
        backend.updateFailureStatus = errSecAuthFailed
        #expect(throws: (any Error).self) { try keychain.saveCustomHTTPHeaders(.init(primary: fallback)) }
        backend.updateFailureStatus = nil
        #expect(try keychain.readCustomHTTPHeaders() == configuration)
        backend.copyFailureStatus = errSecInteractionNotAllowed
        #expect(throws: CustomHTTPHeaderError.unreadableConfiguration) { try keychain.readCustomHTTPHeaders() }
        backend.copyFailureStatus = nil
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalFirstActualStore(keychain: keychain, fileManager: BudgetFileManager(applicationSupportURL: root))
        try store.eraseLocalData()
        #expect(try keychain.readCustomHTTPHeaders() == .init())
        try keychain.saveCustomHTTPHeaders(configuration)
        try keychain.saveCustomHTTPHeaders(.init())
        #expect(try keychain.readCustomHTTPHeaders() == .init())
    }

    @Test func decodedHeadersAreNormalizedAndValidated() throws {
        let data = Data(#"{"origin":{"scheme":"https","host":"example.com","port":443},"headers":[{"id":"00000000-0000-0000-0000-000000000001","name":" X-Test ","value":"secret"}]}"#.utf8)
        let endpoint = try JSONDecoder().decode(EndpointCustomHTTPHeaders.self, from: data)
        #expect(endpoint.headers[0].name == "X-Test")
        let invalid = String(decoding: data, as: UTF8.self).replacingOccurrences(of: " X-Test ", with: "Content-Type")
        #expect(throws: CustomHTTPHeaderError.reservedName) {
            try JSONDecoder().decode(EndpointCustomHTTPHeaders.self, from: Data(invalid.utf8))
        }
        let redactor = DiagnosticReportRedactor(sensitiveValues: [], credentials: ["xy"])
        #expect(!redactor.redact("server echoed xy").contains("xy"))
    }

    @Test func printableValuesAreRedacted() throws {
        let row = CustomHTTPHeader(name: "Authorization", value: "secret-sentinel")
        let endpoint = try EndpointCustomHTTPHeaders(url: URL(string: "https://example.com")!, headers: [row])
        #expect(!String(reflecting: row).contains("secret-sentinel"))
        #expect(!String(reflecting: endpoint).contains("secret-sentinel"))
        let fields = try HTTPHeaderFields(endpoint: endpoint)
        #expect(!String(reflecting: fields).contains("secret-sentinel"))
        #expect(ActualAPIError.serverRejected(status: nil, reason: .sessionExpired).isAuthenticationFailure)
    }
}
