import Combine
import Foundation
import WooTodoCore

@MainActor
final class DayCounterStore: ObservableObject {
    private enum Keys {
        static let configurationVersion = "display.today.configurationVersion"
        static let headerTemplate = "display.today.headerTemplate"
        static let subtitleTemplate = "display.today.subtitleTemplate"
        static let startDate = "display.today.startDate"
        static let deadlineDate = "display.today.deadlineDate"

        static let legacyEnabled = "display.dayCounter.enabled"
        static let legacyTitle = "display.dayCounter.title"
        static let legacyStartDate = "display.dayCounter.startDate"
    }

    @Published private(set) var configuration: DayCounterConfiguration
    @Published private(set) var renderDate = Date()
    private let defaults: UserDefaults
    private var dateChangeObservers = Set<AnyCancellable>()
    private static let currentConfigurationVersion = 1

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let headerTemplate = defaults.object(forKey: Keys.headerTemplate) as? String
        let subtitleTemplate = defaults.object(forKey: Keys.subtitleTemplate) as? String
        let startDate = defaults.object(forKey: Keys.startDate) as? Date
        let deadlineDate = defaults.object(forKey: Keys.deadlineDate) as? Date
        let isCompleteCurrentConfiguration =
            defaults.integer(forKey: Keys.configurationVersion) == Self.currentConfigurationVersion
                && headerTemplate != nil
                && subtitleTemplate != nil
                && startDate != nil
                && deadlineDate != nil

        if isCompleteCurrentConfiguration,
           let headerTemplate,
           let subtitleTemplate,
           let startDate,
           let deadlineDate {
            configuration = DayCounterConfiguration(
                headerTemplate: headerTemplate,
                subtitleTemplate: subtitleTemplate,
                startDate: startDate,
                deadlineDate: deadlineDate
            )
        } else {
            let fallback = DayCounterConfiguration(
                isEnabled: defaults.bool(forKey: Keys.legacyEnabled),
                title: defaults.string(forKey: Keys.legacyTitle) ?? "",
                startDate: defaults.object(forKey: Keys.legacyStartDate) as? Date ?? Date()
            )
            configuration = DayCounterConfiguration(
                headerTemplate: headerTemplate ?? fallback.headerTemplate,
                subtitleTemplate: subtitleTemplate ?? fallback.subtitleTemplate,
                startDate: startDate ?? fallback.startDate,
                deadlineDate: deadlineDate ?? startDate ?? fallback.startDate
            )
            persist()
        }
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshDate()
                }
            }
            .store(in: &dateChangeObservers)
    }

    func update(
        headerTemplate: String,
        subtitleTemplate: String,
        startDate: Date,
        deadlineDate: Date
    ) {
        configuration = DayCounterConfiguration(
            headerTemplate: normalize(headerTemplate, limit: 80),
            subtitleTemplate: normalize(subtitleTemplate, limit: 160),
            startDate: startDate,
            deadlineDate: deadlineDate
        )
        persist()
    }

    func restoreDefaults() {
        configuration = DayCounterConfiguration()
        persist()
    }

    func refreshDate() {
        renderDate = Date()
    }

    private func normalize(_ value: String, limit: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(limit))
    }

    private func persist() {
        defaults.set(configuration.headerTemplate, forKey: Keys.headerTemplate)
        defaults.set(configuration.subtitleTemplate, forKey: Keys.subtitleTemplate)
        defaults.set(configuration.startDate, forKey: Keys.startDate)
        defaults.set(configuration.deadlineDate, forKey: Keys.deadlineDate)
        defaults.set(Self.currentConfigurationVersion, forKey: Keys.configurationVersion)
    }
}
