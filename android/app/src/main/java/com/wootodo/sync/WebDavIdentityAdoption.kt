package com.wootodo.sync

import kotlinx.coroutines.CancellationException

/**
 * 自动保存加入身份并绑定本地任务库；绑定失败时回滚到调用前的身份，
 * 避免留下已保存但无法同步的“半加入”状态。
 */
internal fun <T> withIdentityRollback(
    previous: WebDavIdentity?,
    saveIdentity: (WebDavIdentity) -> Unit,
    deleteIdentity: () -> Unit,
    block: () -> T,
): T = try {
    block()
} catch (error: CancellationException) {
    throw error
} catch (_: Exception) {
    if (previous == null) deleteIdentity() else saveIdentity(previous)
    throw WebDavPairingException.LocalBindingFailed
}
