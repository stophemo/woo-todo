package com.wootodo.sync

import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingDeepLinkTest {
    @Test
    fun `配对深链严格往返`() {
        val link = PairingDeepLink(
            endpoint = "https://sync.example.test/root",
            pairingId = "pair-001",
            pairingSecret = Base64Url.encode(ByteArray(32) { 4 }),
            initiatorPublicKey = Base64Url.encode(ByteArray(32) { 5 }),
        )

        val uri = link.toUri()
        assertEquals(link, PairingDeepLink.parse(uri))
        assertTrue(uri.contains("initiatorPublicKey="))
        assertFalse(uri.contains("publicKey="))
        assertFalse(link.toString().contains(link.pairingSecret))
        assertFalse(link.toString().contains(link.initiatorPublicKey))
    }

    @Test
    fun `配对深链拒绝未知字段和短密钥`() {
        assertThrows(IllegalArgumentException::class.java) {
            PairingDeepLink.parse(
                "wootodo://pair?endpoint=https%3A%2F%2Fexample.test&pairingId=p&" +
                    "pairingSecret=AA&initiatorPublicKey=AA&extra=1",
            )
        }
    }

    @Test
    fun `配对深链只允许HTTPS和本机HTTP`() {
        val secret = Base64Url.encode(ByteArray(32) { 1 })
        val publicKey = Base64Url.encode(ByteArray(32) { 2 })
        val suffix = "&pairingId=pair-1&pairingSecret=$secret&initiatorPublicKey=$publicKey"

        assertThrows(IllegalArgumentException::class.java) {
            PairingDeepLink.parse("wootodo://pair?endpoint=http%3A%2F%2Fexample.test$suffix")
        }
        assertEquals(
            "http://127.0.0.1:8787",
            PairingDeepLink.parse(
                "wootodo://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787$suffix",
            ).endpoint,
        )
    }

    @Test
    fun `端点策略区分双端地址与当前设备回环地址`() {
        assertEquals(
            SyncEndpointScope.CROSS_DEVICE,
            SyncEndpointPolicy.scope(URI("https://sync.example.test")),
        )
        assertEquals(
            SyncEndpointScope.CURRENT_DEVICE_ONLY,
            SyncEndpointPolicy.scope(URI("https://localhost:8787")),
        )
        assertEquals(
            SyncEndpointScope.CURRENT_DEVICE_ONLY,
            SyncEndpointPolicy.scope(URI("http://127.0.0.1:8787")),
        )
        assertEquals(
            SyncEndpointScope.INVALID,
            SyncEndpointPolicy.scope(URI("http://192.168.1.10:8787")),
        )
    }
}
