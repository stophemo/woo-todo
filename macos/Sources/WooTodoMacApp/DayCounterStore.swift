import Combine
import Foundation
import WooTodoCore

@MainActor
final class DayCounterStore: ObservableObject {
    private enum Keys {
        static let enabled = "display.dayCounter.enabled"
        static let title = "display.dayCounter.title"
        static let startDate = "display.dayCounter.startDate"
    }

    @Published private(set) var configuration: DayCounterConfiguration
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = DayCounterConfiguration(
            isEnabled: defaults.bool(forKey: Keys.enabled),
            title: defaults.string(forKey: Keys.title) ?? "",
            startDate: defaults.object(forKey: Keys.startDate) as? Date ?? Date()
        )
    }

    func update(isEnabled: Bool, title: String, startDate: Date) {
        let normalizedTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        configuration = DayCounterConfiguration(
            isEnabled: isEnabled && !normalizedTitle.isEmpty,
            title: normalizedTitle,
            startDate: startDate
        )
        defaults.set(configuration.isEnabled, forKey: Keys.enabled)
        defaults.set(configuration.title, forKey: Keys.title)
        defaults.set(configuration.startDate, forKey: Keys.startDate)
    }

    func disable() {
        update(
            isEnabled: false,
            title: configuration.title,
            startDate: configuration.startDate
        )
    }
}
