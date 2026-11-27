import Foundation

/// 同步二维码/信息里的内容：完整的目标目录、账号、应用密码、空间 ID 与同步密钥。
/// 只在用户的两台设备之间传递，不写入 WebDAV；请只给自己的设备扫描或粘贴。
public struct WebDavInvite: Equatable, Sendable {
    public static let prefix = "woo-todo-invite:1:"
    public static let ttl: TimeInterval = 10 * 60
    private static let protocolVersion = 1
    private static let maximumLength = 4_096
    private static let clockSkew: TimeInterval = 5 * 60
    private static let payloadKeys: Set<String> = [
        "v", "endpoint", "username", "appPassword",
        "vaultId", "vaultKey", "issuedAt", "expiresAt",
    ]

    public let account: WebDavAccount
    public let vaultId: String
    public let vaultKey: Data
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        account: WebDavAccount,
        vaultId: String,
        vaultKey: Data,
        issuedAt: Date,
        expiresAt: Date
    ) throws {
        try account.validate()
        guard vaultId.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
            options: .regularExpression
        ) != nil else {
            throw WebDavError.malformedObject("同步信息缺少同步空间")
        }
        guard vaultKey.count == AES256GCM.keyByteCount else {
            throw WebDavError.malformedObject("同步信息缺少同步密钥")
        }
        guard issuedAt.timeIntervalSince1970 <= expiresAt.timeIntervalSince1970 else {
            throw WebDavError.malformedObject("同步信息时间无效")
        }
        self.account = account
        self.vaultId = vaultId
        self.vaultKey = vaultKey
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public static func create(
        credentials: WebDavCredentials,
        now: Date = Date()
    ) throws -> WebDavInvite {
        try WebDavInvite(
            account: credentials.account,
            vaultId: credentials.identity.vaultId,
            vaultKey: credentials.identity.vaultKey,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    /// 第二台设备必须生成自己的 deviceId，避免两台设备共用同步身份。
    public func identity(deviceId: String) throws -> WebDavIdentity {
        let identity = WebDavIdentity(
            vaultId: vaultId,
            deviceId: deviceId,
            vaultKey: vaultKey
        )
        try identity.validate()
        return identity
    }

    public func encode() throws -> String {
        let payload = Payload(
            v: Self.protocolVersion,
            endpoint: account.endpoint.absoluteString,
            username: account.username,
            appPassword: account.appPassword,
            vaultId: vaultId,
            vaultKey: Base64URL.encode(vaultKey),
            issuedAt: Int64((issuedAt.timeIntervalSince1970 * 1_000).rounded()),
            expiresAt: Int64((expiresAt.timeIntervalSince1970 * 1_000).rounded())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return Self.prefix + Base64URL.encode(try encoder.encode(payload))
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
    }

    public static func decode(_ source: String, now: Date = Date()) throws -> WebDavInvite {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= maximumLength, value.hasPrefix(prefix) else {
            throw invalid()
        }
        guard let data = try? Base64URL.decode(String(value.dropFirst(prefix.count))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == payloadKeys else {
            throw invalid()
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw invalid()
        }
        guard payload.v == protocolVersion else { throw invalid() }
        let issuedAt = Date(timeIntervalSince1970: Double(payload.issuedAt) / 1_000)
        let expiresAt = Date(timeIntervalSince1970: Double(payload.expiresAt) / 1_000)
        let invite: WebDavInvite
        do {
            guard let endpoint = URL(string: payload.endpoint) else { throw invalid() }
            invite = try WebDavInvite(
                account: WebDavAccount(
                    endpoint: endpoint,
                    username: payload.username,
                    appPassword: payload.appPassword
                ),
                vaultId: payload.vaultId,
                vaultKey: try Base64URL.decode(payload.vaultKey),
                issuedAt: issuedAt,
                expiresAt: expiresAt
            )
        } catch {
            throw invalid()
        }
        guard invite.expiresAt > now else {
            throw WebDavError.malformedObject("同步二维码已过期，请在已连接的设备上重新生成")
        }
        guard invite.issuedAt <= now.addingTimeInterval(clockSkew),
              invite.expiresAt.timeIntervalSince(invite.issuedAt)
                <= ttl + clockSkew else {
            throw invalid()
        }
        return invite
    }

    private static func invalid() -> WebDavError {
        .malformedObject("同步信息无效或格式不正确")
    }

    private struct Payload: Codable {
        let v: Int
        let endpoint: String
        let username: String
        let appPassword: String
        let vaultId: String
        let vaultKey: String
        let issuedAt: Int64
        let expiresAt: Int64
    }
}

extension WebDavInvite: Identifiable {
    public var id: String {
        "\(vaultId)-\(Int64(issuedAt.timeIntervalSince1970))"
    }
}
