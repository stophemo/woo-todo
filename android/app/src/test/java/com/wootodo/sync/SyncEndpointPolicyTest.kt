package com.wootodo.sync

import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncEndpointPolicyTest {
    @Test
    fun `只接受公网HTTPS Worker地址`() {
        listOf(
            "https://sync.example.test",
            "https://sync.example.test/",
            "https://woo-todo.workers.dev",
            "https://sync.example.test:8443",
        ).forEach { value ->
            assertTrue(value, SyncEndpointPolicy.isValid(value))
        }

        listOf(
            "http://sync.example.test",
            "https://localhost",
            "https://127.0.0.1",
            "https://192.168.1.10",
            "https://10.0.0.8",
            "https://172.20.1.1",
            "https://woo-todo.local",
            "https://sync.example.test/root",
            "https://user:pass@sync.example.test",
            "https://sync.example.test?x=1",
            "https://sync.example.test#fragment",
            "ftp://sync.example.test",
            "",
        ).forEach { value ->
            assertFalse(value, SyncEndpointPolicy.isValid(value))
        }
    }

    @Test
    fun `规范化去掉首尾空白和末尾斜杠`() {
        assertEquals(
            "https://sync.example.test",
            SyncEndpointPolicy.normalize("  https://sync.example.test/  "),
        )
        assertNull(SyncEndpointPolicy.normalize(null))
        assertNull(SyncEndpointPolicy.normalize("   "))
    }

    @Test
    fun `优先使用有效凭据地址其次构建期地址最后自填地址`() {
        assertEquals(
            "https://credentials.example.test",
            SyncEndpointPolicy.resolvePreferredEndpoint(
                credentialsEndpoint = "https://credentials.example.test",
                buildEndpoint = "https://build.example.test",
                savedEndpoint = "https://saved.example.test",
            ),
        )
        assertEquals(
            "https://build.example.test",
            SyncEndpointPolicy.resolvePreferredEndpoint(
                credentialsEndpoint = "http://192.168.1.10:48473",
                buildEndpoint = "https://build.example.test",
                savedEndpoint = "https://saved.example.test",
            ),
        )
        assertEquals(
            "https://saved.example.test",
            SyncEndpointPolicy.resolvePreferredEndpoint(
                credentialsEndpoint = null,
                buildEndpoint = " ",
                savedEndpoint = "https://saved.example.test",
            ),
        )
        assertNull(
            SyncEndpointPolicy.resolvePreferredEndpoint(null, null, null),
        )
    }

    @Test
    fun `旧版局域网地址被判定为不合法`() {
        assertFalse(SyncEndpointPolicy.isAllowed(URI("http://woo-mac.local:48473")))
        assertFalse(SyncEndpointPolicy.isAllowed(URI("http://127.0.0.1:8787")))
    }

    @Test
    fun `拒绝回环链路本地与私网地址的各种写法`() {
        listOf(
            "https://localhost.",
            "https://pair.localhost",
            "https://127.0.0.2",
            "https://127.255.255.255",
            "https://0.0.0.0",
            "https://0.10.20.30",
            "https://169.254.169.254",
            "https://100.64.0.1",
            "https://100.127.255.255",
            "https://[::]",
            "https://[::1]",
            "https://[fc00::1]",
            "https://[fd12:3456::1]",
            "https://[fe80::1]",
            "https://[::ffff:192.168.1.1]",
            "https://[::ffff:127.0.0.1]",
        ).forEach { value ->
            assertFalse(value, SyncEndpointPolicy.isValid(value))
        }
    }

    @Test
    fun `拒绝非规范数值主机写法`() {
        listOf(
            "https://127.1",
            "https://2130706433",
            "https://0127.0.0.1",
            "https://127.0.0.01",
            "https://127.000.000.001",
            "https://0x7f000001",
            "https://0X7F000001",
            "https://0x7f.0.0.1",
            "https://0177.0.0.1",
            "https://256.0.0.1",
            "https://999.999.999.999",
            "https://0",
            "https://0.0.0.0",
            "https://4294967295",
        ).forEach { value ->
            assertFalse(value, SyncEndpointPolicy.isValid(value))
        }

        // 依赖 DNS 的域名与规范公网 IP 不受影响。
        listOf(
            "https://sync.example.test",
            "https://1.1.1.1",
            "https://8.8.8.8",
            "https://100.128.0.1",
        ).forEach { value ->
            assertTrue(value, SyncEndpointPolicy.isValid(value))
        }
    }

    @Test
    fun `公网地址与带尾点的公网主机名仍然可用`() {
        listOf(
            "https://sync.example.test.",
            "https://8.8.8.8",
            "https://100.128.0.1",
            "https://[2001:db8::1]",
            "https://[::ffff:8.8.8.8]",
        ).forEach { value ->
            assertTrue(value, SyncEndpointPolicy.isValid(value))
        }
    }
}
