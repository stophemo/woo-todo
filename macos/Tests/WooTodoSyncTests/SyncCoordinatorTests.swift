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

    @Test("CURSOR_AHEAD 后重置本地游标并从头恢复同步")
    func testCursorAhead重置游标并恢复同步() async throws {
        let operation = makePushOperation(index: 1)
        let outbox = TestOutbox([operation])
        let local = TestLocal(cursor: 5)
        // 服务端状态丢失重建后 maxCursor 从 1 重新计数：客户端 cursor 5 超纲返回 409 CURSOR_AHEAD，
        // 协调器应重置本地 cursor 后从头重新同步（正常 push outbox + 从 0 拉取）。
        let transport = ScriptedTransport([
            .failure(.cursorAhead),
            .success(SyncData(
                push: SyncPushSummary(received: 1, inserted: 1, duplicates: 0),
                pull: [makePulledOperation(sequence: 1)],
                cursor: 1,
                hasMore: false,
                serverTime: 1
            )),
        ])
        let coordinator = SyncCoordinator(
            transport: transport,
            outbox: outbox,
            local: local,
            deviceToken: "token"
        )

        let summary = try await coordinator.synchronize()
        // 失败的 409 请求不计入完成页数，恢复后的第二轮实际完成 1 页。
        #expect(summary == SyncRunSummary(pushed: 1, pulled: 1, pages: 1, finalCursor: 1))
        #expect(await local.cursorValue() == 1)
        #expect(await local.resetCount == 1)
        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].cursor == 5)
        #expect(requests[1].cursor == 0)
        #expect(requests[1].push.map(\.opId) == [operation.opId])
        #expect(await outbox.remainingIds() == [])
    }

    @Test("非 CURSOR_AHEAD 的服务端错误照常抛出且不重置游标")
    func test非CursorAhead错误不重置游标() async throws {
        let local = TestLocal(cursor: 3)
        let transport = ScriptedTransport([
            .failure(.cursorAheadGeneric),
        ])
        let coordinator = SyncCoordinator(
            transport: transport,
            outbox: TestOutbox([]),
            local: local,
            deviceToken: "token"
        )

        do {
            _ = try await coordinator.synchronize()
            Issue.record("预期 409 非 CURSOR_AHEAD 错误抛出")
        } catch let error as SyncAPIError {
            guard case .server(let statusCode, let payload, _) = error else {
                Issue.record("预期结构化服务端错误")
                return
            }
            #expect(statusCode == 409)
            #expect(payload.code == "OP_ID_CONFLICT")
        }
        #expect(await local.cursorValue() == 3)
        #expect(await local.resetCount == 0)
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

private enum ScriptedFailure: Error, Sendable {
    case network
    case cursorAhead
    case cursorAheadGeneric
}

private actor ScriptedTransport: SyncTransport {
    private var script: [Result<SyncData, ScriptedFailure>]
    private var recorded: [SyncRequest] = []

    init(_ script: [Result<SyncData, ScriptedFailure>]) {
        self.script = script
    }

    func sync(_ request: SyncRequest, deviceToken: String) async throws -> SyncData {
        recorded.append(request)
        guard !script.isEmpty else { throw TestTransportError.noResponse }
        switch script.removeFirst() {
        case .success(let data):
            return data
        case .failure(.network):
            throw TestTransportError.network
        case .failure(.cursorAhead):
            throw SyncAPIError.server(
                statusCode: 409,
                payload: ServerErrorPayload(
                    code: "CURSOR_AHEAD",
                    message: "客户端游标超过服务端最新序号"
                ),
                requestId: nil
            )
        case .failure(.cursorAheadGeneric):
            throw SyncAPIError.server(
                statusCode: 409,
                payload: ServerErrorPayload(
                    code: "OP_ID_CONFLICT",
                    message: "opId 已存在且内容不同"
                ),
                requestId: nil
            )
        }
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
    private(set) var resetCount = 0

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

    func resetCursor() async throws {
        cursor = 0
        resetCount += 1
    }

    func cursorValue() -> Int64 { cursor }
}
