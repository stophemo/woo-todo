import Foundation
import Testing
import WooTodoCore
@testable import WooTodoStorage
@testable import WooTodoSync
@testable import WooTodoMacApp

@Suite("跨设备 WebDAV 设置", .serialized)
@MainActor
struct SyncSettingsStoreTests {
    @Test("测试连接并保存只保存 WebDAV 账号，不创建身份")
    func savesAccountWithoutIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        await fixture.store.testAndSaveAccount()

        #expect(fixture.store.account != nil)
        #expect(fixture.store.connection == nil)
        #expect(try fixture.credentialsStore.loadAccount() != nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(fixture.store.actionErrorMessage == nil)
        #expect(fixture.store.statusMessage != nil)
    }

    @Test("建立同步空间会生成身份、绑定数据库并保留任务")
    func createVaultBindsIdentityAndKeepsTasks() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-old",
            deviceId: "device-old",
            vaultKey: Data(repeating: 3, count: 32)
        ))
        let task = try TodoTask(title: "保留任务", categoryID: TaskCategory.inboxID)
        try fixture.repository.save(task)

        await fixture.store.createVault()

        let identity = try #require(try fixture.credentialsStore.loadIdentity())
        try identity.validate()
        #expect(fixture.store.connection?.vaultId == identity.vaultId)
        #expect(fixture.store.connection?.deviceId == identity.deviceId)
        #expect(fixture.store.account != nil)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["保留任务"])
        #expect(fixture.store.statusMessage?.contains("已建立") == true)
        fixture.store.stop()
    }

    @Test("通过邀请加入：保存账号并生成独立设备身份")
    func joinsWithInviteOnFreshDevice() async throws {
        let fixture = try makeFixture(withSavedAccount: false)
        defer { fixture.cleanup() }
        let invite = try makeInvite()
        let encoded = try invite.encode()

        await fixture.store.prepareInviteJoin(encoded)

        let prompt = try #require(fixture.store.inviteJoinPrompt)
        #expect(prompt.needsClear == false)
        #expect(fixture.store.actionErrorMessage == nil)

        await fixture.store.confirmInviteJoin()

        #expect(fixture.store.actionErrorMessage == nil)
        #expect(fixture.store.account?.username == "invite@example.com")
        #expect(fixture.store.connection?.vaultId == "vault-invite")
        #expect(fixture.store.connection?.deviceId != "device-owner-01")
        #expect(try fixture.credentialsStore.loadAccount()?.appPassword == "invite-password")
        #expect(try fixture.credentialsStore.loadIdentity()?.vaultId == "vault-invite")
    }

    @Test("通过邀请加入另一空间会先清空本机任务")
    func joinWithInviteClearsLocalData() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.repository.save(TodoTask(
            title: "加入前的本机任务",
            categoryID: TaskCategory.inboxID
        ))
        let encoded = try makeInvite().encode()

        await fixture.store.prepareInviteJoin(encoded)

        let prompt = try #require(fixture.store.inviteJoinPrompt)
        #expect(prompt.needsClear)
        #expect(prompt.localSummary?.taskCount == 1)
        await fixture.store.confirmInviteJoin()

        #expect(fixture.store.actionErrorMessage == nil)
        #expect(try fixture.repository.fetchAll().isEmpty)
        #expect(fixture.store.connection?.vaultId == "vault-invite")
    }

    @Test("无效邀请不会改变本机数据")
    func invalidInviteKeepsLocalData() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.repository.save(TodoTask(
            title: "保持不变",
            categoryID: TaskCategory.inboxID
        ))

        await fixture.store.prepareInviteJoin("woo-todo-invite:1:not-valid")

        #expect(fixture.store.inviteJoinPrompt == nil)
        #expect(fixture.store.actionErrorMessage?.contains("同步信息") == true)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["保持不变"])
        #expect(fixture.store.identity == nil)
    }

    @Test("退出同步空间只删本机身份，保留账号与任务")
    func exitSpaceKeepsAccountAndTasks() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let identity = try makeIdentity()
        try fixture.credentialsStore.saveIdentity(identity)
        let store = SyncSettingsStore(
            repository: fixture.repository,
            credentialsStore: fixture.credentialsStore,
            defaults: fixture.defaults,
            clientFactory: fixture.clientFactory
        )
        let task = try TodoTask(title: "退出后保留", categoryID: TaskCategory.inboxID)
        try fixture.repository.save(task)
        #expect(store.connection != nil)

        await store.exitSpace()

        #expect(store.connection == nil)
        #expect(store.account != nil)
        #expect(try fixture.credentialsStore.loadAccount() != nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["退出后保留"])
        // 绑定已重置：可以绑定另一个空间而不触发身份冲突。
        try fixture.repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-new",
            deviceId: "device-new",
            vaultKey: Data(repeating: 2, count: 32)
        ))
        store.stop()
    }

    @Test("legacy 提示只出现一次且不会删除旧凭据")
    func legacyNoticeIsShownOnce() throws {
        let suite = "woo-todo-webdav-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = InMemoryWebDavCredentialsStore()

        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            defaults: defaults,
            legacyNotice: SyncLegacyNotice.webDavMigrationText
        )
        #expect(store.legacyNotice == SyncLegacyNotice.webDavMigrationText)
        store.acknowledgeLegacyNotice()
        #expect(store.legacyNotice == nil)

        let reopened = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            defaults: defaults,
            legacyNotice: SyncLegacyNotice.webDavMigrationText
        )
        #expect(reopened.legacyNotice == nil)
    }

    @Test("账号表单会拒绝非 HTTPS 地址")
    func rejectsInvalidEndpoint() async throws {
        let fixture = try makeFixture(withSavedAccount: false)
        defer { fixture.cleanup() }
        fixture.store.endpointText = "http://dav.example.test"
        fixture.store.username = "user"
        fixture.store.appPassword = "password"

        await fixture.store.testAndSaveAccount()

        #expect(fixture.store.account == nil)
        #expect(fixture.store.actionErrorMessage != nil)
        #expect(try fixture.credentialsStore.loadAccount() == nil)
    }

    @Test("读取远端最大 Lamport 作为加入已有空间的水位")
    func readsRemoteLamportFloor() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let account = try #require(try fixture.credentialsStore.loadAccount())
        let identity = WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let remote = try WebDavOperation(
            vaultId: "personal-vault",
            deviceId: "device-android-01",
            operation: SyncPushOperation(
                opId: "ab-remote-op-01",
                entityId: "entity-remote-01",
                kind: .upsert,
                lamport: 77,
                ciphertext: Base64URL.encode(Data(repeating: 5, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 6, count: 12))
            )
        )
        WebDavTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch request.httpMethod {
            case "PROPFIND":
                let hrefs: [String]
                if path.hasSuffix("/ops") {
                    hrefs = ["v1/personal-vault/ops/ab"]
                } else if path.hasSuffix("/ops/ab") {
                    hrefs = ["v1/personal-vault/ops/ab/ab-remote-op-01.json"]
                } else {
                    hrefs = []
                }
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus(hrefs).utf8)
                )
            case "GET":
                return (
                    try makeWebDavTestResponse(request, status: 200),
                    try JSONEncoder().encode(remote)
                )
            default:
                return (try makeWebDavTestResponse(request, status: 201), Data())
            }
        }

        let floor = try await fixture.store.remoteLamportFloor(
            account: account,
            identity: identity
        )
        #expect(floor == 77)
    }

    @Test("启动加载已有身份时先取远端 Lamport 水位再绑定")
    func startupBindingUsesRemoteLamportFloor() async throws {
        let suite = "woo-todo-webdav-startup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        try repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-old",
            deviceId: "device-old",
            vaultKey: Data(repeating: 3, count: 32)
        ))
        try repository.save(TodoTask(
            title: "升级后保留",
            categoryID: TaskCategory.inboxID
        ))
        let account = WebDavAccount(
            endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
            username: "user@example.com",
            appPassword: "application-password"
        )
        let identity = WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let credentials = InMemoryWebDavCredentialsStore(
            account: account,
            identity: identity
        )
        let remote = try WebDavOperation(
            vaultId: "personal-vault",
            deviceId: "device-android-01",
            operation: SyncPushOperation(
                opId: "ab-startup-op-01",
                entityId: "entity-startup-01",
                kind: .upsert,
                lamport: 77,
                ciphertext: Base64URL.encode(Data(repeating: 5, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 6, count: 12))
            )
        )
        WebDavTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch request.httpMethod {
            case "PROPFIND":
                let hrefs: [String]
                if path.hasSuffix("/ops") {
                    hrefs = ["v1/personal-vault/ops/ab"]
                } else if path.hasSuffix("/ops/ab") {
                    hrefs = ["v1/personal-vault/ops/ab/ab-startup-op-01.json"]
                } else {
                    hrefs = []
                }
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus(hrefs).utf8)
                )
            case "GET":
                return (
                    try makeWebDavTestResponse(request, status: 200),
                    try JSONEncoder().encode(remote)
                )
            case "PUT":
                // 保持 outbox 不确认，便于断言本地快照的 Lamport 水位。
                return (try makeWebDavTestResponse(request, status: 503), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 201), Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentials,
            defaults: defaults,
            pollInterval: 0.02,
            clientFactory: { account, identity in
                try WebDavClient(
                    account: account,
                    identity: identity,
                    session: session,
                    retryDelaysNanoseconds: [],
                    retrySleep: { _ in }
                )
            }
        )
        defer {
            store.stop()
            WebDavTestURLProtocol.handler = nil
        }
        #expect(store.connection != nil)

        store.start()
        var operations: [SyncPushOperation] = []
        let waitUntil = Date().addingTimeInterval(3)
        while Date() < waitUntil {
            operations = try await repository.pendingOperations(limit: 50)
            if !operations.isEmpty, operations.allSatisfy({ $0.lamport > 77 }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!operations.isEmpty)
        #expect(operations.allSatisfy { $0.lamport > 77 })
    }

    @Test("切回已有空间后本地快照从远端 Lamport 水位之后继续")
    func bindingUsesRemoteLamportFloor() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-old",
            deviceId: "device-old",
            vaultKey: Data(repeating: 3, count: 32)
        ))
        try fixture.repository.save(TodoTask(
            title: "切回空间保留",
            categoryID: TaskCategory.inboxID
        ))
        let identity = WebDavIdentity(
            vaultId: "vault-return",
            deviceId: "device-return-01",
            vaultKey: Data(repeating: 4, count: 32)
        )

        try fixture.store.applyBinding(identity, remoteLamportFloor: 77)

        let operations = try await fixture.repository.pendingOperations(limit: 50)
        #expect(!operations.isEmpty)
        #expect(operations.allSatisfy { $0.lamport > 77 })
    }

    @Test("Path A：对方批准后自动保存身份")
    func pathAClaimAutomaticallySavesIdentity() async throws {
        let fixture = try makeFixture(pollInterval: 0.02)
        defer { fixture.cleanup() }
        let vaultKey = Data(repeating: 8, count: 32)
        let offerInfo = try makePathAOffer(
            code: "445566",
            vaultId: "vault-remote-confirm"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }

        fixture.store.claimByShortCode(offerInfo.offer.code)
        let claim = try await waitForClaim(server)
        #expect(fixture.store.joinPolicyPrompt == nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)

        try approve(
            claim: claim,
            offerInfo: offerInfo,
            vaultKey: vaultKey,
            in: server
        )

        let waitUntil = Date().addingTimeInterval(3)
        while Date() < waitUntil {
            if case .confirmed = fixture.store.pathAClaimPhase {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .confirmed = fixture.store.pathAClaimPhase else {
            Issue.record("approval 到达后应自动完成加入")
            return
        }
        let saved = try #require(try fixture.credentialsStore.loadIdentity())
        #expect(saved.vaultId == offerInfo.offer.vaultId)
        #expect(saved.deviceId == claim.deviceId)
        #expect(saved.vaultKey == vaultKey)
        #expect(fixture.store.connection?.vaultId == offerInfo.offer.vaultId)
    }

    @Test("Path B：无数据时对方批准后自动保存身份")
    func pathBCreateAutomaticallySavesIdentity() async throws {
        let fixture = try makeFixture(pollInterval: 0.02)
        defer { fixture.cleanup() }
        let server = PairingFlowServer()
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        await fixture.store.createJoinRequest()
        let code = try #require(fixture.store.pathBCreateCode)
        #expect(fixture.store.joinPolicyPrompt == nil)

        let account = try #require(try fixture.credentialsStore.loadAccount())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let approveClient = try WebDavClient(
            account: account,
            identity: nil,
            session: session,
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )
        let vaultKey = Data(repeating: 4, count: 32)
        let source = try await WebDavPathBApproveSession.start(
            transport: approveClient,
            code: code,
            vaultId: "vault-path-b",
            vaultKey: vaultKey,
            approverDeviceId: "device-mac-source",
            approverName: "Mac Source"
        )
        try await source.approve()

        #expect(try await waitFor {
            if case .approved = fixture.store.pathBCreatePhase {
                return true
            }
            return false
        })
        let saved = try #require(try fixture.credentialsStore.loadIdentity())
        #expect(saved.vaultId == "vault-path-b")
        #expect(saved.vaultKey == vaultKey)
        #expect(fixture.store.connection?.deviceId == saved.deviceId)
        #expect(fixture.store.connection?.vaultId == "vault-path-b")
    }

    @Test("Path B：有任务时批准前保留，批准后清空并加入")
    func pathBCreateWithLocalTasksClearsOnlyAfterApproval() async throws {
        let fixture = try makeFixture(pollInterval: 0.02)
        defer { fixture.cleanup() }
        let server = PairingFlowServer()
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "等待批准的任务",
            categoryID: TaskCategory.inboxID
        ))

        await fixture.store.createJoinRequest()
        #expect(fixture.store.joinPolicyPrompt == clearLocalDataPrompt(taskCount: 1))
        #expect(fixture.store.pathBCreatePhase == .awaitingDecision)

        await fixture.store.continueJoinClearingLocalTasks()
        let code = try #require(fixture.store.pathBCreateCode)
        // 对方尚未批准，任务必须保留。
        #expect(try fixture.repository.fetchAll().map(\.title) == ["等待批准的任务"])
        #expect(try fixture.credentialsStore.loadIdentity() == nil)

        let account = try #require(try fixture.credentialsStore.loadAccount())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let approveClient = try WebDavClient(
            account: account,
            identity: nil,
            session: session,
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )
        let vaultKey = Data(repeating: 2, count: 32)
        let source = try await WebDavPathBApproveSession.start(
            transport: approveClient,
            code: code,
            vaultId: "vault-path-b-clear",
            vaultKey: vaultKey,
            approverDeviceId: "device-mac-source",
            approverName: "Mac Source"
        )
        try await source.approve()

        #expect(try await waitFor {
            if case .approved = fixture.store.pathBCreatePhase {
                return true
            }
            return false
        })
        #expect(try fixture.repository.fetchAll().isEmpty)
        let saved = try #require(try fixture.credentialsStore.loadIdentity())
        #expect(saved.vaultId == "vault-path-b-clear")
        #expect(saved.vaultKey == vaultKey)
        #expect(fixture.store.connection?.vaultId == "vault-path-b-clear")
    }

    @Test("Path B：批准前取消配对不清空本机任务")
    func pathBCreateCancelBeforeApprovalKeepsLocalTasks() async throws {
        let fixture = try makeFixture(pollInterval: 0.02)
        defer { fixture.cleanup() }
        let server = PairingFlowServer()
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "取消后保留",
            categoryID: TaskCategory.inboxID
        ))

        await fixture.store.createJoinRequest()
        #expect(fixture.store.joinPolicyPrompt == clearLocalDataPrompt(taskCount: 1))
        await fixture.store.continueJoinClearingLocalTasks()
        #expect(fixture.store.pathBCreateCode != nil)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["取消后保留"])

        await fixture.store.cancelJoinCreation()

        #expect(fixture.store.pathBCreatePhase == .canceled)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["取消后保留"])
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
    }

    @Test("Path A：无身份但有任务时提示，批准前保留，批准后清空并加入")
    func pathAClaimWithLocalTasksClearsOnlyAfterApproval() async throws {
        let fixture = try makeFixture(pollInterval: 0.02)
        defer { fixture.cleanup() }
        let offerInfo = try makePathAOffer(
            code: "445567",
            vaultId: "vault-peer-tasks"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "本机任务",
            categoryID: TaskCategory.inboxID
        ))

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor {
            fixture.store.joinPolicyPrompt == clearLocalDataPrompt(taskCount: 1)
        })
        #expect(fixture.store.pathAClaimPhase == .awaitingDecision)
        #expect(server.claimData == nil)

        fixture.store.cancelJoinPolicyPrompt()
        #expect(fixture.store.joinPolicyPrompt == nil)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["本机任务"])
        #expect(server.claimData == nil)

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor { fixture.store.joinPolicyPrompt != nil })
        await fixture.store.continueJoinClearingLocalTasks()

        let claim = try await waitForClaim(server)
        #expect(claim.deviceName.isEmpty == false)
        // 对方批准前不得清空本机任务。
        #expect(try fixture.repository.fetchAll().map(\.title) == ["本机任务"])
        #expect(try fixture.credentialsStore.loadAccount() != nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        // 服务端已收到 claim 后，客户端状态可能还要一拍才切到等待批准。
        #expect(try await waitFor {
            if case .awaitingApproval = fixture.store.pathAClaimPhase {
                return true
            }
            return false
        })

        let vaultKey = Data(repeating: 5, count: 32)
        try approve(
            claim: claim,
            offerInfo: offerInfo,
            vaultKey: vaultKey,
            in: server
        )
        #expect(try await waitFor {
            if case .confirmed = fixture.store.pathAClaimPhase {
                return true
            }
            return false
        })
        #expect(try fixture.repository.fetchAll().isEmpty)
        let saved = try #require(try fixture.credentialsStore.loadIdentity())
        #expect(saved.vaultId == offerInfo.offer.vaultId)
        #expect(saved.deviceId == claim.deviceId)
        #expect(saved.vaultKey == vaultKey)
        #expect(fixture.store.connection?.vaultId == offerInfo.offer.vaultId)
    }

    @Test("Path A：已有空间时选择以本机为准，不清空数据也不写 claim")
    func pathAClaimWithIdentityCanChooseLocal() async throws {
        let localIdentity = WebDavIdentity(
            vaultId: "vault-local-choice",
            deviceId: "device-mac-local",
            vaultKey: Data(repeating: 7, count: 32)
        )
        let fixture = try makeFixture(identity: localIdentity, pollInterval: 0.02)
        defer { fixture.cleanup() }
        let offerInfo = try makePathAOffer(
            code: "556677",
            vaultId: "vault-peer-local-choice"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "保留本机",
            categoryID: TaskCategory.inboxID
        ))

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor { fixture.store.joinPolicyPrompt != nil })
        guard case let .chooseSpace(
            localVaultId,
            lastSyncedAt,
            peerDeviceName,
            peerPlatform
        ) = fixture.store.joinPolicyPrompt else {
            Issue.record("已有空间时应提示选择数据基准")
            return
        }
        #expect(localVaultId == localIdentity.vaultId)
        #expect(lastSyncedAt == nil)
        #expect(peerDeviceName == "Mac A")
        #expect(peerPlatform == .macos)

        fixture.store.joinUsingLocalData()

        #expect(fixture.store.joinPolicyPrompt == nil)
        #expect(try fixture.credentialsStore.loadIdentity() == localIdentity)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["保留本机"])
        #expect(server.claimData == nil)
        #expect(fixture.store.pathAClaimPhase == .idle)
        #expect(fixture.store.statusMessage?.contains("显示配对码") == true)
    }

    @Test("Path A：已有空间时选择以对方为准，批准前保留，批准后清空并加入")
    func pathAClaimWithIdentityCanChoosePeer() async throws {
        let localIdentity = WebDavIdentity(
            vaultId: "vault-local-old",
            deviceId: "device-mac-old",
            vaultKey: Data(repeating: 3, count: 32)
        )
        let fixture = try makeFixture(identity: localIdentity, pollInterval: 0.02)
        defer { fixture.cleanup() }
        let vaultKey = Data(repeating: 6, count: 32)
        let offerInfo = try makePathAOffer(
            code: "667788",
            vaultId: "vault-peer-choice"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "将被清空",
            categoryID: TaskCategory.inboxID
        ))

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor { fixture.store.joinPolicyPrompt != nil })
        await fixture.store.joinUsingPeerData()

        let claim = try await waitForClaim(server)
        // 对方批准前保留本机任务、身份与连接。
        #expect(try fixture.repository.fetchAll().map(\.title) == ["将被清空"])
        #expect(try fixture.credentialsStore.loadIdentity() == localIdentity)
        #expect(fixture.store.identity == localIdentity)
        #expect(fixture.store.connection?.vaultId == localIdentity.vaultId)
        guard case .awaitingApproval = fixture.store.pathAClaimPhase else {
            Issue.record("选择以对方为准后应继续认领并等待批准")
            return
        }

        try approve(
            claim: claim,
            offerInfo: offerInfo,
            vaultKey: vaultKey,
            in: server
        )
        #expect(try await waitFor {
            if case .confirmed = fixture.store.pathAClaimPhase {
                return true
            }
            return false
        })
        #expect(try fixture.repository.fetchAll().isEmpty)
        let saved = try #require(try fixture.credentialsStore.loadIdentity())
        #expect(saved.vaultId == offerInfo.offer.vaultId)
        #expect(saved.deviceId == claim.deviceId)
        #expect(saved.vaultKey == vaultKey)
        #expect(fixture.store.identity?.vaultId == offerInfo.offer.vaultId)
        #expect(fixture.store.connection?.vaultId == offerInfo.offer.vaultId)
        #expect(fixture.store.connection?.deviceId == claim.deviceId)
    }

    @Test("Path A：选择以对方为准后取消配对不清空本机数据")
    func pathAClaimPeerCancelBeforeApprovalKeepsLocalData() async throws {
        let localIdentity = WebDavIdentity(
            vaultId: "vault-local-cancel",
            deviceId: "device-mac-cancel",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let fixture = try makeFixture(identity: localIdentity, pollInterval: 0.02)
        defer { fixture.cleanup() }
        let offerInfo = try makePathAOffer(
            code: "889901",
            vaultId: "vault-peer-cancel"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "取消后保留",
            categoryID: TaskCategory.inboxID
        ))

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor { fixture.store.joinPolicyPrompt != nil })
        await fixture.store.joinUsingPeerData()
        _ = try await waitForClaim(server)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["取消后保留"])
        #expect(try fixture.credentialsStore.loadIdentity() == localIdentity)

        fixture.store.cancelShortCodeClaim()

        #expect(fixture.store.pathAClaimPhase == .idle)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["取消后保留"])
        #expect(try fixture.credentialsStore.loadIdentity() == localIdentity)
        #expect(fixture.store.identity == localIdentity)
        #expect(fixture.store.connection?.vaultId == localIdentity.vaultId)
    }

    @Test("Path A：批准前配对码过期不清空本机数据")
    func pathAClaimPeerExpiryBeforeApprovalKeepsLocalData() async throws {
        let localIdentity = WebDavIdentity(
            vaultId: "vault-local-expiry",
            deviceId: "device-mac-expiry",
            vaultKey: Data(repeating: 4, count: 32)
        )
        let fixture = try makeFixture(identity: localIdentity, pollInterval: 0.02)
        defer { fixture.cleanup() }
        let offerInfo = try makePathAOffer(
            code: "889902",
            vaultId: "vault-peer-expiry",
            expiresInMilliseconds: 2_000
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "过期后保留",
            categoryID: TaskCategory.inboxID
        ))

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor { fixture.store.joinPolicyPrompt != nil })
        await fixture.store.joinUsingPeerData()
        _ = try await waitForClaim(server)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["过期后保留"])
        #expect(try fixture.credentialsStore.loadIdentity() == localIdentity)

        #expect(try await waitFor(timeout: 4) {
            if case .failed = fixture.store.pathAClaimPhase {
                return true
            }
            return false
        })
        guard case let .failed(message) = fixture.store.pathAClaimPhase else {
            Issue.record("配对码过期应进入失败状态")
            return
        }
        #expect(message.contains("过期"))
        #expect(try fixture.repository.fetchAll().map(\.title) == ["过期后保留"])
        #expect(try fixture.credentialsStore.loadIdentity() == localIdentity)
        #expect(fixture.store.identity == localIdentity)
        #expect(fixture.store.connection?.vaultId == localIdentity.vaultId)
    }

    @Test("Path A：批准后清空失败不保存新身份")
    func pathAClaimPeerClearFailureDoesNotSaveIdentity() async throws {
        let failingStore = FailingIdentityDeleteStore()
        let fixture = try makeFixture(
            credentialsStore: failingStore,
            pollInterval: 0.02
        )
        defer { fixture.cleanup() }
        let vaultKey = Data(repeating: 3, count: 32)
        let offerInfo = try makePathAOffer(
            code: "889903",
            vaultId: "vault-clear-failure"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "清空失败",
            categoryID: TaskCategory.inboxID
        ))

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor {
            fixture.store.joinPolicyPrompt == clearLocalDataPrompt(taskCount: 1)
        })
        await fixture.store.continueJoinClearingLocalTasks()
        let claim = try await waitForClaim(server)
        try approve(
            claim: claim,
            offerInfo: offerInfo,
            vaultKey: vaultKey,
            in: server
        )

        #expect(try await waitFor {
            if case .failed = fixture.store.pathAClaimPhase {
                return true
            }
            return false
        })
        guard case let .failed(message) = fixture.store.pathAClaimPhase else {
            Issue.record("清空失败应进入失败状态")
            return
        }
        #expect(!message.isEmpty)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(failingStore.saveIdentityCount == 0)
        #expect(fixture.store.identity == nil)
        #expect(fixture.store.connection == nil)
        #expect(try fixture.credentialsStore.loadAccount() != nil)
    }

    @Test("Path A：自动保存身份失败时回滚并显示错误")
    func pathAClaimAutoSaveFailureRollsBack() async throws {
        let failingStore = FailingIdentitySaveStore()
        let fixture = try makeFixture(
            credentialsStore: failingStore,
            pollInterval: 0.02
        )
        defer { fixture.cleanup() }
        let vaultKey = Data(repeating: 9, count: 32)
        let offerInfo = try makePathAOffer(
            code: "778899",
            vaultId: "vault-save-failure"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }

        fixture.store.claimByShortCode(offerInfo.offer.code)
        let claim = try await waitForClaim(server)
        try approve(
            claim: claim,
            offerInfo: offerInfo,
            vaultKey: vaultKey,
            in: server
        )
        #expect(try await waitFor {
            if case .failed = fixture.store.pathAClaimPhase {
                return true
            }
            return false
        })
        guard case let .failed(message) = fixture.store.pathAClaimPhase else {
            Issue.record("保存失败应进入失败状态")
            return
        }
        #expect(!message.isEmpty)
        #expect(fixture.store.connection == nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        // 绑定未成功，仍可绑定其他身份。
        try fixture.repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-after-failure",
            deviceId: "device-after-failure",
            vaultKey: Data(repeating: 1, count: 32)
        ))
    }

    @Test("Path A：持有空间方显示加入方设备名和核对码并批准")
    func pathAShowDisplaysDeviceAndApproves() async throws {
        let fixture = try makeFixture(identity: try makeIdentity())
        defer { fixture.cleanup() }
        let server = PairingFlowServer()
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }

        await fixture.store.createPairing()
        let code = try #require(fixture.store.pathAShowCode)
        let offerName = try #require(
            server.fileNames.first { $0.hasPrefix("offer-\(code)-") }
        )
        let offerData = try #require(server.data(named: offerName))
        guard case let .offer(offer) = try WebDavPairingFileCodec.decode(offerData) else {
            Issue.record("应写入 offer")
            return
        }
        let claimKey = try PairingKeyPair.generate()
        let now = Date()
        let createdAt = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let claim = WebDavPairingClaim(
            pairingId: offer.pairingId,
            createdAt: createdAt,
            expiresAt: createdAt + WebDavPairingProtocol.ttlMilliseconds,
            publicKey: claimKey.publicKeyBase64URL,
            deviceId: "device-android-new",
            deviceName: "Pixel 新机",
            platform: .android
        )
        server.put(
            name: WebDavPairingFileName(
                kind: .claim,
                code: nil,
                pairingId: offer.pairingId
            ).string,
            data: try WebDavPairingFileCodec.encode(.claim(claim))
        )

        #expect(try await waitFor {
            if case .awaitingVerification = fixture.store.pathAShowPhase {
                return true
            }
            return false
        })
        guard case let .awaitingVerification(
            deviceName,
            platform,
            verificationCode,
            _
        ) = fixture.store.pathAShowPhase else {
            Issue.record("持有空间方应显示加入方信息")
            return
        }
        #expect(deviceName == "Pixel 新机")
        #expect(platform == .android)
        #expect(verificationCode.count == 6)

        await fixture.store.confirmPairing()

        #expect(fixture.store.pathAShowPhase == .confirmed)
        #expect(server.data(named: WebDavPairingFileName(
            kind: .approval,
            code: nil,
            pairingId: offer.pairingId
        ).string) != nil)
    }

    @Test("清空本机数据保留账号与显示偏好并刷新列表")
    func clearLocalDataForJoinKeepsAccountAndPreferences() async throws {
        let identity = try makeIdentity()
        let fixture = try makeFixture(identity: identity)
        defer { fixture.cleanup() }
        let preferences = try WireDisplayConfigurationPayload(
            headerTemplate: "{dateLong} · 保留偏好",
            subtitleTemplate: "第 {elapsedDays} 天",
            startDate: "2026-01-01",
            deadlineDate: "2026-12-31"
        )
        try fixture.repository.saveDisplayConfiguration(preferences)
        let work = try TaskCategory(id: "work", name: "工作", order: 4)
        try fixture.repository.saveCategories(
            TaskCategory.normalizeList(TaskCategory.defaults + [work])
        )
        try fixture.repository.save(TodoTask(
            title: "将被清空",
            categoryID: "work"
        ))
        var refreshCount = 0
        fixture.store.onRemoteChanges = { refreshCount += 1 }

        try await fixture.store.clearLocalDataForJoin()

        #expect(try fixture.credentialsStore.loadAccount() != nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(try fixture.repository.fetchAll().isEmpty)
        #expect(try fixture.repository.fetchTrash().isEmpty)
        #expect(try fixture.repository.fetchCategories() == TaskCategory.defaults)
        #expect(try fixture.repository.displayConfiguration() == preferences)
        #expect(fixture.store.identity == nil)
        #expect(fixture.store.connection == nil)
        #expect(refreshCount == 1)
        // 清空后可绑定新身份。
        try fixture.repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-new-binding",
            deviceId: "device-new-binding",
            vaultKey: Data(repeating: 2, count: 32)
        ))
    }

    @Test("只有回收站与自定义标签时也提示清空，不会直接加入")
    func localTrashAndCustomCategoriesRequireClearPrompt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let work = try TaskCategory(id: "work", name: "工作", order: 4)
        try fixture.repository.saveCategories(
            TaskCategory.normalizeList(TaskCategory.defaults + [work])
        )
        let trashed = try TodoTask(title: "回收站任务", categoryID: "work")
        try fixture.repository.save(trashed)
        try fixture.repository.delete(id: trashed.id)

        await fixture.store.createJoinRequest()

        guard case let .clearLocalData(summary) = fixture.store.joinPolicyPrompt else {
            Issue.record("只有回收站和自定义标签时也必须先提示清空")
            return
        }
        #expect(summary.taskCount == 0)
        #expect(summary.trashCount == 1)
        #expect(summary.customCategoryCount == 1)
        #expect(summary.deferredChangeCount > 0)
        #expect(summary.summaryDescription.contains("回收站"))
        #expect(summary.summaryDescription.contains("自定义标签"))
        #expect(fixture.store.pathBCreatePhase == .awaitingDecision)
        #expect(fixture.store.pathBCreateCode == nil)
    }

    @Test("Path A：身份删除失败时保留任务和旧连接并显示错误")
    func pathAClaimIdentityDeleteFailureKeepsLocalDataAndConnection() async throws {
        let failingStore = FailingIdentityDeleteStore()
        let localIdentity = WebDavIdentity(
            vaultId: "vault-local-keep",
            deviceId: "device-mac-keep",
            vaultKey: Data(repeating: 2, count: 32)
        )
        let fixture = try makeFixture(
            identity: localIdentity,
            credentialsStore: failingStore,
            pollInterval: 0.02
        )
        defer { fixture.cleanup() }
        let offerInfo = try makePathAOffer(
            code: "990011",
            vaultId: "vault-peer-keep"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "删除身份失败保留",
            categoryID: TaskCategory.inboxID
        ))
        // 创建 fixture 时写入的初始身份不计入“adopt 新身份”次数。
        let seededSaveCount = failingStore.saveIdentityCount

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor { fixture.store.joinPolicyPrompt != nil })
        await fixture.store.joinUsingPeerData()
        let claim = try await waitForClaim(server)
        try approve(
            claim: claim,
            offerInfo: offerInfo,
            vaultKey: Data(repeating: 5, count: 32),
            in: server
        )

        #expect(try await waitFor {
            if case .failed = fixture.store.pathAClaimPhase {
                return true
            }
            return false
        })
        guard case let .failed(message) = fixture.store.pathAClaimPhase else {
            Issue.record("身份删除失败应显示错误")
            return
        }
        #expect(!message.isEmpty)
        #expect(failingStore.saveIdentityCount == seededSaveCount)
        #expect(try fixture.credentialsStore.loadIdentity() == localIdentity)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["删除身份失败保留"])
        #expect(fixture.store.identity == localIdentity)
        #expect(fixture.store.connection?.vaultId == localIdentity.vaultId)

        // 旧 runner 仍可用：重新触发同步能成功完成。
        fixture.store.requestSync(.manual)
        #expect(try await waitFor(timeout: 5) {
            fixture.store.runtimeSnapshot.lastSuccessfulAt != nil
        })
    }

    @Test("任务清空失败时保留任务并进入未配对状态，不保存新身份")
    func pathAClaimClearFailureKeepsTasksAndUnpairs() async throws {
        let credentials = RecordingCredentialsStore()
        let fixture = try makeFixture(
            credentialsStore: credentials,
            pollInterval: 0.02
        )
        defer { fixture.cleanup() }
        try fixture.repository.installClearLocalDataFailureTriggerForTesting()
        let offerInfo = try makePathAOffer(
            code: "990012",
            vaultId: "vault-peer-clear-fail"
        )
        let server = PairingFlowServer()
        try install(offer: offerInfo.offer, in: server)
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "清空失败保留",
            categoryID: TaskCategory.inboxID
        ))

        fixture.store.claimByShortCode(offerInfo.offer.code)
        #expect(try await waitFor {
            fixture.store.joinPolicyPrompt == clearLocalDataPrompt(taskCount: 1)
        })
        await fixture.store.continueJoinClearingLocalTasks()
        let claim = try await waitForClaim(server)
        try approve(
            claim: claim,
            offerInfo: offerInfo,
            vaultKey: Data(repeating: 4, count: 32),
            in: server
        )

        #expect(try await waitFor {
            if case .failed = fixture.store.pathAClaimPhase {
                return true
            }
            return false
        })
        guard case let .failed(message) = fixture.store.pathAClaimPhase else {
            Issue.record("任务清空失败应显示错误")
            return
        }
        #expect(!message.isEmpty)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["清空失败保留"])
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(credentials.saveIdentityCount == 0)
        #expect(fixture.store.identity == nil)
        #expect(fixture.store.connection == nil)
        #expect(fixture.store.runtimeSnapshot.isConfigured == false)
        #expect(try fixture.credentialsStore.loadAccount() != nil)
    }

    @Test("Path B：配对码过期不清空本机任务")
    func pathBCreateExpiryKeepsLocalTasks() async throws {
        let clock = TestClock()
        let fixture = try makeFixture(
            pollInterval: 0.02,
            now: { clock.now }
        )
        defer { fixture.cleanup() }
        let server = PairingFlowServer()
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "过期后保留",
            categoryID: TaskCategory.inboxID
        ))

        await fixture.store.createJoinRequest()
        #expect(fixture.store.joinPolicyPrompt == clearLocalDataPrompt(taskCount: 1))
        await fixture.store.continueJoinClearingLocalTasks()
        #expect(fixture.store.pathBCreateCode != nil)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["过期后保留"])

        clock.advance(by: 6 * 60)

        #expect(try await waitFor {
            fixture.store.pathBCreatePhase == .expired
        })
        #expect(try fixture.repository.fetchAll().map(\.title) == ["过期后保留"])
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(fixture.store.identity == nil)
        #expect(fixture.store.connection == nil)
        #expect(fixture.store.pathBCreateCode == nil)
    }

    @Test("Path B：清空失败不保存新身份")
    func pathBCreateClearFailureDoesNotAdoptIdentity() async throws {
        let credentials = RecordingCredentialsStore()
        let fixture = try makeFixture(
            credentialsStore: credentials,
            pollInterval: 0.02
        )
        defer { fixture.cleanup() }
        try fixture.repository.installClearLocalDataFailureTriggerForTesting()
        let server = PairingFlowServer()
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }
        try fixture.repository.save(TodoTask(
            title: "清空失败保留",
            categoryID: TaskCategory.inboxID
        ))

        await fixture.store.createJoinRequest()
        #expect(fixture.store.joinPolicyPrompt == clearLocalDataPrompt(taskCount: 1))
        await fixture.store.continueJoinClearingLocalTasks()
        let code = try #require(fixture.store.pathBCreateCode)

        let account = try #require(try fixture.credentialsStore.loadAccount())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let approveClient = try WebDavClient(
            account: account,
            identity: nil,
            session: session,
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )
        let source = try await WebDavPathBApproveSession.start(
            transport: approveClient,
            code: code,
            vaultId: "vault-path-b-clear-fail",
            vaultKey: Data(repeating: 7, count: 32),
            approverDeviceId: "device-mac-source",
            approverName: "Mac Source"
        )
        try await source.approve()

        #expect(try await waitFor {
            if case .failed = fixture.store.pathBCreatePhase {
                return true
            }
            return false
        })
        #expect(try fixture.repository.fetchAll().map(\.title) == ["清空失败保留"])
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(credentials.saveIdentityCount == 0)
        #expect(fixture.store.identity == nil)
        #expect(fixture.store.connection == nil)
        #expect(fixture.store.runtimeSnapshot.isConfigured == false)
    }

    @Test("清空成功后任务、回收站、标签与 deferred 清空，账号与显示偏好保留")
    func clearLocalDataForJoinClearsAllDerivedLocalData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "woo-todo-clear-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("tasks.sqlite")
        let boundRepository = try SQLiteTaskRepository(
            databaseURL: databaseURL,
            syncConfiguration: SQLiteSyncConfiguration(
                vaultId: "vault-clear-source",
                deviceId: "device-clear-source",
                vaultKey: Data(repeating: 6, count: 32)
            )
        )
        let baseTask = try TodoTask(
            title: "将被删除",
            categoryID: TaskCategory.inboxID
        )
        try boundRepository.save(baseTask)
        let work = try TaskCategory(id: "work", name: "工作", order: 4)
        try boundRepository.saveCategories(
            TaskCategory.normalizeList(TaskCategory.defaults + [work])
        )

        // 重新打开后数据库仍记得同步身份，但未加载密钥：新变更会进入 deferred 表。
        let repository = try SQLiteTaskRepository(databaseURL: databaseURL)
        try repository.save(TodoTask(
            title: "待同步任务",
            categoryID: "work"
        ))
        try repository.delete(id: baseTask.id)
        let preferences = try WireDisplayConfigurationPayload(
            headerTemplate: "{dateLong} · 清空后保留",
            subtitleTemplate: "第 {elapsedDays} 天",
            startDate: "2026-01-01",
            deadlineDate: "2026-12-31"
        )
        try repository.saveDisplayConfiguration(preferences)

        let before = try repository.joinLocalDataSummary()
        #expect(before.taskCount == 1)
        #expect(before.trashCount == 1)
        #expect(before.customCategoryCount == 1)
        #expect(before.deferredChangeCount == 2)

        let fixture = try makeFixture(repository: repository)
        defer { fixture.cleanup() }
        try await fixture.store.clearLocalDataForJoin()

        #expect(try repository.joinLocalDataSummary().hasAnyData == false)
        #expect(try repository.fetchAll().isEmpty)
        #expect(try repository.fetchTrash().isEmpty)
        #expect(try repository.fetchCategories() == TaskCategory.defaults)
        #expect(try repository.displayConfiguration() == preferences)
        #expect(try fixture.credentialsStore.loadAccount() != nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(fixture.store.identity == nil)
        #expect(fixture.store.connection == nil)
        #expect(fixture.store.runtimeSnapshot.isConfigured == false)
    }

    @Test("Path A 认领轮询遇到 5xx 时在配对码有效期内继续重试")
    func claimPollingRetriesTransientServerErrors() async throws {
        let fixture = try makeFixture(pollInterval: 0.02)
        defer { fixture.cleanup() }
        let now = Date()
        let pairingId = "pairing-retry-claim-01"
        let code = "112233"
        let offerName = WebDavPairingFileName(
            kind: .offer,
            code: code,
            pairingId: pairingId
        ).string
        let offerKey = try PairingKeyPair.generate()
        let offer = WebDavPairingOffer(
            pairingId: pairingId,
            createdAt: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
            expiresAt: Int64((now.addingTimeInterval(300).timeIntervalSince1970 * 1_000).rounded()),
            code: code,
            publicKey: offerKey.publicKeyBase64URL,
            pairingSecret: Base64URL.encode(try SecureRandom.bytes(count: 32)),
            vaultId: "vault-remote",
            deviceName: "Mac A",
            platform: .macos
        )
        let offerData = try WebDavPairingFileCodec.encode(.offer(offer))
        let counter = PairingListCounter()
        WebDavTestURLProtocol.handler = { request in
            switch request.httpMethod {
            case "MKCOL":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "PROPFIND":
                if counter.next() == 3 {
                    // 第一次轮询模拟 429/5xx：客户端不内部重试，交给配对轮询继续。
                    return (try makeWebDavTestResponse(request, status: 503), Data())
                }
                let hrefs = ["v1/pairing/\(offerName)"]
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus(hrefs).utf8)
                )
            case "GET":
                return (try makeWebDavTestResponse(request, status: 200), offerData)
            case "PUT":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "DELETE":
                return (try makeWebDavTestResponse(request, status: 204), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 200), Data())
            }
        }

        fixture.store.claimByShortCode(code)
        let waitUntil = Date().addingTimeInterval(3)
        while Date() < waitUntil, counter.value < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(counter.value >= 5)
        switch fixture.store.pathAClaimPhase {
        case .failed(let message):
            Issue.record("临时服务错误不应终止配对：\(message)")
        case .awaitingApproval:
            break
        default:
            Issue.record("配对应继续等待对方批准")
        }
        fixture.store.cancelShortCodeClaim()
    }

    @Test("启动激活身份后写入本机设备心跳")
    func startupWritesDeviceHeartbeat() async throws {
        let suite = "woo-todo-webdav-heartbeat-startup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let account = WebDavAccount(
            endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
            username: "user@example.com",
            appPassword: "application-password"
        )
        let identity = WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let credentials = InMemoryWebDavCredentialsStore(
            account: account,
            identity: identity
        )
        let recorder = DeviceHeartbeatRecorder()
        WebDavTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch request.httpMethod {
            case "PUT":
                if path.contains("/devices/") {
                    recorder.recordPut(body: requestBody(request))
                }
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "PROPFIND":
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus([]).utf8)
                )
            case "MKCOL":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "DELETE":
                return (try makeWebDavTestResponse(request, status: 204), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 200), Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentials,
            defaults: defaults,
            clientFactory: { account, identity in
                try WebDavClient(
                    account: account,
                    identity: identity,
                    session: session,
                    retryDelaysNanoseconds: [],
                    retrySleep: { _ in }
                )
            }
        )
        defer {
            store.stop()
            WebDavTestURLProtocol.handler = nil
        }

        store.start()
        let data = try await waitForHeartbeatWrite(recorder)
        let envelope = try JSONDecoder().decode(
            WebDavDeviceHeartbeatEnvelope.self,
            from: data
        )
        #expect(envelope.deviceId == identity.deviceId)
        let heartbeat = try WebDavDeviceHeartbeatCodec.open(
            envelope,
            vaultId: identity.vaultId,
            vaultKey: identity.vaultKey
        )
        #expect(heartbeat.platform == .macos)
        #expect(!heartbeat.name.isEmpty)
        #expect((1...32).contains(heartbeat.appVersion.count))
        #expect(heartbeat.lastSeenAt > 0)
    }

    @Test("每次同步成功后写入设备心跳")
    func syncSuccessWritesDeviceHeartbeat() async throws {
        let suite = "woo-todo-webdav-heartbeat-sync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let account = WebDavAccount(
            endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
            username: "user@example.com",
            appPassword: "application-password"
        )
        let identity = WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let credentials = InMemoryWebDavCredentialsStore(
            account: account,
            identity: identity
        )
        let recorder = DeviceHeartbeatRecorder()
        let failures = DeviceHeartbeatFirstAttemptFailure()
        WebDavTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch request.httpMethod {
            case "PUT":
                if path.contains("/devices/") {
                    // 启动心跳失败不影响同步；同步成功后的心跳应重试成功。
                    if failures.consumeFailure() {
                        return (try makeWebDavTestResponse(request, status: 503), Data())
                    }
                    recorder.recordPut(body: requestBody(request))
                }
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "PROPFIND":
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus([]).utf8)
                )
            case "MKCOL":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "DELETE":
                return (try makeWebDavTestResponse(request, status: 204), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 200), Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentials,
            defaults: defaults,
            clientFactory: { account, identity in
                try WebDavClient(
                    account: account,
                    identity: identity,
                    session: session,
                    retryDelaysNanoseconds: [],
                    retrySleep: { _ in }
                )
            }
        )
        defer {
            store.stop()
            WebDavTestURLProtocol.handler = nil
        }

        store.start()
        _ = try await waitForHeartbeatWrite(recorder, minimumCount: 1)
        store.requestSync(.manual)
        _ = try await waitForHeartbeatWrite(recorder, minimumCount: 2)
        #expect(recorder.heartbeatWrites.count >= 2)
    }

    @Test("退出空间时尽力删除本机设备心跳")
    func exitSpaceDeletesOwnDeviceHeartbeat() async throws {
        let suite = "woo-todo-webdav-heartbeat-exit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let account = WebDavAccount(
            endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
            username: "user@example.com",
            appPassword: "application-password"
        )
        let identity = WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let credentials = InMemoryWebDavCredentialsStore(
            account: account,
            identity: identity
        )
        let recorder = DeviceHeartbeatRecorder()
        WebDavTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch request.httpMethod {
            case "DELETE":
                recorder.recordDelete(path: path)
                return (try makeWebDavTestResponse(request, status: 204), Data())
            case "MKCOL":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "PROPFIND":
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus([]).utf8)
                )
            default:
                return (try makeWebDavTestResponse(request, status: 200), Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentials,
            defaults: defaults,
            clientFactory: { account, identity in
                try WebDavClient(
                    account: account,
                    identity: identity,
                    session: session,
                    retryDelaysNanoseconds: [],
                    retrySleep: { _ in }
                )
            }
        )
        defer {
            store.stop()
            WebDavTestURLProtocol.handler = nil
        }

        await store.exitSpace()

        #expect(
            recorder.deletedPaths
                == ["/woo-todo/v1/personal-vault/devices/device-mac-01.json"]
        )
        #expect(try credentials.loadIdentity() == nil)
        #expect(store.devices.isEmpty)
    }

    @Test("刷新设备列表并标记当前设备")
    func refreshDevicesMarksCurrentDevice() async throws {
        let suite = "woo-todo-webdav-devices-refresh-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let account = WebDavAccount(
            endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
            username: "user@example.com",
            appPassword: "application-password"
        )
        let identity = WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let credentials = InMemoryWebDavCredentialsStore(
            account: account,
            identity: identity
        )
        let currentData = try deviceHeartbeatData(
            identity: identity,
            deviceId: identity.deviceId,
            name: "MacBook Pro",
            platform: .macos,
            lastSeenAt: 2_000
        )
        let otherData = try deviceHeartbeatData(
            identity: identity,
            deviceId: "device-android-02",
            name: "Pixel",
            platform: .android,
            lastSeenAt: 3_000
        )
        WebDavTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch request.httpMethod {
            case "PROPFIND":
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus([
                        "v1/personal-vault/devices/\(identity.deviceId).json",
                        "v1/personal-vault/devices/device-android-02.json",
                    ]).utf8)
                )
            case "GET":
                let data = path.hasSuffix("device-android-02.json")
                    ? otherData
                    : currentData
                return (try makeWebDavTestResponse(request, status: 200), data)
            default:
                return (try makeWebDavTestResponse(request, status: 201), Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentials,
            defaults: defaults,
            clientFactory: { account, identity in
                try WebDavClient(
                    account: account,
                    identity: identity,
                    session: session,
                    retryDelaysNanoseconds: [],
                    retrySleep: { _ in }
                )
            }
        )
        defer {
            store.stop()
            WebDavTestURLProtocol.handler = nil
        }

        await store.refreshDevices()

        #expect(store.devices.map(\.id) == ["device-android-02", identity.deviceId])
        #expect(store.devices.map(\.name) == ["Pixel", "MacBook Pro"])
        #expect(store.devices.map(\.isCurrent) == [false, true])
        #expect(store.devicesErrorMessage == nil)
    }

    private func waitForHeartbeatWrite(
        _ recorder: DeviceHeartbeatRecorder,
        minimumCount: Int = 1,
        timeout: TimeInterval = 3
    ) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = recorder.latestHeartbeat,
               recorder.heartbeatWrites.count >= minimumCount {
                return data
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(recorder.latestHeartbeat)
    }

    private func deviceHeartbeatData(
        identity: WebDavIdentity,
        deviceId: String,
        name: String,
        platform: DevicePlatform,
        lastSeenAt: Int64
    ) throws -> Data {
        let heartbeat = try WebDavDeviceHeartbeat(
            name: name,
            platform: platform,
            lastSeenAt: lastSeenAt,
            appVersion: "0.2.23"
        )
        let envelope = try WebDavDeviceHeartbeatCodec.seal(
            heartbeat,
            vaultId: identity.vaultId,
            deviceId: deviceId,
            vaultKey: identity.vaultKey
        )
        return try JSONEncoder().encode(envelope)
    }

    private func makeFixture(
        withSavedAccount: Bool = true,
        identity: WebDavIdentity? = nil,
        credentialsStore suppliedStore: (any WebDavCredentialsStoring)? = nil,
        pollInterval: TimeInterval = WebDavPairingProtocol.pollIntervalSeconds,
        repository suppliedRepository: SQLiteTaskRepository? = nil,
        now: (() -> Date)? = nil
    ) throws -> Fixture {
        let suite = "woo-todo-webdav-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let repository = try suppliedRepository ?? SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = suppliedStore ?? InMemoryWebDavCredentialsStore()
        let account = WebDavAccount(
            endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
            username: "user@example.com",
            appPassword: "application-password"
        )
        if withSavedAccount {
            try credentialsStore.saveAccount(account)
        }
        if let identity {
            try credentialsStore.saveIdentity(identity)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clientFactory: SyncSettingsStore.ClientFactory = { account, identity in
            try WebDavClient(
                account: account,
                identity: identity,
                session: session,
                retryDelaysNanoseconds: [],
                retrySleep: { _ in }
            )
        }
        WebDavTestURLProtocol.handler = { request in
            switch request.httpMethod {
            case "PROPFIND":
                let body = """
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:"></D:multistatus>
                """
                return (try makeWebDavTestResponse(request, status: 207), Data(body.utf8))
            case "MKCOL":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "PUT":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "DELETE":
                return (try makeWebDavTestResponse(request, status: 204), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 200), Data())
            }
        }
        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            defaults: defaults,
            pollInterval: pollInterval,
            clientFactory: clientFactory,
            now: now ?? { Date() }
        )
        return Fixture(
            suite: suite,
            defaults: defaults,
            repository: repository,
            credentialsStore: credentialsStore,
            store: store,
            clientFactory: clientFactory
        )
    }

    private func makeIdentity() throws -> WebDavIdentity {
        WebDavIdentity(
            vaultId: "vault-test",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 7, count: 32)
        )
    }

    private func makeInvite() throws -> WebDavInvite {
        try WebDavInvite(
            account: WebDavAccount(
                endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
                username: "invite@example.com",
                appPassword: "invite-password"
            ),
            vaultId: "vault-invite",
            vaultKey: Data(repeating: 9, count: 32),
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(WebDavInvite.ttl)
        )
    }

    private func makePathAOffer(
        code: String,
        vaultId: String,
        deviceName: String = "Mac A",
        pairingId: String = "pairing-\(UUID().uuidString.lowercased())",
        expiresInMilliseconds: Int64 = WebDavPairingProtocol.ttlMilliseconds,
        now: Date = Date()
    ) throws -> (
        offer: WebDavPairingOffer,
        keyPair: PairingKeyPair,
        pairingSecret: Data
    ) {
        let keyPair = try PairingKeyPair.generate()
        let pairingSecret = try SecureRandom.bytes(count: 32)
        let createdAt = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let offer = WebDavPairingOffer(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: createdAt + expiresInMilliseconds,
            code: code,
            publicKey: keyPair.publicKeyBase64URL,
            pairingSecret: Base64URL.encode(pairingSecret),
            vaultId: vaultId,
            deviceName: deviceName,
            platform: .macos
        )
        return (offer, keyPair, pairingSecret)
    }

    private func install(
        offer: WebDavPairingOffer,
        in server: PairingFlowServer
    ) throws {
        server.put(
            name: WebDavPairingFileName(
                kind: .offer,
                code: offer.code,
                pairingId: offer.pairingId
            ).string,
            data: try WebDavPairingFileCodec.encode(.offer(offer))
        )
    }

    private func waitForClaim(
        _ server: PairingFlowServer,
        timeout: TimeInterval = 3
    ) async throws -> WebDavPairingClaim {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = server.claimData,
               case let .claim(claim) = try WebDavPairingFileCodec.decode(data) {
                return claim
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let data = server.claimData,
              case let .claim(claim) = try WebDavPairingFileCodec.decode(data) else {
            throw SyncSettingsTestError.claimNotWritten
        }
        return claim
    }

    private func approve(
        claim: WebDavPairingClaim,
        offerInfo: (
            offer: WebDavPairingOffer,
            keyPair: PairingKeyPair,
            pairingSecret: Data
        ),
        vaultKey: Data,
        in server: PairingFlowServer,
        now: Date = Date()
    ) throws {
        let sessionKey = try offerInfo.keyPair.sessionKey(
            peerPublicKey: Base64URL.decode(claim.publicKey),
            pairingId: offerInfo.offer.pairingId,
            pairingSecret: offerInfo.pairingSecret
        )
        let createdAt = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        let approval = WebDavPairingApproval(
            pairingId: offerInfo.offer.pairingId,
            createdAt: createdAt,
            expiresAt: createdAt + WebDavPairingProtocol.ttlMilliseconds,
            deviceId: claim.deviceId,
            vaultId: offerInfo.offer.vaultId,
            vaultKeyEnvelope: WebDavPairingEnvelope(
                try PairingSessionCrypto.sealVaultKey(
                    vaultKey,
                    sessionKey: sessionKey,
                    pairingId: offerInfo.offer.pairingId,
                    claimedDeviceId: claim.deviceId
                )
            ),
            initiatorPublicKey: offerInfo.offer.publicKey
        )
        server.put(
            name: WebDavPairingFileName(
                kind: .approval,
                code: nil,
                pairingId: offerInfo.offer.pairingId
            ).string,
            data: try WebDavPairingFileCodec.encode(.approval(approval))
        )
    }

    private func clearLocalDataPrompt(
        taskCount: Int = 0,
        trashCount: Int = 0,
        customCategoryCount: Int = 0,
        deferredChangeCount: Int = 0
    ) -> JoinPolicyPrompt {
        .clearLocalData(JoinLocalDataSummary(
            taskCount: taskCount,
            trashCount: trashCount,
            customCategoryCount: customCategoryCount,
            deferredChangeCount: deferredChangeCount
        ))
    }

    private func waitFor(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let repository: SQLiteTaskRepository
        let credentialsStore: any WebDavCredentialsStoring
        let store: SyncSettingsStore
        let clientFactory: SyncSettingsStore.ClientFactory

        @MainActor
        func cleanup() {
            store.stop()
            WebDavTestURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private final class DeviceHeartbeatRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var puts: [Data] = []
    private var deletes: [String] = []

    var heartbeatWrites: [Data] {
        lock.withLock { puts }
    }

    var latestHeartbeat: Data? {
        lock.withLock { puts.last }
    }

    var deletedPaths: [String] {
        lock.withLock { deletes }
    }

    func recordPut(body: Data) {
        lock.withLock { puts.append(body) }
    }

    func recordDelete(path: String) {
        lock.withLock { deletes.append(path) }
    }
}

private final class DeviceHeartbeatFirstAttemptFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var attempted = false

    func consumeFailure() -> Bool {
        lock.withLock {
            guard !attempted else { return false }
            attempted = true
            return true
        }
    }
}

private func webDavMultistatus(_ hrefs: [String]) -> String {
    var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        + "<D:multistatus xmlns:D=\"DAV:\">"
    for href in hrefs {
        body += "<D:response><D:href>\(href)</D:href></D:response>"
    }
    body += "</D:multistatus>"
    return body
}

private final class PairingListCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class PairingFlowServer: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var storedClaim: Data?

    var claimData: Data? {
        lock.withLock { storedClaim }
    }

    var fileNames: [String] {
        lock.withLock { objects.keys.sorted() }
    }

    func data(named name: String) -> Data? {
        lock.withLock { objects[name] }
    }

    func put(name: String, data: Data) {
        lock.withLock {
            objects[name] = data
            if name.hasPrefix("claim-") {
                storedClaim = data
            }
        }
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        if method == "MKCOL" {
            return (try makeWebDavTestResponse(request, status: 201), Data())
        }
        if path.contains("/v1/pairing") {
            let name = String(path.split(separator: "/").last ?? "")
            switch method {
            case "PROPFIND":
                let hrefs = lock.withLock {
                    objects.keys.sorted().map { "v1/pairing/\($0)" }
                }
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus(hrefs).utf8)
                )
            case "GET":
                guard let data = lock.withLock({ objects[name] }) else {
                    return (try makeWebDavTestResponse(request, status: 404), Data())
                }
                return (try makeWebDavTestResponse(request, status: 200), data)
            case "PUT":
                let body = requestBody(request)
                let existing = lock.withLock { objects[name] }
                if let existing, existing != body {
                    return (try makeWebDavTestResponse(request, status: 412), Data())
                }
                put(name: name, data: body)
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "DELETE":
                lock.withLock { objects[name] = nil }
                return (try makeWebDavTestResponse(request, status: 204), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 405), Data())
            }
        }
        if method == "PROPFIND" {
            return (
                try makeWebDavTestResponse(request, status: 207),
                Data(webDavMultistatus([]).utf8)
            )
        }
        if method == "PUT" {
            // 非配对 PUT 用于同步 outbox 与设备心跳；接受后便于验证 runner 仍可用。
            return (try makeWebDavTestResponse(request, status: 201), Data())
        }
        return (try makeWebDavTestResponse(request, status: 405), Data())
    }
}

private enum SyncSettingsTestError: Error {
    case claimNotWritten
    case identitySaveFailed
    case identityDeleteFailed
}

/// 模拟 Keychain 保存身份失败，用于验证自动加入失败后的回滚。
private final class FailingIdentitySaveStore: WebDavCredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var account: WebDavAccount?

    func saveAccount(_ account: WebDavAccount) throws {
        try account.validate()
        lock.withLock { self.account = account }
    }

    func loadAccount() throws -> WebDavAccount? {
        lock.withLock { account }
    }

    func deleteAccount() throws {
        lock.withLock { account = nil }
    }

    func saveIdentity(_ identity: WebDavIdentity) throws {
        throw SyncSettingsTestError.identitySaveFailed
    }

    func loadIdentity() throws -> WebDavIdentity? {
        nil
    }

    func deleteIdentity() throws {}
}

/// 模拟清空本机数据时 Keychain 删除身份失败，用于验证不会继续保存新身份。
private final class FailingIdentityDeleteStore: WebDavCredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var account: WebDavAccount?
    private var identity: WebDavIdentity?
    private var saveIdentityCalls = 0

    var saveIdentityCount: Int {
        lock.withLock { saveIdentityCalls }
    }

    func saveAccount(_ account: WebDavAccount) throws {
        try account.validate()
        lock.withLock { self.account = account }
    }

    func loadAccount() throws -> WebDavAccount? {
        lock.withLock { account }
    }

    func deleteAccount() throws {
        lock.withLock { account = nil }
    }

    func saveIdentity(_ identity: WebDavIdentity) throws {
        try identity.validate()
        lock.withLock {
            self.identity = identity
            saveIdentityCalls += 1
        }
    }

    func loadIdentity() throws -> WebDavIdentity? {
        lock.withLock { identity }
    }

    func deleteIdentity() throws {
        throw SyncSettingsTestError.identityDeleteFailed
    }
}

/// 记录保存身份次数，用于验证清空失败后没有 adopt 新身份。
private final class RecordingCredentialsStore: WebDavCredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let base = InMemoryWebDavCredentialsStore()
    private var saveIdentityCalls = 0

    var saveIdentityCount: Int {
        lock.withLock { saveIdentityCalls }
    }

    func saveAccount(_ account: WebDavAccount) throws {
        try base.saveAccount(account)
    }

    func loadAccount() throws -> WebDavAccount? {
        try base.loadAccount()
    }

    func deleteAccount() throws {
        try base.deleteAccount()
    }

    func saveIdentity(_ identity: WebDavIdentity) throws {
        try base.saveIdentity(identity)
        lock.withLock { saveIdentityCalls += 1 }
    }

    func loadIdentity() throws -> WebDavIdentity? {
        try base.loadIdentity()
    }

    func deleteIdentity() throws {
        try base.deleteIdentity()
    }
}

/// 可推进的测试时钟，用于快速验证 Path B 配对码过期。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date()) {
        self.value = value
    }

    var now: Date {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

private func makeWebDavTestResponse(
    _ request: URLRequest,
    status: Int
) throws -> HTTPURLResponse {
    guard let url = request.url else {
        throw URLError(.badURL)
    }
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    ) else {
        throw URLError(.badServerResponse)
    }
    return response
}

private final class WebDavTestHandlerStorage: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private let lock = NSLock()
    private var value: Handler?

    func set(_ handler: Handler?) {
        lock.withLock { value = handler }
    }

    func get() -> Handler? {
        lock.withLock { value }
    }
}

private final class WebDavTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = WebDavTestHandlerStorage()

    static var handler: WebDavTestHandlerStorage.Handler? {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
