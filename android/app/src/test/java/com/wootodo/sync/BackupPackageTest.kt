package com.wootodo.sync

import java.nio.charset.StandardCharsets
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Test

class BackupPackageTest {
    @Test
    fun `共享备份 golden 向量严格匹配并可双向恢复`() {
        val vector = fixture()
        val password = vector.getString("password")
        val kdf = vector.getJSONObject("kdf")
        val cipher = vector.getJSONObject("cipher")
        val salt = Base64Url.decode(kdf.getString("salt"))
        val nonce = Base64Url.decode(cipher.getString("nonce"))

        assertEquals(
            vector.getString("passwordNormalized"),
            BackupKeyDerivation.normalizedPassphrase(password),
        )
        val derivedKey = BackupKeyDerivation.deriveKey(
            passphrase = password,
            salt = salt,
            iterations = kdf.getInt("iterations"),
        )
        assertEquals(vector.getString("derivedKey"), Base64Url.encode(derivedKey))

        val kdfParameters = BackupKdfParameters(
            algorithm = kdf.getString("algorithm"),
            iterations = kdf.getInt("iterations"),
            salt = kdf.getString("salt"),
        )
        assertEquals(
            vector.getString("aadUtf8"),
            BackupPackageCodec.canonicalAad(vector.getLong("createdAt"), kdfParameters),
        )

        val snapshot = BackupPackageCodec.open(encryptedFile(vector), password)
        assertEquals(vector.getLong("createdAt"), snapshot.exportedAt)
        assertEquals(1, snapshot.tasks.size)
        assertEquals(emptyList<TombstonePayload>(), snapshot.tombstones)
        assertEquals("提交周报", snapshot.tasks.single().title)
        assertEquals(WireTaskState.COMPLETED, snapshot.tasks.single().state)
        assertNotNull(snapshot.syncCredentials)
        val credentials = requireNotNull(snapshot.syncCredentials).credentials()
        assertEquals("https://sync.example.test", credentials.endpoint)
        assertEquals("vault-backup-1", credentials.vaultId)
        assertEquals("device-backup-1", credentials.deviceId)
        assertArrayEquals(ByteArray(32) { 3 }, credentials.vaultKey)
        val printableSnapshot = snapshot.toString()
        assertFalse(printableSnapshot.contains(credentials.deviceToken))
        assertFalse(printableSnapshot.contains(Base64Url.encode(credentials.vaultKey)))

        val sealed = BackupPackageCodec.seal(
            snapshot = snapshot,
            passphrase = password,
            iterations = kdf.getInt("iterations"),
            salt = salt,
            nonce = nonce,
        )
        val sealedJson = JSONObject(String(sealed, StandardCharsets.UTF_8))
        assertEquals(cipher.getString("ciphertext"), sealedJson.getJSONObject("cipher").getString("ciphertext"))
        assertEquals(cipher.getString("nonce"), sealedJson.getJSONObject("cipher").getString("nonce"))

        val plaintext = Aes256Gcm.open(
            EncryptedEnvelope(
                ciphertext = cipher.getString("ciphertext"),
                nonce = cipher.getString("nonce"),
            ),
            derivedKey,
            BackupPackageCodec.aadBytes(vector.getLong("createdAt"), kdfParameters),
        )
        assertEquals(vector.getString("plaintextUtf8"), String(plaintext, StandardCharsets.UTF_8))
    }

    @Test
    fun `新备份保留删除屏障且旧备份缺失字段仍兼容`() {
        val vector = fixture()
        val tombstonePlaintext = JSONObject(vector.getString("tombstonePlaintextUtf8"))
        val deleted = tombstonePlaintext.getJSONArray("tombstones").getJSONObject(0)
        val snapshot = BackupSnapshot(
            exportedAt = tombstonePlaintext.getLong("exportedAt"),
            tasks = emptyList(),
            syncCredentials = null,
            tombstones = listOf(
                TombstonePayload(
                    id = deleted.getString("id"),
                    deletedAt = deleted.getLong("deletedAt"),
                ),
            ),
        )
        val sealed = BackupPackageCodec.seal(
            snapshot = snapshot,
            passphrase = vector.getString("password"),
            iterations = vector.getJSONObject("kdf").getInt("iterations"),
            salt = Base64Url.decode(vector.getJSONObject("kdf").getString("salt")),
            nonce = Base64Url.decode(vector.getJSONObject("cipher").getString("nonce")),
        )

        assertEquals(snapshot, BackupPackageCodec.open(sealed, vector.getString("password")))
        val plaintext = decryptPlaintext(sealed, vector)
        assertEquals(1, JSONObject(plaintext).getJSONArray("tombstones").length())
        assertFalse(JSONObject(vector.getString("plaintextUtf8")).has("tombstones"))
    }

    @Test
    fun `错误口令和密文篡改均被认证层拒绝`() {
        val vector = fixture()
        assertThrows(BackupPackageException.AuthenticationFailed::class.java) {
            BackupPackageCodec.open(encryptedFile(vector), "这是另一个足够长的错误口令")
        }

        val tampered = JSONObject(String(encryptedFile(vector), StandardCharsets.UTF_8))
        val cipher = tampered.getJSONObject("cipher")
        val original = cipher.getString("ciphertext")
        val replacement = if (original[0] == 'A') 'B' else 'A'
        cipher.put("ciphertext", replacement + original.drop(1))
        assertThrows(BackupPackageException.AuthenticationFailed::class.java) {
            BackupPackageCodec.open(
                tampered.toString().toByteArray(StandardCharsets.UTF_8),
                vector.getString("password"),
            )
        }
    }

    @Test
    fun `严格JSON拒绝未知字段和重复键`() {
        val vector = fixture()
        val unknownField = JSONObject(String(encryptedFile(vector), StandardCharsets.UTF_8))
            .put("unexpected", true)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        assertThrows(BackupPackageException.InvalidFile::class.java) {
            BackupPackageCodec.open(unknownField, vector.getString("password"))
        }

        val source = String(encryptedFile(vector), StandardCharsets.UTF_8)
        val duplicateKey = source.replaceFirst("{", "{\"format\":\"woo-todo-backup\",")
        assertThrows(BackupPackageException.InvalidFile::class.java) {
            BackupPackageCodec.open(
                duplicateKey.toByteArray(StandardCharsets.UTF_8),
                vector.getString("password"),
            )
        }
    }

    @Test
    fun `解密正文同样严格拒绝未知字段`() {
        val vector = fixture()
        val kdfJson = vector.getJSONObject("kdf")
        val kdf = BackupKdfParameters(
            algorithm = kdfJson.getString("algorithm"),
            iterations = kdfJson.getInt("iterations"),
            salt = kdfJson.getString("salt"),
        )
        val invalidPlaintext = vector.getString("plaintextUtf8")
            .replaceFirst("{", "{\"unexpected\":true,")
            .toByteArray(StandardCharsets.UTF_8)
        val envelope = Aes256Gcm.seal(
            plaintext = invalidPlaintext,
            key = Base64Url.decode(vector.getString("derivedKey")),
            nonce = Base64Url.decode(vector.getJSONObject("cipher").getString("nonce")),
            aad = BackupPackageCodec.aadBytes(vector.getLong("createdAt"), kdf),
        )
        val file = JSONObject(String(encryptedFile(vector), StandardCharsets.UTF_8))
        file.getJSONObject("cipher").put("ciphertext", envelope.ciphertext)

        assertThrows(BackupPackageException.InvalidFile::class.java) {
            BackupPackageCodec.open(
                file.toString().toByteArray(StandardCharsets.UTF_8),
                vector.getString("password"),
            )
        }
    }

    @Test
    fun `备份快照拒绝重复ID和超量任务`() {
        val task = fixtureTask()
        val duplicate = task.copy(id = task.id.uppercase())
        assertThrows(BackupPackageException.DuplicateTaskId::class.java) {
            BackupPackageCodec.seal(
                BackupSnapshot(
                    exportedAt = 1,
                    tasks = listOf(task, duplicate),
                    syncCredentials = null,
                ),
                "这是一个满足长度要求的备份口令",
            )
        }

        assertThrows(BackupPackageException.DuplicateTaskId::class.java) {
            BackupPackageCodec.seal(
                BackupSnapshot(
                    exportedAt = 1,
                    tasks = listOf(task),
                    syncCredentials = null,
                    tombstones = listOf(TombstonePayload(id = task.id, deletedAt = 1)),
                ),
                "这是一个满足长度要求的备份口令",
            )
        }

        assertThrows(BackupPackageException.TooManyTasks::class.java) {
            BackupPackageCodec.seal(
                BackupSnapshot(
                    exportedAt = 1,
                    tasks = List(BackupPackageCodec.MAXIMUM_TASK_COUNT + 1) { task },
                    syncCredentials = null,
                ),
                "这是一个满足长度要求的备份口令",
            )
        }
    }

    private fun decryptPlaintext(fileBytes: ByteArray, vector: JSONObject): String {
        val file = JSONObject(String(fileBytes, StandardCharsets.UTF_8))
        val kdfJson = file.getJSONObject("kdf")
        val kdf = BackupKdfParameters(
            algorithm = kdfJson.getString("algorithm"),
            iterations = kdfJson.getInt("iterations"),
            salt = kdfJson.getString("salt"),
        )
        val key = BackupKeyDerivation.deriveKey(
            vector.getString("password"),
            Base64Url.decode(kdf.salt),
            kdf.iterations,
        )
        val cipher = file.getJSONObject("cipher")
        val plaintext = Aes256Gcm.open(
            EncryptedEnvelope(cipher.getString("ciphertext"), cipher.getString("nonce")),
            key,
            BackupPackageCodec.aadBytes(file.getLong("createdAt"), kdf),
        )
        return String(plaintext, StandardCharsets.UTF_8)
    }

    private fun encryptedFile(vector: JSONObject): ByteArray = JSONObject()
        .put("format", vector.getString("format"))
        .put("version", vector.getInt("version"))
        .put("createdAt", vector.getLong("createdAt"))
        .put("kdf", vector.getJSONObject("kdf"))
        .put("cipher", vector.getJSONObject("cipher"))
        .toString()
        .toByteArray(StandardCharsets.UTF_8)

    private fun fixtureTask(): TaskInstancePayload = TaskInstancePayload(
        id = "550e8400-e29b-41d4-a716-446655440000",
        seriesId = "550e8400-e29b-41d4-a716-446655440000",
        title = "提交周报",
        timeType = WireTimeType.DAY,
        periodStart = "2026-07-16",
        timezone = "Asia/Shanghai",
        questLine = WireQuestLine.MAIN,
        state = WireTaskState.COMPLETED,
        recurrence = WireRecurrence.ONCE,
        sortOrder = 0,
        createdAt = 1,
        updatedAt = 2,
        settledAt = 2,
    )

    private fun fixture(): JSONObject {
        val stream = requireNotNull(
            javaClass.classLoader?.getResourceAsStream("backup-vectors.json"),
        ) { "缺少共享备份向量 backup-vectors.json" }
        return stream.bufferedReader(StandardCharsets.UTF_8).use { JSONObject(it.readText()) }
    }
}
