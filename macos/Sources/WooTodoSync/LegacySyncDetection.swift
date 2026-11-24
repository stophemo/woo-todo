import Foundation

/// 旧版局域网 / WebDAV 同步的遗留状态。只用于提示与停用判断，不删除任何旧凭据。
public struct SyncLegacyDetection: Equatable, Sendable {
    public let credentialsInvalidated: Bool
    public let legacyStoragePresent: Bool

    public init(credentialsInvalidated: Bool, legacyStoragePresent: Bool) {
        self.credentialsInvalidated = credentialsInvalidated
        self.legacyStoragePresent = legacyStoragePresent
    }

    public var isLegacy: Bool {
        credentialsInvalidated || legacyStoragePresent
    }
}

public enum SyncLegacyDetector {
    public static func isLegacyCredentialsError(_ error: Error?) -> Bool {
        guard let error else { return false }
        if let error = error as? CredentialsStoreError {
            return error == .invalidCredentials
        }
        if let error = error as? EncryptedFileSyncCredentialsStoreError {
            return error == .invalidCredentialsFile
        }
        return false
    }

    /// 旧版 WebDAV / 局域网同步留下的文件与目录。
    public static func legacyFileURLs(applicationSupportURL: URL) -> [URL] {
        let secure = applicationSupportURL.appendingPathComponent(
            "Secure",
            isDirectory: true
        )
        return [
            secure.appendingPathComponent("webdav-credentials.enc"),
            secure.appendingPathComponent("webdav-local-key.json"),
            applicationSupportURL.appendingPathComponent("local-sync", isDirectory: true),
        ]
    }

    public static func detect(
        credentialsError: Error?,
        applicationSupportURL: URL?,
        fileManager: FileManager = .default
    ) -> SyncLegacyDetection {
        let storagePresent = applicationSupportURL.map { root in
            legacyFileURLs(applicationSupportURL: root).contains {
                fileManager.fileExists(atPath: $0.path)
            }
        } ?? false
        return SyncLegacyDetection(
            credentialsInvalidated: isLegacyCredentialsError(credentialsError),
            legacyStoragePresent: storagePresent
        )
    }
}

public enum SyncLegacyNotice {
    public static let text = "旧同步方式已停用，本地任务已保留。请重新输入配对码或建立同步空间；旧同步凭据不会被删除。"
    /// 0.4.0 起客户端只使用 WebDAV。
    public static let webDavMigrationText = "同步已改为 WebDAV。旧 Worker/局域网凭据已保留但不会启用；请配置 WebDAV 账号，本地任务会保留。"
}

public extension SyncLegacyDetector {
    /// 旧 Worker/局域网凭据文件与目录；不包含当前仍在使用中的 WebDAV 凭据。
    static func workerLegacyStorageURLs(applicationSupportURL: URL) -> [URL] {
        let secure = applicationSupportURL.appendingPathComponent(
            "Secure",
            isDirectory: true
        )
        return [
            secure.appendingPathComponent("sync-credentials.enc"),
            secure.appendingPathComponent("sync-local-key.json"),
            applicationSupportURL.appendingPathComponent("local-sync", isDirectory: true),
        ]
    }

    static func workerLegacyStoragePresent(
        applicationSupportURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        workerLegacyStorageURLs(applicationSupportURL: applicationSupportURL).contains {
            fileManager.fileExists(atPath: $0.path)
        }
    }
}

/// 启动时的同步身份判断结果：旧文件只影响提示，不否决已读取且合法的新凭据。
public struct SyncStartupDecision {
    public let activeCredentials: SyncCredentials?
    public let legacyDetection: SyncLegacyDetection
    public let activationError: (any Error)?

    public init(
        activeCredentials: SyncCredentials?,
        legacyDetection: SyncLegacyDetection,
        activationError: (any Error)?
    ) {
        self.activeCredentials = activeCredentials
        self.legacyDetection = legacyDetection
        self.activationError = activationError
    }

    /// 已保存且通过校验的凭据仍然存在（即使本次未能激活）。
    public var hasStoredValidCredentials: Bool {
        activeCredentials != nil
    }

    /// 有效凭据存在时旧文件只保留，不触发“旧同步方式已停用”提示。
    public var shouldShowLegacyNotice: Bool {
        activeCredentials == nil && legacyDetection.isLegacy
    }
}

public enum SyncStartupActivationPolicy {
    /// 规则：
    /// - 已保存凭据通过校验 → 正常激活，旧文件不参与否决。
    /// - 已保存凭据校验失败（旧 endpoint 等）→ 视为 legacy，不激活。
    /// - 读取失败但属于 legacy 无效凭据 → 视为 legacy，不激活。
    /// - 读取失败属于密钥/文件系统等其它错误 → 不激活并回传错误。
    public static func evaluate(
        storedCredentials: SyncCredentials?,
        credentialsError: Error?,
        applicationSupportURL: URL?,
        fileManager: FileManager = .default
    ) -> SyncStartupDecision {
        let detection = SyncLegacyDetector.detect(
            credentialsError: credentialsError,
            applicationSupportURL: applicationSupportURL,
            fileManager: fileManager
        )
        if let storedCredentials {
            guard (try? storedCredentials.validate()) != nil else {
                return SyncStartupDecision(
                    activeCredentials: nil,
                    legacyDetection: SyncLegacyDetection(
                        credentialsInvalidated: true,
                        legacyStoragePresent: detection.legacyStoragePresent
                    ),
                    activationError: nil
                )
            }
            return SyncStartupDecision(
                activeCredentials: storedCredentials,
                legacyDetection: detection,
                activationError: nil
            )
        }
        if let credentialsError, !detection.credentialsInvalidated {
            return SyncStartupDecision(
                activeCredentials: nil,
                legacyDetection: detection,
                activationError: credentialsError
            )
        }
        return SyncStartupDecision(
            activeCredentials: nil,
            legacyDetection: detection,
            activationError: nil
        )
    }
}
