import Foundation

public enum WebDavSetupLinkError: Error, Equatable, LocalizedError, Sendable {
    case invalidScheme
    case invalidVersion
    case missingField(String)
    case duplicateOrUnknownField
    case invalidEndpoint
    case invalidUsername
    case invalidAppPassword
    case invalidVaultId
    case invalidVaultKey
    case cannotEncode

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            "不是 Woo Todo WebDAV 配置深链"
        case .invalidVersion:
            "WebDAV 配置深链版本不受支持"
        case .missingField(let field):
            "WebDAV 配置深链缺少字段：\(field)"
        case .duplicateOrUnknownField:
            "WebDAV 配置深链包含重复或未知字段"
        case .invalidEndpoint:
            "WebDAV 服务地址必须是安全的 HTTPS 地址"
        case .invalidUsername:
            "WebDAV 账号格式无效"
        case .invalidAppPassword:
            "WebDAV 应用密码或访问令牌格式无效"
        case .invalidVaultId:
            "同步空间名格式无效"
        case .invalidVaultKey:
            "同步密钥必须为 32 字节 Base64URL"
        case .cannotEncode:
            "无法构造 WebDAV 配置深链"
        }
    }
}

/// 携带加入第三方 WebDAV 同步所需的完整配置；设备 ID 永不进入深链。
public struct WebDavSetupLink: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public static let version = "2"

    public let endpoint: URL
    public let username: String
    public let appPassword: String
    public let vaultId: String
    public let vaultKey: String

    public init(
        endpoint: URL,
        username: String,
        appPassword: String,
        vaultId: String,
        vaultKey: String
    ) throws {
        guard WebDavEndpointPolicy.isAllowed(endpoint) else {
            throw WebDavSetupLinkError.invalidEndpoint
        }
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
        self.endpoint = endpoint
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

        let expectedNames = Set([
            "v", "endpoint", "username", "appPassword", "vaultId", "vaultKey",
        ])
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
        guard let endpoint = URL(string: try value("endpoint")) else {
            throw WebDavSetupLinkError.invalidEndpoint
        }
        try self.init(
            endpoint: endpoint,
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
            URLQueryItem(name: "endpoint", value: endpoint.absoluteString),
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
        "WebDavSetupLink(endpoint: <已隐藏>, username: <已隐藏>, appPassword: <已隐藏>, vaultId: \(vaultId), vaultKey: <已隐藏>)"
    }

    public var debugDescription: String { description }
}
