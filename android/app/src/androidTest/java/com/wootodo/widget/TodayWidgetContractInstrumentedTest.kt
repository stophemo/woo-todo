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
import com.wootodo.domain.Task
import com.wootodo.domain.TaskStatus
import com.wootodo.ui.TaskSectionKind
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
    fun `小组件按标准格数公式声明占位避免图标落进组件区域`() {
        val parser = context.resources.getXml(R.xml.today_widget_info)
        val values = mutableMapOf<String, String>()
        while (parser.next() != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
            if (parser.eventType != org.xmlpull.v1.XmlPullParser.START_TAG) continue
            repeat(parser.attributeCount) { index ->
                values[parser.getAttributeName(index)] = parser.getAttributeValue(index)
            }
        }
        // 桌面用「70 × 格数 − 30」反推占位：4 列 = 250dp，2 行 = 110dp。
        assertEquals(250f, values["minWidth"].dimensionValue(), 0.01f)
        assertEquals(110f, values["minHeight"].dimensionValue(), 0.01f)
        assertEquals(250f, values["minResizeWidth"].dimensionValue(), 0.01f)
        assertEquals(110f, values["minResizeHeight"].dimensionValue(), 0.01f)
        assertEquals("4", values["targetCellWidth"])
        assertEquals("2", values["targetCellHeight"])
    }

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
    fun `日期分区标题可由RemoteViews安全应用`() {
        TaskSectionKind.entries.forEach { kind ->
            val view = TodayWidgetHeaderViews.create(context, kind)
                .apply(context, FrameLayout(context))

            assertEquals(
                context.getString(kind.titleRes),
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
        categoryId = "main",
        startDate = LocalDate.of(2026, 7, 22),
        endDate = LocalDate.of(2026, 7, 22),
        status = status,
        sortOrder = 0,
        createdAt = 1_000,
        updatedAt = 1_000,
        settledAt = if (status == TaskStatus.PENDING) null else 1_000,
    )
}

private fun String?.dimensionValue(): Float =
    requireNotNull(this) { "缺少尺寸属性" }
        .removeSuffix("dip")
        .removeSuffix("dp")
        .toFloat()
