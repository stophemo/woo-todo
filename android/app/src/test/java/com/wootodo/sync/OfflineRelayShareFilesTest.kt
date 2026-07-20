package com.wootodo.sync

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class OfflineRelayShareFilesTest {
    private lateinit var directory: File

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("woo-todo-relay-share").toFile()
    }

    @After
    fun tearDown() {
        if (::directory.isInitialized) directory.deleteRecursively()
    }

    @Test
    fun `同一分钟连续分享仍保留两个独立可读文件`() {
        val firstData = byteArrayOf(1, 2, 3)
        val secondData = byteArrayOf(4, 5, 6)
        val now = System.currentTimeMillis()

        val first = OfflineRelayShareFiles.write(directory, firstData, now)
        val second = OfflineRelayShareFiles.write(directory, secondData, now)

        assertNotEquals(first.name, second.name)
        assertTrue(first.isFile)
        assertTrue(second.isFile)
        assertArrayEquals(firstData, first.readBytes())
        assertArrayEquals(secondData, second.readBytes())
        assertTrue(directory.listFiles().orEmpty().none { it.name.endsWith(".partial") })
    }

    @Test
    fun `仅清理超过保留期的接力分享文件`() {
        val now = System.currentTimeMillis()
        val expired = File(directory, "Woo-Todo-relay-expired.wootodo").apply {
            writeText("expired")
            setLastModified(now - OfflineRelayShareFiles.RETENTION_MILLIS - 1)
        }
        val recent = File(directory, "Woo-Todo-relay-recent.wootodo").apply {
            writeText("recent")
            setLastModified(now - OfflineRelayShareFiles.RETENTION_MILLIS + 1)
        }
        val expiredPartial = File(directory, "Woo-Todo-relay-expired.partial").apply {
            writeText("partial")
            setLastModified(now - OfflineRelayShareFiles.RETENTION_MILLIS - 1)
        }
        val unrelated = File(directory, "other-cache.bin").apply {
            writeText("keep")
            setLastModified(0)
        }

        OfflineRelayShareFiles.cleanupExpired(directory, now)

        assertFalse(expired.exists())
        assertFalse(expiredPartial.exists())
        assertTrue(recent.exists())
        assertTrue(unrelated.exists())
    }
}
