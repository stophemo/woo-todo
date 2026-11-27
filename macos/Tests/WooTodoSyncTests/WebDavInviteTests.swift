import Foundation
import Testing
@testable import WooTodoSync

@Suite("WebDAV 邀请")
struct WebDavInviteTests {
    private let now = Date(timeIntervalSince1970: 1_765_000_000)
    private let credentials = WebDavCredentials(
        endpoint: URL(string: "https://dav.example.com/dav/WooTodo")!,
        username: "user@example.com",
        appPassword: "third-party-password",
        vaultId: "vault-invite-test",
        deviceId: "device-owner-01",
        vaultKey: Data(repeating: 9, count: AES256GCM.keyByteCount)
    )

    @Test("邀请可往返并生成独立设备身份")
    func roundTrip() throws {
        let invite = try WebDavInvite.create(credentials: credentials, now: now)
        let decoded = try WebDavInvite.decode(
            invite.encode(),
            now: now.addingTimeInterval(1)
        )

        #expect(decoded.account == credentials.account)
        #expect(decoded.vaultId == credentials.vaultId)
        #expect(decoded.vaultKey == credentials.vaultKey)
        #expect(decoded.issuedAt == now)
        #expect(decoded.expiresAt == now.addingTimeInterval(WebDavInvite.ttl))

        let identity = try decoded.identity(deviceId: "device-new-01")
        #expect(identity.vaultId == credentials.vaultId)
        #expect(identity.deviceId == "device-new-01")
        #expect(identity.vaultKey == credentials.vaultKey)
    }

    @Test("解码 Android 生成的邀请")
    func decodeAndroidInvite() throws {
        let encoded = """
        woo-todo-invite:1:eyJhcHBQYXNzd29yZCI6InRoaXJkLXBhcnR5LXBhc3N3b3JkIiwiZW5kcG9pbnQiOiJodHRwczovL2Rhdi5leGFtcGxlLmNvbS9kYXYvV29vVG9kbyIsImV4cGlyZXNBdCI6MTc2NTAwMDYwMDAwMCwiaXNzdWVkQXQiOjE3NjUwMDAwMDAwMDAsInVzZXJuYW1lIjoidXNlckBleGFtcGxlLmNvbSIsInYiOjEsInZhdWx0SWQiOiJ2YXVsdC1pbnZpdGUtdGVzdCIsInZhdWx0S2V5IjoiQ1FrSkNRa0pDUWtKQ1FrSkNRa0pDUWtKQ1FrSkNRa0pDUWtKQ1FrSkNRayJ9
        """
        let decoded = try WebDavInvite.decode(encoded, now: now)

        #expect(decoded.vaultId == "vault-invite-test")
        #expect(decoded.account == credentials.account)
        #expect(decoded.vaultKey == credentials.vaultKey)
        #expect(decoded.issuedAt == now)
        #expect(decoded.expiresAt == now.addingTimeInterval(WebDavInvite.ttl))
    }

    @Test("过期的邀请被拒绝")
    func expired() throws {
        let encoded = try WebDavInvite.create(credentials: credentials, now: now).encode()

        do {
            _ = try WebDavInvite.decode(
                encoded,
                now: now.addingTimeInterval(WebDavInvite.ttl + 1)
            )
            Issue.record("过期邀请不应通过")
        } catch let error as WebDavError {
            guard case .malformedObject(let message) = error else {
                Issue.record("错误类型不正确：\(error)")
                return
            }
            #expect(message.contains("过期"))
        }
    }

    @Test("前缀、内容或字段被篡改时拒绝")
    func tampered() throws {
        let encoded = try WebDavInvite.create(credentials: credentials, now: now).encode()

        #expect(throws: (any Error).self) {
            _ = try WebDavInvite.decode(
                encoded.replacingOccurrences(of: WebDavInvite.prefix, with: "other:"),
                now: now
            )
        }
        #expect(throws: (any Error).self) {
            _ = try WebDavInvite.decode(encoded + "A", now: now)
        }

        let payload = try JSONSerialization.jsonObject(
            with: try Base64URL.decode(String(encoded.dropFirst(WebDavInvite.prefix.count)))
        ) as! [String: Any]
        var extra = payload
        extra["unexpected"] = true
        let extraData = try JSONSerialization.data(withJSONObject: extra)
        let extraEncoded = WebDavInvite.prefix + Base64URL.encode(extraData)
        #expect(throws: (any Error).self) {
            _ = try WebDavInvite.decode(extraEncoded, now: now)
        }
    }

    @Test("时间跨度异常时拒绝")
    func invalidWindow() throws {
        let payload: [String: Any] = [
            "v": 1,
            "endpoint": credentials.account.endpoint.absoluteString,
            "username": credentials.account.username,
            "appPassword": credentials.account.appPassword,
            "vaultId": credentials.vaultId,
            "vaultKey": Base64URL.encode(credentials.vaultKey),
            "issuedAt": Int64(now.timeIntervalSince1970 * 1_000),
            "expiresAt": Int64(
                now.addingTimeInterval(WebDavInvite.ttl * 2).timeIntervalSince1970 * 1_000
            ),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let encoded = WebDavInvite.prefix + Base64URL.encode(data)

        #expect(throws: (any Error).self) {
            _ = try WebDavInvite.decode(encoded, now: now)
        }
        #expect(throws: (any Error).self) {
            _ = try WebDavInvite.decode(encoded, now: now.addingTimeInterval(-600))
        }
    }
}
