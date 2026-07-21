package com.wootodo.sync

import org.json.JSONArray
import org.json.JSONObject
import java.time.DayOfWeek
import java.time.LocalDate

class ProtocolJsonException(message: String, cause: Throwable? = null) : Exception(message, cause)

data class DecodedFailure(
    val payload: ServerErrorPayload,
    val requestId: String?,
)

object SyncJsonCodec {
    fun encode(request: CreateVaultRequest): String = JSONObject()
        .put("device", encodeDevice(request.device))
        .apply { request.recoveryEnvelope?.let { put("recoveryEnvelope", encodeEnvelope(it)) } }
        .toString()

    fun encode(request: CreatePairingRequest): String {
        requireBase64Bytes(request.publicKey, 32, "publicKey")
        return JSONObject().put("publicKey", request.publicKey).toString()
    }

    fun encode(request: PairingClaimRequest): String {
        requireBase64Bytes(request.pairingSecret, 32, "pairingSecret")
        requireBase64Bytes(request.deviceToken, 32, "deviceToken")
        require(request.device.publicKey != null) { "认领配对必须提供 X25519 公钥" }
        return JSONObject()
            .put("pairingSecret", request.pairingSecret)
            .put("deviceToken", request.deviceToken)
            .put("device", encodeDevice(request.device))
            .toString()
    }

    fun encode(request: PairingConfirmRequest): String = JSONObject()
        .put("vaultKeyEnvelope", encodeEnvelope(request.vaultKeyEnvelope))
        .toString()

    fun encode(request: PairingResultRequest): String {
        requireBase64Bytes(request.pairingSecret, 32, "pairingSecret")
        requireBase64Bytes(request.deviceToken, 32, "deviceToken")
        return JSONObject()
            .put("pairingSecret", request.pairingSecret)
            .put("deviceToken", request.deviceToken)
            .toString()
    }

    fun encode(request: SyncRequest): String {
        require(request.cursor >= 0)
        request.ack?.let { require(it in 0..request.cursor) }
        request.pullLimit?.let { require(it in 1..SyncProtocolLimits.MAX_PULL_OPERATIONS) }
        require(request.push.size <= SyncProtocolLimits.MAX_PUSH_OPERATIONS)
        return JSONObject()
            .put("cursor", request.cursor)
            .apply { request.ack?.let { put("ack", it) } }
            .apply { request.pullLimit?.let { put("pullLimit", it) } }
            .put("push", JSONArray().apply { request.push.forEach { put(encodePushOperation(it)) } })
            .toString()
    }

    fun decodeCreateVaultData(source: String): CreateVaultData =
        decodeSuccess(source, ::decodeCreateVaultDataObject)

    fun decodeCreatePairingData(source: String): CreatePairingData =
        decodeSuccess(source, ::decodeCreatePairingDataObject)

    fun decodePairingClaimData(source: String): PairingClaimData =
        decodeSuccess(source, ::decodePairingClaimDataObject)

    fun decodePairingStatusData(source: String): PairingStatusData =
        decodeSuccess(source, ::decodePairingStatusDataObject)

    fun decodePairingConfirmData(source: String): PairingConfirmData =
        decodeSuccess(source, ::decodePairingConfirmDataObject)

    fun decodePairingResultData(source: String): PairingResultData =
        decodeSuccess(source, ::decodePairingResultDataObject)

    fun decodeSyncData(source: String): SyncData = decodeSuccess(source, ::decodeSyncDataObject)

    fun decodeDeviceListData(source: String): DeviceListData =
        decodeSuccess(source, ::decodeDeviceListDataObject)

    fun decodeRevokeDeviceData(source: String): RevokeDeviceData =
        decodeSuccess(source, ::decodeRevokeDeviceDataObject)

    fun decodeFailure(source: String): DecodedFailure {
        val root = jsonObject(source)
        root.requireKeys(setOf("ok", "error"), setOf("requestId"))
        if (root.boolean("ok")) throw ProtocolJsonException("失败响应中的 ok 必须为 false")
        val error = root.objectValue("error")
        error.requireKeys(setOf("code", "message"), setOf("details"))
        val details = if (error.has("details") && !error.isNull("details")) {
            val detailsObject = error.objectValue("details")
            detailsObject.keys().asSequence().associateWith { key ->
                jsonValue(detailsObject.get(key))
            }
        } else {
            null
        }
        return DecodedFailure(
            payload = ServerErrorPayload(error.string("code"), error.string("message"), details),
            requestId = root.nullableString("requestId"),
        )
    }

    fun encodeTaskPayload(payload: TaskWirePayload): String = when (payload) {
        is TaskInstancePayload -> encodeTask(payload).toString()
        is TombstonePayload -> encodeTombstone(payload).toString()
    }

    fun decodeTaskPayload(source: String): TaskWirePayload {
        val objectValue = jsonObject(source)
        return when (objectValue.string("entityType")) {
            "task" -> decodeTask(objectValue)
            "tombstone" -> decodeTombstone(objectValue)
            else -> throw ProtocolJsonException("未知任务正文 entityType")
        }
    }

    private fun <T> decodeSuccess(source: String, decoder: (JSONObject) -> T): T {
        val root = jsonObject(source)
        root.requireKeys(setOf("ok", "data", "requestId"))
        if (!root.boolean("ok")) throw ProtocolJsonException("成功响应中的 ok 必须为 true")
        root.string("requestId")
        return decoder(root.objectValue("data"))
    }

    private fun decodeCreateVaultDataObject(value: JSONObject): CreateVaultData {
        value.requireKeys(setOf("vaultId", "device", "serverTime"))
        val device = value.objectValue("device").apply {
            requireKeys(setOf("id", "name", "platform", "token"))
        }
        val token = device.string("token").also { requireBase64Bytes(it, 32, "device.token") }
        return CreateVaultData(
            vaultId = value.string("vaultId"),
            device = CreatedDevice(
                id = device.string("id"),
                name = device.string("name"),
                platform = DevicePlatform.fromWire(device.string("platform")),
                token = token,
            ),
            serverTime = value.nonNegativeLong("serverTime"),
        )
    }

    private fun decodeCreatePairingDataObject(value: JSONObject): CreatePairingData {
        value.requireKeys(
            setOf("pairingId", "pairingSecret", "initiatorPublicKey", "expiresAt", "serverTime"),
        )
        val secret = value.string("pairingSecret").also { requireBase64Bytes(it, 32, "pairingSecret") }
        val publicKey = value.string("initiatorPublicKey")
            .also { requireBase64Bytes(it, 32, "initiatorPublicKey") }
        return CreatePairingData(
            pairingId = value.string("pairingId"),
            pairingSecret = secret,
            initiatorPublicKey = publicKey,
            expiresAt = value.nonNegativeLong("expiresAt"),
            serverTime = value.nonNegativeLong("serverTime"),
        )
    }

    private fun decodePairingClaimDataObject(value: JSONObject): PairingClaimData {
        value.requireKeys(setOf("pairingId", "status", "deviceId", "expiresAt"))
        return PairingClaimData(
            pairingId = value.string("pairingId"),
            status = PairingStatus.fromWire(value.string("status")),
            deviceId = value.string("deviceId"),
            expiresAt = value.nonNegativeLong("expiresAt"),
        )
    }

    private fun decodePairingStatusDataObject(value: JSONObject): PairingStatusData {
        value.requireKeys(setOf("pairingId", "status", "expiresAt", "claim"))
        val claim = if (value.isNull("claim")) null else value.objectValue("claim").let { objectValue ->
            objectValue.requireKeys(
                setOf("deviceId", "name", "platform", "publicKey", "claimedAt"),
            )
            PairingClaimInfo(
                deviceId = objectValue.string("deviceId"),
                name = objectValue.string("name"),
                platform = DevicePlatform.fromWire(objectValue.string("platform")),
                publicKey = objectValue.string("publicKey").also {
                    requireBase64Bytes(it, 32, "claim.publicKey")
                },
                claimedAt = objectValue.nonNegativeLong("claimedAt"),
            )
        }
        return PairingStatusData(
            pairingId = value.string("pairingId"),
            status = PairingStatus.fromWire(value.string("status")),
            expiresAt = value.nonNegativeLong("expiresAt"),
            claim = claim,
        )
    }

    private fun decodePairingConfirmDataObject(value: JSONObject): PairingConfirmData {
        value.requireKeys(setOf("pairingId", "status", "deviceId"))
        return PairingConfirmData(
            pairingId = value.string("pairingId"),
            status = PairingStatus.fromWire(value.string("status")),
            deviceId = value.string("deviceId"),
        )
    }

    private fun decodePairingResultDataObject(value: JSONObject): PairingResultData {
        value.requireKeys(
            setOf("pairingId", "status", "expiresAt"),
            setOf("vaultId", "deviceId", "initiatorPublicKey", "vaultKeyEnvelope"),
        )
        return PairingResultData(
            pairingId = value.string("pairingId"),
            status = PairingStatus.fromWire(value.string("status")),
            vaultId = value.nullableString("vaultId"),
            deviceId = value.nullableString("deviceId"),
            initiatorPublicKey = value.nullableString("initiatorPublicKey")?.also {
                requireBase64Bytes(it, 32, "initiatorPublicKey")
            },
            vaultKeyEnvelope = value.nullableObject("vaultKeyEnvelope")?.let(::decodeEnvelope),
            expiresAt = value.nonNegativeLong("expiresAt"),
        )
    }

    private fun decodeSyncDataObject(value: JSONObject): SyncData {
        value.requireKeys(setOf("push", "pull", "cursor", "hasMore", "serverTime"))
        val summaryObject = value.objectValue("push").apply {
            requireKeys(setOf("received", "inserted", "duplicates"))
        }
        val pullArray = value.array("pull")
        if (pullArray.length() > SyncProtocolLimits.MAX_PULL_OPERATIONS) {
            throw ProtocolJsonException("pull 超过 100 条")
        }
        return SyncData(
            push = SyncPushSummary(
                received = summaryObject.nonNegativeInt("received"),
                inserted = summaryObject.nonNegativeInt("inserted"),
                duplicates = summaryObject.nonNegativeInt("duplicates"),
            ),
            pull = (0 until pullArray.length()).map { index ->
                decodePulledOperation(pullArray.objectAt(index))
            },
            cursor = value.nonNegativeLong("cursor"),
            hasMore = value.boolean("hasMore"),
            serverTime = value.nonNegativeLong("serverTime"),
        )
    }

    private fun decodeDeviceListDataObject(value: JSONObject): DeviceListData {
        value.requireKeys(setOf("devices"))
        val devices = value.array("devices")
        return DeviceListData((0 until devices.length()).map { index ->
            val device = devices.objectAt(index).apply {
                requireKeys(
                    setOf(
                        "id", "name", "platform", "publicKey", "createdAt",
                        "lastSeenAt", "revokedAt", "isCurrent",
                    ),
                )
            }
            DeviceInfo(
                id = device.string("id"),
                name = device.string("name"),
                platform = DevicePlatform.fromWire(device.string("platform")),
                publicKey = device.nullableString("publicKey")?.also {
                    requireBase64Bytes(it, 32, "devices[$index].publicKey")
                },
                createdAt = device.nonNegativeLong("createdAt"),
                lastSeenAt = device.nullableNonNegativeLong("lastSeenAt"),
                revokedAt = device.nullableNonNegativeLong("revokedAt"),
                isCurrent = device.boolean("isCurrent"),
            )
        })
    }

    private fun decodeRevokeDeviceDataObject(value: JSONObject): RevokeDeviceData {
        value.requireKeys(setOf("deviceId", "revokedAt"))
        return RevokeDeviceData(value.string("deviceId"), value.nonNegativeLong("revokedAt"))
    }

    private fun encodeDevice(device: DeviceRegistration): JSONObject {
        val name = device.name.trim()
        require(name.isNotEmpty() && name.length <= 80 && name.none { it.code < 32 || it.code == 127 })
        return JSONObject()
            .put("name", name)
            .put("platform", device.platform.wireValue)
            .apply {
                device.publicKey?.let {
                    requireBase64Bytes(it, 32, "device.publicKey")
                    put("publicKey", it)
                }
            }
    }

    private fun encodeEnvelope(envelope: EncryptedEnvelope): JSONObject {
        validateEnvelope(envelope)
        return JSONObject().put("ciphertext", envelope.ciphertext).put("nonce", envelope.nonce)
    }

    private fun decodeEnvelope(value: JSONObject): EncryptedEnvelope {
        value.requireKeys(setOf("ciphertext", "nonce"))
        return EncryptedEnvelope(value.string("ciphertext"), value.string("nonce")).also(::validateEnvelope)
    }

    private fun encodePushOperation(operation: SyncPushOperation): JSONObject {
        requireIdentifier(operation.opId, "opId")
        requireIdentifier(operation.entityId, "entityId")
        require(operation.lamport >= 1)
        validateEnvelope(EncryptedEnvelope(operation.ciphertext, operation.nonce))
        require(Base64Url.decode(operation.ciphertext).size <= SyncProtocolLimits.MAX_CIPHERTEXT_BYTES)
        return JSONObject()
            .put("opId", operation.opId)
            .put("entityId", operation.entityId)
            .put("kind", operation.kind.wireValue)
            .put("lamport", operation.lamport)
            .put("ciphertext", operation.ciphertext)
            .put("nonce", operation.nonce)
    }

    private fun decodePulledOperation(value: JSONObject): SyncPulledOperation {
        value.requireKeys(
            setOf(
                "serverSeq", "opId", "deviceId", "entityId", "kind", "lamport",
                "ciphertext", "nonce", "createdAt",
            ),
        )
        val envelope = decodeEnvelope(JSONObject().put("ciphertext", value.string("ciphertext"))
            .put("nonce", value.string("nonce")))
        require(Base64Url.decode(envelope.ciphertext).size <= SyncProtocolLimits.MAX_CIPHERTEXT_BYTES)
        return SyncPulledOperation(
            serverSeq = value.positiveLong("serverSeq"),
            opId = value.string("opId").also { requireIdentifier(it, "opId") },
            deviceId = value.string("deviceId").also { requireIdentifier(it, "deviceId") },
            entityId = value.string("entityId").also { requireIdentifier(it, "entityId") },
            kind = SyncOperationKind.fromWire(value.string("kind")),
            lamport = value.positiveLong("lamport"),
            ciphertext = envelope.ciphertext,
            nonce = envelope.nonce,
            createdAt = value.nonNegativeLong("createdAt"),
        )
    }

    private fun encodeTask(task: TaskInstancePayload): JSONObject {
        validateTask(task)
        return JSONObject()
            .put("protocolVersion", task.protocolVersion)
            .put("entityType", task.entityType)
            .put("id", task.id)
            .put("seriesId", task.seriesId)
            .put("title", task.title)
            .put("timeType", task.timeType.value)
            .put("periodStart", task.periodStart ?: JSONObject.NULL)
            .put("timezone", task.timezone)
            .put("questLine", task.questLine.value)
            .put("state", task.state.value)
            .put("recurrence", task.recurrence.value)
            .put("sortOrder", task.sortOrder)
            .put("createdAt", task.createdAt)
            .put("updatedAt", task.updatedAt)
            .put("settledAt", task.settledAt ?: JSONObject.NULL)
            .apply { task.reminderTime?.let { put("reminderTime", it) } }
    }

    private fun decodeTask(value: JSONObject): TaskInstancePayload {
        value.requireKeys(
            setOf(
                "protocolVersion", "entityType", "id", "seriesId", "title", "timeType",
                "periodStart", "timezone", "questLine", "state", "recurrence", "sortOrder",
                "createdAt", "updatedAt", "settledAt",
            ),
            setOf("reminderTime"),
        )
        return TaskInstancePayload(
            protocolVersion = value.nonNegativeInt("protocolVersion"),
            entityType = value.string("entityType"),
            id = value.string("id"),
            seriesId = value.string("seriesId"),
            title = value.string("title"),
            timeType = WireTimeType.fromWire(value.string("timeType")),
            periodStart = value.nullableString("periodStart"),
            timezone = value.string("timezone"),
            questLine = WireQuestLine.fromWire(value.string("questLine")),
            state = WireTaskState.fromWire(value.string("state")),
            recurrence = WireRecurrence.fromWire(value.string("recurrence")),
            sortOrder = value.nonNegativeLong("sortOrder"),
            createdAt = value.nonNegativeLong("createdAt"),
            updatedAt = value.nonNegativeLong("updatedAt"),
            settledAt = value.nullableNonNegativeLong("settledAt"),
            reminderTime = value.nullableString("reminderTime"),
        ).also(::validateTask)
    }

    private fun encodeTombstone(tombstone: TombstonePayload): JSONObject {
        require(tombstone.protocolVersion == 1 && tombstone.entityType == "tombstone")
        require(
            tombstone.id.hasWireCodePointLength(8..128) &&
                IDENTIFIER.matches(tombstone.id) &&
                tombstone.deletedAt in 0..WIRE_MAXIMUM_SAFE_INTEGER,
        )
        return JSONObject()
            .put("protocolVersion", tombstone.protocolVersion)
            .put("entityType", tombstone.entityType)
            .put("id", tombstone.id)
            .put("deletedAt", tombstone.deletedAt)
    }

    private fun decodeTombstone(value: JSONObject): TombstonePayload {
        value.requireKeys(setOf("protocolVersion", "entityType", "id", "deletedAt"))
        return TombstonePayload(
            protocolVersion = value.nonNegativeInt("protocolVersion"),
            entityType = value.string("entityType"),
            id = value.string("id"),
            deletedAt = value.nonNegativeLong("deletedAt"),
        ).also { encodeTombstone(it) }
    }

    private fun validateTask(task: TaskInstancePayload) {
        require(task.protocolVersion == 1 && task.entityType == "task")
        require(
            task.id.hasWireCodePointLength(8..128) &&
                IDENTIFIER.matches(task.id) &&
                task.seriesId.hasWireCodePointLength(8..128) &&
                IDENTIFIER.matches(task.seriesId),
        )
        require(task.title.hasWireCodePointLength(1..120) && task.timezone == WIRE_FIXED_TIMEZONE)
        require(task.sortOrder in 0..WIRE_MAXIMUM_SORT_ORDER)
        require(task.createdAt in 0..WIRE_MAXIMUM_SAFE_INTEGER)
        require(task.updatedAt in 0..WIRE_MAXIMUM_SAFE_INTEGER)
        task.settledAt?.let { require(it in 0..WIRE_MAXIMUM_SAFE_INTEGER) }
        task.reminderTime?.let { require(REMINDER_TIME.matches(it)) }
        if (task.timeType == WireTimeType.SOMEDAY) {
            require(
                task.periodStart == null &&
                    task.recurrence == WireRecurrence.ONCE &&
                    task.reminderTime == null,
            )
        } else {
            val periodStart = requireNotNull(task.periodStart)
            require(DATE_KEY.matches(periodStart))
            val date = LocalDate.parse(periodStart)
            require(date.year in 1..9_999)
            when (task.timeType) {
                WireTimeType.DAY -> Unit
                WireTimeType.WEEK -> require(date.dayOfWeek == DayOfWeek.MONDAY)
                WireTimeType.MONTH -> require(date.dayOfMonth == 1)
                WireTimeType.SOMEDAY -> error("闲时任务不能携带周期起点")
            }
        }
        if (task.state == WireTaskState.PENDING) require(task.settledAt == null)
        else require(task.settledAt != null)
    }

    private fun validateEnvelope(envelope: EncryptedEnvelope) {
        require(Base64Url.decode(envelope.nonce).size == Aes256Gcm.NONCE_BYTES)
        require(Base64Url.decode(envelope.ciphertext).size >= Aes256Gcm.TAG_BYTES)
    }

    private fun requireBase64Bytes(value: String, bytes: Int, field: String) {
        require(Base64Url.decode(value).size == bytes) { "$field 必须是 $bytes 字节" }
    }

    private fun requireIdentifier(value: String, field: String) {
        require(value.length in 1..128 && IDENTIFIER.matches(value)) { "$field 不是安全标识" }
    }

    private fun jsonObject(source: String): JSONObject = try {
        JSONObject(source)
    } catch (error: Exception) {
        throw ProtocolJsonException("JSON 对象解析失败", error)
    }

    private fun jsonValue(value: Any?): JsonValue = when (value) {
        null, JSONObject.NULL -> JsonValue.NullValue
        is String -> JsonValue.Text(value)
        is Boolean -> JsonValue.BooleanValue(value)
        is Number -> JsonValue.NumberValue(value.toDouble())
        is JSONObject -> JsonValue.ObjectValue(
            value.keys().asSequence().associateWith { jsonValue(value.get(it)) },
        )
        is JSONArray -> JsonValue.ArrayValue(
            (0 until value.length()).map { jsonValue(value.get(it)) },
        )
        else -> throw ProtocolJsonException("错误详情包含未知 JSON 类型")
    }

    private val IDENTIFIER = Regex("^[A-Za-z0-9._:-]+$")
    private val DATE_KEY = Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
    private val REMINDER_TIME = Regex("^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
}

private fun String.hasWireCodePointLength(range: IntRange): Boolean {
    var index = 0
    while (index < length) {
        val character = this[index]
        when {
            Character.isHighSurrogate(character) -> {
                if (index + 1 >= length || !Character.isLowSurrogate(this[index + 1])) return false
                index += 2
            }
            Character.isLowSurrogate(character) -> return false
            else -> index += 1
        }
    }
    return codePointCount(0, length) in range
}

private fun JSONObject.requireKeys(required: Set<String>, optional: Set<String> = emptySet()) {
    val actual = keys().asSequence().toSet()
    val missing = required - actual
    val unknown = actual - required - optional
    if (missing.isNotEmpty() || unknown.isNotEmpty()) {
        throw ProtocolJsonException("JSON 字段不匹配，缺少 $missing，未知 $unknown")
    }
}

private fun JSONObject.string(name: String): String = get(name) as? String
    ?: throw ProtocolJsonException("$name 必须是字符串")

private fun JSONObject.nullableString(name: String): String? = when {
    !has(name) || isNull(name) -> null
    else -> string(name)
}

private fun JSONObject.boolean(name: String): Boolean = get(name) as? Boolean
    ?: throw ProtocolJsonException("$name 必须是布尔值")

private fun JSONObject.objectValue(name: String): JSONObject = get(name) as? JSONObject
    ?: throw ProtocolJsonException("$name 必须是对象")

private fun JSONObject.nullableObject(name: String): JSONObject? = when {
    !has(name) || isNull(name) -> null
    else -> objectValue(name)
}

private fun JSONObject.array(name: String): JSONArray = get(name) as? JSONArray
    ?: throw ProtocolJsonException("$name 必须是数组")

private fun JSONArray.objectAt(index: Int): JSONObject = get(index) as? JSONObject
    ?: throw ProtocolJsonException("数组第 $index 项必须是对象")

private fun JSONObject.nonNegativeLong(name: String): Long = integer(name, 0)
private fun JSONObject.positiveLong(name: String): Long = integer(name, 1)

private fun JSONObject.nonNegativeInt(name: String): Int {
    val value = nonNegativeLong(name)
    if (value > Int.MAX_VALUE) throw ProtocolJsonException("$name 超出 Int 范围")
    return value.toInt()
}

private fun JSONObject.nullableNonNegativeLong(name: String): Long? = when {
    !has(name) || isNull(name) -> null
    else -> nonNegativeLong(name)
}

private fun JSONObject.integer(name: String, minimum: Long): Long {
    val number = get(name) as? Number ?: throw ProtocolJsonException("$name 必须是整数")
    val doubleValue = number.toDouble()
    val longValue = number.toLong()
    if (!doubleValue.isFinite() || doubleValue != longValue.toDouble() ||
        longValue < minimum || longValue > WIRE_MAXIMUM_SAFE_INTEGER
    ) {
        throw ProtocolJsonException("$name 不是有效安全整数")
    }
    return longValue
}
