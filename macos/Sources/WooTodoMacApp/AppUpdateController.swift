import Foundation
import Sparkle
import WooTodoCore

@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate {
    private enum Keys {
        static let lastSuccessfulCheckAt = "appUpdate.lastSuccessfulCheckAt"
        static let lastAttemptAt = "appUpdate.lastAttemptAt"
    }

    private let defaults: UserDefaults
    private var updaterController: SPUStandardUpdaterController!
    private var retryTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
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

    func checkManually() {
        updaterController.checkForUpdates(nil)
    }

    func checkAutomatically() {
        let updater = updaterController.updater
        let now = Date()
        guard !updater.sessionInProgress,
              AppUpdatePolicy.shouldPerformAutomaticCheck(
                  lastSuccessfulCheckAt: defaults.object(
                      forKey: Keys.lastSuccessfulCheckAt
                  ) as? Date,
                  lastAttemptAt: defaults.object(forKey: Keys.lastAttemptAt) as? Date,
                  now: now
              ) else { return }
        updater.checkForUpdatesInBackground()
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    @objc private func retryTimerFired(_ timer: Timer) {
        checkAutomatically()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let now = Date()
        if updateCheck != .updates {
            guard AppUpdatePolicy.shouldPerformAutomaticCheck(
                lastSuccessfulCheckAt: defaults.object(
                    forKey: Keys.lastSuccessfulCheckAt
                ) as? Date,
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
}
