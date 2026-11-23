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
    private let syncCredentialsStore: any SyncCredentialsStoring
    private let allowsAppRemoval: Bool

    init(
        fileManager: FileManager = .default,
        bundleIdentifier: String,
        bundleURL: URL,
        appSupportURL: URL,
        cachesURL: URL,
        savedStateURL: URL,
        defaults: UserDefaults,
        syncCredentialsStore: any SyncCredentialsStoring,
        allowsAppRemoval: Bool
    ) {
        self.fileManager = fileManager
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.appSupportURL = appSupportURL
        self.cachesURL = cachesURL
        self.savedStateURL = savedStateURL
        self.defaults = defaults
        self.syncCredentialsStore = syncCredentialsStore
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

        attempt { try syncCredentialsStore.delete() }
        // 0.3.0 起不再使用 WebDAV/局域网同步，但“清除本机数据”仍应覆盖旧凭据文件。
        for legacyURL in SyncLegacyDetector.legacyFileURLs(
            applicationSupportURL: appSupportURL
        ) where fileManager.fileExists(atPath: legacyURL.path) {
            attempt { try fileManager.removeItem(at: legacyURL) }
        }
        for directory in [appSupportURL, cachesURL, savedStateURL] {
            if fileManager.fileExists(atPath: directory.path) {
                attempt { try fileManager.removeItem(at: directory) }
            }
        }
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
