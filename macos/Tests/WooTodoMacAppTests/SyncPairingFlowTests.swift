import Foundation
import Testing
import WooTodoCore
import WooTodoStorage
import WooTodoSync
@testable import WooTodoMacApp

@Suite("跨设备配对流程", .serialized)
@MainActor
struct SyncPairingFlowTests {
    // MARK: - Path A 认领校验

    @Test("Path A 认领结果的 deviceId/vaultId/initiatorPublicKey 不一致时拒绝保存")
    func shortCodeClaimRejectsMismatchedResult() async throws {
        let initiator = try PairingKeyPair.generate()
        let otherInitiator = try PairingKeyPair.generate()
        let scenarios: [(name: String, deviceId: String, vaultId: String, initiatorPublicKey: String)] = [
            ("deviceId", "device-other", "vault-resolved", initiator.publicKeyBase64URL),
            ("vaultId", "device-claim", "vault-other", initiator.publicKeyBase64URL),
            ("initiatorPublicKey", "device-claim", "vault-resolved", otherInitiator.publicKeyBase64URL),
        ]
        defer { SyncStoreURLProtocol.handler = nil }

        for scenario in scenarios {
            let (suite, defaults) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let repository = try SQLiteTaskRepository(path: ":memory:")
            let credentialsStore = PairingTestCredentialsStore()
            SyncStoreURLProtocol.handler = { request in
                let path = request.url?.path ?? ""
                let now = nowMilliseconds()
                switch path {
                case "/v1/pairings/resolve":
                    return (200, try successJSON([
                        "pairingId": "pairing-1",
                        "pairingSecret": Base64URL.encode(Data(repeating: 3, count: 32)),
                        "initiatorPublicKey": initiator.publicKeyBase64URL,
                        "vaultId": "vault-resolved",
                        "expiresAt": now + 300_000,
                        "serverTime": now,
                    ]))
                case "/v1/pairings/pairing-1/claim":
                    return (200, try successJSON([
                        "pairingId": "pairing-1",
                        "status": "claimed",
                        "deviceId": "device-claim",
                        "expiresAt": now + 300_000,
                    ]))
                case "/v1/pairings/pairing-1/result":
                    return (200, try successJSON([
                        "pairingId": "pairing-1",
                        "status": "confirmed",
                        "vaultId": scenario.vaultId,
                        "deviceId": scenario.deviceId,
                        "initiatorPublicKey": scenario.initiatorPublicKey,
                        "vaultKeyEnvelope": ["ciphertext": "AAAA", "nonce": "BBBB"],
                        "expiresAt": now + 300_000,
                    ]))
                default:
                    throw TestFailure.unexpectedRequest(path)
                }
            }
            let store = try makeStore(
                credentials: nil,
                credentialsStore: credentialsStore,
                repository: repository,
                defaults: defaults
            )
            store.claimByShortCode("123456")
            try await waitUntil {
                if case .failed = store.shortCodeClaimPhase { return true }
                return false
            }
            guard case let .failed(message) = store.shortCodeClaimPhase else {
                Issue.record("\(scenario.name) 不一致时认领应失败")
                continue
            }
            #expect(message.contains("不一致"), "\(scenario.name) 不一致应给出明确错误")
            #expect(store.connection == nil)
            #expect(try credentialsStore.load() == nil)
        }
    }

    @Test("未配对入口不会覆盖已存在的合法同步身份")
    func unpairedFlowDoesNotOverwriteExistingIdentity() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let credentials = try makeCredentials()
        try credentialsStore.save(credentials)
        SyncStoreURLProtocol.handler = { request in
            throw TestFailure.unexpectedRequest(request.url?.path ?? "")
        }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        #expect(store.connection == nil)

        await store.createVault(inviteCode: String(repeating: "a", count: 16))

        #expect(store.connection == nil)
        #expect(store.actionErrorMessage?.contains("本机已有同步身份") == true)
        #expect(try credentialsStore.load() == credentials)
    }

    // MARK: - Path A 时钟偏移

    @Test("Path A 本地时钟比服务器快 10 分钟仍能完成配对")
    func shortCodeClaimToleratesFastLocalClock() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let server = try ShortCodeClaimTestServer(failResult: false)
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }

        store.claimByShortCode("123456")
        try await waitUntil {
            if case .confirmed = store.shortCodeClaimPhase { return true }
            return false
        }

        #expect(store.connection?.vaultId == "vault-claim")
        let saved = try #require(try credentialsStore.load())
        #expect(saved.deviceId == "device-claim")
        #expect(saved.vaultKey == server.expectedVaultKey)
        // 成功保存后不得撤销本次设备。
        #expect(server.revokeAttempts == 0)
    }

    @Test("Path A claim 成功后轮询失败会撤销临时设备")
    func shortCodeClaimFailureRevokesClaimedDevice() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let server = try ShortCodeClaimTestServer(failResult: true, revokeStatus: 401)
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }

        store.claimByShortCode("123456")
        try await waitUntil {
            if case .failed = store.shortCodeClaimPhase { return true }
            return false
        }

        #expect(store.connection == nil)
        #expect(try credentialsStore.load() == nil)
        let claimToken = try #require(server.claimedDeviceToken)
        #expect(server.revokeTokens == ["Bearer \(claimToken)"])
    }

    // MARK: - Path B 创建方

    @Test("Path B 创建方 approved 先到：显示核对码，确认后才解封保存")
    func joinCreatorApprovedFirstRequiresConfirmationAndSaves() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let server = try JoinCreatorTestServer(mode: .approvedFirst)
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }
        await store.createJoinRequest()
        #expect(store.joinCreatorPhase != .idle)

        try await waitUntil { store.joinCreatorApprovalPending }
        guard case let .awaitingConfirmation(verification) = store.joinCreatorPhase else {
            Issue.record("approved 先到时应停留在核对确认阶段")
            return
        }
        #expect(verification.code == (try server.expectedVerificationCode()))
        #expect(store.connection == nil)
        #expect(try credentialsStore.load() == nil)

        await store.confirmJoinCreation()

        #expect(store.joinCreatorPhase == .approved(vaultId: "vault-join", deviceId: "device-join"))
        #expect(store.joinCreatorApprovalPending == false)
        #expect(store.connection?.vaultId == "vault-join")
        let saved = try #require(try credentialsStore.load())
        #expect(saved.vaultId == "vault-join")
        #expect(saved.deviceId == "device-join")
        #expect(saved.vaultKey == server.expectedVaultKey)
        #expect(saved.endpoint == URL(string: "https://sync.example.test"))
        try repository.validateSyncBinding(vaultId: "vault-join", deviceId: "device-join")
        #expect(store.statusMessage != nil)
        // 成功保存后不得撤销本次设备。
        #expect(server.revokeAttempts == 0)
    }

    @Test("Path B 到达 deadline 时最后一次查询取回 approved 并允许确认")
    func joinCreatorApprovalArrivingAtDeadlineIsKept() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        // 创建响应与 approved 结果的相对有效期都是 0，模拟本地时间已越过服务器 expiresAt。
        let server = try JoinCreatorTestServer(
            mode: .approvedFirst,
            createLifetimeMs: 0,
            approvedLifetimeMs: 0
        )
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }

        await store.createJoinRequest()
        try await waitUntil { store.joinCreatorApprovalPending }
        guard case .awaitingConfirmation = store.joinCreatorPhase else {
            Issue.record("deadline 到达时应通过最后一次查询进入核对阶段")
            return
        }

        await store.confirmJoinCreation()

        #expect(store.joinCreatorPhase == .approved(vaultId: "vault-join", deviceId: "device-join"))
        #expect(try credentialsStore.load()?.vaultKey == server.expectedVaultKey)
    }

    @Test("Path B approved 到达后超过 TTL 仍保留待确认并可确认")
    func joinCreatorPendingApprovalSurvivesDeadline() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let server = try JoinCreatorTestServer(
            mode: .approvedFirst,
            createLifetimeMs: 300_000,
            approvedLifetimeMs: 0
        )
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }

        await store.createJoinRequest()
        try await waitUntil { store.joinCreatorApprovalPending }

        // 等待超过轮询间隔，旧实现会在这里按 TTL 将 pending approval 作废。
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(store.joinCreatorApprovalPending)
        guard case .awaitingConfirmation = store.joinCreatorPhase else {
            Issue.record("approved 已到达时不得因 TTL 过期丢弃待确认结果")
            return
        }

        await store.confirmJoinCreation()

        #expect(store.joinCreatorPhase == .approved(vaultId: "vault-join", deviceId: "device-join"))
        #expect(try credentialsStore.load()?.deviceId == "device-join")
    }

    @Test("Path B 已批准后取消会先撤销临时设备再取消配对")
    func cancelJoinCreationAfterApprovalRevokesDevice() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let server = try JoinCreatorTestServer(mode: .approvedFirst)
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }

        await store.createJoinRequest()
        try await waitUntil { store.joinCreatorApprovalPending }

        await store.cancelJoinCreation()

        #expect(store.joinCreatorPhase == .canceled)
        let creatorToken = try #require(server.creatorDeviceToken)
        #expect(server.revokeTokens == ["Bearer \(creatorToken)"])
        #expect(server.events == ["revoke", "cancel"])
        #expect(try credentialsStore.load() == nil)
    }

    @Test("Path B 创建方核对后 approved 公钥变化会被拒绝")
    func joinCreatorRejectsChangedApproverKey() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let server = try JoinCreatorTestServer(mode: .keyChanges)
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }
        await store.createJoinRequest()

        try await waitUntil {
            if case .awaitingConfirmation = store.joinCreatorPhase { return true }
            return false
        }
        try await waitUntil {
            if case .failed = store.joinCreatorPhase { return true }
            return false
        }
        guard case let .failed(message) = store.joinCreatorPhase else {
            Issue.record("approved 公钥变化应失败")
            return
        }
        #expect(message.contains("不匹配"))
        #expect(store.connection == nil)
        #expect(try credentialsStore.load() == nil)
    }

    @Test("Path B 创建方 deadline 使用 expiresAt - serverTime 偏移并随轮询更新")
    func joinCreatorDeadlineUsesServerTime() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let serverNow = nowMilliseconds()
        SyncStoreURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/v1/pairings/join":
                return (200, try successJSON([
                    "joinRequestId": "join-1",
                    "joinSecret": Base64URL.encode(Data(repeating: 4, count: 32)),
                    "shortCode": "123456",
                    "deviceId": "device-join",
                    "expiresAt": serverNow + 300_000,
                    "serverTime": serverNow,
                ]))
            case "/v1/pairings/join/join-1/result":
                return (500, try failureJSON(code: "SERVER_ERROR", message: "稍后重试"))
            default:
                throw TestFailure.unexpectedRequest(path)
            }
        }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: nil,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }
        await store.createJoinRequest()

        let initialDeadline = try #require(store.joinCreatorDeadline)
        #expect(abs(initialDeadline.timeIntervalSinceNow - 300) < 5)

        // 轮询返回 serverTime 偏移后的剩余时间，deadline 应随之更新。
        let polledAt = nowMilliseconds()
        SyncStoreURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            guard path == "/v1/pairings/join/join-1/result" else {
                throw TestFailure.unexpectedRequest(path)
            }
            return (200, try successJSON([
                "joinRequestId": "join-1",
                "status": "open",
                "deviceId": "device-join",
                "expiresAt": polledAt + 120_000,
                "serverTime": polledAt,
            ]))
        }
        try await waitUntil {
            guard let deadline = store.joinCreatorDeadline else { return false }
            return abs(deadline.timeIntervalSinceNow - 120) < 5
        }
        store.resetJoinCreation()
    }

    // MARK: - Path B 批准方

    @Test("Path B 批准方 resolve 后核对并批准成功")
    func joinApproverResolvesAndApproves() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let credentials = try makeCredentials()
        try credentialsStore.save(credentials)
        try repository.configureSync(SQLiteSyncConfiguration(
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId,
            vaultKey: credentials.vaultKey
        ))
        let server = try JoinApproverTestServer(failFirstApprove: false)
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: credentials,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }

        await store.resolveJoinCode("123456")
        guard case let .awaitingConfirmation(verification) = store.joinApproverPhase else {
            Issue.record("resolve 后应等待核对")
            return
        }
        #expect(verification.deviceName == "新手机")
        #expect(verification.code.count == 6)
        #expect(verification.code == (try server.expectedVerificationCode()))

        await store.approveJoin()
        #expect(store.joinApproverPhase == .done(deviceId: "device-new"))
        #expect(store.statusMessage?.contains("已批准") == true)
        #expect(server.approveAttempts == 1)
    }

    @Test("Path B 批准方 approve 失败后保留核对状态并可重试")
    func joinApproverRetainsStateAfterApproveFailure() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let credentials = try makeCredentials()
        try credentialsStore.save(credentials)
        try repository.configureSync(SQLiteSyncConfiguration(
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId,
            vaultKey: credentials.vaultKey
        ))
        let server = try JoinApproverTestServer(failFirstApprove: true)
        SyncStoreURLProtocol.handler = { try server.handle($0) }
        defer { SyncStoreURLProtocol.handler = nil }

        let store = try makeStore(
            credentials: credentials,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }

        await store.resolveJoinCode("123456")
        guard case .awaitingConfirmation = store.joinApproverPhase else {
            Issue.record("resolve 后应等待核对")
            return
        }

        await store.approveJoin()
        guard case .awaitingConfirmation = store.joinApproverPhase else {
            Issue.record("approve 失败后应保留核对状态")
            return
        }
        #expect(store.actionErrorMessage != nil)
        #expect(server.approveAttempts == 1)

        await store.approveJoin()
        #expect(store.joinApproverPhase == .done(deviceId: "device-new"))
        #expect(server.approveAttempts == 2)
    }

    // MARK: - 退出同步空间

    @Test("退出同步空间遇到 401/403 设备已撤销仍清理本地身份")
    func exitSpaceCleansUpWhenDeviceAlreadyRevoked() async throws {
        defer { SyncStoreURLProtocol.handler = nil }
        for (status, code) in [(401, "INVALID_DEVICE_TOKEN"), (403, "DEVICE_REVOKED")] {
            let (suite, defaults) = try makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let repository = try SQLiteTaskRepository(path: ":memory:")
            let credentialsStore = PairingTestCredentialsStore()
            let credentials = try makeCredentials()
            try credentialsStore.save(credentials)
            try repository.configureSync(SQLiteSyncConfiguration(
                vaultId: credentials.vaultId,
                deviceId: credentials.deviceId,
                vaultKey: credentials.vaultKey
            ))
            try repository.save(TodoTask(title: "保留任务", categoryID: TaskCategory.inboxID))
            SyncStoreURLProtocol.handler = { request in
                guard request.url?.path == "/v1/devices/current/revoke" else {
                    throw TestFailure.unexpectedRequest(request.url?.path ?? "")
                }
                return (status, try failureJSON(code: code, message: "设备已失效"))
            }
            let store = try makeStore(
                credentials: credentials,
                credentialsStore: credentialsStore,
                repository: repository,
                defaults: defaults
            )
            defer { store.stop() }

            await store.exitSpace()

            #expect(store.connection == nil)
            #expect(try credentialsStore.load() == nil)
            #expect(try repository.fetchAll().map(\.title) == ["保留任务"])
            try repository.configureSync(SQLiteSyncConfiguration(
                vaultId: "vault-new",
                deviceId: "device-new",
                vaultKey: Data(repeating: 2, count: 32)
            ))
        }
    }

    @Test("退出同步空间遇到其它错误时中止且保留本地身份")
    func exitSpaceKeepsIdentityOnOtherErrors() async throws {
        let (suite, defaults) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = PairingTestCredentialsStore()
        let credentials = try makeCredentials()
        try credentialsStore.save(credentials)
        try repository.configureSync(SQLiteSyncConfiguration(
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId,
            vaultKey: credentials.vaultKey
        ))
        SyncStoreURLProtocol.handler = { request in
            guard request.url?.path == "/v1/devices/current/revoke" else {
                throw TestFailure.unexpectedRequest(request.url?.path ?? "")
            }
            return (500, try failureJSON(code: "INTERNAL", message: "服务暂时不可用"))
        }
        defer { SyncStoreURLProtocol.handler = nil }
        let store = try makeStore(
            credentials: credentials,
            credentialsStore: credentialsStore,
            repository: repository,
            defaults: defaults
        )
        defer { store.stop() }

        await store.exitSpace()

        #expect(store.connection != nil)
        #expect(try credentialsStore.load() == credentials)
        #expect(store.actionErrorMessage != nil)
    }

    // MARK: - 帮助方法

    private func makeStore(
        credentials: SyncCredentials?,
        credentialsStore: PairingTestCredentialsStore,
        repository: SQLiteTaskRepository,
        defaults: UserDefaults,
        legacyDetection: SyncLegacyDetection = SyncLegacyDetection(
            credentialsInvalidated: false,
            legacyStoragePresent: false
        ),
        hasStoredValidCredentials: Bool = false
    ) throws -> SyncSettingsStore {
        let endpoint = try #require(URL(string: "https://sync.example.test"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncStoreURLProtocol.self]
        let client = try SyncAPIClient(
            endpoint: endpoint,
            session: URLSession(configuration: configuration)
        )
        return try SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            credentials: credentials,
            defaultSyncEndpoint: endpoint,
            legacyDetection: legacyDetection,
            hasStoredValidCredentials: hasStoredValidCredentials,
            apiClientFactory: { _ in client },
            defaults: defaults
        )
    }

    private func makeDefaults() throws -> (suite: String, defaults: UserDefaults) {
        let suite = "woo-todo-sync-pairing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (suite, defaults)
    }

    private func makeCredentials() throws -> SyncCredentials {
        SyncCredentials(
            endpoint: try #require(URL(string: "https://sync.example.test")),
            vaultId: "vault-test",
            deviceId: "device-mac",
            deviceToken: Base64URL.encode(Data(repeating: 1, count: 32)),
            vaultKey: Data(repeating: 7, count: 32)
        )
    }
}

// MARK: - 测试服务端

private enum JoinCreatorTestMode {
    case approvedFirst
    case keyChanges
}

private final class JoinCreatorTestServer: @unchecked Sendable {
    private let mode: JoinCreatorTestMode
    private let createLifetimeMs: Int64
    private let approvedLifetimeMs: Int64
    private let lock = NSLock()
    private var creatorPublicKey: String?
    private var capturedCreatorDeviceToken: String?
    private var pollCount = 0
    private var recordedEvents: [String] = []
    private var recordedRevokeTokens: [String] = []
    private let approverKeyPair: PairingKeyPair
    private let changedApproverKeyPair: PairingKeyPair
    private let vaultKey = Data(repeating: 7, count: 32)

    init(
        mode: JoinCreatorTestMode,
        createLifetimeMs: Int64 = 300_000,
        approvedLifetimeMs: Int64 = 300_000
    ) throws {
        self.mode = mode
        self.createLifetimeMs = createLifetimeMs
        self.approvedLifetimeMs = approvedLifetimeMs
        self.approverKeyPair = try PairingKeyPair.generate()
        self.changedApproverKeyPair = try PairingKeyPair.generate()
    }

    var expectedVaultKey: Data { vaultKey }

    var creatorDeviceToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return capturedCreatorDeviceToken
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var revokeTokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRevokeTokens
    }

    var revokeAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRevokeTokens.count
    }

    func expectedVerificationCode() throws -> String {
        lock.lock()
        let creator = creatorPublicKey
        lock.unlock()
        guard let creator else { throw TestFailure.missingCreatorKey }
        let creatorKey = try Base64URL.decode(creator)
        let sessionKey = try PairingJoinCrypto.sessionKey(
            keyPair: approverKeyPair,
            peerPublicKey: creatorKey,
            joinRequestId: "join-1"
        )
        return try PairingJoinCrypto.verificationCode(
            sessionKey: sessionKey,
            joinRequestId: "join-1",
            creatorPublicKey: creatorKey,
            approverPublicKey: approverKeyPair.publicKey
        )
    }

    func handle(_ request: URLRequest) throws -> (Int, String) {
        let path = request.url?.path ?? ""
        switch path {
        case "/v1/pairings/join":
            let body = try JSONDecoder().decode(
                CreateJoinRequest.self,
                from: requestBodyData(request)
            )
            lock.lock()
            creatorPublicKey = body.publicKey
            capturedCreatorDeviceToken = body.deviceToken
            lock.unlock()
            let now = nowMilliseconds()
            return (200, try successJSON([
                "joinRequestId": "join-1",
                "joinSecret": Base64URL.encode(Data(repeating: 4, count: 32)),
                "shortCode": "123456",
                "deviceId": "device-join",
                "expiresAt": now + createLifetimeMs,
                "serverTime": now,
            ]))
        case "/v1/pairings/join/join-1/result":
            lock.lock()
            let creator = creatorPublicKey
            pollCount += 1
            let poll = pollCount
            lock.unlock()
            guard let creator else { throw TestFailure.missingCreatorKey }
            let now = nowMilliseconds()
            switch mode {
            case .approvedFirst:
                let envelope = try sealEnvelope(approver: approverKeyPair, creator: creator)
                return (200, try approvedJSON(
                    approver: approverKeyPair,
                    envelope: envelope,
                    now: now
                ))
            case .keyChanges:
                if poll == 1 {
                    return (200, try successJSON([
                        "joinRequestId": "join-1",
                        "status": "resolved",
                        "deviceId": "device-join",
                        "approverPublicKey": approverKeyPair.publicKeyBase64URL,
                        "expiresAt": now + 300_000,
                        "serverTime": now,
                    ]))
                }
                let envelope = try sealEnvelope(
                    approver: changedApproverKeyPair,
                    creator: creator
                )
                return (200, try approvedJSON(
                    approver: changedApproverKeyPair,
                    envelope: envelope,
                    now: now
                ))
            }
        case "/v1/devices":
            return (200, try successJSON(["devices": []]))
        case "/v1/sync":
            let body = try JSONDecoder().decode(SyncRequest.self, from: requestBodyData(request))
            return (200, try successJSON([
                "push": [
                    "received": body.push.count,
                    "inserted": body.push.count,
                    "duplicates": 0,
                ],
                "pull": [],
                "cursor": body.cursor,
                "hasMore": false,
                "serverTime": nowMilliseconds(),
            ]))
        case "/v1/devices/current/revoke":
            lock.lock()
            recordedEvents.append("revoke")
            recordedRevokeTokens.append(
                request.value(forHTTPHeaderField: "Authorization") ?? ""
            )
            lock.unlock()
            return (200, try successJSON([
                "deviceId": "device-join",
                "revokedAt": nowMilliseconds(),
            ]))
        case "/v1/pairings/join/join-1/cancel":
            lock.lock()
            recordedEvents.append("cancel")
            lock.unlock()
            return (200, try successJSON([
                "joinRequestId": "join-1",
                "status": "canceled",
                "serverTime": nowMilliseconds(),
            ]))
        default:
            throw TestFailure.unexpectedRequest(path)
        }
    }

    private func sealEnvelope(
        approver: PairingKeyPair,
        creator: String
    ) throws -> EncryptedEnvelope {
        let creatorKey = try Base64URL.decode(creator)
        let sessionKey = try PairingJoinCrypto.sessionKey(
            keyPair: approver,
            peerPublicKey: creatorKey,
            joinRequestId: "join-1"
        )
        return try PairingJoinCrypto.sealVaultKey(
            vaultKey,
            sessionKey: sessionKey,
            joinRequestId: "join-1",
            deviceId: "device-join"
        )
    }

    private func approvedJSON(
        approver: PairingKeyPair,
        envelope: EncryptedEnvelope,
        now: Int64
    ) throws -> String {
        try successJSON([
            "joinRequestId": "join-1",
            "status": "approved",
            "deviceId": "device-join",
            "vaultId": "vault-join",
            "approverPublicKey": approver.publicKeyBase64URL,
            "vaultKeyEnvelope": [
                "ciphertext": envelope.ciphertext,
                "nonce": envelope.nonce,
            ],
            "expiresAt": now + approvedLifetimeMs,
            "serverTime": now,
        ])
    }
}

/// Path A 认领端测试服务：模拟服务端时钟比本机慢 10 分钟。
private final class ShortCodeClaimTestServer: @unchecked Sendable {
    private let lock = NSLock()
    private let failResult: Bool
    private let revokeStatus: Int
    private let initiatorKeyPair: PairingKeyPair
    private let pairingSecret = Data(repeating: 3, count: 32)
    private let vaultKey = Data(repeating: 9, count: 32)
    private let serverSkewMs: Int64
    private var claimedToken: String?
    private var claimedPublicKey: String?
    private var recordedRevokeTokens: [String] = []

    init(failResult: Bool, revokeStatus: Int = 200, serverSkewMs: Int64 = -600_000) throws {
        self.failResult = failResult
        self.revokeStatus = revokeStatus
        self.serverSkewMs = serverSkewMs
        self.initiatorKeyPair = try PairingKeyPair.generate()
    }

    var expectedVaultKey: Data { vaultKey }

    var claimedDeviceToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return claimedToken
    }

    var revokeTokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRevokeTokens
    }

    var revokeAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRevokeTokens.count
    }

    func handle(_ request: URLRequest) throws -> (Int, String) {
        let path = request.url?.path ?? ""
        // 服务端时间比本机慢 10 分钟：绝对 expiresAt 在本机看来可能已经过去。
        let serverNow = nowMilliseconds() + serverSkewMs
        switch path {
        case "/v1/pairings/resolve":
            return (200, try successJSON([
                "pairingId": "pairing-1",
                "pairingSecret": Base64URL.encode(pairingSecret),
                "initiatorPublicKey": initiatorKeyPair.publicKeyBase64URL,
                "vaultId": "vault-claim",
                "expiresAt": serverNow + 300_000,
                "serverTime": serverNow,
            ]))
        case "/v1/pairings/pairing-1/claim":
            let body = try JSONDecoder().decode(
                PairingClaimRequest.self,
                from: requestBodyData(request)
            )
            lock.lock()
            claimedToken = body.deviceToken
            claimedPublicKey = body.device.publicKey
            lock.unlock()
            return (200, try successJSON([
                "pairingId": "pairing-1",
                "status": "claimed",
                "deviceId": "device-claim",
                "expiresAt": serverNow + 300_000,
            ]))
        case "/v1/pairings/pairing-1/result":
            if failResult {
                return (500, try failureJSON(code: "SERVER_ERROR", message: "稍后重试"))
            }
            lock.lock()
            let claimPublicKey = claimedPublicKey
            lock.unlock()
            guard let claimPublicKey else { throw TestFailure.missingClaimKey }
            let sessionKey = try initiatorKeyPair.sessionKey(
                peerPublicKeyBase64URL: claimPublicKey,
                pairingId: "pairing-1",
                pairingSecretBase64URL: Base64URL.encode(pairingSecret)
            )
            let envelope = try PairingSessionCrypto.sealVaultKey(
                vaultKey,
                sessionKey: sessionKey,
                pairingId: "pairing-1",
                claimedDeviceId: "device-claim"
            )
            return (200, try successJSON([
                "pairingId": "pairing-1",
                "status": "confirmed",
                "vaultId": "vault-claim",
                "deviceId": "device-claim",
                "initiatorPublicKey": initiatorKeyPair.publicKeyBase64URL,
                "vaultKeyEnvelope": [
                    "ciphertext": envelope.ciphertext,
                    "nonce": envelope.nonce,
                ],
                "expiresAt": serverNow + 300_000,
            ]))
        case "/v1/devices/current/revoke":
            lock.lock()
            recordedRevokeTokens.append(
                request.value(forHTTPHeaderField: "Authorization") ?? ""
            )
            lock.unlock()
            if revokeStatus == 200 {
                return (200, try successJSON([
                    "deviceId": "device-claim",
                    "revokedAt": nowMilliseconds(),
                ]))
            }
            return (
                revokeStatus,
                try failureJSON(code: "INVALID_DEVICE_TOKEN", message: "设备令牌无效")
            )
        case "/v1/devices":
            return (200, try successJSON(["devices": []]))
        case "/v1/sync":
            let body = try JSONDecoder().decode(SyncRequest.self, from: requestBodyData(request))
            return (200, try successJSON([
                "push": [
                    "received": body.push.count,
                    "inserted": body.push.count,
                    "duplicates": 0,
                ],
                "pull": [],
                "cursor": body.cursor,
                "hasMore": false,
                "serverTime": nowMilliseconds(),
            ]))
        default:
            throw TestFailure.unexpectedRequest(path)
        }
    }
}

private final class JoinApproverTestServer: @unchecked Sendable {
    private let creatorKeyPair: PairingKeyPair
    private let vaultKey = Data(repeating: 7, count: 32)
    private let failFirstApprove: Bool
    private let lock = NSLock()
    private var approverPublicKey: String?
    private var attempts = 0

    init(failFirstApprove: Bool) throws {
        self.creatorKeyPair = try PairingKeyPair.generate()
        self.failFirstApprove = failFirstApprove
    }

    var approveAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func expectedVerificationCode() throws -> String {
        lock.lock()
        let approver = approverPublicKey
        lock.unlock()
        guard let approver else { throw TestFailure.missingApproverKey }
        let approverKey = try Base64URL.decode(approver)
        let sessionKey = try PairingJoinCrypto.sessionKey(
            keyPair: creatorKeyPair,
            peerPublicKey: approverKey,
            joinRequestId: "join-1"
        )
        return try PairingJoinCrypto.verificationCode(
            sessionKey: sessionKey,
            joinRequestId: "join-1",
            creatorPublicKey: creatorKeyPair.publicKey,
            approverPublicKey: approverKey
        )
    }

    func handle(_ request: URLRequest) throws -> (Int, String) {
        let path = request.url?.path ?? ""
        switch path {
        case "/v1/pairings/join/resolve":
            let body = try JSONDecoder().decode(
                ResolveJoinRequest.self,
                from: requestBodyData(request)
            )
            lock.lock()
            approverPublicKey = body.publicKey
            lock.unlock()
            let now = nowMilliseconds()
            return (200, try successJSON([
                "joinRequestId": "join-1",
                "joinPublicKey": creatorKeyPair.publicKeyBase64URL,
                "deviceId": "device-new",
                "device": ["name": "新手机", "platform": "android"],
                "approverPublicKey": body.publicKey,
                "expiresAt": now + 300_000,
                "serverTime": now,
            ]))
        case "/v1/pairings/join/join-1/approve":
            lock.lock()
            attempts += 1
            let attempt = attempts
            let approver = approverPublicKey
            lock.unlock()
            if failFirstApprove, attempt == 1 {
                return (500, try failureJSON(code: "SERVER_ERROR", message: "稍后重试"))
            }
            let body = try JSONDecoder().decode(
                PairingConfirmRequest.self,
                from: requestBodyData(request)
            )
            guard let approver else { throw TestFailure.missingApproverKey }
            let approverKey = try Base64URL.decode(approver)
            let sessionKey = try PairingJoinCrypto.sessionKey(
                keyPair: creatorKeyPair,
                peerPublicKey: approverKey,
                joinRequestId: "join-1"
            )
            let opened = try PairingJoinCrypto.openVaultKey(
                body.vaultKeyEnvelope,
                sessionKey: sessionKey,
                joinRequestId: "join-1",
                deviceId: "device-new"
            )
            guard opened == vaultKey else { throw TestFailure.vaultKeyMismatch }
            return (200, try successJSON([
                "joinRequestId": "join-1",
                "status": "approved",
                "vaultId": "vault-test",
                "deviceId": "device-new",
                "expiresAt": nowMilliseconds() + 300_000,
            ]))
        case "/v1/devices":
            return (200, try successJSON(["devices": []]))
        case "/v1/sync":
            let body = try JSONDecoder().decode(SyncRequest.self, from: requestBodyData(request))
            return (200, try successJSON([
                "push": [
                    "received": body.push.count,
                    "inserted": body.push.count,
                    "duplicates": 0,
                ],
                "pull": [],
                "cursor": body.cursor,
                "hasMore": false,
                "serverTime": nowMilliseconds(),
            ]))
        default:
            throw TestFailure.unexpectedRequest(path)
        }
    }
}

// MARK: - 测试基础设施

private enum TestFailure: Error, LocalizedError {
    case unexpectedRequest(String)
    case missingCreatorKey
    case missingApproverKey
    case missingClaimKey
    case vaultKeyMismatch
    case timeout

    var errorDescription: String? {
        switch self {
        case .unexpectedRequest(let path): "未预期的请求：\(path)"
        case .missingCreatorKey: "缺少创建方公钥"
        case .missingApproverKey: "缺少批准方公钥"
        case .missingClaimKey: "缺少认领方公钥"
        case .vaultKeyMismatch: "vault key 信封解密结果不一致"
        case .timeout: "等待测试状态超时"
        }
    }
}

private final class PairingTestCredentialsStore: SyncCredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: SyncCredentials?

    func save(_ credentials: SyncCredentials) throws {
        try credentials.validate()
        lock.lock()
        defer { lock.unlock() }
        self.credentials = credentials
    }

    func load() throws -> SyncCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        credentials = nil
    }
}

private final class SyncStoreHandlerBox: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, String)
    private let lock = NSLock()
    private var value: Handler?

    func set(_ handler: Handler?) {
        lock.lock()
        value = handler
        lock.unlock()
    }

    func get() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SyncStoreURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = SyncStoreHandlerBox()

    static var handler: SyncStoreHandlerBox.Handler? {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: TestFailure.unexpectedRequest("未配置处理器"))
            return
        }
        do {
            let (status, json) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func nowMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded())
}

private func successJSON(_ data: [String: Any]) throws -> String {
    try jsonString(["ok": true, "data": data, "requestId": "req-test"])
}

private func failureJSON(code: String, message: String) throws -> String {
    try jsonString([
        "ok": false,
        "error": ["code": code, "message": message],
        "requestId": "req-test",
    ])
}

private func jsonString(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func requestBodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(12),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TestFailure.timeout
}
