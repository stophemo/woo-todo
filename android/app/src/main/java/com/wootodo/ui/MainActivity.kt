package com.wootodo.ui

import android.Manifest
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TimePicker
import android.widget.Toast
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.annotation.StringRes
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.PopupMenu
import androidx.appcompat.widget.SwitchCompat
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.ItemTouchHelper
import com.google.android.material.floatingactionbutton.FloatingActionButton
import com.google.android.material.snackbar.Snackbar
import com.wootodo.BuildConfig
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.display.DayCounterPreferences
import com.wootodo.display.DayCounterSettings
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.reminder.ReminderPreferences
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.reminder.ReminderSettings
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.update.AppUpdateCheckResult
import com.wootodo.update.AppUpdateEvent
import com.wootodo.update.AppUpdatePolicy
import com.wootodo.update.AppUpdatePreferences
import com.wootodo.update.AppUpdateViewModel
import com.wootodo.update.ApkUpdateInstaller
import com.wootodo.update.GitHubRelease
import com.wootodo.widget.TodayWidgetPreferences
import com.wootodo.widget.TodayWidgetUpdater
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {
    private lateinit var taskAdapter: TaskAdapter
    private lateinit var taskList: RecyclerView
    private lateinit var emptyView: TextView
    private lateinit var emptyState: View
    private lateinit var syncStatus: TextView
    private lateinit var screenTitle: TextView
    private lateinit var dayCounterText: TextView
    private lateinit var titleEditHint: View
    private var updateProgressDialog: AlertDialog? = null
    private var updatePromptDialog: AlertDialog? = null
    private var updateDownloadJob: Job? = null
    private var pendingUpdatePermissionRelease: GitHubRelease? = null
    private var availableUpdateRelease: GitHubRelease? = null
    private val updatePreferences by lazy { AppUpdatePreferences(this) }
    private val apkUpdateInstaller by lazy { ApkUpdateInstaller(this) }
    private val dayCounterChangeListener: (DayCounterSettings) -> Unit = {
        runOnUiThread { renderDayCounter() }
    }

    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (!granted) {
                Toast.makeText(
                    this,
                    R.string.notification_permission_denied,
                    Toast.LENGTH_LONG,
                ).show()
            }
        }

    private val requestUpdateInstallPermission = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) {
        val release = pendingUpdatePermissionRelease
        pendingUpdatePermissionRelease = null
        if (release == null) return@registerForActivityResult
        if (apkUpdateInstaller.canRequestPackageInstalls()) {
            downloadAndInstallUpdate(release)
        } else {
            Toast.makeText(this, R.string.update_install_permission_denied, Toast.LENGTH_LONG).show()
        }
    }

    private val viewModel: MainViewModel by viewModels {
        val app = application as WooTodoApplication
        MainViewModel.Factory(app.taskRepository) {
            TodayWidgetUpdater.updateAllAsync(applicationContext)
            app.notifyLocalMutation()
        }
    }

    private val appUpdateViewModel: AppUpdateViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        applySystemBarInsets(findViewById(R.id.main_root))
        availableUpdateRelease = updatePreferences.loadAvailableRelease(currentVersionLabel())
        taskList = findViewById(R.id.task_list)
        emptyView = findViewById(R.id.empty_view)
        emptyState = findViewById(R.id.empty_state)
        syncStatus = findViewById(R.id.sync_status)
        screenTitle = findViewById(R.id.screen_title)
        dayCounterText = findViewById(R.id.day_counter_text)
        titleEditHint = findViewById(R.id.title_edit_hint)
        // 标题就长在主界面上，点它直接改，不再只能从“更多”菜单里找。
        findViewById<View>(R.id.title_area).setOnClickListener {
            showDayCounterSettings()
        }
        syncStatus.enableReadOnlyTextSelection()
        dayCounterText.enableReadOnlyTextSelection()

        taskAdapter = TaskAdapter(
            context = this,
            onCheck = { task ->
                if (task.status == TaskStatus.COMPLETED) {
                    reopenTask(task)
                } else {
                    completeTask(task)
                }
            },
            onMenu = ::showTaskMenu,
            onEdit = { openEditor(it.id) },
        )
        taskList.apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = taskAdapter
        }
        attachRowGestures()

        findViewById<FloatingActionButton>(R.id.add_task).setOnClickListener { openEditor() }
        findViewById<Button>(R.id.empty_add_task).setOnClickListener { openEditor() }
        findViewById<View>(R.id.insights_button).setOnClickListener {
            startActivity(Intent(this, InsightsActivity::class.java))
        }
        findViewById<View>(R.id.reminder_settings_button).setOnClickListener { anchor ->
            showMoreMenu(anchor)
        }
        // 同步状态行和“更多 → 跨设备”都进入同一个设置页。
        syncStatus.setOnClickListener { openCrossDeviceSettings() }
        // 凭据在 Application 的后台初始化中读取；先按当前快照渲染，避免启动窗口仍可点击。
        renderSyncState((application as WooTodoApplication).syncRuntime.state.value)

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    combine(viewModel.sections, viewModel.categories) { sections, categories ->
                        sections to categories
                    }.collect { (sections, categories) ->
                        taskAdapter.submitSections(sections, categories)
                        emptyState.isVisible = sections.isEmpty()
                    }
                }
                launch {
                    (application as WooTodoApplication).syncRuntime.state.collect(::renderSyncState)
                }
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.RESUMED) {
                launch {
                    appUpdateViewModel.events.collect(::renderAppUpdateEvent)
                }
                launch {
                    while (true) {
                        checkForAppUpdate(manual = false)
                        delay(AppUpdatePolicy.AUTOMATIC_CHECK_POLL_INTERVAL_MILLIS)
                    }
                }
            }
        }
        if (savedInstanceState == null) {
            checkForAppUpdate(manual = false, force = true)
        }
        requestNotificationPermissionIfNeeded()
        renderDayCounter()
        availableUpdateRelease?.let { maybeShowUpdatePrompt(it, manual = false) }
        maybeShowLegacySyncNotice()
    }

    override fun onResume() {
        super.onResume()
        viewModel.refresh()
        renderDayCounter()
        (application as WooTodoApplication).settleRecurringTasksAsync()
        (application as WooTodoApplication).notifyAppForegrounded()
    }

    override fun onStart() {
        super.onStart()
        DayCounterPreferences.addListener(dayCounterChangeListener)
    }

    override fun onStop() {
        DayCounterPreferences.removeListener(dayCounterChangeListener)
        super.onStop()
    }

    override fun onDestroy() {
        updateProgressDialog?.dismiss()
        updatePromptDialog?.dismiss()
        super.onDestroy()
    }

    private fun openCrossDeviceSettings() {
        startActivity(Intent(this, CrossDeviceSettingsActivity::class.java))
    }

    /** 旧同步方式只提示一次；旧凭据保留在安全存储中，不删除也不启用。 */
    private fun maybeShowLegacySyncNotice() {
        val app = application as WooTodoApplication
        lifecycleScope.launch {
            val legacy = withContext(Dispatchers.IO) {
                app.legacySyncDetected() && app.legacySyncNotice.shouldShowOnce()
            }
            if (!legacy || isFinishing || isDestroyed) return@launch
            app.legacySyncNotice.markShown()
            AlertDialog.Builder(this@MainActivity)
                .setTitle(R.string.legacy_sync_disabled_title)
                .setMessage(R.string.legacy_sync_disabled_message)
                .setNegativeButton(R.string.legacy_sync_later, null)
                .setPositiveButton(R.string.legacy_sync_go_pair) { _, _ ->
                    openCrossDeviceSettings()
                }
                .show()
                .enableMessageSelection()
        }
    }

    private fun openEditor(taskId: String? = null) {
        startActivity(
            Intent(this, EditTaskActivity::class.java).apply {
                taskId?.let { putExtra(EditTaskActivity.EXTRA_TASK_ID, it) }
            },
        )
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) return
        val preferences = getSharedPreferences(NOTIFICATION_PERMISSION_STATE, MODE_PRIVATE)
        if (preferences.getBoolean(KEY_NOTIFICATION_PERMISSION_REQUESTED, false)) return
        preferences.edit().putBoolean(KEY_NOTIFICATION_PERMISSION_REQUESTED, true).apply()
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun attachRowGestures() {
        val density = resources.displayMetrics.density
        val edgePadding = 16f * density
        val revealPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 14f * resources.displayMetrics.scaledDensity
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val callback = object : ItemTouchHelper.Callback() {
            override fun isLongPressDragEnabled(): Boolean = false

            override fun getMovementFlags(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
            ): Int {
                val task = taskAdapter.taskAt(viewHolder.adapterPosition)
                    ?: return makeMovementFlags(0, 0)
                val swipeFlags = (if (swipeRightAction(task.status) != null) {
                    ItemTouchHelper.RIGHT
                } else {
                    0
                }) or (if (swipeLeftAction(task.status) != null) ItemTouchHelper.LEFT else 0)
                return makeMovementFlags(0, swipeFlags)
            }

            override fun onMove(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                target: RecyclerView.ViewHolder,
            ): Boolean = false

            override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) {
                val position = viewHolder.adapterPosition
                val task = taskAdapter.taskAt(position) ?: return
                val action = if (direction == ItemTouchHelper.RIGHT) {
                    swipeRightAction(task.status)
                } else {
                    swipeLeftAction(task.status)
                }
                action?.let { handleRowAction(it, task) }
                // ItemTouchHelper 不会自动把未删除的行推回原位，必须主动复位。
                viewHolder.itemView.translationX = 0f
                taskList.post { taskAdapter.notifyItemChanged(position) }
            }

            override fun onChildDraw(
                canvas: Canvas,
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                dX: Float,
                dY: Float,
                actionState: Int,
                isCurrentlyActive: Boolean,
            ) {
                if (actionState == ItemTouchHelper.ACTION_STATE_SWIPE &&
                    isCurrentlyActive &&
                    dX != 0f
                ) {
                    val task = taskAdapter.taskAt(viewHolder.adapterPosition)
                    val action = if (dX > 0) {
                        task?.let { swipeRightAction(it.status) }
                    } else {
                        task?.let { swipeLeftAction(it.status) }
                    }
                    if (action != null) {
                        val itemView = viewHolder.itemView
                        val left = if (dX > 0) itemView.left.toFloat() else itemView.right + dX
                        val right = if (dX > 0) itemView.left + dX else itemView.right.toFloat()
                        val radius = 12f * density
                        revealPaint.color = ContextCompat.getColor(
                            this@MainActivity,
                            swipeColorRes(action),
                        )
                        canvas.drawRoundRect(
                            left,
                            itemView.top.toFloat(),
                            right,
                            itemView.bottom.toFloat(),
                            radius,
                            radius,
                            revealPaint,
                        )
                        val label = getString(swipeLabelRes(action))
                        labelPaint.color = ContextCompat.getColor(this@MainActivity, R.color.on_primary)
                        val baseline = itemView.top + itemView.height / 2f -
                            (labelPaint.descent() + labelPaint.ascent()) / 2f
                        val textX = if (dX > 0) {
                            itemView.left + edgePadding
                        } else {
                            itemView.right - edgePadding - labelPaint.measureText(label)
                        }
                        canvas.drawText(label, textX, baseline, labelPaint)
                    }
                }
                super.onChildDraw(
                    canvas,
                    recyclerView,
                    viewHolder,
                    dX,
                    dY,
                    actionState,
                    isCurrentlyActive,
                )
            }

            override fun clearView(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
            ) {
                super.clearView(recyclerView, viewHolder)
                viewHolder.itemView.translationX = 0f
            }
        }
        ItemTouchHelper(callback).attachToRecyclerView(taskList)
    }

    private fun swipeLabelRes(action: TaskRowAction): Int = when (action) {
        TaskRowAction.COMPLETE -> R.string.task_menu_complete
        TaskRowAction.REOPEN -> R.string.task_menu_reopen
        TaskRowAction.DELETE -> R.string.task_menu_delete
        TaskRowAction.PASS -> R.string.task_menu_pass
        TaskRowAction.EDIT -> R.string.task_menu_edit
    }

    private fun swipeColorRes(action: TaskRowAction): Int = when (action) {
        TaskRowAction.DELETE, TaskRowAction.PASS -> R.color.orange
        else -> R.color.green
    }

    private fun showTaskMenu(task: Task, anchor: View) {
        val actions = taskRowActions(task.status)
        PopupMenu(this, anchor).apply {
            actions.forEachIndexed { index, action ->
                menu.add(0, index, index, getString(action.labelRes(task.status)))
            }
            setOnMenuItemClickListener { item ->
                val action = actions.getOrNull(item.itemId) ?: return@setOnMenuItemClickListener false
                handleRowAction(action, task)
                true
            }
            show()
        }
    }

    private fun handleRowAction(action: TaskRowAction, task: Task) {
        when (action) {
            TaskRowAction.COMPLETE -> completeTask(task)
            TaskRowAction.REOPEN -> reopenTask(task)
            TaskRowAction.PASS -> confirmPass(task)
            TaskRowAction.EDIT -> openEditor(task.id)
            TaskRowAction.DELETE -> deleteTask(task)
        }
    }

    private fun completeTask(task: Task) {
        viewModel.complete(task.id) { changed ->
            if (changed) {
                showUndoSnackbar(
                    getString(R.string.task_completed_message, task.title),
                    R.string.undo,
                ) {
                    reopenTask(task, quiet = true)
                }
            }
        }
    }

    private fun reopenTask(task: Task, quiet: Boolean = false) {
        viewModel.reopen(task.id) { changed ->
            when {
                changed && !quiet -> showTransientMessage(
                    getString(R.string.task_reopened_message, task.title),
                )
                !changed -> showTransientMessage(
                    R.string.task_reopen_unavailable,
                    Snackbar.LENGTH_LONG,
                )
            }
        }
    }

    private fun confirmPass(task: Task) {
        val dialog = AlertDialog.Builder(this)
            .setTitle(getString(R.string.pass_confirm_title, task.title))
            .setMessage(R.string.pass_confirm_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.pass_confirm) { _, _ ->
                viewModel.pass(task.id) { changed ->
                    if (changed) {
                        showTransientMessage(getString(R.string.task_passed_message, task.title))
                    }
                }
            }
            .show()
        // 主题会把按钮文字转成大写，与产品中统一的 Pass 写法不一致。
        dialog.getButton(AlertDialog.BUTTON_POSITIVE)?.isAllCaps = false
    }

    private fun deleteTask(task: Task) {
        viewModel.delete(task) { deleted ->
            if (!deleted) {
                showTransientMessage(R.string.task_delete_failed, Snackbar.LENGTH_LONG)
                return@delete
            }
            showUndoSnackbar(
                getString(R.string.task_deleted_message, task.title),
                R.string.undo,
            ) {
                viewModel.restoreTrash(task.id) { restored ->
                    if (!restored) {
                        showTransientMessage(R.string.task_restore_failed, Snackbar.LENGTH_LONG)
                    }
                }
            }
        }
    }

    private fun showUndoSnackbar(
        message: String,
        @StringRes actionRes: Int,
        onUndo: () -> Unit,
    ) {
        Snackbar.make(findViewById(R.id.main_root), message, Snackbar.LENGTH_LONG)
            .setAction(actionRes) { onUndo() }
            .show()
    }

    private fun showReminderSettings() {
        val settings = ReminderPreferences.load(this)
        val padding = (20 * resources.displayMetrics.density).toInt()
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, 0, padding, 0)
        }
        val enabledSwitch = SwitchCompat(this).apply {
            text = getString(R.string.reminder_enabled)
            isChecked = settings.enabled
        }
        val timePicker = TimePicker(this).apply {
            setIs24HourView(true)
            hour = settings.hour
            minute = settings.minute
            isEnabled = settings.enabled
        }
        enabledSwitch.setOnCheckedChangeListener { _, enabled ->
            timePicker.isEnabled = enabled
        }
        container.addView(enabledSwitch)
        container.addView(timePicker)
        container.addView(
            TextView(this).apply {
                setText(R.string.reminder_settings_message)
                setTextAppearance(com.google.android.material.R.style.TextAppearance_Material3_BodySmall)
                setPadding(0, padding / 2, 0, 0)
                setTextColor(
                    androidx.core.content.ContextCompat.getColor(context, R.color.muted),
                )
            },
        )

        AlertDialog.Builder(this)
            .setTitle(R.string.reminder_settings_title)
            .setView(container)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.confirm) { _, _ ->
                ReminderPreferences.save(
                    this,
                    ReminderSettings(
                        enabled = enabledSwitch.isChecked,
                        hour = timePicker.hour,
                        minute = timePicker.minute,
                    ),
                )
                ReminderScheduler.schedule(this)
            }
            .show()
    }

    private fun showMoreMenu(anchor: View) {
        PopupMenu(this, anchor).apply {
            var order = 0
            val release = appUpdateViewModel.availableRelease.value ?: availableUpdateRelease
            release?.let {
                menu.add(
                    0,
                    MENU_AVAILABLE_UPDATE,
                    order++,
                    getString(R.string.update_available_menu, it.versionLabel),
                )
            }
            menu.add(0, MENU_DAY_COUNTER, order++, R.string.day_counter_settings_title)
            menu.add(0, MENU_CATEGORIES, order++, R.string.category_manage)
            menu.add(0, MENU_TRASH, order++, R.string.trash_menu)
            menu.add(0, MENU_REMINDER, order++, R.string.reminder_settings_title)
            menu.add(0, MENU_CROSS_DEVICE, order++, R.string.cross_device_settings)
            menu.add(0, MENU_CHECK_UPDATE, order++, R.string.check_for_updates)
            setOnMenuItemClickListener { item ->
                when (item.itemId) {
                    MENU_AVAILABLE_UPDATE -> {
                        release?.let(::beginUpdate)
                    }
                    MENU_DAY_COUNTER -> showDayCounterSettings()
                    MENU_CATEGORIES -> manageCategories()
                    MENU_TRASH -> showTrashDialog()
                    MENU_REMINDER -> showReminderSettings()
                    MENU_CROSS_DEVICE -> openCrossDeviceSettings()
                    MENU_CHECK_UPDATE -> checkForAppUpdate(manual = true)
                    else -> return@setOnMenuItemClickListener false
                }
                true
            }
            show()
        }
    }

    private fun manageCategories() {
        val app = application as WooTodoApplication
        CategoryManagerDialog.show(this, app.taskRepository) {
            app.notifyLocalMutation()
            TodayWidgetUpdater.updateAllAsync(applicationContext)
        }
    }

    private fun showTrashDialog() {
        val app = application as WooTodoApplication
        TrashDialog.show(this, app.taskRepository) {
            app.notifyLocalMutation()
            TodayWidgetUpdater.updateAllAsync(applicationContext)
        }
    }

    private fun showDayCounterSettings() {
        TodayDisplaySettingsDialog.show(
            activity = this,
            initial = DayCounterPreferences.load(this),
            initialWidgetOpacity = TodayWidgetPreferences.loadBackgroundOpacity(this),
            today = TaskDateRules.today(),
        ) { settings, widgetOpacity ->
            lifecycleScope.launch {
                val recorded = withContext(Dispatchers.IO) {
                    TodayWidgetPreferences.saveBackgroundOpacity(
                        this@MainActivity,
                        widgetOpacity,
                    )
                    DayCounterPreferences.save(this@MainActivity, settings)
                }
                renderDayCounter()
                TodayWidgetUpdater.updateAllAsync(applicationContext)
                if (recorded) {
                    (application as WooTodoApplication).notifyLocalMutation()
                }
            }
        }
    }

    private fun renderDayCounter() {
        titleEditHint.isVisible = true
        val rendered = DayCounterPreferences.render(this, TaskDateRules.today())
        screenTitle.text = rendered.header ?: getString(R.string.task_screen_title)
        screenTitle.isVisible = true
        dayCounterText.text = rendered.subtitle.orEmpty()
        dayCounterText.isVisible = rendered.subtitle != null
    }

    private fun checkForAppUpdate(manual: Boolean, force: Boolean = false) {
        if (manual) {
            showTransientMessage(R.string.update_checking)
        }
        val now = System.currentTimeMillis()
        if (!manual && !force && !updatePreferences.shouldAutomaticallyCheck(now)) {
            return
        }
        if (!manual) updatePreferences.markAttempted(now)
        appUpdateViewModel.check(manual)
    }

    private fun renderAppUpdateEvent(event: AppUpdateEvent) {
        if (event.result.isSuccess) {
            updatePreferences.markCheckCompleted(event.completedAt)
        }
        event.result.fold(
            onSuccess = { updateResult ->
                when (updateResult) {
                    AppUpdateCheckResult.Current -> {
                        availableUpdateRelease = null
                        updatePromptDialog?.dismiss()
                        updatePromptDialog = null
                        updatePreferences.clearAvailableRelease()
                        if (event.reportToUser) {
                            showTransientMessage(
                                getString(R.string.update_up_to_date, currentVersionLabel()),
                            )
                        }
                    }
                    is AppUpdateCheckResult.Available -> {
                        val release = updateResult.release
                        availableUpdateRelease = release
                        updatePreferences.cacheAvailableRelease(release)
                        maybeShowUpdatePrompt(release, manual = event.reportToUser)
                    }
                }
            },
            onFailure = {
                if (event.reportToUser) {
                    showTransientMessage(R.string.update_check_failed, Snackbar.LENGTH_LONG)
                }
            }
        )
    }

    private fun maybeShowUpdatePrompt(release: GitHubRelease, manual: Boolean) {
        if (isFinishing || isDestroyed) return
        if (updatePromptDialog?.isShowing == true) return
        if (updateProgressDialog?.isShowing == true) return
        val now = System.currentTimeMillis()
        if (!updatePreferences.shouldPrompt(release, manual, now)) return
        val hasApk = release.apkUrl != null
        val dialog = AlertDialog.Builder(this)
            .setTitle(getString(R.string.update_available_title, release.versionLabel))
            .setMessage(R.string.update_available_message)
            .setPositiveButton(
                if (hasApk) R.string.update_now else R.string.update_open_download,
            ) { _, _ ->
                updatePreferences.markPrompted(release.versionLabel, now)
                beginUpdate(release)
            }
            .setNegativeButton(R.string.update_later) { _, _ ->
                updatePreferences.markPrompted(release.versionLabel, now)
            }
            .setNeutralButton(R.string.update_skip_version) { _, _ ->
                updatePreferences.skipVersion(release.versionLabel)
            }
            .setOnCancelListener {
                updatePreferences.markPrompted(release.versionLabel, now)
            }
            .create()
        updatePromptDialog = dialog
        dialog.setOnDismissListener {
            if (updatePromptDialog === dialog) updatePromptDialog = null
        }
        dialog.show()
    }

    private fun showTransientMessage(
        @StringRes messageRes: Int,
        duration: Int = Snackbar.LENGTH_SHORT,
    ) {
        showTransientMessage(getString(messageRes), duration)
    }

    private fun showTransientMessage(
        message: String,
        duration: Int = Snackbar.LENGTH_SHORT,
    ) {
        Snackbar.make(findViewById(R.id.main_root), message, duration).show()
    }

    private fun beginUpdate(release: GitHubRelease) {
        if (release.apkUrl == null) {
            openUpdateUrl(release.pageUrl)
            return
        }
        if (!apkUpdateInstaller.canRequestPackageInstalls()) {
            pendingUpdatePermissionRelease = release
            try {
                requestUpdateInstallPermission.launch(apkUpdateInstaller.unknownSourcesSettingsIntent())
            } catch (_: ActivityNotFoundException) {
                pendingUpdatePermissionRelease = null
                Toast.makeText(this, R.string.update_install_permission_unavailable, Toast.LENGTH_LONG).show()
            }
            return
        }
        downloadAndInstallUpdate(release)
    }

    private fun downloadAndInstallUpdate(release: GitHubRelease) {
        if (updateDownloadJob?.isActive == true) return
        val progress = ProgressBar(this).apply {
            isIndeterminate = true
            val padding = (24 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
        }
        updateProgressDialog = AlertDialog.Builder(this)
            .setTitle(getString(R.string.update_downloading, release.versionLabel))
            .setView(progress)
            .setNegativeButton(R.string.cancel) { _, _ -> updateDownloadJob?.cancel() }
            .setCancelable(false)
            .show()
        updateDownloadJob = lifecycleScope.launch {
            runCatching { apkUpdateInstaller.downloadAndVerify(release) }
                .onSuccess { apk ->
                    updateProgressDialog?.dismiss()
                    updateProgressDialog = null
                    try {
                        startActivity(apkUpdateInstaller.installIntent(apk))
                    } catch (_: ActivityNotFoundException) {
                        Toast.makeText(
                            this@MainActivity,
                            R.string.update_installer_unavailable,
                            Toast.LENGTH_LONG,
                        ).show()
                    }
                }
                .onFailure { error ->
                    updateProgressDialog?.dismiss()
                    updateProgressDialog = null
                    if (error !is kotlinx.coroutines.CancellationException) {
                        AlertDialog.Builder(this@MainActivity)
                            .setTitle(R.string.update_download_failed_title)
                            .setMessage(error.localizedMessage ?: getString(R.string.update_download_failed))
                            .setPositiveButton(R.string.confirm, null)
                            .show()
                            .enableMessageSelection()
                    }
                }
            updateDownloadJob = null
        }
    }

    private fun openUpdateUrl(url: String) {
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                    addCategory(Intent.CATEGORY_BROWSABLE)
                },
            )
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, R.string.update_open_failed, Toast.LENGTH_LONG).show()
        }
    }

    private fun currentVersionLabel(): String = BuildConfig.VERSION_NAME.let { version ->
        if (version.startsWith("v", ignoreCase = true)) version else "v$version"
    }

    private fun renderSyncState(state: SyncRuntimeState) {
        syncStatus.text = when (state) {
            SyncRuntimeState.Loading -> getString(R.string.sync_loading)
            SyncRuntimeState.Unpaired -> getString(R.string.sync_unpaired)
            SyncRuntimeState.Idle -> getString(R.string.sync_ready)
            SyncRuntimeState.Running -> getString(R.string.sync_running)
            is SyncRuntimeState.Succeeded -> getString(
                R.string.sync_succeeded,
                state.summary.pushed,
                state.summary.pulled,
            )
            is SyncRuntimeState.Failed -> state.message
        }
    }


    private fun AlertDialog.enableMessageSelection(): AlertDialog = apply {
        findViewById<TextView>(android.R.id.message)?.enableReadOnlyTextSelection()
    }

    companion object {
        private const val MENU_REMINDER = 1
        private const val MENU_DAY_COUNTER = 2
        private const val MENU_CROSS_DEVICE = 3
        private const val MENU_CHECK_UPDATE = 6
        private const val MENU_AVAILABLE_UPDATE = 7
        private const val MENU_CATEGORIES = 8
        private const val MENU_TRASH = 9
        private const val NOTIFICATION_PERMISSION_STATE = "notification_permission_state"
        private const val KEY_NOTIFICATION_PERMISSION_REQUESTED = "requested"
    }
}
