package com.wootodo.ui

import android.Manifest
import android.app.AlertDialog
import android.content.ClipData
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
import android.widget.TimePicker
import android.widget.Toast
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.PopupMenu
import androidx.appcompat.widget.SwitchCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.ItemTouchHelper
import com.google.android.material.floatingactionbutton.FloatingActionButton
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import com.wootodo.domain.QuestLine
import com.wootodo.reminder.ReminderPreferences
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.reminder.ReminderSettings
import com.wootodo.sync.BackupPackageCodec
import com.wootodo.sync.BackupPackageException
import com.wootodo.sync.BackupTransferException
import com.wootodo.sync.OfflineRelayShareFiles
import com.wootodo.sync.PairingDeepLink
import com.wootodo.sync.PairingPollPolicy
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.widget.TodayWidgetUpdater
import java.io.ByteArrayOutputStream
import java.io.File
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
    private lateinit var scopeGroup: RadioGroup
    private var pairingDialog: AlertDialog? = null
    private var pairingTerminalDialog: AlertDialog? = null
    private var pairingMessageView: TextView? = null
    private var pairingCodeView: TextView? = null
    private var pairingIntentConsumed = false
    private var backupProgressDialog: AlertDialog? = null

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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        applySystemBarInsets(findViewById(R.id.main_root))
        taskList = findViewById(R.id.task_list)
        emptyView = findViewById(R.id.empty_view)
        syncButton = findViewById(R.id.sync_button)
        syncStatus = findViewById(R.id.sync_status)
        screenTitle = findViewById(R.id.screen_title)

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
                    screenTitle.setText(R.string.tomorrow_title)
                    viewModel.selectTomorrow()
                }
                R.id.scope_week -> {
                    screenTitle.setText(R.string.week_title)
                    viewModel.selectScope(TaskTimeType.WEEK)
                }
                R.id.scope_month -> {
                    screenTitle.setText(R.string.month_title)
                    viewModel.selectScope(TaskTimeType.MONTH)
                }
                R.id.scope_leisure -> {
                    screenTitle.setText(R.string.leisure_title)
                    viewModel.selectScope(TaskTimeType.LEISURE)
                }
                else -> {
                    screenTitle.setText(R.string.today_title)
                    viewModel.selectToday()
                }
            }
        }
        findViewById<FloatingActionButton>(R.id.add_task).setOnClickListener { openEditor() }
        findViewById<Button>(R.id.insights_button).setOnClickListener {
            startActivity(Intent(this, InsightsActivity::class.java))
        }
        findViewById<Button>(R.id.reminder_settings_button).setOnClickListener { anchor ->
            showMoreMenu(anchor)
        }
        syncButton.setOnClickListener { handleSyncAction() }

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
        requestNotificationPermissionIfNeeded()
        if (savedInstanceState == null) {
            applyInitialView(intent)
        } else {
            scopeGroup.check(
                savedInstanceState.getInt(STATE_SELECTED_SCOPE, R.id.scope_today),
            )
        }
        pairingIntentConsumed = savedInstanceState?.getBoolean(STATE_PAIRING_INTENT_CONSUMED)
            ?: false
        val pairingWasActive = savedInstanceState?.getBoolean(STATE_PAIRING_ACTIVE) == true
        if (PairingRecoveryPolicy.requiresRescan(
                wasPairingInSavedState = pairingWasActive,
                runtimeStillActive = pairingViewModel.isPairingActive(),
            )
        ) {
            consumePairingIntent()
            pairingViewModel.recoverInterruptedPairing()
        } else if (!pairingIntentConsumed) {
            handlePairingIntent(intent)
        } else {
            consumePairingIntent()
        }
        if (backupFileViewModel.importData() != null) {
            showBackupImportDialog()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pairingIntentConsumed = false
        applyInitialView(intent)
        handlePairingIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        viewModel.refresh()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(STATE_PAIRING_ACTIVE, pairingViewModel.isPairingActive())
        outState.putBoolean(STATE_PAIRING_INTENT_CONSUMED, pairingIntentConsumed)
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
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
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
            menu.add(0, MENU_REMINDER, 0, R.string.reminder_settings_title)
            menu.add(0, MENU_EXPORT_RELAY, 1, R.string.offline_relay_export)
            menu.add(0, MENU_IMPORT_RELAY, 2, R.string.offline_relay_import)
            menu.add(0, MENU_EXPORT_BACKUP, 3, R.string.backup_export)
            menu.add(0, MENU_IMPORT_BACKUP, 4, R.string.backup_import)
            setOnMenuItemClickListener { item ->
                when (item.itemId) {
                    MENU_REMINDER -> showReminderSettings()
                    MENU_EXPORT_RELAY -> showBackupExportDialog(
                        hasSyncCredentials = false,
                        purpose = BackupExportPurpose.OFFLINE_RELAY,
                    )
                    MENU_IMPORT_RELAY -> prepareOfflineRelayImport()
                    MENU_EXPORT_BACKUP -> prepareBackupExport()
                    MENU_IMPORT_BACKUP -> prepareBackupImport()
                    else -> return@setOnMenuItemClickListener false
                }
                true
            }
            show()
        }
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
                        purpose = BackupExportPurpose.RECOVERY,
                    )
                },
                onFailure = { showBackupError(it) },
            )
        }
    }

    private fun showBackupExportDialog(
        hasSyncCredentials: Boolean,
        purpose: BackupExportPurpose,
    ) {
        val padding = (20 * resources.displayMetrics.density).toInt()
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, 0, padding, 0)
        }
        val explanation = TextView(this).apply {
            setText(
                if (purpose == BackupExportPurpose.OFFLINE_RELAY) {
                    R.string.offline_relay_export_message
                } else {
                    R.string.backup_export_message
                },
            )
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
        if (purpose == BackupExportPurpose.RECOVERY) {
            container.addView(includeIdentity)
            container.addView(identityNote)
        }

        val builder = AlertDialog.Builder(this)
            .setTitle(
                if (purpose == BackupExportPurpose.OFFLINE_RELAY) {
                    R.string.offline_relay_export_title
                } else {
                    R.string.backup_export_title
                },
            )
            .setView(container)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.backup_choose_location, null)
        if (purpose == BackupExportPurpose.OFFLINE_RELAY) {
            builder.setNeutralButton(R.string.offline_relay_share, null)
        }
        val dialog = builder.create()
        dialog.setOnShowListener {
            fun beginExport(shareAfterEncryption: Boolean) {
                val positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                val neutral = dialog.getButton(AlertDialog.BUTTON_NEUTRAL)
                positive.isEnabled = false
                neutral?.isEnabled = false
                passphrase.error = null
                confirmation.error = null
                lifecycleScope.launch {
                    showBackupProgress(R.string.backup_encrypting)
                    val result = runCatching {
                        (application as WooTodoApplication).createEncryptedBackup(
                            passphrase = passphrase.text.toString(),
                            confirmation = confirmation.text.toString(),
                            includeSyncCredentials = purpose == BackupExportPurpose.RECOVERY &&
                                includeIdentity.isChecked,
                        )
                    }
                    dismissBackupProgress()
                    result.fold(
                        onSuccess = { data ->
                            passphrase.setText("")
                            confirmation.setText("")
                            dialog.dismiss()
                            if (shareAfterEncryption) {
                                val shareResult = runCatching { shareOfflineRelay(data) }
                                data.fill(0)
                                shareResult.exceptionOrNull()?.let(::showBackupError)
                            } else {
                                backupFileViewModel.holdExport(data, purpose)
                                createBackupDocument.launch(backupFileName(purpose))
                            }
                        },
                        onFailure = { error ->
                            positive.isEnabled = true
                            neutral?.isEnabled = true
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
                beginExport(shareAfterEncryption = false)
            }
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL)?.setOnClickListener {
                beginExport(shareAfterEncryption = true)
            }
        }
        dialog.show()
    }

    private fun writePendingBackup(uri: Uri) {
        val data = backupFileViewModel.exportData()
        val purpose = backupFileViewModel.exportPurpose()
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
                        if (purpose == BackupExportPurpose.OFFLINE_RELAY) {
                            R.string.offline_relay_export_succeeded
                        } else {
                            R.string.backup_export_succeeded
                        },
                        Toast.LENGTH_LONG,
                    ).show()
                },
                onFailure = { showBackupError(it) },
            )
        }
    }

    private suspend fun shareOfflineRelay(data: ByteArray) {
        val uri = withContext(Dispatchers.IO) {
            val directory = File(cacheDir, OFFLINE_RELAY_CACHE_DIRECTORY)
            val file = OfflineRelayShareFiles.write(directory, data)
            FileProvider.getUriForFile(
                this@MainActivity,
                "${applicationContext.packageName}.files",
                file,
            )
        }
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = BACKUP_MIME_TYPE
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newUri(contentResolver, getString(R.string.offline_relay_export), uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, getString(R.string.offline_relay_share_title)))
    }

    private fun prepareBackupImport() {
        lifecycleScope.launch {
            val result = runCatching {
                (application as WooTodoApplication).requireBackupRestoreReady()
            }
            result.fold(
                onSuccess = {
                    backupFileViewModel.beginImport(BackupImportMode.RESTORE)
                    openBackupDocument.launch(BACKUP_MIME_TYPES)
                },
                onFailure = { showBackupError(it, R.string.backup_import_unavailable_title) },
            )
        }
    }

    private fun prepareOfflineRelayImport() {
        backupFileViewModel.beginImport(BackupImportMode.OFFLINE_RELAY)
        openBackupDocument.launch(BACKUP_MIME_TYPES)
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
        val mode = backupFileViewModel.importMode() ?: return
        val padding = (20 * resources.displayMetrics.density).toInt()
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, 0, padding, 0)
        }
        val explanation = TextView(this).apply {
            setText(
                if (mode == BackupImportMode.OFFLINE_RELAY) {
                    R.string.offline_relay_import_message
                } else {
                    R.string.backup_import_message
                },
            )
            setPadding(0, 0, 0, padding / 2)
        }
        val passphrase = passwordInput(R.string.backup_passphrase_hint)
        container.addView(explanation)
        container.addView(passphrase)

        val dialog = AlertDialog.Builder(this)
            .setTitle(
                if (mode == BackupImportMode.OFFLINE_RELAY) {
                    R.string.offline_relay_import_title
                } else {
                    R.string.backup_import_title
                },
            )
            .setView(container)
            .setNegativeButton(R.string.cancel) { _, _ ->
                backupFileViewModel.clearImport()
            }
            .setPositiveButton(
                if (mode == BackupImportMode.OFFLINE_RELAY) {
                    R.string.offline_relay_merge
                } else {
                    R.string.backup_restore
                },
                null,
            )
            .setOnCancelListener { backupFileViewModel.clearImport() }
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val data = backupFileViewModel.importData() ?: return@setOnClickListener
                val positive = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
                positive.isEnabled = false
                passphrase.error = null
                lifecycleScope.launch {
                    showBackupProgress(
                        if (mode == BackupImportMode.OFFLINE_RELAY) {
                            R.string.offline_relay_merging
                        } else {
                            R.string.backup_restoring
                        },
                    )
                    val result = runCatching {
                        val app = application as WooTodoApplication
                        if (mode == BackupImportMode.OFFLINE_RELAY) {
                            val merged = app.mergeEncryptedOfflineRelay(
                                data = data,
                                passphrase = passphrase.text.toString(),
                            )
                            getString(
                                R.string.offline_relay_import_succeeded,
                                merged.mergedTaskCount,
                                merged.mergedTombstoneCount,
                                merged.unchangedCount,
                            )
                        } else {
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
    }

    private fun backupFileName(purpose: BackupExportPurpose): String {
        val timestamp = BACKUP_FILENAME_FORMAT.format(Instant.now())
        val prefix = if (purpose == BackupExportPurpose.OFFLINE_RELAY) {
            "woo-todo-relay"
        } else {
            "woo-todo"
        }
        return "$prefix-$timestamp.wootodo"
    }

    private fun handlePairingIntent(intent: Intent) {
        if (intent.action != Intent.ACTION_VIEW || intent.data?.scheme != "wootodo") return
        val pairingLink = runCatching {
            PairingDeepLink.parse(requireNotNull(intent.dataString))
        }.getOrNull()
        pairingIntentConsumed = true
        consumePairingIntent()
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

    private fun consumePairingIntent() {
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
        if ((application as WooTodoApplication).syncRuntime.state.value == SyncRuntimeState.Unpaired) {
            AlertDialog.Builder(this)
                .setTitle(R.string.pairing_help_title)
                .setMessage(R.string.pairing_help_message)
                .setPositiveButton(R.string.confirm, null)
                .show()
        } else {
            synchronizeNow()
        }
    }

    private fun renderSyncState(state: SyncRuntimeState) {
        syncButton.isEnabled = state != SyncRuntimeState.Running
        syncButton.setText(
            if (state == SyncRuntimeState.Unpaired) {
                R.string.sync_pairing_help
            } else {
                R.string.sync_now
            },
        )
        syncStatus.text = when (state) {
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
            }
            pairingCodeView = TextView(this).apply {
                gravity = Gravity.CENTER
                textSize = 36f
                letterSpacing = 0.12f
                setPadding(0, padding / 2, 0, padding / 2)
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
    }

    companion object {
        const val EXTRA_OPEN_TOMORROW = "open_tomorrow"
        private const val MENU_REMINDER = 1
        private const val MENU_EXPORT_RELAY = 2
        private const val MENU_IMPORT_RELAY = 3
        private const val MENU_EXPORT_BACKUP = 4
        private const val MENU_IMPORT_BACKUP = 5
        private const val OFFLINE_RELAY_CACHE_DIRECTORY = "offline-relay"
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
        private const val STATE_PAIRING_INTENT_CONSUMED = "pairing_intent_consumed"
        private const val STATE_SELECTED_SCOPE = "selected_scope"
    }
}
