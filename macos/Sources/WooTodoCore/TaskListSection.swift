import Foundation

public enum TaskSectionKind: String, CaseIterable, Sendable {
    case overdue
    case today
    case upcoming
    case unscheduled
    case settledToday

    public var title: String {
        switch self {
        case .overdue: "已逾期"
        case .today: "今天"
        case .upcoming: "接下来"
        case .unscheduled: "未安排"
        case .settledToday: "今天完成"
        }
    }
}

public struct TaskListSection: Identifiable, Equatable, Sendable {
    public let kind: TaskSectionKind
    public let tasks: [TodoTask]

    public var id: TaskSectionKind { kind }

    public init(kind: TaskSectionKind, tasks: [TodoTask]) {
        self.kind = kind
        self.tasks = tasks
    }
}

public enum TaskListPresenter {
    public static func sections(
        tasks: [TodoTask],
        categories: [TaskCategory],
        on date: Date,
        calendar: Calendar = TodoTask.protocolCalendar
    ) -> [TaskListSection] {
        let categoryOrder = Dictionary(
            uniqueKeysWithValues: categories.map { ($0.id, $0.order) }
        )
        let pending = tasks.filter { $0.status == .pending }
        let overdue = pending.filter {
            TaskDateState.isOverdue($0, on: date, calendar: calendar)
        }
        let today = pending.filter {
            !TaskDateState.isOverdue($0, on: date, calendar: calendar) &&
                TaskDateState.isActive($0, on: date, calendar: calendar)
        }
        let upcoming = pending.filter { task in
            guard let start = task.startDate else { return false }
            return calendar.startOfDay(for: start) > calendar.startOfDay(for: date)
        }
        let unscheduled = pending.filter {
            $0.startDate == nil && $0.endDate == nil
        }
        let settledToday = tasks.filter {
            TaskDateState.isSettled($0, on: date, calendar: calendar)
        }

        func ordered(_ values: [TodoTask]) -> [TodoTask] {
            values.sorted { left, right in
                let leftOrder = categoryOrder[left.categoryID] ?? Int.max
                let rightOrder = categoryOrder[right.categoryID] ?? Int.max
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                let leftEnd = left.endDate ?? .distantFuture
                let rightEnd = right.endDate ?? .distantFuture
                if leftEnd != rightEnd { return leftEnd < rightEnd }
                if left.sortIndex != right.sortIndex {
                    return left.sortIndex < right.sortIndex
                }
                if left.createdAt != right.createdAt {
                    return left.createdAt < right.createdAt
                }
                return left.id.uuidString < right.id.uuidString
            }
        }

        var sections: [TaskListSection] = []
        func append(_ kind: TaskSectionKind, _ values: [TodoTask]) {
            if !values.isEmpty {
                sections.append(TaskListSection(kind: kind, tasks: ordered(values)))
            }
        }
        append(.overdue, overdue)
        append(.today, today)
        append(.upcoming, upcoming)
        append(.unscheduled, unscheduled)
        append(.settledToday, settledToday)
        return sections
    }
}
