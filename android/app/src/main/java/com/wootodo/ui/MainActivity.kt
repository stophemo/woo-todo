package com.wootodo.ui

import android.Manifest
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioGroup
import android.widget.ScrollView
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
import com.journeyapps.barcodescanner.ScanContract
import com.wootodo.BuildConfig
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.display.DayCounterPreferences
import com.wootodo.display.DayCounterSettings
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import com.wootodo.domain.QuestLine
import com.wootodo.reminder.ReminderPreferences
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.reminder.ReminderSettings
import com.wootodo.sync.Base64Url
import com.wootodo.sync.PairingDeepLink
import com.wootodo.sync.PairingPollPolicy
import com.wootodo.sync.ScannedConfiguration
import com.wootodo.sync.ScannedConfigurationParser
import com.wootodo.sync.SyncBackend
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.sync.SecureBytes
import com.wootodo.sync.WebDavCredentials
import com.wootodo.sync.WebDavEndpointPolicy
import com.wootodo.sync.WebDavSetupLink
import com.wootodo.sync.newWebDavIdentity
import com.wootodo.update.AppUpdateCheckResult
import com.wootodo.update.AppUpdateEvent
import com.wootodo.update.AppUpdatePolicy
import com.wootodo.update.AppUpdatePreferences
import com.wootodo.update.AppUpdateViewModel
import com.wootodo.update.ApkUpdateInstaller
import com.wootodo.update.GitHubRelease
import com.wootodo.widget.TodayWidgetUpdater
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {
    private lateinit var taskAdapter: TaskAdapter
    private lateinit var taskList: RecyclerView
    private lateinit var emptyView: TextView
    private lateinit var syncButton: Button
    private lateinit var syncStatus: TextView
    private lateinit var screenTitle: TextView
    private lateinit var dayCounterText: TextView
    private lateinit var scopeGroup: RadioGroup
    private var pairingDialog: AlertDialog? = null
    private var pairingSwitchDialog: AlertDialog? = null
    private var pairingMessageView: TextView? = null
    private var pairingCodeView: TextView? = null
    private var pairingEntryJob: Job? = null
    private val pairingEntryGeneration = PairingSessionGeneration()
    private var deepLinkIntentConsumed = false
    private var updateProgressDialog: AlertDialog? = null
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

    private val qrScanner = registerForActivityResult(ScanContract()) { result ->
        val source = result.contents
        if (source == null) {
            Toast.makeText(this, R.string.scan_qr_cancelled, Toast.LENGTH_SHORT).show()
        } else {
            handleScannedConfiguration(source)
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

    private val pairingViewModel: PairingViewModel by viewModels {
        PairingViewModel.Factory(application as WooTodoApplication)
    }

    private val appUpdateViewModel: AppUpdateViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        applySystemBarInsets(findViewById(R.id.main_root))
        availableUpdateRelease = updatePreferences.loadAvailableRelease(currentVersionLabel())
        taskList = findViewById(R.id.task_list)
        emptyView = findViewById(R.id.empty_view)
        syncButton = findViewById(R.id.sync_button)
        syncStatus = findViewById(R.id.sync_status)
        screenTitle = findViewById(R.id.screen_title)
        dayCounterText = findViewById(R.id.day_counter_text)
        syncStatus.enableReadOnlyTextSelection()
        dayCounterText.enableReadOnlyTextSelection()

        taskAdapter = TaskAdapter(
            onComplete = { viewModel.toggleCompletion(it.id) },
            onPass = { viewModel.settle(it.id, TaskStatus.PASS) },
            onEdit = { openEditor(it.id) },
        )
        taskList.apply {
            layoutManager = LinearLayoutManager(this@MainActivity)
            adapter = taskAdapter
        }
        attachReordering()

        scopeGroup = findViewById(R.id.scope_group)
        scopeGroup.setOnCheckedChangeListener { _, checkedId ->
            when (checkedId) {
                R.id.scope_tomorrow -> {
                    viewModel.selectTomorrow()
                }
                R.id.scope_week -> {
                    viewModel.selectScope(TaskTimeType.WEEK)
                }
                R.id.scope_month -> {
                    viewModel.selectScope(TaskTimeType.MONTH)
                }
                R.id.scope_leisure -> {
                    viewModel.selectScope(TaskTimeType.LEISURE)
                }
                else -> {
                    viewModel.selectToday()
                }
            }
            renderDayCounter()
        }
        findViewById<FloatingActionButton>(R.id.add_task).setOnClickListener { openEditor() }
        findViewById<Button>(R.id.insights_button).setOnClickListener {
            startActivity(Intent(this, InsightsActivity::class.java))
        }
        findViewById<Button>(R.id.reminder_settings_button).setOnClickListener { anchor ->
            showMoreMenu(anchor)
        }
        syncButton.setOnClickListener { handleSyncAction() }
        // 凭据在 Application 的后台初始化中读取；先按当前快照渲染，避免启动窗口仍可点击。
        renderSyncState((application as WooTodoApplication).syncRuntime.state.value)

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    viewModel.tasks.collect { tasks ->
                        taskAdapter.submitTasks(tasks)
                        emptyView.isVisible = tasks.isEmpty()
                    }
                }
                launch {
                    (application as WooTodoApplication).syncRuntime.state.collect(::renderSyncState)
                }
                launch {
                    pairingViewModel.state.collect(::renderPairingState)
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
        if (savedInstanceState == null) {
            applyInitialView(intent)
        } else {
            scopeGroup.check(
                savedInstanceState.getInt(STATE_SELECTED_SCOPE, R.id.scope_today),
            )
        }
        deepLinkIntentConsumed = savedInstanceState?.getBoolean(STATE_DEEP_LINK_INTENT_CONSUMED)
            ?: false
        val pairingWasActive = savedInstanceState?.getBoolean(STATE_PAIRING_ACTIVE) == true
        if (PairingRecoveryPolicy.requiresRescan(
                wasPairingInSavedState = pairingWasActive,
                runtimeStillActive = pairingViewModel.isPairingActive(),
            )
        ) {
            consumeDeepLinkIntent()
            pairingViewModel.recoverInterruptedPairing()
        } else if (!deepLinkIntentConsumed) {
            handleDeepLinkIntent(intent)
        } else {
            consumeDeepLinkIntent()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deepLinkIntentConsumed = false
        applyInitialView(intent)
        handleDeepLinkIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        viewModel.refresh()
        renderDayCounter()
    }

    override fun onStart() {
        super.onStart()
        DayCounterPreferences.addListener(dayCounterChangeListener)
    }

    override fun onStop() {
        DayCounterPreferences.removeListener(dayCounterChangeListener)
        super.onStop()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_PAIRING_ACTIVE, pairingViewModel.isPairingActive())
        outState.putBoolean(STATE_DEEP_LINK_INTENT_CONSUMED, deepLinkIntentConsumed)
        outState.putInt(STATE_SELECTED_SCOPE, scopeGroup.checkedRadioButtonId)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        pairingEntryJob?.cancel()
        pairingDialog?.dismiss()
        pairingSwitchDialog?.dismiss()
        updateProgressDialog?.dismiss()
        super.onDestroy()
    }

    private fun openEditor(taskId: String? = null) {
        startActivity(
            Intent(this, EditTaskActivity::class.java).apply {
                taskId?.let { putExtra(EditTaskActivity.EXTRA_TASK_ID, it) }
                putExtra(
                    EditTaskActivity.EXTRA_TIME_TYPE,
                    viewModel.selectedScope.value.rawValue,
                )
                if (viewModel.selectedScope.value == TaskTimeType.DAY) {
                    putExtra(
                        EditTaskActivity.EXTRA_TARGET_DATE,
                        viewModel.selectedReferenceDate.value.toString(),
                    )
                }
            },
        )
    }

    private fun applyInitialView(intent: Intent) {
        if (intent.getBooleanExtra(EXTRA_OPEN_TOMORROW, false)) {
            scopeGroup.check(R.id.scope_tomorrow)
        }
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

    private fun attachReordering() {
        val callback = object : ItemTouchHelper.Callback() {
            private var draggedLine: QuestLine? = null

            override fun isLongPressDragEnabled(): Boolean = true

            override fun getMovementFlags(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
            ): Int = if (taskAdapter.questLineAt(viewHolder.adapterPosition) != null) {
                makeMovementFlags(ItemTouchHelper.UP or ItemTouchHelper.DOWN, 0)
            } else {
                makeMovementFlags(0, 0)
            }

            override fun onMove(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                target: RecyclerView.ViewHolder,
            ): Boolean {
                val from = viewHolder.adapterPosition
                val to = target.adapterPosition
                val line = taskAdapter.questLineAt(from) ?: return false
                if (taskAdapter.questLineAt(to) != line) return false
                draggedLine = line
                return taskAdapter.moveItem(from, to)
            }

            override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) = Unit

            override fun clearView(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
            ) {
                super.clearView(recyclerView, viewHolder)
                draggedLine?.let { line ->
                    viewModel.reorder(taskAdapter.taskIdsForLine(line))
                }
                draggedLine = null
            }
        }
        ItemTouchHelper(callback).attachToRecyclerView(taskList)
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
            menu.add(0, MENU_REMINDER, order++, R.string.reminder_settings_title)
            menu.add(0, MENU_SYNC_METHOD, order++, R.string.sync_method_settings)
            menu.add(0, MENU_CHECK_UPDATE, order++, R.string.check_for_updates)
            setOnMenuItemClickListener { item ->
                when (item.itemId) {
                    MENU_AVAILABLE_UPDATE -> {
                        release?.let(::beginUpdate)
                    }
                    MENU_DAY_COUNTER -> showDayCounterSettings()
                    MENU_REMINDER -> showReminderSettings()
                    MENU_SYNC_METHOD -> showPairingMethodMenu(anchor)
                    MENU_CHECK_UPDATE -> checkForAppUpdate(manual = true)
                    else -> return@setOnMenuItemClickListener false
                }
                true
            }
            show()
        }
    }

    private fun scanMacConfiguration() {
        qrScanner.launch(WooTodoScanOptions.create(this))
    }

    private fun showPairingMethodMenu(anchor: View) {
        lifecycleScope.launch {
            val canSwitchToSavedWorker = withContext(Dispatchers.IO) {
                runCatching {
                    (application as WooTodoApplication).canSwitchToSavedWorkerOrLocalSync()
                }.getOrDefault(false)
            }
            if (!lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return@launch
            PopupMenu(this@MainActivity, anchor).apply {
                menuInflater.inflate(R.menu.pairing_methods, menu)
                menu.findItem(R.id.pairing_saved_worker).isVisible = canSwitchToSavedWorker
                setOnMenuItemClickListener { item ->
                    when (item.itemId) {
                        R.id.pairing_saved_worker -> switchToSavedWorkerOrLocalSync()
                        R.id.pairing_scan_qr -> scanMacConfiguration()
                        R.id.pairing_paste_link -> showPairingLinkInput()
                        R.id.pairing_manual_webdav -> showWebDavSettings()
                        else -> return@setOnMenuItemClickListener false
                    }
                    true
                }
                show()
            }
        }
    }

    private fun switchToSavedWorkerOrLocalSync() {
        showSyncSwitchConfirmation(
            messageRes = R.string.sync_switch_to_saved_worker_message,
            onConfirm = {
                lifecycleScope.launch {
                    val app = application as WooTodoApplication
                    val result = runCatching {
                        app.switchToSavedWorkerOrLocalSync()
                        when (val syncResult = app.synchronizeManually()) {
                            is SyncExecutionResult.Succeeded ->
                                getString(R.string.sync_switched_to_saved_worker)

                            is SyncExecutionResult.Failed -> if (syncResult.retryable) {
                                getString(R.string.sync_switched_to_saved_worker_retrying)
                            } else {
                                getString(R.string.sync_switched_to_saved_worker_failed)
                            }

                            SyncExecutionResult.NotConfigured ->
                                getString(R.string.sync_switched_to_saved_worker_pending)
                        }
                    }
                    Toast.makeText(
                        this@MainActivity,
                        result.getOrElse {
                            it.localizedMessage ?: getString(R.string.sync_switch_saved_worker_failed)
                        },
                        Toast.LENGTH_LONG,
                    ).show()
                }
            },
        )
    }

    private fun showPairingLinkInput() {
        val input = EditText(this).apply {
            hint = getString(R.string.pairing_link_input_hint)
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            enableEditableTextActions()
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.pairing_link_input_title)
            .setView(input)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.confirm) { _, _ ->
                val source = input.text.toString().trim()
                input.text.clear()
                handleConfigurationSource(source, R.string.pairing_link_input_invalid)
            }
            .show()
    }

    private fun handleScannedConfiguration(source: String) {
        handleConfigurationSource(source, R.string.scan_qr_invalid)
    }

    private fun handleConfigurationSource(source: String, @StringRes invalidMessageRes: Int) {
        when (val configuration = runCatching {
            ScannedConfigurationParser.parse(source)
        }.getOrNull()) {
            is ScannedConfiguration.WebDav -> showWebDavSettings(configuration.setupLink)
            is ScannedConfiguration.WorkerPairing -> {
                beginWorkerPairing(configuration.pairingLink)
            }
            null -> Toast.makeText(this, invalidMessageRes, Toast.LENGTH_LONG).show()
        }
    }

    private fun showWebDavSettings(setupLink: WebDavSetupLink? = null) {
        val importedVaultKey = setupLink?.let { link ->
            try {
                Base64Url.encode(link.vaultKey)
            } finally {
                link.vaultKey.fill(0)
            }
        }
        lifecycleScope.launch {
            val app = application as WooTodoApplication
            val existing = withContext(Dispatchers.IO) {
                runCatching { app.webDavCredentialsStore.load() }.getOrNull()
            }
            val workerSyncConfigured = withContext(Dispatchers.IO) {
                runCatching {
                    app.activeSyncBackend() == SyncBackend.WORKER_OR_LOCAL
                }.getOrDefault(false)
            }
            val generatedIdentity = newWebDavIdentity()
            val generatedKey = Base64Url.encode(SecureBytes.generate(32))
            val padding = (20 * resources.displayMetrics.density).toInt()
            val container = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(padding, 0, padding, 0)
            }
            fun field(hintRes: Int, value: String, password: Boolean = false): EditText =
                EditText(this@MainActivity).apply {
                    hint = getString(hintRes)
                    setText(value)
                    isSingleLine = true
                    inputType = if (password) {
                        InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                    } else {
                        InputType.TYPE_CLASS_TEXT
                    }
                    enableEditableTextActions()
                }
            val endpoint = TextView(this@MainActivity).apply {
                text = WebDavEndpointPolicy.ENDPOINT
                setPadding(0, padding / 2, 0, padding / 2)
                enableReadOnlyTextSelection()
            }
            val username = field(
                R.string.webdav_username_hint,
                setupLink?.username ?: existing?.username.orEmpty(),
            )
            val appPassword = field(
                R.string.webdav_app_password_hint,
                setupLink?.appPassword ?: existing?.appPassword.orEmpty(),
                password = true,
            )
            val vaultId = field(
                R.string.webdav_vault_id_hint,
                setupLink?.vaultId ?: existing?.vaultId ?: generatedIdentity.first,
            )
            val vaultKey = field(
                R.string.webdav_vault_key_hint,
                importedVaultKey ?: existing?.let { Base64Url.encode(it.vaultKey) } ?: generatedKey,
            )
            container.addView(endpoint)
            container.addView(username)
            container.addView(appPassword)
            container.addView(vaultId)
            container.addView(vaultKey)
            val scrollView = ScrollView(this@MainActivity).apply {
                isFillViewport = true
                addView(container)
            }

            AlertDialog.Builder(this@MainActivity)
                .setTitle(R.string.webdav_settings_title)
                .setMessage(
                    if (workerSyncConfigured) {
                        R.string.webdav_switch_message
                    } else if (setupLink == null) {
                        R.string.webdav_settings_message
                    } else {
                        R.string.webdav_setup_link_message
                    },
                )
                .setView(scrollView)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(
                    if (workerSyncConfigured) R.string.sync_switch_to_webdav else R.string.save,
                ) { _, _ ->
                    val configure: () -> Unit = {
                        lifecycleScope.launch {
                            val result = runCatching {
                                val credentials = WebDavCredentials(
                                    username = username.text.toString().trim(),
                                    appPassword = appPassword.text.toString(),
                                    vaultId = vaultId.text.toString().trim(),
                                    deviceId = existing?.deviceId ?: generatedIdentity.second,
                                    vaultKey = Base64Url.decode(vaultKey.text.toString().trim()),
                                )
                                credentials.validate()
                                app.configureWebDav(
                                    credentials,
                                    replacingWorkerSync = workerSyncConfigured,
                                )
                                when (val syncResult = app.synchronizeManually()) {
                                    is SyncExecutionResult.Succeeded ->
                                        getString(R.string.webdav_saved_and_synced)

                                    is SyncExecutionResult.Failed -> if (syncResult.retryable) {
                                        getString(R.string.webdav_saved_sync_retrying)
                                    } else {
                                        getString(R.string.webdav_saved_sync_failed)
                                    }

                                    SyncExecutionResult.NotConfigured ->
                                        getString(R.string.webdav_saved_sync_pending)
                                }
                            }
                            Toast.makeText(
                                this@MainActivity,
                                result.fold(
                                    onSuccess = { it },
                                    onFailure = {
                                        it.localizedMessage ?: getString(R.string.webdav_invalid)
                                    },
                                ),
                                Toast.LENGTH_LONG,
                            ).show()
                        }
                    }
                    if (workerSyncConfigured) {
                        showSyncSwitchConfirmation(
                            messageRes = R.string.sync_switch_to_webdav_message,
                            onConfirm = configure,
                        )
                    } else {
                        configure()
                    }
                }
                .show()
                .enableMessageSelection()
        }
    }

    private fun showDayCounterSettings() {
        TodayDisplaySettingsDialog.show(
            activity = this,
            initial = DayCounterPreferences.load(this),
            today = TaskDateRules.today(),
        ) { settings ->
            lifecycleScope.launch {
                val recorded = withContext(Dispatchers.IO) {
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
        val isToday = scopeGroup.checkedRadioButtonId == R.id.scope_today
        if (!isToday) {
            screenTitle.isVisible = true
            dayCounterText.isVisible = false
            screenTitle.setText(
                when (scopeGroup.checkedRadioButtonId) {
                    R.id.scope_tomorrow -> R.string.tomorrow_title
                    R.id.scope_week -> R.string.week_title
                    R.id.scope_month -> R.string.month_title
                    R.id.scope_leisure -> R.string.leisure_title
                    else -> R.string.today_title
                },
            )
            return
        }
        val rendered = DayCounterPreferences.render(this, TaskDateRules.today())
        screenTitle.text = rendered.header.orEmpty()
        screenTitle.isVisible = rendered.header != null
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
                        showTransientMessage(
                            getString(R.string.update_available_hint, release.versionLabel),
                        )
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

    private fun handleDeepLinkIntent(intent: Intent) {
        if (intent.action != Intent.ACTION_VIEW ||
            !intent.data?.scheme.equals("wootodo", ignoreCase = true)
        ) return
        val source = intent.dataString ?: return
        deepLinkIntentConsumed = true
        consumeDeepLinkIntent()
        when {
            intent.data?.host.equals("pair", ignoreCase = true) -> handlePairingDeepLink(source)
            intent.data?.host.equals("webdav", ignoreCase = true) -> handleWebDavSetupLink(source)
            else -> Toast.makeText(this, R.string.deep_link_invalid, Toast.LENGTH_SHORT).show()
        }
    }

    private fun handlePairingDeepLink(source: String) {
        val pairingLink = runCatching {
            PairingDeepLink.parse(source)
        }.getOrNull()
        if (pairingLink == null) {
            Toast.makeText(this, R.string.pairing_link_invalid, Toast.LENGTH_SHORT).show()
        } else {
            beginWorkerPairing(pairingLink)
        }
    }

    private fun beginWorkerPairing(link: PairingDeepLink) {
        pairingEntryJob?.cancel()
        pairingSwitchDialog?.dismiss()
        pairingSwitchDialog = null
        val generation = pairingEntryGeneration.advance()
        pairingViewModel.prepareForNewPairing()
        showTransientMessage(R.string.pairing_link_received, Snackbar.LENGTH_LONG)
        pairingEntryJob = lifecycleScope.launch {
            val replacingWebDav = withContext(Dispatchers.IO) {
                runCatching {
                    (application as WooTodoApplication).activeSyncBackend() == SyncBackend.WEB_DAV
                }.getOrDefault(false)
            }
            if (!pairingEntryGeneration.isCurrent(generation)) return@launch
            val begin = {
                if (pairingEntryGeneration.isCurrent(generation)) {
                    pairingViewModel.begin(link, deviceDisplayName())
                }
            }
            if (replacingWebDav) {
                pairingSwitchDialog = showSyncSwitchConfirmation(
                    messageRes = R.string.sync_switch_to_worker_message,
                    onConfirm = begin,
                )
            } else {
                begin()
            }
            pairingEntryJob = null
        }
    }

    private fun showSyncSwitchConfirmation(
        @StringRes messageRes: Int,
        onConfirm: () -> Unit,
    ): AlertDialog = AlertDialog.Builder(this)
        .setTitle(R.string.sync_switch_title)
        .setMessage(messageRes)
        .setNegativeButton(R.string.cancel, null)
        .setPositiveButton(R.string.sync_switch_confirm) { _, _ -> onConfirm() }
        .show()
        .enableMessageSelection()

    private fun handleWebDavSetupLink(source: String) {
        val setupLink = runCatching { WebDavSetupLink.parse(source) }.getOrNull()
        if (setupLink == null) {
            AlertDialog.Builder(this)
                .setTitle(R.string.webdav_link_invalid_title)
                .setMessage(R.string.webdav_link_invalid_message)
                .setPositiveButton(R.string.confirm, null)
                .show()
                .enableMessageSelection()
            return
        }
        Toast.makeText(this, R.string.webdav_link_received, Toast.LENGTH_SHORT).show()
        showWebDavSettings(setupLink)
    }

    private fun consumeDeepLinkIntent() {
        setIntent(
            Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
            },
        )
    }

    private fun deviceDisplayName(): String {
        val manufacturer = Build.MANUFACTURER.trim()
        val model = Build.MODEL.trim()
        return listOf(manufacturer, model)
            .filter { it.isNotBlank() }
            .distinctBy { it.lowercase() }
            .joinToString(" ")
            .ifBlank { getString(R.string.android_device_name) }
    }

    private fun synchronizeNow() {
        lifecycleScope.launch {
            val app = application as WooTodoApplication
            if (app.synchronizeManually() == SyncExecutionResult.NotConfigured) {
                Toast.makeText(
                    this@MainActivity,
                    R.string.sync_scan_pairing_first,
                    Toast.LENGTH_SHORT,
                ).show()
            }
        }
    }

    private fun handleSyncAction() {
        when ((application as WooTodoApplication).syncRuntime.state.value) {
            SyncRuntimeState.Loading,
            SyncRuntimeState.Running,
            -> Unit

            SyncRuntimeState.Unpaired -> showPairingMethodMenu(syncButton)
            else -> synchronizeNow()
        }
    }

    private fun renderSyncState(state: SyncRuntimeState) {
        syncButton.isEnabled = state != SyncRuntimeState.Loading && state != SyncRuntimeState.Running
        syncButton.setText(
            if (state == SyncRuntimeState.Unpaired) {
                R.string.sync_pairing_help
            } else {
                R.string.sync_now
            },
        )
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

    private fun renderPairingState(state: PairingUiState) {
        when (state) {
            PairingUiState.Idle -> dismissPairingProgress()
            PairingUiState.Claiming -> showPairingProgress(
                message = getString(R.string.pairing_claiming),
                verificationCode = null,
            )
            is PairingUiState.AwaitingConfirmation -> {
                val remainingMinutes = (
                    PairingPollPolicy.remainingSeconds(
                        System.currentTimeMillis(),
                        state.expiresAt,
                    ) + 59L
                    ) / 60L
                showPairingProgress(
                    message = getString(
                        R.string.pairing_verify_message,
                        remainingMinutes.coerceAtLeast(1L),
                    ),
                    verificationCode = state.verificationCode,
                )
            }
            PairingUiState.SavingCredentials -> showPairingProgress(
                message = getString(R.string.pairing_saving),
                verificationCode = null,
                allowCancel = false,
            )
            is PairingUiState.Succeeded -> {
                dismissPairingProgress()
                showTransientMessage(R.string.pairing_succeeded, Snackbar.LENGTH_LONG)
                pairingViewModel.acknowledgeTerminalState()
            }
            is PairingUiState.Failed -> {
                dismissPairingProgress()
                showTransientMessage(state.message, Snackbar.LENGTH_LONG)
                pairingViewModel.acknowledgeTerminalState()
            }
            PairingUiState.Interrupted -> {
                dismissPairingProgress()
                showTransientMessage(R.string.pairing_interrupted_message, Snackbar.LENGTH_LONG)
                pairingViewModel.acknowledgeTerminalState()
            }
        }
    }

    private fun showPairingProgress(
        message: String,
        verificationCode: String?,
        allowCancel: Boolean = true,
    ) {
        if (pairingDialog?.isShowing != true) {
            val padding = (24 * resources.displayMetrics.density).toInt()
            val container = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(padding, padding / 2, padding, 0)
            }
            pairingMessageView = TextView(this).apply {
                gravity = Gravity.CENTER
                textSize = 16f
                enableReadOnlyTextSelection()
            }
            pairingCodeView = TextView(this).apply {
                gravity = Gravity.CENTER
                textSize = 36f
                letterSpacing = 0.12f
                setPadding(0, padding / 2, 0, padding / 2)
                enableReadOnlyTextSelection()
            }
            container.addView(pairingMessageView)
            container.addView(pairingCodeView)
            container.addView(ProgressBar(this))
            pairingDialog = AlertDialog.Builder(this)
                .setTitle(R.string.pairing_title)
                .setView(container)
                .setNegativeButton(R.string.cancel) { _, _ -> pairingViewModel.cancel() }
                .setOnCancelListener { pairingViewModel.cancel() }
                .show()
        }
        pairingMessageView?.text = message
        pairingCodeView?.apply {
            text = verificationCode.orEmpty()
            isVisible = verificationCode != null
        }
        pairingDialog?.getButton(AlertDialog.BUTTON_NEGATIVE)?.isEnabled = allowCancel
    }

    private fun dismissPairingProgress() {
        pairingDialog?.dismiss()
        pairingDialog = null
        pairingMessageView = null
        pairingCodeView = null
    }

    private fun AlertDialog.enableMessageSelection(): AlertDialog = apply {
        findViewById<TextView>(android.R.id.message)?.enableReadOnlyTextSelection()
    }

    companion object {
        const val EXTRA_OPEN_TOMORROW = "open_tomorrow"
        private const val MENU_REMINDER = 1
        private const val MENU_DAY_COUNTER = 4
        private const val MENU_SYNC_METHOD = 5
        private const val MENU_CHECK_UPDATE = 6
        private const val MENU_AVAILABLE_UPDATE = 8
        private const val STATE_PAIRING_ACTIVE = "pairing_active"
        private const val STATE_DEEP_LINK_INTENT_CONSUMED = "deep_link_intent_consumed"
        private const val STATE_SELECTED_SCOPE = "selected_scope"
        private const val NOTIFICATION_PERMISSION_STATE = "notification_permission_state"
        private const val KEY_NOTIFICATION_PERMISSION_REQUESTED = "requested"
    }
}
