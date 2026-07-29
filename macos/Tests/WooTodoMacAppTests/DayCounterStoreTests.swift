import Combine
import Foundation
import Testing
import WooTodoStorage
@testable import WooTodoMacApp

@Suite("DayCounterStore 日期刷新", .serialized)
@MainActor
struct DayCounterStoreTests {
    @Test(
        "后台系统日期通知安全切回主线程",
        arguments: [
            Notification.Name.NSCalendarDayChanged,
            Notification.Name.NSSystemTimeZoneDidChange,
        ]
    )
    func backgroundDateNotificationRefreshesOnMainActor(
        notificationName: Notification.Name
    ) async throws {
        let suiteName = "DayCounterStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationCenter = NotificationCenter()
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let store = DayCounterStore(
            defaults: defaults,
            repository: repository,
            notificationCenter: notificationCenter
        )
        var cancellable: AnyCancellable?

        let refreshedOnMainThread = await withCheckedContinuation { continuation in
            cancellable = store.$renderDate
                .dropFirst()
                .prefix(1)
                .sink { _ in
                    continuation.resume(returning: Thread.isMainThread)
                }
            DispatchQueue.global(qos: .userInitiated).async {
                notificationCenter.post(name: notificationName, object: nil)
            }
        }

        #expect(refreshedOnMainThread)
        withExtendedLifetime(cancellable) {}
    }
}
