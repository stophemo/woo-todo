package com.wootodo.ui

import android.graphics.Paint
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.TextView
import androidx.core.view.isVisible
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.RecyclerView
import com.wootodo.R
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus

private sealed interface TaskListItem {
    data class Header(val questLine: QuestLine) : TaskListItem
    data class Row(val task: Task) : TaskListItem
}

internal class TaskAdapter(
    private val onComplete: (Task) -> Unit,
    private val onPass: (Task) -> Unit,
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

        fun bind(line: QuestLine) {
            headerTitle.setText(line.labelRes())
        }
    }

    private inner class TaskViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        private val taskRow: View = itemView.findViewById(R.id.task_row)
        private val taskCheck: CheckBox = itemView.findViewById(R.id.task_check)
        private val taskTitle: TextView = itemView.findViewById(R.id.task_title)
        private val taskStatus: TextView = itemView.findViewById(R.id.task_status)
        private val passButton: Button = itemView.findViewById(R.id.pass_button)

        fun bind(task: Task) {
            val pending = task.status == TaskStatus.PENDING
            taskTitle.text = task.title
            taskStatus.setText(task.status.labelRes())
            taskCheck.setOnCheckedChangeListener(null)
            taskCheck.isChecked = task.status == TaskStatus.COMPLETED
            taskCheck.isEnabled = pending
            taskCheck.setOnClickListener {
                if (pending) onComplete(task)
            }
            passButton.isVisible = pending
            passButton.setOnClickListener { onPass(task) }
            taskRow.alpha = if (pending) 1f else 0.55f
            taskTitle.paintFlags = if (task.status == TaskStatus.COMPLETED) {
                taskTitle.paintFlags or Paint.STRIKE_THRU_TEXT_FLAG
            } else {
                taskTitle.paintFlags and Paint.STRIKE_THRU_TEXT_FLAG.inv()
            }
            taskRow.setOnClickListener {
                if (pending) onEdit(task)
            }
        }
    }

    private companion object {
        const val VIEW_TYPE_HEADER = 0
        const val VIEW_TYPE_TASK = 1
    }
}
