import Foundation
import Testing
@testable import WooTodoSync

@Suite("Path B Join 状态机")
struct JoinPairingStateMachineTests {
    private let approverPublicKey = Base64URL.encode(Data(repeating: 9, count: 32))
    private let creatorPublicKey = Base64URL.encode(Data(repeating: 8, count: 32))

    @Test("创建方：创建 → 等待 → 核对 → 批准")
    func creatorHappyPath() throws {
        var machine = JoinCreatorStateMachine()
        #expect(machine.phase == .idle)

        try machine.beginCreation()
        #expect(machine.phase == .creating)
        try machine.didCreate(makeCreateData())
        guard case let .waitingApproval(invitation) = machine.phase else {
            Issue.record("应进入等待批准")
            return
        }
        #expect(invitation.shortCode == "123456")
        #expect(invitation.deviceId == "device-join")

        try machine.didPoll(makeResult(status: .open))
        guard case .waitingApproval = machine.phase else {
            Issue.record("open 状态应继续等待")
            return
        }

        try machine.didPoll(
            makeResult(status: .resolved, approverPublicKey: approverPublicKey),
            verificationCode: "654321"
        )
        guard case let .awaitingConfirmation(verification) = machine.phase else {
            Issue.record("resolved 后应显示核对码")
            return
        }
        #expect(verification.code == "654321")

        try machine.didPoll(
            makeResult(
                status: .approved,
                vaultId: "vault-join",
                approverPublicKey: approverPublicKey,
                envelope: EncryptedEnvelope(ciphertext: "cipher", nonce: "nonce")
            ),
            verificationCode: "654321"
        )
        guard case .awaitingConfirmation = machine.phase else {
            Issue.record("approved 结果必须先经用户确认")
            return
        }
        #expect(machine.pendingApproval?.vaultId == "vault-join")
        let approval = try machine.confirmJoinCreation()
        #expect(approval.approverPublicKey == approverPublicKey)
        #expect(machine.phase == .approved(vaultId: "vault-join", deviceId: "device-join"))
    }

    @Test("创建方：approved 先到时先显示核对码，确认后才进入 approved")
    func creatorRequiresConfirmationForImmediateApproval() throws {
        var machine = JoinCreatorStateMachine()
        try machine.beginCreation()
        try machine.didCreate(makeCreateData())
        try machine.didPoll(
            makeResult(
                status: .approved,
                vaultId: "vault-join",
                approverPublicKey: approverPublicKey,
                envelope: EncryptedEnvelope(ciphertext: "cipher", nonce: "nonce")
            ),
            verificationCode: "654321"
        )
        guard case let .awaitingConfirmation(verification) = machine.phase else {
            Issue.record("approved 先到时应显示核对码并等待确认")
            return
        }
        #expect(verification.code == "654321")
        #expect(verification.approverPublicKey == approverPublicKey)
        #expect(machine.pendingApproval != nil)
        #expect(machine.phase != .approved(vaultId: "vault-join", deviceId: "device-join"))

        let approval = try machine.confirmJoinCreation()
        #expect(approval.deviceId == "device-join")
        #expect(machine.phase == .approved(vaultId: "vault-join", deviceId: "device-join"))
    }

    @Test("创建方：已显示核对码后 approved 公钥变化必须拒绝")
    func creatorRejectsChangedApproverKey() throws {
        var machine = JoinCreatorStateMachine()
        try machine.beginCreation()
        try machine.didCreate(makeCreateData())
        try machine.didPoll(
            makeResult(status: .resolved, approverPublicKey: approverPublicKey),
            verificationCode: "654321"
        )
        let otherApproverKey = Base64URL.encode(Data(repeating: 5, count: 32))
        #expect(throws: JoinPairingStateError.responseMismatch) {
            try machine.didPoll(
                makeResult(
                    status: .approved,
                    vaultId: "vault-join",
                    approverPublicKey: otherApproverKey,
                    envelope: EncryptedEnvelope(ciphertext: "cipher", nonce: "nonce")
                ),
                verificationCode: "654321"
            )
        }
        #expect(machine.pendingApproval == nil)
        #expect(throws: JoinPairingStateError.invalidTransition) {
            try machine.confirmJoinCreation()
        }
    }

    @Test("创建方：尚无 approved 结果时不能确认")
    func creatorCannotConfirmWithoutApproval() throws {
        var machine = JoinCreatorStateMachine()
        try machine.beginCreation()
        try machine.didCreate(makeCreateData())
        try machine.didPoll(
            makeResult(status: .resolved, approverPublicKey: approverPublicKey),
            verificationCode: "654321"
        )
        #expect(throws: JoinPairingStateError.invalidTransition) {
            try machine.confirmJoinCreation()
        }
    }

    @Test("创建方：拒绝不匹配的加入请求或设备身份")
    func creatorRejectsMismatch() throws {
        var machine = JoinCreatorStateMachine()
        try machine.beginCreation()
        try machine.didCreate(makeCreateData())

        #expect(throws: JoinPairingStateError.responseMismatch) {
            try machine.didPoll(makeResult(status: .open, joinRequestId: "other"))
        }
        #expect(throws: JoinPairingStateError.responseMismatch) {
            try machine.didPoll(makeResult(status: .open, deviceId: "other"))
        }
        #expect(throws: JoinPairingStateError.responseMismatch) {
            try machine.didPoll(
                makeResult(status: .approved, vaultId: "vault-join"),
                verificationCode: nil
            )
        }
        #expect(throws: JoinPairingStateError.responseMismatch) {
            try machine.didPoll(
                makeResult(status: .resolved),
                verificationCode: "12345"
            )
        }
    }

    @Test("创建方：过期、取消与失败状态可重试")
    func creatorTerminalStates() throws {
        var machine = JoinCreatorStateMachine()
        try machine.beginCreation()
        try machine.didCreate(makeCreateData())
        try machine.didPoll(makeResult(status: .expired))
        #expect(machine.phase == .expired)

        try machine.beginCreation()
        try machine.didCreate(makeCreateData())
        machine.cancel()
        #expect(machine.phase == .canceled)

        machine.fail("网络错误")
        #expect(machine.phase == .failed("网络错误"))
        machine.reset()
        #expect(machine.phase == .idle)
    }

    @Test("批准方：解析 → 核对 → 批准")
    func approverHappyPath() throws {
        var machine = JoinApproverStateMachine()
        try machine.beginResolving()
        #expect(machine.phase == .resolving)
        try machine.didResolve(
            ResolveJoinRequestData(
                joinRequestId: "join-1",
                joinPublicKey: creatorPublicKey,
                deviceId: "device-new",
                device: JoinDeviceRegistration(name: "新手机", platform: .android),
                approverPublicKey: approverPublicKey,
                expiresAt: 300_000,
                serverTime: 0
            ),
            verificationCode: "112233",
            expectedApproverPublicKey: approverPublicKey
        )
        guard case let .awaitingConfirmation(verification) = machine.phase else {
            Issue.record("应等待用户核对")
            return
        }
        #expect(verification.deviceName == "新手机")
        #expect(verification.code == "112233")

        let pending = try machine.beginApproval()
        #expect(machine.phase == .approving(verification))
        #expect(pending.deviceId == "device-new")
        #expect(throws: JoinPairingStateError.responseMismatch) {
            try machine.didApprove(ApproveJoinData(
                joinRequestId: "join-1",
                status: "approved",
                vaultId: "vault-join",
                deviceId: "device-other",
                expiresAt: 300_000
            ))
        }
        try machine.didApprove(ApproveJoinData(
            joinRequestId: "join-1",
            status: "approved",
            vaultId: "vault-join",
            deviceId: "device-new",
            expiresAt: 300_000
        ))
        #expect(machine.phase == .done(deviceId: "device-new"))
    }

    @Test("批准方：拒绝不匹配的批准方公钥与非法加入公钥")
    func approverRejectsMismatch() throws {
        var machine = JoinApproverStateMachine()
        try machine.beginResolving()
        #expect(throws: JoinPairingStateError.responseMismatch) {
            try machine.didResolve(
                makeResolve(approverPublicKey: "different"),
                verificationCode: "112233",
                expectedApproverPublicKey: approverPublicKey
            )
        }
        #expect(throws: JoinPairingStateError.responseMismatch) {
            try machine.didResolve(
                makeResolve(approverPublicKey: approverPublicKey, joinPublicKey: "short"),
                verificationCode: "112233",
                expectedApproverPublicKey: approverPublicKey
            )
        }
    }

    @Test("批准方：批准失败可回到等待核对状态")
    func approverCanRetryApproval() throws {
        var machine = JoinApproverStateMachine()
        try machine.beginResolving()
        try machine.didResolve(
            makeResolve(approverPublicKey: approverPublicKey),
            verificationCode: "112233",
            expectedApproverPublicKey: approverPublicKey
        )
        _ = try machine.beginApproval()
        try machine.cancelApproval()
        guard case .awaitingConfirmation = machine.phase else {
            Issue.record("应回到等待核对")
            return
        }
        machine.reset()
        #expect(machine.phase == .idle)
    }

    private func makeCreateData() -> CreateJoinRequestData {
        CreateJoinRequestData(
            joinRequestId: "join-1",
            joinSecret: Base64URL.encode(Data(repeating: 4, count: 32)),
            shortCode: "123456",
            deviceId: "device-join",
            expiresAt: 300_000,
            serverTime: 0
        )
    }

    private func makeResult(
        status: JoinRequestStatus,
        joinRequestId: String = "join-1",
        deviceId: String = "device-join",
        vaultId: String? = nil,
        approverPublicKey: String? = nil,
        envelope: EncryptedEnvelope? = nil
    ) -> JoinResultData {
        JoinResultData(
            joinRequestId: joinRequestId,
            status: status,
            deviceId: deviceId,
            vaultId: vaultId,
            approverPublicKey: approverPublicKey,
            vaultKeyEnvelope: envelope,
            expiresAt: 300_000,
            serverTime: 0
        )
    }

    private func makeResolve(
        approverPublicKey: String,
        joinPublicKey: String? = nil
    ) -> ResolveJoinRequestData {
        ResolveJoinRequestData(
            joinRequestId: "join-1",
            joinPublicKey: joinPublicKey ?? creatorPublicKey,
            deviceId: "device-new",
            device: JoinDeviceRegistration(name: "新手机", platform: .android),
            approverPublicKey: approverPublicKey,
            expiresAt: 300_000,
            serverTime: 0
        )
    }
}
