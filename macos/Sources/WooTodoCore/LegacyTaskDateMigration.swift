import Foundation

/// v0.2.18 之前任务必须同时填写开始和结束日期，旧客户端/Agent 常把“某天要做的事”
/// 写成前一天到当天的一天区间。升级后统一折算成“任务日期 = 区间最后一天”，
/// 只执行一次；之后用户主动创建的两天任务不会再次被折叠。
public enum LegacyTaskDateMigration {
    public static let defaultsKey = "migration.legacy-task-dates.v1"
    /// v0.2.18 发布时间；此前创建的任务才使用旧的“必须两段日期”语义。
    public static let legacyCutoff = Date(timeIntervalSince1970: 1_795_355_665)

    public static func plan(
        tasks: [TodoTask],
        calendar: Calendar = TodoTask.protocolCalendar
    ) -> [TodoTask] {
        tasks.compactMap { task in
            guard task.status == .pending,
                  task.recurrence == .once,
                  task.createdAt < legacyCutoff,
                  let start = task.startDate,
                  let end = task.endDate else { return nil }
            let startDay = calendar.startOfDay(for: start)
            let endDay = calendar.startOfDay(for: end)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startDay),
                  calendar.isDate(nextDay, inSameDayAs: endDay) else { return nil }
            var migrated = task
            migrated.startDate = endDay
            migrated.endDate = endDay
            return migrated
        }
    }

    /// 返回迁移了多少条任务；已经执行过时直接返回 0。
    @discardableResult
    public static func run(
        repository: TaskRepository,
        defaults: UserDefaults,
        now: Date = Date()
    ) throws -> Int {
        guard !defaults.bool(forKey: defaultsKey) else { return 0 }
        let migrated = plan(tasks: try repository.fetchAll()).map { task in
            var updated = task
            updated.updatedAt = now
            return updated
        }
        if !migrated.isEmpty {
            try repository.save(migrated)
        }
        defaults.set(true, forKey: defaultsKey)
        return migrated.count
    }
}
