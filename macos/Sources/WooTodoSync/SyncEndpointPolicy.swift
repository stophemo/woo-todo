import Foundation

/// 跨设备同步只允许公网 HTTPS Worker：不再接受 HTTP、私有地址、`.local` 或回环地址。
public enum SyncEndpointPolicy {
    public static func isAllowed(_ endpoint: URL) -> Bool {
        guard endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host,
              !host.isEmpty,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            return false
        }
        let path = endpoint.path
        guard path.isEmpty || path == "/" else { return false }
        return !isLocalOrPrivateHost(host)
    }

    static func isLocalOrPrivateHost(_ host: String) -> Bool {
        var normalized = host.lowercased()
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else { return true }
        if isNumericLookingHost(normalized) {
            return true
        }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }
        if isLocalHostname(normalized) {
            return true
        }
        if isPrivateIPv4(normalized) {
            return true
        }
        return isPrivateIPv6(normalized)
    }

    /// 数值地址的写法变体（inet_aton 语义）不依赖 DNS 解析，一律 fail-closed：
    /// 纯数字、仅数字和点但不是规范四段十进制（含 127.1、前导零、五段等）、
    /// 以及 0x 开头的十六进制写法都视为本地/保留地址。
    static func isNumericLookingHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let containsHexLabel = labels.contains { $0.hasPrefix("0x") }
        if containsHexLabel,
           labels.allSatisfy({ label in
               label.allSatisfy { $0.isHexDigit || $0 == "x" }
           }) {
            return true
        }
        // 规范四段十进制交给私网/公网判断；其余纯数字与点写法（纯数字、127.1、
        // 127.0.0.01、五段等）全部拒绝。
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return parseIPv4(host) == nil
        }
        return false
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        guard let octets = parseIPv4(host) else { return false }
        let first = octets[0]
        let second = octets[1]
        return first == 0
            || first == 10
            || first == 127
            || (first == 100 && (64...127).contains(second))
            || (first == 169 && second == 254)
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }

    private static func parseIPv4(_ host: String) -> [Int]? {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        var octets: [Int] = []
        for component in components {
            guard !component.isEmpty,
                  component.count <= 3,
                  component.allSatisfy(\.isNumber),
                  !(component.count > 1 && component.first == "0"),
                  let value = Int(component), (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    /// 拒绝 IPv6 未指定、回环、ULA（fc00::/7）、链路本地（fe80::/10）与 IPv4-mapped 私网。
    private static func isPrivateIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard address.contains(":"),
              let groups = parseIPv6Groups(address) else {
            return false
        }
        if groups.allSatisfy({ $0 == 0 }) {
            return true
        }
        if groups[0...6].allSatisfy({ $0 == 0 }), groups[7] == 1 {
            return true
        }
        if (groups[0] & 0xfe00) == 0xfc00 {
            return true
        }
        if (groups[0] & 0xffc0) == 0xfe80 {
            return true
        }
        if groups[0...4].allSatisfy({ $0 == 0 }), groups[5] == 0xffff {
            let mapped = [
                Int(groups[6] >> 8),
                Int(groups[6] & 0xff),
                Int(groups[7] >> 8),
                Int(groups[7] & 0xff),
            ]
            return isPrivateIPv4(mapped.map(String.init).joined(separator: "."))
        }
        return false
    }

    private static func parseIPv6Groups(_ address: String) -> [UInt16]? {
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func parsePart(_ part: String) -> [UInt16]? {
            guard !part.isEmpty else { return [] }
            var result: [UInt16] = []
            for piece in part.split(separator: ":", omittingEmptySubsequences: false) {
                if piece.contains(".") {
                    guard let octets = parseIPv4(String(piece)) else { return nil }
                    result.append(UInt16(octets[0]) << 8 | UInt16(octets[1]))
                    result.append(UInt16(octets[2]) << 8 | UInt16(octets[3]))
                } else {
                    guard (1...4).contains(piece.count),
                          let value = UInt16(piece, radix: 16) else {
                        return nil
                    }
                    result.append(value)
                }
            }
            return result
        }

        guard let head = parsePart(halves[0]) else { return nil }
        if halves.count == 1 {
            return head.count == 8 ? head : nil
        }
        guard let tail = parsePart(halves[1]) else { return nil }
        let missing = 8 - head.count - tail.count
        guard missing >= 1 else { return nil }
        return head + Array(repeating: 0, count: missing) + tail
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
    case includesAPIVersion
    case ready(URL)
}

public enum SyncEndpointSetupPolicy {
    public static func assess(_ source: String) -> SyncEndpointSetupAssessment {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let endpoint = URL(string: trimmed) else { return .invalid }

        let finalPathComponent = endpoint.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .last?
            .lowercased()
        if finalPathComponent == "v1",
           endpoint.scheme?.lowercased() == "https",
           endpoint.user == nil,
           endpoint.password == nil,
           endpoint.query == nil,
           endpoint.fragment == nil {
            return .includesAPIVersion
        }

        return SyncEndpointPolicy.isAllowed(endpoint) ? .ready(endpoint) : .invalid
    }
}
