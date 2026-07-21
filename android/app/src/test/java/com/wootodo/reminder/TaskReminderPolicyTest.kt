package com.wootodo.reminder

import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskReminderPolicyTest {
    private val zone = ZoneId.of("Asia/Shanghai")

    @Test
    fun `按任务日期与固定时区生成触发时间`() {
        val task = task(reminderTime = LocalTime.of(23, 10))

        assertEquals(
            Instant.parse("2026-07-21T15:10:00Z"),
            TaskReminderPolicy.triggerAt(task, zone),
        )
    }

    @Test
    fun `已完成无日期或无时间的任务不排程`() {
        assertNull(TaskReminderPolicy.triggerAt(task(reminderTime = null), zone))
        assertNull(
            TaskReminderPolicy.triggerAt(
                task(reminderTime = LocalTime.NOON).copy(status = TaskStatus.COMPLETED),
                zone,
            ),
        )
        assertNull(
            TaskReminderPolicy.triggerAt(
                task(reminderTime = LocalTime.NOON).copy(
                    timeType = TaskTimeType.LEISURE,
                    targetDate = null,
                ),
                zone,
            ),
        )
    }

    private fun task(reminderTime: LocalTime?): Task = Task(
        id = "00000000-0000-4000-8000-000000000001",
        seriesId = "00000000-0000-4000-8000-000000000001",
        title = "测试提醒",
        timeType = TaskTimeType.DAY,
        targetDate = LocalDate.of(2026, 7, 21),
        questLine = QuestLine.MAIN,
        status = TaskStatus.PENDING,
        recurrence = Recurrence.ONCE,
        sortOrder = 0,
        createdAt = 1,
        updatedAt = 1,
        settledAt = null,
        reminderTime = reminderTime,
    )
}
