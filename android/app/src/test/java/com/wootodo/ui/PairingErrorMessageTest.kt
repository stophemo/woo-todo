package com.wootodo.ui

import com.wootodo.sync.PairingException
import com.wootodo.sync.SyncApiException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingErrorMessageTest {
    @Test
    fun `回环地址错误说明127在手机上的真实含义`() {
        val message = PairingErrorMessage.from(PairingException.CurrentDeviceOnlyEndpoint)

        assertTrue(message.contains("只代表手机自己"))
        assertTrue(message.contains("HTTPS Worker"))
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

        assertTrue(unknownHost.contains("已部署 Worker"))
        assertTrue(timeout.contains("超时"))
        assertTrue(certificate.contains("HTTPS 证书"))
    }
}
