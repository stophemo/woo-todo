package com.wootodo.data

import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.TaskDraft
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
    private val ids = ArrayDeque(listOf("task-1", "task-2", "task-3"))
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
}

private class FakeTaskStore : TaskStore {
    val items = MutableStateFlow<List<TaskEntity>>(emptyList())

    override fun observeAll(): Flow<List<TaskEntity>> = items

    override fun observeForPeriod(
        timeType: TaskTimeType,
        targetDate: LocalDate,
    ): Flow<List<TaskEntity>> = items.map { tasks ->
        tasks.filter { it.timeType == timeType && it.targetDate == targetDate }
    }

    override fun observeLeisure(): Flow<List<TaskEntity>> = items.map { tasks ->
        tasks.filter { it.timeType == TaskTimeType.LEISURE }
    }

    override suspend fun getForDay(date: LocalDate): List<TaskEntity> =
        items.value.filter {
            it.timeType == TaskTimeType.DAY &&
                it.targetDate == date &&
                it.status != TaskStatus.PASS
        }

    override suspend fun getExpiredPending(
        dayCutoff: LocalDate,
        weekCutoff: LocalDate,
        monthCutoff: LocalDate,
    ): List<TaskEntity> = items.value.filter { task ->
        task.status == TaskStatus.PENDING && when (task.timeType) {
            TaskTimeType.DAY -> task.targetDate?.isBefore(dayCutoff) == true
            TaskTimeType.WEEK -> task.targetDate?.isBefore(weekCutoff) == true
            TaskTimeType.MONTH -> task.targetDate?.isBefore(monthCutoff) == true
            TaskTimeType.LEISURE -> false
        }
    }

    override suspend fun countForDay(date: LocalDate): Int =
        items.value.count { it.timeType == TaskTimeType.DAY && it.targetDate == date }

    override suspend fun getById(id: String): TaskEntity? = items.value.firstOrNull { it.id == id }

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
        val next = nextTask(current)
        items.value = items.value.map { if (it.id == id) settled else it } + listOfNotNull(next)
        return true
    }

    override suspend fun reorder(idsInOrder: List<String>, updatedAt: Long): Boolean {
        val order = idsInOrder.withIndex().associate { (index, id) -> id to index }
        items.value = items.value.map { task ->
            order[task.id]?.let { task.copy(sortOrder = it, updatedAt = updatedAt) } ?: task
        }
        return idsInOrder.isNotEmpty()
    }
}
