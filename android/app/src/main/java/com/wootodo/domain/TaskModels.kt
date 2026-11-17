package com.wootodo.domain

import java.time.LocalDate
import java.time.LocalTime

/** 任务标签（分类）。order 越小越靠前。 */
data class TaskCategory(
    val id: String,
    val name: String,
    val order: Int,
)

object TaskCategories {
    const val INBOX_ID = "inbox"
    private val ID_PATTERN = Regex("^[a-z0-9][a-z0-9_-]{0,31}$")
    private val CUSTOM_ID_CHARS = ('a'..'z') + ('0'..'9')
    const val MAXIMUM_COUNT = 8
    const val MAXIMUM_NAME_LENGTH = 12

    val defaults: List<TaskCategory> = listOf(
        TaskCategory(INBOX_ID, "未分类", 0),
    )

    fun isValidId(id: String): Boolean = ID_PATTERN.matches(id)

    fun normalizeName(name: String): String? {
        val normalized = name.trim()
        if (normalized.isEmpty() ||
            normalized.codePointCount(0, normalized.length) > MAXIMUM_NAME_LENGTH
        ) {
            return null
        }
        if (normalized.any { it == '\r' || it == '\n' || it == '\u000B' || it == '\u000C' }) {
            return null
        }
        return normalized
    }

    /** 去重、保留当前优先级顺序并重排 order；缺少 inbox 时补在最前。 */
    fun normalizeList(input: List<TaskCategory>): List<TaskCategory> {
        val seenIds = HashSet<String>()
        val seenNames = HashSet<String>()
        var hasInbox = false
        val values = buildList {
            input.forEach { category ->
                val name = normalizeName(category.name) ?: return@forEach
                if (!isValidId(category.id) || !seenIds.add(category.id)) return@forEach
                if (!seenNames.add(name)) return@forEach
                if (category.id == INBOX_ID) hasInbox = true
                add(category.copy(name = name))
            }
            if (!hasInbox) {
                add(0, TaskCategory(INBOX_ID, "未分类", 0))
            }
        }
        val limited = values.take(MAXIMUM_COUNT).toMutableList()
        if (limited.none { it.id == INBOX_ID }) {
            limited[limited.lastIndex] = TaskCategory(INBOX_ID, "未分类", 0)
        }
        return limited.mapIndexed { index, category ->
            category.copy(order = index)
        }
    }

    fun newId(existing: Set<String>): String {
        repeat(64) {
            val candidate = buildString {
                append('c')
                repeat(7) { append(CUSTOM_ID_CHARS.random()) }
            }
            if (candidate !in existing) return candidate
        }
        error("无法生成唯一分类 ID")
    }

    fun resolveName(id: String, categories: List<TaskCategory>): String =
        categories.firstOrNull { it.id == id }?.name
            ?: defaults.firstOrNull { it.id == id }?.name
            ?: "未分类"
}

/** 标签输入解析结果；留空会落到 inbox，由界面显示为“无标签”。 */
sealed interface CategoryInputResult {
    data class Selected(val category: TaskCategory) : CategoryInputResult

    data object InvalidName : CategoryInputResult

    data object LimitReached : CategoryInputResult

    data object SaveFailed : CategoryInputResult
}

enum class TaskStatus(val rawValue: String) {
    PENDING("pending"),
    COMPLETED("completed"),
    PASS("pass");

    companion object {
        fun fromRaw(value: String): TaskStatus =
            entries.firstOrNull { it.rawValue == value }
                ?: entries.first { it.name.equals(value, ignoreCase = true) }
    }
}

data class Task(
    val id: String,
    val seriesId: String,
    val title: String,
    val categoryId: String,
    val startDate: LocalDate?,
    val endDate: LocalDate?,
    val status: TaskStatus,
    val sortOrder: Int,
    val createdAt: Long,
    val updatedAt: Long,
    val settledAt: Long?,
    val reminderTime: LocalTime? = null,
)

/** 本机恢复快照；任务已通过同步删除记录从其他设备移除。 */
data class TrashedTask(
    val task: Task,
    val deletedAt: Long,
)

data class TaskDraft(
    val title: String,
    val categoryId: String = TaskCategories.INBOX_ID,
    val startDate: LocalDate? = null,
    val endDate: LocalDate? = null,
    val reminderTime: LocalTime? = null,
    val sortOrder: Int? = null,
)
