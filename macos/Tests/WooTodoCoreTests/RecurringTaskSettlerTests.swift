import Foundation
import Testing
import WooTodoCore

@Suite("每天重复任务结算")
struct RecurringTaskSettlerTests {
    private let calendar = TodoTask.protocolCalendar
    private let now = RecurringTaskSettlerTests.day("2026-11-20", hour: 12)
    private let today = RecurringTaskSettlerTests.day("2026-11-20")

    @Test("未完成的每日任务记为放弃并生成今天的新任务")
    func missedTaskBecomesPassAndNextIsCreated() throws {
        let task = try makeTask(
            title: "铲屎",
            start: "2026-11-19",
            end: "2026-11-19",
            recurrence: .daily
        )
        let result = RecurringTaskSettler.settle(
            tasks: [task],
            today: today,
            now: now
        )

        #expect(result.updatedTasks.count == 1)
        #expect(result.createdTasks.count == 1)
        let missed = try #require(result.updatedTasks.first)
        #expect(missed.status == .pass)
        #expect(missed.completedAt == Self.day("2026-11-19"))
        let next = try #require(result.createdTasks.first)
        #expect(next.title == task.title)
        #expect(next.seriesID == task.seriesID)
        #expect(next.status == .pending)
        #expect(next.startDate == today)
        #expect(next.endDate == today)
        #expect(next.recurrence == .daily)
        #expect(next.id == RecurringTaskSettler.occurrenceID(
            seriesID: task.seriesID,
            startDate: today
        ))
    }

    @Test("连续漏做会逐日记录放弃并补齐到今天")
    func missedDaysAreRecorded() throws {
        let task = try makeTask(
            title: "铲屎",
            start: "2026-11-17",
            end: "2026-11-17",
            recurrence: .daily
        )
        let result = RecurringTaskSettler.settle(
            tasks: [task],
            today: today,
            now: now
        )

        #expect(result.updatedTasks.count == 1)
        #expect(result.createdTasks.count == 3)
        let settled = result.updatedTasks + result.createdTasks.filter { $0.status == .pass }
        #expect(settled.count == 3)
        #expect(settled.allSatisfy { $0.status == .pass })
        let pending = result.createdTasks.filter { $0.status == .pending }
        #expect(pending.count == 1)
        #expect(pending.first?.startDate == today)
    }

    @Test("已完成的上一条不会改写，但仍生成下一条")
    func completedTaskStillGeneratesNext() throws {
        var task = try makeTask(
            title: "铲屎",
            start: "2026-11-19",
            end: "2026-11-19",
            recurrence: .daily
        )
        task.status = .completed
        task.completedAt = Self.day("2026-11-19", hour: 9)
        task.updatedAt = Self.day("2026-11-19", hour: 9)

        let result = RecurringTaskSettler.settle(
            tasks: [task],
            today: today,
            now: now
        )
        #expect(result.updatedTasks.isEmpty)
        #expect(result.createdTasks.count == 1)
        #expect(result.createdTasks.first?.startDate == today)
    }

    @Test("重复结算保持幂等")
    func settlementIsIdempotent() throws {
        let task = try makeTask(
            title: "铲屎",
            start: "2026-11-19",
            end: "2026-11-19",
            recurrence: .daily
        )
        let first = RecurringTaskSettler.settle(
            tasks: [task],
            today: today,
            now: now
        )
        var settled = [task]
        for updated in first.updatedTasks {
            settled.removeAll { $0.id == updated.id }
            settled.append(updated)
        }
        settled.append(contentsOf: first.createdTasks)
        let second = RecurringTaskSettler.settle(
            tasks: settled,
            today: today,
            now: now
        )
        #expect(second.isEmpty)
    }

    @Test("删除下一条后序列停止，不会每天复活")
    func deletedOccurrenceStopsSeries() throws {
        let task = try makeTask(
            title: "铲屎",
            start: "2026-11-19",
            end: "2026-11-19",
            recurrence: .daily
        )
        let nextID = RecurringTaskSettler.occurrenceID(
            seriesID: task.seriesID,
            startDate: today
        )
        let result = RecurringTaskSettler.settle(
            tasks: [task],
            today: today,
            now: now,
            deletedTaskIDs: [nextID]
        )
        #expect(result.createdTasks.isEmpty)
    }

    @Test("一次性任务不参与重复结算")
    func onceTaskIsIgnored() throws {
        let task = try makeTask(
            title: "一次性",
            start: "2026-11-19",
            end: "2026-11-19",
            recurrence: .once
        )
        let result = RecurringTaskSettler.settle(
            tasks: [task],
            today: today,
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("occurrence id 与 Android 和旧周期任务保持一致")
    func occurrenceIDMatchesSharedAlgorithm() {
        let seriesID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
        #expect(
            RecurringTaskSettler.occurrenceID(
                seriesID: seriesID,
                startDate: Self.day("2026-11-20")
            ).uuidString.lowercased()
                == "ca7b0dc3-d6fa-57db-ad8f-568c71426692"
        )
    }

    @Test("每天重复必须设置日期")
    func dailyRequiresDates() {
        #expect(throws: TaskValidationError.invalidRecurrence) {
            try TodoTask(
                title: "没有日期",
                categoryID: TaskCategory.inboxID,
                recurrence: .daily
            )
        }
    }

    private func makeTask(
        title: String,
        start: String,
        end: String,
        recurrence: TaskRecurrence
    ) throws -> TodoTask {
        try TodoTask(
            title: title,
            categoryID: TaskCategory.inboxID,
            startDate: Self.day(start),
            endDate: Self.day(end),
            recurrence: recurrence
        )
    }

    private static func day(_ value: String, hour: Int = 0) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = TodoTask.protocolCalendar
        formatter.timeZone = TodoTask.protocolCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH"
        formatter.isLenient = false
        return formatter.date(from: "\(value) \(hour)")!
    }
}
