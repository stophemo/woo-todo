package com.wootodo.sync

import java.io.File
import java.io.FileOutputStream

internal object OfflineRelayShareFiles {
    internal const val RETENTION_MILLIS = 7L * 24 * 60 * 60 * 1_000
    private const val FILE_PREFIX = "Woo-Todo-relay-"
    private const val FILE_SUFFIX = ".wootodo"
    private const val PARTIAL_SUFFIX = ".partial"

    fun write(
        directory: File,
        data: ByteArray,
        nowMillis: Long = System.currentTimeMillis(),
    ): File {
        check(directory.exists() || directory.mkdirs()) { "无法创建离线接力分享目录" }
        check(directory.isDirectory) { "离线接力分享路径不是目录" }
        cleanupExpired(directory, nowMillis)

        val partial = File.createTempFile(FILE_PREFIX, PARTIAL_SUFFIX, directory)
        val file = File(directory, partial.name.removeSuffix(PARTIAL_SUFFIX) + FILE_SUFFIX)
        return try {
            FileOutputStream(partial).use { output ->
                output.write(data)
                output.fd.sync()
            }
            check(partial.renameTo(file)) { "无法完成离线接力分享文件" }
            file
        } catch (error: Exception) {
            partial.delete()
            file.delete()
            throw error
        }
    }

    internal fun cleanupExpired(directory: File, nowMillis: Long) {
        val cutoff = nowMillis - RETENTION_MILLIS
        directory.listFiles()?.forEach { file ->
            if (file.isFile &&
                file.name.startsWith(FILE_PREFIX) &&
                (file.name.endsWith(FILE_SUFFIX) || file.name.endsWith(PARTIAL_SUFFIX)) &&
                file.lastModified() < cutoff
            ) {
                file.delete()
            }
        }
    }
}
