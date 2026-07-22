package com.wootodo.sync

internal sealed interface ScannedConfiguration {
    class WebDav(val setupLink: WebDavSetupLink) : ScannedConfiguration
    class WorkerPairing(val pairingLink: PairingDeepLink) : ScannedConfiguration
}

internal object ScannedConfigurationParser {
    fun parse(source: String): ScannedConfiguration {
        val normalized = source.trim()
        return when {
            normalized.startsWith("wootodo://webdav?", ignoreCase = true) ->
                ScannedConfiguration.WebDav(WebDavSetupLink.parse(normalized))

            normalized.startsWith("wootodo://pair?", ignoreCase = true) ->
                ScannedConfiguration.WorkerPairing(PairingDeepLink.parse(normalized))

            else -> throw IllegalArgumentException("不是受支持的 Woo Todo 配置二维码")
        }
    }
}
