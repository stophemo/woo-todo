import Foundation

public enum WebDavError: Error, Equatable, LocalizedError, Sendable {
    case invalidCredentials
    case invalidEndpoint
    case encoding(String)
    case transport(String)
    case invalidResponse
    case http(Int)
    case objectConflict(String)
    case malformedObject(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "WebDAV 账号或同步身份无效"
        case .invalidEndpoint: "WebDAV 服务必须使用不含凭据、查询参数或片段的 HTTPS 地址"
        case .encoding(let message): "WebDAV 对象编码失败：\(message)"
        case .transport(let message): "WebDAV 网络请求失败：\(message)"
        case .invalidResponse: "WebDAV 服务返回了无效的 HTTP 响应"
        case .http(let status): "WebDAV 服务返回 HTTP \(status)"
        case .objectConflict(let path): "WebDAV 对象发生冲突：\(path)"
        case .malformedObject(let message): "WebDAV 同步对象无效：\(message)"
        }
    }
}

public enum WebDavEndpointPolicy {
    /// 供应商根目录允许带路径；不允许 userinfo、查询参数、片段，且必须是 HTTPS。
    public static func isAllowed(_ value: URL) -> Bool {
        guard value.absoluteString.count <= 2_048,
              let components = URLComponents(url: value, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            return false
        }
        return components.percentEncodedPath.split(separator: "/").allSatisfy { segment in
            guard let decoded = String(segment).removingPercentEncoding else { return false }
            return decoded != "." && decoded != ".."
                && !decoded.contains("/") && !decoded.contains("\\")
        }
    }
}

/// WebDAV 账号凭据：供应商地址、用户名与应用密码。单独加密保存。
public struct WebDavAccount: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let username: String
    public let appPassword: String

    public init(endpoint: URL, username: String, appPassword: String) {
        self.endpoint = endpoint
        self.username = username
        self.appPassword = appPassword
    }

    public func validate() throws {
        guard WebDavEndpointPolicy.isAllowed(endpoint) else {
            throw WebDavError.invalidEndpoint
        }
        guard (1...320).contains(username.unicodeScalars.count),
              (1...256).contains(appPassword.unicodeScalars.count),
              username.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              username.rangeOfCharacter(from: .controlCharacters) == nil,
              appPassword.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WebDavError.invalidCredentials
        }
    }
}

/// 同步空间身份：空间 ID、本机设备 ID 与 32 字节同步密钥。单独加密保存。
public struct WebDavIdentity: Codable, Equatable, Sendable {
    public let vaultId: String
    public let deviceId: String
    public let vaultKey: Data

    public init(vaultId: String, deviceId: String, vaultKey: Data) {
        self.vaultId = vaultId
        self.deviceId = deviceId
        self.vaultKey = vaultKey
    }

    public func validate() throws {
        guard vaultId.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
            options: .regularExpression
        ) != nil,
              deviceId.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$",
                options: .regularExpression
              ) != nil,
              vaultKey.count == AES256GCM.keyByteCount else {
            throw WebDavError.invalidCredentials
        }
    }
}

/// 账号与身份的组合形态，便于启动装配与旧凭据迁移。
/// WebDAV 账号与身份不写入备份，恢复备份后需要重新配置并重新配对。
public struct WebDavCredentials: Codable, Equatable, Sendable {
    public let account: WebDavAccount
    public let identity: WebDavIdentity

    public init(account: WebDavAccount, identity: WebDavIdentity) {
        self.account = account
        self.identity = identity
    }

    public init(
        endpoint: URL,
        username: String,
        appPassword: String,
        vaultId: String,
        deviceId: String,
        vaultKey: Data
    ) {
        self.init(
            account: WebDavAccount(
                endpoint: endpoint,
                username: username,
                appPassword: appPassword
            ),
            identity: WebDavIdentity(
                vaultId: vaultId,
                deviceId: deviceId,
                vaultKey: vaultKey
            )
        )
    }

    public var endpoint: URL { account.endpoint }
    public var username: String { account.username }
    public var appPassword: String { account.appPassword }
    public var vaultId: String { identity.vaultId }
    public var deviceId: String { identity.deviceId }
    public var vaultKey: Data { identity.vaultKey }

    public func validate() throws {
        try account.validate()
        try identity.validate()
    }
}

public protocol WebDavCredentialsStoring: Sendable {
    func saveAccount(_ account: WebDavAccount) throws
    func loadAccount() throws -> WebDavAccount?
    func deleteAccount() throws
    func saveIdentity(_ identity: WebDavIdentity) throws
    func loadIdentity() throws -> WebDavIdentity?
    func deleteIdentity() throws
}

public extension WebDavCredentialsStoring {
    func save(_ credentials: WebDavCredentials) throws {
        try credentials.validate()
        try saveAccount(credentials.account)
        try saveIdentity(credentials.identity)
    }

    func load() throws -> WebDavCredentials? {
        let account = try loadAccount()
        let identity = try loadIdentity()
        switch (account, identity) {
        case let (account?, identity?):
            return WebDavCredentials(account: account, identity: identity)
        default:
            return nil
        }
    }

    func delete() throws {
        try deleteIdentity()
        try deleteAccount()
    }
}

/// 测试与 UI 测试使用的内存实现。
public final class InMemoryWebDavCredentialsStore: WebDavCredentialsStoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var account: WebDavAccount?
    private var identity: WebDavIdentity?

    public init(account: WebDavAccount? = nil, identity: WebDavIdentity? = nil) {
        self.account = account
        self.identity = identity
    }

    public func saveAccount(_ account: WebDavAccount) throws {
        try account.validate()
        lock.withLock { self.account = account }
    }

    public func loadAccount() throws -> WebDavAccount? {
        lock.withLock { account }
    }

    public func deleteAccount() throws {
        lock.withLock { account = nil }
    }

    public func saveIdentity(_ identity: WebDavIdentity) throws {
        try identity.validate()
        lock.withLock { self.identity = identity }
    }

    public func loadIdentity() throws -> WebDavIdentity? {
        lock.withLock { identity }
    }

    public func deleteIdentity() throws {
        lock.withLock { identity = nil }
    }
}
