import Foundation
import WooTodoCore

@MainActor
final class DailyDigestSettingsStore: ObservableObject {
    private enum Keys {
        static let enabled = "reminder.dailyDigest.enabled.v1"
        static let hour = "reminder.dailyDigest.hour.v1"
        static let minute = "reminder.dailyDigest.minute.v1"
    }

    @Published var isEnabled: Bool {
        didSet { persist() }
    }
    @Published var time: Date {
        didSet { persist() }
    }

    var onChange: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let hour = defaults.object(forKey: Keys.hour) as? Int ?? 23
        let minute = defaults.object(forKey: Keys.minute) as? Int ?? 10
        time = Calendar.current.date(
            bySettingHour: (0...23).contains(hour) ? hour : 23,
            minute: (0...59).contains(minute) ? minute : 10,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    var configuration: DailyDigestConfiguration {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let reminderTime = (try? TaskReminderTime(
            hour: components.hour ?? 23,
            minute: components.minute ?? 10
        )) ?? (try! TaskReminderTime(hour: 23, minute: 10))
        return DailyDigestConfiguration(enabled: isEnabled, time: reminderTime)
    }

    private func persist() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        defaults.set(isEnabled, forKey: Keys.enabled)
        defaults.set(components.hour ?? 23, forKey: Keys.hour)
        defaults.set(components.minute ?? 10, forKey: Keys.minute)
        onChange?()
    }
}
