import Foundation
import Testing
@testable import WooTodoSync

@Suite("WebDAV 六位码配对")
struct WebDavPairingTests {
    private let identity = WebDavIdentity(
        vaultId: "vault-pairing",
        deviceId: "device-mac-a1",
        vaultKey: Data(repeating: 9, count: 32)
    )
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Path A：offer → claim → approval，核对码一致并自动解封 vaultKey")
    func pathAEndToEnd() async throws {
        let transport = InMemoryPairingTransport()
        let show = try await WebDavPathAShowSession.start(
            transport: transport,
            identity: identity,
            deviceName: "Mac A",
            now: now
        )
        #expect(WebDavPairingFileName.parse(
            WebDavPairingFileName(
                kind: .offer,
                code: show.code,
                pairingId: show.pairingId
            ).string
        ) != nil)

        let claim = try await WebDavPathAClaimSession.start(
            transport: transport,
            code: show.code,
            deviceName: "Mac B",
            now: now.addingTimeInterval(1)
        )

        let showState = try await show.poll(now: now.addingTimeInterval(2))
        guard case let .claimed(deviceId, deviceName, platform, code) = showState else {
            Issue.record("已有设备应看到 claim")
            return
        }
        #expect(deviceId == claim.deviceId)
        #expect(deviceName == "Mac B")
        #expect(platform == .macos)
        #expect(code == claim.verificationCode)

        try await show.approve(now: now.addingTimeInterval(3))

        let approved = try await claim.poll(now: now.addingTimeInterval(4))
        guard case let .approved(pendingIdentity) = approved else {
            Issue.record("approval 到达后应直接返回可保存身份")
            return
        }
        #expect(pendingIdentity.vaultId == identity.vaultId)
        #expect(pendingIdentity.deviceId == claim.deviceId)
        #expect(pendingIdentity.vaultKey == identity.vaultKey)
        #expect(claim.awaitingIdentity?.vaultId == identity.vaultId)
        // 返回身份时还未保存；调用方确认后才会删除配对文件。
        #expect(!(await transport.fileNames().isEmpty))

        let newIdentity = try await claim.confirm(now: now.addingTimeInterval(5))
        #expect(newIdentity.vaultId == identity.vaultId)
        #expect(newIdentity.deviceId == claim.deviceId)
        #expect(newIdentity.vaultKey == identity.vaultKey)
        #expect(await transport.fileNames().isEmpty)
    }

    @Test("Path A：预览 offer 只读，不写入 claim")
    func pathAPreviewDoesNotClaim() async throws {
        let transport = InMemoryPairingTransport()
        let show = try await WebDavPathAShowSession.start(
            transport: transport,
            identity: identity,
            deviceName: "Mac A",
            now: now
        )

        let preview = try await WebDavPathAClaimSession.previewOffer(
            transport: transport,
            code: show.code,
            now: now.addingTimeInterval(1)
        )

        #expect(preview.deviceName == "Mac A")
        #expect(preview.platform == .macos)
        #expect(preview.vaultId == identity.vaultId)
        #expect(await transport.fileNames() == [
            WebDavPairingFileName(
                kind: .offer,
                code: show.code,
                pairingId: show.pairingId
            ).string,
        ])
    }

    @Test("Path A：同一配对码已有 claim 时第二台设备冲突")
    func pathAClaimConflict() async throws {
        let transport = InMemoryPairingTransport()
        let show = try await WebDavPathAShowSession.start(
            transport: transport,
            identity: identity,
            deviceName: "Mac A",
            now: now
        )
        _ = try await WebDavPathAClaimSession.start(
            transport: transport,
            code: show.code,
            deviceName: "Mac B",
            now: now.addingTimeInterval(1)
        )

        await #expect(throws: WebDavPairingError.conflict) {
            _ = try await WebDavPathAClaimSession.start(
                transport: transport,
                code: show.code,
                deviceName: "Mac C",
                now: now.addingTimeInterval(2)
            )
        }
    }

    @Test("Path A：超过相对 TTL 后报告过期")
    func pathAExpiresAfterRelativeTTL() async throws {
        let transport = InMemoryPairingTransport()
        let show = try await WebDavPathAShowSession.start(
            transport: transport,
            identity: identity,
            deviceName: "Mac A",
            now: now
        )
        let claim = try await WebDavPathAClaimSession.start(
            transport: transport,
            code: show.code,
            deviceName: "Mac B",
            now: now.addingTimeInterval(1)
        )

        #expect(try await claim.poll(now: now.addingTimeInterval(302)) == .expired)
        #expect(try await show.poll(now: now.addingTimeInterval(302)) == .expired)
    }

    @Test("Path A：同一六位码多份 offer 时报冲突且不按时间戳择一")
    func pathAMultipleOffersConflict() async throws {
        let transport = InMemoryPairingTransport()
        let code = "123456"
        let older = try makeOffer(
            pairingId: "pairing-conflict-older",
            code: code,
            createdAt: milliseconds(now.addingTimeInterval(-1)),
            expiresAt: milliseconds(now.addingTimeInterval(299))
        )
        let newer = try makeOffer(
            pairingId: "pairing-conflict-newer",
            code: code,
            createdAt: milliseconds(now.addingTimeInterval(3_600)),
            expiresAt: milliseconds(now.addingTimeInterval(3_900))
        )
        try await transport.inject(
            name: WebDavPairingFileName(kind: .offer, code: code, pairingId: older.pairingId).string,
            data: WebDavPairingFileCodec.encode(.offer(older))
        )
        try await transport.inject(
            name: WebDavPairingFileName(kind: .offer, code: code, pairingId: newer.pairingId).string,
            data: WebDavPairingFileCodec.encode(.offer(newer))
        )

        await #expect(throws: WebDavPairingError.pairingCodeConflict) {
            _ = try await WebDavPathAClaimSession.start(
                transport: transport,
                code: code,
                deviceName: "Mac B",
                now: now
            )
        }
        #expect(await transport.fileNames().sorted() == [
            WebDavPairingFileName(kind: .offer, code: code, pairingId: newer.pairingId).string,
            WebDavPairingFileName(kind: .offer, code: code, pairingId: older.pairingId).string,
        ].sorted())
    }

    @Test("Path A：无法解码的 offer 只跳过，不影响唯一有效 offer")
    func pathASkipsUndecodableOffer() async throws {
        let transport = InMemoryPairingTransport()
        let code = "654321"
        let valid = try makeOffer(
            pairingId: "pairing-valid-only",
            code: code,
            createdAt: milliseconds(now),
            expiresAt: milliseconds(now.addingTimeInterval(300))
        )
        try await transport.inject(
            name: WebDavPairingFileName(kind: .offer, code: code, pairingId: valid.pairingId).string,
            data: WebDavPairingFileCodec.encode(.offer(valid))
        )
        try await transport.inject(
            name: WebDavPairingFileName(
                kind: .offer,
                code: code,
                pairingId: "pairing-broken-only"
            ).string,
            data: Data("{not-json".utf8)
        )

        let claim = try await WebDavPathAClaimSession.start(
            transport: transport,
            code: code,
            deviceName: "Mac B",
            now: now
        )
        #expect(claim.pairingId == valid.pairingId)
    }

    @Test("Path A：本地时钟偏移时使用相对 TTL")
    func pathAUsesRelativeTTLForClockSkew() async throws {
        let transport = InMemoryPairingTransport()
        let futureCode = "222222"
        let future = try makeOffer(
            pairingId: "pairing-future",
            code: futureCode,
            createdAt: milliseconds(now.addingTimeInterval(3_600)),
            expiresAt: milliseconds(now.addingTimeInterval(3_900))
        )
        try await transport.inject(
            name: WebDavPairingFileName(
                kind: .offer,
                code: futureCode,
                pairingId: future.pairingId
            ).string,
            data: WebDavPairingFileCodec.encode(.offer(future))
        )
        let futureClaim = try await WebDavPathAClaimSession.start(
            transport: transport,
            code: futureCode,
            deviceName: "Mac B",
            now: now
        )
        #expect(abs(futureClaim.deadline.timeIntervalSince(
            now.addingTimeInterval(300)
        )) < 1)

        let pastCode = "333333"
        let past = try makeOffer(
            pairingId: "pairing-past",
            code: pastCode,
            createdAt: milliseconds(now.addingTimeInterval(-3_600)),
            expiresAt: milliseconds(now.addingTimeInterval(-3_300))
        )
        try await transport.inject(
            name: WebDavPairingFileName(
                kind: .offer,
                code: pastCode,
                pairingId: past.pairingId
            ).string,
            data: WebDavPairingFileCodec.encode(.offer(past))
        )
        let pastClaim = try await WebDavPathAClaimSession.start(
            transport: transport,
            code: pastCode,
            deviceName: "Mac B",
            now: now
        )
        #expect(abs(pastClaim.deadline.timeIntervalSince(
            now.addingTimeInterval(300)
        )) < 1)
    }

    @Test("Path A：篡改 approval 密文无法解封 vaultKey")
    func pathATamperedApprovalIsRejected() async throws {
        let transport = InMemoryPairingTransport()
        let show = try await WebDavPathAShowSession.start(
            transport: transport,
            identity: identity,
            deviceName: "Mac A",
            now: now
        )
        let claim = try await WebDavPathAClaimSession.start(
            transport: transport,
            code: show.code,
            deviceName: "Mac B",
            now: now.addingTimeInterval(1)
        )
        _ = try await show.poll(now: now.addingTimeInterval(2))
        try await show.approve(now: now.addingTimeInterval(3))

        let approvalName = WebDavPairingFileName(
            kind: .approval,
            code: nil,
            pairingId: show.pairingId
        ).string
        let data = try await transport.readPairingFile(name: approvalName)
        guard case let .approval(approval) = try WebDavPairingFileCodec.decode(data) else {
            Issue.record("应读取 approval")
            return
        }
        let ciphertext = approval.vaultKeyEnvelope.ciphertext
        let tampered = WebDavPairingApproval(
            pairingId: approval.pairingId,
            createdAt: approval.createdAt,
            expiresAt: approval.expiresAt,
            deviceId: approval.deviceId,
            vaultId: approval.vaultId,
            vaultKeyEnvelope: WebDavPairingEnvelope(
                ciphertext: (ciphertext.first == "A" ? "B" : "A")
                    + String(ciphertext.dropFirst()),
                nonce: approval.vaultKeyEnvelope.nonce
            ),
            initiatorPublicKey: approval.initiatorPublicKey
        )
        try await transport.inject(
            name: approvalName,
            data: WebDavPairingFileCodec.encode(.approval(tampered))
        )

        await #expect(throws: (any Error).self) {
            _ = try await claim.poll(now: now.addingTimeInterval(4))
        }
    }

    @Test("Path B：join → resolve → approval，核对码一致并自动解封 vaultKey")
    func pathBEndToEnd() async throws {
        let transport = InMemoryPairingTransport()
        let create = try await WebDavPathBCreateSession.start(
            transport: transport,
            deviceName: "Mac B",
            now: now
        )
        let approve = try await WebDavPathBApproveSession.start(
            transport: transport,
            code: create.code,
            vaultId: identity.vaultId,
            vaultKey: identity.vaultKey,
            approverDeviceId: identity.deviceId,
            approverName: "Mac A",
            now: now.addingTimeInterval(1)
        )
        #expect(approve.verificationCode.count == 6)

        let verification = try await create.poll(now: now.addingTimeInterval(2))
        guard case let .verification(deviceName, code) = verification else {
            Issue.record("新设备应显示核对码")
            return
        }
        #expect(deviceName == "Mac A")
        #expect(code == approve.verificationCode)

        try await approve.approve(now: now.addingTimeInterval(3))

        let approved = try await create.poll(now: now.addingTimeInterval(4))
        guard case let .approved(pendingIdentity) = approved else {
            Issue.record("approval 到达后应直接返回可保存身份")
            return
        }
        #expect(pendingIdentity.vaultId == identity.vaultId)
        #expect(pendingIdentity.deviceId == create.deviceId)
        #expect(pendingIdentity.vaultKey == identity.vaultKey)
        #expect(create.awaitingIdentity?.vaultId == identity.vaultId)
        // 返回身份时还未保存；调用方确认后才会删除配对文件。
        #expect(!(await transport.fileNames().isEmpty))

        let newIdentity = try await create.confirm(now: now.addingTimeInterval(5))
        #expect(newIdentity.vaultId == identity.vaultId)
        #expect(newIdentity.deviceId == create.deviceId)
        #expect(newIdentity.vaultKey == identity.vaultKey)
        #expect(await transport.fileNames().isEmpty)
    }

    @Test("Path B：同一 join 已有 resolve 时第二台批准设备冲突")
    func pathBResolveConflict() async throws {
        let transport = InMemoryPairingTransport()
        let create = try await WebDavPathBCreateSession.start(
            transport: transport,
            deviceName: "Mac B",
            now: now
        )
        _ = try await WebDavPathBApproveSession.start(
            transport: transport,
            code: create.code,
            vaultId: identity.vaultId,
            vaultKey: identity.vaultKey,
            approverDeviceId: identity.deviceId,
            approverName: "Mac A",
            now: now.addingTimeInterval(1)
        )
        await #expect(throws: WebDavPairingError.conflict) {
            _ = try await WebDavPathBApproveSession.start(
                transport: transport,
                code: create.code,
                vaultId: "vault-other",
                vaultKey: Data(repeating: 2, count: 32),
                approverDeviceId: "device-mac-c1",
                approverName: "Mac C",
                now: now.addingTimeInterval(2)
            )
        }
    }

    @Test("Path B：过期后不能批准，创建方报告过期")
    func pathBExpiresAfterTTL() async throws {
        let transport = InMemoryPairingTransport()
        let create = try await WebDavPathBCreateSession.start(
            transport: transport,
            deviceName: "Mac B",
            now: now
        )
        let approve = try await WebDavPathBApproveSession.start(
            transport: transport,
            code: create.code,
            vaultId: identity.vaultId,
            vaultKey: identity.vaultKey,
            approverDeviceId: identity.deviceId,
            approverName: "Mac A",
            now: now.addingTimeInterval(1)
        )

        await #expect(throws: WebDavPairingError.expired) {
            try await approve.approve(now: now.addingTimeInterval(302))
        }
        #expect(try await create.poll(now: now.addingTimeInterval(302)) == .expired)
    }

    @Test("Path B：只有 approval 没有 resolve 时被忽略且不解封")
    func pathBIgnoresApprovalWithoutResolve() async throws {
        let transport = InMemoryPairingTransport()
        let create = try await WebDavPathBCreateSession.start(
            transport: transport,
            deviceName: "Mac B",
            now: now
        )
        let attacker = try PairingKeyPair.generate()
        let approval = WebDavPairingApproval(
            pairingId: create.pairingId,
            createdAt: milliseconds(now.addingTimeInterval(1)),
            expiresAt: milliseconds(now.addingTimeInterval(301)),
            deviceId: create.deviceId,
            vaultId: "vault-attacker",
            vaultKeyEnvelope: WebDavPairingEnvelope(
                ciphertext: Base64URL.encode(Data(repeating: 1, count: 48)),
                nonce: Base64URL.encode(Data(repeating: 2, count: 12))
            ),
            initiatorPublicKey: create.publicKeyBase64URL,
            approverPublicKey: attacker.publicKeyBase64URL
        )
        try await transport.inject(
            name: WebDavPairingFileName(
                kind: .approval,
                code: nil,
                pairingId: create.pairingId
            ).string,
            data: WebDavPairingFileCodec.encode(.approval(approval))
        )

        let state = try await create.poll(now: now.addingTimeInterval(2))
        #expect(state == .waiting)
        #expect(create.awaitingIdentity == nil)
        #expect(await transport.fileNames().contains(
            WebDavPairingFileName(
                kind: .join,
                code: create.code,
                pairingId: create.pairingId
            ).string
        ))
    }

    @Test("Path B：approval 的 approverPublicKey 必须与 resolve 一致")
    func pathBApprovalKeyMustMatchResolve() async throws {
        let transport = InMemoryPairingTransport()
        let create = try await WebDavPathBCreateSession.start(
            transport: transport,
            deviceName: "Mac B",
            now: now
        )
        _ = try await WebDavPathBApproveSession.start(
            transport: transport,
            code: create.code,
            vaultId: identity.vaultId,
            vaultKey: identity.vaultKey,
            approverDeviceId: identity.deviceId,
            approverName: "Mac A",
            now: now.addingTimeInterval(1)
        )
        let verification = try await create.poll(now: now.addingTimeInterval(2))
        guard case .verification = verification else {
            Issue.record("应先显示核对码")
            return
        }

        let attacker = try PairingKeyPair.generate()
        let forged = WebDavPairingApproval(
            pairingId: create.pairingId,
            createdAt: milliseconds(now.addingTimeInterval(3)),
            expiresAt: milliseconds(now.addingTimeInterval(303)),
            deviceId: create.deviceId,
            vaultId: identity.vaultId,
            vaultKeyEnvelope: WebDavPairingEnvelope(
                ciphertext: Base64URL.encode(Data(repeating: 3, count: 48)),
                nonce: Base64URL.encode(Data(repeating: 4, count: 12))
            ),
            initiatorPublicKey: create.publicKeyBase64URL,
            approverPublicKey: attacker.publicKeyBase64URL
        )
        try await transport.inject(
            name: WebDavPairingFileName(
                kind: .approval,
                code: nil,
                pairingId: create.pairingId
            ).string,
            data: WebDavPairingFileCodec.encode(.approval(forged))
        )

        await #expect(throws: WebDavPairingError.responseMismatch) {
            _ = try await create.poll(now: now.addingTimeInterval(4))
        }
        #expect(create.awaitingIdentity == nil)
    }

    @Test("Path B：同一六位码多份 join 时报冲突")
    func pathBMultipleJoinsConflict() async throws {
        let transport = InMemoryPairingTransport()
        let code = "135790"
        let first = try makeJoin(
            pairingId: "pairing-join-conflict-a",
            code: code,
            deviceId: "device-mac-b1",
            createdAt: milliseconds(now),
            expiresAt: milliseconds(now.addingTimeInterval(300))
        )
        let second = try makeJoin(
            pairingId: "pairing-join-conflict-b",
            code: code,
            deviceId: "device-mac-c1",
            createdAt: milliseconds(now.addingTimeInterval(60)),
            expiresAt: milliseconds(now.addingTimeInterval(360))
        )
        try await transport.inject(
            name: WebDavPairingFileName(kind: .join, code: code, pairingId: first.pairingId).string,
            data: WebDavPairingFileCodec.encode(.join(first))
        )
        try await transport.inject(
            name: WebDavPairingFileName(kind: .join, code: code, pairingId: second.pairingId).string,
            data: WebDavPairingFileCodec.encode(.join(second))
        )

        await #expect(throws: WebDavPairingError.pairingCodeConflict) {
            _ = try await WebDavPathBApproveSession.start(
                transport: transport,
                code: code,
                vaultId: identity.vaultId,
                vaultKey: identity.vaultKey,
                approverDeviceId: identity.deviceId,
                approverName: "Mac A",
                now: now
            )
        }
        // 冲突时不写 resolve，避免误批准任意一方。
        #expect(await transport.fileNames().sorted() == [
            WebDavPairingFileName(kind: .join, code: code, pairingId: first.pairingId).string,
            WebDavPairingFileName(kind: .join, code: code, pairingId: second.pairingId).string,
        ])
    }

    @Test("Path B：对端时钟落后时使用相对 TTL 仍能完成配对")
    func pathBUsesRelativeTTLForClockSkew() async throws {
        let transport = InMemoryPairingTransport()
        let create = try await WebDavPathBCreateSession.start(
            transport: transport,
            deviceName: "Mac B",
            now: now
        )
        // 模拟对端时钟比本机慢一小时：join 的时间戳整体落在过去。
        let joinName = WebDavPairingFileName(
            kind: .join,
            code: create.code,
            pairingId: create.pairingId
        ).string
        let data = try await transport.readPairingFile(name: joinName)
        guard case let .join(join) = try WebDavPairingFileCodec.decode(data) else {
            Issue.record("应读取 join")
            return
        }
        let skewedJoin = WebDavPairingJoin(
            pairingId: join.pairingId,
            createdAt: milliseconds(now.addingTimeInterval(-3_600)),
            expiresAt: milliseconds(now.addingTimeInterval(-3_300)),
            code: join.code,
            publicKey: join.publicKey,
            deviceId: join.deviceId,
            deviceName: join.deviceName,
            platform: join.platform
        )
        try await transport.inject(
            name: joinName,
            data: WebDavPairingFileCodec.encode(.join(skewedJoin))
        )

        let approve = try await WebDavPathBApproveSession.start(
            transport: transport,
            code: create.code,
            vaultId: identity.vaultId,
            vaultKey: identity.vaultKey,
            approverDeviceId: identity.deviceId,
            approverName: "Mac A",
            now: now
        )
        try await approve.approve(now: now.addingTimeInterval(1))

        let approved = try await create.poll(now: now.addingTimeInterval(2))
        guard case let .approved(pendingIdentity) = approved else {
            Issue.record("时钟偏移不应阻止配对")
            return
        }
        #expect(pendingIdentity.vaultId == identity.vaultId)
        #expect(try await create.confirm(now: now.addingTimeInterval(3)).vaultId == identity.vaultId)
    }

    @Test("Path A：对端 approval 时间戳偏旧时仍按本机观察时间接受")
    func pathAUsesRelativeTTLForApprovalClockSkew() async throws {
        let transport = InMemoryPairingTransport()
        let show = try await WebDavPathAShowSession.start(
            transport: transport,
            identity: identity,
            deviceName: "Mac A",
            now: now.addingTimeInterval(-3_600)
        )
        let claim = try await WebDavPathAClaimSession.start(
            transport: transport,
            code: show.code,
            deviceName: "Mac B",
            now: now
        )
        _ = try await show.poll(now: now.addingTimeInterval(-3_599))
        // 已有设备使用自己（落后一小时）的时钟写入 approval。
        try await show.approve(now: now.addingTimeInterval(-3_598))

        let approved = try await claim.poll(now: now.addingTimeInterval(1))
        guard case let .approved(pendingIdentity) = approved else {
            Issue.record("时钟偏移不应阻止读取 approval")
            return
        }
        #expect(pendingIdentity.vaultId == identity.vaultId)
        #expect(try await claim.confirm(now: now.addingTimeInterval(2)).vaultId == identity.vaultId)
    }

    @Test("清理：只删除本机已观察且超过相对 TTL 的文件")
    func cleanupOnlyDeletesObservedExpiredFiles() async throws {
        let transport = InMemoryPairingTransport()
        let code = "246802"
        let offer = try makeOffer(
            pairingId: "pairing-cleanup-offer",
            code: code,
            createdAt: milliseconds(now),
            expiresAt: milliseconds(now.addingTimeInterval(300))
        )
        let name = WebDavPairingFileName(
            kind: .offer,
            code: code,
            pairingId: offer.pairingId
        ).string
        try await transport.inject(
            name: name,
            data: WebDavPairingFileCodec.encode(.offer(offer))
        )

        // 第一次观察只记录起点，不删除。
        await transport.cleanupExpiredPairingFiles(now: now)
        #expect(await transport.fileNames().contains(name))

        // 相对 TTL 到期后才删除。
        await transport.cleanupExpiredPairingFiles(
            now: now.addingTimeInterval(301)
        )
        #expect(!(await transport.fileNames().contains(name)))
    }

    @Test("清理：未知协议版本与无法解码的文件只跳过不删除")
    func cleanupSkipsUndecodableAndUnknownVersionFiles() async throws {
        let transport = InMemoryPairingTransport()
        let unknownName = WebDavPairingFileName(
            kind: .offer,
            code: "246803",
            pairingId: "pairing-cleanup-unknown"
        ).string
        let brokenName = WebDavPairingFileName(
            kind: .offer,
            code: "246804",
            pairingId: "pairing-cleanup-broken"
        ).string
        let offer = try makeOffer(
            pairingId: "pairing-cleanup-unknown",
            code: "246803",
            createdAt: milliseconds(now),
            expiresAt: milliseconds(now.addingTimeInterval(300))
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: WebDavPairingFileCodec.encode(.offer(offer))
            ) as? [String: Any]
        )
        object["protocolVersion"] = 2
        try await transport.inject(
            name: unknownName,
            data: try JSONSerialization.data(withJSONObject: object)
        )
        try await transport.inject(name: brokenName, data: Data("{broken".utf8))

        await transport.cleanupExpiredPairingFiles(now: now)
        await transport.cleanupExpiredPairingFiles(
            now: now.addingTimeInterval(10_000)
        )

        #expect(await transport.fileNames().contains(unknownName))
        #expect(await transport.fileNames().contains(brokenName))
    }

    @Test("配对文件拒绝未知字段")
    func pairingFileRejectsUnknownFields() throws {
        let join = try makeJoin(
            pairingId: "pairing-join-01",
            code: "444444",
            deviceId: "device-mac-b1",
            createdAt: milliseconds(now),
            expiresAt: milliseconds(now.addingTimeInterval(300))
        )
        let data = try WebDavPairingFileCodec.encode(.join(join))
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["unexpected"] = true
        let tampered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: WebDavPairingError.self) {
            _ = try WebDavPairingFileCodec.decode(tampered)
        }
    }

    @Test("approval 必须包含 initiatorPublicKey，approverPublicKey 可选")
    func approvalRequiresInitiatorPublicKey() throws {
        let key = try PairingKeyPair.generate()
        let envelope = WebDavPairingEnvelope(
            ciphertext: Base64URL.encode(Data(repeating: 1, count: 48)),
            nonce: Base64URL.encode(Data(repeating: 2, count: 12))
        )
        let base: [String: Any] = [
            "format": WebDavPairingProtocol.format,
            "protocolVersion": WebDavPairingProtocol.protocolVersion,
            "kind": "approval",
            "pairingId": "pairing-approval-01",
            "createdAt": milliseconds(now),
            "expiresAt": milliseconds(now.addingTimeInterval(300)),
            "deviceId": "device-mac-b1",
            "vaultId": "vault-pairing",
            "vaultKeyEnvelope": [
                "ciphertext": envelope.ciphertext,
                "nonce": envelope.nonce,
            ],
        ]
        let withoutInitiator = try JSONSerialization.data(withJSONObject: base)
        #expect(throws: WebDavPairingError.self) {
            _ = try WebDavPairingFileCodec.decode(withoutInitiator)
        }

        var withInitiator = base
        withInitiator["initiatorPublicKey"] = key.publicKeyBase64URL
        let initiatorOnly = try JSONSerialization.data(withJSONObject: withInitiator)
        guard case let .approval(pathA) = try WebDavPairingFileCodec.decode(initiatorOnly) else {
            Issue.record("Path A approval 应可解码")
            return
        }
        #expect(pathA.approverPublicKey == nil)

        withInitiator["approverPublicKey"] = key.publicKeyBase64URL
        let bothData = try JSONSerialization.data(withJSONObject: withInitiator)
        guard case let .approval(pathB) = try WebDavPairingFileCodec.decode(bothData) else {
            Issue.record("Path B approval 应可解码")
            return
        }
        #expect(pathB.approverPublicKey == key.publicKeyBase64URL)
    }

    @Test("共享配对 fixtures 全部可严格解码")
    func sharedPairingFixturesDecode() throws {
        for name in ["offer", "claim", "join", "resolve", "approval"] {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("shared")
                .appendingPathComponent("fixtures")
                .appendingPathComponent("webdav-pairing-\(name).json")
            let file = try WebDavPairingFileCodec.decode(Data(contentsOf: url))
            #expect(file.kind.rawValue == name)
        }
    }

    @Test("取消配对会尽力删除本机写入的配对文件")
    func cancelCleansOwnFiles() async throws {
        let showTransport = InMemoryPairingTransport()
        let show = try await WebDavPathAShowSession.start(
            transport: showTransport,
            identity: identity,
            deviceName: "Mac A",
            now: now
        )
        await show.cancel()
        #expect(await showTransport.fileNames().isEmpty)

        let joinTransport = InMemoryPairingTransport()
        let create = try await WebDavPathBCreateSession.start(
            transport: joinTransport,
            deviceName: "Mac B",
            now: now
        )
        await create.cancel()
        #expect(await joinTransport.fileNames().isEmpty)
    }

    @Test("配对码必须为六位数字")
    func rejectsInvalidCode() async {
        let transport = InMemoryPairingTransport()
        await #expect(throws: WebDavPairingError.invalidCode) {
            _ = try await WebDavPathAClaimSession.start(
                transport: transport,
                code: "12345",
                deviceName: "Mac B"
            )
        }
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private func makeOffer(
        pairingId: String,
        code: String,
        createdAt: Int64,
        expiresAt: Int64
    ) throws -> WebDavPairingOffer {
        let keyPair = try PairingKeyPair.generate()
        return WebDavPairingOffer(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            code: code,
            publicKey: keyPair.publicKeyBase64URL,
            pairingSecret: Base64URL.encode(try SecureRandom.bytes(count: 32)),
            vaultId: identity.vaultId,
            deviceName: "Mac A",
            platform: .macos
        )
    }

    private func makeJoin(
        pairingId: String,
        code: String,
        deviceId: String,
        createdAt: Int64,
        expiresAt: Int64
    ) throws -> WebDavPairingJoin {
        let keyPair = try PairingKeyPair.generate()
        return WebDavPairingJoin(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            code: code,
            publicKey: keyPair.publicKeyBase64URL,
            deviceId: deviceId,
            deviceName: "Mac B",
            platform: .macos
        )
    }
}

private actor InMemoryPairingTransport: WebDavPairingFileTransport {
    private var files: [String: Data] = [:]

    func fileNames() -> [String] {
        files.keys.sorted()
    }

    func inject(name: String, data: Data) {
        files[name] = data
    }

    func ensurePairingDirectory() async throws {}

    func listPairingFileNames() async throws -> [String] {
        files.keys.sorted()
    }

    func readPairingFile(name: String) async throws -> Data {
        guard let data = files[name] else {
            throw WebDavError.http(404)
        }
        return data
    }

    func writePairingFile(name: String, data: Data) async throws {
        if let existing = files[name], existing != data {
            throw WebDavError.objectConflict(name)
        }
        files[name] = data
    }

    func deletePairingFile(name: String) async throws {
        files[name] = nil
    }
}
