import Foundation

public struct AppVersion: Comparable, CustomStringConvertible, Hashable, Sendable {
    private enum PrereleaseIdentifier: Hashable, Sendable {
        case number(Int)
        case text(String)

        var stringValue: String {
            switch self {
            case .number(let value): String(value)
            case .text(let value): value
            }
        }
    }

    public let major: Int
    public let minor: Int
    public let patch: Int

    private let prerelease: [PrereleaseIdentifier]?

    public init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        let buildParts = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !buildParts.isEmpty,
              buildParts.count <= 2,
              buildParts.count == 1 || Self.isValidIdentifierList(buildParts[1]) else {
            return nil
        }

        let releaseParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let coreParts = releaseParts[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard coreParts.count == 3,
              let major = Self.parseCoreNumber(coreParts[0]),
              let minor = Self.parseCoreNumber(coreParts[1]),
              let patch = Self.parseCoreNumber(coreParts[2]) else {
            return nil
        }

        let prerelease: [PrereleaseIdentifier]?
        if releaseParts.count == 2 {
            let rawIdentifiers = releaseParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard !rawIdentifiers.isEmpty else { return nil }
            var parsed: [PrereleaseIdentifier] = []
            parsed.reserveCapacity(rawIdentifiers.count)
            for rawIdentifier in rawIdentifiers {
                guard Self.isValidIdentifier(rawIdentifier) else { return nil }
                if rawIdentifier.utf8.allSatisfy(Self.isASCIIDigit) {
                    guard (rawIdentifier.count == 1 || rawIdentifier.first != "0"),
                          let number = Int(rawIdentifier) else {
                        return nil
                    }
                    parsed.append(.number(number))
                } else {
                    parsed.append(.text(String(rawIdentifier)))
                }
            }
            prerelease = parsed
        } else {
            prerelease = nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if let prerelease {
            value += "-" + prerelease.map(\.stringValue).joined(separator: ".")
        }
        return value
    }

    public var isPrerelease: Bool {
        prerelease != nil
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _):
            return false
        case (_, nil):
            return true
        case (.some(let lhsIdentifiers), .some(let rhsIdentifiers)):
            for index in 0..<min(lhsIdentifiers.count, rhsIdentifiers.count) {
                let lhsIdentifier = lhsIdentifiers[index]
                let rhsIdentifier = rhsIdentifiers[index]
                guard lhsIdentifier != rhsIdentifier else { continue }
                return Self.isIdentifier(lhsIdentifier, lessThan: rhsIdentifier)
            }
            return lhsIdentifiers.count < rhsIdentifiers.count
        }
    }

    private static func parseCoreNumber(_ rawValue: Substring) -> Int? {
        guard !rawValue.isEmpty,
              rawValue.utf8.allSatisfy(isASCIIDigit),
              rawValue.count == 1 || rawValue.first != "0" else {
            return nil
        }
        return Int(rawValue)
    }

    private static func isValidIdentifierList(_ rawValue: Substring) -> Bool {
        let identifiers = rawValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return !identifiers.isEmpty && identifiers.allSatisfy(isValidIdentifier)
    }

    private static func isValidIdentifier(_ rawValue: Substring) -> Bool {
        !rawValue.isEmpty && rawValue.utf8.allSatisfy { byte in
            isASCIIDigit(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
        }
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func isIdentifier(
        _ lhs: PrereleaseIdentifier,
        lessThan rhs: PrereleaseIdentifier
    ) -> Bool {
        switch (lhs, rhs) {
        case (.number(let lhsValue), .number(let rhsValue)):
            lhsValue < rhsValue
        case (.number, .text):
            true
        case (.text, .number):
            false
        case (.text(let lhsValue), .text(let rhsValue)):
            lhsValue < rhsValue
        }
    }
}

public enum AppUpdatePolicy {
    public static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    public static let failedCheckRetryInterval: TimeInterval = 15 * 60

    public static func shouldPerformAutomaticCheck(
        lastCheckedAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = automaticCheckInterval
    ) -> Bool {
        guard let lastCheckedAt else { return true }
        let elapsed = now.timeIntervalSince(lastCheckedAt)
        if !elapsed.isFinite || elapsed < 0 { return true }
        if minimumInterval <= 0 { return true }
        return elapsed >= minimumInterval
    }

    public static func stableReleaseVersion(fromGitHubTag tag: String) -> AppVersion? {
        guard let version = AppVersion(tag), !version.isPrerelease else { return nil }
        let canonical = version.description
        guard tag == "v\(canonical)" else { return nil }
        return version
    }

    /// 更新检查结果用于菜单提示时，只依据当前版本和最新正式版判断。
    /// 用户是否曾经忽略提示不会隐藏菜单中的可用更新。
    public static func shouldShowAvailableUpdate(
        currentVersion: AppVersion,
        latestVersion: AppVersion
    ) -> Bool {
        latestVersion > currentVersion
    }
}
