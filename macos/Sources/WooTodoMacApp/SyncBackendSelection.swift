import Foundation

enum SyncBackendSelection: String {
    case workerOrLocal
    case webDav

    private static let defaultsKey = "sync.active-backend"

    static func resolve(
        defaults: UserDefaults,
        hasWorkerOrLocalCredentials: Bool,
        hasWebDavCredentials: Bool
    ) -> Self? {
        if let rawValue = defaults.string(forKey: defaultsKey),
           let selected = Self(rawValue: rawValue),
           selected == .workerOrLocal ? hasWorkerOrLocalCredentials : hasWebDavCredentials {
            return selected
        }
        if hasWorkerOrLocalCredentials { return .workerOrLocal }
        if hasWebDavCredentials { return .webDav }
        return nil
    }

    func persist(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
