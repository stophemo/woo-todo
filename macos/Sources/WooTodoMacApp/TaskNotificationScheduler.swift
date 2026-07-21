import Foundation
@preconcurrency import UserNotifications
import WooTodoCore

@MainActor
final class TaskNotificationScheduler {
    private static let identifierPrefix = "woo-todo.task."
    private let center: UNUserNotificationCenter
    private var schedulingTask: Task<Void, Never>?
    private var generation = UUID()

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func synchronize(_ tasks: [TodoTask], now: Date = Date()) {
        let generation = UUID()
        self.generation = generation
        schedulingTask?.cancel()
        schedulingTask = Task { [weak self, center] in
            guard let self else { return }
            let candidates = tasks.compactMap { task -> (TodoTask, Date)? in
                guard let fireDate = TaskReminderSchedulePolicy.fireDate(for: task),
                      fireDate > now else { return nil }
                return (task, fireDate)
            }

            let settings = await center.notificationSettings()
            var authorized = settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined && !candidates.isEmpty {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            }

            guard !Task.isCancelled, self.generation == generation else { return }
            let pending = await center.pendingNotificationRequests()
            let managed = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.identifierPrefix) }
            guard !Task.isCancelled, self.generation == generation else { return }
            center.removePendingNotificationRequests(withIdentifiers: managed)
            guard authorized, !Task.isCancelled, self.generation == generation else { return }

            for (task, fireDate) in candidates {
                guard !Task.isCancelled, self.generation == generation else { return }
                let content = UNMutableNotificationContent()
                content.title = "待办提醒"
                content.body = task.title
                content.sound = .default
                content.userInfo = ["taskId": task.id.uuidString.lowercased()]

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TaskReminderSchedulePolicy.protocolTimeZone
                var components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: fireDate
                )
                components.timeZone = calendar.timeZone
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: Self.identifierPrefix + task.id.uuidString.lowercased(),
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }
    }
}
