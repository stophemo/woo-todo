package com.wootodo.data

import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskDateState
import com.wootodo.domain.TaskDraft
import com.wootodo.domain.TaskStatus
import java.time.Clock
import java.time.LocalDate
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class TaskRepository(
    private val store: TaskStore,
    private val clock: Clock = Clock.system(TaskDateRules.zoneId),
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
    private val categoryIdFactory: (Set<String>) -> String = TaskCategories::newId,
) {
    fun observeAllTasks(): Flow<List<Task>> = store.observeAll().map { entities ->
        entities.map(TaskEntity::toDomain).sortedWith(ordering)
    }

    suspend fun allTasks(): List<Task> =
        store.getAll().map(TaskEntity::toDomain).sortedWith(ordering)

    fun observeCategories(): Flow<List<TaskCategory>> = store.observeCategories().map { categories ->
        if (categories.isEmpty()) TaskCategories.defaults else categories
    }

    suspend fun allCategories(): List<TaskCategory> =
        store.getCategories().ifEmpty { TaskCategories.defaults }

    suspend fun get(id: String): Task? = store.getById(id)?.toDomain()

    suspend fun create(draft: TaskDraft): String {
        val title = validateTitle(draft.title)
        val (start, end) = validateDates(draft.startDate, draft.endDate)
        val categoryId = resolveCategory(draft.categoryId)
        val now = clock.millis()
        val sortOrder = draft.sortOrder
            ?: ((store.getAll().maxOfOrNull { it.sortOrder } ?: -1) + 1)
        val id = idFactory()
        store.insert(
            TaskEntity(
                id = id,
                seriesId = id,
                title = title,
                categoryId = categoryId,
                startDate = start,
                endDate = end,
                status = TaskStatus.PENDING,
                sortOrder = sortOrder,
                createdAt = now,
                updatedAt = now,
                settledAt = null,
                reminderTime = draft.reminderTime.takeIf { start != null },
            ),
        )
        return id
    }

    suspend fun update(id: String, draft: TaskDraft): Boolean {
        val current = store.getById(id) ?: return false
        if (current.status != TaskStatus.PENDING) return false
        val title = validateTitle(draft.title)
        val (start, end) = validateDates(draft.startDate, draft.endDate)
        val categoryId = resolveCategory(draft.categoryId)
        return store.update(
            current.copy(
                title = title,
                categoryId = categoryId,
                startDate = start,
                endDate = end,
                reminderTime = draft.reminderTime.takeIf { start != null },
                sortOrder = draft.sortOrder ?: current.sortOrder,
                updatedAt = clock.millis(),
            ),
        )
    }

    suspend fun delete(id: String): Boolean = store.deletePending(id, clock.millis())

    suspend fun clearHistory(ids: Set<String>? = null): Int {
        if (ids?.isEmpty() == true) return 0
        return store.deleteSettled(ids, clock.millis())
    }

    suspend fun settle(id: String, status: TaskStatus): Boolean {
        require(status == TaskStatus.COMPLETED || status == TaskStatus.PASS)
        return store.settle(id, status, clock.millis())
    }

    suspend fun toggleCompletion(id: String): Boolean {
        val current = store.getById(id) ?: return false
        return when (current.status) {
            TaskStatus.PENDING -> settle(id, TaskStatus.COMPLETED)
            TaskStatus.COMPLETED -> reopen(id)
            TaskStatus.PASS -> false
        }
    }

    suspend fun reopen(id: String): Boolean {
        val current = store.getById(id) ?: return false
        if (current.status != TaskStatus.COMPLETED) return false
        return store.reopenCompleted(id, clock.millis())
    }

    suspend fun tasksForToday(date: LocalDate = LocalDate.now(clock)): List<Task> {
        val zone = clock.zone
        return allTasks().filter { task ->
            TaskDateState.isRelevantOn(task, date) ||
                TaskDateState.isSettledOn(task, date, zone)
        }
    }

    suspend fun countTasksForDay(date: LocalDate): Int = store.getAll().count { task ->
        task.status == TaskStatus.PENDING &&
            task.startDate != null &&
            task.endDate != null &&
            !task.startDate.isAfter(date) &&
            !task.endDate.isBefore(date)
    }

    suspend fun addCategory(name: String): TaskCategory? {
        val current = allCategories()
        if (current.size >= TaskCategories.MAXIMUM_COUNT) return null
        val normalized = TaskCategories.normalizeName(name) ?: return null
        if (current.any { it.name == normalized }) return null
        val category = TaskCategory(
            id = categoryIdFactory(current.mapTo(HashSet()) { it.id }),
            name = normalized,
            order = current.size,
        )
        val updated = TaskCategories.normalizeList(current + category)
        store.replaceCategories(updated, clock.millis())
        return updated.firstOrNull { it.id == category.id }
    }

    suspend fun renameCategory(id: String, name: String): Boolean {
        val normalized = TaskCategories.normalizeName(name) ?: return false
        val current = allCategories()
        if (current.none { it.id == id }) return false
        if (current.any { it.id != id && it.name == normalized }) return false
        val updated = current.map { category ->
            if (category.id == id) category.copy(name = normalized) else category
        }
        store.replaceCategories(TaskCategories.normalizeList(updated), clock.millis())
        return true
    }

    suspend fun deleteCategory(id: String): Boolean {
        if (id == TaskCategories.INBOX_ID) return false
        val current = allCategories()
        if (current.none { it.id == id }) return false
        val now = clock.millis()
        store.reassignPendingCategory(id, TaskCategories.INBOX_ID, now)
        store.replaceCategories(
            TaskCategories.normalizeList(current.filterNot { it.id == id }),
            now,
        )
        return true
    }

    private suspend fun resolveCategory(categoryId: String): String {
        val categories = allCategories()
        return categoryId.takeIf { id -> categories.any { it.id == id } }
            ?: TaskCategories.INBOX_ID
    }

    private fun validateTitle(title: String): String {
        val normalized = title.trim()
        require(normalized.isNotEmpty()) { "任务标题不能为空" }
        require(normalized.codePointCount(0, normalized.length) <= 120) {
            "任务标题不能超过 120 个 Unicode 字符"
        }
        return normalized
    }

    private fun validateDates(start: LocalDate?, end: LocalDate?): Pair<LocalDate?, LocalDate?> {
        require((start == null) == (end == null)) { "开始日期和结束日期必须同时设置或同时为空" }
        if (start != null && end != null) {
            require(!start.isAfter(end)) { "开始日期不能晚于结束日期" }
        }
        return start to end
    }

    private val ordering: Comparator<Task> = compareBy<Task> { statusRank(it.status) }
        .thenBy { it.startDate ?: LocalDate.MAX }
        .thenBy { it.sortOrder }
        .thenBy { it.createdAt }
        .thenBy { it.id }

    private fun statusRank(status: TaskStatus): Int = when (status) {
        TaskStatus.PENDING -> 0
        TaskStatus.COMPLETED -> 1
        TaskStatus.PASS -> 2
    }
}
