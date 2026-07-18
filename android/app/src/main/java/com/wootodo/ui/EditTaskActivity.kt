package com.wootodo.ui

import android.app.DatePickerDialog
import android.app.AlertDialog
import android.os.Bundle
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.data.TaskRepository
import com.wootodo.domain.QuestLine
import com.wootodo.domain.Recurrence
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskDraft
import com.wootodo.domain.TaskRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.widget.TodayWidgetUpdater
import java.time.LocalDate
import kotlinx.coroutines.launch

class EditTaskActivity : AppCompatActivity() {
    private lateinit var repository: TaskRepository
    private lateinit var pageTitle: TextView
    private lateinit var titleInput: EditText
    private lateinit var questSpinner: Spinner
    private lateinit var timeSpinner: Spinner
    private lateinit var dateButton: Button
    private lateinit var recurrenceSpinner: Spinner
    private lateinit var saveButton: Button
    private lateinit var deleteButton: Button
    private val questLines = QuestLine.entries
    private val timeTypes = TaskTimeType.entries
    private var recurrenceOptions: List<Recurrence> = Recurrence.entries
    private var selectedDate: LocalDate = TaskDateRules.today()
    private var editingTask: Task? = null
    private var isLoadingTask = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_edit_task)
        applySystemBarInsets(findViewById(R.id.edit_task_root))
        pageTitle = findViewById(R.id.page_title)
        titleInput = findViewById(R.id.title_input)
        questSpinner = findViewById(R.id.quest_spinner)
        timeSpinner = findViewById(R.id.time_spinner)
        dateButton = findViewById(R.id.date_button)
        recurrenceSpinner = findViewById(R.id.recurrence_spinner)
        saveButton = findViewById(R.id.save_button)
        deleteButton = findViewById(R.id.delete_button)
        repository = (application as WooTodoApplication).taskRepository

        val restoredDate = savedInstanceState?.getString(STATE_SELECTED_DATE)
        (restoredDate ?: intent.getStringExtra(EXTRA_TARGET_DATE))?.let { encoded ->
            runCatching { LocalDate.parse(encoded) }.getOrNull()?.let { selectedDate = it }
        }
        setupSpinners()
        dateButton.setOnClickListener { showDatePicker() }
        saveButton.setOnClickListener { saveTask() }
        deleteButton.setOnClickListener { confirmDelete() }

        val taskId = intent.getStringExtra(EXTRA_TASK_ID)
        if (taskId == null) {
            if (savedInstanceState != null) {
                restoreDraftState(savedInstanceState)
            } else {
                val initialType = intent.getStringExtra(EXTRA_TIME_TYPE)
                    ?.let { runCatching { TaskTimeType.fromRaw(it) }.getOrNull() }
                    ?: TaskTimeType.DAY
                timeSpinner.setSelection(timeTypes.indexOf(initialType))
                updateDateButton(initialType)
            }
        } else {
            loadTask(taskId, savedInstanceState)
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_TITLE, titleInput.text.toString())
        outState.putString(STATE_SELECTED_DATE, selectedDate.toString())
        questLines.getOrNull(questSpinner.selectedItemPosition)?.let {
            outState.putString(STATE_QUEST_LINE, it.rawValue)
        }
        timeTypes.getOrNull(timeSpinner.selectedItemPosition)?.let {
            outState.putString(STATE_TIME_TYPE, it.rawValue)
        }
        outState.putString(STATE_RECURRENCE, selectedRecurrenceOrOnce().rawValue)
        super.onSaveInstanceState(outState)
    }

    private fun setupSpinners() {
        questSpinner.adapter = simpleAdapter(questLines.map { getString(it.labelRes()) })
        timeSpinner.adapter = simpleAdapter(timeTypes.map { getString(it.labelRes()) })
        timeSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
                val type = timeTypes[position]
                updateRecurrenceOptions(type, selectedRecurrenceOrOnce())
                updateDateButton(type)
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
        updateRecurrenceOptions(TaskTimeType.DAY, Recurrence.ONCE)
    }

    private fun updateRecurrenceOptions(type: TaskTimeType, preferred: Recurrence) {
        recurrenceOptions = TaskRules.allowedRecurrences(type)
        recurrenceSpinner.adapter = simpleAdapter(
            recurrenceOptions.map { getString(it.labelRes()) },
        )
        val selection = recurrenceOptions.indexOf(preferred).takeIf { it >= 0 } ?: 0
        recurrenceSpinner.setSelection(selection)
    }

    private fun selectedRecurrenceOrOnce(): Recurrence =
        recurrenceOptions.getOrNull(recurrenceSpinner.selectedItemPosition) ?: Recurrence.ONCE

    private fun loadTask(taskId: String, restoredState: Bundle?) {
        isLoadingTask = true
        lifecycleScope.launch {
            val task = repository.get(taskId)
            if (task == null) {
                finish()
                return@launch
            }
            editingTask = task
            val pending = task.status == TaskStatus.PENDING
            pageTitle.setText(R.string.edit_task)
            if (restoredState == null) {
                titleInput.setText(task.title)
                questSpinner.setSelection(questLines.indexOf(task.questLine))
                selectedDate = task.targetDate ?: TaskDateRules.today()
                timeSpinner.setSelection(timeTypes.indexOf(task.timeType))
                updateRecurrenceOptions(task.timeType, task.recurrence)
                updateDateButton(task.timeType)
            } else {
                // 旋转后的异步数据库读取只恢复实体身份，不能覆盖用户尚未保存的草稿。
                restoreDraftState(restoredState, fallback = task)
            }
            deleteButton.isVisible = pending
            saveButton.isEnabled = pending
            isLoadingTask = false
        }
    }

    private fun restoreDraftState(state: Bundle, fallback: Task? = null) {
        titleInput.setText(state.getString(STATE_TITLE) ?: fallback?.title.orEmpty())
        selectedDate = state.getString(STATE_SELECTED_DATE)
            ?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            ?: fallback?.targetDate
            ?: selectedDate
        val questLine = state.getString(STATE_QUEST_LINE)
            ?.let { runCatching { QuestLine.fromRaw(it) }.getOrNull() }
            ?: fallback?.questLine
            ?: QuestLine.MAIN
        val timeType = state.getString(STATE_TIME_TYPE)
            ?.let { runCatching { TaskTimeType.fromRaw(it) }.getOrNull() }
            ?: fallback?.timeType
            ?: TaskTimeType.DAY
        val recurrence = state.getString(STATE_RECURRENCE)
            ?.let { runCatching { Recurrence.fromRaw(it) }.getOrNull() }
            ?: fallback?.recurrence
            ?: Recurrence.ONCE
        questSpinner.setSelection(questLines.indexOf(questLine))
        timeSpinner.setSelection(timeTypes.indexOf(timeType))
        updateRecurrenceOptions(timeType, recurrence)
        updateDateButton(timeType)
    }

    private fun saveTask() {
        if (isLoadingTask) return
        val title = titleInput.text.toString().trim()
        if (title.isBlank()) {
            titleInput.error = getString(R.string.title_required)
            return
        }
        val type = timeTypes[timeSpinner.selectedItemPosition]
        val draft = TaskDraft(
            title = title,
            timeType = type,
            targetDate = if (type == TaskTimeType.LEISURE) null else selectedDate,
            questLine = questLines[questSpinner.selectedItemPosition],
            recurrence = selectedRecurrenceOrOnce(),
        )
        saveButton.isEnabled = false
        lifecycleScope.launch {
            val saved = runCatching {
                editingTask?.let { repository.update(it.id, draft) } ?: run {
                    repository.create(draft)
                    true
                }
            }.getOrDefault(false)
            if (saved) {
                TodayWidgetUpdater.updateAllAsync(applicationContext)
                ReminderScheduler.schedule(applicationContext)
                (application as WooTodoApplication).notifyLocalMutation()
                finish()
            } else {
                saveButton.isEnabled = true
                Toast.makeText(this@EditTaskActivity, R.string.save_failed, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun showDatePicker() {
        DatePickerDialog(
            this,
            { _, year, month, day ->
                selectedDate = LocalDate.of(year, month + 1, day)
                updateDateButton(timeTypes[timeSpinner.selectedItemPosition])
            },
            selectedDate.year,
            selectedDate.monthValue - 1,
            selectedDate.dayOfMonth,
        ).show()
    }

    private fun confirmDelete() {
        val task = editingTask ?: return
        if (task.status != TaskStatus.PENDING) return
        AlertDialog.Builder(this)
            .setTitle(R.string.delete_task_title)
            .setMessage(R.string.delete_task_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.delete) { _, _ -> deleteTask(task.id) }
            .show()
    }

    private fun deleteTask(taskId: String) {
        deleteButton.isEnabled = false
        lifecycleScope.launch {
            if (repository.delete(taskId)) {
                TodayWidgetUpdater.updateAllAsync(applicationContext)
                (application as WooTodoApplication).notifyLocalMutation()
                finish()
            } else {
                deleteButton.isEnabled = true
                Toast.makeText(this@EditTaskActivity, R.string.delete_failed, Toast.LENGTH_SHORT).show()
            }
        }
    }

    private fun updateDateButton(type: TaskTimeType) {
        dateButton.isVisible = type != TaskTimeType.LEISURE
        val normalized = TaskDateRules.normalizeTargetDate(type, selectedDate)
        dateButton.text = when (type) {
            TaskTimeType.DAY -> "日期：$normalized"
            TaskTimeType.WEEK -> "所在周：$normalized 起"
            TaskTimeType.MONTH -> "月份：${normalized?.year}-${normalized?.monthValue.toString().padStart(2, '0')}"
            TaskTimeType.LEISURE -> getString(R.string.select_date)
        }
    }

    private fun simpleAdapter(labels: List<String>): ArrayAdapter<String> =
        ArrayAdapter(this, android.R.layout.simple_spinner_item, labels).also {
            it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }

    companion object {
        const val EXTRA_TASK_ID = "task_id"
        const val EXTRA_TIME_TYPE = "time_type"
        const val EXTRA_TARGET_DATE = "target_date"
        private const val STATE_TITLE = "editor_title"
        private const val STATE_SELECTED_DATE = "editor_selected_date"
        private const val STATE_QUEST_LINE = "editor_quest_line"
        private const val STATE_TIME_TYPE = "editor_time_type"
        private const val STATE_RECURRENCE = "editor_recurrence"
    }
}
