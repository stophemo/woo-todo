import Foundation

public enum WebDavSetupLinkError: Error, Equatable, LocalizedError, Sendable {
    case invalidScheme
    case invalidVersion
    case missingField(String)
    case duplicateOrUnknownField
    case invalidUsername
    case invalidAppPassword
    case invalidVaultId
    case invalidVaultKey
    case cannotEncode

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            "不是 woo-todo 坚果云配置深链"
        case .invalidVersion:
            "坚果云配置深链版本不受支持"
        case .missingField(let field):
            "坚果云配置深链缺少字段：\(field)"
        case .duplicateOrUnknownField:
            "坚果云配置深链包含重复或未知字段"
        case .invalidUsername:
            "坚果云账号邮箱格式无效"
        case .invalidAppPassword:
            "坚果云应用密码格式无效"
        case .invalidVaultId:
            "同步空间名格式无效"
        case .invalidVaultKey:
            "同步密钥必须为 32 字节 Base64URL"
        case .cannotEncode:
            "无法构造坚果云配置深链"
        }
    }
}

/// 携带加入坚果云同步所需的完整凭据；设备 ID 与固定 WebDAV 地址永不进入深链。
public struct WebDavSetupLink: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public static let version = "1"

    public let username: String
    public let appPassword: String
    public let vaultId: String
    public let vaultKey: String

    public init(
        username: String,
        appPassword: String,
        vaultId: String,
        vaultKey: String
    ) throws {
        guard (1...320).contains(username.unicodeScalars.count),
              username.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              username.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WebDavSetupLinkError.invalidUsername
        }
        guard (1...256).contains(appPassword.unicodeScalars.count),
              appPassword.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WebDavSetupLinkError.invalidAppPassword
        }
        guard vaultId.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
            options: .regularExpression
        ) != nil else {
            throw WebDavSetupLinkError.invalidVaultId
        }
        guard (try? Base64URL.decode(vaultKey).count) == AES256GCM.keyByteCount else {
            throw WebDavSetupLinkError.invalidVaultKey
        }
        self.username = username
        self.appPassword = appPassword
        self.vaultId = vaultId
        self.vaultKey = vaultKey
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wootodo",
              components.host?.lowercased() == "webdav",
              components.path.isEmpty,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw WebDavSetupLinkError.invalidScheme
        }

        let expectedNames = Set(["v", "username", "appPassword", "vaultId", "vaultKey"])
        let items = components.queryItems ?? []
        guard items.count == expectedNames.count,
              Set(items.map(\.name)) == expectedNames else {
            throw WebDavSetupLinkError.duplicateOrUnknownField
        }

        func value(_ name: String) throws -> String {
            guard let value = items.first(where: { $0.name == name })?.value,
                  !value.isEmpty else {
                throw WebDavSetupLinkError.missingField(name)
            }
            return value
        }

        guard try value("v") == Self.version else {
            throw WebDavSetupLinkError.invalidVersion
        }
        try self.init(
            username: value("username"),
            appPassword: value("appPassword"),
            vaultId: value("vaultId"),
            vaultKey: value("vaultKey")
        )
    }

    public func url() throws -> URL {
        var components = URLComponents()
        components.scheme = "wootodo"
        components.host = "webdav"
        components.queryItems = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "appPassword", value: appPassword),
            URLQueryItem(name: "vaultId", value: vaultId),
            URLQueryItem(name: "vaultKey", value: vaultKey),
        ]
        guard let url = components.url else {
            throw WebDavSetupLinkError.cannotEncode
        }
        return url
    }

    /// 深链包含应用密码与同步密钥，描述和调试输出不得泄露完整 URL。
    public var description: String {
        "WebDavSetupLink(username: <已隐藏>, appPassword: <已隐藏>, vaultId: \(vaultId), vaultKey: <已隐藏>)"
    }

    public var debugDescription: String { description }
}
