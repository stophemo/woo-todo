package com.wootodo.ui

import com.wootodo.sync.SyncCryptoException
import com.wootodo.sync.WebDavException
import com.wootodo.sync.WebDavPairingException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingErrorMessageTest {
    @Test
    fun `配对码错误直接给出五分钟提示`() {
        val notFound = PairingErrorMessage.from(WebDavPairingException.OfferNotFound)
        val expired = PairingErrorMessage.from(WebDavPairingException.Expired)

        assertTrue(notFound.contains("5 分钟"))
        assertTrue(notFound.contains("重新输入"))
        assertTrue(expired.contains("5 分钟"))
        assertTrue(expired.contains("重新生成"))
    }

    @Test
    fun `WebDAV认证与网络错误给出可执行提示`() {
        val credentials = PairingErrorMessage.from(WebDavException.InvalidCredentials())
        val unauthorized = PairingErrorMessage.from(WebDavException.Http(401))
        val transport = PairingErrorMessage.from(WebDavException.Transport("offline"))

        assertTrue(credentials.contains("应用密码"))
        assertTrue(unauthorized.contains("应用密码"))
        assertTrue(transport.contains("WebDAV"))
        assertTrue(transport.contains("网络"))
        assertFalse(transport.contains("Worker"))
    }

    @Test
    fun `密钥协商错误不向用户暴露英文实现细节`() {
        val message = PairingErrorMessage.from(
            SyncCryptoException("当前系统无法生成 X25519 临时密钥"),
        )

        assertTrue(message.contains("密钥协商"))
        assertFalse(message.contains("X25519"))
    }
}
