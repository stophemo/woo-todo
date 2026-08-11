package com.wootodo.ui

import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.domain.QuestLine
import com.wootodo.domain.StatisticsEngine
import com.wootodo.domain.StatisticsSnapshot
import com.wootodo.domain.StatusCounts
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskTimeType
import com.wootodo.domain.TrendBucket
import com.wootodo.data.TaskRepository
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.launch

class InsightsActivity : AppCompatActivity() {
    private lateinit var endedRate: TextView
    private lateinit var mainRate: TextView
    private lateinit var dailyTrend: TextView
    private lateinit var weeklyTrend: TextView
    private lateinit var monthlyTrend: TextView
    private lateinit var timeTypeCounts: TextView
    private lateinit var questLineCounts: TextView
    private lateinit var recentHistoryList: LinearLayout
    private lateinit var historySelectButton: Button
    private lateinit var historyDeleteSelectedButton: Button
    private lateinit var historyClearAllButton: Button
    private lateinit var repository: TaskRepository
    private var historyTasks: List<Task> = emptyList()
    private val selectedHistoryIds = linkedSetOf<String>()
    private var selectingHistory = false
    private var clearingHistory = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_insights)
        applySystemBarInsets(findViewById(R.id.insights_root))
        endedRate = findViewById(R.id.ended_rate)
        mainRate = findViewById(R.id.main_rate)
        dailyTrend = findViewById(R.id.daily_trend)
        weeklyTrend = findViewById(R.id.weekly_trend)
        monthlyTrend = findViewById(R.id.monthly_trend)
        timeTypeCounts = findViewById(R.id.time_type_counts)
        questLineCounts = findViewById(R.id.quest_line_counts)
        recentHistoryList = findViewById(R.id.recent_history_list)
        historySelectButton = findViewById(R.id.history_select_button)
        historyDeleteSelectedButton = findViewById(R.id.history_delete_selected_button)
        historyClearAllButton = findViewById(R.id.history_clear_all_button)
        historySelectButton.setOnClickListener { toggleHistorySelection() }
        historyDeleteSelectedButton.setOnClickListener {
            confirmClearHistory(selectedHistoryIds.toSet())
        }
        historyClearAllButton.setOnClickListener { confirmClearHistory(ids = null) }
        listOf(
            endedRate,
            mainRate,
            dailyTrend,
            weeklyTrend,
            monthlyTrend,
            timeTypeCounts,
            questLineCounts,
        ).forEach { it.enableReadOnlyTextSelection() }

        repository = (application as WooTodoApplication).taskRepository
        lifecycleScope.launch {
            if (repository.autoPassExpired() > 0) {
                (application as WooTodoApplication).notifyLocalMutation()
            }
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                repository.observeAllTasks().collect { tasks ->
                    render(
                        StatisticsEngine.calculate(
                            tasks,
                            TaskDateRules.today(),
                            recentHistoryLimit = Int.MAX_VALUE,
                        ),
                    )
                }
            }
        }
    }

    private fun render(snapshot: StatisticsSnapshot) {
        endedRate.text = getString(
            R.string.ended_fulfillment,
            formatRate(snapshot.endedPeriodFulfillmentRate),
        )
        mainRate.text = getString(
            R.string.main_fulfillment,
            formatRate(snapshot.mainQuestFulfillmentRate),
        )
        dailyTrend.text = formatTrend(snapshot.dailyTrend, TaskTimeType.DAY)
        weeklyTrend.text = formatTrend(snapshot.weeklyTrend, TaskTimeType.WEEK)
        monthlyTrend.text = formatTrend(snapshot.monthlyTrend, TaskTimeType.MONTH)
        timeTypeCounts.text = TaskTimeType.entries.joinToString("\n") { type ->
            formatCounts(getString(type.labelRes()), snapshot.byTimeType.getValue(type))
        }
        questLineCounts.text = QuestLine.entries.joinToString("\n") { line ->
            formatCounts(getString(line.labelRes()), snapshot.byQuestLine.getValue(line))
        }
        historyTasks = snapshot.recentHistory
        val availableIds = historyTasks.mapTo(HashSet(), Task::id)
        selectedHistoryIds.retainAll(availableIds)
        if (historyTasks.isEmpty()) selectingHistory = false
        renderHistory()
    }

    private fun renderHistory() {
        recentHistoryList.removeAllViews()
        if (historyTasks.isEmpty()) {
            recentHistoryList.addView(historyText(getString(R.string.no_history)))
        } else {
            historyTasks.forEach { task ->
                recentHistoryList.addView(historyRow(task))
            }
        }
        historySelectButton.visibility = if (historyTasks.isEmpty()) View.GONE else View.VISIBLE
        historySelectButton.setText(
            if (selectingHistory) R.string.exit_selection else R.string.select_multiple,
        )
        historyDeleteSelectedButton.visibility =
            if (selectingHistory) View.VISIBLE else View.GONE
        historyDeleteSelectedButton.text = getString(
            R.string.clear_selected_count,
            selectedHistoryIds.size,
        )
        historyDeleteSelectedButton.isEnabled = selectedHistoryIds.isNotEmpty() && !clearingHistory
        historyClearAllButton.visibility =
            if (historyTasks.isEmpty() || selectingHistory) View.GONE else View.VISIBLE
        historySelectButton.isEnabled = !clearingHistory
        historyClearAllButton.isEnabled = !clearingHistory
    }

    private fun historyRow(task: Task): View = if (selectingHistory) {
        CheckBox(this).apply {
            text = formatHistory(task)
            textSize = 16f
            setPadding(0, 14, 0, 14)
            isChecked = task.id in selectedHistoryIds
            setOnCheckedChangeListener { _, checked ->
                if (checked) selectedHistoryIds.add(task.id) else selectedHistoryIds.remove(task.id)
                historyDeleteSelectedButton.text = getString(
                    R.string.clear_selected_count,
                    selectedHistoryIds.size,
                )
                historyDeleteSelectedButton.isEnabled =
                    selectedHistoryIds.isNotEmpty() && !clearingHistory
            }
        }
    } else {
        historyText(formatHistory(task))
    }

    private fun toggleHistorySelection() {
        selectingHistory = !selectingHistory
        selectedHistoryIds.clear()
        renderHistory()
    }

    private fun confirmClearHistory(ids: Set<String>?) {
        val count = ids?.count { selected -> historyTasks.any { it.id == selected } }
            ?: historyTasks.size
        if (count == 0 || clearingHistory) return
        AlertDialog.Builder(this)
            .setTitle(R.string.clear_history_title)
            .setMessage(getString(R.string.clear_history_message, count))
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.delete) { _, _ -> clearHistory(ids) }
            .show()
    }

    private fun clearHistory(ids: Set<String>?) {
        clearingHistory = true
        renderHistory()
        lifecycleScope.launch {
            runCatching { repository.clearHistory(ids) }
                .onSuccess { count ->
                    if (count > 0) {
                        selectedHistoryIds.clear()
                        selectingHistory = false
                        (application as WooTodoApplication).notifyLocalMutation()
                        Toast.makeText(
                            this@InsightsActivity,
                            getString(R.string.history_cleared, count),
                            Toast.LENGTH_SHORT,
                        ).show()
                    }
                }
                .onFailure {
                    Toast.makeText(
                        this@InsightsActivity,
                        R.string.clear_history_failed,
                        Toast.LENGTH_SHORT,
                    ).show()
                }
            clearingHistory = false
            renderHistory()
        }
    }

    private fun formatRate(rate: Double?): String = rate?.let {
        String.format(Locale.SIMPLIFIED_CHINESE, "%.0f%%", it * 100)
    } ?: getString(R.string.no_rate)

    private fun formatCounts(label: String, counts: StatusCounts): String =
        getString(
            R.string.counts_format,
            label,
            counts.completed,
            counts.pass,
            counts.pending,
        )

    private fun formatTrend(buckets: List<TrendBucket>, timeType: TaskTimeType): String =
        buckets.joinToString("\n") { bucket ->
            val period = when (timeType) {
                TaskTimeType.DAY -> bucket.startDate.format(dayFormatter)
                TaskTimeType.WEEK -> getString(
                    R.string.trend_week_period,
                    bucket.startDate.format(dayFormatter),
                )
                TaskTimeType.MONTH -> bucket.startDate.format(monthFormatter)
                TaskTimeType.LEISURE -> ""
            }
            val rate = if (bucket.isEnded) {
                formatRate(bucket.fulfillmentRate)
            } else {
                getString(R.string.trend_in_progress)
            }
            getString(
                R.string.trend_item_format,
                period,
                rate,
                bucket.completed,
                bucket.pass,
                bucket.sampleCount,
            )
        }

    private fun formatHistory(task: Task): String = getString(
        R.string.history_item_format,
        task.title,
        getString(task.timeType.labelRes()),
        getString(task.questLine.labelRes()),
        getString(task.status.labelRes()),
    )

    private fun historyText(value: String): TextView = TextView(this).apply {
        text = value
        textSize = 16f
        setPadding(0, 14, 0, 14)
        enableReadOnlyTextSelection()
    }

    private companion object {
        val dayFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern(
            "M月d日",
            Locale.SIMPLIFIED_CHINESE,
        )
        val monthFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern(
            "yyyy年M月",
            Locale.SIMPLIFIED_CHINESE,
        )
    }
}
