package com.wootodo.data

import com.wootodo.domain.Recurrence
import com.wootodo.domain.OccurrenceId
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskDraft
import com.wootodo.domain.TaskRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.Clock
import java.time.LocalDate
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class TaskRepository(
    private val store: TaskStore,
    private val clock: Clock = Clock.system(TaskDateRules.zoneId),
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
) {
    fun observeAllTasks(): Flow<List<Task>> = store.observeAll().map { entities ->
        entities.map(TaskEntity::toDomain).sortedWith(TaskRules.ordering)
    }

    suspend fun allTasks(): List<Task> =
        store.getAll().map(TaskEntity::toDomain).sortedWith(TaskRules.ordering)

    fun observeForScope(timeType: TaskTimeType, referenceDate: LocalDate): Flow<List<Task>> {
        val source = if (timeType == TaskTimeType.LEISURE) {
            store.observeLeisure()
        } else {
            val targetDate = requireNotNull(TaskDateRules.targetForScope(timeType, referenceDate))
            store.observeForPeriod(timeType, targetDate)
        }
        return source.map { entities ->
            entities.map(TaskEntity::toDomain).sortedWith(TaskRules.ordering)
        }
    }

    suspend fun get(id: String): Task? = store.getById(id)?.toDomain()

    suspend fun create(draft: TaskDraft): String {
        require(draft.title.isNotBlank()) { "任务标题不能为空" }
        require(draft.title.codePointCount(0, draft.title.length) <= 120) {
            "任务标题不能超过 120 个 Unicode 字符"
        }
        val now = clock.millis()
        val id = idFactory()
        val recurrence = TaskRules.sanitizeRecurrence(draft.timeType, draft.recurrence)
        val targetDate = normalizedTarget(draft.timeType, draft.targetDate)
        val sortOrder = draft.sortOrder ?: (
            (store.maximumSortOrder(draft.timeType, targetDate, draft.questLine) ?: -1) + 1
            )
        store.insert(
            TaskEntity(
                id = id,
                seriesId = id,
                title = draft.title.trim(),
                timeType = draft.timeType,
                targetDate = targetDate,
                questLine = draft.questLine,
                status = TaskStatus.PENDING,
                recurrence = recurrence,
                sortOrder = sortOrder,
                createdAt = now,
                updatedAt = now,
                settledAt = null,
                reminderTime = if (draft.timeType == TaskTimeType.LEISURE) null else draft.reminderTime,
            ),
        )
        return id
    }

    suspend fun update(id: String, draft: TaskDraft): Boolean {
        require(draft.title.isNotBlank()) { "任务标题不能为空" }
        require(draft.title.codePointCount(0, draft.title.length) <= 120) {
            "任务标题不能超过 120 个 Unicode 字符"
        }
        val current = store.getById(id) ?: return false
        if (current.status != TaskStatus.PENDING) return false
        val targetDate = normalizedTarget(draft.timeType, draft.targetDate)
        val movedToAnotherGroup = current.timeType != draft.timeType ||
            current.targetDate != targetDate || current.questLine != draft.questLine
        val sortOrder = when {
            draft.sortOrder != null -> draft.sortOrder
            movedToAnotherGroup -> (
                (store.maximumSortOrder(draft.timeType, targetDate, draft.questLine) ?: -1) + 1
                )
            else -> current.sortOrder
        }
        return store.update(
            current.copy(
                title = draft.title.trim(),
                timeType = draft.timeType,
                targetDate = targetDate,
                questLine = draft.questLine,
                recurrence = TaskRules.sanitizeRecurrence(draft.timeType, draft.recurrence),
                reminderTime = if (draft.timeType == TaskTimeType.LEISURE) null else draft.reminderTime,
                sortOrder = sortOrder,
                updatedAt = clock.millis(),
            ),
        )
    }

    suspend fun delete(id: String): Boolean = store.deletePending(id, clock.millis())

    suspend fun settle(id: String, status: TaskStatus): Boolean {
        require(status == TaskStatus.COMPLETED || status == TaskStatus.PASS)
        val now = clock.millis()
        return store.settleAndSchedule(id, status, now) { current ->
            nextOccurrence(current, now)
        }
    }

    suspend fun tasksForToday(date: LocalDate = LocalDate.now(clock)): List<Task> =
        store.getForDay(date).map(TaskEntity::toDomain).sortedWith(TaskRules.ordering)

    suspend fun autoPassExpired(referenceDate: LocalDate = LocalDate.now(clock)): Int {
        val weekCutoff = requireNotNull(
            TaskDateRules.normalizeTargetDate(TaskTimeType.WEEK, referenceDate),
        )
        val monthCutoff = requireNotNull(
            TaskDateRules.normalizeTargetDate(TaskTimeType.MONTH, referenceDate),
        )
        var settledCount = 0
        while (true) {
            val expired = store.getExpiredPending(referenceDate, weekCutoff, monthCutoff)
            if (expired.isEmpty()) return settledCount
            var settledThisRound = 0
            expired.forEach { task ->
                if (settle(task.id, TaskStatus.PASS)) {
                    settledCount += 1
                    settledThisRound += 1
                }
            }
            if (settledThisRound == 0) return settledCount
        }
    }

    suspend fun countTasksForDay(date: LocalDate): Int = store.countForDay(date)

    suspend fun reorder(idsInOrder: List<String>) {
        store.reorder(idsInOrder, clock.millis())
    }

    private fun normalizedTarget(timeType: TaskTimeType, date: LocalDate?): LocalDate? {
        if (timeType == TaskTimeType.LEISURE) return null
        return TaskDateRules.normalizeTargetDate(timeType, date ?: LocalDate.now(clock))
    }

    private fun nextOccurrence(current: TaskEntity, now: Long): TaskEntity? {
        if (current.recurrence == Recurrence.ONCE || current.timeType == TaskTimeType.LEISURE) {
            return null
        }
        val currentDate = current.targetDate ?: LocalDate.now(clock)
        val advancedDate = TaskDateRules.nextOccurrenceDate(currentDate, current.recurrence)
            ?: return null
        val targetDate = TaskDateRules.normalizeTargetDate(current.timeType, advancedDate)
            ?: return null
        return current.copy(
            id = OccurrenceId.create(current.seriesId, current.timeType, targetDate),
            targetDate = targetDate,
            status = TaskStatus.PENDING,
            createdAt = now,
            updatedAt = now,
            settledAt = null,
        )
    }
}
