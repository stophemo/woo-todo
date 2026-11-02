package com.wootodo.sync

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

enum class SyncEndpointScope {
    CROSS_DEVICE,
    LOCAL_NETWORK,
    CURRENT_DEVICE_ONLY,
    INVALID,
}

object SyncEndpointPolicy {
    fun scope(endpoint: URI): SyncEndpointScope {
        val host = endpoint.host?.lowercase() ?: return SyncEndpointScope.INVALID
        if (endpoint.rawUserInfo != null || endpoint.rawQuery != null ||
            endpoint.rawFragment != null || endpoint.path.trimEnd('/').substringAfterLast('/')
                .equals("v1", ignoreCase = true)
        ) {
            return SyncEndpointScope.INVALID
        }

        val scheme = endpoint.scheme?.lowercase()
        val isLoopback = host == "127.0.0.1" || host == "localhost" ||
            host == "::1" || host == "[::1]"
        if (isLoopback) {
            return if (scheme == "https" || (scheme == "http" && host == "127.0.0.1")) {
                SyncEndpointScope.CURRENT_DEVICE_ONLY
            } else {
                SyncEndpointScope.INVALID
            }
        }
        return when {
            scheme == "https" -> SyncEndpointScope.CROSS_DEVICE
            scheme == "http" && (isPrivateIpv4(host) || isLocalHostname(host)) ->
                SyncEndpointScope.LOCAL_NETWORK
            else -> SyncEndpointScope.INVALID
        }
    }

    fun isAllowed(endpoint: URI): Boolean = scope(endpoint) != SyncEndpointScope.INVALID

    fun isCrossDevice(endpoint: URI): Boolean = scope(endpoint) in setOf(
        SyncEndpointScope.CROSS_DEVICE,
        SyncEndpointScope.LOCAL_NETWORK,
    )

    private fun isPrivateIpv4(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        val octets = parts.map { part ->
            if (part.isEmpty() || part.length > 3 || part.any { !it.isDigit() } ||
                (part.length > 1 && part.startsWith('0'))
            ) {
                return false
            }
            part.toIntOrNull()?.takeIf { it in 0..255 } ?: return false
        }
        return octets[0] == 10 ||
            (octets[0] == 172 && octets[1] in 16..31) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    private fun isLocalHostname(host: String): Boolean =
        host.length <= 253 && LOCAL_HOSTNAME.matches(host)

    private val LOCAL_HOSTNAME = Regex(
        "^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+local$",
    )
}

data class PairingDeepLink(
    val endpoint: String,
    val pairingId: String,
    val pairingSecret: String,
    val initiatorPublicKey: String,
    val vaultId: String? = null,
    /** 同一台主机的其他可能可达地址，热点拓扑下 `.local` 经常解析不到。 */
    val alternateEndpoints: List<String> = emptyList(),
) {
    init {
        require(SyncEndpointPolicy.isAllowed(URI(endpoint)))
        alternateEndpoints.forEach { require(SyncEndpointPolicy.isAllowed(URI(it))) }
        require(identifier.matches(pairingId))
        vaultId?.let { require(identifier.matches(it)) }
        require(Base64Url.decode(pairingSecret).size == 32)
        require(Base64Url.decode(initiatorPublicKey).size == 32)
    }

    /** 主地址在前、备选地址在后，去重后供连接时逐个尝试。 */
    val endpointCandidates: List<String>
        get() = (listOf(endpoint) + alternateEndpoints).distinct()

    fun toUri(): String {
        val params = linkedMapOf(
            "endpoint" to endpoint,
            "pairingId" to pairingId,
            "pairingSecret" to pairingSecret,
            "initiatorPublicKey" to initiatorPublicKey,
        ).apply { vaultId?.let { put("vaultId", it) } }
            .entries.map { (key, value) -> key to value }
            .toMutableList()
        alternateEndpoints.distinct().filter { it != endpoint }.forEach { params += "alt" to it }
        val query = params.joinToString("&") { (key, value) ->
            "$key=${URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")}"
        }
        return "wootodo://pair?$query"
    }

    override fun toString(): String =
        "PairingDeepLink(endpoint=$endpoint, alternates=${alternateEndpoints.size}, " +
            "pairingId=$pairingId, pairingSecret=<已隐藏>, initiatorPublicKey=<已隐藏>)"

    companion object {
        private val identifier = Regex("^[A-Za-z0-9._:-]{1,128}$")
        private val requiredKeys =
            setOf("endpoint", "pairingId", "pairingSecret", "initiatorPublicKey")
        private val allowedKeys = requiredKeys + "vaultId" + "alt"

        fun parse(source: String): PairingDeepLink {
            val uri = URI(source)
            require(
                uri.scheme?.lowercase() == "wootodo" && uri.host?.equals("pair", ignoreCase = true) == true &&
                    uri.rawPath.isNullOrEmpty() && uri.rawFragment == null,
            )
            val values = linkedMapOf<String, String>()
            val alternates = mutableListOf<String>()
            uri.rawQuery?.split('&')?.filter { it.isNotEmpty() }?.forEach { part ->
                val pair = part.split('=', limit = 2)
                require(pair.size == 2)
                val key = decode(pair[0])
                require(key in allowedKeys)
                // alt 允许重复出现，其余字段仍然不能重复。
                if (key == "alt") {
                    alternates += decode(pair[1])
                } else {
                    require(key !in values)
                    values[key] = decode(pair[1])
                }
            }
            require(values.keys.containsAll(requiredKeys))
            require(values.keys.all { it in allowedKeys })
            val endpoint = values.getValue("endpoint")
            val pairingId = values.getValue("pairingId")
            val pairingSecret = values.getValue("pairingSecret")
            val publicKey = values.getValue("initiatorPublicKey")
            return PairingDeepLink(
                endpoint,
                pairingId,
                pairingSecret,
                publicKey,
                values["vaultId"],
                // 备选地址去重且剔除与主地址相同的项，避免重复消耗配对尝试。
                alternates.distinct().filter { it != endpoint },
            )
        }

        private fun decode(value: String): String = try {
            // Query 参数是 URI 组件而不是 application/x-www-form-urlencoded；原始 '+' 必须保留。
            URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8.name())
        } catch (error: Exception) {
            throw IllegalArgumentException("配对深链参数编码无效", error)
        }
    }
}
