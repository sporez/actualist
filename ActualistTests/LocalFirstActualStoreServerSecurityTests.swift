import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func loginResponseDecodesTopLevelAndNestedToken() async throws {
        let topLevel = try JSONDecoder.actual.decode(
            ActualLoginResponse.self,
            from: Data(#"{"token":"abc"}"#.utf8)
        )
        let nested = try JSONDecoder.actual.decode(
            ActualLoginResponse.self,
            from: Data(#"{"data":{"token":"def"}}"#.utf8)
        )

        #expect(topLevel.token == "abc")
        #expect(nested.token == "def")
    }

    @Test func serverConnectionSecurityAllowsHTTPSWithoutWarning() async {
        #expect(ActualServerConnectionSecurity.warningMessage(for: "actual.example.com") == nil)
        #expect(ActualServerConnectionSecurity.blockedMessage(for: "actual.example.com") == nil)
    }

    @Test func serverConnectionSecurityWarnsForLocalHTTP() async {
        #expect(
            ActualServerConnectionSecurity.warningMessage(for: "http://192.168.1.16:5007")
                == ActualServerConnectionSecurity.localHTTPWarning
        )
        #expect(ActualServerConnectionSecurity.blockedMessage(for: "http://192.168.1.16:5007") == nil)
        #expect(ActualServerConnectionSecurity.localHTTPWarning.contains("server password"))
        #expect(ActualServerConnectionSecurity.localHTTPWarning.contains("long-lived sync token"))
        #expect(ActualServerConnectionSecurity.localHTTPWarning.contains("every request"))
        #expect(ActualServerConnectionSecurity.localHTTPWarning.contains("intercept"))
    }

    @Test func serverConnectionSecurityHandlesEveryTypedURLPrefixAndEmptyHost() {
        let addresses = [
            "http://192.168.1.16:5007",
            "HTTP://localhost:5006",
            "http://actual.tailnet-name.ts.net:5006",
            "http://[fe80::1%25en0]:5006",
            "https://actual.example.com"
        ]
        let malformedEmptyHostInputs = [
            "http://",
            " http:// ",
            "http:///actual",
            "http://:5006",
            "http://?query",
            "http://#fragment",
            "http://[]",
            "http://%25",
            "http://%25%25"
        ]

        func verifySecurityClassificationDoesNotCrash(_ input: String) {
            let warning = ActualServerConnectionSecurity.warningMessage(for: input)
            let blocked = ActualServerConnectionSecurity.blockedMessage(for: input)

            #expect(
                warning == nil || blocked == nil,
                "An address must not be both warned and blocked: \(input)"
            )
        }

        for address in addresses {
            var typedPrefix = ""
            verifySecurityClassificationDoesNotCrash(typedPrefix)
            for character in address {
                typedPrefix.append(character)
                verifySecurityClassificationDoesNotCrash(typedPrefix)
            }
        }

        for input in malformedEmptyHostInputs {
            verifySecurityClassificationDoesNotCrash(input)
        }
    }

    @Test(arguments: [
        "http://100.64.0.1:5006",
        "http://100.127.255.254:5006",
        "http://actual.tailnet-name.ts.net:5006",
        "http://[fc00::1]:5006",
        "http://[fd12:3456:789a::1]:5006",
        "http://[fe80::1]:5006",
        "http://[fe80::1%25en0]:5006",
        "http://[::ffff:192.168.1.20]:5006"
    ])
    func serverConnectionSecurityAllowsLocalAndTailnetHTTP(_ input: String) {
        #expect(
            ActualServerConnectionSecurity.warningMessage(for: input)
                == ActualServerConnectionSecurity.localHTTPWarning
        )
        #expect(ActualServerConnectionSecurity.blockedMessage(for: input) == nil)
    }

    @Test(arguments: [
        "http://100.63.255.255:5006",
        "http://100.128.0.1:5006",
        "http://[2001:db8::1]:5006",
        "http://actual.internal:5006"
    ])
    func serverConnectionSecurityBlocksNonlocalHTTP(_ input: String) {
        #expect(ActualServerConnectionSecurity.warningMessage(for: input) == nil)
        #expect(
            ActualServerConnectionSecurity.blockedMessage(for: input)
                == ActualServerConnectionSecurity.remoteHTTPBlockedMessage
        )
    }

    @Test func serverConnectionSecurityBlocksRemoteHTTP() async {
        #expect(ActualServerConnectionSecurity.warningMessage(for: "http://actual.example.com") == nil)
        #expect(
            ActualServerConnectionSecurity.blockedMessage(for: "http://actual.example.com")
                == ActualServerConnectionSecurity.remoteHTTPBlockedMessage
        )
    }

    @Test func serverConnectionSecurityDoesNotResolveUnrecognizedHostnames() {
        // This result must not depend on local DNS.
        #expect(
            ActualServerConnectionSecurity.blockedMessage(for: "http://budget.home.arpa:5006")
                == ActualServerConnectionSecurity.remoteHTTPBlockedMessage
        )
    }

    @Test func loginMethodsDecodeActualServerObjectShape() async throws {
        let response = try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self,
            from: Data("""
            {
              "status": "ok",
              "methods": [
                { "method": "password", "active": 1, "displayName": "Password" },
                { "method": "openid", "active": 0, "displayName": "OpenID" }
              ]
            }
            """.utf8)
        )

        #expect(response.methods == ["password"])
    }

    @Test func userFilesDecodeDeletedFilteringInputs() async throws {
        let data = Data("""
        {
          "groupId": "group-1",
          "files": [
            { "fileId": "file-1", "name": "Main" },
            { "fileId": "file-2", "name": "Old", "deleted": true }
          ]
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFilesResponse.self, from: data)
        let visible = response.files.filter { !$0.deleted }

        #expect(visible.map(\.fileID) == ["file-1"])
        #expect(visible.first?.name == "Main")
    }

    @Test func userFilesDecodeActualServerDataArrayShape() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": [
            {
              "deleted": 0,
              "encryptKeyId": "key-1",
              "fileId": "file-1",
              "groupId": "group-1",
              "name": "My Budget",
              "owner": "user-1",
              "usersWithAccess": [
                {
                  "displayName": "",
                  "owner": true,
                  "userId": "user-1",
                  "userName": ""
                }
              ]
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFilesResponse.self, from: data)

        #expect(response.groupID == nil)
        #expect(response.files.count == 1)
        #expect(response.files.first?.fileID == "file-1")
        #expect(response.files.first?.groupID == "group-1")
        #expect(response.files.first?.name == "My Budget")
        #expect(response.files.first?.deleted == false)
        #expect(response.files.first?.encryptKeyID == "key-1")
        #expect(response.files.first?.requiresEncryptionPassword == false)
        #expect(response.files.first?.syncEncryptionKeyID == nil)
    }

    @Test func userFileInfoDecodesActualServerDataObjectShape() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": {
            "deleted": 0,
            "encryptKeyId": "key-1",
            "fileId": "file-1",
            "groupId": "group-1",
            "name": "My Budget"
          }
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFileInfoResponse.self, from: data)

        #expect(response.file?.fileID == "file-1")
        #expect(response.file?.groupID == "group-1")
        #expect(response.file?.encryptKeyID == "key-1")
        #expect(response.file?.requiresEncryptionPassword == false)
        #expect(response.file?.syncEncryptionKeyID == nil)
    }

    @Test func userFileInfoTreatsNullEncryptMetaAsUnencrypted() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": {
            "fileId": "file-1",
            "groupId": "group-1",
            "name": "My Budget",
            "encryptMeta": null
          }
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFileInfoResponse.self, from: data)

        #expect(response.file?.requiresEncryptionPassword == false)
    }

    @Test func userFileInfoDetectsEncryptedDownloadMetadata() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": {
            "fileId": "file-1",
            "groupId": "group-1",
            "name": "My Budget",
            "encryptMeta": {
              "keyId": "key-1"
            }
          }
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFileInfoResponse.self, from: data)

        #expect(response.file?.requiresEncryptionPassword == true)
        #expect(response.file?.syncEncryptionKeyID == "key-1")
    }

    @Test func userKeyResponseDecodesNestedActualServerShape() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": {
            "id": "key-1",
            "salt": "salt-1",
            "test": "{\\"value\\":\\"abc\\",\\"meta\\":{\\"keyId\\":\\"key-1\\",\\"algorithm\\":\\"aes-256-gcm\\",\\"iv\\":\\"MTIzNDU2Nzg5MDEy\\",\\"authTag\\":\\"YWJjZGVmZ2hpamtsbW5vcA==\\"}}"
          }
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserKeyResponse.self, from: data)

        #expect(response.id == "key-1")
        #expect(response.salt == "salt-1")
        #expect(response.test?.contains("aes-256-gcm") == true)
    }
}
