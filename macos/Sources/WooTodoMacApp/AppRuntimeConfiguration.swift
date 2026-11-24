import Foundation
import WooTodoCore
import WooTodoStorage
import WooTodoSync

enum InitialScreen: Equatable {
    case panel
    case quickAdd
    case main(MainWindowSection)
    case settings(SettingsSection)
}

struct AppRuntimeConfiguration {
    static let uiTestBundleIdentifier = "io.github.stophemo.woo-todo.ui-test"

    let databaseURL: URL
    let appDataURL: URL
    let cachesURL: URL
    let savedStateURL: URL
    let defaults: UserDefaults
    let webDavCredentialsStore: any WebDavCredentialsStoring
    let allowsExternalServices: Bool
    let allowsLocalDataRemoval: Bool
    let initialScreen: InitialScreen
    let shouldSeedUITestFixtures: Bool
    let uiTestArtifactDirectory: URL?
    let uiTestScreenName: String?

    static func initialScreen(for screen: String) throws -> InitialScreen {
        switch screen {
        case "panel":
            return .panel
        case "quick-add":
            return .quickAdd
        case "main", "today":
            return .main(.today)
        case "tasks":
            // 旧截图脚本使用 tasks 表示完整任务列表。
            return .main(.all)
        case "all":
            return .main(.all)
        case "history":
            return .main(.history)
        case "statistics":
            return .main(.statistics)
        case "trash":
            return .main(.trash)
        case "display", "shortcuts", "sync", "mcp", "localData":
            guard let section = SettingsSection(rawValue: screen) else {
                throw AppRuntimeConfigurationError.invalidUITestScreen(screen)
            }
            return .settings(section)
        default:
            throw AppRuntimeConfigurationError.invalidUITestScreen(screen)
        }
    }

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
            let resolvedBundleIdentifier =
                bundleIdentifier ?? "io.github.stophemo.woo-todo"
            let caches = try fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent(resolvedBundleIdentifier, isDirectory: true)
            let savedState = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent(
                    "\(resolvedBundleIdentifier).savedState",
                    isDirectory: true
                )
            return Self(
                databaseURL: applicationData.appendingPathComponent("tasks.sqlite"),
                appDataURL: applicationData,
                cachesURL: caches,
                savedStateURL: savedState,
                defaults: .standard,
                webDavCredentialsStore: EncryptedFileWebDavCredentialsStore(
                    directoryURL: applicationData.appendingPathComponent(
                        "Secure",
                        isDirectory: true
                    )
                ),
                allowsExternalServices: true,
                allowsLocalDataRemoval: true,
                initialScreen: .panel,
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
        let initialScreen = try Self.initialScreen(for: screen)

        let defaultsSuite = "\(uiTestBundleIdentifier).\(root.lastPathComponent)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw AppRuntimeConfigurationError.defaultsUnavailable
        }
        return Self(
            databaseURL: root.appendingPathComponent("tasks.sqlite"),
            appDataURL: root,
            cachesURL: root.appendingPathComponent("caches", isDirectory: true),
            savedStateURL: root.appendingPathComponent("saved-state", isDirectory: true),
            defaults: defaults,
            webDavCredentialsStore: InMemoryWebDavCredentialsStore(),
            allowsExternalServices: false,
            allowsLocalDataRemoval: false,
            initialScreen: initialScreen,
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
        let work = try TaskCategory(id: "work", name: "工作", order: 1)
        let study = try TaskCategory(id: "study", name: "学习", order: 2)
        let life = try TaskCategory(id: "life", name: "生活", order: 3)
        try repository.saveCategories(
            TaskCategory.normalizeList(TaskCategory.defaults + [work, study, life])
        )
        try repository.save([
            TodoTask(
                title: "昨日遗留：提交本版本验收记录",
                categoryID: "work",
                startDate: yesterday,
                endDate: yesterday,
                sortIndex: 0,
                createdAt: yesterday
            ),
            TodoTask(
                title: "完成 macOS 面板验收",
                categoryID: "work",
                startDate: today,
                endDate: dayAfterTomorrow,
                sortIndex: 1,
                createdAt: now.addingTimeInterval(-180)
            ),
            TodoTask(
                title: "整理同步方式切换说明",
                categoryID: "study",
                startDate: today,
                endDate: tomorrow,
                sortIndex: 0,
                createdAt: now.addingTimeInterval(-120)
            ),
            TodoTask(
                title: "记录后续优化想法",
                categoryID: "life",
                sortIndex: 0,
                createdAt: now.addingTimeInterval(-60)
            ),
            TodoTask(
                title: "已完成示例",
                categoryID: "study",
                status: .completed,
                startDate: yesterday,
                endDate: yesterday,
                sortIndex: 2,
                createdAt: yesterday,
                completedAt: now
            ),
        ])
        try repository.saveDisplayConfiguration(WireDisplayConfigurationPayload(
            headerTemplate: "今日任务",
            subtitleTemplate: "重构第 {elapsedDays:2026-07-01} 天 · 距截止 {deadlineDays:2026-12-31} 天",
            startDate: "2026-01-01",
            deadlineDate: "2026-12-31"
        ))
        // 最近删除页面需要一条可见的恢复副本。
        let trashed = try TodoTask(
            title: "误删示例：整理桌面收纳盒",
            categoryID: "life",
            sortIndex: 1,
            createdAt: now.addingTimeInterval(-30)
        )
        try repository.save(trashed)
        try repository.delete(id: trashed.id)
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
