package com.wootodo.sync

import org.json.JSONObject

object PairingFileKind {
    const val OFFER = "offer"
    const val CLAIM = "claim"
    const val JOIN = "join"
    const val RESOLVE = "resolve"
    const val APPROVAL = "approval"

    val all = setOf(OFFER, CLAIM, JOIN, RESOLVE, APPROVAL)
}

data class PairingFileName(
    val kind: String,
    val pairingId: String,
    val code: String?,
)

object PairingFileNames {
    private val codeFilePattern = Regex(
        "^(offer|join)-([0-9]{6})-([A-Za-z0-9][A-Za-z0-9._:-]{7,127})\\.json$",
    )
    private val simpleFilePattern = Regex(
        "^(claim|resolve|approval)-([A-Za-z0-9][A-Za-z0-9._:-]{7,127})\\.json$",
    )

    fun offer(code: String, pairingId: String): String = "offer-$code-$pairingId.json"

    fun claim(pairingId: String): String = "claim-$pairingId.json"

    fun join(code: String, pairingId: String): String = "join-$code-$pairingId.json"

    fun resolve(pairingId: String): String = "resolve-$pairingId.json"

    fun approval(pairingId: String): String = "approval-$pairingId.json"

    fun parse(name: String): PairingFileName? {
        codeFilePattern.matchEntire(name)?.let { match ->
            return PairingFileName(
                kind = match.groupValues[1],
                pairingId = match.groupValues[3],
                code = match.groupValues[2],
            )
        }
        simpleFilePattern.matchEntire(name)?.let { match ->
            return PairingFileName(
                kind = match.groupValues[1],
                pairingId = match.groupValues[2],
                code = null,
            )
        }
        return null
    }
}

object PairingTimePolicy {
    const val TTL_MILLIS = 5L * 60L * 1_000L
    const val POLL_INTERVAL_MILLIS = 2_000L
    const val POLL_GRACE_MILLIS = 30_000L

    fun isValidWindow(createdAt: Long, expiresAt: Long): Boolean =
        createdAt > 0L && expiresAt > createdAt &&
            expiresAt - createdAt <= TTL_MILLIS

    /**
     * 以本机首次观察该文件的时间为起点，用文件自身的 TTL 换算截止时间。
     * 不使用本地 now 直接减远端 createdAt，以容忍两台设备的时钟偏移。
     */
    fun deadlineFrom(observedAtMillis: Long, createdAt: Long, expiresAt: Long): Long? =
        if (isValidWindow(createdAt, expiresAt)) {
            observedAtMillis + (expiresAt - createdAt)
        } else {
            null
        }

    fun isExpired(
        nowMillis: Long,
        observedAtMillis: Long,
        createdAt: Long,
        expiresAt: Long,
    ): Boolean {
        val deadline = deadlineFrom(observedAtMillis, createdAt, expiresAt) ?: return true
        return nowMillis > deadline
    }

    fun canContinue(nowMillis: Long, deadlineMillis: Long): Boolean =
        nowMillis <= deadlineMillis + POLL_GRACE_MILLIS

    fun remainingSeconds(nowMillis: Long, deadlineMillis: Long): Long =
        ((deadlineMillis - nowMillis).coerceAtLeast(0L) + 999L) / 1_000L
}

sealed interface PairingFile {
    val kind: String
    val pairingId: String
    val createdAt: Long
    val expiresAt: Long
    val fileName: String

    fun encode(): String
}

private object PairingJson {
    const val FORMAT = "woo-todo-webdav-pairing"
    const val PROTOCOL_VERSION = 1

    fun base(kind: String, pairingId: String, createdAt: Long, expiresAt: Long): JSONObject =
        JSONObject()
            .put("format", FORMAT)
            .put("protocolVersion", PROTOCOL_VERSION)
            .put("kind", kind)
            .put("pairingId", pairingId)
            .put("createdAt", createdAt)
            .put("expiresAt", expiresAt)

    fun envelope(value: EncryptedEnvelope): JSONObject = JSONObject()
        .put("ciphertext", value.ciphertext)
        .put("nonce", value.nonce)

    fun requireExactKeys(value: JSONObject, expected: Set<String>) {
        if (value.keys().asSequence().toSet() != expected) {
            throw WebDavException.MalformedObject("配对文件字段不匹配")
        }
    }

    fun string(value: JSONObject, name: String): String =
        value.opt(name) as? String
            ?: throw WebDavException.MalformedObject("配对文件字段类型不匹配")

    fun long(value: JSONObject, name: String): Long = when (val raw = value.opt(name)) {
        is Int -> raw.toLong()
        is Long -> raw
        else -> throw WebDavException.MalformedObject("配对文件字段类型不匹配")
    }

    fun protocolVersion(value: JSONObject) {
        val raw = value.opt("protocolVersion")
        if (!((raw is Int && raw == PROTOCOL_VERSION) ||
                (raw is Long && raw == PROTOCOL_VERSION.toLong()))
        ) {
            throw WebDavException.MalformedObject("配对协议版本不支持")
        }
    }

    fun common(value: JSONObject, expectedKind: String): LongArray {
        protocolVersion(value)
        if (string(value, "format") != FORMAT ||
            string(value, "kind") != expectedKind
        ) {
            throw WebDavException.MalformedObject("配对文件格式不匹配")
        }
        val createdAt = long(value, "createdAt")
        val expiresAt = long(value, "expiresAt")
        val pairingId = string(value, "pairingId")
        validatePairingId(pairingId)
        if (!PairingTimePolicy.isValidWindow(createdAt, expiresAt)) {
            throw WebDavException.MalformedObject("配对文件有效期无效")
        }
        return longArrayOf(createdAt, expiresAt)
    }

    fun validatePairingId(value: String) {
        if (!Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$").matches(value)) {
            throw WebDavException.MalformedObject("配对 ID 无效")
        }
    }

    fun validateCode(value: String) {
        if (!Regex("^[0-9]{6}$").matches(value)) {
            throw WebDavException.MalformedObject("配对码无效")
        }
    }

    fun validatePublicKey(value: String) {
        if (Base64Url.decode(value).size != 32) {
            throw WebDavException.MalformedObject("配对公钥无效")
        }
    }

    fun validateSecret(value: String) {
        if (Base64Url.decode(value).size != 32) {
            throw WebDavException.MalformedObject("配对 secret 无效")
        }
    }

    fun validateDeviceId(value: String) {
        if (!WebDavCredentialPolicy.isValidDeviceId(value)) {
            throw WebDavException.MalformedObject("配对设备 ID 无效")
        }
    }

    fun validateVaultId(value: String) {
        if (!WebDavCredentialPolicy.isValidVaultId(value)) {
            throw WebDavException.MalformedObject("配对同步空间无效")
        }
    }

    fun validateDeviceName(value: String) {
        if (value.codePointCount(0, value.length) !in 1..64 ||
            value.any(Char::isISOControl)
        ) {
            throw WebDavException.MalformedObject("配对设备名无效")
        }
    }

    fun validatePlatform(value: String): DevicePlatform = try {
        DevicePlatform.fromWire(value)
    } catch (_: IllegalArgumentException) {
        throw WebDavException.MalformedObject("配对平台无效")
    }

    fun decodeEnvelope(value: JSONObject): EncryptedEnvelope {
        requireExactKeys(value, setOf("ciphertext", "nonce"))
        val envelope = EncryptedEnvelope(
            ciphertext = string(value, "ciphertext"),
            nonce = string(value, "nonce"),
        )
        if (Base64Url.decode(envelope.nonce).size != Aes256Gcm.NONCE_BYTES ||
            Base64Url.decode(envelope.ciphertext).size !=
            Aes256Gcm.KEY_BYTES + Aes256Gcm.TAG_BYTES
        ) {
            throw WebDavException.MalformedObject("配对密钥信封无效")
        }
        return envelope
    }
}

data class PairingOffer(
    override val pairingId: String,
    override val createdAt: Long,
    override val expiresAt: Long,
    val code: String,
    val publicKey: String,
    val pairingSecret: String,
    val vaultId: String,
    val deviceName: String,
    val platform: DevicePlatform,
) : PairingFile {
    override val kind: String get() = PairingFileKind.OFFER
    override val fileName: String get() = PairingFileNames.offer(code, pairingId)

    override fun encode(): String = PairingJson.base(kind, pairingId, createdAt, expiresAt)
        .put("code", code)
        .put("publicKey", publicKey)
        .put("pairingSecret", pairingSecret)
        .put("vaultId", vaultId)
        .put("deviceName", deviceName)
        .put("platform", platform.wireValue)
        .toString()

    fun validate() {
        PairingJson.validatePairingId(pairingId)
        if (!PairingTimePolicy.isValidWindow(createdAt, expiresAt)) {
            throw WebDavException.MalformedObject("配对文件有效期无效")
        }
        PairingJson.validateCode(code)
        PairingJson.validatePublicKey(publicKey)
        PairingJson.validateSecret(pairingSecret)
        PairingJson.validateVaultId(vaultId)
        PairingJson.validateDeviceName(deviceName)
    }

    companion object {
        fun decode(source: String): PairingOffer {
            val value = JSONObject(source)
            val expected = setOf(
                "format", "protocolVersion", "kind", "pairingId", "createdAt",
                "expiresAt", "code", "publicKey", "pairingSecret", "vaultId",
                "deviceName", "platform",
            )
            PairingJson.requireExactKeys(value, expected)
            val times = PairingJson.common(value, PairingFileKind.OFFER)
            return PairingOffer(
                pairingId = PairingJson.string(value, "pairingId"),
                createdAt = times[0],
                expiresAt = times[1],
                code = PairingJson.string(value, "code"),
                publicKey = PairingJson.string(value, "publicKey"),
                pairingSecret = PairingJson.string(value, "pairingSecret"),
                vaultId = PairingJson.string(value, "vaultId"),
                deviceName = PairingJson.string(value, "deviceName"),
                platform = PairingJson.validatePlatform(PairingJson.string(value, "platform")),
            ).also(PairingOffer::validate)
        }
    }
}

data class PairingClaim(
    override val pairingId: String,
    override val createdAt: Long,
    override val expiresAt: Long,
    val publicKey: String,
    val deviceId: String,
    val deviceName: String,
    val platform: DevicePlatform,
) : PairingFile {
    override val kind: String get() = PairingFileKind.CLAIM
    override val fileName: String get() = PairingFileNames.claim(pairingId)

    override fun encode(): String = PairingJson.base(kind, pairingId, createdAt, expiresAt)
        .put("publicKey", publicKey)
        .put("deviceId", deviceId)
        .put("deviceName", deviceName)
        .put("platform", platform.wireValue)
        .toString()

    fun validate() {
        PairingJson.validatePairingId(pairingId)
        if (!PairingTimePolicy.isValidWindow(createdAt, expiresAt)) {
            throw WebDavException.MalformedObject("配对文件有效期无效")
        }
        PairingJson.validatePublicKey(publicKey)
        PairingJson.validateDeviceId(deviceId)
        PairingJson.validateDeviceName(deviceName)
    }

    companion object {
        fun decode(source: String): PairingClaim {
            val value = JSONObject(source)
            val expected = setOf(
                "format", "protocolVersion", "kind", "pairingId", "createdAt",
                "expiresAt", "publicKey", "deviceId", "deviceName", "platform",
            )
            PairingJson.requireExactKeys(value, expected)
            val times = PairingJson.common(value, PairingFileKind.CLAIM)
            return PairingClaim(
                pairingId = PairingJson.string(value, "pairingId"),
                createdAt = times[0],
                expiresAt = times[1],
                publicKey = PairingJson.string(value, "publicKey"),
                deviceId = PairingJson.string(value, "deviceId"),
                deviceName = PairingJson.string(value, "deviceName"),
                platform = PairingJson.validatePlatform(PairingJson.string(value, "platform")),
            ).also(PairingClaim::validate)
        }
    }
}

data class PairingJoin(
    override val pairingId: String,
    override val createdAt: Long,
    override val expiresAt: Long,
    val code: String,
    val publicKey: String,
    val deviceId: String,
    val deviceName: String,
    val platform: DevicePlatform,
) : PairingFile {
    override val kind: String get() = PairingFileKind.JOIN
    override val fileName: String get() = PairingFileNames.join(code, pairingId)

    override fun encode(): String = PairingJson.base(kind, pairingId, createdAt, expiresAt)
        .put("code", code)
        .put("publicKey", publicKey)
        .put("deviceId", deviceId)
        .put("deviceName", deviceName)
        .put("platform", platform.wireValue)
        .toString()

    fun validate() {
        PairingJson.validatePairingId(pairingId)
        if (!PairingTimePolicy.isValidWindow(createdAt, expiresAt)) {
            throw WebDavException.MalformedObject("配对文件有效期无效")
        }
        PairingJson.validateCode(code)
        PairingJson.validatePublicKey(publicKey)
        PairingJson.validateDeviceId(deviceId)
        PairingJson.validateDeviceName(deviceName)
    }

    companion object {
        fun decode(source: String): PairingJoin {
            val value = JSONObject(source)
            val expected = setOf(
                "format", "protocolVersion", "kind", "pairingId", "createdAt",
                "expiresAt", "code", "publicKey", "deviceId", "deviceName", "platform",
            )
            PairingJson.requireExactKeys(value, expected)
            val times = PairingJson.common(value, PairingFileKind.JOIN)
            return PairingJoin(
                pairingId = PairingJson.string(value, "pairingId"),
                createdAt = times[0],
                expiresAt = times[1],
                code = PairingJson.string(value, "code"),
                publicKey = PairingJson.string(value, "publicKey"),
                deviceId = PairingJson.string(value, "deviceId"),
                deviceName = PairingJson.string(value, "deviceName"),
                platform = PairingJson.validatePlatform(PairingJson.string(value, "platform")),
            ).also(PairingJoin::validate)
        }
    }
}

data class PairingResolve(
    override val pairingId: String,
    override val createdAt: Long,
    override val expiresAt: Long,
    val approverPublicKey: String,
    val approverDeviceId: String,
    val approverName: String,
) : PairingFile {
    override val kind: String get() = PairingFileKind.RESOLVE
    override val fileName: String get() = PairingFileNames.resolve(pairingId)

    override fun encode(): String = PairingJson.base(kind, pairingId, createdAt, expiresAt)
        .put("approverPublicKey", approverPublicKey)
        .put("approverDeviceId", approverDeviceId)
        .put("approverName", approverName)
        .toString()

    fun validate() {
        PairingJson.validatePairingId(pairingId)
        if (!PairingTimePolicy.isValidWindow(createdAt, expiresAt)) {
            throw WebDavException.MalformedObject("配对文件有效期无效")
        }
        PairingJson.validatePublicKey(approverPublicKey)
        PairingJson.validateDeviceId(approverDeviceId)
        PairingJson.validateDeviceName(approverName)
    }

    companion object {
        fun decode(source: String): PairingResolve {
            val value = JSONObject(source)
            val expected = setOf(
                "format", "protocolVersion", "kind", "pairingId", "createdAt",
                "expiresAt", "approverPublicKey", "approverDeviceId", "approverName",
            )
            PairingJson.requireExactKeys(value, expected)
            val times = PairingJson.common(value, PairingFileKind.RESOLVE)
            return PairingResolve(
                pairingId = PairingJson.string(value, "pairingId"),
                createdAt = times[0],
                expiresAt = times[1],
                approverPublicKey = PairingJson.string(value, "approverPublicKey"),
                approverDeviceId = PairingJson.string(value, "approverDeviceId"),
                approverName = PairingJson.string(value, "approverName"),
            ).also(PairingResolve::validate)
        }
    }
}

data class PairingApproval(
    override val pairingId: String,
    override val createdAt: Long,
    override val expiresAt: Long,
    val deviceId: String,
    val vaultId: String,
    val vaultKeyEnvelope: EncryptedEnvelope,
    val initiatorPublicKey: String,
    /** Path B 的批准方公钥；Path A 的 approval 不携带该字段。 */
    val approverPublicKey: String?,
) : PairingFile {
    override val kind: String get() = PairingFileKind.APPROVAL
    override val fileName: String get() = PairingFileNames.approval(pairingId)

    override fun encode(): String {
        val value = PairingJson.base(kind, pairingId, createdAt, expiresAt)
            .put("deviceId", deviceId)
            .put("vaultId", vaultId)
            .put("vaultKeyEnvelope", PairingJson.envelope(vaultKeyEnvelope))
            .put("initiatorPublicKey", initiatorPublicKey)
        approverPublicKey?.let { value.put("approverPublicKey", it) }
        return value.toString()
    }

    fun validate() {
        PairingJson.validatePairingId(pairingId)
        if (!PairingTimePolicy.isValidWindow(createdAt, expiresAt)) {
            throw WebDavException.MalformedObject("配对文件有效期无效")
        }
        PairingJson.validateDeviceId(deviceId)
        PairingJson.validateVaultId(vaultId)
        PairingJson.decodeEnvelope(
            JSONObject()
                .put("ciphertext", vaultKeyEnvelope.ciphertext)
                .put("nonce", vaultKeyEnvelope.nonce),
        )
        PairingJson.validatePublicKey(initiatorPublicKey)
        approverPublicKey?.let(PairingJson::validatePublicKey)
    }

    companion object {
        fun decode(source: String): PairingApproval {
            val value = JSONObject(source)
            val keys = value.keys().asSequence().toSet()
            val base = setOf(
                "format", "protocolVersion", "kind", "pairingId", "createdAt",
                "expiresAt", "deviceId", "vaultId", "vaultKeyEnvelope",
                "initiatorPublicKey",
            )
            val pathB = base + "approverPublicKey"
            if (keys != base && keys != pathB) {
                throw WebDavException.MalformedObject("配对文件字段不匹配")
            }
            val times = PairingJson.common(value, PairingFileKind.APPROVAL)
            val envelope = value.opt("vaultKeyEnvelope") as? JSONObject
                ?: throw WebDavException.MalformedObject("配对密钥信封无效")
            return PairingApproval(
                pairingId = PairingJson.string(value, "pairingId"),
                createdAt = times[0],
                expiresAt = times[1],
                deviceId = PairingJson.string(value, "deviceId"),
                vaultId = PairingJson.string(value, "vaultId"),
                vaultKeyEnvelope = PairingJson.decodeEnvelope(envelope),
                initiatorPublicKey = PairingJson.string(value, "initiatorPublicKey"),
                approverPublicKey = if (keys == pathB) {
                    PairingJson.string(value, "approverPublicKey")
                } else {
                    null
                },
            ).also(PairingApproval::validate)
        }
    }
}

object PairingFileCodec {
    fun decode(source: String): PairingFile {
        val value = try {
            JSONObject(source)
        } catch (error: Exception) {
            throw WebDavException.MalformedObject("配对文件不是有效 JSON")
        }
        return when (val kind = value.opt("kind") as? String) {
            PairingFileKind.OFFER -> PairingOffer.decode(source)
            PairingFileKind.CLAIM -> PairingClaim.decode(source)
            PairingFileKind.JOIN -> PairingJoin.decode(source)
            PairingFileKind.RESOLVE -> PairingResolve.decode(source)
            PairingFileKind.APPROVAL -> PairingApproval.decode(source)
            else -> throw WebDavException.MalformedObject("未知配对文件类型：$kind")
        }
    }
}
