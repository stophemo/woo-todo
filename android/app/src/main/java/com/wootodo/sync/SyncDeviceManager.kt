package com.wootodo.sync

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** 设备列表、移除其他设备和退出当前同步空间。 */
class SyncDeviceManager(
    private val clientFactory: (String) -> SyncApiClient = { endpoint -> SyncApiClient(endpoint) },
) {
    fun listDevices(credentials: SyncCredentials): DeviceListData = client(credentials)
        .listDevices(BearerCredential(credentials.deviceToken))

    fun removeDevice(credentials: SyncCredentials, deviceId: String): RevokeDeviceData =
        client(credentials).revokeDevice(deviceId, BearerCredential(credentials.deviceToken))

    fun leaveSpace(credentials: SyncCredentials): RevokeDeviceData = client(credentials)
        .revokeCurrentDevice(BearerCredential(credentials.deviceToken))

    private fun client(credentials: SyncCredentials): SyncApiClient {
        credentials.validate()
        return clientFactory(credentials.endpoint)
    }
}

/**
 * 退出空间时服务端已经没有当前设备（被其他设备移除或令牌失效）。
 * 这种情况仍必须继续清理本地凭据，否则设备会卡在无法退出、也无法重新配对的状态。
 */
/**
 * 配对失败或取消后尽力撤销本次配对创建的临时设备。设备尚未创建时服务端
 * 返回 401/403，网络失败也不影响本地放弃本次配对，因此全部忽略。
 * 使用 NonCancellable，确保协程已取消时仍能发出撤销请求。
 */
internal suspend fun revokeTemporaryDevice(client: SyncApiClient, deviceToken: String) {
    withContext(NonCancellable) {
        runCatching { client.revokeCurrentDevice(BearerCredential(deviceToken)) }
    }
}

internal object SyncLeavePolicy {
    fun serverAlreadyRemoved(error: Throwable): Boolean = when (error) {
        is SyncApiException.Server ->
            (error.statusCode == 401 && error.payload.code == "INVALID_DEVICE_TOKEN") ||
                (error.statusCode == 403 && error.payload.code == "DEVICE_REVOKED")
        else -> false
    }
}
