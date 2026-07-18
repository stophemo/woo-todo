package com.wootodo.sync

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.net.URL
import java.nio.charset.StandardCharsets

sealed class SyncApiException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class InvalidEndpoint : SyncApiException("同步服务地址无效")
    class Transport(cause: Throwable) : SyncApiException("网络请求失败", cause)
    class Decoding(cause: Throwable) : SyncApiException("响应解析失败", cause)
    class Server(
        val statusCode: Int,
        val payload: ServerErrorPayload,
        val requestId: String?,
    ) : SyncApiException("同步服务错误（${payload.code}）：${payload.message}")
}

interface SyncTransport {
    fun sync(request: SyncRequest, credential: BearerCredential): SyncData
}

interface PairingTransport {
    fun claimPairing(pairingId: String, request: PairingClaimRequest): PairingClaimData
    fun pairingResult(pairingId: String, request: PairingResultRequest): PairingResultData
}

class SyncApiClient(
    endpoint: String,
    private val connectTimeoutMillis: Int = 10_000,
    private val readTimeoutMillis: Int = 20_000,
    private val connectionFactory: (URL) -> HttpURLConnection = { url ->
        url.openConnection() as HttpURLConnection
    },
) : SyncTransport, PairingTransport {
    private val endpoint: URI = validateEndpoint(endpoint)

    fun createVault(request: CreateVaultRequest, inviteCode: String): CreateVaultData = send(
        method = "POST",
        path = listOf("v1", "vaults"),
        body = SyncJsonCodec.encode(request),
        credential = null,
        decoder = SyncJsonCodec::decodeCreateVaultData,
        vaultCreationInviteCode = inviteCode,
    )

    fun createPairing(
        request: CreatePairingRequest,
        credential: BearerCredential,
    ): CreatePairingData = send(
        "POST",
        listOf("v1", "pairings"),
        SyncJsonCodec.encode(request),
        credential,
        SyncJsonCodec::decodeCreatePairingData,
    )

    fun pairingStatus(
        pairingId: String,
        credential: BearerCredential,
    ): PairingStatusData = send(
        "GET",
        listOf("v1", "pairings", pairingId),
        null,
        credential,
        SyncJsonCodec::decodePairingStatusData,
    )

    override fun claimPairing(
        pairingId: String,
        request: PairingClaimRequest,
    ): PairingClaimData = send(
        "POST",
        listOf("v1", "pairings", pairingId, "claim"),
        SyncJsonCodec.encode(request),
        null,
        SyncJsonCodec::decodePairingClaimData,
    )

    fun confirmPairing(
        pairingId: String,
        request: PairingConfirmRequest,
        credential: BearerCredential,
    ): PairingConfirmData = send(
        "POST",
        listOf("v1", "pairings", pairingId, "confirm"),
        SyncJsonCodec.encode(request),
        credential,
        SyncJsonCodec::decodePairingConfirmData,
    )

    override fun pairingResult(
        pairingId: String,
        request: PairingResultRequest,
    ): PairingResultData = send(
        "POST",
        listOf("v1", "pairings", pairingId, "result"),
        SyncJsonCodec.encode(request),
        null,
        SyncJsonCodec::decodePairingResultData,
    )

    override fun sync(request: SyncRequest, credential: BearerCredential): SyncData = send(
        "POST",
        listOf("v1", "sync"),
        SyncJsonCodec.encode(request),
        credential,
        SyncJsonCodec::decodeSyncData,
    )

    fun listDevices(credential: BearerCredential): DeviceListData = send(
        "GET",
        listOf("v1", "devices"),
        null,
        credential,
        SyncJsonCodec::decodeDeviceListData,
    )

    fun revokeDevice(deviceId: String, credential: BearerCredential): RevokeDeviceData = send(
        "POST",
        listOf("v1", "devices", deviceId, "revoke"),
        null,
        credential,
        SyncJsonCodec::decodeRevokeDeviceData,
    )

    private fun <T> send(
        method: String,
        path: List<String>,
        body: String?,
        credential: BearerCredential?,
        decoder: (String) -> T,
        vaultCreationInviteCode: String? = null,
    ): T {
        val connection = try {
            connectionFactory(buildUrl(path)).apply {
                requestMethod = method
                connectTimeout = connectTimeoutMillis
                readTimeout = readTimeoutMillis
                useCaches = false
                setRequestProperty("Accept", "application/json")
                credential?.let {
                    setRequestProperty("Authorization", "Bearer ${it.deviceToken}")
                }
                vaultCreationInviteCode?.let {
                    setRequestProperty("X-Woo-Todo-Invite-Code", it)
                }
                if (body != null) {
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    outputStream.use { output ->
                        output.write(body.toByteArray(StandardCharsets.UTF_8))
                    }
                }
            }
        } catch (error: IOException) {
            throw SyncApiException.Transport(error)
        }

        try {
            val status = connection.responseCode
            val responseBody = readResponse(connection, status)
            if (status in 200..299) {
                return try {
                    decoder(responseBody)
                } catch (error: Exception) {
                    throw SyncApiException.Decoding(error)
                }
            }
            val decodedFailure = runCatching { SyncJsonCodec.decodeFailure(responseBody) }.getOrNull()
            throw SyncApiException.Server(
                statusCode = status,
                payload = decodedFailure?.payload ?: ServerErrorPayload(
                    code = "HTTP_$status",
                    message = connection.responseMessage ?: "HTTP 请求失败",
                ),
                requestId = decodedFailure?.requestId
                    ?: connection.getHeaderField("x-request-id"),
            )
        } catch (error: SyncApiException) {
            throw error
        } catch (error: IOException) {
            throw SyncApiException.Transport(error)
        } finally {
            connection.disconnect()
        }
    }

    private fun readResponse(connection: HttpURLConnection, status: Int): String {
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        return stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
    }

    private fun buildUrl(path: List<String>): URL {
        val base = endpoint.toString().trimEnd('/') + "/"
        val encodedPath = path.joinToString("/") { component ->
            URLEncoder.encode(component, StandardCharsets.UTF_8.name()).replace("+", "%20")
        }
        return URI(base + encodedPath).toURL()
    }

    private fun validateEndpoint(value: String): URI {
        val uri = runCatching { URI(value) }.getOrNull() ?: throw SyncApiException.InvalidEndpoint()
        if (!SyncEndpointPolicy.isAllowed(uri)) {
            throw SyncApiException.InvalidEndpoint()
        }
        return uri
    }
}
