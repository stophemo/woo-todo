package com.wootodo.data

import com.wootodo.domain.CategoryInputResult
import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskDraft
import com.wootodo.domain.TaskStatus
import com.wootodo.ui.toRestoreDraft
import java.time.Clock
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskRepositoryTest {
    private val date = LocalDate.of(2026, 7, 15)
    private val store = FakeTaskStore()
    private val ids = ArrayDeque((1..20).map { "task-$it" })
    private val repository = TaskRepository(
        store = store,
        clock = Clock.fixed(Instant.parse("2026-07-15T04:00:00Z"), ZoneId.of("Asia/Shanghai")),
        idFactory = { ids.removeFirst() },
    )

    @Test
    fun `创建无日期任务默认未分类并清理标题`() = runBlocking {
        val id = repository.create(TaskDraft(title = "  写周报  "))

        val task = repository.get(id)!!
        assertEquals("写周报", task.title)
        assertEquals(TaskCategories.INBOX_ID, task.categoryId)
        assertNull(task.startDate)
        assertNull(task.endDate)
        assertEquals(0, task.sortOrder)
    }

    @Test
    fun `默认只有未分类类型`() = runBlocking {
        assertEquals(
            listOf(TaskCategories.INBOX_ID),
            repository.allCategories().map(TaskCategory::id),
        )
    }

    @Test
    fun `创建日期范围任务并拒绝开始晚于结束`() = runBlocking {
        val work = repository.addCategory("整理")!!
        val id = repository.create(
            TaskDraft(
                title = "整理方案",
                categoryId = work.id,
                startDate = date,
                endDate = date.plusDays(2),
            ),
        )

        val task = repository.get(id)!!
        assertEquals(work.id, task.categoryId)
        assertEquals(date, task.startDate)
        assertEquals(date.plusDays(2), task.endDate)

        assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                repository.create(
                    TaskDraft(
                        title = "错误范围",
                        startDate = date.plusDays(1),
                        endDate = date,
                    ),
                )
            }
        }
        Unit
    }

    @Test
    fun `标题上限按Unicode code point计算`() = runBlocking {
        val valid = "😀".repeat(120)
        val id = repository.create(TaskDraft(title = valid))
        assertEquals(valid, repository.get(id)?.title)

        assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                repository.create(TaskDraft(title = "😀".repeat(121)))
            }
        }
        Unit
    }

    @Test
    fun `完成撤销和放弃的状态规则`() = runBlocking {
        val id = repository.create(TaskDraft(title = "状态测试"))

        assertTrue(repository.toggleCompletion(id))
        assertEquals(TaskStatus.COMPLETED, repository.get(id)?.status)
        assertTrue(repository.toggleCompletion(id))
        assertEquals(TaskStatus.PENDING, repository.get(id)?.status)

        assertTrue(repository.settle(id, TaskStatus.PASS))
        assertEquals(TaskStatus.PASS, repository.get(id)?.status)
        assertFalse(repository.reopen(id))
    }

    @Test
    fun `只有待办任务可以删除`() = runBlocking {
        val pending = repository.create(TaskDraft(title = "待删除"))
        assertTrue(repository.delete(pending))
        assertNull(repository.get(pending))

        val completed = repository.create(TaskDraft(title = "已完成"))
        repository.settle(completed, TaskStatus.COMPLETED)
        assertFalse(repository.delete(completed))
    }

    @Test
    fun `今日任务包含逾期覆盖今天无日期和今天结算`() = runBlocking {
        val overdue = repository.create(
            TaskDraft(title = "逾期", startDate = date.minusDays(2), endDate = date.minusDays(1)),
        )
        val active = repository.create(
            TaskDraft(title = "进行中", startDate = date.minusDays(1), endDate = date.plusDays(1)),
        )
        val undated = repository.create(TaskDraft(title = "无日期"))
        val future = repository.create(
            TaskDraft(title = "未来", startDate = date.plusDays(2), endDate = date.plusDays(3)),
        )
        val settledToday = repository.create(TaskDraft(title = "今天完成"))
        repository.settle(settledToday, TaskStatus.COMPLETED)
        val settledYesterday = repository.create(TaskDraft(title = "昨天完成"))
        store.items.value = store.items.value.map { task ->
            if (task.id == settledYesterday) {
                task.copy(
                    status = TaskStatus.COMPLETED,
                    settledAt = date.minusDays(1).atTime(10, 0)
                        .atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli(),
                )
            } else {
                task
            }
        }

        val ids = repository.tasksForToday(date).map(Task::id).toSet()
        assertEquals(setOf(overdue, active, undated, settledToday), ids)
        assertFalse(future in ids)
        assertFalse(settledYesterday in ids)
    }

    @Test
    fun `统计某天任务数包含覆盖当天和当天开始`() = runBlocking {
        repository.create(TaskDraft(title = "覆盖", startDate = date.minusDays(1), endDate = date))
        repository.create(TaskDraft(title = "当天开始", startDate = date, endDate = date.plusDays(2)))
        repository.create(TaskDraft(title = "未来", startDate = date.plusDays(1), endDate = date.plusDays(1)))

        assertEquals(2, repository.countTasksForDay(date))
    }

    @Test
    fun `分类新增改名删除与重分配`() = runBlocking {
        val work = repository.addCategory("工作")!!
        assertEquals("工作", work.name)
        assertTrue(repository.renameCategory(work.id, "工作项目"))
        assertEquals("工作项目", repository.allCategories().first { it.id == work.id }.name)

        val taskId = repository.create(TaskDraft(title = "归入工作", categoryId = work.id))
        assertTrue(repository.deleteCategory(work.id))
        assertEquals(TaskCategories.INBOX_ID, repository.get(taskId)?.categoryId)
        assertFalse(repository.deleteCategory(TaskCategories.INBOX_ID))
    }

    @Test
    fun `分类最多八个且名称不能重复`() = runBlocking {
        assertEquals(1, repository.allCategories().size)
        repeat(7) { index ->
            assertTrue(repository.addCategory("自定义$index") != null)
        }
        assertEquals(8, repository.allCategories().size)
        assertNull(repository.addCategory("第九个"))
        assertNull(repository.addCategory("自定义0"))
    }

    @Test
    fun `标签输入留空匹配已有或自动新建`() = runBlocking {
        val work = repository.addCategory("工作")!!

        val matched = repository.resolveCategoryInput("  工作 ")
        assertEquals(work.id, (matched as CategoryInputResult.Selected).category.id)

        val none = repository.resolveCategoryInput("   ")
        assertEquals(
            TaskCategories.INBOX_ID,
            (none as CategoryInputResult.Selected).category.id,
        )

        val created = repository.resolveCategoryInput("学习")
        val category = (created as CategoryInputResult.Selected).category
        assertEquals("学习", category.name)
        assertTrue(repository.allCategories().any { it.id == category.id })
    }

    @Test
    fun `标签输入匹配忽略大小写`() = runBlocking {
        val work = repository.addCategory("Work")!!

        val matched = repository.resolveCategoryInput("work")

        assertEquals(work.id, (matched as CategoryInputResult.Selected).category.id)
        assertEquals(2, repository.allCategories().size)
    }

    @Test
    fun `标签输入校验名称和数量上限`() = runBlocking {
        assertEquals(
            CategoryInputResult.InvalidName,
            repository.resolveCategoryInput("字".repeat(13)),
        )

        repeat(7) { index ->
            assertTrue(repository.addCategory("标签$index") != null)
        }
        assertEquals(
            CategoryInputResult.LimitReached,
            repository.resolveCategoryInput("新标签"),
        )
    }

    @Test
    fun `撤销删除恢复原分类和日期`() = runBlocking {
        val side = repository.addCategory("支线")!!
        val id = repository.create(
            TaskDraft(
                title = "恢复任务",
                categoryId = side.id,
                startDate = date,
                endDate = date.plusDays(2),
            ),
        )
        val original = repository.get(id)!!
        assertTrue(repository.delete(id))

        val restored = repository.create(original.toRestoreDraft())
        val task = repository.get(restored)!!
        assertEquals(side.id, task.categoryId)
        assertEquals(date, task.startDate)
        assertEquals(date.plusDays(2), task.endDate)
        assertEquals(original.sortOrder, task.sortOrder)
    }
}

private class FakeTaskStore : TaskStore {
    val items = MutableStateFlow<List<TaskEntity>>(emptyList())
    val categories = MutableStateFlow(TaskCategories.defaults)

    override fun observeAll(): Flow<List<TaskEntity>> = items

    override suspend fun getAll(): List<TaskEntity> = items.value

    override fun observeCategories(): Flow<List<TaskCategory>> = categories

    override suspend fun getCategories(): List<TaskCategory> = categories.value

    override suspend fun replaceCategories(
        categories: List<TaskCategory>,
        updatedAt: Long,
    ) {
        this.categories.value = categories
    }

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

    override suspend fun deleteSettled(ids: Set<String>?, deletedAt: Long): Int {
        if (ids?.isEmpty() == true) return 0
        val before = items.value.size
        items.value = items.value.filterNot { task ->
            task.status != TaskStatus.PENDING && (ids == null || task.id in ids)
        }
        return before - items.value.size
    }

    override suspend fun settle(id: String, status: TaskStatus, settledAt: Long): Boolean {
        val current = getById(id) ?: return false
        if (current.status != TaskStatus.PENDING) return false
        items.value = items.value.map { task ->
            if (task.id == id) {
                task.copy(status = status, settledAt = settledAt, updatedAt = settledAt)
            } else {
                task
            }
        }
        return true
    }

    override suspend fun reopenCompleted(id: String, updatedAt: Long): Boolean {
        val current = getById(id) ?: return false
        if (current.status != TaskStatus.COMPLETED) return false
        items.value = items.value.map { task ->
            if (task.id == id) {
                task.copy(status = TaskStatus.PENDING, settledAt = null, updatedAt = updatedAt)
            } else {
                task
            }
        }
        return true
    }

    override suspend fun reassignPendingCategory(
        from: String,
        to: String,
        updatedAt: Long,
    ): List<String> {
        val changed = items.value.filter { it.status == TaskStatus.PENDING && it.categoryId == from }
        items.value = items.value.map { task ->
            if (task.status == TaskStatus.PENDING && task.categoryId == from) {
                task.copy(categoryId = to, updatedAt = updatedAt)
            } else {
                task
            }
        }
        return changed.map(TaskEntity::id)
    }
}
