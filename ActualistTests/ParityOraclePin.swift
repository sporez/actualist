import Foundation

/// The pinned Actual release, read from `config/parity/oracle-pin.json` so oracle
/// tests assert fixture provenance against one record instead of a copied commit.
struct ParityOraclePin: Decodable {
    let tag: String
    let commit: String
    let packageVersion: String
    let fixtureDirectory: String

    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func load() throws -> ParityOraclePin {
        try JSONDecoder().decode(
            ParityOraclePin.self,
            from: Data(contentsOf: repositoryRoot.appending(path: "config/parity/oracle-pin.json"))
        )
    }

    /// The domain folder (for example `Splits`) inside the pinned fixture directory.
    static func fixtureURL(_ domain: String) throws -> URL {
        try repositoryRoot.appending(path: load().fixtureDirectory).appending(path: domain)
    }
}
