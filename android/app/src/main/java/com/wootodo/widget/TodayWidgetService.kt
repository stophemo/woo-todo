package com.wootodo.widget

import android.content.Context
import android.content.Intent
import android.util.Log
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
        tasks = try {
            runBlocking(Dispatchers.IO) {
                val application = context.applicationContext as WooTodoApplication
                if (application.taskRepository.autoPassExpired() > 0) {
                    application.notifyLocalMutation()
                }
                application.taskRepository.tasksForToday().take(MAX_VISIBLE_TASKS)
            }
        } catch (error: Exception) {
            Log.e(TAG, "读取今日任务失败", error)
            emptyList()
        }
    }

    override fun onDestroy() {
        tasks = emptyList()
    }

    override fun getCount(): Int = tasks.size

    override fun getViewAt(position: Int): RemoteViews? =
        tasks.getOrNull(position)?.let { TodayWidgetRowViews.create(context, it) }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = tasks.getOrNull(position)?.id?.hashCode()?.toLong() ?: 0

    override fun hasStableIds(): Boolean = true

    companion object {
        private const val TAG = "TodayWidgetFactory"
        private const val MAX_VISIBLE_TASKS = 30
    }
}

internal object TodayWidgetRowViews {
    fun create(context: Context, task: Task): RemoteViews =
        RemoteViews(context.packageName, R.layout.item_widget_task).apply {
            val completed = task.status == TaskStatus.COMPLETED
            setTextViewText(R.id.widget_task_title, task.title)
            setTextViewText(R.id.widget_task_line, context.getString(task.questLine.labelRes()))
            setCompoundButtonChecked(R.id.widget_task_check, completed)
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

    private fun itemIntent(command: String, taskId: String): Intent = Intent().apply {
        putExtra(TodayWidgetProvider.EXTRA_COMMAND, command)
        putExtra(TodayWidgetProvider.EXTRA_TASK_ID, taskId)
    }
}
