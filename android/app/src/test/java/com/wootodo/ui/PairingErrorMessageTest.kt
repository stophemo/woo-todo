package com.wootodo.ui

import com.wootodo.sync.PairingException
import com.wootodo.sync.SyncApiException
import com.wootodo.sync.SyncCryptoException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.InvalidAlgorithmParameterException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingErrorMessageTest {
    @Test
    fun `配对异常直接给出中文提示`() {
        val notFound = PairingErrorMessage.from(PairingException.JoinNotFound)
        val limit = PairingErrorMessage.from(PairingException.DeviceLimit)

        assertTrue(notFound.contains("5 分钟"))
        assertTrue(notFound.contains("重新输入"))
        assertTrue(limit.contains("4 台"))
        assertTrue(limit.contains("移除"))
    }

    @Test
    fun `网络错误给出可执行的分类型提示`() {
        val unknownHost = PairingErrorMessage.from(
            SyncApiException.Transport(UnknownHostException("测试域名不存在")),
        )
        val timeout = PairingErrorMessage.from(
            SyncApiException.Transport(SocketTimeoutException("测试超时")),
        )
        val certificate = PairingErrorMessage.from(
            SyncApiException.Transport(SSLHandshakeException("测试证书错误")),
        )

        assertTrue(unknownHost.contains("服务器地址"))
        assertTrue(timeout.contains("超时"))
        assertTrue(certificate.contains("HTTPS 证书"))
        assertFalse(unknownHost.contains("Mac"))
    }

    @Test
    fun `服务端配对错误映射为对应中文提示`() {
        val expired = PairingErrorMessage.from(
            SyncApiException.Server(
                statusCode = 410,
                payload = com.wootodo.sync.ServerErrorPayload(
                    "PAIRING_EXPIRED",
                    "配对请求已过期",
                ),
                requestId = "req",
            ),
        )
        val capacity = PairingErrorMessage.from(
            SyncApiException.Server(
                statusCode = 409,
                payload = com.wootodo.sync.ServerErrorPayload(
                    "VAULT_DEVICE_LIMIT",
                    "设备数量已达上限",
                ),
                requestId = "req",
            ),
        )

        assertTrue(expired.contains("5 分钟"))
        assertTrue(capacity.contains("4 台"))
    }

    @Test
    fun `Provider兼容错误不向用户暴露英文实现细节`() {
        val message = PairingErrorMessage.from(
            SyncCryptoException(
                "当前系统无法生成 X25519 临时密钥",
                InvalidAlgorithmParameterException(
                    "No AlgorithmParameterSpec classes are supported",
                ),
            ),
        )

        assertTrue(message.contains("密钥协商"))
        assertFalse(message.contains("AlgorithmParameterSpec"))
    }
}
