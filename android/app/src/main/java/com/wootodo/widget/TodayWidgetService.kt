package com.wootodo.widget

import android.content.Context
import android.content.Intent
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StrikethroughSpan
import android.util.Log
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.ui.TaskListPresenter
import com.wootodo.ui.TaskListSection
import com.wootodo.ui.TaskSectionKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking

class TodayWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        TodayWidgetFactory(applicationContext)
}

private class TodayWidgetFactory(
    private val context: Context,
) : RemoteViewsService.RemoteViewsFactory {
    private var items: List<TodayWidgetListItem> = emptyList()

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        // Widget 工厂线程只做只读读取；结算过期任务与触发同步属于应用生命周期职责。
        items = try {
            runBlocking(Dispatchers.IO) {
                val application = context.applicationContext as WooTodoApplication
                val tasks = application.taskRepository.allTasks()
                val categories = application.taskRepository.allCategories()
                val sections = TaskListPresenter.sections(
                    tasks,
                    categories,
                    TaskDateRules.today(),
                )
                TodayWidgetItems.from(sections, MAX_VISIBLE_TASKS)
            }
        } catch (error: Exception) {
            Log.e(TAG, "读取今日任务失败", error)
            emptyList()
        }
    }

    override fun onDestroy() {
        items = emptyList()
    }

    override fun getCount(): Int = items.size

    override fun getViewAt(position: Int): RemoteViews? = when (val item = items.getOrNull(position)) {
        is TodayWidgetListItem.Header -> TodayWidgetHeaderViews.create(context, item.kind)
        is TodayWidgetListItem.Row -> TodayWidgetRowViews.create(context, item.task)
        null -> null
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = TODAY_WIDGET_VIEW_TYPE_COUNT

    override fun getItemId(position: Int): Long = items.getOrNull(position)?.stableId ?: 0

    override fun hasStableIds(): Boolean = true

    companion object {
        private const val TAG = "TodayWidgetFactory"
        private const val MAX_VISIBLE_TASKS = 30
    }
}

internal const val TODAY_WIDGET_VIEW_TYPE_HEADER = 0
internal const val TODAY_WIDGET_VIEW_TYPE_TASK = 1
private const val TODAY_WIDGET_VIEW_TYPE_COUNT = 2

internal sealed interface TodayWidgetListItem {
    val stableId: Long
    val viewType: Int

    data class Header(val kind: TaskSectionKind) : TodayWidgetListItem {
        override val stableId: Long =
            Long.MIN_VALUE + (kind.name.hashCode().toLong() and 0x7FFF_FFFFL)
        override val viewType: Int = TODAY_WIDGET_VIEW_TYPE_HEADER
    }

    data class Row(val task: Task) : TodayWidgetListItem {
        override val stableId: Long = stableTaskId(task.id)
        override val viewType: Int = TODAY_WIDGET_VIEW_TYPE_TASK
    }
}

internal object TodayWidgetItems {
    fun from(
        sections: List<TaskListSection>,
        maxRows: Int = Int.MAX_VALUE,
    ): List<TodayWidgetListItem> = buildList {
        var rows = 0
        for (section in sections) {
            if (rows >= maxRows) break
            val visible = section.tasks.take(maxRows - rows)
            if (visible.isEmpty()) continue
            add(TodayWidgetListItem.Header(section.kind))
            visible.forEach {
                add(TodayWidgetListItem.Row(it))
                rows += 1
            }
        }
    }
}

private fun stableTaskId(taskId: String): Long {
    var hash = -3750763034362895579L
    taskId.forEach { character ->
        hash = hash xor character.code.toLong()
        hash *= 1099511628211L
    }
    return hash and Long.MAX_VALUE
}

internal object TodayWidgetHeaderViews {
    fun create(context: Context, kind: TaskSectionKind): RemoteViews =
        RemoteViews(context.packageName, R.layout.item_widget_header).apply {
            setTextViewText(R.id.widget_group_title, context.getString(kind.titleRes))
            setImageViewResource(R.id.widget_group_marker, R.drawable.quest_marker)
        }
}

internal object TodayWidgetRowViews {
    fun create(context: Context, task: Task): RemoteViews =
        RemoteViews(context.packageName, R.layout.item_widget_task).apply {
            val completed = task.status == TaskStatus.COMPLETED
            val title = SpannableString(task.title).apply {
                if (completed) {
                    setSpan(StrikethroughSpan(), 0, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }
            setTextViewText(R.id.widget_task_title, title)
            setCompoundButtonChecked(R.id.widget_task_check, completed)
            setContentDescription(
                R.id.widget_task_check,
                context.getString(
                    if (completed) R.string.reopen_completed else R.string.mark_completed,
                ),
            )
            if (task.status != TaskStatus.PASS) {
                setOnClickFillInIntent(
                    R.id.widget_task_check,
                    itemIntent(TodayWidgetProvider.COMMAND_TOGGLE_COMPLETION, task.id),
                )
            }
            if (!completed) {
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
