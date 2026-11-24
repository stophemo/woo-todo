package com.wootodo.ui

import com.wootodo.sync.SyncCryptoException
import com.wootodo.sync.WebDavException
import com.wootodo.sync.WebDavPairingException

/** WebDAV 配对与同步错误统一转换为可执行的中文提示。 */
internal object PairingErrorMessage {
    fun from(error: Throwable): String = when (error) {
        is WebDavPairingException -> error.message
            ?: "配对未完成，请确认两台设备显示同一组配对码后重试"
        is WebDavException.InvalidCredentials ->
            "WebDAV 账号或应用密码无效，请重新配置账号"
        is WebDavException.Transport ->
            "无法连接 WebDAV 服务，请检查服务器地址、网络和应用密码"
        is WebDavException.Http -> when (error.statusCode) {
            401, 403 -> "WebDAV 账号或应用密码无效，请重新配置账号"
            404 -> "WebDAV 路径不存在，请检查服务器地址后重试"
            429, 500, 502, 503, 504 -> "WebDAV 服务暂时不可用，请稍后重试"
            409, 412 -> "WebDAV 文件发生冲突，请重新开始配对"
            else -> "WebDAV 服务返回 HTTP ${error.statusCode}"
        }
        is WebDavException.ObjectConflict ->
            "WebDAV 文件发生冲突，请重新开始配对"
        is WebDavException.MalformedObject ->
            "配对文件内容无效，请更新应用后重试"
        is SyncCryptoException ->
            "配对密钥协商或校验失败，请更新应用后重试"
        else -> error.localizedMessage
            ?.takeIf(String::isNotBlank)
            ?.let { "配对未完成：$it" }
            ?: "配对未完成，请确认两台设备显示同一组配对码后重试"
    }
}
