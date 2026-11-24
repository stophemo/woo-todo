import Foundation
import WooTodoSync

enum LocalDataManagerError: LocalizedError {
    case appRemovalDisabled
    case notApplicationBundle(String)

    var errorDescription: String? {
        switch self {
        case .appRemovalDisabled: "当前运行模式不允许自动移动应用"
        case .notApplicationBundle(let path): "无法自动卸载：\(path) 不是 .app 应用包，请手动拖到废纸篓"
        }
    }
}

@MainActor
final class LocalDataManager {
    private let fileManager: FileManager
    private let bundleIdentifier: String
    private let bundleURL: URL
    private let appSupportURL: URL
    private let cachesURL: URL
    private let savedStateURL: URL
    private let defaults: UserDefaults
    private let webDavCredentialsStore: any WebDavCredentialsStoring
    private let allowsAppRemoval: Bool

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String,
        bundleURL: URL,
        appSupportURL: URL,
        cachesURL: URL,
        savedStateURL: URL,
        defaults: UserDefaults,
        webDavCredentialsStore: any WebDavCredentialsStoring,
        allowsAppRemoval: Bool
    ) {
        self.fileManager = fileManager
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.appSupportURL = appSupportURL
        self.cachesURL = cachesURL
        self.savedStateURL = savedStateURL
        self.defaults = defaults
        self.webDavCredentialsStore = webDavCredentialsStore
        self.allowsAppRemoval = allowsAppRemoval
    }

    var dataDirectoryPath: String {
        appSupportURL.path
    }

    var canRemoveApplication: Bool {
        allowsAppRemoval
    }

    /// 删除本机任务库、凭据、偏好、缓存与窗口恢复状态。云端和其他设备不受影响。
    func clearLocalData() throws {
        var firstError: Error?
        func attempt(_ action: () throws -> Void) {
            do {
                try action()
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // 删除应用数据目录会一并覆盖旧版 Worker/局域网与旧 WebDAV 凭据文件。
        for directory in [appSupportURL, cachesURL, savedStateURL] {
            if fileManager.fileExists(atPath: directory.path) {
                attempt { try fileManager.removeItem(at: directory) }
            }
        }
        // 目录删除后再清一次凭据：删除旧 Keychain 项并重新写入迁移标记，
        // 确保“清除本机数据”后不会从 Keychain 回填旧身份。
        attempt { try webDavCredentialsStore.deleteIdentity() }
        attempt { try webDavCredentialsStore.deleteAccount() }
        attempt { defaults.removePersistentDomain(forName: bundleIdentifier) }
        defaults.synchronize()

        if let firstError {
            throw firstError
        }
    }

    func moveApplicationToTrash() throws {
        guard allowsAppRemoval else {
            throw LocalDataManagerError.appRemovalDisabled
        }
        guard bundleURL.pathExtension.lowercased() == "app" else {
            throw LocalDataManagerError.notApplicationBundle(bundleURL.path)
        }
        try fileManager.trashItem(at: bundleURL, resultingItemURL: nil)
    }
}
