import Foundation
import OSLog
@preconcurrency import UserNotifications
import WooTodoCore

@MainActor
final class TaskNotificationScheduler {
    private static let identifierPrefix = "woo-todo.task."
    private static let digestIdentifier = "woo-todo.daily-digest"
    private static let logger = Logger(
        subsystem: "io.github.stophemo.woo-todo",
        category: "任务提醒"
    )
    private let center: UNUserNotificationCenter
    private var schedulingTask: Task<Void, Never>?
    private var generation = UUID()

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func synchronize(
        _ tasks: [TodoTask],
        digest: DailyDigestConfiguration,
        now: Date = Date()
    ) {
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
            let digestFireDate = digest.enabled
                ? Self.nextDigestFireDate(for: digest.time, after: now)
                : nil

            let settings = await center.notificationSettings()
            var authorized = settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined,
               !candidates.isEmpty || digestFireDate != nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            }

            guard !Task.isCancelled, self.generation == generation else { return }
            let pending = await center.pendingNotificationRequests()
            let managed = pending
                .map(\.identifier)
                .filter {
                    $0.hasPrefix(Self.identifierPrefix)
                        || $0 == Self.digestIdentifier
                }
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
                do {
                    try await center.add(request)
                } catch {
                    // 单条提醒调度失败不中断其余提醒，但记录日志便于排查。
                    Self.logger.error(
                        "无法调度任务提醒 \(task.id.uuidString, privacy: .public)：\(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            guard let digestFireDate,
                  !Task.isCancelled,
                  self.generation == generation else { return }
            let message = DailyDigestBuilder.message(tasks: tasks, on: digestFireDate)
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            content.sound = .default
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TaskReminderSchedulePolicy.protocolTimeZone
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: digestFireDate
            )
            components.timeZone = calendar.timeZone
            let request = UNNotificationRequest(
                identifier: Self.digestIdentifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: false
                )
            )
            do {
                try await center.add(request)
            } catch {
                Self.logger.error(
                    "无法调度晚间提醒：\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func nextDigestFireDate(
        for time: TaskReminderTime,
        after now: Date
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TaskReminderSchedulePolicy.protocolTimeZone
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.timeZone = calendar.timeZone
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        guard var fireDate = calendar.date(from: components) else { return nil }
        if fireDate <= now {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: fireDate) else {
                return nil
            }
            fireDate = nextDay
        }
        return fireDate
    }
}
