import Foundation
import Sparkle
import WooTodoCore

enum AppUpdateState: Equatable {
    case idle
    case checking
    case available(String)
    case downloading(String)
}

@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private enum Keys {
        static let lastSuccessfulCheckAt = "appUpdate.lastSuccessfulCheckAt"
        static let lastAttemptAt = "appUpdate.lastAttemptAt"
    }

    var onStateChange: ((AppUpdateState) -> Void)?
    var onMessage: ((String, String) -> Void)?
    var onUpdateAvailable: ((String) -> Void)?

    private let defaults: UserDefaults
    private var updaterController: SPUStandardUpdaterController!
    private var retryTimer: Timer?
    private var state = AppUpdateState.idle
    private var availableVersion: String?
    private var probeIsManual = false
    private var forceCurrentProbe = false
    private var probeProducedResult = false
    private var installWhenReady = false
    private var immediateInstallHandler: (() -> Void)?
    private var lastNotifiedVersion: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        let updater = updaterController.updater
        // 检查由本控制器调度；仅在用户点击菜单后临时启用静默下载。
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        let timer = Timer(
            timeInterval: AppUpdatePolicy.automaticCheckPollingInterval,
            target: self,
            selector: #selector(retryTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    func checkOnLaunch() {
        beginProbe(manual: false, force: true)
    }

    func checkAutomatically() {
        let now = Date()
        guard AppUpdatePolicy.shouldPerformAutomaticCheck(
            lastSuccessfulCheckAt: defaults.object(forKey: Keys.lastSuccessfulCheckAt) as? Date,
            lastAttemptAt: defaults.object(forKey: Keys.lastAttemptAt) as? Date,
            now: now
        ) else { return }
        beginProbe(manual: false, force: false)
    }

    func performMenuAction() {
        switch state {
        case let .available(version):
            beginInstallation(version: version)
        case .idle:
            beginProbe(manual: true, force: true)
        case .checking:
            onMessage?("正在检查更新", "检查在后台进行，完成后会在菜单中显示结果。")
        case .downloading:
            onMessage?("正在更新", "更新正在后台下载和校验，请稍候。")
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func beginProbe(manual: Bool, force: Bool) {
        let updater = updaterController.updater
        guard !updater.sessionInProgress else {
            if manual {
                onMessage?("正在检查更新", "检查在后台进行，完成后会在菜单中显示结果。")
            }
            return
        }
        probeIsManual = manual
        forceCurrentProbe = force
        probeProducedResult = false
        setState(.checking)
        updater.checkForUpdateInformation()
    }

    private func beginInstallation(version: String) {
        let updater = updaterController.updater
        installWhenReady = true
        setState(.downloading(version))
        if let immediateInstallHandler {
            updater.automaticallyDownloadsUpdates = false
            immediateInstallHandler()
            return
        }
        guard !updater.sessionInProgress else { return }
        probeIsManual = false
        forceCurrentProbe = true
        probeProducedResult = false
        updater.automaticallyDownloadsUpdates = true
        updater.checkForUpdatesInBackground()
    }

    private func setState(_ newState: AppUpdateState) {
        state = newState
        onStateChange?(newState)
    }

    @objc private func retryTimerFired(_ timer: Timer) {
        checkAutomatically()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let now = Date()
        if updateCheck != .updates && !forceCurrentProbe {
            guard AppUpdatePolicy.shouldPerformAutomaticCheck(
                lastSuccessfulCheckAt: defaults.object(forKey: Keys.lastSuccessfulCheckAt) as? Date,
                lastAttemptAt: defaults.object(forKey: Keys.lastAttemptAt) as? Date,
                now: now
            ) else {
                throw NSError(
                    domain: "io.github.stophemo.woo-todo.update",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "自动更新检查尚未到期"]
                )
            }
        }
        defaults.set(now, forKey: Keys.lastAttemptAt)
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        defaults.set(Date(), forKey: Keys.lastSuccessfulCheckAt)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        probeProducedResult = true
        let version = item.displayVersionString
        availableVersion = version
        if installWhenReady {
            setState(.downloading(version))
        } else {
            setState(.available(version))
            announceAvailableVersion(version)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        probeProducedResult = true
        let wasInstalling = installWhenReady
        installWhenReady = false
        immediateInstallHandler = nil
        updater.automaticallyDownloadsUpdates = false
        availableVersion = nil
        lastNotifiedVersion = nil
        setState(.idle)
        if wasInstalling {
            onMessage?("无法更新", "刚才发现的版本已不可用，请重新检查。")
        } else if probeIsManual {
            let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "当前版本"
            onMessage?("已是最新版本", "当前版本为 v\(version)。")
        }
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state userState: SPUUserUpdateState
    ) {
        switch choice {
        case .install:
            setState(.downloading(item.displayVersionString))
        case .dismiss, .skip:
            installWhenReady = false
            setState(.available(item.displayVersionString))
        @unknown default:
            setState(.available(item.displayVersionString))
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        let wasManual = probeIsManual
        let shouldStartQueuedInstallation = error == nil &&
            installWhenReady &&
            immediateInstallHandler == nil &&
            updateCheck == .updateInformation &&
            availableVersion != nil
        probeIsManual = false
        forceCurrentProbe = false

        if shouldStartQueuedInstallation, let availableVersion {
            beginInstallation(version: availableVersion)
            return
        }
        guard error != nil else {
            if case .checking = state {
                setState(availableVersion.map(AppUpdateState.available) ?? .idle)
            }
            return
        }
        let wasInstalling = installWhenReady
        if wasInstalling {
            installWhenReady = false
            immediateInstallHandler = nil
            updater.automaticallyDownloadsUpdates = false
        }
        if availableVersion == nil {
            setState(.idle)
        } else if let availableVersion {
            setState(.available(availableVersion))
        }
        if wasInstalling {
            onMessage?("更新失败", "下载或校验未完成，请稍后重试。")
        } else if wasManual && !probeProducedResult {
            onMessage?("检查更新失败", "网络暂时不可用，请稍后重试。")
        }
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        availableVersion = item.displayVersionString
        self.immediateInstallHandler = immediateInstallHandler
        updater.automaticallyDownloadsUpdates = false
        if installWhenReady {
            setState(.downloading(item.displayVersionString))
            immediateInstallHandler()
        } else {
            setState(.available(item.displayVersionString))
        }
        return true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state userState: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        availableVersion = update.displayVersionString
        setState(.available(update.displayVersionString))
        announceAvailableVersion(update.displayVersionString)
    }

    private func announceAvailableVersion(_ version: String) {
        guard lastNotifiedVersion != version else { return }
        lastNotifiedVersion = version
        onUpdateAvailable?(version)
    }
}
