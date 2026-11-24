package com.wootodo.sync

import java.net.Inet4Address
import java.net.InetAddress
import java.net.URI

/**
 * 跨设备同步只允许部署在公网的 HTTPS Worker 地址。
 * 局域网、明文、回环和私有地址已移除，旧地址只会被识别为未配对。
 */
object SyncEndpointPolicy {
    private const val MAXIMUM_LENGTH = 2_048
    private val DECIMAL_LABEL = Regex("^[0-9]+$")
    private val HEX_LABEL = Regex("^0[xX][0-9a-fA-F]*$")
    private val CANONICAL_OCTET = Regex("^(?:0|[1-9][0-9]{0,2})$")

    fun isAllowed(endpoint: URI): Boolean {
        if (endpoint.toString().length > MAXIMUM_LENGTH) return false
        if (!endpoint.scheme.equals("https", ignoreCase = true)) return false
        if (endpoint.rawUserInfo != null || endpoint.rawQuery != null ||
            endpoint.rawFragment != null
        ) {
            return false
        }
        if (endpoint.port != -1 && endpoint.port !in 1..65_535) return false
        // 末尾点等价于同一主机名，先规范化再判断。
        val host = endpoint.host?.trim()?.lowercase().orEmpty().trimEnd('.')
        if (host.isEmpty()) return false
        val path = endpoint.rawPath.orEmpty()
        if (path.isNotEmpty() && path != "/") return false
        if (host == "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) {
            return false
        }
        val bareHost = host.removePrefix("[").removeSuffix("]")
        return when {
            bareHost.contains(':') -> !isPrivateIpv6(bareHost)
            // 纯数字/点/十六进制写法会被系统解析到回环或未指定地址。
            // 只放行规范的公网四段点分十进制，其余数值主机一律拒绝。
            isNumericHost(bareHost) -> isCanonicalPublicIpv4(bareHost)
            else -> true
        }
    }

    fun isValid(value: String?): Boolean = normalize(value) != null

    /** 返回去掉首尾空白和末尾 `/` 的规范地址；不合法时返回 null。 */
    fun normalize(value: String?): String? {
        val trimmed = value?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
        if (!isAllowed(uri)) return null
        return trimmed.removeSuffix("/")
    }

    fun resolvePreferredEndpoint(
        credentialsEndpoint: String?,
        buildEndpoint: String?,
        savedEndpoint: String?,
    ): String? {
        credentialsEndpoint?.let { normalize(it) }?.let { return it }
        return normalize(buildEndpoint) ?: normalize(savedEndpoint)
    }

    /** 整个主机名都由十进制数段或 0x 十六进制数段组成（inet_aton 风格数值地址）。 */
    private fun isNumericHost(host: String): Boolean =
        host.split('.').all { DECIMAL_LABEL.matches(it) || HEX_LABEL.matches(it) }

    /** 只有规范四段点分十进制且属于公网时才允许。 */
    private fun isCanonicalPublicIpv4(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = IntArray(4)
        for ((index, part) in parts.withIndex()) {
            if (!CANONICAL_OCTET.matches(part)) return false
            octets[index] = part.toInt().takeIf { it in 0..255 } ?: return false
        }
        return !isPrivateIpv4(octets)
    }

    private fun isPrivateIpv4(bytes: ByteArray): Boolean {
        if (bytes.size != 4) return false
        return isPrivateIpv4(IntArray(4) { bytes[it].toInt() and 0xFF })
    }

    private fun isPrivateIpv4(octets: IntArray): Boolean =
        octets[0] == 0 ||
            octets[0] == 10 ||
            octets[0] == 127 ||
            (octets[0] == 172 && octets[1] in 16..31) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254) ||
            (octets[0] == 100 && octets[1] in 64..127)

    /** 解析 IPv6 字面量；无法解析时按不安全处理。 */
    private fun isPrivateIpv6(host: String): Boolean {
        val address = runCatching { InetAddress.getByName(host) }.getOrNull() ?: return true
        if (address is Inet4Address) return isPrivateIpv4(address.address)
        val bytes = address.address.map { it.toInt() and 0xFF }
        if (bytes.size != 16) return true
        // :: 与 ::1
        if (bytes.all { it == 0 }) return true
        if (bytes.subList(0, 15).all { it == 0 } && bytes[15] == 1) return true
        // fc00::/7（唯一本地地址）
        if ((bytes[0] and 0xFE) == 0xFC) return true
        // fe80::/10（链路本地）
        if (bytes[0] == 0xFE && (bytes[1] and 0xC0) == 0x80) return true
        // IPv4-mapped ::ffff:a.b.c.d（部分 JVM 仍返回 Inet6Address）
        if (bytes.subList(0, 10).all { it == 0 } &&
            bytes[10] == 0xFF && bytes[11] == 0xFF
        ) {
            return isPrivateIpv4(
                byteArrayOf(
                    bytes[12].toByte(),
                    bytes[13].toByte(),
                    bytes[14].toByte(),
                    bytes[15].toByte(),
                ),
            )
        }
        return false
    }
}
