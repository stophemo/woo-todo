package com.wootodo.widget

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.widget.CheckBox
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.wootodo.R
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
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
