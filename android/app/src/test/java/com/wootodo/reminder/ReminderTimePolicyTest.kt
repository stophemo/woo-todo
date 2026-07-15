package com.wootodo.reminder

import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import org.junit.Assert.assertEquals
import org.junit.Test

class ReminderTimePolicyTest {
    private val zone = ZoneId.of("Asia/Shanghai")

    @Test
    fun `23点10分前安排到当天提醒时刻`() {
        val now = ZonedDateTime.of(2026, 7, 15, 22, 0, 0, 0, zone)

        assertEquals(
            ZonedDateTime.of(2026, 7, 15, 23, 10, 0, 0, zone),
            ReminderTimePolicy.nextTrigger(now, null),
        )
    }

    @Test
    fun `错过提醒且当天未处理时尽快补发`() {
        val now = ZonedDateTime.of(2026, 7, 15, 23, 30, 0, 0, zone)

        assertEquals(now.plusSeconds(5), ReminderTimePolicy.nextTrigger(now, null))
    }

    @Test
    fun `当天已经处理后安排到次日`() {
        val now = ZonedDateTime.of(2026, 7, 15, 23, 30, 0, 0, zone)

        assertEquals(
            ZonedDateTime.of(2026, 7, 16, 23, 10, 0, 0, zone),
            ReminderTimePolicy.nextTrigger(now, LocalDate.of(2026, 7, 15)),
        )
    }

    @Test
    fun `使用用户配置的本地提醒时间`() {
        val now = ZonedDateTime.of(2026, 7, 15, 20, 0, 0, 0, zone)

        assertEquals(
            ZonedDateTime.of(2026, 7, 15, 21, 45, 0, 0, zone),
            ReminderTimePolicy.nextTrigger(now, null, LocalTime.of(21, 45)),
        )
    }

    @Test
    fun `提醒设置默认开启且为23点10分`() {
        val settings = ReminderSettings()

        assertEquals(true, settings.enabled)
        assertEquals(LocalTime.of(23, 10), settings.time)
    }
}
