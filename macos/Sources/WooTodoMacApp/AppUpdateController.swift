import Sparkle

@MainActor
final class AppUpdateController {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkManually() {
        updaterController.checkForUpdates(nil)
    }

    func showAvailableUpdate() {
        updaterController.checkForUpdates(nil)
    }
}
