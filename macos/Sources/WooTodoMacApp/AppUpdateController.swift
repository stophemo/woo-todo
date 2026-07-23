import AppKit
import Foundation
import WooTodoCore

struct AvailableAppUpdate: Sendable {
    let version: AppVersion
    let releasePageURL: URL
}

enum AppUpdateCheckError: LocalizedError, Sendable {
    case networkUnavailable
    case invalidResponse
    case httpStatus(Int)
    case invalidRelease

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            "无法连接 GitHub，请检查网络后重试。"
        case .invalidResponse:
            "GitHub 没有返回有效响应，请稍后重试。"
        case .httpStatus(let status):
            "GitHub 更新服务暂时不可用（HTTP \(status)），请稍后重试。"
        case .invalidRelease:
            "GitHub 最新正式 Release 的版本或下载地址无效。"
        }
    }
}

struct GitHubReleaseClient: @unchecked Sendable {
    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    private let endpoint: URL
    private let session: URLSession

    init(session: URLSession = .shared) {
        endpoint = URL(
            string: "https://api.github.com/repos/stophemo/woo-todo/releases/latest"
        )!
        self.session = session
    }

    func fetchLatestRelease() async throws -> AvailableAppUpdate {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Woo-Todo-macOS", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AppUpdateCheckError.networkUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateCheckError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw AppUpdateCheckError.httpStatus(httpResponse.statusCode)
        }
        guard data.count <= 1_000_000,
              let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data),
              !payload.draft,
              !payload.prerelease,
              let version = AppUpdatePolicy.stableReleaseVersion(
                  fromGitHubTag: payload.tagName
              ),
              payload.htmlURL.scheme?.lowercased() == "https",
              payload.htmlURL.host?.lowercased() == "github.com",
              payload.htmlURL.user == nil,
              payload.htmlURL.password == nil,
              payload.htmlURL.port == nil,
              payload.htmlURL.query == nil,
              payload.htmlURL.fragment == nil,
              payload.htmlURL.path == "/stophemo/woo-todo/releases/tag/\(payload.tagName)" else {
            throw AppUpdateCheckError.invalidRelease
        }
        return AvailableAppUpdate(
            version: version,
            releasePageURL: payload.htmlURL
        )
    }
}

@MainActor
final class AppUpdateController {
    private static let lastAutomaticCheckKey = "updates.lastAutomaticCheckAt.v1"
    private static let lastAutomaticAttemptKey = "updates.lastAutomaticAttemptAt.v1"
    private static let lastHandledVersionKey = "updates.lastHandledVersion.v1"
    private static let legacyLastNotifiedVersionKey = "updates.lastNotifiedVersion.v1"

    private let defaults: UserDefaults
    private let bundle: Bundle
    private let client: GitHubReleaseClient
    private let now: () -> Date

    private var activeCheck: Task<Void, Never>?
    private var manualFeedbackRequested = false

    init(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        client: GitHubReleaseClient = GitHubReleaseClient(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.bundle = bundle
        self.client = client
        self.now = now
    }

    func checkAutomatically() {
        guard activeCheck == nil,
              let currentVersion = installedVersion() else {
            return
        }
        let checkedAt = now()
        guard AppUpdatePolicy.shouldPerformAutomaticCheck(
            lastCheckedAt: lastAutomaticCheckDate(),
            now: checkedAt
        ), AppUpdatePolicy.shouldPerformAutomaticCheck(
            lastCheckedAt: lastAutomaticAttemptDate(),
            now: checkedAt,
            minimumInterval: AppUpdatePolicy.failedCheckRetryInterval
        ) else {
            return
        }
        recordAttempt(at: checkedAt)
        beginCheck(currentVersion: currentVersion, reportAllResults: false)
    }

    func checkManually() {
        guard let currentVersion = installedVersion() else {
            presentMessage(
                title: "无法检查更新",
                message: "无法读取当前安装包版本，请重新安装正式发布包后再试。",
                style: .warning
            )
            return
        }
        if activeCheck != nil {
            manualFeedbackRequested = true
            return
        }
        beginCheck(currentVersion: currentVersion, reportAllResults: true)
    }

    func stop() {
        activeCheck?.cancel()
        activeCheck = nil
        manualFeedbackRequested = false
    }

    private func beginCheck(
        currentVersion: AppVersion,
        reportAllResults: Bool
    ) {
        manualFeedbackRequested = reportAllResults
        activeCheck = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeCheck = nil
                self.manualFeedbackRequested = false
            }
            do {
                let release = try await self.client.fetchLatestRelease()
                guard !Task.isCancelled else { return }
                self.recordSuccessfulCheck(at: self.now())
                self.handle(
                    release,
                    currentVersion: currentVersion,
                    reportAllResults: self.manualFeedbackRequested
                )
            } catch {
                guard !Task.isCancelled, self.manualFeedbackRequested else { return }
                self.presentMessage(
                    title: "无法检查更新",
                    message: error.localizedDescription,
                    style: .warning
                )
            }
        }
    }

    private func handle(
        _ release: AvailableAppUpdate,
        currentVersion: AppVersion,
        reportAllResults: Bool
    ) {
        let lastHandledVersion = (
            defaults.string(forKey: Self.lastHandledVersionKey)
                ?? defaults.string(forKey: Self.legacyLastNotifiedVersionKey)
        )
            .flatMap { AppVersion($0) }
        let shouldNotify = AppUpdatePolicy.shouldNotify(
            currentVersion: currentVersion,
            latestVersion: release.version,
            lastHandledVersion: lastHandledVersion
        )

        if release.version > currentVersion, reportAllResults || shouldNotify {
            if presentUpdate(release, currentVersion: currentVersion) {
                defaults.set(
                    release.version.description,
                    forKey: Self.lastHandledVersionKey
                )
                defaults.removeObject(forKey: Self.legacyLastNotifiedVersionKey)
            }
        } else if reportAllResults {
            presentMessage(
                title: "已经是最新版本",
                message: "当前安装的是 Woo Todo v\(currentVersion)。",
                style: .informational
            )
        }
    }

    private func installedVersion() -> AppVersion? {
        guard let value = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return nil
        }
        return AppVersion(value)
    }

    private func lastAutomaticCheckDate() -> Date? {
        guard let value = defaults.object(
            forKey: Self.lastAutomaticCheckKey
        ) as? NSNumber else {
            return nil
        }
        let timestamp = value.doubleValue
        guard timestamp.isFinite else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func lastAutomaticAttemptDate() -> Date? {
        guard let value = defaults.object(
            forKey: Self.lastAutomaticAttemptKey
        ) as? NSNumber else {
            return nil
        }
        let timestamp = value.doubleValue
        guard timestamp.isFinite else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func recordAttempt(at date: Date) {
        defaults.set(
            date.timeIntervalSince1970,
            forKey: Self.lastAutomaticAttemptKey
        )
    }

    private func recordSuccessfulCheck(at date: Date) {
        defaults.set(
            date.timeIntervalSince1970,
            forKey: Self.lastAutomaticCheckKey
        )
    }

    private func presentUpdate(
        _ release: AvailableAppUpdate,
        currentVersion: AppVersion
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 v\(release.version)"
        alert.informativeText = "当前版本为 v\(currentVersion)。你可以选择更新或忽略此版本；更新会打开 GitHub Release 下载页。"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "忽略此版本")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
            return false
        }
        guard response == .alertFirstButtonReturn else { return true }
        guard NSWorkspace.shared.open(release.releasePageURL) else {
            presentMessage(
                title: "无法打开下载页",
                message: "请稍后再次选择菜单栏中的“检查更新…”。",
                style: .warning
            )
            return true
        }
        return true
    }

    private func presentMessage(
        title: String,
        message: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
