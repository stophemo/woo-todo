package com.wootodo.sync

enum class DevicePlatform(val wireValue: String) {
    MACOS("macos"),
    ANDROID("android");

    companion object {
        fun fromWire(value: String): DevicePlatform = entries.firstOrNull { it.wireValue == value }
            ?: throw IllegalArgumentException("不支持的平台：$value")
    }
}

enum class PairingStatus(val wireValue: String) {
    OPEN("open"),
    CLAIMED("claimed"),
    CONFIRMED("confirmed"),
    EXPIRED("expired"),
    CANCELED("canceled");

    companion object {
        fun fromWire(value: String): PairingStatus = entries.firstOrNull { it.wireValue == value }
            ?: throw IllegalArgumentException("不支持的配对状态：$value")
    }
}

enum class SyncOperationKind(val wireValue: String) {
    UPSERT("upsert"),
    DELETE("delete"),
    COMPLETE("complete"),
    PASS("pass"),
    REORDER("reorder");

    companion object {
        fun fromWire(value: String): SyncOperationKind = entries.firstOrNull { it.wireValue == value }
            ?: throw IllegalArgumentException("不支持的同步操作：$value")
    }
}

data class EncryptedEnvelope(
    val ciphertext: String,
    val nonce: String,
)

data class DeviceRegistration(
    val name: String,
    val platform: DevicePlatform,
    val publicKey: String? = null,
)

data class CreateVaultRequest(
    val device: DeviceRegistration,
    val recoveryEnvelope: EncryptedEnvelope? = null,
)

data class CreatedDevice(
    val id: String,
    val name: String,
    val platform: DevicePlatform,
    val token: String,
)

data class CreateVaultData(
    val vaultId: String,
    val device: CreatedDevice,
    val serverTime: Long,
)

data class CreatePairingRequest(val publicKey: String)

data class CreatePairingData(
    val pairingId: String,
    val pairingSecret: String,
    val initiatorPublicKey: String,
    val expiresAt: Long,
    val serverTime: Long,
)

data class PairingClaimRequest(
    val pairingSecret: String,
    val deviceToken: String,
    val device: DeviceRegistration,
)

data class PairingClaimData(
    val pairingId: String,
    val status: PairingStatus,
    val deviceId: String,
    val expiresAt: Long,
)

data class PairingClaimInfo(
    val deviceId: String,
    val name: String,
    val platform: DevicePlatform,
    val publicKey: String,
    val claimedAt: Long,
)

data class PairingStatusData(
    val pairingId: String,
    val status: PairingStatus,
    val expiresAt: Long,
    val claim: PairingClaimInfo?,
)

data class PairingConfirmRequest(val vaultKeyEnvelope: EncryptedEnvelope)

data class PairingConfirmData(
    val pairingId: String,
    val status: PairingStatus,
    val deviceId: String,
)

data class PairingResultRequest(
    val pairingSecret: String,
    val deviceToken: String,
)

data class PairingResultData(
    val pairingId: String,
    val status: PairingStatus,
    val vaultId: String?,
    val deviceId: String?,
    val initiatorPublicKey: String?,
    val vaultKeyEnvelope: EncryptedEnvelope?,
    val expiresAt: Long,
)

data class SyncPushOperation(
    val opId: String,
    val entityId: String,
    val kind: SyncOperationKind,
    val lamport: Long,
    val ciphertext: String,
    val nonce: String,
)

data class SyncRequest(
    val cursor: Long,
    val ack: Long? = null,
    val pullLimit: Int? = null,
    val push: List<SyncPushOperation>,
)

data class SyncPushSummary(
    val received: Int,
    val inserted: Int,
    val duplicates: Int,
)

data class SyncPulledOperation(
    val serverSeq: Long,
    val opId: String,
    val deviceId: String,
    val entityId: String,
    val kind: SyncOperationKind,
    val lamport: Long,
    val ciphertext: String,
    val nonce: String,
    val createdAt: Long,
) {
    fun metadata(): SyncOperationMetadata = SyncOperationMetadata(
        opId = opId,
        entityId = entityId,
        kind = kind,
        lamport = lamport,
        deviceId = deviceId,
    )
}

data class SyncData(
    val push: SyncPushSummary,
    val pull: List<SyncPulledOperation>,
    val cursor: Long,
    val hasMore: Boolean,
    val serverTime: Long,
)

data class DeviceInfo(
    val id: String,
    val name: String,
    val platform: DevicePlatform,
    val publicKey: String?,
    val createdAt: Long,
    val lastSeenAt: Long?,
    val revokedAt: Long?,
    val isCurrent: Boolean,
)

data class DeviceListData(val devices: List<DeviceInfo>)

data class RevokeDeviceData(
    val deviceId: String,
    val revokedAt: Long,
)

sealed interface JsonValue {
    data class Text(val value: String) : JsonValue
    data class NumberValue(val value: Double) : JsonValue
    data class BooleanValue(val value: Boolean) : JsonValue
    data class ObjectValue(val value: Map<String, JsonValue>) : JsonValue
    data class ArrayValue(val value: List<JsonValue>) : JsonValue
    data object NullValue : JsonValue
}

data class ServerErrorPayload(
    val code: String,
    val message: String,
    val details: Map<String, JsonValue>? = null,
)

data class BearerCredential(val deviceToken: String) {
    init {
        require(Base64Url.decode(deviceToken).size == 32) { "设备令牌必须是 32 字节" }
    }
}

object SyncProtocolLimits {
    const val MAX_PUSH_OPERATIONS = 50
    const val MAX_PULL_OPERATIONS = 100
    const val MAX_CIPHERTEXT_BYTES = 32 * 1024
}
