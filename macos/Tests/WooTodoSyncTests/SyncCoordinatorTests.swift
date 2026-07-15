import Foundation
import Testing
@testable import WooTodoSync

@Suite("同步协调器")
struct SyncCoordinatorTests {
    @Test("分页成功后才确认 outbox 并推进 cursor")
    func test分页成功后才确认Outbox并推进Cursor() async throws {
        let operation = makePushOperation(index: 1)
        let outbox = TestOutbox([operation])
        let local = TestLocal(cursor: 0)
        let transport = ScriptedTransport([
            .success(SyncData(
                push: SyncPushSummary(received: 1, inserted: 1, duplicates: 0),
                pull: [makePulledOperation(sequence: 1)],
                cursor: 1,
                hasMore: true,
                serverTime: 1
            )),
            .success(SyncData(
                push: SyncPushSummary(received: 0, inserted: 0, duplicates: 0),
                pull: [makePulledOperation(sequence: 2)],
                cursor: 2,
                hasMore: false,
                serverTime: 2
            )),
        ])
        let coordinator = SyncCoordinator(
            transport: transport,
            outbox: outbox,
            local: local,
            deviceToken: "token"
        )

        let summary = try await coordinator.synchronize()
        #expect(summary == SyncRunSummary(pushed: 1, pulled: 2, pages: 2, finalCursor: 2))
        let remaining = await outbox.remainingIds()
        let acknowledgements = await outbox.acknowledgements()
        let cursor = await local.cursorValue()
        #expect(remaining == [])
        #expect(acknowledgements == [[operation.opId]])
        #expect(cursor == 2)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].push.map(\.opId) == [operation.opId])
        #expect(requests[1].push == [])
        #expect(requests[1].cursor == 1)
    }

    @Test("分页中途失败不会删除 outbox")
    func test分页中途失败不会删除Outbox() async throws {
        let operation = makePushOperation(index: 1)
        let outbox = TestOutbox([operation])
        let local = TestLocal(cursor: 0)
        let transport = ScriptedTransport([
            .success(SyncData(
                push: SyncPushSummary(received: 1, inserted: 1, duplicates: 0),
                pull: [makePulledOperation(sequence: 1)],
                cursor: 1,
                hasMore: true,
                serverTime: 1
            )),
            .failure(.network),
        ])
        let coordinator = SyncCoordinator(
            transport: transport,
            outbox: outbox,
            local: local,
            deviceToken: "token"
        )

        do {
            _ = try await coordinator.synchronize()
            Issue.record("预期第二页失败")
        } catch TestTransportError.network {
            // 预期错误。
        }
        let remaining = await outbox.remainingIds()
        let acknowledgements = await outbox.acknowledgements()
        let cursor = await local.cursorValue()
        #expect(remaining == [operation.opId])
        #expect(acknowledgements == [])
        #expect(cursor == 1)
    }

    @Test("超过五十条 outbox 会分批推送")
    func test超过五十条Outbox会分批推送() async throws {
        let operations = (0..<51).map(makePushOperation)
        let outbox = TestOutbox(operations)
        let local = TestLocal(cursor: 0)
        let transport = ScriptedTransport([
            .success(SyncData(
                push: SyncPushSummary(received: 50, inserted: 50, duplicates: 0),
                pull: [], cursor: 0, hasMore: false, serverTime: 1
            )),
            .success(SyncData(
                push: SyncPushSummary(received: 1, inserted: 1, duplicates: 0),
                pull: [], cursor: 0, hasMore: false, serverTime: 2
            )),
        ])
        let coordinator = SyncCoordinator(
            transport: transport,
            outbox: outbox,
            local: local,
            deviceToken: "token"
        )

        let summary = try await coordinator.synchronize()
        #expect(summary.pushed == 51)
        #expect(summary.pages == 2)
        let requests = await transport.requests()
        #expect(requests.map { $0.push.count } == [50, 1])
        let remaining = await outbox.remainingIds()
        #expect(remaining == [])
    }

    private func makePushOperation(index: Int) -> SyncPushOperation {
        SyncPushOperation(
            opId: "op-\(index)",
            entityId: "task-\(index)",
            kind: .upsert,
            lamport: Int64(index + 1),
            ciphertext: Base64URL.encode(Data(repeating: UInt8(index % 255), count: 16)),
            nonce: Base64URL.encode(Data(repeating: UInt8((index + 1) % 255), count: 12))
        )
    }

    private func makePulledOperation(sequence: Int64) -> SyncPulledOperation {
        SyncPulledOperation(
            serverSeq: sequence,
            opId: "remote-\(sequence)",
            deviceId: "device-remote",
            entityId: "task-remote-\(sequence)",
            kind: .upsert,
            lamport: sequence,
            ciphertext: Base64URL.encode(Data(repeating: 8, count: 16)),
            nonce: Base64URL.encode(Data(repeating: 9, count: 12)),
            createdAt: sequence
        )
    }
}

private enum TestTransportError: Error, Sendable {
    case network
    case noResponse
}

private actor ScriptedTransport: SyncTransport {
    private var script: [Result<SyncData, TestTransportError>]
    private var recorded: [SyncRequest] = []

    init(_ script: [Result<SyncData, TestTransportError>]) {
        self.script = script
    }

    func sync(_ request: SyncRequest, deviceToken: String) async throws -> SyncData {
        recorded.append(request)
        guard !script.isEmpty else { throw TestTransportError.noResponse }
        return try script.removeFirst().get()
    }

    func requests() -> [SyncRequest] { recorded }
}

private actor TestOutbox: SyncOutbox {
    private var operations: [SyncPushOperation]
    private var acknowledged: [[String]] = []

    init(_ operations: [SyncPushOperation]) {
        self.operations = operations
    }

    func pendingOperations(limit: Int) async throws -> [SyncPushOperation] {
        Array(operations.prefix(limit))
    }

    func acknowledgeOperations(opIds: [String]) async throws {
        acknowledged.append(opIds)
        let ids = Set(opIds)
        operations.removeAll { ids.contains($0.opId) }
    }

    func remainingIds() -> [String] { operations.map(\.opId) }
    func acknowledgements() -> [[String]] { acknowledged }
}

private actor TestLocal: SyncLocalApplying {
    private var cursor: Int64

    init(cursor: Int64) {
        self.cursor = cursor
    }

    func currentCursor() async throws -> Int64 { cursor }

    func applyRemoteOperations(
        _ operations: [SyncPulledOperation],
        advancingCursorTo cursor: Int64
    ) async throws {
        self.cursor = cursor
    }

    func cursorValue() -> Int64 { cursor }
}
