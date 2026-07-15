package com.wootodo.sync

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

object SyncEndpointPolicy {
    fun isAllowed(endpoint: URI): Boolean {
        val isHttps = endpoint.scheme?.lowercase() == "https"
        val isLocalHttp = endpoint.scheme?.lowercase() == "http" &&
            endpoint.host == "127.0.0.1"
        return (isHttps || isLocalHttp) && endpoint.host != null &&
            endpoint.rawUserInfo == null && endpoint.rawQuery == null &&
            endpoint.rawFragment == null
    }
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
