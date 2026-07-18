package com.wootodo.sync

/** 备份恢复要求数据库处于全新安装状态，避免把两个本地历史隐式合并。 */
data class BackupDatabaseState(
    val taskCount: Int,
    val vaultId: String,
    val deviceId: String,
    val cursor: Long,
    val lamport: Long,
    val outboxCount: Int,
    val entityVersionCount: Int,
    val tombstoneCount: Int,
    val appliedOperationCount: Int,
) {
    init {
        require(
            listOf(
                taskCount,
                outboxCount,
                entityVersionCount,
                tombstoneCount,
                appliedOperationCount,
            ).all { it >= 0 },
        )
        require(cursor >= 0 && lamport >= 0)
    }

    val hasBoundIdentity: Boolean
        get() = vaultId.isNotEmpty() || deviceId.isNotEmpty()

    val hasSyncHistory: Boolean
        get() = cursor != 0L || lamport != 0L ||
            outboxCount != 0 || entityVersionCount != 0 ||
            tombstoneCount != 0 || appliedOperationCount != 0
}

data class BackupTaskSnapshot(
    val state: BackupDatabaseState,
    val tasks: List<TaskInstancePayload>,
    val tombstones: List<TombstonePayload> = emptyList(),
)

data class BackupRestoreResult(
    val restoredTaskCount: Int,
    val syncCredentialsRestored: Boolean,
)

sealed class BackupTransferException(message: String, cause: Throwable? = null) :
    Exception(message, cause) {
    class PassphraseMismatch : BackupTransferException("两次输入的备份口令不一致")

    class ExistingTasks : BackupTransferException("仅可向空任务库导入，请先使用全新安装")

    class ExistingIdentity :
        BackupTransferException("当前设备已经绑定同步身份，不能导入另一份身份")

    class ResidualSyncState :
        BackupTransferException("本地仍有同步历史，不能安全导入备份")

    class CredentialsUnavailable :
        BackupTransferException("当前设备尚未绑定同步身份，只能导出任务数据")

    class CredentialsDoNotMatchDatabase :
        BackupTransferException("Keystore 同步身份与本地任务库不一致，已停止导出")
}

object BackupPassphraseConfirmation {
    /** 返回原始口令；编解码器会统一执行 NFKC 规范化。 */
    fun requireConfirmed(passphrase: String, confirmation: String): String {
        if (passphrase != confirmation) throw BackupTransferException.PassphraseMismatch()
        BackupKeyDerivation.normalizedPassphrase(passphrase)
        return passphrase
    }
}

object BackupRestorePolicy {
    fun requireReady(state: BackupDatabaseState, hasStoredCredentials: Boolean) {
        if (state.taskCount != 0) throw BackupTransferException.ExistingTasks()
        if (hasStoredCredentials || state.hasBoundIdentity) {
            throw BackupTransferException.ExistingIdentity()
        }
        if (state.hasSyncHistory) throw BackupTransferException.ResidualSyncState()
    }

    fun requireExportIdentityMatches(
        state: BackupDatabaseState,
        credentials: SyncCredentials,
    ) {
        if (state.vaultId != credentials.vaultId || state.deviceId != credentials.deviceId) {
            throw BackupTransferException.CredentialsDoNotMatchDatabase()
        }
    }
}

interface BackupRestoreTransaction {
    fun readState(): BackupDatabaseState

    fun insertTask(task: TaskInstancePayload)

    fun insertTombstone(tombstone: TombstonePayload)

    fun bindIdentityAndCreateBaseline(credentials: SyncCredentials)
}

interface BackupDatabase {
    fun readState(): BackupDatabaseState

    fun readTaskSnapshot(): BackupTaskSnapshot

    fun <T> inTransaction(block: (BackupRestoreTransaction) -> T): T
}

/**
 * 将凭据写入放在 SQLite 事务提交前；任一步失败都会回滚任务，并清理本轮新写入的凭据。
 * 恢复策略保证写入前不存在旧凭据，因此此处永远不会覆盖已有 Keystore 身份。
 */
class BackupRestoreCoordinator(
    private val database: BackupDatabase,
    private val credentialsStore: SyncCredentialsStore,
) {
    fun requireReady() {
        BackupRestorePolicy.requireReady(
            state = database.readState(),
            hasStoredCredentials = credentialsStore.load() != null,
        )
    }

    fun restore(snapshot: BackupSnapshot): BackupRestoreResult {
        val restoredCredentials = snapshot.syncCredentials?.credentials()
        var credentialsWriteAttempted = false
        var committed = false
        try {
            database.inTransaction { transaction ->
                BackupRestorePolicy.requireReady(
                    state = transaction.readState(),
                    hasStoredCredentials = credentialsStore.load() != null,
                )
                snapshot.tasks.forEach(transaction::insertTask)
                snapshot.tombstones.forEach(transaction::insertTombstone)
                restoredCredentials?.let { credentials ->
                    credentialsWriteAttempted = true
                    if (!credentialsStore.saveIfAbsent(credentials)) {
                        credentialsWriteAttempted = false
                        throw BackupTransferException.ExistingIdentity()
                    }
                    transaction.bindIdentityAndCreateBaseline(credentials)
                }
            }
            committed = true
            return BackupRestoreResult(
                restoredTaskCount = snapshot.tasks.size,
                syncCredentialsRestored = restoredCredentials != null,
            )
        } catch (error: Exception) {
            if (credentialsWriteAttempted && !committed) {
                runCatching(credentialsStore::delete).exceptionOrNull()?.let(error::addSuppressed)
            }
            throw error
        } finally {
            restoredCredentials?.vaultKey?.fill(0)
        }
    }
}

class BackupTransferService(
    private val database: BackupDatabase,
    private val credentialsStore: SyncCredentialsStore,
    private val clockMillis: () -> Long = System::currentTimeMillis,
) {
    private val restoreCoordinator = BackupRestoreCoordinator(database, credentialsStore)

    fun hasSyncCredentials(): Boolean = credentialsStore.load() != null

    fun requireRestoreReady() = restoreCoordinator.requireReady()

    fun createEncryptedBackup(
        passphrase: String,
        confirmation: String,
        includeSyncCredentials: Boolean,
    ): ByteArray {
        val confirmedPassphrase = BackupPassphraseConfirmation.requireConfirmed(
            passphrase,
            confirmation,
        )
        val taskSnapshot = database.readTaskSnapshot()
        val backupCredentials = if (includeSyncCredentials) {
            val credentials = credentialsStore.load()
                ?: throw BackupTransferException.CredentialsUnavailable()
            try {
                BackupRestorePolicy.requireExportIdentityMatches(taskSnapshot.state, credentials)
                BackupSyncCredentials.from(credentials)
            } finally {
                credentials.vaultKey.fill(0)
            }
        } else {
            null
        }
        return BackupPackageCodec.seal(
            snapshot = BackupSnapshot(
                exportedAt = clockMillis(),
                tasks = taskSnapshot.tasks,
                syncCredentials = backupCredentials,
                tombstones = taskSnapshot.tombstones,
            ),
            passphrase = confirmedPassphrase,
        )
    }

    fun restoreEncryptedBackup(data: ByteArray, passphrase: String): BackupRestoreResult {
        // 解密前先快速拒绝非空安装；事务内还会再次校验，防止检查与写入之间发生变化。
        restoreCoordinator.requireReady()
        val snapshot = BackupPackageCodec.open(data, passphrase)
        return restoreCoordinator.restore(snapshot)
    }
}
