package com.wootodo.ui

import android.content.res.ColorStateList
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.data.TaskRepository
import com.wootodo.domain.CategoryActivity
import com.wootodo.domain.StatisticsEngine
import com.wootodo.domain.StatisticsSnapshot
import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

class InsightsActivity : AppCompatActivity() {
    private lateinit var statWeekValue: TextView
    private lateinit var statStreakValue: TextView
    private lateinit var statOnTimeValue: TextView
    private lateinit var statPendingValue: TextView
    private lateinit var activitySummary: TextView
    private lateinit var activityChart: ActivityBarChartView
    private lateinit var categoryBreakdown: LinearLayout
    private lateinit var recentHistoryList: LinearLayout
    private lateinit var historySelectButton: Button
    private lateinit var historyDeleteSelectedButton: Button
    private lateinit var historyClearAllButton: Button
    private lateinit var repository: TaskRepository
    private var categories: List<TaskCategory> = TaskCategories.defaults
    private var historyTasks: List<Task> = emptyList()
    private val selectedHistoryIds = linkedSetOf<String>()
    private var selectingHistory = false
    private var clearingHistory = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_insights)
        applySystemBarInsets(findViewById(R.id.insights_root))
        findViewById<View>(R.id.insights_back_button).setOnClickListener { finish() }
        statWeekValue = findViewById(R.id.stat_week_value)
        statStreakValue = findViewById(R.id.stat_streak_value)
        statOnTimeValue = findViewById(R.id.stat_on_time_value)
        statPendingValue = findViewById(R.id.stat_pending_value)
        activitySummary = findViewById(R.id.activity_summary)
        activityChart = findViewById(R.id.activity_chart)
        categoryBreakdown = findViewById(R.id.category_breakdown)
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
            statWeekValue,
            statStreakValue,
            statOnTimeValue,
            statPendingValue,
            activitySummary,
        ).forEach { it.enableReadOnlyTextSelection() }

        repository = (application as WooTodoApplication).taskRepository
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                combine(
                    repository.observeAllTasks(),
                    repository.observeCategories(),
                ) { tasks, categories -> tasks to categories }
                    .collect { (tasks, categories) ->
                        this@InsightsActivity.categories = categories
                        render(
                            StatisticsEngine.calculate(
                                tasks = tasks,
                                referenceDate = TaskDateRules.today(),
                                zoneId = TaskDateRules.zoneId,
                                recentHistoryLimit = RECENT_HISTORY_LIMIT,
                            ),
                        )
                    }
            }
        }
    }

    private fun render(snapshot: StatisticsSnapshot) {
        statWeekValue.text = snapshot.completedThisWeek.toString()
        statStreakValue.text = getString(R.string.stats_streak_value, snapshot.currentStreakDays)
        statOnTimeValue.text = formatRate(snapshot.onTimeRate)
        statPendingValue.text = snapshot.pendingCount.toString()
        val total = snapshot.dailyActivity.sumOf { it.completed }
        activitySummary.text = getString(R.string.stats_activity_summary, total)
        activityChart.setData(snapshot.dailyActivity)
        renderCategories(snapshot.categoryActivity)
        historyTasks = snapshot.recentHistory
        val availableIds = historyTasks.mapTo(HashSet(), Task::id)
        selectedHistoryIds.retainAll(availableIds)
        if (historyTasks.isEmpty()) selectingHistory = false
        renderHistory()
    }

    private fun renderCategories(activity: List<CategoryActivity>) {
        categoryBreakdown.removeAllViews()
        if (activity.isEmpty()) {
            categoryBreakdown.addView(historyText(getString(R.string.stats_no_categories)))
            return
        }
        activity.forEach { item ->
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(0, dp(8), 0, dp(8))
            }
            val header = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
            }
            header.addView(
                TextView(this).apply {
                    text = TaskCategories.resolveName(item.categoryId, categories)
                    textSize = 16f
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                },
            )
            header.addView(
                TextView(this).apply {
                    text = getString(
                        R.string.stats_category_count,
                        item.completed,
                        (item.ratio * 100).roundToInt(),
                    )
                    textSize = 13f
                    setTextColor(getColor(R.color.muted))
                },
            )
            row.addView(header)
            row.addView(
                ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
                    max = 100
                    progress = (item.ratio * 100).roundToInt()
                    progressTintList = ColorStateList.valueOf(getColor(R.color.primary))
                    progressBackgroundTintList = ColorStateList.valueOf(getColor(R.color.line))
                },
            )
            categoryBreakdown.addView(row)
        }
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

    private fun formatHistory(task: Task): String {
        val date = task.settledAt
            ?.let { Instant.ofEpochMilli(it).atZone(TaskDateRules.zoneId).toLocalDate() }
            ?.format(dayFormatter)
            .orEmpty()
        return getString(
            R.string.history_item_format,
            task.title,
            TaskCategories.resolveName(task.categoryId, categories),
            getString(task.status.labelRes()),
            date,
        )
    }

    private fun historyText(value: String): TextView = TextView(this).apply {
        text = value
        textSize = 16f
        setPadding(0, 14, 0, 14)
        enableReadOnlyTextSelection()
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val RECENT_HISTORY_LIMIT = 200
        val dayFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern(
            "M月d日",
            Locale.SIMPLIFIED_CHINESE,
        )
    }
}
