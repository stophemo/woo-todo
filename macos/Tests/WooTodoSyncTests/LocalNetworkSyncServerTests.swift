import Foundation
import Testing
@testable import WooTodoSync

@Suite("局域网同步主机")
struct LocalNetworkSyncServerTests {
    @Test("同步操作重复提交幂等且重启后仍可拉取")
    func operationReplayAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let credentials = try fixtureCredentials()
        let operation = SyncPushOperation(
            opId: "op-local-network-1",
            entityId: "task-local-network-1",
            kind: .upsert,
            lamport: 1,
            ciphertext: Base64URL.encode(Data(repeating: 7, count: 32)),
            nonce: Base64URL.encode(Data(repeating: 8, count: 12))
        )
        let body = try JSONEncoder().encode(
            SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [operation])
        )

        let firstStore = try LocalSyncServerStore(
            fileURL: stateURL,
            bootstrapCredentials: credentials,
            now: { 1_000 }
        )
        let first = await firstStore.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: body
        ))
        let firstData: SyncData = try successData(first)
        #expect(firstData.push.inserted == 1)
        #expect(firstData.pull.map(\.opId) == [operation.opId])
        #expect(firstData.cursor == 1)

        let replay = await firstStore.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: body
        ))
        let replayData: SyncData = try successData(replay)
        #expect(replayData.push.inserted == 0)
        #expect(replayData.push.duplicates == 1)
        #expect(replayData.cursor == 1)

        let restartedStore = try LocalSyncServerStore(
            fileURL: stateURL,
            bootstrapCredentials: credentials,
            now: { 2_000 }
        )
        let pulled = await restartedStore.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [])
            )
        ))
        let pulledData: SyncData = try successData(pulled)
        #expect(pulledData.pull.map(\.opId) == [operation.opId])
        #expect(pulledData.cursor == 1)
    }

    @Test("相同 opId 的不同内容被拒绝且原操作保持不变")
    func conflictingOperationReplay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try fixtureCredentials()
        let store = try LocalSyncServerStore(
            fileURL: directory.appendingPathComponent("state.json"),
            bootstrapCredentials: credentials
        )
        let original = SyncPushOperation(
            opId: "op-local-conflict",
            entityId: "task-local-conflict",
            kind: .upsert,
            lamport: 1,
            ciphertext: Base64URL.encode(Data(repeating: 3, count: 32)),
            nonce: Base64URL.encode(Data(repeating: 4, count: 12))
        )
        let changed = SyncPushOperation(
            opId: original.opId,
            entityId: original.entityId,
            kind: original.kind,
            lamport: original.lamport,
            ciphertext: Base64URL.encode(Data(repeating: 9, count: 32)),
            nonce: original.nonce
        )
        _ = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [original])
            )
        ))

        let conflict = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [changed])
            )
        ))
        #expect(conflict.statusCode == 409)
        let failure = try JSONDecoder().decode(FailureEnvelope.self, from: conflict.body)
        #expect(failure.error.code == "OP_ID_CONFLICT")

        let pulled = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [])
            )
        ))
        let data: SyncData = try successData(pulled)
        #expect(data.pull.count == 1)
        #expect(data.pull[0].ciphertext == original.ciphertext)
    }

    @Test("服务端状态只接受同一局域网身份重载")
    func persistedIdentityCannotBeRebound() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let credentials = try fixtureCredentials()
        _ = try LocalSyncServerStore(fileURL: stateURL, bootstrapCredentials: credentials)

        let mismatched = SyncCredentials(
            endpoint: credentials.endpoint,
            vaultId: credentials.vaultId,
            deviceId: "device-another-local",
            deviceToken: credentials.deviceToken,
            vaultKey: credentials.vaultKey
        )
        #expect(throws: LocalSyncServerError.identityMismatch) {
            _ = try LocalSyncServerStore(fileURL: stateURL, bootstrapCredentials: mismatched)
        }
    }

    @Test("超出 TCP 范围的端口会被拒绝而不是触发整数转换崩溃")
    func outOfRangePortIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-port-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = URL(string: "http://192.168.8.21:99999")!
        let credentials = SyncCredentials(
            endpoint: endpoint,
            vaultId: "vault-local-network",
            deviceId: "device-macos-local",
            deviceToken: Base64URL.encode(Data(repeating: 1, count: 32)),
            vaultKey: Data(repeating: 2, count: 32)
        )
        let store = try LocalSyncServerStore(
            fileURL: directory.appendingPathComponent("state.json"),
            bootstrapCredentials: credentials
        )

        #expect(throws: LocalSyncServerError.cannotResolveEndpoint) {
            _ = try LocalNetworkSyncHTTPServer(store: store, endpoint: endpoint)
        }
    }

    @Test("新设备完成配对后可同步且撤销后令牌立即失效")
    func pairedDeviceCanSyncUntilRevoked() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-pairing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = try fixtureCredentials()
        let remoteOperations = RemoteOperationsRecorder()
        let store = try LocalSyncServerStore(
            fileURL: directory.appendingPathComponent("state.json"),
            bootstrapCredentials: credentials,
            now: { 10_000 },
            onRemoteOperationsStored: { deviceId, inserted in
                remoteOperations.record(deviceId: deviceId, inserted: inserted)
            }
        )
        let initiatorPublicKey = Base64URL.encode(Data(repeating: 3, count: 32))
        let createdResponse = await store.handle(request(
            path: "/v1/pairings",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                CreatePairingRequest(publicKey: initiatorPublicKey)
            )
        ))
        let created: CreatePairingData = try successData(createdResponse)

        let deviceToken = Base64URL.encode(Data(repeating: 4, count: 32))
        let devicePublicKey = Base64URL.encode(Data(repeating: 5, count: 32))
        let claimResponse = await store.handle(request(
            path: "/v1/pairings/\(created.pairingId)/claim",
            body: try JSONEncoder().encode(PairingClaimRequest(
                pairingSecret: created.pairingSecret,
                deviceToken: deviceToken,
                device: PairingDeviceRegistration(
                    name: "Android 测试设备",
                    platform: .android,
                    publicKey: devicePublicKey
                )
            ))
        ))
        let claim: PairingClaimData = try successData(claimResponse)
        #expect(claim.status == .claimed)

        let envelope = EncryptedEnvelope(
            ciphertext: Base64URL.encode(Data(repeating: 6, count: 32)),
            nonce: Base64URL.encode(Data(repeating: 7, count: 12))
        )
        let confirmResponse = await store.handle(request(
            path: "/v1/pairings/\(created.pairingId)/confirm",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                PairingConfirmRequest(vaultKeyEnvelope: envelope)
            )
        ))
        let confirmed: PairingConfirmData = try successData(confirmResponse)
        #expect(confirmed.deviceId == claim.deviceId)
        #expect(confirmed.status == .confirmed)

        let resultResponse = await store.handle(request(
            path: "/v1/pairings/\(created.pairingId)/result",
            body: try JSONEncoder().encode(PairingResultRequest(
                pairingSecret: created.pairingSecret,
                deviceToken: deviceToken
            ))
        ))
        let result: PairingResultData = try successData(resultResponse)
        #expect(result.vaultId == credentials.vaultId)
        #expect(result.deviceId == claim.deviceId)
        #expect(result.vaultKeyEnvelope == envelope)

        let operation = SyncPushOperation(
            opId: "op-android-remote-change",
            entityId: "task-android-remote-change",
            kind: .upsert,
            lamport: 1,
            ciphertext: Base64URL.encode(Data(repeating: 8, count: 32)),
            nonce: Base64URL.encode(Data(repeating: 9, count: 12))
        )
        let syncBody = try JSONEncoder().encode(
            SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [operation])
        )
        let beforeRevocation = await store.handle(request(
            path: "/v1/sync",
            token: deviceToken,
            body: syncBody
        ))
        #expect(beforeRevocation.statusCode == 200)
        #expect(remoteOperations.events == [
            RemoteOperationsRecorder.Event(deviceId: claim.deviceId, inserted: 1)
        ])

        let replay = await store.handle(request(
            path: "/v1/sync",
            token: deviceToken,
            body: syncBody
        ))
        #expect(replay.statusCode == 200)
        #expect(remoteOperations.events == [
            RemoteOperationsRecorder.Event(deviceId: claim.deviceId, inserted: 1)
        ])

        let deleteOperation = SyncPushOperation(
            opId: "op-android-remote-delete",
            entityId: operation.entityId,
            kind: .delete,
            lamport: 2,
            ciphertext: Base64URL.encode(Data(repeating: 12, count: 32)),
            nonce: Base64URL.encode(Data(repeating: 13, count: 12))
        )
        let remoteDelete = await store.handle(request(
            path: "/v1/sync",
            token: deviceToken,
            body: try JSONEncoder().encode(
                SyncRequest(cursor: 1, ack: 1, pullLimit: 100, push: [deleteOperation])
            )
        ))
        #expect(remoteDelete.statusCode == 200)
        #expect(remoteOperations.events == [
            RemoteOperationsRecorder.Event(deviceId: claim.deviceId, inserted: 1),
            RemoteOperationsRecorder.Event(deviceId: claim.deviceId, inserted: 1)
        ])

        let hostOperation = SyncPushOperation(
            opId: "op-macos-local-change",
            entityId: "task-macos-local-change",
            kind: .upsert,
            lamport: 3,
            ciphertext: Base64URL.encode(Data(repeating: 10, count: 32)),
            nonce: Base64URL.encode(Data(repeating: 11, count: 12))
        )
        let hostSync = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [hostOperation])
            )
        ))
        #expect(hostSync.statusCode == 200)
        #expect(remoteOperations.events == [
            RemoteOperationsRecorder.Event(deviceId: claim.deviceId, inserted: 1),
            RemoteOperationsRecorder.Event(deviceId: claim.deviceId, inserted: 1)
        ])

        let revokeResponse = await store.handle(request(
            path: "/v1/devices/\(claim.deviceId)/revoke",
            token: credentials.deviceToken
        ))
        #expect(revokeResponse.statusCode == 200)

        let afterRevocation = await store.handle(request(
            path: "/v1/sync",
            token: deviceToken,
            body: syncBody
        ))
        #expect(afterRevocation.statusCode == 401)
    }

    @Test("ack 驱动裁剪：全部确认后旧操作被裁剪且序号不重置")
    func confirmedOperationsAreTrimmedAndSequenceKeepsCounting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-trim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let credentials = try fixtureCredentials()
        let store = try LocalSyncServerStore(
            fileURL: stateURL,
            bootstrapCredentials: credentials,
            now: { 1_000 }
        )

        func push(_ opId: String, ack: Int64, cursor: Int64) async throws -> SyncData {
            let response = await store.handle(request(
                path: "/v1/sync",
                token: credentials.deviceToken,
                body: try JSONEncoder().encode(SyncRequest(
                    cursor: cursor,
                    ack: ack,
                    pullLimit: 100,
                    push: [makeOperation(opId: opId)]
                ))
            ))
            return try successData(response)
        }

        // 第一轮：插入 op-trim-1（seq 1），ack 0 → 不被裁剪。
        var data = try await push("op-trim-1", ack: 0, cursor: 0)
        #expect(data.push.inserted == 1)
        #expect(data.cursor == 1)
        // 第二轮：ack 1 确认 seq 1 → 触发裁剪，随后插入 op-trim-2（seq 2）。
        data = try await push("op-trim-2", ack: 1, cursor: 1)
        #expect(data.push.inserted == 1)
        #expect(data.cursor == 2)
        // 第三轮：ack 2 确认 seq 1-2 → 全部裁剪。
        data = try await push("op-trim-3", ack: 2, cursor: 2)
        #expect(data.push.inserted == 1)
        #expect(data.cursor == 3)

        // 从 0 重新拉取：只应看到未被裁剪的 op-trim-3（seq 3），旧操作已移除。
        let pulled = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [])
            )
        ))
        let pulledData: SyncData = try successData(pulled)
        #expect(pulledData.pull.map(\.opId) == ["op-trim-3"])
        #expect(pulledData.cursor == 3)
    }

    @Test("重复 push 已确认 opId 被跳过且不会重新计数")
    func repushConfirmedOperationIsSkipped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-repush-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let credentials = try fixtureCredentials()
        let store = try LocalSyncServerStore(
            fileURL: stateURL,
            bootstrapCredentials: credentials,
            now: { 1_000 }
        )
        let operation = makeOperation(opId: "op-repush-1")

        _ = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 0, ack: 0, pullLimit: 100, push: [operation]
            ))
        ))
        // 确认 seq 1 → 裁剪并进入 confirmedOperationIds。
        _ = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 1, ack: 1, pullLimit: 100, push: []
            ))
        ))

        // 重复 push 已确认 opId：应计为重复而非重新插入（否则 seq 会重新计数）。
        let repush = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 1, ack: 1, pullLimit: 100, push: [operation]
            ))
        ))
        let repushData: SyncData = try successData(repush)
        #expect(repushData.push.inserted == 0)
        #expect(repushData.push.duplicates == 1)
        #expect(repushData.cursor == 1)

        // 新操作应从 seq 2 继续编号，且从 0 拉取看不到已确认的 op-repush-1。
        let second = makeOperation(opId: "op-repush-2")
        let secondResponse = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 1, ack: 1, pullLimit: 100, push: [second]
            ))
        ))
        let secondData: SyncData = try successData(secondResponse)
        #expect(secondData.pull.map(\.opId) == ["op-repush-2"])
        #expect(secondData.pull.first?.serverSeq == 2)
    }

    @Test("多设备时低水位设备未确认的操作不被裁剪")
    func unconfirmedOperationsOfLaggingDeviceAreRetained() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-multidevice-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let credentials = try fixtureCredentials()
        let store = try LocalSyncServerStore(
            fileURL: stateURL,
            bootstrapCredentials: credentials,
            now: { 10_000 }
        )

        // 配对一台新设备（低水位设备）。
        let createdResponse = await store.handle(request(
            path: "/v1/pairings",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(
                CreatePairingRequest(publicKey: Base64URL.encode(Data(repeating: 3, count: 32)))
            )
        ))
        let created: CreatePairingData = try successData(createdResponse)
        let androidToken = Base64URL.encode(Data(repeating: 4, count: 32))
        _ = await store.handle(request(
            path: "/v1/pairings/\(created.pairingId)/claim",
            body: try JSONEncoder().encode(PairingClaimRequest(
                pairingSecret: created.pairingSecret,
                deviceToken: androidToken,
                device: PairingDeviceRegistration(
                    name: "低水位设备",
                    platform: .android,
                    publicKey: Base64URL.encode(Data(repeating: 5, count: 32))
                )
            ))
        ))
        _ = await store.handle(request(
            path: "/v1/pairings/\(created.pairingId)/confirm",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(PairingConfirmRequest(
                vaultKeyEnvelope: EncryptedEnvelope(
                    ciphertext: Base64URL.encode(Data(repeating: 6, count: 32)),
                    nonce: Base64URL.encode(Data(repeating: 7, count: 12))
                )
            ))
        ))

        // 主机插入 op-host-1（seq 1）并确认到 seq 1；Android 尚未确认任何序号。
        let hostSync = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 0, ack: 0, pullLimit: 100,
                push: [makeOperation(opId: "op-host-1")]
            ))
        ))
        let hostData: SyncData = try successData(hostSync)
        #expect(hostData.pull.map(\.opId) == ["op-host-1"])
        _ = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 1, ack: 1, pullLimit: 100, push: []
            ))
        ))

        // 低水位设备未确认 → 主机已确认的 op-host-1 仍可被低水位设备从 0 拉取。
        let laggingPull = await store.handle(request(
            path: "/v1/sync",
            token: androidToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 0, ack: 0, pullLimit: 100, push: []
            ))
        ))
        let laggingData: SyncData = try successData(laggingPull)
        #expect(laggingData.pull.map(\.opId) == ["op-host-1"])

        // Android 确认到 seq 1 后，低水位消失 → 操作被裁剪，从 0 拉取不再返回。
        _ = await store.handle(request(
            path: "/v1/sync",
            token: androidToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 1, ack: 1, pullLimit: 100, push: []
            ))
        ))
        let afterAllAcked = await store.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 0, ack: 0, pullLimit: 100, push: []
            ))
        ))
        let afterData: SyncData = try successData(afterAllAcked)
        #expect(afterData.pull.isEmpty)
        #expect(afterData.cursor == 0)
    }

    @Test("旧格式状态文件（无 ackCursor/confirmedOperationIds）可加载并继续同步")
    func legacyStateFileWithoutAckFieldsLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-todo-lan-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("state.json")
        let credentials = try fixtureCredentials()

        // 先写入新格式状态，再剥离新字段模拟旧版本文件。
        let writer = try LocalSyncServerStore(
            fileURL: stateURL,
            bootstrapCredentials: credentials,
            now: { 1_000 }
        )
        _ = await writer.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 0, ack: 0, pullLimit: 100,
                push: [makeOperation(opId: "op-legacy-1")]
            ))
        ))
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        object.removeValue(forKey: "confirmedOperationIds")
        object.removeValue(forKey: "maxLamportEver")
        if var devices = object["devices"] as? [[String: Any]] {
            for index in devices.indices {
                devices[index].removeValue(forKey: "ackCursor")
            }
            object["devices"] = devices
        }
        try JSONSerialization.data(withJSONObject: object).write(to: stateURL, options: .atomic)

        let legacyStore = try LocalSyncServerStore(
            fileURL: stateURL,
            bootstrapCredentials: credentials,
            now: { 2_000 }
        )
        // 旧文件加载后仍可同步：从 0 拉取到旧操作，并可用 ack 触发裁剪。
        let pulled = await legacyStore.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 0, ack: 0, pullLimit: 100, push: []
            ))
        ))
        let pulledData: SyncData = try successData(pulled)
        #expect(pulledData.pull.map(\.opId) == ["op-legacy-1"])

        let confirm = await legacyStore.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 1, ack: 1, pullLimit: 100, push: []
            ))
        ))
        let confirmData: SyncData = try successData(confirm)
        #expect(confirmData.cursor == 1)
        let trimmed = await legacyStore.handle(request(
            path: "/v1/sync",
            token: credentials.deviceToken,
            body: try JSONEncoder().encode(SyncRequest(
                cursor: 0, ack: 0, pullLimit: 100, push: []
            ))
        ))
        let trimmedData: SyncData = try successData(trimmed)
        #expect(trimmedData.pull.isEmpty)
        #expect(trimmedData.cursor == 0)
    }

    private func makeOperation(opId: String) -> SyncPushOperation {
        SyncPushOperation(
            opId: opId,
            entityId: "task-\(opId)",
            kind: .upsert,
            lamport: 1,
            ciphertext: Base64URL.encode(Data(repeating: 7, count: 32)),
            nonce: Base64URL.encode(Data(repeating: 8, count: 12))
        )
    }

    private func fixtureCredentials() throws -> SyncCredentials {
        let credentials = SyncCredentials(
            endpoint: URL(string: "http://192.168.8.21:48473")!,
            vaultId: "vault-local-network",
            deviceId: "device-macos-local",
            deviceToken: Base64URL.encode(Data(repeating: 1, count: 32)),
            vaultKey: Data(repeating: 2, count: 32)
        )
        try credentials.validate()
        return credentials
    }

    private func request(
        path: String,
        token: String? = nil,
        body: Data = Data()
    ) -> LocalSyncHTTPRequest {
        LocalSyncHTTPRequest(
            method: "POST",
            path: path,
            headers: token.map { ["Authorization": "Bearer \($0)"] } ?? [:],
            body: body
        )
    }

    private func successData<Value: Decodable>(_ response: LocalSyncHTTPResponse) throws -> Value {
        #expect((200..<300).contains(response.statusCode))
        return try JSONDecoder().decode(SuccessEnvelope<Value>.self, from: response.body).data
    }
}

private struct SuccessEnvelope<Value: Decodable>: Decodable {
    let data: Value
}

private struct FailureEnvelope: Decodable {
    let error: ServerErrorPayload
}

private final class RemoteOperationsRecorder: @unchecked Sendable {
    struct Event: Equatable {
        let deviceId: String
        let inserted: Int
    }

    private let lock = NSLock()
    private var storedEvents: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func record(deviceId: String, inserted: Int) {
        lock.lock()
        storedEvents.append(Event(deviceId: deviceId, inserted: inserted))
        lock.unlock()
    }
}
