import Foundation
import Testing
@testable import WooTodoSync

@Suite("同步运行时状态机")
struct SyncRuntimeStateTests {
    @Test("未配置时忽略触发，运行中请求合并为一次")
    func coalescesTriggers() {
        var machine = SyncRuntimeStateMachine(isConfigured: false)
        #expect(!machine.request(.launch))

        machine.setConfigured(true)
        #expect(machine.request(.launch))
        #expect(!machine.request(.localChange))
        #expect(!machine.request(.manual))
        #expect(machine.snapshot.hasPendingRun)

        let successAt = Date(timeIntervalSince1970: 100)
        #expect(machine.succeed(at: successAt) == .manual)
        #expect(machine.snapshot.isRunning)
        #expect(!machine.snapshot.hasPendingRun)
        #expect(machine.succeed(at: Date(timeIntervalSince1970: 101)) == nil)
        #expect(!machine.snapshot.isRunning)
        #expect(machine.snapshot.lastSuccessfulAt == Date(timeIntervalSince1970: 101))
    }

    @Test("失败保留上次成功时间且允许稍后重试")
    func failureDoesNotBlockRetry() {
        let previous = Date(timeIntervalSince1970: 80)
        var machine = SyncRuntimeStateMachine(
            isConfigured: true,
            lastSuccessfulAt: previous
        )
        #expect(machine.request(.wake))
        #expect(machine.fail(message: "网络不可用") == nil)
        #expect(machine.snapshot.lastSuccessfulAt == previous)
        #expect(machine.snapshot.lastErrorMessage == "网络不可用")
        #expect(machine.request(.networkRestored))
    }
}

@Suite("Mac 发起端配对状态机")
struct InitiatorPairingStateTests {
    @Test("二维码、认领、核对和确认按顺序推进")
    func completesPairing() throws {
        var machine = InitiatorPairingStateMachine()
        try machine.beginCreation()
        try machine.didCreate(makeCreatedPairing())

        let claim = PairingClaimInfo(
            deviceId: "android-device",
            name: "Galaxy S23 Ultra",
            platform: .android,
            publicKey: "claim-public-key",
            claimedAt: 1_000
        )
        try machine.didPoll(
            PairingStatusData(
                pairingId: "pair-1",
                status: .claimed,
                expiresAt: 600_000,
                claim: claim
            ),
            verificationCode: "042731"
        )
        let verification = try machine.beginConfirmation()
        #expect(verification.claimedDeviceId == "android-device")
        #expect(verification.code == "042731")

        try machine.didConfirm(PairingConfirmData(
            pairingId: "pair-1",
            status: .confirmed,
            deviceId: "android-device"
        ))
        #expect(machine.phase == .confirmed(deviceId: "android-device"))
    }

    @Test("跳过核对或使用错误响应会被拒绝")
    func rejectsInvalidTransitions() throws {
        var machine = InitiatorPairingStateMachine()
        #expect(throws: InitiatorPairingStateError.invalidTransition) {
            _ = try machine.beginConfirmation()
        }
        try machine.beginCreation()
        try machine.didCreate(makeCreatedPairing())
        #expect(throws: InitiatorPairingStateError.responseMismatch) {
            try machine.didPoll(PairingStatusData(
                pairingId: "another-pair",
                status: .open,
                expiresAt: 600_000,
                claim: nil
            ))
        }
    }

    private func makeCreatedPairing() -> CreatePairingData {
        CreatePairingData(
            pairingId: "pair-1",
            pairingSecret: "pairing-secret",
            initiatorPublicKey: "initiator-public-key",
            expiresAt: 600_000,
            serverTime: 0
        )
    }
}
