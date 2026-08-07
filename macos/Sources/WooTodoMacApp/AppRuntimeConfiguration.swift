import Foundation
import WooTodoCore
import WooTodoStorage
import WooTodoSync

struct AppRuntimeConfiguration {
    static let uiTestBundleIdentifier = "io.github.stophemo.woo-todo.ui-test"

    let databaseURL: URL
    let defaults: UserDefaults
    let syncCredentialsStore: any SyncCredentialsStoring
    let webDavCredentialsStore: any WebDavCredentialsStoring
    let allowsExternalServices: Bool
    let initialDashboardSection: DashboardSection?
    let shouldSeedUITestFixtures: Bool
    let uiTestArtifactDirectory: URL?
    let uiTestScreenName: String?

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        fileManager: FileManager = .default
    ) throws -> Self {
        guard environment["WOO_TODO_UI_TEST"] == "1" else {
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let applicationData = applicationSupport
                .appendingPathComponent("WooTodo", isDirectory: true)
            return Self(
                databaseURL: applicationData.appendingPathComponent("tasks.sqlite"),
                defaults: .standard,
                syncCredentialsStore: KeychainCredentialsStore(),
                webDavCredentialsStore: EncryptedFileWebDavCredentialsStore(
                    directoryURL: applicationData.appendingPathComponent(
                        "Secure",
                        isDirectory: true
                    )
                ),
                allowsExternalServices: true,
                initialDashboardSection: nil,
                shouldSeedUITestFixtures: false,
                uiTestArtifactDirectory: nil,
                uiTestScreenName: nil
            )
        }

        guard bundleIdentifier == uiTestBundleIdentifier else {
            throw AppRuntimeConfigurationError.invalidUITestBundle(bundleIdentifier)
        }
        guard let rawRoot = environment["WOO_TODO_UI_TEST_ROOT"], !rawRoot.isEmpty else {
            throw AppRuntimeConfigurationError.missingUITestRoot
        }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let safeRootPrefixes = [
            "/private/tmp/woo-todo-ui-",
            "/tmp/woo-todo-ui-",
        ]
        guard safeRootPrefixes.contains(where: root.path.hasPrefix) else {
            throw AppRuntimeConfigurationError.unsafeUITestRoot(root.path)
        }
        guard let fixedHome = environment["CFFIXED_USER_HOME"] else {
            throw AppRuntimeConfigurationError.missingFixedHome
        }
        let resolvedFixedHome = URL(fileURLWithPath: fixedHome, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard resolvedFixedHome == root else {
            throw AppRuntimeConfigurationError.fixedHomeMismatch(
                expected: root.path,
                actual: resolvedFixedHome.path
            )
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let screen = environment["WOO_TODO_UI_TEST_SCREEN"] ?? "panel"
        let initialDashboardSection: DashboardSection?
        if screen == "panel" {
            initialDashboardSection = nil
        } else if let section = DashboardSection(rawValue: screen) {
            initialDashboardSection = section
        } else {
            throw AppRuntimeConfigurationError.invalidUITestScreen(screen)
        }

        let defaultsSuite = "\(uiTestBundleIdentifier).\(root.lastPathComponent)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw AppRuntimeConfigurationError.defaultsUnavailable
        }
        let webDavCredentialsStore = InMemoryWebDavCredentialsStore()
        if initialDashboardSection == .sync {
            try webDavCredentialsStore.save(WebDavCredentials(
                endpoint: URL(string: "https://dav.example.invalid/woo-todo/")!,
                username: "ui-test@example.invalid",
                appPassword: "ui-test-only",
                vaultId: "vault-ui-test",
                deviceId: "ui-test-device-0001",
                vaultKey: Data(repeating: 7, count: 32)
            ))
        }
        return Self(
            databaseURL: root.appendingPathComponent("tasks.sqlite"),
            defaults: defaults,
            syncCredentialsStore: InMemorySyncCredentialsStore(),
            webDavCredentialsStore: webDavCredentialsStore,
            allowsExternalServices: false,
            initialDashboardSection: initialDashboardSection,
            shouldSeedUITestFixtures: true,
            uiTestArtifactDirectory: root,
            uiTestScreenName: screen
        )
    }
}

enum UITestFixtureSeeder {
    static func seedIfNeeded(
        repository: SQLiteTaskRepository,
        now: Date = Date(),
        calendar sourceCalendar: Calendar = .current
    ) throws {
        guard try repository.fetchAll().isEmpty else { return }

        var calendar = sourceCalendar
        calendar.timeZone = sourceCalendar.timeZone
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: today) else {
            throw AppRuntimeConfigurationError.fixtureDateFailed
        }
        let overduePeriod = TaskPeriod(start: yesterday, end: today)
        let currentPeriod = TaskPeriod(start: today, end: tomorrow)

        try repository.save([
            TodoTask(
                title: "昨日遗留：提交本版本验收记录",
                timeScope: .daily,
                tier: .mainline,
                period: overduePeriod,
                sortIndex: 0,
                createdAt: yesterday,
                deadlineDate: today
            ),
            TodoTask(
                title: "完成 macOS 面板验收",
                timeScope: .daily,
                tier: .mainline,
                period: currentPeriod,
                sortIndex: 1,
                createdAt: now.addingTimeInterval(-180),
                deadlineDate: dayAfterTomorrow
            ),
            TodoTask(
                title: "整理同步方式切换说明",
                timeScope: .daily,
                tier: .side,
                period: currentPeriod,
                sortIndex: 0,
                createdAt: now.addingTimeInterval(-120)
            ),
            TodoTask(
                title: "记录后续优化想法",
                timeScope: .daily,
                tier: .extra,
                period: currentPeriod,
                sortIndex: 0,
                createdAt: now.addingTimeInterval(-60)
            ),
        ])
        try repository.saveDisplayConfiguration(WireDisplayConfigurationPayload(
            headerTemplate: "今日任务",
            subtitleTemplate: "重构第 {elapsedDays:2026-07-01} 天 · 距截止 {deadlineDays:2026-12-31} 天",
            startDate: "2026-01-01",
            deadlineDate: "2026-12-31"
        ))
    }
}

private final class InMemorySyncCredentialsStore: SyncCredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: SyncCredentials?

    func save(_ credentials: SyncCredentials) throws {
        try credentials.validate()
        lock.lock()
        defer { lock.unlock() }
        self.credentials = credentials
    }

    func load() throws -> SyncCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        credentials = nil
    }
}

private final class InMemoryWebDavCredentialsStore: WebDavCredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: WebDavCredentials?

    func save(_ credentials: WebDavCredentials) throws {
        try credentials.validate()
        lock.lock()
        defer { lock.unlock() }
        self.credentials = credentials
    }

    func load() throws -> WebDavCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        credentials = nil
    }
}

private enum AppRuntimeConfigurationError: LocalizedError {
    case invalidUITestBundle(String?)
    case missingUITestRoot
    case unsafeUITestRoot(String)
    case missingFixedHome
    case fixedHomeMismatch(expected: String, actual: String)
    case invalidUITestScreen(String)
    case defaultsUnavailable
    case fixtureDateFailed

    var errorDescription: String? {
        switch self {
        case .invalidUITestBundle(let identifier):
            "UI 测试模式只能由专用 Bundle 启动，当前为 \(identifier ?? "未知")"
        case .missingUITestRoot:
            "UI 测试模式缺少 WOO_TODO_UI_TEST_ROOT"
        case .unsafeUITestRoot(let path):
            "UI 测试目录必须位于系统临时目录的 woo-todo-ui-* 下，当前为 \(path)"
        case .missingFixedHome:
            "UI 测试模式缺少 CFFIXED_USER_HOME"
        case .fixedHomeMismatch(let expected, let actual):
            "CFFIXED_USER_HOME 必须与 UI 测试目录一致：期望 \(expected)，当前为 \(actual)"
        case .invalidUITestScreen(let value):
            "未知的 UI 测试页面：\(value)"
        case .defaultsUnavailable:
            "无法创建 UI 测试专用偏好设置"
        case .fixtureDateFailed:
            "无法生成 UI 测试日期"
        }
    }
}
