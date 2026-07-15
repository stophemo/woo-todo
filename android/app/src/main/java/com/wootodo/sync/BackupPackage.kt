package com.wootodo.sync

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.text.Normalizer
import java.util.Locale
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

sealed class BackupPackageException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {
    class InvalidFile(val field: String, cause: Throwable? = null) :
        BackupPackageException("备份文件的 $field 字段无效", cause)

    class UnsupportedVersion(val version: Long) :
        BackupPackageException("不支持备份协议版本：$version")

    class InvalidPassphrase :
        BackupPackageException("备份口令规范化后须为 10～256 个字符")

    class AuthenticationFailed(cause: Throwable? = null) :
        BackupPackageException("备份口令错误或文件已损坏", cause)

    class SnapshotTooLarge : BackupPackageException("备份文件超过安全大小限制")

    class TooManyTasks : BackupPackageException("备份中的任务数量超过 50000 条")

    class DuplicateTaskId(val taskId: String) :
        BackupPackageException("备份中存在重复任务 ID：$taskId")

    class TimestampMismatch :
        BackupPackageException("备份外层与加密正文的导出时间不一致")
}

data class BackupKdfParameters(
    val iterations: Int,
    val salt: String,
    val algorithm: String = BackupPackageCodec.KDF_ALGORITHM,
)

data class BackupCipherPayload(
    val nonce: String,
    val ciphertext: String,
    val algorithm: String = BackupPackageCodec.CIPHER_ALGORITHM,
)

data class EncryptedBackupFile(
    val createdAt: Long,
    val kdf: BackupKdfParameters,
    val cipher: BackupCipherPayload,
    val format: String = BackupPackageCodec.FILE_FORMAT,
    val version: Int = BackupPackageCodec.PROTOCOL_VERSION,
)

data class BackupSyncCredentials(
    val endpoint: String,
    val vaultId: String,
    val deviceId: String,
    val deviceToken: String,
    val vaultKey: String,
) {
    fun credentials(): SyncCredentials {
        if (!endpoint.hasCodePointLength(1..2048) ||
            !vaultId.hasCodePointLength(1..128) ||
            !deviceId.hasCodePointLength(1..128) ||
            deviceToken.length != BASE64URL_32_BYTE_LENGTH ||
            vaultKey.length != BASE64URL_32_BYTE_LENGTH
        ) {
            throw BackupPackageException.InvalidFile("syncCredentials")
        }
        val decodedKey = decodeBase64(vaultKey, "syncCredentials.vaultKey")
        val credentials = try {
            SyncCredentials(
                endpoint = endpoint,
                vaultId = vaultId,
                deviceId = deviceId,
                deviceToken = deviceToken,
                vaultKey = decodedKey,
            )
        } finally {
            decodedKey.fill(0)
        }
        try {
            credentials.validate()
        } catch (error: Exception) {
            credentials.vaultKey.fill(0)
            throw BackupPackageException.InvalidFile("syncCredentials", error)
        }
        return credentials
    }

    override fun toString(): String =
        "BackupSyncCredentials(endpoint=$endpoint, vaultId=$vaultId, deviceId=$deviceId, " +
            "deviceToken=<已隐藏>, vaultKey=<已隐藏>)"

    companion object {
        fun from(credentials: SyncCredentials): BackupSyncCredentials {
            try {
                credentials.validate()
            } catch (error: Exception) {
                throw BackupPackageException.InvalidFile("syncCredentials", error)
            }
            return BackupSyncCredentials(
                endpoint = credentials.endpoint,
                vaultId = credentials.vaultId,
                deviceId = credentials.deviceId,
                deviceToken = credentials.deviceToken,
                vaultKey = Base64Url.encode(credentials.vaultKey),
            )
        }
    }
}

data class BackupSnapshot(
    val exportedAt: Long,
    val tasks: List<TaskInstancePayload>,
    val syncCredentials: BackupSyncCredentials?,
    val protocolVersion: Int = BackupPackageCodec.PROTOCOL_VERSION,
)

object BackupKeyDerivation {
    fun normalizedPassphrase(passphrase: String): String {
        if (!passphrase.isWellFormedUnicode()) {
            throw BackupPackageException.InvalidPassphrase()
        }
        val normalized = Normalizer.normalize(passphrase, Normalizer.Form.NFKC)
        val characterCount = normalized.codePointCount(0, normalized.length)
        if (characterCount !in 10..256) {
            throw BackupPackageException.InvalidPassphrase()
        }
        return normalized
    }

    /** PBKDF2-HMAC-SHA256，口令严格以 NFKC 规范化后的 UTF-8 字节参与计算。 */
    fun deriveKey(
        passphrase: String,
        salt: ByteArray,
        iterations: Int,
    ): ByteArray {
        if (salt.size != BackupPackageCodec.SALT_BYTES) {
            throw BackupPackageException.InvalidFile("kdf.salt")
        }
        if (iterations !in BackupPackageCodec.ALLOWED_ITERATIONS) {
            throw BackupPackageException.InvalidFile("kdf.iterations")
        }

        val password = normalizedPassphrase(passphrase).toByteArray(StandardCharsets.UTF_8)
        val initial = ByteArray(salt.size + 4)
        salt.copyInto(initial)
        initial[initial.lastIndex] = 1
        val hmac = Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(password, "HmacSHA256"))
        }
        var previous = hmac.doFinal(initial)
        val output = previous.copyOf()
        try {
            repeat(iterations - 1) {
                val next = hmac.doFinal(previous)
                for (index in output.indices) {
                    output[index] = (output[index].toInt() xor next[index].toInt()).toByte()
                }
                previous.fill(0)
                previous = next
            }
            return output
        } finally {
            password.fill(0)
            initial.fill(0)
            previous.fill(0)
        }
    }
}

object BackupPackageCodec {
    const val FILE_FORMAT = "woo-todo-backup"
    const val PROTOCOL_VERSION = 1
    const val KDF_ALGORITHM = "pbkdf2-hmac-sha256"
    const val CIPHER_ALGORITHM = "aes-256-gcm"
    const val AAD_NAMESPACE = "woo-todo-backup-v1"
    const val DEFAULT_ITERATIONS = 210_000
    val ALLOWED_ITERATIONS = 100_000..2_000_000
    const val SALT_BYTES = 16
    const val MAXIMUM_TASK_COUNT = 50_000
    const val MAXIMUM_CIPHERTEXT_BYTES = 32 * 1024 * 1024
    const val MAXIMUM_CIPHERTEXT_CHARACTERS = 44_739_243
    const val MAXIMUM_FILE_BYTES = 45 * 1024 * 1024

    fun seal(
        snapshot: BackupSnapshot,
        passphrase: String,
        iterations: Int = DEFAULT_ITERATIONS,
        salt: ByteArray? = null,
        nonce: ByteArray? = null,
    ): ByteArray {
        validateSnapshot(snapshot)
        if (iterations !in ALLOWED_ITERATIONS) {
            throw BackupPackageException.InvalidFile("kdf.iterations")
        }
        val actualSalt = salt?.copyOf() ?: SecureBytes.generate(SALT_BYTES)
        if (actualSalt.size != SALT_BYTES) {
            actualSalt.fill(0)
            throw BackupPackageException.InvalidFile("kdf.salt")
        }
        val actualNonce = nonce?.copyOf() ?: SecureBytes.generate(Aes256Gcm.NONCE_BYTES)
        if (actualNonce.size != Aes256Gcm.NONCE_BYTES) {
            actualSalt.fill(0)
            actualNonce.fill(0)
            throw BackupPackageException.InvalidFile("cipher.nonce")
        }
        val plaintext = encodeSnapshot(snapshot)
        if (plaintext.size > MAXIMUM_CIPHERTEXT_BYTES - Aes256Gcm.TAG_BYTES) {
            actualSalt.fill(0)
            actualNonce.fill(0)
            plaintext.fill(0)
            throw BackupPackageException.SnapshotTooLarge()
        }

        val kdf = BackupKdfParameters(
            iterations = iterations,
            salt = Base64Url.encode(actualSalt),
        )
        val key = try {
            BackupKeyDerivation.deriveKey(passphrase, actualSalt, iterations)
        } catch (error: Exception) {
            actualSalt.fill(0)
            actualNonce.fill(0)
            plaintext.fill(0)
            throw error
        }
        val envelope = try {
            Aes256Gcm.seal(
                plaintext = plaintext,
                key = key,
                nonce = actualNonce,
                aad = aadBytes(snapshot.exportedAt, kdf),
            )
        } finally {
            key.fill(0)
            actualSalt.fill(0)
            actualNonce.fill(0)
            plaintext.fill(0)
        }
        val encoded = encodeFile(
            EncryptedBackupFile(
                createdAt = snapshot.exportedAt,
                kdf = kdf,
                cipher = BackupCipherPayload(
                    nonce = envelope.nonce,
                    ciphertext = envelope.ciphertext,
                ),
            ),
        )
        if (encoded.size > MAXIMUM_FILE_BYTES) {
            throw BackupPackageException.SnapshotTooLarge()
        }
        return encoded
    }

    fun open(data: ByteArray, passphrase: String): BackupSnapshot {
        if (data.size > MAXIMUM_FILE_BYTES) {
            throw BackupPackageException.SnapshotTooLarge()
        }
        val file = decodeFile(parseObject(data, "json", MAXIMUM_OUTER_JSON_NODES))
        val decodedFile = validateFile(file)
        val key = try {
            BackupKeyDerivation.deriveKey(
                passphrase = passphrase,
                salt = decodedFile.salt,
                iterations = file.kdf.iterations,
            )
        } catch (error: Exception) {
            decodedFile.salt.fill(0)
            throw error
        }
        val plaintext = try {
            try {
                Aes256Gcm.open(
                    envelope = EncryptedEnvelope(
                        ciphertext = file.cipher.ciphertext,
                        nonce = file.cipher.nonce,
                    ),
                    key = key,
                    aad = aadBytes(file.createdAt, file.kdf),
                )
            } catch (error: Exception) {
                throw BackupPackageException.AuthenticationFailed(error)
            }
        } finally {
            key.fill(0)
            decodedFile.salt.fill(0)
        }
        return try {
            val snapshot = decodeSnapshot(
                parseObject(plaintext, "plaintext", MAXIMUM_PLAINTEXT_JSON_NODES),
            )
            if (snapshot.exportedAt != file.createdAt) {
                throw BackupPackageException.TimestampMismatch()
            }
            snapshot
        } finally {
            plaintext.fill(0)
        }
    }

    fun canonicalAad(createdAt: Long, kdf: BackupKdfParameters): String = listOf(
        AAD_NAMESPACE,
        createdAt.toString(),
        kdf.algorithm,
        kdf.iterations.toString(),
        kdf.salt,
        CIPHER_ALGORITHM,
    ).joinToString("|")

    fun aadBytes(createdAt: Long, kdf: BackupKdfParameters): ByteArray =
        canonicalAad(createdAt, kdf).toByteArray(StandardCharsets.UTF_8)

    private data class DecodedFile(
        val salt: ByteArray,
    )

    private fun validateFile(file: EncryptedBackupFile): DecodedFile {
        if (file.format != FILE_FORMAT) throw BackupPackageException.InvalidFile("format")
        if (file.version != PROTOCOL_VERSION) {
            throw BackupPackageException.UnsupportedVersion(file.version.toLong())
        }
        if (file.createdAt !in 0..WIRE_MAXIMUM_SAFE_INTEGER) {
            throw BackupPackageException.InvalidFile("createdAt")
        }
        if (file.kdf.algorithm != KDF_ALGORITHM || file.kdf.iterations !in ALLOWED_ITERATIONS) {
            throw BackupPackageException.InvalidFile("kdf")
        }
        if (file.kdf.salt.length != BASE64URL_16_BYTE_LENGTH) {
            throw BackupPackageException.InvalidFile("kdf.salt")
        }
        val salt = decodeBase64(file.kdf.salt, "kdf.salt")
        if (salt.size != SALT_BYTES) {
            salt.fill(0)
            throw BackupPackageException.InvalidFile("kdf.salt")
        }
        try {
            if (file.cipher.algorithm != CIPHER_ALGORITHM) {
                throw BackupPackageException.InvalidFile("cipher.algorithm")
            }
            if (file.cipher.nonce.length != BASE64URL_12_BYTE_LENGTH ||
                !file.cipher.nonce.isCanonicalBase64Url()
            ) {
                throw BackupPackageException.InvalidFile("cipher.nonce")
            }
            if (file.cipher.ciphertext.length > MAXIMUM_CIPHERTEXT_CHARACTERS) {
                throw BackupPackageException.SnapshotTooLarge()
            }
            if (file.cipher.ciphertext.length < BASE64URL_16_BYTE_LENGTH ||
                !file.cipher.ciphertext.isCanonicalBase64Url()
            ) {
                throw BackupPackageException.InvalidFile("cipher.ciphertext")
            }
            return DecodedFile(salt)
        } catch (error: Exception) {
            salt.fill(0)
            throw error
        }
    }

    private fun validateSnapshot(snapshot: BackupSnapshot) {
        if (snapshot.protocolVersion != PROTOCOL_VERSION) {
            throw BackupPackageException.UnsupportedVersion(snapshot.protocolVersion.toLong())
        }
        if (snapshot.exportedAt !in 0..WIRE_MAXIMUM_SAFE_INTEGER) {
            throw BackupPackageException.InvalidFile("exportedAt")
        }
        if (snapshot.tasks.size > MAXIMUM_TASK_COUNT) {
            throw BackupPackageException.TooManyTasks()
        }
        val identifiers = HashSet<String>(snapshot.tasks.size)
        snapshot.tasks.forEachIndexed { index, task ->
            validateTask(task, "tasks[$index]")
            val canonicalId = task.id.lowercase(Locale.ROOT)
            if (!identifiers.add(canonicalId)) {
                throw BackupPackageException.DuplicateTaskId(task.id)
            }
        }
        snapshot.syncCredentials?.let(::validateCredentials)
    }

    private fun validateTask(task: TaskInstancePayload, path: String) {
        if (!task.id.hasCodePointLength(8..128) ||
            !task.seriesId.hasCodePointLength(8..128) ||
            !task.title.hasCodePointLength(1..120) ||
            !task.timezone.isWellFormedUnicode() ||
            task.periodStart?.isWellFormedUnicode() == false
        ) {
            throw BackupPackageException.InvalidFile(path)
        }
        try {
            SyncJsonCodec.encodeTaskPayload(task)
        } catch (error: Exception) {
            throw BackupPackageException.InvalidFile(path, error)
        }
    }

    private fun validateCredentials(credentials: BackupSyncCredentials) {
        if (!credentials.endpoint.hasCodePointLength(1..2048) ||
            !credentials.vaultId.hasCodePointLength(1..128) ||
            !credentials.deviceId.hasCodePointLength(1..128) ||
            credentials.deviceToken.length != BASE64URL_32_BYTE_LENGTH ||
            credentials.vaultKey.length != BASE64URL_32_BYTE_LENGTH
        ) {
            throw BackupPackageException.InvalidFile("syncCredentials")
        }
        val token = decodeBase64(credentials.deviceToken, "syncCredentials.deviceToken")
        if (token.size != 32) {
            token.fill(0)
            throw BackupPackageException.InvalidFile("syncCredentials.deviceToken")
        }
        token.fill(0)
        val key = decodeBase64(credentials.vaultKey, "syncCredentials.vaultKey")
        if (key.size != Aes256Gcm.KEY_BYTES) {
            key.fill(0)
            throw BackupPackageException.InvalidFile("syncCredentials.vaultKey")
        }
        key.fill(0)
        credentials.credentials().vaultKey.fill(0)
    }

    private fun decodeFile(root: StrictJsonObject): EncryptedBackupFile {
        root.requireExactKeys(setOf("format", "version", "createdAt", "kdf", "cipher"), "root")
        val version = root.long("version", "version", Long.MIN_VALUE..Long.MAX_VALUE)
        if (version != PROTOCOL_VERSION.toLong()) {
            throw BackupPackageException.UnsupportedVersion(version)
        }
        val kdf = root.objectValue("kdf", "kdf").also {
            it.requireExactKeys(setOf("algorithm", "iterations", "salt"), "kdf")
        }
        val cipher = root.objectValue("cipher", "cipher").also {
            it.requireExactKeys(setOf("algorithm", "nonce", "ciphertext"), "cipher")
        }
        return EncryptedBackupFile(
            format = root.string("format", "format"),
            version = version.toInt(),
            createdAt = root.long("createdAt", "createdAt", 0..WIRE_MAXIMUM_SAFE_INTEGER),
            kdf = BackupKdfParameters(
                algorithm = kdf.string("algorithm", "kdf.algorithm"),
                iterations = kdf.int("iterations", "kdf.iterations", ALLOWED_ITERATIONS),
                salt = kdf.string("salt", "kdf.salt"),
            ),
            cipher = BackupCipherPayload(
                algorithm = cipher.string("algorithm", "cipher.algorithm"),
                nonce = cipher.string("nonce", "cipher.nonce"),
                ciphertext = cipher.string("ciphertext", "cipher.ciphertext"),
            ),
        )
    }

    private fun decodeSnapshot(root: StrictJsonObject): BackupSnapshot {
        root.requireExactKeys(
            setOf("protocolVersion", "exportedAt", "tasks", "syncCredentials"),
            "plaintext",
        )
        val version = root.long(
            "protocolVersion",
            "protocolVersion",
            Long.MIN_VALUE..Long.MAX_VALUE,
        )
        if (version != PROTOCOL_VERSION.toLong()) {
            throw BackupPackageException.UnsupportedVersion(version)
        }
        val taskValues = root.array("tasks", "tasks")
        if (taskValues.size > MAXIMUM_TASK_COUNT) throw BackupPackageException.TooManyTasks()
        val tasks = taskValues.mapIndexed { index, value ->
            decodeTask(value as? StrictJsonObject ?: invalidFile("tasks[$index]"), "tasks[$index]")
        }
        val credentials = when (val value = root.value("syncCredentials", "syncCredentials")) {
            StrictJsonNull -> null
            is StrictJsonObject -> decodeCredentials(value)
            else -> invalidFile("syncCredentials")
        }
        return BackupSnapshot(
            protocolVersion = version.toInt(),
            exportedAt = root.long("exportedAt", "exportedAt", 0..WIRE_MAXIMUM_SAFE_INTEGER),
            tasks = tasks,
            syncCredentials = credentials,
        ).also(::validateSnapshot)
    }

    private fun decodeTask(root: StrictJsonObject, path: String): TaskInstancePayload {
        root.requireExactKeys(TASK_KEYS, path)
        val task = try {
            TaskInstancePayload(
                protocolVersion = root.int("protocolVersion", "$path.protocolVersion", 0..Int.MAX_VALUE),
                entityType = root.string("entityType", "$path.entityType"),
                id = root.string("id", "$path.id"),
                seriesId = root.string("seriesId", "$path.seriesId"),
                title = root.string("title", "$path.title"),
                timeType = WireTimeType.fromWire(root.string("timeType", "$path.timeType")),
                periodStart = root.nullableString("periodStart", "$path.periodStart"),
                timezone = root.string("timezone", "$path.timezone"),
                questLine = WireQuestLine.fromWire(root.string("questLine", "$path.questLine")),
                state = WireTaskState.fromWire(root.string("state", "$path.state")),
                recurrence = WireRecurrence.fromWire(root.string("recurrence", "$path.recurrence")),
                sortOrder = root.long("sortOrder", "$path.sortOrder", 0..WIRE_MAXIMUM_SORT_ORDER),
                createdAt = root.long("createdAt", "$path.createdAt", 0..WIRE_MAXIMUM_SAFE_INTEGER),
                updatedAt = root.long("updatedAt", "$path.updatedAt", 0..WIRE_MAXIMUM_SAFE_INTEGER),
                settledAt = root.nullableLong(
                    "settledAt",
                    "$path.settledAt",
                    0..WIRE_MAXIMUM_SAFE_INTEGER,
                ),
            )
        } catch (error: BackupPackageException) {
            throw error
        } catch (error: Exception) {
            throw BackupPackageException.InvalidFile(path, error)
        }
        validateTask(task, path)
        return task
    }

    private fun decodeCredentials(root: StrictJsonObject): BackupSyncCredentials {
        root.requireExactKeys(CREDENTIAL_KEYS, "syncCredentials")
        return BackupSyncCredentials(
            endpoint = root.string("endpoint", "syncCredentials.endpoint"),
            vaultId = root.string("vaultId", "syncCredentials.vaultId"),
            deviceId = root.string("deviceId", "syncCredentials.deviceId"),
            deviceToken = root.string("deviceToken", "syncCredentials.deviceToken"),
            vaultKey = root.string("vaultKey", "syncCredentials.vaultKey"),
        )
    }

    private fun encodeSnapshot(snapshot: BackupSnapshot): ByteArray = buildString {
        append('{')
        append("\"exportedAt\":").append(snapshot.exportedAt)
        append(",\"protocolVersion\":").append(snapshot.protocolVersion)
        append(",\"syncCredentials\":")
        if (snapshot.syncCredentials == null) append("null") else appendCredentials(snapshot.syncCredentials)
        append(",\"tasks\":[")
        snapshot.tasks.forEachIndexed { index, task ->
            if (index > 0) append(',')
            appendTask(task)
        }
        append("]}")
    }.toByteArray(StandardCharsets.UTF_8)

    private fun encodeFile(file: EncryptedBackupFile): ByteArray = buildString {
        append("{\"cipher\":{")
        append("\"algorithm\":").appendJsonString(file.cipher.algorithm)
        append(",\"ciphertext\":").appendJsonString(file.cipher.ciphertext)
        append(",\"nonce\":").appendJsonString(file.cipher.nonce)
        append("},\"createdAt\":").append(file.createdAt)
        append(",\"format\":").appendJsonString(file.format)
        append(",\"kdf\":{")
        append("\"algorithm\":").appendJsonString(file.kdf.algorithm)
        append(",\"iterations\":").append(file.kdf.iterations)
        append(",\"salt\":").appendJsonString(file.kdf.salt)
        append("},\"version\":").append(file.version).append('}')
    }.toByteArray(StandardCharsets.UTF_8)

    private fun StringBuilder.appendCredentials(credentials: BackupSyncCredentials) {
        append("{\"deviceId\":").appendJsonString(credentials.deviceId)
        append(",\"deviceToken\":").appendJsonString(credentials.deviceToken)
        append(",\"endpoint\":").appendJsonString(credentials.endpoint)
        append(",\"vaultId\":").appendJsonString(credentials.vaultId)
        append(",\"vaultKey\":").appendJsonString(credentials.vaultKey).append('}')
    }

    private fun StringBuilder.appendTask(task: TaskInstancePayload) {
        append("{\"createdAt\":").append(task.createdAt)
        append(",\"entityType\":").appendJsonString(task.entityType)
        append(",\"id\":").appendJsonString(task.id)
        append(",\"periodStart\":")
        if (task.periodStart == null) append("null") else appendJsonString(task.periodStart)
        append(",\"protocolVersion\":").append(task.protocolVersion)
        append(",\"questLine\":").appendJsonString(task.questLine.value)
        append(",\"recurrence\":").appendJsonString(task.recurrence.value)
        append(",\"seriesId\":").appendJsonString(task.seriesId)
        append(",\"settledAt\":").append(task.settledAt ?: "null")
        append(",\"sortOrder\":").append(task.sortOrder)
        append(",\"state\":").appendJsonString(task.state.value)
        append(",\"timeType\":").appendJsonString(task.timeType.value)
        append(",\"timezone\":").appendJsonString(task.timezone)
        append(",\"title\":").appendJsonString(task.title)
        append(",\"updatedAt\":").append(task.updatedAt).append('}')
    }

    private val TASK_KEYS = setOf(
        "protocolVersion", "entityType", "id", "seriesId", "title", "timeType",
        "periodStart", "timezone", "questLine", "state", "recurrence", "sortOrder",
        "createdAt", "updatedAt", "settledAt",
    )
    private val CREDENTIAL_KEYS =
        setOf("endpoint", "vaultId", "deviceId", "deviceToken", "vaultKey")

    private const val MAXIMUM_OUTER_JSON_NODES = 32
    private const val MAXIMUM_PLAINTEXT_JSON_NODES = 805_000
}

private fun parseObject(
    bytes: ByteArray,
    field: String,
    maximumNodes: Int,
): StrictJsonObject {
    val source = try {
        StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (error: Exception) {
        throw BackupPackageException.InvalidFile(field, error)
    }
    return try {
        StrictJsonParser(source, maximumNodes).parseRootObject()
    } catch (error: StrictJsonException) {
        throw BackupPackageException.InvalidFile(field, error)
    }
}

private fun decodeBase64(value: String, field: String): ByteArray = try {
    Base64Url.decode(value)
} catch (error: Exception) {
    throw BackupPackageException.InvalidFile(field, error)
}

private fun invalidFile(field: String): Nothing = throw BackupPackageException.InvalidFile(field)

private fun String.hasCodePointLength(range: IntRange): Boolean =
    isWellFormedUnicode() && codePointCount(0, length) in range

private fun String.isWellFormedUnicode(): Boolean {
    var index = 0
    while (index < length) {
        val current = this[index]
        when {
            Character.isHighSurrogate(current) -> {
                if (index + 1 >= length || !Character.isLowSurrogate(this[index + 1])) return false
                index += 2
            }
            Character.isLowSurrogate(current) -> return false
            else -> index += 1
        }
    }
    return true
}

private fun String.isCanonicalBase64Url(): Boolean {
    if (isEmpty() || length % 4 == 1) return false
    var lastValue = 0
    for (character in this) {
        lastValue = when (character) {
            in 'A'..'Z' -> character.code - 'A'.code
            in 'a'..'z' -> character.code - 'a'.code + 26
            in '0'..'9' -> character.code - '0'.code + 52
            '-' -> 62
            '_' -> 63
            else -> return false
        }
    }
    return when (length % 4) {
        2 -> lastValue and 0x0f == 0
        3 -> lastValue and 0x03 == 0
        else -> true
    }
}

private fun StringBuilder.appendJsonString(value: String): StringBuilder {
    append('"')
    value.forEach { character ->
        when (character) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\u000c' -> append("\\f")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (character.code < 0x20) {
                append("\\u00")
                append(HEX_DIGITS[character.code ushr 4])
                append(HEX_DIGITS[character.code and 0x0f])
            } else {
                append(character)
            }
        }
    }
    return append('"')
}

private const val HEX_DIGITS = "0123456789abcdef"
private const val BASE64URL_12_BYTE_LENGTH = 16
private const val BASE64URL_16_BYTE_LENGTH = 22
private const val BASE64URL_32_BYTE_LENGTH = 43
private val INTEGER_PATTERN = Regex("-?(0|[1-9][0-9]*)")

private sealed interface StrictJsonValue
private data class StrictJsonObject(val values: Map<String, StrictJsonValue>) : StrictJsonValue
private data class StrictJsonArray(val values: List<StrictJsonValue>) : StrictJsonValue
private data class StrictJsonString(val value: String) : StrictJsonValue
private data class StrictJsonNumber(val source: String) : StrictJsonValue
private data class StrictJsonBoolean(val value: Boolean) : StrictJsonValue
private data object StrictJsonNull : StrictJsonValue

private fun StrictJsonObject.requireExactKeys(expected: Set<String>, field: String) {
    if (values.keys != expected) invalidFile(field)
}

private fun StrictJsonObject.value(key: String, field: String): StrictJsonValue =
    values[key] ?: invalidFile(field)

private fun StrictJsonObject.string(key: String, field: String): String =
    (value(key, field) as? StrictJsonString)?.value ?: invalidFile(field)

private fun StrictJsonObject.nullableString(key: String, field: String): String? =
    when (val value = value(key, field)) {
        StrictJsonNull -> null
        is StrictJsonString -> value.value
        else -> invalidFile(field)
    }

private fun StrictJsonObject.objectValue(key: String, field: String): StrictJsonObject =
    value(key, field) as? StrictJsonObject ?: invalidFile(field)

private fun StrictJsonObject.array(key: String, field: String): List<StrictJsonValue> =
    (value(key, field) as? StrictJsonArray)?.values ?: invalidFile(field)

private fun StrictJsonObject.long(key: String, field: String, range: LongRange): Long {
    val number = (value(key, field) as? StrictJsonNumber)?.source ?: invalidFile(field)
    if (!INTEGER_PATTERN.matches(number)) invalidFile(field)
    val decoded = number.toLongOrNull() ?: invalidFile(field)
    if (decoded !in range) invalidFile(field)
    return decoded
}

private fun StrictJsonObject.int(key: String, field: String, range: IntRange): Int {
    val decoded = long(key, field, range.first.toLong()..range.last.toLong())
    return decoded.toInt()
}

private fun StrictJsonObject.nullableLong(key: String, field: String, range: LongRange): Long? =
    when (value(key, field)) {
        StrictJsonNull -> null
        is StrictJsonNumber -> long(key, field, range)
        else -> invalidFile(field)
    }

private class StrictJsonException(message: String) : Exception(message)

private class StrictJsonParser(
    private val source: String,
    private val maximumNodes: Int,
) {
    private var index = 0
    private var nodeCount = 0

    fun parseRootObject(): StrictJsonObject {
        val root = parseValue(0) as? StrictJsonObject ?: fail("根节点必须是对象")
        skipWhitespace()
        if (index != source.length) fail("JSON 末尾存在多余内容")
        return root
    }

    private fun parseValue(depth: Int): StrictJsonValue {
        if (depth > MAXIMUM_DEPTH) fail("JSON 嵌套过深")
        nodeCount += 1
        if (nodeCount > maximumNodes) fail("JSON 节点数量超过安全限制")
        skipWhitespace()
        if (index >= source.length) fail("JSON 意外结束")
        return when (source[index]) {
            '{' -> parseObject(depth + 1)
            '[' -> parseArray(depth + 1)
            '"' -> StrictJsonString(parseString())
            't' -> parseLiteral("true", StrictJsonBoolean(true))
            'f' -> parseLiteral("false", StrictJsonBoolean(false))
            'n' -> parseLiteral("null", StrictJsonNull)
            '-', in '0'..'9' -> StrictJsonNumber(parseNumber())
            else -> fail("JSON 值无效")
        }
    }

    private fun parseObject(depth: Int): StrictJsonObject {
        expect('{')
        skipWhitespace()
        val values = linkedMapOf<String, StrictJsonValue>()
        if (consume('}')) return StrictJsonObject(values)
        while (true) {
            skipWhitespace()
            if (index >= source.length || source[index] != '"') fail("对象键必须是字符串")
            val key = parseString()
            if (key in values) fail("对象包含重复键")
            skipWhitespace()
            expect(':')
            values[key] = parseValue(depth)
            skipWhitespace()
            if (consume('}')) break
            expect(',')
        }
        return StrictJsonObject(values)
    }

    private fun parseArray(depth: Int): StrictJsonArray {
        expect('[')
        skipWhitespace()
        val values = mutableListOf<StrictJsonValue>()
        if (consume(']')) return StrictJsonArray(values)
        while (true) {
            values += parseValue(depth)
            skipWhitespace()
            if (consume(']')) break
            expect(',')
        }
        return StrictJsonArray(values)
    }

    private fun parseString(): String {
        expect('"')
        val contentStart = index
        var segmentStart = index
        var result: StringBuilder? = null
        while (index < source.length) {
            val characterIndex = index
            val character = source[index++]
            when {
                character == '"' -> {
                    val value = if (result == null) {
                        source.substring(contentStart, characterIndex)
                    } else {
                        result.append(source, segmentStart, characterIndex).toString()
                    }
                    if (!value.isWellFormedUnicode()) fail("字符串包含无效 Unicode")
                    return value
                }
                character == '\\' -> {
                    val builder = result ?: StringBuilder(characterIndex - contentStart + 16).also {
                        result = it
                    }
                    builder.append(source, segmentStart, characterIndex)
                    builder.append(parseEscape())
                    segmentStart = index
                }
                character.code < 0x20 -> fail("字符串包含未转义控制字符")
            }
        }
        fail("字符串意外结束")
    }

    private fun parseEscape(): Char {
        if (index >= source.length) fail("转义序列意外结束")
        return when (val escaped = source[index++]) {
            '"', '\\', '/' -> escaped
            'b' -> '\b'
            'f' -> '\u000c'
            'n' -> '\n'
            'r' -> '\r'
            't' -> '\t'
            'u' -> {
                if (index + 4 > source.length) fail("Unicode 转义不完整")
                val code = source.substring(index, index + 4).toIntOrNull(16)
                    ?: fail("Unicode 转义无效")
                index += 4
                code.toChar()
            }
            else -> fail("未知转义字符：$escaped")
        }
    }

    private fun parseNumber(): String {
        val start = index
        consume('-')
        if (index >= source.length) fail("数字意外结束")
        if (consume('0')) {
            if (index < source.length && source[index] in '0'..'9') fail("数字存在前导零")
        } else {
            if (source[index] !in '1'..'9') fail("数字整数部分无效")
            while (index < source.length && source[index] in '0'..'9') index += 1
        }
        if (consume('.')) {
            consumeDigits("数字小数部分无效")
        }
        if (index < source.length && source[index] in charArrayOf('e', 'E')) {
            index += 1
            if (index < source.length && source[index] in charArrayOf('+', '-')) index += 1
            consumeDigits("数字指数部分无效")
        }
        return source.substring(start, index)
    }

    private fun consumeDigits(message: String) {
        val start = index
        while (index < source.length && source[index] in '0'..'9') index += 1
        if (index == start) fail(message)
    }

    private fun <T : StrictJsonValue> parseLiteral(literal: String, value: T): T {
        if (!source.startsWith(literal, index)) fail("JSON 字面量无效")
        index += literal.length
        return value
    }

    private fun skipWhitespace() {
        while (index < source.length && source[index] in JSON_WHITESPACE) index += 1
    }

    private fun expect(character: Char) {
        if (!consume(character)) fail("应为字符 $character")
    }

    private fun consume(character: Char): Boolean {
        if (index < source.length && source[index] == character) {
            index += 1
            return true
        }
        return false
    }

    private fun fail(message: String): Nothing =
        throw StrictJsonException("$message（位置 $index）")

    private companion object {
        const val MAXIMUM_DEPTH = 64
        val JSON_WHITESPACE = charArrayOf(' ', '\t', '\n', '\r')
    }
}
