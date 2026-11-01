package com.wootodo.ui

import android.content.Context
import android.view.View
import android.widget.CheckBox
import android.widget.FrameLayout
import androidx.appcompat.view.ContextThemeWrapper
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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TaskRowContractInstrumentedTest {
    // 行布局引用了应用主题里的 ?attr/selectableItemBackground，用默认平台主题
    // 会在 inflation 阶段抛 UnsupportedOperationException，因此这里显式套用应用主题。
    private val context: Context
        get() = ContextThemeWrapper(
            ApplicationProvider.getApplicationContext(),
            R.style.Theme_WooTodo,
        )

    @Test
    fun `每一行都提供更多操作入口而不是常驻Pass按钮`() {
        val row = bindRow(task(status = TaskStatus.PENDING))

        assertNotNull(row.findViewById<View>(R.id.task_actions))
        assertNotNull(row.findViewById<View>(R.id.task_check))
    }

    @Test
    fun `Pass任务隐藏复选框避免误认为可勾选`() {
        val row = bindRow(task(status = TaskStatus.PASS))

        assertEquals(View.INVISIBLE, row.findViewById<CheckBox>(R.id.task_check).visibility)
    }

    @Test
    fun `任意状态的行都能打开详情`() {
        TaskStatus.entries.forEach { status ->
            var opened: String? = null
            val row = bindRow(task(status = status), onEdit = { opened = it.id })

            row.findViewById<View>(R.id.task_row).performClick()

            assertEquals("点击 $status 行应打开详情", "task-$status", opened)
        }
    }

    @Test
    fun `点击复选框按状态分发完成或撤销`() {
        val pending = mutableListOf<TaskStatus>()
        bindRow(task(status = TaskStatus.PENDING), onCheck = { pending += it.status })
            .findViewById<CheckBox>(R.id.task_check)
            .performClick()
        assertEquals(listOf(TaskStatus.PENDING), pending)

        val completed = mutableListOf<TaskStatus>()
        bindRow(task(status = TaskStatus.COMPLETED), onCheck = { completed += it.status })
            .findViewById<CheckBox>(R.id.task_check)
            .performClick()
        assertEquals(listOf(TaskStatus.COMPLETED), completed)

        val passed = mutableListOf<TaskStatus>()
        bindRow(task(status = TaskStatus.PASS), onCheck = { passed += it.status })
            .findViewById<CheckBox>(R.id.task_check)
            .performClick()
        assertTrue(passed.isEmpty())
    }

    private fun bindRow(
        task: Task,
        onCheck: (Task) -> Unit = {},
        onEdit: (Task) -> Unit = {},
    ): View {
        val adapter = TaskAdapter(
            onCheck = onCheck,
            onMenu = { _, _ -> },
            onEdit = onEdit,
        )
        adapter.submitTasks(listOf(task))
        val parent = FrameLayout(context)
        val rowIndex = (0 until adapter.itemCount).first {
            adapter.getItemViewType(it) == 1
        }
        val holder = adapter.onCreateViewHolder(parent, 1)
        adapter.onBindViewHolder(holder, rowIndex)
        return holder.itemView
    }

    private fun task(status: TaskStatus): Task = Task(
        id = "task-$status",
        seriesId = "series-$status",
        title = "写周报",
        timeType = TaskTimeType.DAY,
        targetDate = LocalDate.of(2026, 7, 15),
        questLine = QuestLine.MAIN,
        status = status,
        recurrence = Recurrence.ONCE,
        sortOrder = 0,
        createdAt = 0,
        updatedAt = 0,
        settledAt = null,
    )
}
