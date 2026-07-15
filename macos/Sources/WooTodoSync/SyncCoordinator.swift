import Foundation

public protocol SyncOutbox: Sendable {
    /// 必须稳定返回最早的未确认操作；确认前重复读取应返回相同 opId。
    func pendingOperations(limit: Int) async throws -> [SyncPushOperation]

    /// 仅在服务端成功接收且全部分页落地后调用，实现方应原子删除这些操作。
    func acknowledgeOperations(opIds: [String]) async throws
}

public protocol SyncLocalApplying: Sendable {
    func currentCursor() async throws -> Int64

    /// 实现方必须在同一事务内幂等应用操作并保存 cursor。
    func applyRemoteOperations(
        _ operations: [SyncPulledOperation],
        advancingCursorTo cursor: Int64
    ) async throws
}

public struct SyncRunSummary: Equatable, Sendable {
    public let pushed: Int
    public let pulled: Int
    public let pages: Int
    public let finalCursor: Int64

    public init(pushed: Int, pulled: Int, pages: Int, finalCursor: Int64) {
        self.pushed = pushed
        self.pulled = pulled
        self.pages = pages
        self.finalCursor = finalCursor
    }
}

public enum SyncCoordinatorError: Error, Equatable, LocalizedError {
    case invalidPushSummary
    case cursorRegressed(previous: Int64, received: Int64)
    case cursorDidNotAdvance(Int64)
    case invalidPulledSequence
    case pageLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidPushSummary: "服务端返回的 push 计数不一致"
        case .cursorRegressed(let previous, let received):
            "服务端 cursor 从 \(previous) 回退到 \(received)"
        case .cursorDidNotAdvance(let cursor):
            "服务端声明仍有分页，但 cursor \(cursor) 未前进"
        case .invalidPulledSequence: "服务端 pull 序号未严格递增或超出 cursor"
        case .pageLimitExceeded: "单次同步分页超过安全上限"
        }
    }
}

public actor SyncCoordinator {
    public static let maximumPushBatch = 50
    public static let maximumPullBatch = 100
    public static let maximumPagesPerRun = 1_000

    private let transport: any SyncTransport
    private let outbox: any SyncOutbox
    private let local: any SyncLocalApplying
    private let deviceToken: String

    public init(
        transport: any SyncTransport,
        outbox: any SyncOutbox,
        local: any SyncLocalApplying,
        deviceToken: String
    ) {
        self.transport = transport
        self.outbox = outbox
        self.local = local
        self.deviceToken = deviceToken
    }

    public func synchronize() async throws -> SyncRunSummary {
        var cursor = try await local.currentCursor()
        var pushed = 0
        var pulled = 0
        var pages = 0
        var performedEmptyPush = false

        while true {
            let pending = try await outbox.pendingOperations(limit: Self.maximumPushBatch)
            if pending.isEmpty && performedEmptyPush { break }
            let opIds = pending.map(\.opId)
            var outgoing = pending
            var batchPages = 0

            repeat {
                guard pages < Self.maximumPagesPerRun else {
                    throw SyncCoordinatorError.pageLimitExceeded
                }
                let previousCursor = cursor
                let response = try await transport.sync(
                    SyncRequest(
                        cursor: cursor,
                        ack: cursor,
                        pullLimit: Self.maximumPullBatch,
                        push: outgoing
                    ),
                    deviceToken: deviceToken
                )
                pages += 1
                batchPages += 1

                guard response.push.received == outgoing.count,
                      response.push.inserted + response.push.duplicates == response.push.received else {
                    throw SyncCoordinatorError.invalidPushSummary
                }
                guard response.cursor >= previousCursor else {
                    throw SyncCoordinatorError.cursorRegressed(
                        previous: previousCursor,
                        received: response.cursor
                    )
                }
                try validatePull(response.pull, previousCursor: previousCursor, cursor: response.cursor)
                try await local.applyRemoteOperations(
                    response.pull,
                    advancingCursorTo: response.cursor
                )
                pulled += response.pull.count
                cursor = response.cursor

                if response.hasMore && cursor == previousCursor {
                    throw SyncCoordinatorError.cursorDidNotAdvance(cursor)
                }
                outgoing = []
                if !response.hasMore { break }
            } while true

            if !opIds.isEmpty {
                try await outbox.acknowledgeOperations(opIds: opIds)
                pushed += opIds.count
            } else {
                performedEmptyPush = true
            }

            if pending.count < Self.maximumPushBatch {
                // 当前 outbox 已抽空；本批分页也已拉到服务端尾部。
                if pending.isEmpty || batchPages > 0 { break }
            }
        }

        return SyncRunSummary(
            pushed: pushed,
            pulled: pulled,
            pages: pages,
            finalCursor: cursor
        )
    }

    private func validatePull(
        _ operations: [SyncPulledOperation],
        previousCursor: Int64,
        cursor: Int64
    ) throws {
        var sequence = previousCursor
        for operation in operations {
            guard operation.serverSeq > sequence, operation.serverSeq <= cursor else {
                throw SyncCoordinatorError.invalidPulledSequence
            }
            sequence = operation.serverSeq
        }
        if let last = operations.last, last.serverSeq != cursor {
            throw SyncCoordinatorError.invalidPulledSequence
        }
        if operations.isEmpty && cursor != previousCursor {
            throw SyncCoordinatorError.invalidPulledSequence
        }
    }
}
