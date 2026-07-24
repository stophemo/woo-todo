import Foundation

public enum SyncEndpointScope: Equatable, Sendable {
    /// 可供 Mac 与 Android 共同访问的 HTTPS 地址。
    case crossDevice
    /// 仅允许 RFC1918 IPv4 或 mDNS `.local` 主机名使用明文 HTTP。
    case localNetwork
    /// 仅指向当前设备的回环地址，不能用于真实双机配对。
    case currentDeviceOnly
    case invalid
}

public enum SyncEndpointPolicy {
    public static func scope(of endpoint: URL) -> SyncEndpointScope {
        guard let host = endpoint.host?.lowercased(),
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            return .invalid
        }

        let scheme = endpoint.scheme?.lowercased()
        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        if isLoopback {
            if scheme == "https" || (scheme == "http" && host == "127.0.0.1") {
                return .currentDeviceOnly
            }
            return .invalid
        }
        if scheme == "https" { return .crossDevice }
        if scheme == "http", isPrivateIPv4(host) || isLocalHostname(host) {
            return .localNetwork
        }
        return .invalid
    }

    public static func isAllowed(_ endpoint: URL) -> Bool {
        scope(of: endpoint) != .invalid
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        var octets: [Int] = []
        for component in components {
            guard !component.isEmpty,
                  component.count <= 3,
                  component.allSatisfy(\.isNumber),
                  !(component.count > 1 && component.first == "0"),
                  let value = Int(component), (0...255).contains(value) else {
                return false
            }
            octets.append(value)
        }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        guard host.count <= 253, host.hasSuffix(".local") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last == "local" else { return false }
        return labels.dropLast().allSatisfy { label in
            guard (1...63).contains(label.count),
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true else {
                return false
            }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

public enum SyncEndpointSetupAssessment: Equatable, Sendable {
    case empty
    case invalid
    case currentDeviceOnly
    case includesAPIVersion
    case ready(URL)
}

/// 仅用于创建真实双端同步空间；底层客户端仍保留 127.0.0.1 本机调试能力。
public enum SyncEndpointSetupPolicy {
    public static func assess(_ source: String) -> SyncEndpointSetupAssessment {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let endpoint = URL(string: trimmed) else { return .invalid }

        switch SyncEndpointPolicy.scope(of: endpoint) {
        case .invalid:
            return .invalid
        case .currentDeviceOnly:
            return .currentDeviceOnly
        case .localNetwork:
            return .invalid
        case .crossDevice:
            let finalPathComponent = endpoint.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .last?
                .lowercased()
            if finalPathComponent == "v1" {
                return .includesAPIVersion
            }
            return .ready(endpoint)
        }
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
        case .invalidEndpoint: "配对服务必须使用 HTTPS，或使用受限的局域网 HTTP 地址"
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
