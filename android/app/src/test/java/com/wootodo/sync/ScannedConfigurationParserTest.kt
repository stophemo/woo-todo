package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ScannedConfigurationParserTest {
    @Test
    fun `识别Mac生成的坚果云配置并保留预填字段`() {
        val setup = WebDavSetupLink(
            username = "person@example.com",
            appPassword = "app-password",
            vaultId = "personal-vault",
            vaultKey = ByteArray(Aes256Gcm.KEY_BYTES) { it.toByte() },
        )

        val parsed = ScannedConfigurationParser.parse(setup.toUri())

        assertTrue(parsed is ScannedConfiguration.WebDav)
        parsed as ScannedConfiguration.WebDav
        assertEquals(setup, parsed.setupLink)
    }

    @Test
    fun `继续兼容Worker配对二维码`() {
        val link = PairingDeepLink(
            endpoint = "https://sync.example.test",
            pairingId = "pairing-123",
            pairingSecret = Base64Url.encode(ByteArray(32) { 1 }),
            initiatorPublicKey = Base64Url.encode(ByteArray(32) { 2 }),
        )

        val parsed = ScannedConfigurationParser.parse(link.toUri())

        assertTrue(parsed is ScannedConfiguration.WorkerPairing)
        parsed as ScannedConfiguration.WorkerPairing
        assertEquals(link, parsed.pairingLink)
    }

    @Test
    fun `粘贴配对链接时忽略首尾空白`() {
        val link = PairingDeepLink(
            endpoint = "https://sync.example.test",
            pairingId = "pairing-pasted",
            pairingSecret = Base64Url.encode(ByteArray(32) { 5 }),
            initiatorPublicKey = Base64Url.encode(ByteArray(32) { 6 }),
        )

        val parsed = ScannedConfigurationParser.parse("  ${link.toUri()}\n")

        assertTrue(parsed is ScannedConfiguration.WorkerPairing)
        assertEquals(link, (parsed as ScannedConfiguration.WorkerPairing).pairingLink)
    }

    @Test
    fun `拒绝网页文本和字段被篡改的配置`() {
        listOf(
            "https://github.com/stophemo/woo-todo",
            "普通文本",
            "wootodo://webdav?v=1",
            "wootodo://pair?pairingId=missing-fields",
        ).forEach { source ->
            assertThrows(IllegalArgumentException::class.java) {
                ScannedConfigurationParser.parse(source)
            }
        }
    }
}
