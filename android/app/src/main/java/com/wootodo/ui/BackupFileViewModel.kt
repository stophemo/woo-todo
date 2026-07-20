package com.wootodo.ui

import androidx.lifecycle.ViewModel

enum class BackupExportPurpose {
    RECOVERY,
    OFFLINE_RELAY,
}

enum class BackupImportMode {
    RESTORE,
    OFFLINE_RELAY,
}

/** 只跨配置变更保留已加密文件字节，不持久化口令。 */
class BackupFileViewModel : ViewModel() {
    private var exportData: ByteArray? = null
    private var exportPurpose: BackupExportPurpose? = null
    private var importData: ByteArray? = null
    private var importMode: BackupImportMode? = null

    fun holdExport(data: ByteArray, purpose: BackupExportPurpose) {
        clearExport()
        exportData = data
        exportPurpose = purpose
    }

    fun exportData(): ByteArray? = exportData

    fun exportPurpose(): BackupExportPurpose? = exportPurpose

    fun clearExport() {
        exportData?.fill(0)
        exportData = null
        exportPurpose = null
    }

    fun beginImport(mode: BackupImportMode) {
        clearImportData()
        importMode = mode
    }

    fun holdImport(data: ByteArray) {
        check(importMode != null) { "尚未选择导入模式" }
        clearImportData()
        importData = data
    }

    fun importData(): ByteArray? = importData

    fun importMode(): BackupImportMode? = importMode

    fun clearImport() {
        clearImportData()
        importMode = null
    }

    private fun clearImportData() {
        importData?.fill(0)
        importData = null
    }

    override fun onCleared() {
        clearExport()
        clearImport()
    }
}
