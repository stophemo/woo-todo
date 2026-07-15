import Foundation

public enum SyncEndpointPolicy {
    public static func isAllowed(_ endpoint: URL) -> Bool {
        guard endpoint.host != nil,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            return false
        }
        if endpoint.scheme?.lowercased() == "https" { return true }
        return endpoint.scheme?.lowercased() == "http" && endpoint.host == "127.0.0.1"
    }
}

public enum PairingDeepLinkError: Error, Equatable, LocalizedError {
    case invalidScheme
    case invalidEndpoint
    case missingField(String)
    case duplicateOrUnknownField
    case invalidPairingId
    case invalidSecret
    case invalidPublicKey
    case cannotEncode

    public var errorDescription: String? {
        switch self {
        case .invalidScheme: "不是 woo-todo 配对深链"
        case .invalidEndpoint: "配对服务必须使用 HTTPS；本地调试仅允许 127.0.0.1 HTTP"
        case .missingField(let field): "配对深链缺少字段：\(field)"
        case .duplicateOrUnknownField: "配对深链包含重复或未知字段"
        case .invalidPairingId: "配对 ID 格式无效"
        case .invalidSecret: "配对 secret 必须为 32 字节 Base64URL"
        case .invalidPublicKey: "发起方公钥必须为 32 字节 Base64URL"
        case .cannotEncode: "无法构造配对深链"
        }
    }
}

public struct PairingDeepLink: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let endpoint: URL
    public let pairingId: String
    public let pairingSecret: String
    public let initiatorPublicKey: String

    public init(
        endpoint: URL,
        pairingId: String,
        pairingSecret: String,
        initiatorPublicKey: String
    ) throws {
        guard SyncEndpointPolicy.isAllowed(endpoint) else {
            throw PairingDeepLinkError.invalidEndpoint
        }
        let identifierCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-"
        )
        guard (1...128).contains(pairingId.count),
              pairingId.rangeOfCharacter(from: identifierCharacters.inverted) == nil else {
            throw PairingDeepLinkError.invalidPairingId
        }
        guard (try? Base64URL.decode(pairingSecret).count) == 32 else {
            throw PairingDeepLinkError.invalidSecret
        }
        guard (try? Base64URL.decode(initiatorPublicKey).count) == 32 else {
            throw PairingDeepLinkError.invalidPublicKey
        }
        self.endpoint = endpoint
        self.pairingId = pairingId
        self.pairingSecret = pairingSecret
        self.initiatorPublicKey = initiatorPublicKey
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "wootodo",
              components.host == "pair",
              components.path.isEmpty else {
            throw PairingDeepLinkError.invalidScheme
        }
        let expectedNames = Set(["endpoint", "pairingId", "pairingSecret", "initiatorPublicKey"])
        let items = components.queryItems ?? []
        guard items.count == expectedNames.count,
              Set(items.map(\.name)) == expectedNames else {
            throw PairingDeepLinkError.duplicateOrUnknownField
        }
        func value(_ name: String) throws -> String {
            guard let value = items.first(where: { $0.name == name })?.value, !value.isEmpty else {
                throw PairingDeepLinkError.missingField(name)
            }
            return value
        }
        guard let endpoint = URL(string: try value("endpoint")) else {
            throw PairingDeepLinkError.invalidEndpoint
        }
        try self.init(
            endpoint: endpoint,
            pairingId: value("pairingId"),
            pairingSecret: value("pairingSecret"),
            initiatorPublicKey: value("initiatorPublicKey")
        )
    }

    public func url() throws -> URL {
        var components = URLComponents()
        components.scheme = "wootodo"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "endpoint", value: endpoint.absoluteString),
            URLQueryItem(name: "pairingId", value: pairingId),
            URLQueryItem(name: "pairingSecret", value: pairingSecret),
            URLQueryItem(name: "initiatorPublicKey", value: initiatorPublicKey),
        ]
        guard let url = components.url else {
            throw PairingDeepLinkError.cannotEncode
        }
        return url
    }

    /// 严禁把完整深链写入日志；description 固定隐藏 secret 与临时公钥。
    public var description: String {
        "PairingDeepLink(endpoint: \(endpoint.absoluteString), pairingId: \(pairingId), pairingSecret: <已隐藏>, initiatorPublicKey: <已隐藏>)"
    }

    public var debugDescription: String { description }
}
