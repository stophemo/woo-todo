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
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate
import java.time.temporal.ChronoUnit

private sealed interface TaskListItem {
    data class Header(val questLine: QuestLine) : TaskListItem
    data class Row(val task: Task) : TaskListItem
}

internal class TaskAdapter(
    private val onCheck: (Task) -> Unit,
    private val onMenu: (Task, View) -> Unit,
    private val onEdit: (Task) -> Unit,
) : RecyclerView.Adapter<RecyclerView.ViewHolder>() {
    private val items = mutableListOf<TaskListItem>()

    fun submitTasks(tasks: List<Task>) {
        val updatedItems = buildList {
            QuestLine.entries.forEach { line ->
                val group = tasks.filter { it.questLine == line }
                if (group.isNotEmpty()) {
                    add(TaskListItem.Header(line))
                    group.forEach { add(TaskListItem.Row(it)) }
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
                        old.questLine == new.questLine
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

    fun questLineAt(position: Int): QuestLine? =
        (items.getOrNull(position) as? TaskListItem.Row)?.task
            ?.takeIf { it.status == TaskStatus.PENDING }
            ?.questLine

    fun taskAt(position: Int): Task? = (items.getOrNull(position) as? TaskListItem.Row)?.task

    fun moveItem(fromPosition: Int, toPosition: Int): Boolean {
        val fromLine = questLineAt(fromPosition) ?: return false
        val toLine = questLineAt(toPosition) ?: return false
        if (fromLine != toLine) return false
        val moved = items.removeAt(fromPosition)
        items.add(toPosition, moved)
        notifyItemMoved(fromPosition, toPosition)
        return true
    }

    fun taskIdsForLine(line: QuestLine): List<String> = items.mapNotNull { item ->
        (item as? TaskListItem.Row)?.task
            ?.takeIf { it.questLine == line && it.status == TaskStatus.PENDING }
            ?.id
    }

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
            is TaskListItem.Header -> (holder as HeaderViewHolder).bind(item.questLine)
            is TaskListItem.Row -> (holder as TaskViewHolder).bind(item.task)
        }
    }

    private class HeaderViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val headerTitle: TextView = itemView.findViewById(R.id.header_title)
        private val headerMarker: View = itemView.findViewById(R.id.header_marker)

        fun bind(line: QuestLine) {
            headerTitle.setText(line.labelRes())
            val color = when (line) {
                QuestLine.MAIN -> R.color.primary
                QuestLine.SIDE -> R.color.green
                QuestLine.EXTRA -> R.color.orange
            }
            headerMarker.background.mutate().setTint(ContextCompat.getColor(itemView.context, color))
        }
    }

    private inner class TaskViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val taskRow: View = itemView.findViewById(R.id.task_row)
        private val taskCheck: CheckBox = itemView.findViewById(R.id.task_check)
        private val taskTitle: TextView = itemView.findViewById(R.id.task_title)
        private val taskStatus: TextView = itemView.findViewById(R.id.task_status)
        private val taskActions: View = itemView.findViewById(R.id.task_actions)

        fun bind(task: Task) {
            val pending = task.status == TaskStatus.PENDING
            taskTitle.text = task.title
            val statusLabel = itemView.context.getString(task.status.labelRes())
            val deadline = taskDeadlineIndicator(task.status, task.deadlineDate, TaskDateRules.today())
            val deadlineLabel = when (deadline) {
                is TaskDeadlineIndicator.DateOnly -> itemView.context.getString(
                    R.string.task_deadline_date,
                    deadline.date,
                )
                is TaskDeadlineIndicator.DueToday -> itemView.context.getString(
                    R.string.task_deadline_due_today,
                )
                is TaskDeadlineIndicator.Overdue -> itemView.context.getString(
                    R.string.task_deadline_overdue,
                    deadline.days,
                    deadline.date,
                )
                null -> null
            }
            // 状态行同时透露重复规则，手机上不必进编辑页就能判断会不会自动滚动。
            taskStatus.text = buildList {
                add(statusLabel)
                if (task.recurrence != Recurrence.ONCE && task.timeType != TaskTimeType.LEISURE) {
                    add(itemView.context.getString(task.recurrence.labelRes()))
                }
                deadlineLabel?.let(::add)
            }.joinToString(" · ")
            taskStatus.setTextColor(
                ContextCompat.getColor(
                    itemView.context,
                    if (deadline is TaskDeadlineIndicator.Overdue) R.color.orange else R.color.muted,
                ),
            )
            taskCheck.setOnCheckedChangeListener(null)
            taskCheck.isChecked = task.status == TaskStatus.COMPLETED
            taskCheck.isEnabled = task.status != TaskStatus.PASS
            // Pass 不可逆，空复选框会让人误以为还能点，隐藏后整行交给详情页。
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
            // 任何状态都能打开详情，避免已完成 / Pass 任务在手机上成为死路。
            taskRow.setOnClickListener { onEdit(task) }
        }
    }

    private companion object {
        const val VIEW_TYPE_HEADER = 0
        const val VIEW_TYPE_TASK = 1
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
