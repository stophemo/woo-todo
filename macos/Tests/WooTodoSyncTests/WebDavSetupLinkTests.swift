import Foundation
import Testing
@testable import WooTodoSync

@Suite("坚果云配置深链")
struct WebDavSetupLinkTests {
    private let username = "person@example.com"
    private let appPassword = "app-password-demo"
    private let vaultId = "vault-demo"
    private let vaultKey = Base64URL.encode(Data(repeating: 7, count: AES256GCM.keyByteCount))

    @Test("共享 fixture 可由 macOS 严格解析并往返")
    func sharedFixtureRoundTrip() throws {
        let fixture = try JSONDecoder().decode(
            SetupLinkFixture.self,
            from: Data(contentsOf: fixtureURL())
        )
        let value = try WebDavSetupLink(
            username: fixture.username,
            appPassword: fixture.appPassword,
            vaultId: fixture.vaultId,
            vaultKey: fixture.vaultKey
        )

        #expect(fixture.v == WebDavSetupLink.version)
        #expect(try WebDavSetupLink(url: value.url()) == value)
    }

    @Test("共享跨端 URI 与 macOS URLComponents 编码一致")
    func sharedURIEncoding() throws {
        let source = try String(contentsOf: fixtureURL(named: "webdav-setup-link-uri.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = try WebDavSetupLink(
            username: "person+tag@example.com",
            appPassword: "space and & equals= + slash/",
            vaultId: "personal-vault",
            vaultKey: Base64URL.encode(Data(repeating: 7, count: AES256GCM.keyByteCount))
        )

        #expect(try WebDavSetupLink(url: URL(string: source)!) == value)
        #expect(try value.url().absoluteString == source)
        #expect(try WebDavSetupLink(url: value.url()) == value)
    }

    @Test("严格往返且不泄露同步密钥")
    func roundTripAndRedaction() throws {
        let value = try WebDavSetupLink(
            username: username,
            appPassword: appPassword,
            vaultId: vaultId,
            vaultKey: vaultKey
        )
        let url = try value.url()
        let parsed = try WebDavSetupLink(url: url)

        #expect(parsed == value)
        #expect(url.scheme == "wootodo")
        #expect(url.host == "webdav")
        #expect(url.path.isEmpty)
        #expect(!url.absoluteString.contains("deviceId="))
        #expect(!url.absoluteString.contains("endpoint="))
        #expect(!value.description.contains(username))
        #expect(!value.description.contains(appPassword))
        #expect(!value.description.contains(vaultKey))
        #expect(!value.debugDescription.contains(username))
        #expect(!value.debugDescription.contains(appPassword))
        #expect(!value.debugDescription.contains(vaultKey))

        let escaped = try WebDavSetupLink(
            username: "person+tag@example.com",
            appPassword: "space and & equals=",
            vaultId: vaultId,
            vaultKey: vaultKey
        )
        #expect(try WebDavSetupLink(url: escaped.url()) == escaped)
    }

    @Test("只允许固定字段并拒绝重复、未知字段")
    func rejectsUnexpectedFields() throws {
        let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let encodedKey = vaultKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let encodedPassword = appPassword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let base = "wootodo://webdav?v=1&username=\(encodedUser)&appPassword=\(encodedPassword)&vaultId=\(vaultId)&vaultKey=\(encodedKey)"

        #expect(throws: WebDavSetupLinkError.duplicateOrUnknownField) {
            _ = try WebDavSetupLink(url: URL(string: base + "&extra=1")!)
        }
        #expect(throws: WebDavSetupLinkError.duplicateOrUnknownField) {
            _ = try WebDavSetupLink(url: URL(string: base + "&v=1")!)
        }
        #expect(throws: WebDavSetupLinkError.invalidScheme) {
            _ = try WebDavSetupLink(url: URL(string: base.replacingOccurrences(of: "webdav", with: "pair"))!)
        }
        #expect(throws: WebDavSetupLinkError.invalidScheme) {
            _ = try WebDavSetupLink(url: URL(string: base.replacingOccurrences(of: "webdav?", with: "webdav/path?"))!)
        }
        #expect(throws: WebDavSetupLinkError.invalidScheme) {
            _ = try WebDavSetupLink(url: URL(string: base + "#fragment")!)
        }
        #expect(throws: WebDavSetupLinkError.missingField("appPassword")) {
            _ = try WebDavSetupLink(
                url: URL(string: base.replacingOccurrences(
                    of: "appPassword=\(encodedPassword)",
                    with: "appPassword="
                ))!
            )
        }
    }

    @Test("拒绝错误版本、非法账号、空间名和密钥")
    func rejectsInvalidValues() throws {
        #expect(throws: WebDavSetupLinkError.invalidVersion) {
            _ = try WebDavSetupLink(url: URL(string: "wootodo://webdav?v=2&username=u&appPassword=p&vaultId=vault-a&vaultKey=\(vaultKey)")!)
        }
        #expect(throws: WebDavSetupLinkError.invalidUsername) {
            _ = try WebDavSetupLink(
                username: "bad user",
                appPassword: appPassword,
                vaultId: vaultId,
                vaultKey: vaultKey
            )
        }
        #expect(throws: WebDavSetupLinkError.invalidAppPassword) {
            _ = try WebDavSetupLink(
                username: username,
                appPassword: "bad\npassword",
                vaultId: vaultId,
                vaultKey: vaultKey
            )
        }
        #expect(throws: WebDavSetupLinkError.invalidUsername) {
            _ = try WebDavSetupLink(
                username: String(repeating: "u", count: 321),
                appPassword: appPassword,
                vaultId: vaultId,
                vaultKey: vaultKey
            )
        }
        #expect(throws: WebDavSetupLinkError.invalidAppPassword) {
            _ = try WebDavSetupLink(
                username: username,
                appPassword: String(repeating: "p", count: 257),
                vaultId: vaultId,
                vaultKey: vaultKey
            )
        }
        #expect(throws: WebDavSetupLinkError.invalidVaultId) {
            _ = try WebDavSetupLink(
                username: username,
                appPassword: appPassword,
                vaultId: "../escape",
                vaultKey: vaultKey
            )
        }
        #expect(throws: WebDavSetupLinkError.invalidVaultKey) {
            _ = try WebDavSetupLink(
                username: username,
                appPassword: appPassword,
                vaultId: vaultId,
                vaultKey: "AA"
            )
        }
    }

    private func fixtureURL(named name: String = "webdav-setup-link.json") -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared")
            .appendingPathComponent("fixtures")
            .appendingPathComponent(name)
    }
}

private struct SetupLinkFixture: Decodable {
    let v: String
    let username: String
    let appPassword: String
    let vaultId: String
    let vaultKey: String
}
