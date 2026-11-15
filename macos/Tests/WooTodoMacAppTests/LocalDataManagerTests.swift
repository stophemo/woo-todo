import Foundation
import Testing
import WooTodoSync
@testable import WooTodoMacApp

@Suite("本机数据清理")
@MainActor
struct LocalDataManagerTests {
    @Test("清除本机数据会删除目录、偏好和凭据并保留目录外文件")
    func clearLocalData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-local-data-\(UUID().uuidString)", isDirectory: true)
        let appData = root.appendingPathComponent("app-data", isDirectory: true)
        let secure = appData.appendingPathComponent("Secure", isDirectory: true)
        let caches = root.appendingPathComponent("caches", isDirectory: true)
        let savedState = root.appendingPathComponent("saved-state", isDirectory: true)
        let outside = root.appendingPathComponent("outside.txt")
        let bundle = root.appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: secure, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: savedState, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: appData.appendingPathComponent("tasks.sqlite"))
        try Data("secret".utf8).write(to: secure.appendingPathComponent("webdav.json"))
        try Data("cache".utf8).write(to: caches.appendingPathComponent("cache.txt"))
        try Data("state".utf8).write(to: savedState.appendingPathComponent("state.txt"))
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleIdentifier = "io.github.stophemo.woo-todo.local-data-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: bundleIdentifier))
        defer { defaults.removePersistentDomain(forName: bundleIdentifier) }
        defaults.set("value", forKey: "kept-key")
        let syncStore = FakeSyncCredentialsStore()
        let webDavStore = FakeWebDavCredentialsStore()
        let manager = LocalDataManager(
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundle,
            appSupportURL: appData,
            cachesURL: caches,
            savedStateURL: savedState,
            defaults: defaults,
            syncCredentialsStore: syncStore,
            webDavCredentialsStore: webDavStore,
            allowsAppRemoval: false
        )

        try manager.clearLocalData()

        #expect(!FileManager.default.fileExists(atPath: appData.path))
        #expect(!FileManager.default.fileExists(atPath: caches.path))
        #expect(!FileManager.default.fileExists(atPath: savedState.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(defaults.object(forKey: "kept-key") == nil)
        #expect(syncStore.deleted)
        #expect(webDavStore.deleted)

        try manager.clearLocalData()
    }

    @Test("禁止自动卸载时移动应用会失败")
    func moveApplicationDisabled() throws {
        let manager = makeManager(allowsAppRemoval: false, bundleExtension: "app")
        #expect(throws: LocalDataManagerError.self) {
            try manager.moveApplicationToTrash()
        }
    }

    @Test("非 app 包不能自动移入废纸篓")
    func moveNonApplicationBundle() throws {
        let manager = makeManager(allowsAppRemoval: true, bundleExtension: "txt")
        #expect(throws: LocalDataManagerError.self) {
            try manager.moveApplicationToTrash()
        }
    }

    private func makeManager(
        allowsAppRemoval: Bool,
        bundleExtension: String
    ) -> LocalDataManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-local-data-\(UUID().uuidString)", isDirectory: true)
        return LocalDataManager(
            bundleIdentifier: "io.github.stophemo.woo-todo.test",
            bundleURL: root.appendingPathComponent("Fake.\(bundleExtension)"),
            appSupportURL: root,
            cachesURL: root,
            savedStateURL: root,
            defaults: UserDefaults(suiteName: "woo-todo.local-data-test")!,
            syncCredentialsStore: FakeSyncCredentialsStore(),
            webDavCredentialsStore: FakeWebDavCredentialsStore(),
            allowsAppRemoval: allowsAppRemoval
        )
    }
}

private final class FakeSyncCredentialsStore: SyncCredentialsStoring, @unchecked Sendable {
    private(set) var deleted = false

    func save(_ credentials: SyncCredentials) throws {}
    func load() throws -> SyncCredentials? { nil }
    func delete() throws { deleted = true }
}

private final class FakeWebDavCredentialsStore: WebDavCredentialsStoring, @unchecked Sendable {
    private(set) var deleted = false

    func save(_ credentials: WebDavCredentials) throws {}
    func load() throws -> WebDavCredentials? { nil }
    func delete() throws { deleted = true }
}
