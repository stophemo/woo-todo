package com.wootodo.domain

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.LocalDate
import java.util.Locale
import java.util.UUID

object OccurrenceId {
    private const val NAMESPACE = "woo-todo-occurrence-v1"

    fun create(
        seriesId: String,
        timeType: TaskTimeType,
        periodStart: LocalDate,
    ): String {
        val source = listOf(
            NAMESPACE,
            seriesId.lowercase(Locale.ROOT),
            timeType.rawValue,
            periodStart.toString(),
        ).joinToString("|")
        val bytes = MessageDigest.getInstance("SHA-256")
            .digest(source.toByteArray(StandardCharsets.UTF_8))
            .copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long).toString()
    }
}
