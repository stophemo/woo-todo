package com.wootodo.ui

import androidx.lifecycle.ViewModel

/** 只跨配置变更保留已加密文件字节，不持久化口令。 */
class BackupFileViewModel : ViewModel() {
    private var exportData: ByteArray? = null
    private var importData: ByteArray? = null

    fun holdExport(data: ByteArray) {
        clearExport()
        exportData = data
    }

    fun exportData(): ByteArray? = exportData

    fun clearExport() {
        exportData?.fill(0)
        exportData = null
    }

    fun beginImport() {
        clearImportData()
    }

    fun holdImport(data: ByteArray) {
        clearImportData()
        importData = data
    }

    fun importData(): ByteArray? = importData

    fun clearImport() {
        clearImportData()
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
