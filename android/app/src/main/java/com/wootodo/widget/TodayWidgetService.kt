package com.wootodo.widget

import android.content.Context
import android.content.Intent
import android.graphics.Paint
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus
import com.wootodo.ui.labelRes
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking

class TodayWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        TodayWidgetFactory(applicationContext)
}

private class TodayWidgetFactory(
    private val context: Context,
) : RemoteViewsService.RemoteViewsFactory {
    private var tasks: List<Task> = emptyList()

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        tasks = runCatching {
            runBlocking(Dispatchers.IO) {
                val application = context.applicationContext as WooTodoApplication
                if (application.taskRepository.autoPassExpired() > 0) {
                    application.notifyLocalMutation()
                }
                application.taskRepository.tasksForToday().take(MAX_VISIBLE_TASKS)
            }
        }.getOrDefault(emptyList())
    }

    override fun onDestroy() {
        tasks = emptyList()
    }

    override fun getCount(): Int = tasks.size

    override fun getViewAt(position: Int): RemoteViews? = tasks.getOrNull(position)?.let { task ->
        RemoteViews(context.packageName, R.layout.item_widget_task).apply {
            val completed = task.status == TaskStatus.COMPLETED
            setTextViewText(R.id.widget_task_title, task.title)
            setTextViewText(R.id.widget_task_line, context.getString(task.questLine.labelRes()))
            setBoolean(R.id.widget_task_check, "setChecked", completed)
            setBoolean(R.id.widget_task_check, "setEnabled", !completed)
            setInt(
                R.id.widget_task_title,
                "setPaintFlags",
                Paint.ANTI_ALIAS_FLAG or
                    (if (completed) Paint.STRIKE_THRU_TEXT_FLAG else 0),
            )
            if (!completed) {
                setOnClickFillInIntent(
                    R.id.widget_task_check,
                    itemIntent(TodayWidgetProvider.COMMAND_COMPLETE, task.id),
                )
                setOnClickFillInIntent(
                    R.id.widget_task_row,
                    itemIntent(TodayWidgetProvider.COMMAND_EDIT, task.id),
                )
            }
        }
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = tasks.getOrNull(position)?.id?.hashCode()?.toLong() ?: 0

    override fun hasStableIds(): Boolean = true

    private fun itemIntent(command: String, taskId: String): Intent = Intent().apply {
        putExtra(TodayWidgetProvider.EXTRA_COMMAND, command)
        putExtra(TodayWidgetProvider.EXTRA_TASK_ID, taskId)
    }

    companion object {
        private const val MAX_VISIBLE_TASKS = 30
    }
}
