package com.wootodo.sync

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

enum class SyncEndpointScope {
    CROSS_DEVICE,
    CURRENT_DEVICE_ONLY,
    INVALID,
}

object SyncEndpointPolicy {
    fun scope(endpoint: URI): SyncEndpointScope {
        val host = endpoint.host?.lowercase() ?: return SyncEndpointScope.INVALID
        if (endpoint.rawUserInfo != null || endpoint.rawQuery != null ||
            endpoint.rawFragment != null
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
        return if (scheme == "https") {
            SyncEndpointScope.CROSS_DEVICE
        } else {
            SyncEndpointScope.INVALID
        }
    }

    fun isAllowed(endpoint: URI): Boolean = scope(endpoint) != SyncEndpointScope.INVALID

    fun isCrossDevice(endpoint: URI): Boolean = scope(endpoint) == SyncEndpointScope.CROSS_DEVICE
}

data class PairingDeepLink(
    val endpoint: String,
    val pairingId: String,
    val pairingSecret: String,
    val initiatorPublicKey: String,
) {
    init {
        require(SyncEndpointPolicy.isAllowed(URI(endpoint)))
        require(identifier.matches(pairingId))
        require(Base64Url.decode(pairingSecret).size == 32)
        require(Base64Url.decode(initiatorPublicKey).size == 32)
    }

    fun toUri(): String {
        val query = linkedMapOf(
            "endpoint" to endpoint,
            "pairingId" to pairingId,
            "pairingSecret" to pairingSecret,
            "initiatorPublicKey" to initiatorPublicKey,
        ).entries.joinToString("&") { (key, value) ->
            "$key=${URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")}"
        }
        return "wootodo://pair?$query"
    }

    override fun toString(): String =
        "PairingDeepLink(endpoint=$endpoint, pairingId=$pairingId, " +
            "pairingSecret=<已隐藏>, initiatorPublicKey=<已隐藏>)"

    companion object {
        private val identifier = Regex("^[A-Za-z0-9._:-]{1,128}$")
        private val requiredKeys =
            setOf("endpoint", "pairingId", "pairingSecret", "initiatorPublicKey")

        fun parse(source: String): PairingDeepLink {
            val uri = URI(source)
            require(
                uri.scheme?.lowercase() == "wootodo" && uri.host == "pair" &&
                    uri.rawPath.isNullOrEmpty() && uri.rawFragment == null,
            )
            val values = linkedMapOf<String, String>()
            uri.rawQuery?.split('&')?.filter { it.isNotEmpty() }?.forEach { part ->
                val pair = part.split('=', limit = 2)
                require(pair.size == 2)
                val key = decode(pair[0])
                require(key in requiredKeys && key !in values)
                values[key] = decode(pair[1])
            }
            require(values.keys == requiredKeys)
            val endpoint = values.getValue("endpoint")
            val pairingId = values.getValue("pairingId")
            val pairingSecret = values.getValue("pairingSecret")
            val publicKey = values.getValue("initiatorPublicKey")
            return PairingDeepLink(endpoint, pairingId, pairingSecret, publicKey)
        }

        private fun decode(value: String): String =
            URLDecoder.decode(value, StandardCharsets.UTF_8.name())
    }
}
