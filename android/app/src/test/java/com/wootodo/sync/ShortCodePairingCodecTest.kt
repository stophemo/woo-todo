package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class ShortCodePairingCodecTest {
    private val secret = Base64Url.encode(ByteArray(32) { 1 })
    private val publicKey = Base64Url.encode(ByteArray(32) { 2 })

    @Test
    fun `六位码请求严格编码为六位数字`() {
        assertEquals(
            "{\"code\":\"012345\"}",
            SyncJsonCodec.encode(ResolveShortCodeRequest("012345")),
        )
        assertThrows(IllegalArgumentException::class.java) {
            SyncJsonCodec.encode(ResolveShortCodeRequest("12345"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            SyncJsonCodec.encode(ResolveShortCodeRequest("12345a"))
        }
    }

    @Test
    fun `解析六位码响应`() {
        val source = """
            {"ok":true,"data":{"pairingId":"pair-1","pairingSecret":"$secret",
            "initiatorPublicKey":"$publicKey","vaultId":"vault-1","expiresAt":1000},
            "requestId":"req-1"}
        """.trimIndent()

        val data = SyncJsonCodec.decodeResolveShortCodeData(source)
        assertEquals("pair-1", data.pairingId)
        assertEquals(secret, data.pairingSecret)
        assertEquals(publicKey, data.initiatorPublicKey)
        assertEquals("vault-1", data.vaultId)
        assertEquals(1_000L, data.expiresAt)
    }

    @Test
    fun `创建配对响应可选择携带六位码`() {
        val withCode = """
            {"ok":true,"data":{"pairingId":"pair-1","pairingSecret":"$secret",
            "initiatorPublicKey":"$publicKey","expiresAt":1000,"serverTime":500,
            "shortCode":"012345"},"requestId":"req-1"}
        """.trimIndent()
        assertEquals("012345", SyncJsonCodec.decodeCreatePairingData(withCode).shortCode)

        val withoutCode = """
            {"ok":true,"data":{"pairingId":"pair-1","pairingSecret":"$secret",
            "initiatorPublicKey":"$publicKey","expiresAt":1000,"serverTime":500},
            "requestId":"req-1"}
        """.trimIndent()
        assertNull(SyncJsonCodec.decodeCreatePairingData(withoutCode).shortCode)
    }
}
