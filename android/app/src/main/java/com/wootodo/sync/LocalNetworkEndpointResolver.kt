package com.wootodo.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

fun interface LocalNetworkServiceResolver {
    fun resolve(vaultId: String): List<String>
}

internal object LocalNetworkDiscoveryIdentity {
    const val SERVICE_TYPE = "_wootodo._tcp."
    const val VAULT_FINGERPRINT_KEY = "vault"

    fun vaultFingerprint(vaultId: String): String = Base64Url.encode(
        MessageDigest.getInstance("SHA-256")
            .digest(vaultId.toByteArray(StandardCharsets.UTF_8)),
    )
}

/**
 * 旧地址不可达时只重定位服务，不更换已配对的设备令牌和同步密钥。
 */
class RecoveringLocalNetworkSyncTransport(
    initialEndpoint: String,
    private val vaultId: String,
    private val resolver: LocalNetworkServiceResolver,
    private val transportFactory: (String) -> SyncTransport = ::SyncApiClient,
    private val onEndpointRecovered: (String) -> Unit = {},
) : SyncTransport {
    @Volatile
    private var currentEndpoint = initialEndpoint

    override fun sync(request: SyncRequest, credential: BearerCredential): SyncData {
        val failedEndpoint = currentEndpoint
        val initialFailure = try {
            return transportFactory(failedEndpoint).sync(request, credential)
        } catch (error: SyncApiException.Transport) {
            if (!error.localNetwork) throw error
            error
        }

        val candidates = try {
            resolver.resolve(vaultId)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw initialFailure
        }

        var authorizationFailure: SyncApiException.Server? = null
        for (candidate in candidates.distinct()) {
            if (candidate == failedEndpoint) continue
            try {
                val result = transportFactory(candidate).sync(request, credential)
                currentEndpoint = candidate
                runCatching { onEndpointRecovered(candidate) }
                return result
            } catch (error: CancellationException) {
                throw error
            } catch (_: SyncApiException.Transport) {
                continue
            } catch (error: SyncApiException.Server) {
                if (error.statusCode == 401 || error.statusCode == 403) {
                    authorizationFailure = authorizationFailure ?: error
                    continue
                }
                throw error
            }
        }
        throw authorizationFailure ?: initialFailure
    }
}

class AndroidLocalNetworkServiceResolver(context: Context) : LocalNetworkServiceResolver {
    private val applicationContext = context.applicationContext

    override fun resolve(vaultId: String): List<String> {
        val nsdManager = applicationContext.getSystemService(NsdManager::class.java)
            ?: return emptyList()
        val wifiManager = applicationContext.getSystemService(WifiManager::class.java)
        val multicastLock = wifiManager?.createMulticastLock(MULTICAST_LOCK_TAG)?.apply {
            setReferenceCounted(false)
        }
        val matchingService = CountDownLatch(1)
        val resolutionQueue = ServiceResolutionQueue(
            nsdManager = nsdManager,
            expectedFingerprint = LocalNetworkDiscoveryIdentity.vaultFingerprint(vaultId),
            matchingService = matchingService,
        )
        val discoveryStopped = AtomicBoolean(false)
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (normalizedType(serviceInfo.serviceType) ==
                    normalizedType(LocalNetworkDiscoveryIdentity.SERVICE_TYPE)
                ) {
                    resolutionQueue.enqueue(serviceInfo)
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onDiscoveryStopped(serviceType: String) {
                discoveryStopped.set(true)
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                matchingService.countDown()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                discoveryStopped.set(true)
            }
        }

        return try {
            multicastLock?.acquire()
            nsdManager.discoverServices(
                LocalNetworkDiscoveryIdentity.SERVICE_TYPE,
                NsdManager.PROTOCOL_DNS_SD,
                discoveryListener,
            )
            try {
                matchingService.await(DISCOVERY_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                throw CancellationException("局域网服务发现已取消").apply { initCause(error) }
            }
            resolutionQueue.endpoints()
        } finally {
            if (!discoveryStopped.get()) {
                runCatching { nsdManager.stopServiceDiscovery(discoveryListener) }
            }
            if (multicastLock?.isHeld == true) multicastLock.release()
        }
    }

    private fun normalizedType(value: String): String = value.trimEnd('.').lowercase()

    private class ServiceResolutionQueue(
        private val nsdManager: NsdManager,
        private val expectedFingerprint: String,
        private val matchingService: CountDownLatch,
    ) {
        private val pending = ConcurrentLinkedQueue<NsdServiceInfo>()
        private val resolving = AtomicBoolean(false)
        private val endpoints = Collections.synchronizedSet(linkedSetOf<String>())

        fun enqueue(serviceInfo: NsdServiceInfo) {
            pending.add(serviceInfo)
            resolveNext()
        }

        fun endpoints(): List<String> = synchronized(endpoints) { endpoints.toList() }

        private fun resolveNext() {
            if (!resolving.compareAndSet(false, true)) return
            val serviceInfo = pending.poll()
            if (serviceInfo == null) {
                resolving.set(false)
                if (pending.isNotEmpty()) resolveNext()
                return
            }
            try {
                @Suppress("DEPRECATION")
                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        finishResolution()
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        val fingerprint = serviceInfo.attributes[
                            LocalNetworkDiscoveryIdentity.VAULT_FINGERPRINT_KEY
                        ]?.toString(StandardCharsets.UTF_8)
                        if (fingerprint == expectedFingerprint) {
                            endpoint(serviceInfo)?.let {
                                endpoints.add(it)
                                matchingService.countDown()
                            }
                        }
                        finishResolution()
                    }
                })
            } catch (_: RuntimeException) {
                finishResolution()
            }
        }

        private fun finishResolution() {
            resolving.set(false)
            resolveNext()
        }

        @Suppress("DEPRECATION")
        private fun endpoint(serviceInfo: NsdServiceInfo): String? {
            if (serviceInfo.port !in 1..65_535) return null
            val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                serviceInfo.hostAddresses
            } else {
                listOfNotNull(serviceInfo.host)
            }
            return addresses.firstNotNullOfOrNull { address ->
                val host = address.hostAddress?.substringBefore('%') ?: return@firstNotNullOfOrNull null
                val endpoint = URI("http", null, host, serviceInfo.port, null, null, null)
                endpoint.takeIf {
                    SyncEndpointPolicy.scope(it) == SyncEndpointScope.LOCAL_NETWORK
                }?.toString()
            }
        }
    }

    private companion object {
        const val MULTICAST_LOCK_TAG = "woo-todo-local-sync-discovery"
        const val DISCOVERY_TIMEOUT_SECONDS = 4L
    }
}
