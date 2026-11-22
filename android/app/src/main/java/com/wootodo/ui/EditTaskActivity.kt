package com.wootodo.ui

import android.app.DatePickerDialog
import android.app.AlertDialog
import android.app.TimePickerDialog
import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import androidx.lifecycle.lifecycleScope
import com.google.android.material.textfield.MaterialAutoCompleteTextView
import com.google.android.material.textfield.TextInputLayout
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.data.TaskRepository
import com.wootodo.domain.CategoryInputResult
import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskDraft
import com.wootodo.domain.TaskStatus
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.widget.TodayWidgetUpdater
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.launch

class EditTaskActivity : AppCompatActivity() {
    private lateinit var repository: TaskRepository
    private lateinit var pageTitle: TextView
    private lateinit var settledNotice: TextView
    private lateinit var titleInput: EditText
    private lateinit var categoryInputLayout: TextInputLayout
    private lateinit var categoryInput: MaterialAutoCompleteTextView
    private lateinit var manageCategoriesButton: Button
    private lateinit var dateRangeSwitch: SwitchCompat
    private lateinit var dateRangeContainer: LinearLayout
    private lateinit var startDateButton: Button
    private lateinit var endDateSwitch: SwitchCompat
    private lateinit var endDateButton: Button
    private lateinit var reminderSwitch: SwitchCompat
    private lateinit var reminderTimeButton: Button
    private lateinit var repeatDailySwitch: SwitchCompat
    private lateinit var saveButton: Button
    private lateinit var deleteButton: Button
    private var categories: List<TaskCategory> = TaskCategories.defaults
    private var dateRangeEnabled = false
    private var startDate: LocalDate = TaskDateRules.today()
    private var endDateEnabled = false
    private var endDate: LocalDate = TaskDateRules.today()
    private var reminderTime: LocalTime = LocalTime.of(9, 0)
    private var repeatDaily = false
    private var editingTask: Task? = null
    private var isLoading = true
    private var initialSnapshot: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_edit_task)
        applySystemBarInsets(findViewById(R.id.edit_task_root))
        pageTitle = findViewById(R.id.page_title)
        settledNotice = findViewById(R.id.settled_notice)
        titleInput = findViewById(R.id.title_input)
        titleInput.enableEditableTextActions()
        categoryInputLayout = findViewById(R.id.category_input_layout)
        categoryInput = findViewById(R.id.category_input)
        manageCategoriesButton = findViewById(R.id.manage_categories_button)
        dateRangeSwitch = findViewById(R.id.date_range_switch)
        dateRangeContainer = findViewById(R.id.date_range_container)
        startDateButton = findViewById(R.id.start_date_button)
        endDateSwitch = findViewById(R.id.end_date_switch)
        endDateButton = findViewById(R.id.end_date_button)
        reminderSwitch = findViewById(R.id.reminder_switch)
        reminderTimeButton = findViewById(R.id.reminder_time_button)
        repeatDailySwitch = findViewById(R.id.repeat_daily_switch)
        saveButton = findViewById(R.id.save_button)
        deleteButton = findViewById(R.id.delete_button)
        repository = (application as WooTodoApplication).taskRepository

        findViewById<View>(R.id.back_button).setOnClickListener { attemptClose() }
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() = attemptClose()
            },
        )

        categoryInput.doAfterTextChanged { categoryInputLayout.error = null }
        manageCategoriesButton.setOnClickListener { manageCategories() }
        dateRangeSwitch.setOnCheckedChangeListener { _, enabled ->
            dateRangeEnabled = enabled
            dateRangeContainer.isVisible = enabled
            if (enabled && startDate.isAfter(endDate)) endDate = startDate
            if (!enabled) {
                repeatDaily = false
                repeatDailySwitch.isChecked = false
                endDateEnabled = false
                endDateSwitch.isChecked = false
            }
            updateDateButtons()
            updateReminderControls()
        }
        repeatDailySwitch.setOnCheckedChangeListener { _, checked ->
            repeatDaily = checked && dateRangeEnabled
        }
        endDateSwitch.setOnCheckedChangeListener { _, checked ->
            endDateEnabled = checked && dateRangeEnabled
            if (endDateEnabled && endDate.isBefore(startDate)) endDate = startDate
            updateDateButtons()
        }
        startDateButton.setOnClickListener { showDatePicker(isStart = true) }
        endDateButton.setOnClickListener { showDatePicker(isStart = false) }
        reminderSwitch.setOnCheckedChangeListener { _, _ -> updateReminderControls() }
        reminderTimeButton.setOnClickListener { showReminderTimePicker() }
        saveButton.setOnClickListener { saveTask() }
        deleteButton.setOnClickListener { confirmDelete() }

        lifecycleScope.launch {
            categories = repository.allCategories()
            setupCategoryInput()
            val taskId = intent.getStringExtra(EXTRA_TASK_ID)
            if (taskId == null) {
                applyDraftDefaults(savedInstanceState)
                applyEditable(true)
            } else {
                val task = repository.get(taskId)
                if (task == null) {
                    finish()
                    return@launch
                }
                editingTask = task
                applyTask(task, savedInstanceState)
                applyEditable(task.status == TaskStatus.PENDING)
            }
            isLoading = false
            initialSnapshot = currentSnapshot()
        }
    }

    private fun setupCategoryInput() {
        categoryInput.setAdapter(
            ArrayAdapter(
                this,
                android.R.layout.simple_dropdown_item_1line,
                categories.map(TaskCategory::name),
            ),
        )
    }

    private fun applyDraftDefaults(state: Bundle?) {
        val today = TaskDateRules.today()
        startDate = today
        endDate = today
        categoryInput.setText(state?.getString(STATE_CATEGORY_INPUT).orEmpty())
        titleInput.setText(state?.getString(STATE_TITLE).orEmpty())
        dateRangeEnabled = state?.getBoolean(STATE_DATE_RANGE_ENABLED) ?: false
        state?.getString(STATE_START_DATE)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            ?.let { startDate = it }
        endDateEnabled = state?.getBoolean(STATE_END_DATE_ENABLED) ?: false
        state?.getString(STATE_END_DATE)?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            ?.let { endDate = it }
        reminderTime = state?.getString(STATE_REMINDER_TIME)
            ?.let { runCatching { LocalTime.parse(it) }.getOrNull() }
            ?: reminderTime
        reminderSwitch.isChecked = state?.getBoolean(STATE_REMINDER_ENABLED) ?: false
        repeatDaily = state?.getBoolean(STATE_REPEAT_DAILY) ?: false
        repeatDailySwitch.isChecked = repeatDaily
        endDateSwitch.isChecked = endDateEnabled
        dateRangeSwitch.isChecked = dateRangeEnabled
        dateRangeContainer.isVisible = dateRangeEnabled
        updateDateButtons()
        updateReminderControls()
    }

    private fun applyTask(task: Task, state: Bundle?) {
        pageTitle.setText(
            if (task.status == TaskStatus.PENDING) R.string.edit_task else R.string.view_task_title,
        )
        categoryInput.setText(
            state?.getString(STATE_CATEGORY_INPUT)
                ?: categories.firstOrNull { it.id == task.categoryId }
                    ?.takeIf { it.id != TaskCategories.INBOX_ID }
                    ?.name
                    .orEmpty(),
        )
        titleInput.setText(state?.getString(STATE_TITLE) ?: task.title)
        startDate = state?.getString(STATE_START_DATE)
            ?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            ?: task.startDate
            ?: TaskDateRules.today()
        endDate = state?.getString(STATE_END_DATE)
            ?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
            ?: task.endDate
            ?: startDate
        endDateEnabled = state?.getBoolean(STATE_END_DATE_ENABLED)
            ?: (task.startDate != null && task.endDate != null && task.endDate.isAfter(task.startDate))
        dateRangeEnabled = state?.getBoolean(STATE_DATE_RANGE_ENABLED)
            ?: (task.startDate != null)
        reminderTime = state?.getString(STATE_REMINDER_TIME)
            ?.let { runCatching { LocalTime.parse(it) }.getOrNull() }
            ?: task.reminderTime
            ?: reminderTime
        reminderSwitch.isChecked = state?.getBoolean(STATE_REMINDER_ENABLED)
            ?: (task.reminderTime != null)
        repeatDaily = state?.getBoolean(STATE_REPEAT_DAILY)
            ?: (task.recurrence == com.wootodo.domain.TaskRecurrence.DAILY)
        repeatDailySwitch.isChecked = repeatDaily
        endDateSwitch.isChecked = endDateEnabled
        dateRangeSwitch.isChecked = dateRangeEnabled
        dateRangeContainer.isVisible = dateRangeEnabled
        updateDateButtons()
        updateReminderControls()
        deleteButton.isVisible = task.status == TaskStatus.PENDING
    }

    private fun applyEditable(editable: Boolean) {
        settledNotice.isVisible = !editable
        listOf(
            titleInput,
            categoryInput,
            manageCategoriesButton,
            dateRangeSwitch,
            startDateButton,
            endDateSwitch,
            endDateButton,
            reminderSwitch,
            reminderTimeButton,
            repeatDailySwitch,
        ).forEach { it.isEnabled = editable }
        saveButton.isVisible = editable
        deleteButton.isVisible = editable &&
            editingTask != null &&
            editingTask?.status == TaskStatus.PENDING
    }

    private fun updateDateButtons() {
        startDateButton.text = getString(
            R.string.date_button_format,
            getString(R.string.start_date_label),
            startDate.format(dateFormatter),
        )
        endDateButton.isVisible = endDateEnabled
        endDateButton.text = getString(
            R.string.date_button_format,
            getString(R.string.end_date_label),
            endDate.format(dateFormatter),
        )
    }

    private fun updateReminderControls() {
        val available = dateRangeEnabled
        reminderSwitch.isEnabled = available
        if (!available) reminderSwitch.isChecked = false
        reminderTimeButton.isEnabled = available && reminderSwitch.isChecked
        reminderTimeButton.text = if (reminderSwitch.isChecked && available) {
            getString(R.string.task_reminder_time, reminderTime.toString())
        } else {
            getString(R.string.task_reminder_not_set)
        }
    }

    private fun showDatePicker(isStart: Boolean) {
        val current = if (isStart) startDate else endDate
        DatePickerDialog(
            this,
            { _, year, month, day ->
                val picked = LocalDate.of(year, month + 1, day)
                if (isStart) {
                    startDate = picked
                    if (endDate.isBefore(startDate)) endDate = picked
                } else {
                    endDate = if (picked.isBefore(startDate)) startDate else picked
                }
                updateDateButtons()
            },
            current.year,
            current.monthValue - 1,
            current.dayOfMonth,
        ).show()
    }

    private fun showReminderTimePicker() {
        TimePickerDialog(
            this,
            { _, hour, minute ->
                reminderTime = LocalTime.of(hour, minute)
                reminderSwitch.isChecked = true
                updateReminderControls()
            },
            reminderTime.hour,
            reminderTime.minute,
            true,
        ).show()
    }

    private fun saveTask() {
        if (isLoading) return
        val title = titleInput.text.toString().trim()
        if (title.isBlank()) {
            titleInput.error = getString(R.string.title_required)
            return
        }
        if (dateRangeEnabled && endDateEnabled && startDate.isAfter(endDate)) {
            Toast.makeText(this, R.string.date_range_invalid, Toast.LENGTH_SHORT).show()
            return
        }
        saveButton.isEnabled = false
        lifecycleScope.launch {
            val category = when (val result = repository.resolveCategoryInput(
                categoryInput.text.toString(),
            )) {
                is CategoryInputResult.Selected -> result.category
                CategoryInputResult.InvalidName -> {
                    showCategoryError(getString(R.string.category_name_invalid))
                    return@launch
                }
                CategoryInputResult.LimitReached -> {
                    showCategoryError(getString(R.string.category_limit_reached))
                    return@launch
                }
                CategoryInputResult.SaveFailed -> {
                    saveButton.isEnabled = true
                    Toast.makeText(
                        this@EditTaskActivity,
                        R.string.save_failed,
                        Toast.LENGTH_SHORT,
                    ).show()
                    return@launch
                }
            }
            categories = repository.allCategories()
            setupCategoryInput()
            val draft = TaskDraft(
                title = title,
                categoryId = category.id,
                startDate = startDate.takeIf { dateRangeEnabled },
                endDate = endDate.takeIf { dateRangeEnabled && endDateEnabled },
                reminderTime = reminderTime.takeIf {
                    dateRangeEnabled && reminderSwitch.isChecked
                },
                recurrence = if (dateRangeEnabled && repeatDaily) {
                    com.wootodo.domain.TaskRecurrence.DAILY
                } else {
                    com.wootodo.domain.TaskRecurrence.ONCE
                },
            )
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

    private fun showCategoryError(message: String) {
        saveButton.isEnabled = true
        categoryInputLayout.error = message
        categoryInput.requestFocus()
    }

    private fun manageCategories() {
        CategoryManagerDialog.show(this, repository) { updated ->
            val typedName = categoryInput.text.toString().trim()
            val previous = categories.firstOrNull {
                it.name.equals(typedName, ignoreCase = true)
            }
            categories = updated
            if (previous != null) {
                categoryInput.setText(
                    updated.firstOrNull { it.id == previous.id }?.name.orEmpty(),
                )
            }
            setupCategoryInput()
            (application as WooTodoApplication).notifyLocalMutation()
            TodayWidgetUpdater.updateAllAsync(applicationContext)
        }
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

    private fun attemptClose() {
        if (isLoading || !hasUnsavedChanges()) {
            finish()
            return
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.editor_discard_title)
            .setMessage(R.string.editor_discard_message)
            .setNegativeButton(R.string.editor_discard_cancel, null)
            .setPositiveButton(R.string.editor_discard_confirm) { _, _ -> finish() }
            .show()
    }

    private fun hasUnsavedChanges(): Boolean {
        val baseline = initialSnapshot ?: return false
        return currentSnapshot() != baseline
    }

    private fun currentSnapshot(): String = listOf(
        titleInput.text.toString(),
        categoryInput.text.toString().trim(),
        dateRangeEnabled,
        startDate,
        endDateEnabled,
        endDate,
        reminderSwitch.isChecked,
        reminderTime,
        repeatDaily,
    ).joinToString("|")

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_TITLE, titleInput.text.toString())
        outState.putString(STATE_CATEGORY_INPUT, categoryInput.text.toString())
        outState.putBoolean(STATE_DATE_RANGE_ENABLED, dateRangeEnabled)
        outState.putString(STATE_START_DATE, startDate.toString())
        outState.putBoolean(STATE_END_DATE_ENABLED, endDateEnabled)
        outState.putString(STATE_END_DATE, endDate.toString())
        outState.putBoolean(STATE_REMINDER_ENABLED, reminderSwitch.isChecked)
        outState.putString(STATE_REMINDER_TIME, reminderTime.toString())
        outState.putBoolean(STATE_REPEAT_DAILY, repeatDaily)
        super.onSaveInstanceState(outState)
    }

    companion object {
        const val EXTRA_TASK_ID = "task_id"
        const val STATE_TITLE = "editor_title"
        const val STATE_CATEGORY_INPUT = "editor_category_input"
        const val STATE_DATE_RANGE_ENABLED = "editor_date_range_enabled"
        const val STATE_START_DATE = "editor_start_date"
        const val STATE_END_DATE_ENABLED = "editor_end_date_enabled"
        const val STATE_END_DATE = "editor_end_date"
        const val STATE_REMINDER_ENABLED = "editor_reminder_enabled"
        const val STATE_REMINDER_TIME = "editor_reminder_time"
        const val STATE_REPEAT_DAILY = "editor_repeat_daily"
        val dateFormatter: DateTimeFormatter =
            DateTimeFormatter.ofPattern("M月d日", Locale.SIMPLIFIED_CHINESE)
    }
}
