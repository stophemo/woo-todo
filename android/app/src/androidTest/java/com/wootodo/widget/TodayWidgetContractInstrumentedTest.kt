package com.wootodo.widget

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.graphics.Color
import android.text.Spanned
import android.text.style.StrikethroughSpan
import android.view.Gravity
import android.view.LayoutInflater
import android.widget.CheckBox
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.RemoteViews
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.R
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import com.wootodo.ui.labelRes
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TodayWidgetContractInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    @Test
    fun `小组件集合服务允许桌面宿主通过系统权限绑定`() {
        val serviceInfo = context.packageManager.getServiceInfo(
            ComponentName(context, TodayWidgetService::class.java),
            0,
        )

        assertTrue(serviceInfo.exported)
        assertEquals(Manifest.permission.BIND_REMOTEVIEWS, serviceInfo.permission)
    }

    @Test
    fun `待办和已完成任务行可由RemoteViews安全应用`() {
        val pending = task("pending", TaskStatus.PENDING)
        val completed = task("completed", TaskStatus.COMPLETED)

        val pendingView = TodayWidgetRowViews.create(context, pending)
            .apply(context, FrameLayout(context))
        val completedView = TodayWidgetRowViews.create(context, completed)
            .apply(context, FrameLayout(context))

        assertEquals("pending", pendingView.findViewById<TextView>(R.id.widget_task_title).text.toString())
        assertFalse(pendingView.findViewById<CheckBox>(R.id.widget_task_check).isChecked)
        assertEquals("completed", completedView.findViewById<TextView>(R.id.widget_task_title).text.toString())
        assertTrue(completedView.findViewById<CheckBox>(R.id.widget_task_check).isChecked)
        assertTrue(
            completedView.findViewById<TextView>(R.id.widget_task_title).text
                .let { it as Spanned }
                .getSpans(0, "completed".length, StrikethroughSpan::class.java)
                .isNotEmpty(),
        )
    }

    @Test
    fun `三种任务线标题可由RemoteViews安全应用`() {
        QuestLine.entries.forEach { questLine ->
            val view = TodayWidgetHeaderViews.create(context, questLine)
                .apply(context, FrameLayout(context))

            assertEquals(
                context.getString(questLine.labelRes()),
                view.findViewById<TextView>(R.id.widget_group_title).text.toString(),
            )
        }
    }

    @Test
    fun `小组件背景不透明度可由RemoteViews安全应用`() {
        val remoteViews = RemoteViews(context.packageName, R.layout.widget_today)
        TodayWidgetAppearance.applyBackground(context, remoteViews, 40)

        val view = remoteViews.apply(context, LinearLayout(context))
        val tint = view.findViewById<LinearLayout>(R.id.widget_root).backgroundTintList

        assertEquals(TodayWidgetPreferences.backgroundAlpha(40), Color.alpha(tint?.defaultColor ?: 0))
    }

    @Test
    fun `添加入口固定在内容区后的右下角`() {
        val view = LayoutInflater.from(context)
            .inflate(R.layout.widget_today, FrameLayout(context), false)
        val root = view.findViewById<LinearLayout>(R.id.widget_root)
        val header = view.findViewById<LinearLayout>(R.id.widget_header)
        val list = view.findViewById<ListView>(R.id.widget_list)
        val add = view.findViewById<TextView>(R.id.widget_add)
        val layoutParams = add.layoutParams as LinearLayout.LayoutParams

        assertEquals(root, add.parent)
        assertFalse(header.findViewById<TextView>(R.id.widget_add) != null)
        assertTrue(root.indexOfChild(add) > root.indexOfChild(list))
        assertEquals(Gravity.END, layoutParams.gravity)
    }

    private fun task(id: String, status: TaskStatus) = Task(
        id = id,
        seriesId = "series-$id",
        title = id,
        timeType = TaskTimeType.DAY,
        targetDate = LocalDate.of(2026, 7, 22),
        questLine = QuestLine.MAIN,
        status = status,
        recurrence = Recurrence.ONCE,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = if (status == TaskStatus.PENDING) null else 1_000,
    )
}
