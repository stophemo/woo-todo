package com.wootodo.ui

import android.graphics.Paint
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.CheckBox
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.RecyclerView
import com.wootodo.R
import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskDateState
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

private sealed interface TaskListItem {
    data class Header(val kind: TaskSectionKind) : TaskListItem
    data class Row(
        val task: Task,
        val meta: String,
    ) : TaskListItem
}

internal class TaskAdapter(
    private val context: android.content.Context,
    private val onCheck: (Task) -> Unit,
    private val onMenu: (Task, View) -> Unit,
    private val onEdit: (Task) -> Unit,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
    private val items = mutableListOf<TaskListItem>()

    fun submitSections(
        sections: List<TaskListSection>,
        categories: List<TaskCategory>,
    ) {
        val today = TaskDateRules.today()
        val updatedItems = buildList {
            sections.forEach { section ->
                add(TaskListItem.Header(section.kind))
                section.tasks.forEach { task ->
                    add(
                        TaskListItem.Row(
                            task = task,
                            meta = taskMeta(task, categories, today),
                        ),
                    )
                }
            }
        }
        val previousItems = items.toList()
        val difference = DiffUtil.calculateDiff(object : DiffUtil.Callback() {
            override fun getOldListSize(): Int = previousItems.size

            override fun getNewListSize(): Int = updatedItems.size

            override fun areItemsTheSame(oldItemPosition: Int, newItemPosition: Int): Boolean {
                val old = previousItems[oldItemPosition]
                val new = updatedItems[newItemPosition]
                return when {
                    old is TaskListItem.Header && new is TaskListItem.Header ->
                        old.kind == new.kind
                    old is TaskListItem.Row && new is TaskListItem.Row ->
                        old.task.id == new.task.id
                    else -> false
                }
            }

            override fun areContentsTheSame(oldItemPosition: Int, newItemPosition: Int): Boolean =
                previousItems[oldItemPosition] == updatedItems[newItemPosition]
        })
        items.clear()
        items.addAll(updatedItems)
        difference.dispatchUpdatesTo(this)
    }

    fun taskAt(position: Int): Task? = (items.getOrNull(position) as? TaskListItem.Row)?.task

    override fun getItemCount(): Int = items.size

    override fun getItemViewType(position: Int): Int =
        when (items[position]) {
            is TaskListItem.Header -> VIEW_TYPE_HEADER
            is TaskListItem.Row -> VIEW_TYPE_TASK
        }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): RecyclerView.ViewHolder {
        val inflater = LayoutInflater.from(parent.context)
        return when (viewType) {
            VIEW_TYPE_HEADER -> HeaderViewHolder(
                inflater.inflate(R.layout.item_task_header, parent, false),
            )
            else -> TaskViewHolder(inflater.inflate(R.layout.item_task, parent, false))
        }
    }

    override fun onBindViewHolder(holder: RecyclerView.ViewHolder, position: Int) {
        when (val item = items[position]) {
            is TaskListItem.Header -> (holder as HeaderViewHolder).bind(item.kind)
            is TaskListItem.Row -> (holder as TaskViewHolder).bind(item.task, item.meta)
        }
    }

    private class HeaderViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val headerTitle: TextView = itemView.findViewById(R.id.header_title)
        private val headerMarker: View = itemView.findViewById(R.id.header_marker)

        fun bind(kind: TaskSectionKind) {
            headerTitle.setText(kind.titleRes)
            val color = when (kind) {
                TaskSectionKind.OVERDUE -> R.color.orange
                TaskSectionKind.TODAY -> R.color.primary
                TaskSectionKind.UPCOMING -> R.color.muted
                TaskSectionKind.UNSCHEDULED -> R.color.muted
                TaskSectionKind.SETTLED_TODAY -> R.color.green
            }
            headerMarker.background.mutate()
                .setTint(ContextCompat.getColor(itemView.context, color))
        }
    }

    private inner class TaskViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val taskRow: View = itemView.findViewById(R.id.task_row)
        private val taskCheck: CheckBox = itemView.findViewById(R.id.task_check)
        private val taskTitle: TextView = itemView.findViewById(R.id.task_title)
        private val taskStatus: TextView = itemView.findViewById(R.id.task_status)
        private val taskActions: View = itemView.findViewById(R.id.task_actions)

        fun bind(task: Task, meta: String) {
            val pending = task.status == TaskStatus.PENDING
            taskTitle.text = task.title
            taskStatus.text = meta
            taskStatus.setTextColor(
                ContextCompat.getColor(
                    itemView.context,
                    if (TaskDateState.isOverdue(task, TaskDateRules.today())) {
                        R.color.orange
                    } else {
                        R.color.muted
                    },
                ),
            )
            taskCheck.setOnCheckedChangeListener(null)
            taskCheck.isChecked = task.status == TaskStatus.COMPLETED
            taskCheck.isEnabled = task.status != TaskStatus.PASS
            taskCheck.visibility = if (task.status == TaskStatus.PASS) View.INVISIBLE else View.VISIBLE
            taskCheck.contentDescription = itemView.context.getString(
                if (task.status == TaskStatus.COMPLETED) {
                    R.string.reopen_completed
                } else {
                    R.string.mark_completed
                },
            )
            taskCheck.setOnClickListener {
                if (task.status != TaskStatus.PASS) onCheck(task)
            }
            taskActions.contentDescription = itemView.context.getString(
                R.string.task_actions_for,
                task.title,
            )
            taskActions.setOnClickListener { onMenu(task, it) }
            taskRow.alpha = if (pending) 1f else 0.72f
            taskTitle.paintFlags = if (task.status == TaskStatus.COMPLETED) {
                taskTitle.paintFlags or Paint.STRIKE_THRU_TEXT_FLAG
            } else {
                taskTitle.paintFlags and Paint.STRIKE_THRU_TEXT_FLAG.inv()
            }
            taskRow.setOnClickListener { onEdit(task) }
        }
    }

    private fun taskMeta(
        task: Task,
        categories: List<TaskCategory>,
        today: LocalDate,
    ): String = buildList {
        when (task.status) {
            TaskStatus.COMPLETED -> add(itemViewContextString(R.string.status_completed))
            TaskStatus.PASS -> add(itemViewContextString(R.string.status_passed))
            TaskStatus.PENDING -> Unit
        }
        if (task.categoryId != TaskCategories.INBOX_ID) {
            add(TaskCategories.resolveName(task.categoryId, categories))
        }
        if (task.startDate == null || task.endDate == null) {
            add(itemViewContextString(R.string.section_unscheduled))
        } else if (task.startDate == task.endDate) {
            add(task.startDate.format(dateFormatter))
        } else {
            add("${task.startDate.format(dateFormatter)}–${task.endDate.format(dateFormatter)}")
        }
        if (task.status == TaskStatus.PENDING &&
            task.endDate != null &&
            task.endDate.isBefore(today)
        ) {
            val days = ChronoUnit.DAYS.between(task.endDate, today)
            add(itemViewContextString(R.string.task_overdue_days, days))
        }
        if (task.recurrence == com.wootodo.domain.TaskRecurrence.DAILY) {
            add(itemViewContextString(R.string.repeat_daily))
        }
        task.reminderTime?.let {
            add(itemViewContextString(R.string.task_reminder_time_short, it.toString()))
        }
    }.joinToString(" · ")

    private fun itemViewContextString(@androidx.annotation.StringRes id: Int): String =
        context.getString(id)

    private fun itemViewContextString(@androidx.annotation.StringRes id: Int, vararg args: Any): String =
        context.getString(id, *args)

    private companion object {
        const val VIEW_TYPE_HEADER = 0
        const val VIEW_TYPE_TASK = 1
        val dateFormatter: DateTimeFormatter =
            DateTimeFormatter.ofPattern("M月d日", Locale.SIMPLIFIED_CHINESE)
    }
}

internal sealed interface TaskDeadlineIndicator {
    val date: LocalDate

    data class DateOnly(override val date: LocalDate) : TaskDeadlineIndicator
    data class DueToday(override val date: LocalDate) : TaskDeadlineIndicator
    data class Overdue(override val date: LocalDate, val days: Long) : TaskDeadlineIndicator
}

internal fun taskDeadlineIndicator(
    status: TaskStatus,
    deadlineDate: LocalDate?,
    today: LocalDate,
): TaskDeadlineIndicator? {
    deadlineDate ?: return null
    if (status != TaskStatus.PENDING) return TaskDeadlineIndicator.DateOnly(deadlineDate)
    return when {
        deadlineDate.isBefore(today) -> TaskDeadlineIndicator.Overdue(
            deadlineDate,
            ChronoUnit.DAYS.between(deadlineDate, today),
        )
        deadlineDate == today -> TaskDeadlineIndicator.DueToday(deadlineDate)
        else -> TaskDeadlineIndicator.DateOnly(deadlineDate)
    }
}
