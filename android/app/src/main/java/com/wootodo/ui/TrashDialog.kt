package com.wootodo.ui

import android.app.AlertDialog
import android.view.LayoutInflater
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.wootodo.R
import com.wootodo.data.TaskRepository
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TrashedTask
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 本机“最近删除”列表；恢复会把任务以新任务重新入队，其他设备会像收到新增任务一样同步。 */
object TrashDialog {
    private val protocolZone = ZoneId.of("Asia/Shanghai")
    private val dateFormatter = DateTimeFormatter.ofPattern("M月d日")
    private val deletedAtFormatter = DateTimeFormatter.ofPattern("M月d日 HH:mm")

    fun show(
        activity: AppCompatActivity,
        repository: TaskRepository,
        onRestored: () -> Unit,
    ) {
        val content = LayoutInflater.from(activity).inflate(R.layout.dialog_trash, null)
        val list = content.findViewById<LinearLayout>(R.id.trash_list)
        val empty = content.findViewById<TextView>(R.id.trash_empty)
        val clear = content.findViewById<MaterialButton>(R.id.trash_clear)
        val dialog = AlertDialog.Builder(activity)
            .setTitle(R.string.trash_title)
            .setView(content)
            .setNegativeButton(R.string.done, null)
            .create()

        var categories = emptyList<TaskCategory>()
        var items = emptyList<TrashedTask>()

        fun categoryName(id: String): String =
            categories.firstOrNull { it.id == id }?.name
                ?: activity.getString(R.string.trash_category_fallback)

        lateinit var render: () -> Unit
        lateinit var reload: () -> Unit

        render = {
            list.removeAllViews()
            empty.isVisible = items.isEmpty()
            clear.isVisible = items.isNotEmpty()

            val inflater = LayoutInflater.from(activity)
            items.forEach { item ->
                val row = inflater.inflate(R.layout.item_trash, list, false)
                row.findViewById<TextView>(R.id.trash_title).text = item.task.title
                row.findViewById<TextView>(R.id.trash_meta).text = listOf(
                    categoryName(item.task.categoryId),
                    dateRangeText(activity, item),
                    activity.getString(
                        R.string.trash_deleted_at,
                        Instant.ofEpochMilli(item.deletedAt)
                            .atZone(protocolZone)
                            .format(deletedAtFormatter),
                    ),
                ).joinToString(" · ")

                val restore = row.findViewById<MaterialButton>(R.id.trash_restore)
                restore.setOnClickListener {
                    restore.isEnabled = false
                    activity.lifecycleScope.launch {
                        val restored = runCatching {
                            repository.restoreTrash(item.task.id)
                        }.getOrDefault(false)
                        if (restored) {
                            items = items.filterNot { it.task.id == item.task.id }
                            onRestored()
                            render()
                        } else {
                            // 快照可能已被其他设备恢复；刷新列表后按钮状态才准确。
                            reload()
                            Toast.makeText(
                                activity,
                                R.string.trash_restore_failed,
                                Toast.LENGTH_SHORT,
                            ).show()
                        }
                    }
                }
                list.addView(row)
            }
        }

        reload = {
            activity.lifecycleScope.launch {
                val loaded = withContext(Dispatchers.IO) {
                    repository.trashTasks() to repository.allCategories()
                }
                items = loaded.first
                categories = loaded.second
                render()
            }
        }

        clear.setOnClickListener {
            AlertDialog.Builder(activity)
                .setTitle(R.string.trash_clear_confirm_title)
                .setMessage(R.string.trash_clear_confirm_message)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.trash_clear) { _, _ ->
                    activity.lifecycleScope.launch {
                        runCatching { repository.removeTrash() }
                            .onSuccess {
                                items = emptyList()
                                render()
                            }
                            .onFailure {
                                reload()
                                Toast.makeText(
                                    activity,
                                    R.string.trash_clear_failed,
                                    Toast.LENGTH_SHORT,
                                ).show()
                            }
                    }
                }
                .show()
        }

        dialog.setOnShowListener { reload() }
        dialog.show()
    }

    private fun dateRangeText(activity: AppCompatActivity, item: TrashedTask): String {
        val start = item.task.startDate
        val end = item.task.endDate
        if (start == null || end == null) {
            return activity.getString(R.string.trash_unscheduled)
        }
        return if (start == end) {
            start.format(dateFormatter)
        } else {
            "${start.format(dateFormatter)}–${end.format(dateFormatter)}"
        }
    }
}
