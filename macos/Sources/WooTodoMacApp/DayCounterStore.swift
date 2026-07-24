import Combine
import Foundation
import WooTodoCore
import WooTodoStorage
import WooTodoSync

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
    @Published private(set) var persistenceErrorMessage: String?
    var onLocalConfigurationChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let repository: SQLiteTaskRepository
    private var dateChangeObservers = Set<AnyCancellable>()
    private static let currentConfigurationVersion = 1

    init(
        defaults: UserDefaults = .standard,
        repository: SQLiteTaskRepository
    ) {
        self.defaults = defaults
        self.repository = repository
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
                headerTemplate: Self.normalize(headerTemplate, limit: 80),
                subtitleTemplate: Self.normalize(subtitleTemplate, limit: 160),
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
                headerTemplate: Self.normalize(
                    headerTemplate ?? fallback.headerTemplate,
                    limit: 80
                ),
                subtitleTemplate: Self.normalize(
                    subtitleTemplate ?? fallback.subtitleTemplate,
                    limit: 160
                ),
                startDate: startDate ?? fallback.startDate,
                deadlineDate: deadlineDate ?? startDate ?? fallback.startDate
            )
        }
        loadRepositoryConfiguration()
        persistDefaults()

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshDate()
                }
            }
            .store(in: &dateChangeObservers)
    }

    @discardableResult
    func update(
        headerTemplate: String,
        subtitleTemplate: String,
        startDate: Date,
        deadlineDate: Date
    ) -> Bool {
        saveLocalConfiguration(DayCounterConfiguration(
            headerTemplate: Self.normalize(headerTemplate, limit: 80),
            subtitleTemplate: Self.normalize(subtitleTemplate, limit: 160),
            startDate: startDate,
            deadlineDate: deadlineDate
        ))
    }

    @discardableResult
    func restoreDefaults() -> Bool {
        saveLocalConfiguration(DayCounterConfiguration())
    }

    func reloadFromRepository() {
        do {
            guard let payload = try repository.displayConfiguration() else { return }
            let incoming = try Self.configuration(from: payload)
            if incoming != configuration {
                configuration = incoming
                persistDefaults()
            }
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = "无法读取同步的显示设置：\(error.localizedDescription)"
        }
    }

    func refreshDate() {
        renderDate = Date()
    }

    private func loadRepositoryConfiguration() {
        do {
            if let payload = try repository.displayConfiguration() {
                configuration = try Self.configuration(from: payload)
            } else {
                let payload = try Self.payload(from: configuration)
                try repository.saveDisplayConfiguration(payload)
                configuration = try Self.configuration(from: payload)
            }
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = "无法保存显示设置：\(error.localizedDescription)"
        }
    }

    private func saveLocalConfiguration(_ value: DayCounterConfiguration) -> Bool {
        do {
            let payload = try Self.payload(from: value)
            try repository.saveDisplayConfiguration(payload)
            configuration = try Self.configuration(from: payload)
            persistDefaults()
            persistenceErrorMessage = nil
            onLocalConfigurationChanged?()
            return true
        } catch {
            persistenceErrorMessage = "无法保存显示设置：\(error.localizedDescription)"
            return false
        }
    }

    private static func normalize(_ value: String, limit: Int) -> String {
        let singleLine = value
            .map { $0.isNewline ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.unicodeScalars.prefix(limit))
    }

    private func persistDefaults() {
        defaults.set(configuration.headerTemplate, forKey: Keys.headerTemplate)
        defaults.set(configuration.subtitleTemplate, forKey: Keys.subtitleTemplate)
        defaults.set(configuration.startDate, forKey: Keys.startDate)
        defaults.set(configuration.deadlineDate, forKey: Keys.deadlineDate)
        defaults.set(Self.currentConfigurationVersion, forKey: Keys.configurationVersion)
    }

    private static func payload(
        from configuration: DayCounterConfiguration
    ) throws -> WireDisplayConfigurationPayload {
        try WireDisplayConfigurationPayload(
            headerTemplate: normalize(configuration.headerTemplate, limit: 80),
            subtitleTemplate: normalize(configuration.subtitleTemplate, limit: 160),
            startDate: wireDateKey(configuration.startDate),
            deadlineDate: wireDateKey(configuration.deadlineDate)
        )
    }

    private static func configuration(
        from payload: WireDisplayConfigurationPayload
    ) throws -> DayCounterConfiguration {
        try payload.validate()
        guard let startDate = date(fromWireKey: payload.startDate),
              let deadlineDate = date(fromWireKey: payload.deadlineDate) else {
            throw DayCounterStoreError.invalidDate
        }
        return DayCounterConfiguration(
            headerTemplate: payload.headerTemplate,
            subtitleTemplate: payload.subtitleTemplate,
            startDate: startDate,
            deadlineDate: deadlineDate
        )
    }

    private static func wireDateKey(_ date: Date) -> String {
        let components = wireCalendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private static func date(fromWireKey value: String) -> Date? {
        let values = value.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = wireCalendar
        components.timeZone = wireCalendar.timeZone
        components.year = values[0]
        components.month = values[1]
        components.day = values[2]
        return wireCalendar.date(from: components)
    }

    private static var wireCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: WireTaskPayload.fixedTimeZone)!
        return calendar
    }

    private enum DayCounterStoreError: LocalizedError {
        case invalidDate

        var errorDescription: String? {
            "同步的显示日期无效"
        }
    }
}
