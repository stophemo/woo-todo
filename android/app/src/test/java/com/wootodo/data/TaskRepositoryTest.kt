package com.wootodo.data

import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskDraft
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class TaskRepositoryTest {
    private val date = LocalDate.of(2026, 7, 15)
    private val store = FakeTaskStore()
    private val ids = ArrayDeque((1..10).map { "task-$it" })
    private val repository = TaskRepository(
        store = store,
        clock = Clock.fixed(Instant.parse("2026-07-15T04:00:00Z"), ZoneId.of("Asia/Shanghai")),
        idFactory = { ids.removeFirst() },
    )

    @Test
    fun `创建任务会清理标题并写入当前周期`() = runBlocking {
        val id = repository.create(
            TaskDraft(
                title = "  完成日报  ",
                timeType = TaskTimeType.WEEK,
                targetDate = date,
                questLine = QuestLine.MAIN,
            ),
        )

        val task = repository.get(id)!!
        assertEquals("完成日报", task.title)
        assertEquals(LocalDate.of(2026, 7, 13), task.targetDate)
    }

    @Test
    fun `标题上限按Unicode code point计算`() = runBlocking {
        val valid = "😀".repeat(61)
        val id = repository.create(TaskDraft(title = valid, targetDate = date))
        assertEquals(valid, repository.get(id)?.title)

        assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                repository.create(
                    TaskDraft(title = "👨‍👩‍👧‍👦".repeat(18), targetDate = date),
                )
            }
        }
        Unit
    }

    @Test
    fun `完成每日任务会保留已完成实例并生成下一实例`() = runBlocking {
        val id = repository.create(
            TaskDraft(
                title = "周三复盘",
                timeType = TaskTimeType.DAY,
                targetDate = date,
                recurrence = Recurrence.DAILY,
            ),
        )

        assertTrue(repository.settle(id, TaskStatus.COMPLETED))

        val all = store.items.value.sortedBy { it.targetDate }
        assertEquals(2, all.size)
        assertEquals(TaskStatus.COMPLETED, all[0].status)
        assertEquals(date.plusDays(1), all[1].targetDate)
        assertEquals(TaskStatus.PENDING, all[1].status)
        assertEquals(all[0].seriesId, all[1].seriesId)
    }

    @Test
    fun `当前周期已完成任务可以撤销且重复恢复保持幂等`() = runBlocking {
        val id = repository.create(TaskDraft(title = "误点完成", targetDate = date))
        assertTrue(repository.toggleCompletion(id, date))
        assertEquals(TaskStatus.COMPLETED, repository.get(id)?.status)

        assertTrue(repository.toggleCompletion(id, date))
        assertEquals(TaskStatus.PENDING, repository.get(id)?.status)
        assertEquals(null, repository.get(id)?.settledAt)

        assertFalse(store.reopenCompleted(id, 99_999))
        assertEquals(TaskStatus.PENDING, repository.get(id)?.status)
    }

    @Test
    fun `过期重复周期与Pass任务不能恢复为待办`() = runBlocking {
        val expiredId = repository.create(
            TaskDraft(
                title = "昨日完成",
                targetDate = date.minusDays(1),
                recurrence = Recurrence.DAILY,
            ),
        )
        assertTrue(repository.settle(expiredId, TaskStatus.COMPLETED))
        assertFalse(repository.toggleCompletion(expiredId, date))
        assertEquals(TaskStatus.COMPLETED, repository.get(expiredId)?.status)

        val passedId = repository.create(TaskDraft(title = "已Pass", targetDate = date))
        assertTrue(repository.settle(passedId, TaskStatus.PASS))
        assertFalse(repository.toggleCompletion(passedId, date))
        assertEquals(TaskStatus.PASS, repository.get(passedId)?.status)
    }

    @Test
    fun `一次性任务 Pass 后不会产生新实例且不能重复结算`() = runBlocking {
        val id = repository.create(TaskDraft(title = "可选整理", targetDate = date))

        assertTrue(repository.settle(id, TaskStatus.PASS))
        assertFalse(repository.settle(id, TaskStatus.COMPLETED))
        assertEquals(1, store.items.value.size)
        assertEquals(TaskStatus.PASS, store.items.value.single().status)
    }

    @Test
    fun `今日查询返回待办和已完成但不返回 Pass`() = runBlocking {
        repository.create(TaskDraft(title = "今天", targetDate = date))
        repository.create(TaskDraft(title = "明天", targetDate = date.plusDays(1)))

        val todayId = repository.tasksForToday(date).single().id
        repository.settle(todayId, TaskStatus.COMPLETED)
        assertEquals(listOf(TaskStatus.COMPLETED), repository.tasksForToday(date).map { it.status })
        assertEquals(1, repository.observeForScope(TaskTimeType.DAY, date).first().size)
    }

    @Test
    fun `过期一次性任务会保留到当前周期直至手动Pass`() = runBlocking {
        val overdueId = repository.create(
            TaskDraft(title = "昨日未完成", targetDate = date.minusDays(1)),
        )

        assertEquals(0, repository.autoPassExpired(date))
        assertEquals(
            listOf(overdueId),
            repository.observeForScope(TaskTimeType.DAY, date).first().map { it.id },
        )
        assertEquals(listOf(overdueId), repository.tasksForToday(date).map { it.id })

        assertTrue(repository.settle(overdueId, TaskStatus.PASS))
        assertTrue(repository.tasksForToday(date).isEmpty())
    }

    @Test
    fun `过期一次性任务完成当天仍可见且次日退出今日列表`() = runBlocking {
        val overdueId = repository.create(
            TaskDraft(title = "昨日待办", targetDate = date.minusDays(1)),
        )

        assertTrue(repository.toggleCompletion(overdueId, date))

        assertEquals(
            listOf(TaskStatus.COMPLETED),
            repository.observeForScope(TaskTimeType.DAY, date).first().map { it.status },
        )
        assertEquals(listOf(overdueId), repository.tasksForToday(date).map { it.id })
        assertTrue(repository.tasksForToday(date.plusDays(1)).isEmpty())
    }

    @Test
    fun `一次性任务保留截止日期且重复任务会清除截止日期`() = runBlocking {
        val deadline = date.plusDays(7)
        val onceId = repository.create(
            TaskDraft(title = "有截止日", targetDate = date, deadlineDate = deadline),
        )
        val repeatingId = repository.create(
            TaskDraft(
                title = "每日重复",
                targetDate = date,
                recurrence = Recurrence.DAILY,
                deadlineDate = deadline,
            ),
        )

        assertEquals(deadline, repository.get(onceId)?.deadlineDate)
        assertEquals(null, repository.get(repeatingId)?.deadlineDate)
    }

    @Test
    fun `自动 Pass 会追赶重复任务直到当前周期`() = runBlocking {
        repository.create(
            TaskDraft(
                title = "每日回顾",
                targetDate = date.minusDays(2),
                recurrence = Recurrence.DAILY,
            ),
        )

        assertEquals(2, repository.autoPassExpired(date))
        val occurrences = store.items.value.sortedBy { it.targetDate }
        assertEquals(
            listOf(TaskStatus.PASS, TaskStatus.PASS, TaskStatus.PENDING),
            occurrences.map { it.status },
        )
        assertEquals(date, occurrences.last().targetDate)
    }

    @Test
    fun `只有待办任务可以删除`() = runBlocking {
        val pendingId = repository.create(TaskDraft(title = "待删除", targetDate = date))

        assertTrue(repository.delete(pendingId))
        assertEquals(null, repository.get(pendingId))

        val completedId = repository.create(TaskDraft(title = "已结束", targetDate = date))
        repository.settle(completedId, TaskStatus.COMPLETED)
        assertFalse(repository.delete(completedId))
    }

    @Test
    fun `重排会保存同组任务顺序`() = runBlocking {
        val first = repository.create(TaskDraft(title = "一", targetDate = date))
        val second = repository.create(TaskDraft(title = "二", targetDate = date))
        val third = repository.create(TaskDraft(title = "三", targetDate = date))

        repository.reorder(listOf(third, first, second))

        assertEquals(
            listOf(third, first, second),
            repository.observeForScope(TaskTimeType.DAY, date).first().map { it.id },
        )
    }

    @Test
    fun `新任务追加到手动排序后的组末尾`() = runBlocking {
        val first = repository.create(TaskDraft(title = "一", targetDate = date))
        val second = repository.create(TaskDraft(title = "二", targetDate = date))
        val third = repository.create(TaskDraft(title = "三", targetDate = date))
        repository.reorder(listOf(third, first, second))

        val fourth = repository.create(TaskDraft(title = "四", targetDate = date))

        assertEquals(
            listOf(third, first, second, fourth),
            repository.observeForScope(TaskTimeType.DAY, date).first().map { it.id },
        )
    }

    @Test
    fun `追加顺序按周期和任务线分别计算`() = runBlocking {
        val todayMain = repository.create(TaskDraft(title = "今日主线一", targetDate = date))
        val tomorrowMain = repository.create(
            TaskDraft(title = "明日主线", targetDate = date.plusDays(1)),
        )
        val todaySide = repository.create(
            TaskDraft(title = "今日支线", targetDate = date, questLine = QuestLine.SIDE),
        )
        val todayMainSecond = repository.create(TaskDraft(title = "今日主线二", targetDate = date))

        assertEquals(0, repository.get(todayMain)?.sortOrder)
        assertEquals(0, repository.get(tomorrowMain)?.sortOrder)
        assertEquals(0, repository.get(todaySide)?.sortOrder)
        assertEquals(1, repository.get(todayMainSecond)?.sortOrder)
    }

    @Test
    fun `编辑任务默认保留手动排序位置`() = runBlocking {
        val first = repository.create(TaskDraft(title = "一", targetDate = date))
        val second = repository.create(TaskDraft(title = "二", targetDate = date))
        repository.reorder(listOf(second, first))

        assertTrue(repository.update(second, TaskDraft(title = "二（已编辑）", targetDate = date)))

        assertEquals(
            listOf(second, first),
            repository.observeForScope(TaskTimeType.DAY, date).first().map { it.id },
        )
    }

    @Test
    fun `编辑任务移入其他组时追加到目标组末尾`() = runBlocking {
        val source = repository.create(TaskDraft(title = "今日", targetDate = date))
        val first = repository.create(TaskDraft(title = "明日一", targetDate = date.plusDays(1)))
        val second = repository.create(TaskDraft(title = "明日二", targetDate = date.plusDays(1)))

        assertTrue(
            repository.update(
                source,
                TaskDraft(title = "移到明日", targetDate = date.plusDays(1)),
            ),
        )

        assertEquals(2, repository.get(source)?.sortOrder)
        assertEquals(
            listOf(first, second, source),
            repository.observeForScope(TaskTimeType.DAY, date.plusDays(1)).first().map { it.id },
        )
    }
}

private class FakeTaskStore : TaskStore {
    val items = MutableStateFlow<List<TaskEntity>>(emptyList())

    override fun observeAll(): Flow<List<TaskEntity>> = items

    override fun observeForPeriod(
        timeType: TaskTimeType,
        targetDate: LocalDate,
        includeOverdueOnce: Boolean,
    ): Flow<List<TaskEntity>> = items.map { tasks ->
        tasks.filter { task ->
            task.timeType == timeType &&
                (task.targetDate == targetDate ||
                    (includeOverdueOnce && task.targetDate?.isBefore(targetDate) == true &&
                        task.recurrence == Recurrence.ONCE &&
                        (task.status == TaskStatus.PENDING ||
                            task.completedInPeriod(timeType, targetDate))))
        }
    }

    override fun observeLeisure(): Flow<List<TaskEntity>> = items.map { tasks ->
        tasks.filter { it.timeType == TaskTimeType.LEISURE }
    }

    override suspend fun getForDay(date: LocalDate): List<TaskEntity> =
        items.value.filter {
            it.timeType == TaskTimeType.DAY &&
                ((it.targetDate == date && it.status != TaskStatus.PASS) ||
                    (it.targetDate?.isBefore(date) == true && it.recurrence == Recurrence.ONCE &&
                        (it.status == TaskStatus.PENDING ||
                            it.completedInPeriod(TaskTimeType.DAY, date))))
        }

    override suspend fun getExpiredPending(
        dayCutoff: LocalDate,
        weekCutoff: LocalDate,
        monthCutoff: LocalDate,
    ): List<TaskEntity> = items.value.filter { task ->
        task.status == TaskStatus.PENDING && task.recurrence != Recurrence.ONCE &&
            when (task.timeType) {
            TaskTimeType.DAY -> task.targetDate?.isBefore(dayCutoff) == true
            TaskTimeType.WEEK -> task.targetDate?.isBefore(weekCutoff) == true
            TaskTimeType.MONTH -> task.targetDate?.isBefore(monthCutoff) == true
            TaskTimeType.LEISURE -> false
            }
    }

    override suspend fun countForDay(date: LocalDate): Int =
        items.value.count { it.timeType == TaskTimeType.DAY && it.targetDate == date }

    override suspend fun getById(id: String): TaskEntity? = items.value.firstOrNull { it.id == id }

    override suspend fun maximumSortOrder(
        timeType: TaskTimeType,
        targetDate: LocalDate?,
        questLine: QuestLine,
    ): Int? = items.value
        .filter {
            it.timeType == timeType && it.targetDate == targetDate && it.questLine == questLine
        }
        .maxOfOrNull(TaskEntity::sortOrder)

    override suspend fun insert(task: TaskEntity) {
        check(items.value.none { it.id == task.id })
        items.value = items.value + task
    }

    override suspend fun update(task: TaskEntity): Boolean {
        if (items.value.none { it.id == task.id }) return false
        items.value = items.value.map { if (it.id == task.id) task else it }
        return true
    }

    override suspend fun deletePending(id: String, deletedAt: Long): Boolean {
        val task = getById(id) ?: return false
        if (task.status != TaskStatus.PENDING) return false
        items.value = items.value.filterNot { it.id == id }
        return true
    }

    override suspend fun settleAndSchedule(
        id: String,
        status: TaskStatus,
        settledAt: Long,
        nextTask: (TaskEntity) -> TaskEntity?,
    ): Boolean {
        val current = getById(id) ?: return false
        if (current.status != TaskStatus.PENDING) return false
        val settled = current.copy(status = status, settledAt = settledAt, updatedAt = settledAt)
        val next = nextTask(current)?.takeUnless { candidate ->
            items.value.any { it.id == candidate.id }
        }
        items.value = items.value.map { if (it.id == id) settled else it } + listOfNotNull(next)
        return true
    }

    override suspend fun reopenCompleted(id: String, updatedAt: Long): Boolean {
        val current = getById(id) ?: return false
        if (current.status != TaskStatus.COMPLETED) return false
        items.value = items.value.map { task ->
            if (task.id == id) {
                task.copy(
                    status = TaskStatus.PENDING,
                    settledAt = null,
                    updatedAt = updatedAt,
                )
            } else {
                task
            }
        }
        return true
    }

    override suspend fun reorder(idsInOrder: List<String>, updatedAt: Long): Boolean {
        val order = idsInOrder.withIndex().associate { (index, id) -> id to index }
        items.value = items.value.map { task ->
            order[task.id]?.let { task.copy(sortOrder = it, updatedAt = updatedAt) } ?: task
        }
        return idsInOrder.isNotEmpty()
    }

    private fun TaskEntity.completedInPeriod(
        timeType: TaskTimeType,
        periodStart: LocalDate,
    ): Boolean {
        if (status != TaskStatus.COMPLETED) return false
        val settledDate = settledAt
            ?.let(Instant::ofEpochMilli)
            ?.atZone(TaskDateRules.zoneId)
            ?.toLocalDate()
            ?: return false
        val periodEnd = when (timeType) {
            TaskTimeType.DAY -> periodStart.plusDays(1)
            TaskTimeType.WEEK -> periodStart.plusWeeks(1)
            TaskTimeType.MONTH -> periodStart.plusMonths(1)
            TaskTimeType.LEISURE -> return false
        }
        return settledDate >= periodStart && settledDate < periodEnd
    }
}
