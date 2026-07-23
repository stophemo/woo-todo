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
import com.journeyapps.barcodescanner.ScanContract
import com.wootodo.BuildConfig
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.display.DayCounterPreferences
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import com.wootodo.domain.QuestLine
import com.wootodo.reminder.ReminderPreferences
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.reminder.ReminderSettings
import com.wootodo.sync.BackupPackageCodec
import com.wootodo.sync.BackupPackageException
import com.wootodo.sync.BackupTransferException
import com.wootodo.sync.Base64Url
import com.wootodo.sync.PairingDeepLink
import com.wootodo.sync.PairingPollPolicy
import com.wootodo.sync.ScannedConfiguration
import com.wootodo.sync.ScannedConfigurationParser
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.sync.SecureBytes
import com.wootodo.sync.WebDavCredentials
import com.wootodo.sync.WebDavEndpointPolicy
import com.wootodo.sync.WebDavSetupLink
import com.wootodo.sync.newWebDavIdentity
import com.wootodo.update.AppUpdateCheckResult
import com.wootodo.update.AppUpdateEvent
import com.wootodo.update.AppUpdatePreferences
import com.wootodo.update.AppUpdateViewModel
import com.wootodo.update.GitHubRelease
import com.wootodo.widget.TodayWidgetUpdater
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
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
    private var pairingTerminalDialog: AlertDialog? = null
    private var pairingMessageView: TextView? = null
    private var pairingCodeView: TextView? = null
    private var deepLinkIntentConsumed = false
    private var backupProgressDialog: AlertDialog? = null
    private var availableUpdateRelease: GitHubRelease? = null
    private val updatePreferences by lazy { AppUpdatePreferences(this) }

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

    private val createBackupDocument = registerForActivityResult(
        ActivityResultContracts.CreateDocument(BACKUP_MIME_TYPE),
    ) { uri ->
        if (uri == null) {
            backupFileViewModel.clearExport()
        } else {
            writePendingBackup(uri)
        }
    }

    private val openBackupDocument = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) {
            backupFileViewModel.clearImport()
        } else {
            readBackupForImport(uri)
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

    private val backupFileViewModel: BackupFileViewModel by viewModels()

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
            onComplete = { viewModel.settle(it.id, TaskStatus.COMPLETED) },
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
                appUpdateViewModel.events.collect(::renderAppUpdateEvent)
            }
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
        if (backupFileViewModel.importData() != null) {
            showBackupImportDialog()
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
        checkForAppUpdate(manual = false)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_PAIRING_ACTIVE, pairingViewModel.isPairingActive())
        outState.putBoolean(STATE_DEEP_LINK_INTENT_CONSUMED, deepLinkIntentConsumed)
        outState.putInt(STATE_SELECTED_SCOPE, scopeGroup.checkedRadioButtonId)
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        pairingDialog?.dismiss()
        pairingTerminalDialog?.dismiss()
        backupProgressDialog?.dismiss()
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
            menu.add(0, MENU_SCAN_MAC_WEBDAV, order++, R.string.scan_mac_webdav_qr)
            menu.add(0, MENU_WEBDAV, order++, R.string.webdav_settings_title)
            menu.add(0, MENU_CHECK_UPDATE, order++, R.string.check_for_updates)
            menu.add(0, MENU_EXPORT_BACKUP, order++, R.string.backup_export)
            menu.add(0, MENU_IMPORT_BACKUP, order, R.string.backup_import)
            setOnMenuItemClickListener { item ->
                when (item.itemId) {
                    MENU_AVAILABLE_UPDATE -> {
                        release?.let { openUpdateUrl(it.downloadUrl) }
                    }
                    MENU_DAY_COUNTER -> showDayCounterSettings()
                    MENU_REMINDER -> showReminderSettings()
                    MENU_SCAN_MAC_WEBDAV -> scanMacConfiguration()
                    MENU_WEBDAV -> showWebDavSettings()
                    MENU_CHECK_UPDATE -> checkForAppUpdate(manual = true)
                    MENU_EXPORT_BACKUP -> prepareBackupExport()
                    MENU_IMPORT_BACKUP -> prepareBackupImport()
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
        PopupMenu(this, anchor).apply {
            menuInflater.inflate(R.menu.pairing_methods, menu)
            setOnMenuItemClickListener { item ->
                when (item.itemId) {
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
                Toast.makeText(this, R.string.pairing_link_received, Toast.LENGTH_SHORT).show()
                pairingViewModel.begin(configuration.pairingLink, deviceDisplayName())
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
                    if (setupLink == null) {
                        R.string.webdav_settings_message
                    } else {
                        R.string.webdav_setup_link_message
                    },
                )
                .setView(scrollView)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.save) { _, _ ->
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
                            app.configureWebDav(credentials)
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
                                onFailure = { it.localizedMessage ?: getString(R.string.webdav_invalid) },
                            ),
                            Toast.LENGTH_LONG,
                        ).show()
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
            DayCounterPreferences.save(this, settings)
            renderDayCounter()
            TodayWidgetUpdater.updateAllAsync(applicationContext)
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

    private fun prepareBackupExport() {
        lifecycleScope.launch {
            val result = runCatching {
                (application as WooTodoApplication).hasBackupSyncCredentials()
            }
            result.fold(
                onSuccess = { hasSyncCredentials ->
                    showBackupExportDialog(
                        hasSyncCredentials = hasSyncCredentials,
                    )
                },
                onFailure = { showBackupError(it) },
            )
        }
    }

    private fun showBackupExportDialog(hasSyncCredentials: Boolean) {
        val padding = (20 * resources.displayMetrics.density).toInt()
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, 0, padding, 0)
        }
        val explanation = TextView(this).apply {
            setText(R.string.backup_export_message)
            setPadding(0, 0, 0, padding / 2)
        }
        val passphrase = passwordInput(R.string.backup_passphrase_hint)
        val confirmation = passwordInput(R.string.backup_passphrase_confirm_hint)
        val includeIdentity = SwitchCompat(this).apply {
            setText(R.string.backup_include_sync_identity)
            isChecked = false
            isEnabled = hasSyncCredentials
        }
        val identityNote = TextView(this).apply {
            setText(
                if (hasSyncCredentials) {
                    R.string.backup_identity_warning
                } else {
                    R.string.backup_identity_unavailable
                },
            )
            setPadding(0, 0, 0, padding / 2)
        }
        container.addView(explanation)
        container.addView(passphrase)
        container.addView(confirmation)
        container.addView(includeIdentity)
        container.addView(identityNote)

        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.backup_export_title)
            .setView(container)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.backup_choose_location, null)
            .create()
        dialog.setOnShowListener {
            fun beginExport() {
                val positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                positive.isEnabled = false
                passphrase.error = null
                confirmation.error = null
                lifecycleScope.launch {
                    showBackupProgress(R.string.backup_encrypting)
                    val result = runCatching {
                        (application as WooTodoApplication).createEncryptedBackup(
                            passphrase = passphrase.text.toString(),
                            confirmation = confirmation.text.toString(),
                            includeSyncCredentials = includeIdentity.isChecked,
                        )
                    }
                    dismissBackupProgress()
                    result.fold(
                        onSuccess = { data ->
                            passphrase.setText("")
                            confirmation.setText("")
                            dialog.dismiss()
                            backupFileViewModel.holdExport(data)
                            createBackupDocument.launch(backupFileName())
                        },
                        onFailure = { error ->
                            positive.isEnabled = true
                            when (error) {
                                is BackupTransferException.PassphraseMismatch ->
                                    confirmation.error = error.message

                                is BackupPackageException.InvalidPassphrase ->
                                    passphrase.error = error.message

                                else -> showBackupError(error)
                            }
                        },
                    )
                }
            }
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                beginExport()
            }
        }
        dialog.show()
    }

    private fun writePendingBackup(uri: Uri) {
        val data = backupFileViewModel.exportData()
        if (data == null) {
            showBackupError(IllegalStateException(getString(R.string.backup_export_interrupted)))
            return
        }
        lifecycleScope.launch {
            showBackupProgress(R.string.backup_writing)
            val result = runCatching {
                withContext(Dispatchers.IO) {
                    val output = contentResolver.openOutputStream(uri, "w")
                        ?: error(getString(R.string.backup_open_output_failed))
                    output.use {
                        it.write(data)
                        it.flush()
                    }
                }
            }
            if (result.isFailure) {
                withContext(Dispatchers.IO) {
                    runCatching { contentResolver.delete(uri, null, null) }
                }
            }
            backupFileViewModel.clearExport()
            dismissBackupProgress()
            result.fold(
                onSuccess = {
                    Toast.makeText(
                        this@MainActivity,
                        R.string.backup_export_succeeded,
                        Toast.LENGTH_LONG,
                    ).show()
                },
                onFailure = { showBackupError(it) },
            )
        }
    }

    private fun prepareBackupImport() {
        lifecycleScope.launch {
            val result = runCatching {
                (application as WooTodoApplication).requireBackupRestoreReady()
            }
            result.fold(
                onSuccess = {
                    backupFileViewModel.beginImport()
                    openBackupDocument.launch(BACKUP_MIME_TYPES)
                },
                onFailure = { showBackupError(it, R.string.backup_import_unavailable_title) },
            )
        }
    }

    private fun readBackupForImport(uri: Uri) {
        lifecycleScope.launch {
            showBackupProgress(R.string.backup_reading)
            val result = runCatching {
                withContext(Dispatchers.IO) { readBackupBytes(uri) }
            }
            dismissBackupProgress()
            result.fold(
                onSuccess = { data ->
                    backupFileViewModel.holdImport(data)
                    showBackupImportDialog()
                },
                onFailure = {
                    backupFileViewModel.clearImport()
                    showBackupError(it)
                },
            )
        }
    }

    private fun showBackupImportDialog() {
        if (backupFileViewModel.importData() == null) return
        val padding = (20 * resources.displayMetrics.density).toInt()
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, 0, padding, 0)
        }
        val explanation = TextView(this).apply {
            setText(R.string.backup_import_message)
            setPadding(0, 0, 0, padding / 2)
        }
        val passphrase = passwordInput(R.string.backup_passphrase_hint)
        container.addView(explanation)
        container.addView(passphrase)

        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.backup_import_title)
            .setView(container)
            .setNegativeButton(R.string.cancel) { _, _ ->
                backupFileViewModel.clearImport()
            }
            .setPositiveButton(R.string.backup_restore, null)
            .setOnCancelListener { backupFileViewModel.clearImport() }
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val data = backupFileViewModel.importData() ?: return@setOnClickListener
                val positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                positive.isEnabled = false
                passphrase.error = null
                lifecycleScope.launch {
                    showBackupProgress(R.string.backup_restoring)
                    val result = runCatching {
                        val app = application as WooTodoApplication
                        val restored = app.restoreEncryptedBackup(
                            data = data,
                            passphrase = passphrase.text.toString(),
                        )
                        getString(
                            if (restored.syncCredentialsRestored) {
                                R.string.backup_import_succeeded_with_sync
                            } else {
                                R.string.backup_import_succeeded
                            },
                            restored.restoredTaskCount,
                        )
                    }
                    dismissBackupProgress()
                    result.fold(
                        onSuccess = { successMessage ->
                            passphrase.setText("")
                            backupFileViewModel.clearImport()
                            dialog.dismiss()
                            viewModel.refresh()
                            Toast.makeText(
                                this@MainActivity,
                                successMessage,
                                Toast.LENGTH_LONG,
                            ).show()
                        },
                        onFailure = { error ->
                            positive.isEnabled = true
                            when (error) {
                                is BackupPackageException.AuthenticationFailed,
                                is BackupPackageException.InvalidPassphrase ->
                                    passphrase.error = error.message

                                else -> {
                                    backupFileViewModel.clearImport()
                                    dialog.dismiss()
                                    showBackupError(error)
                                }
                            }
                        },
                    )
                }
            }
        }
        dialog.show()
    }

    private fun passwordInput(hintRes: Int): EditText = EditText(this).apply {
        setHint(hintRes)
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        isSingleLine = true
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        enableEditableTextActions()
    }

    private fun readBackupBytes(uri: Uri): ByteArray {
        val input = contentResolver.openInputStream(uri)
            ?: error(getString(R.string.backup_open_input_failed))
        return input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8 * 1024)
            var total = 0
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                total += count
                if (total > BackupPackageCodec.MAXIMUM_FILE_BYTES) {
                    throw BackupPackageException.SnapshotTooLarge()
                }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }

    private fun showBackupProgress(titleRes: Int) {
        dismissBackupProgress()
        backupProgressDialog = AlertDialog.Builder(this)
            .setTitle(titleRes)
            .setView(ProgressBar(this))
            .setCancelable(false)
            .show()
    }

    private fun dismissBackupProgress() {
        backupProgressDialog?.dismiss()
        backupProgressDialog = null
    }

    private fun showBackupError(error: Throwable, titleRes: Int = R.string.backup_failed_title) {
        val message = when (error) {
            is BackupPackageException,
            is BackupTransferException -> error.message

            else -> null
        } ?: getString(R.string.backup_failed_message)
        AlertDialog.Builder(this)
            .setTitle(titleRes)
            .setMessage(message)
            .setPositiveButton(R.string.confirm, null)
            .show()
            .enableMessageSelection()
    }

    private fun backupFileName(): String {
        val timestamp = BACKUP_FILENAME_FORMAT.format(Instant.now())
        return "woo-todo-$timestamp.wootodo"
    }

    private fun checkForAppUpdate(manual: Boolean) {
        if (manual) {
            Toast.makeText(this, R.string.update_checking, Toast.LENGTH_SHORT).show()
        }
        val now = System.currentTimeMillis()
        if (!manual && !updatePreferences.shouldAutomaticallyCheck(now)) {
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
                            Toast.makeText(
                                this,
                                getString(R.string.update_up_to_date, currentVersionLabel()),
                                Toast.LENGTH_SHORT,
                            ).show()
                        }
                    }
                    is AppUpdateCheckResult.Available -> {
                        val release = updateResult.release
                        availableUpdateRelease = release
                        updatePreferences.cacheAvailableRelease(release)
                    }
                }
            },
            onFailure = {
                if (event.reportToUser) {
                    Toast.makeText(this, R.string.update_check_failed, Toast.LENGTH_LONG).show()
                }
            }
        )
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
        Toast.makeText(
            this,
            if (pairingLink != null) {
                R.string.pairing_link_received
            } else {
                R.string.pairing_link_invalid
            },
            Toast.LENGTH_SHORT,
        ).show()
        pairingLink?.let { pairingViewModel.begin(it, deviceDisplayName()) }
    }

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
                Toast.makeText(this, R.string.pairing_succeeded, Toast.LENGTH_SHORT).show()
                pairingViewModel.acknowledgeTerminalState()
            }
            is PairingUiState.Failed -> showPairingTerminalDialog(
                title = getString(R.string.pairing_failed_title),
                message = state.message,
            )
            PairingUiState.Interrupted -> showPairingTerminalDialog(
                title = getString(R.string.pairing_interrupted_title),
                message = getString(R.string.pairing_interrupted_message),
            )
        }
    }

    private fun showPairingProgress(
        message: String,
        verificationCode: String?,
        allowCancel: Boolean = true,
    ) {
        pairingTerminalDialog?.dismiss()
        pairingTerminalDialog = null
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

    private fun showPairingTerminalDialog(title: String, message: String) {
        dismissPairingProgress()
        if (pairingTerminalDialog?.isShowing == true) return
        pairingTerminalDialog = AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton(R.string.confirm) { _, _ ->
                pairingViewModel.acknowledgeTerminalState()
                pairingTerminalDialog = null
            }
            .setOnCancelListener {
                pairingViewModel.acknowledgeTerminalState()
                pairingTerminalDialog = null
            }
            .show()
            .enableMessageSelection()
    }

    private fun AlertDialog.enableMessageSelection(): AlertDialog = apply {
        findViewById<TextView>(android.R.id.message)?.enableReadOnlyTextSelection()
    }

    companion object {
        const val EXTRA_OPEN_TOMORROW = "open_tomorrow"
        private const val MENU_REMINDER = 1
        private const val MENU_EXPORT_BACKUP = 2
        private const val MENU_IMPORT_BACKUP = 3
        private const val MENU_DAY_COUNTER = 4
        private const val MENU_WEBDAV = 5
        private const val MENU_CHECK_UPDATE = 6
        private const val MENU_SCAN_MAC_WEBDAV = 7
        private const val MENU_AVAILABLE_UPDATE = 8
        private const val BACKUP_MIME_TYPE = "application/octet-stream"
        val BACKUP_MIME_TYPES = arrayOf(
            BACKUP_MIME_TYPE,
            "application/json",
            "application/vnd.woo-todo.backup",
        )
        val BACKUP_FILENAME_FORMAT: DateTimeFormatter = DateTimeFormatter
            .ofPattern("yyyyMMdd-HHmm")
            .withZone(ZoneId.systemDefault())
        private const val STATE_PAIRING_ACTIVE = "pairing_active"
        private const val STATE_DEEP_LINK_INTENT_CONSUMED = "deep_link_intent_consumed"
        private const val STATE_SELECTED_SCOPE = "selected_scope"
        private const val NOTIFICATION_PERMISSION_STATE = "notification_permission_state"
        private const val KEY_NOTIFICATION_PERMISSION_REQUESTED = "requested"
    }
}
