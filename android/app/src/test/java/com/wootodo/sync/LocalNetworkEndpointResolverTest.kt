package com.wootodo.sync

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class LocalNetworkEndpointResolverTest {
    private val request = SyncRequest(cursor = 7, push = emptyList())
    private val credential = BearerCredential(Base64Url.encode(ByteArray(32) { 1 }))
    private val response = SyncData(
        push = SyncPushSummary(received = 0, inserted = 0, duplicates = 0),
        pull = emptyList(),
        cursor = 7,
        hasMore = false,
        serverTime = 10,
    )

    @Test
    fun `同步空间指纹与Mac端协议一致且不包含原始标识`() {
        val fingerprint = LocalNetworkDiscoveryIdentity.vaultFingerprint("vault-local-network")

        assertEquals("RfUwop7bTtqyqSTnYPOC59GEb1TR5lF0zufaM5aoNGE", fingerprint)
        assertFalse(fingerprint.contains("vault-local-network"))
    }

    @Test
    fun `旧IP失败后发现同一空间的新地址并在后续分页复用`() {
        val oldEndpoint = "http://192.168.1.10:48473"
        val newEndpoint = "http://192.168.1.23:48473"
        val attempts = mutableListOf<String>()
        val recovered = mutableListOf<String>()
        var discoveries = 0
        val transport = RecoveringLocalNetworkSyncTransport(
            initialEndpoint = oldEndpoint,
            vaultId = "vault-local-network",
            resolver = LocalNetworkServiceResolver {
                discoveries += 1
                listOf(oldEndpoint, newEndpoint)
            },
            transportFactory = { endpoint ->
                RecordingTransport(endpoint, attempts) {
                    if (endpoint == oldEndpoint) {
                        throw SyncApiException.Transport(IOException("旧地址不可达"), true)
                    }
                    response
                }
            },
            onEndpointRecovered = { recovered += it },
        )

        assertEquals(response, transport.sync(request, credential))
        assertEquals(response, transport.sync(request.copy(cursor = 8), credential))

        assertEquals(listOf(oldEndpoint, newEndpoint, newEndpoint), attempts)
        assertEquals(listOf(newEndpoint), recovered)
        assertEquals(1, discoveries)
    }

    @Test
    fun `未发现新地址时保留原始网络错误供自动重试`() {
        val original = SyncApiException.Transport(IOException("offline"), true)
        val transport = RecoveringLocalNetworkSyncTransport(
            initialEndpoint = "http://192.168.1.10:48473",
            vaultId = "vault-local-network",
            resolver = LocalNetworkServiceResolver { emptyList() },
            transportFactory = {
                RecordingTransport(it, mutableListOf()) { throw original }
            },
        )

        val thrown = assertThrows(SyncApiException.Transport::class.java) {
            transport.sync(request, credential)
        }

        assertSame(original, thrown)
    }
}

private class RecordingTransport(
    private val endpoint: String,
    private val attempts: MutableList<String>,
    private val response: () -> SyncData,
) : SyncTransport {
    override fun sync(request: SyncRequest, credential: BearerCredential): SyncData {
        attempts += endpoint
        return response()
    }
}
