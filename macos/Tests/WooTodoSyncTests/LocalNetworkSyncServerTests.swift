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
        let store = try LocalSyncServerStore(
            fileURL: directory.appendingPathComponent("state.json"),
            bootstrapCredentials: credentials,
            now: { 10_000 }
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

        let syncBody = try JSONEncoder().encode(
            SyncRequest(cursor: 0, ack: 0, pullLimit: 100, push: [])
        )
        let beforeRevocation = await store.handle(request(
            path: "/v1/sync",
            token: deviceToken,
            body: syncBody
        ))
        #expect(beforeRevocation.statusCode == 200)

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
