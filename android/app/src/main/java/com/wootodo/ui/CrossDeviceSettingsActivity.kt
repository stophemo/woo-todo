package com.wootodo.ui

import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.annotation.StringRes
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.data.LocalJoinDataSummary
import com.wootodo.sync.DevicePlatform
import com.wootodo.sync.JoinIdentityAdoption
import com.wootodo.sync.JoinPolicy
import com.wootodo.sync.JoinPolicyChoice
import com.wootodo.sync.JoinPolicyDecider
import com.wootodo.sync.JoinPreparation
import com.wootodo.sync.JoinPreparationResult
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.sync.WebDavAccount
import com.wootodo.sync.WebDavClaimInfo
import com.wootodo.sync.WebDavClaimSession
import com.wootodo.sync.WebDavClient
import com.wootodo.sync.WebDavStorageLayout
import com.wootodo.sync.WebDavCredentials
import com.wootodo.sync.WebDavDeviceInfo
import com.wootodo.sync.WebDavEndpointPolicy
import com.wootodo.sync.WebDavJoinSession
import com.wootodo.sync.WebDavJoinTarget
import com.wootodo.sync.WebDavOfferSession
import com.wootodo.sync.WebDavPairingCoordinator
import com.wootodo.sync.WebDavPairingStoreClient
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 唯一跨设备入口：WebDAV 账号、建立空间、六位码配对（Path A / Path B）、
 * 同步状态与退出空间。所有配对文件只包含公钥、设备名、vaultId 与密文。
 */
class CrossDeviceSettingsActivity : AppCompatActivity() {
    private enum class PanelMode {
        NONE,
        CLAIM_OFFER,
        SHOW_OFFER,
        JOIN_CREATOR,
        JOIN_APPROVER,
        CREATE_SPACE,
    }

    private data class WebDavProvider(
        @StringRes val titleRes: Int,
        @StringRes val hintRes: Int,
        val endpoint: String,
    )

    private lateinit var app: WooTodoApplication
    private lateinit var expiryTopHint: TextView
    private lateinit var setupHint: TextView
    private lateinit var accountSummary: TextView
    private lateinit var endpointSummary: TextView
    private lateinit var folderNote: TextView
    private lateinit var editAccount: Button
    private lateinit var accountForm: View
    private lateinit var providerSpinner: Spinner
    private lateinit var providerHint: TextView
    private lateinit var endpointInput: EditText
    private lateinit var usernameInput: EditText
    private lateinit var appPasswordInput: EditText
    private lateinit var saveAccount: Button
    private lateinit var connectionFeedback: View
    private lateinit var connectionProgress: ProgressBar
    private lateinit var connectionStatus: TextView
    private lateinit var noIdentitySection: View
    private lateinit var pairedSection: View
    private lateinit var spaceIdValue: TextView
    private lateinit var spaceDeviceValue: TextView
    private lateinit var spaceIdCopy: Button
    private lateinit var spaceSyncValue: TextView
    private lateinit var spaceLastSyncValue: TextView
    private lateinit var spaceSyncNow: Button
    private lateinit var devicesStatus: TextView
    private lateinit var devicesEmpty: TextView
    private lateinit var deviceList: LinearLayout
    private lateinit var pairingPanel: View
    private lateinit var panelTitle: TextView
    private lateinit var panelStatus: TextView
    private lateinit var panelCode: SixDigitCodeView
    private lateinit var panelVerificationGroup: View
    private lateinit var panelVerification: SixDigitCodeView
    private lateinit var panelExpiry: TextView
    private lateinit var panelPrimary: Button
    private lateinit var panelCancel: Button

    private val timeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    private var operationJob: Job? = null
    private var devicesJob: Job? = null
    @Volatile
    private var panelGeneration = 0
    private var panelMode = PanelMode.NONE
    private var panelCoordinator: WebDavPairingCoordinator? = null
    private var offerSession: WebDavOfferSession? = null
    private var claimInfo: WebDavClaimInfo? = null
    private var claimSession: WebDavClaimSession? = null
    private var joinSession: WebDavJoinSession? = null
    private var joinTarget: WebDavJoinTarget? = null
    private var joinPolicyDialog: AlertDialog? = null
    private var pendingJoinDecision: CompletableDeferred<JoinPolicyChoice>? = null
    private var pendingApproval: CompletableDeferred<Unit>? = null
    private var currentAccount: WebDavAccount? = null
    private var suppressProviderAutofill = false
    private var accountFormInitialized = false
    private val webDavProviders = listOf(
        WebDavProvider(
            titleRes = R.string.cross_device_webdav_provider_jianguoyun,
            hintRes = R.string.cross_device_webdav_provider_hint_jianguoyun,
            endpoint = "https://dav.jianguoyun.com/dav/",
        ),
        WebDavProvider(
            titleRes = R.string.cross_device_webdav_provider_nextcloud,
            hintRes = R.string.cross_device_webdav_provider_hint_nextcloud,
            endpoint = "",
        ),
        WebDavProvider(
            titleRes = R.string.cross_device_webdav_provider_synology,
            hintRes = R.string.cross_device_webdav_provider_hint_synology,
            endpoint = "",
        ),
        WebDavProvider(
            titleRes = R.string.cross_device_webdav_provider_custom,
            hintRes = R.string.cross_device_webdav_provider_hint_custom,
            endpoint = "",
        ),
    )
    private var currentCredentials: WebDavCredentials? = null
    private var lastSuccessfulSyncAt: Long? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as WooTodoApplication
        setContentView(R.layout.activity_cross_device_settings)
        applySystemBarInsets(findViewById(R.id.cross_device_root))
        bindViews()
        expiryTopHint.isVisible = false
        lastSuccessfulSyncAt = app.syncStatusPreferences.lastSuccessfulSyncAt()
        findViewById<View>(R.id.cross_device_back_button).setOnClickListener { finish() }
        bindActions()
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                app.syncRuntime.state.collect(::renderSyncState)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    override fun onDestroy() {
        hidePanel()
        super.onDestroy()
    }

    private fun bindViews() {
        expiryTopHint = findViewById(R.id.cross_device_expiry_top)
        setupHint = findViewById(R.id.webdav_setup_hint)
        accountSummary = findViewById(R.id.webdav_account_summary)
        endpointSummary = findViewById(R.id.webdav_endpoint_summary)
        folderNote = findViewById(R.id.webdav_folder_note)
        editAccount = findViewById(R.id.webdav_edit_account)
        accountForm = findViewById(R.id.webdav_account_form)
        providerSpinner = findViewById(R.id.webdav_provider_spinner)
        providerHint = findViewById(R.id.webdav_provider_hint)
        endpointInput = findViewById(R.id.webdav_endpoint_input)
        usernameInput = findViewById(R.id.webdav_username_input)
        appPasswordInput = findViewById(R.id.webdav_app_password_input)
        saveAccount = findViewById(R.id.webdav_save_account)
        connectionFeedback = findViewById(R.id.webdav_connection_feedback)
        connectionProgress = findViewById(R.id.webdav_connection_progress)
        connectionStatus = findViewById(R.id.webdav_connection_status)
        noIdentitySection = findViewById(R.id.no_identity_section)
        pairedSection = findViewById(R.id.paired_section)
        spaceIdValue = findViewById(R.id.space_id_value)
        spaceDeviceValue = findViewById(R.id.space_device_value)
        spaceIdCopy = findViewById(R.id.space_id_copy)
        spaceSyncValue = findViewById(R.id.space_sync_value)
        spaceLastSyncValue = findViewById(R.id.space_last_sync_value)
        spaceSyncNow = findViewById(R.id.space_sync_now)
        devicesStatus = findViewById(R.id.devices_status)
        devicesEmpty = findViewById(R.id.devices_empty)
        deviceList = findViewById(R.id.device_list)
        pairingPanel = findViewById(R.id.pairing_panel)
        panelTitle = findViewById(R.id.pairing_panel_title)
        panelStatus = findViewById(R.id.pairing_panel_status)
        panelCode = findViewById(R.id.pairing_panel_code)
        panelVerificationGroup = findViewById(R.id.pairing_panel_verification_group)
        panelVerification = findViewById(R.id.pairing_panel_verification)
        panelExpiry = findViewById(R.id.pairing_panel_expiry)
        panelPrimary = findViewById(R.id.pairing_panel_primary)
        panelCancel = findViewById(R.id.pairing_panel_cancel)
        panelCode.setEditable(false)
        panelVerification.setEditable(false)
    }

    private fun bindActions() {
        saveAccount.setOnClickListener { saveWebDavAccount() }
        providerSpinner.adapter = ArrayAdapter(
            this,
            android.R.layout.simple_spinner_item,
            webDavProviders.map { getString(it.titleRes) },
        ).apply {
            setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        }
        providerSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(
                parent: AdapterView<*>?,
                view: View?,
                position: Int,
                id: Long,
            ) {
                if (suppressProviderAutofill) return
                val provider = webDavProviders[position]
                providerHint.setText(provider.hintRes)
                if (provider.endpoint.isNotEmpty()) {
                    endpointInput.setText(provider.endpoint)
                }
            }

            override fun onNothingSelected(parent: AdapterView<*>?) = Unit
        }
        editAccount.setOnClickListener {
            val account = currentAccount ?: return@setOnClickListener
            endpointInput.setText(account.endpoint)
            usernameInput.setText(account.username)
            appPasswordInput.setText(account.appPassword)
            selectProvider(providerIndex(account.endpoint), applyEndpoint = false)
            accountFormInitialized = true
            accountSummary.isVisible = false
            endpointSummary.isVisible = false
            editAccount.isVisible = false
            accountForm.isVisible = true
            clearConnectionFeedback()
        }
        findViewById<View>(R.id.action_enter_code).setOnClickListener {
            startClaimOffer()
        }
        findViewById<View>(R.id.action_show_my_code).setOnClickListener {
            startJoinCreator()
        }
        findViewById<View>(R.id.action_create_space).setOnClickListener {
            confirmCreateSpace()
        }
        findViewById<View>(R.id.action_show_pairing_code).setOnClickListener {
            startShowOffer()
        }
        findViewById<View>(R.id.action_enter_new_device_code).setOnClickListener {
            startJoinApprover()
        }
        findViewById<View>(R.id.action_enter_join_code).setOnClickListener {
            startClaimOffer()
        }
        findViewById<View>(R.id.space_sync_now).setOnClickListener {
            synchronizeNow()
        }
        findViewById<View>(R.id.devices_refresh).setOnClickListener {
            loadDevices()
        }
        spaceIdCopy.setOnClickListener {
            val vaultId = currentCredentials?.vaultId ?: return@setOnClickListener
            val clipboard = getSystemService(ClipboardManager::class.java)
            clipboard?.setPrimaryClip(ClipData.newPlainText("Woo Todo", vaultId))
            showTransient(R.string.cross_device_space_id_copied)
        }
        findViewById<View>(R.id.action_leave_space).setOnClickListener {
            confirmLeaveSpace()
        }
    }

    private fun render() {
        lifecycleScope.launch {
            val account = withContext(Dispatchers.IO) { app.webDavAccount() }
            val credentials = withContext(Dispatchers.IO) {
                runCatching { app.activeSyncCredentials() }.getOrNull()
            }
            if (isFinishing || isDestroyed) return@launch
            currentAccount = account
            currentCredentials = credentials
            renderAccount(account)
            val hasIdentity = credentials != null
            noIdentitySection.isVisible = account != null && !hasIdentity
            pairedSection.isVisible = account != null && hasIdentity
            if (credentials != null) {
                renderSpaceCard(credentials)
                loadDevices()
            }
            renderSyncState(app.syncRuntime.state.value)
        }
    }

    private fun renderAccount(account: WebDavAccount?) {
        setupHint.isVisible = account == null
        expiryTopHint.isVisible = account != null
        if (account == null) {
            if (!accountFormInitialized) {
                accountFormInitialized = true
                if (endpointInput.text.isNullOrEmpty()) {
                    selectProvider(0, applyEndpoint = true)
                } else {
                    selectProvider(providerIndex(endpointInput.text.toString()), applyEndpoint = false)
                }
            }
            accountSummary.isVisible = false
            endpointSummary.isVisible = false
            folderNote.isVisible = false
            editAccount.isVisible = false
            accountForm.isVisible = true
            clearConnectionFeedback()
            return
        }
        accountFormInitialized = false
        accountSummary.isVisible = true
        endpointSummary.isVisible = true
        folderNote.isVisible = true
        editAccount.isVisible = true
        accountForm.isVisible = false
        accountSummary.text = getString(
            R.string.cross_device_webdav_account_format,
            account.username,
        )
        endpointSummary.text = getString(
            R.string.cross_device_webdav_endpoint_format,
            account.endpoint,
        )
        folderNote.text = if (WebDavStorageLayout.isAppFolder(account.endpoint)) {
            getString(R.string.cross_device_webdav_folder_note)
        } else {
            getString(R.string.cross_device_webdav_folder_legacy_note)
        }
    }

    private fun renderSpaceCard(credentials: WebDavCredentials) {
        spaceIdValue.text = getString(
            R.string.cross_device_space_id,
            shortVaultId(credentials.vaultId),
        )
        spaceDeviceValue.text = getString(
            R.string.cross_device_current_device_detail,
            DeviceName.current(this),
            platformLabel(DevicePlatform.ANDROID),
        )
    }

    private fun loadDevices() {
        devicesJob?.cancel()
        devicesStatus.isVisible = true
        devicesStatus.setText(R.string.cross_device_devices_loading)
        devicesEmpty.isVisible = false
        deviceList.isVisible = false
        devicesJob = lifecycleScope.launch {
            try {
                val devices = app.listWebDavDevices()
                if (isFinishing || isDestroyed) return@launch
                renderDevices(devices)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (isFinishing || isDestroyed) return@launch
                devicesStatus.isVisible = true
                devicesStatus.setText(R.string.cross_device_devices_failed)
            }
        }
    }

    private fun renderDevices(devices: List<WebDavDeviceInfo>) {
        val now = System.currentTimeMillis()
        val otherDevices = devices.filterNot { it.isCurrent }
        deviceList.removeAllViews()
        devicesStatus.isVisible = false
        deviceList.isVisible = otherDevices.isNotEmpty()
        otherDevices.forEach { device ->
            val row = layoutInflater.inflate(
                R.layout.item_cross_device_device,
                deviceList,
                false,
            )
            row.findViewById<TextView>(R.id.device_name).text = device.name
            row.findViewById<TextView>(R.id.device_meta).text = getString(
                R.string.cross_device_device_meta,
                platformLabel(device.platform),
                device.appVersion,
            )
            val lastSeen = getString(
                R.string.cross_device_device_last_seen,
                timeFormatter.format(
                    Instant.ofEpochMilli(device.lastSeenAt).atZone(ZoneId.systemDefault()),
                ),
            )
            row.findViewById<TextView>(R.id.device_last_seen).text =
                if (now - device.lastSeenAt > STALE_DEVICE_MILLIS) {
                    getString(R.string.cross_device_device_last_seen_stale, lastSeen)
                } else {
                    lastSeen
                }
            deviceList.addView(row)
        }
        devicesEmpty.isVisible = otherDevices.isEmpty()
    }

    private fun renderSyncState(state: SyncRuntimeState) {
        val text = when (state) {
            SyncRuntimeState.Loading -> getString(R.string.sync_loading)
            SyncRuntimeState.Unpaired -> getString(R.string.sync_unpaired_short)
            SyncRuntimeState.Idle -> getString(R.string.sync_ready)
            SyncRuntimeState.Running -> getString(R.string.sync_running)
            is SyncRuntimeState.Succeeded -> getString(
                R.string.sync_succeeded,
                state.summary.pushed,
                state.summary.pulled,
            )
            is SyncRuntimeState.Failed -> state.message
        }
        spaceSyncValue.text = text
        val running = state is SyncRuntimeState.Running
        spaceSyncNow.isEnabled = !running
        spaceSyncNow.setText(
            if (running) R.string.cross_device_sync_running else R.string.cross_device_sync_now,
        )
        if (state is SyncRuntimeState.Succeeded) {
            lastSuccessfulSyncAt = state.finishedAt
        }
        val lastSync = lastSuccessfulSyncAt
        spaceLastSyncValue.isVisible = lastSync != null && currentCredentials != null
        if (lastSync != null) {
            spaceLastSyncValue.text = getString(
                R.string.cross_device_last_sync,
                timeFormatter.format(
                    Instant.ofEpochMilli(lastSync).atZone(ZoneId.systemDefault()),
                ),
            )
        }
    }

    private fun selectProvider(position: Int, applyEndpoint: Boolean) {
        suppressProviderAutofill = true
        providerSpinner.setSelection(position, false)
        suppressProviderAutofill = false
        val provider = webDavProviders[position]
        providerHint.setText(provider.hintRes)
        if (applyEndpoint && provider.endpoint.isNotEmpty()) {
            endpointInput.setText(provider.endpoint)
        }
    }

    private fun providerIndex(endpoint: String): Int = when {
        endpoint.startsWith("https://dav.jianguoyun.com/") -> 0
        endpoint.contains("/remote.php/dav/") -> 1
        endpoint.contains(":5006") -> 2
        else -> 3
    }

    private fun saveWebDavAccount() {
        val endpoint = WebDavEndpointPolicy.normalize(endpointInput.text.toString())
        val username = usernameInput.text.toString()
        val password = appPasswordInput.text.toString()
        if (endpoint == null || username.isBlank() || password.isEmpty()) {
            showTransient(R.string.cross_device_webdav_account_invalid)
            return
        }
        val account = WebDavAccount(endpoint, username, password)
        showConnectionTesting()
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    app.saveWebDavAccount(account)
                }
                if (isFinishing || isDestroyed) return@launch
                endpointInput.setText("")
                usernameInput.setText("")
                appPasswordInput.setText("")
                clearConnectionFeedback()
                showTransient(R.string.cross_device_webdav_account_saved)
                render()
            } catch (error: Exception) {
                if (isFinishing || isDestroyed) return@launch
                showConnectionFailure(PairingErrorMessage.from(error))
            } finally {
                connectionProgress.isVisible = false
                saveAccount.isEnabled = true
            }
        }
    }

    private fun showConnectionTesting() {
        connectionFeedback.isVisible = true
        connectionProgress.isVisible = true
        connectionStatus.isVisible = true
        connectionStatus.setText(R.string.cross_device_webdav_connecting)
        connectionStatus.setTextColor(ContextCompat.getColor(this, R.color.muted))
        saveAccount.isEnabled = false
    }

    private fun showConnectionFailure(message: String) {
        connectionFeedback.isVisible = true
        connectionProgress.isVisible = false
        connectionStatus.isVisible = true
        connectionStatus.text = getString(
            R.string.cross_device_webdav_connection_failed,
            message,
        )
        connectionStatus.setTextColor(ContextCompat.getColor(this, R.color.orange_text))
        saveAccount.isEnabled = true
    }

    private fun clearConnectionFeedback() {
        connectionFeedback.isVisible = false
        connectionProgress.isVisible = false
        connectionStatus.isVisible = false
        connectionStatus.text = ""
        saveAccount.isEnabled = true
    }

    private fun confirmCreateSpace() {
        if (currentAccount == null) {
            showTransient(R.string.cross_device_webdav_account_required)
            return
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.cross_device_create_space)
            .setMessage(R.string.cross_device_create_space_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.cross_device_create_space) { _, _ ->
                createSpace()
            }
            .show()
    }

    private fun createSpace() {
        hidePanel()
        panelMode = PanelMode.CREATE_SPACE
        beginPanel(R.string.cross_device_create_space, getString(R.string.cross_device_creating_space))
        panelCode.isVisible = false
        panelPrimary.isVisible = false
        operationJob = lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    app.createWebDavSpace(DeviceName.current(this@CrossDeviceSettingsActivity))
                }
                if (isFinishing || isDestroyed) return@launch
                hidePanel()
                lastSuccessfulSyncAt = null
                showTransient(R.string.cross_device_space_created)
                render()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed) {
                    showPanelFailure(PairingErrorMessage.from(error))
                }
            }
        }
    }

    // ---------- Path A：已有设备显示码，新设备输入 ----------

    private fun startClaimOffer() {
        val account = currentAccount ?: run {
            showTransient(R.string.cross_device_webdav_account_required)
            return
        }
        hidePanel()
        panelMode = PanelMode.CLAIM_OFFER
        panelCoordinator = coordinatorFor(account)
        beginPanel(
            if (currentCredentials != null) {
                R.string.cross_device_enter_join_code
            } else {
                R.string.cross_device_enter_code
            },
            getString(R.string.cross_device_input_code_hint),
        )
        panelCode.isVisible = true
        panelCode.setCode("")
        panelCode.setEditable(true)
        panelCode.requestInputFocus()
        panelCancel.setOnClickListener { cancelPairingFlow() }
        panelPrimary.setText(R.string.pairing_short_code_pair)
        panelPrimary.isVisible = true
        panelPrimary.setOnClickListener {
            val code = panelCode.code
            if (code.length != 6) {
                panelCode.setError(true)
                setPanelStatus(getString(R.string.pairing_short_code_invalid), isError = true)
                return@setOnClickListener
            }
            claimOfferByCode(account, code)
        }
    }

    private fun claimOfferByCode(account: WebDavAccount, code: String) {
        val coordinator = panelCoordinator ?: return
        val generation = panelGeneration
        panelCode.setEditable(false)
        panelPrimary.isVisible = false
        setPanelStatus(getString(R.string.pairing_claiming))
        operationJob = lifecycleScope.launch {
            var session: WebDavClaimSession? = null
            try {
                val offer = withContext(Dispatchers.IO) { coordinator.findOffer(code) }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                // 先按本机身份/任务量确认数据基准，再写入 claim；需要清空时推迟到批准成功后。
                val clearLocalDataAfterApproval = when (
                    val result = joinPreparation().prepare(offer.deviceName, offer.platform)
                ) {
                    is JoinPreparationResult.Ready -> result.clearLocalDataAfterApproval
                    JoinPreparationResult.UseLocalData -> {
                        cancelJoinWithMessage(R.string.cross_device_join_use_local_hint)
                        return@launch
                    }
                    JoinPreparationResult.Cancelled -> {
                        cancelJoinWithMessage(R.string.cross_device_pairing_canceled)
                        return@launch
                    }
                }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                setPanelStatus(getString(R.string.pairing_claiming))
                session = withContext(Dispatchers.IO) {
                    coordinator.claimOffer(
                        offer,
                        DeviceName.current(this@CrossDeviceSettingsActivity),
                    )
                }
                claimSession = session
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                panelCode.isVisible = false
                showVerification(session.verificationCode)
                setPanelStatus(getString(R.string.cross_device_waiting_approval))
                // approval 到达后按加入策略清空本机数据并自动保存身份。
                val activeSession = session ?: return@launch
                val identity = joinIdentityAdoption(generation).awaitAndAdopt(
                    clearLocalDataAfterApproval = clearLocalDataAfterApproval,
                    awaitIdentity = {
                        withContext(Dispatchers.IO) {
                            coordinator.awaitOfferApproval(activeSession)
                        }.also {
                            claimSession = null
                            session = null
                        }
                    },
                )
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                lastSuccessfulSyncAt = null
                render()
                showTransient(
                    getString(R.string.cross_device_joined_space, shortVaultId(identity.vaultId)),
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (session != null) claimSession = session
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    showPanelFailure(PairingErrorMessage.from(error))
                }
            }
        }
    }

    private fun startShowOffer() {
        val credentials = currentCredentials ?: run {
            showTransient(R.string.cross_device_not_paired)
            return
        }
        hidePanel()
        val generation = panelGeneration
        panelMode = PanelMode.SHOW_OFFER
        val coordinator = coordinatorFor(credentials.account)
        panelCoordinator = coordinator
        beginPanel(
            R.string.cross_device_show_pairing_code,
            getString(R.string.pairing_short_code_creating),
        )
        panelCode.isVisible = true
        panelCode.setEditable(false)
        panelCancel.setOnClickListener { cancelPairingFlow() }
        var offer: WebDavOfferSession? = null
        var claim: WebDavClaimInfo? = null
        operationJob = lifecycleScope.launch {
            try {
                val created = withContext(Dispatchers.IO) {
                    coordinator.createOffer(credentials.identity, DeviceName.current(this@CrossDeviceSettingsActivity))
                }
                offer = created
                offerSession = created
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                panelCode.setCode(created.code)
                setPanelStatus(getString(R.string.pairing_short_code_waiting))
                val claimed = withContext(Dispatchers.IO) { coordinator.awaitOfferClaim(created) }
                claim = claimed
                claimInfo = claimed
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                showVerification(claimed.verificationCode)
                setPanelStatus(
                    getString(
                        R.string.cross_device_claimed_by_device,
                        claimed.deviceName,
                        platformLabel(claimed.platform),
                    ) + "\n" + getString(R.string.cross_device_approve_warning),
                )
                val confirmation = CompletableDeferred<Unit>()
                pendingApproval = confirmation
                panelPrimary.setText(R.string.cross_device_approve_device)
                panelPrimary.isVisible = true
                panelPrimary.setOnClickListener { confirmation.complete(Unit) }
                confirmation.await()
                pendingApproval = null
                if (!isCurrentPairing(generation)) return@launch
                panelCancel.isEnabled = false
                withContext(Dispatchers.IO) {
                    coordinator.approveOffer(created, claimed, credentials.identity)
                }
                offerSession = null
                claimInfo = null
                offer = null
                claim = null
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                showTransient(R.string.pairing_short_code_confirmed)
                synchronizeNow(quiet = true)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    val retryOffer = offer
                    val retryClaim = claim
                    if (retryOffer != null && retryClaim != null) {
                        showPanelFailure(PairingErrorMessage.from(error)) {
                            retryApproveOffer(coordinator, retryOffer, retryClaim, credentials)
                        }
                    } else {
                        showPanelFailure(PairingErrorMessage.from(error))
                    }
                }
            }
        }
    }

    private fun retryApproveOffer(
        coordinator: WebDavPairingCoordinator,
        offer: WebDavOfferSession,
        claim: WebDavClaimInfo,
        credentials: WebDavCredentials,
    ) {
        val generation = panelGeneration
        operationJob = lifecycleScope.launch {
            try {
                panelPrimary.isVisible = false
                withContext(Dispatchers.IO) {
                    coordinator.approveOffer(offer, claim, credentials.identity)
                }
                offerSession = null
                claimInfo = null
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                showTransient(R.string.pairing_short_code_confirmed)
                synchronizeNow(quiet = true)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    showPanelFailure(PairingErrorMessage.from(error)) {
                        retryApproveOffer(coordinator, offer, claim, credentials)
                    }
                }
            }
        }
    }

    // ---------- Path B：新设备显示码，已有设备输入并批准 ----------

    private fun startJoinCreator() {
        val account = currentAccount ?: run {
            showTransient(R.string.cross_device_webdav_account_required)
            return
        }
        hidePanel()
        val generation = panelGeneration
        panelMode = PanelMode.JOIN_CREATOR
        val coordinator = coordinatorFor(account)
        panelCoordinator = coordinator
        beginPanel(R.string.cross_device_show_my_code, getString(R.string.pairing_short_code_creating))
        panelCode.isVisible = true
        panelCode.setEditable(false)
        panelCancel.setOnClickListener { cancelPairingFlow() }
        operationJob = lifecycleScope.launch {
            var session: WebDavJoinSession? = null
            try {
                // 先按本机身份/任务量确认数据基准，再创建 join 配对文件；需要清空时推迟到批准成功后。
                val clearLocalDataAfterApproval = when (
                    val result = joinPreparation().prepare(null, null)
                ) {
                    is JoinPreparationResult.Ready -> result.clearLocalDataAfterApproval
                    JoinPreparationResult.UseLocalData -> {
                        cancelJoinWithMessage(R.string.cross_device_join_use_local_hint)
                        return@launch
                    }
                    JoinPreparationResult.Cancelled -> {
                        cancelJoinWithMessage(R.string.cross_device_pairing_canceled)
                        return@launch
                    }
                }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                setPanelStatus(getString(R.string.pairing_short_code_creating))
                session = withContext(Dispatchers.IO) {
                    coordinator.createJoin(DeviceName.current(this@CrossDeviceSettingsActivity))
                }
                joinSession = session
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                panelCode.setCode(session.code)
                setPanelStatus(getString(R.string.pairing_short_code_waiting))
                // approval 到达后按加入策略清空本机数据并自动保存身份。
                val activeSession = session ?: return@launch
                val identity = joinIdentityAdoption(generation).awaitAndAdopt(
                    clearLocalDataAfterApproval = clearLocalDataAfterApproval,
                    awaitIdentity = {
                        withContext(Dispatchers.IO) {
                            coordinator.awaitJoinCompletion(
                                session = activeSession,
                                onResolution = { resolution ->
                                    runOnUiThread {
                                        if (panelMode != PanelMode.JOIN_CREATOR ||
                                            !isCurrentPairing(generation)
                                        ) {
                                            return@runOnUiThread
                                        }
                                        showVerification(resolution.verificationCode)
                                        if (resolution.approverName != null) {
                                            setPanelStatus(
                                                getString(
                                                    R.string.cross_device_resolved_by_device,
                                                    resolution.approverName,
                                                ),
                                            )
                                        } else {
                                            setPanelStatus(
                                                getString(R.string.cross_device_waiting_approval),
                                            )
                                        }
                                    }
                                },
                            )
                        }.also {
                            joinSession = null
                            session = null
                        }
                    },
                )
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                lastSuccessfulSyncAt = null
                render()
                showTransient(
                    getString(R.string.cross_device_joined_space, shortVaultId(identity.vaultId)),
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    showPanelFailure(PairingErrorMessage.from(error))
                }
            }
        }
    }

    private fun startJoinApprover() {
        val credentials = currentCredentials ?: run {
            showTransient(R.string.cross_device_not_paired)
            return
        }
        hidePanel()
        panelMode = PanelMode.JOIN_APPROVER
        panelCoordinator = coordinatorFor(credentials.account)
        beginPanel(
            R.string.cross_device_enter_new_device_code,
            getString(R.string.cross_device_input_new_device_code_hint),
        )
        panelCode.isVisible = true
        panelCode.setCode("")
        panelCode.setEditable(true)
        panelCode.requestInputFocus()
        panelCancel.setOnClickListener { cancelPairingFlow() }
        panelPrimary.setText(R.string.pairing_short_code_pair)
        panelPrimary.isVisible = true
        panelPrimary.setOnClickListener {
            val code = panelCode.code
            if (code.length != 6) {
                panelCode.setError(true)
                setPanelStatus(getString(R.string.pairing_short_code_invalid), isError = true)
                return@setOnClickListener
            }
            resolveJoinByCode(credentials, code)
        }
    }

    private fun resolveJoinByCode(credentials: WebDavCredentials, code: String) {
        val coordinator = panelCoordinator ?: return
        val generation = panelGeneration
        panelCode.setEditable(false)
        panelPrimary.isVisible = false
        operationJob = lifecycleScope.launch {
            var target: WebDavJoinTarget? = null
            try {
                val join = withContext(Dispatchers.IO) { coordinator.findJoin(code) }
                target = withContext(Dispatchers.IO) {
                    coordinator.resolveJoin(
                        join,
                        credentials.identity,
                        DeviceName.current(this@CrossDeviceSettingsActivity),
                    )
                }
                joinTarget = target
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                showVerification(target.verificationCode)
                setPanelStatus(
                    getString(
                        R.string.cross_device_device_wants_to_join,
                        target.deviceName,
                        platformLabel(target.platform),
                    ) + "\n" + getString(R.string.cross_device_approve_warning),
                )
                val confirmation = CompletableDeferred<Unit>()
                pendingApproval = confirmation
                panelPrimary.setText(R.string.cross_device_approve_device)
                panelPrimary.isVisible = true
                panelPrimary.setOnClickListener { confirmation.complete(Unit) }
                confirmation.await()
                pendingApproval = null
                if (!isCurrentPairing(generation)) return@launch
                panelCancel.isEnabled = false
                withContext(Dispatchers.IO) {
                    coordinator.approveJoin(target, credentials.identity)
                }
                joinTarget = null
                target = null
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                showTransient(R.string.cross_device_device_approved)
                synchronizeNow(quiet = true)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (target != null) joinTarget = target
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    if (target != null) {
                        val retryTarget = target
                        showPanelFailure(PairingErrorMessage.from(error)) {
                            retryApproveJoin(coordinator, retryTarget, credentials)
                        }
                    } else {
                        showPanelFailure(PairingErrorMessage.from(error))
                    }
                }
            }
        }
    }

    private fun retryApproveJoin(
        coordinator: WebDavPairingCoordinator,
        target: WebDavJoinTarget,
        credentials: WebDavCredentials,
    ) {
        val generation = panelGeneration
        operationJob = lifecycleScope.launch {
            try {
                panelPrimary.isVisible = false
                withContext(Dispatchers.IO) {
                    coordinator.approveJoin(target, credentials.identity)
                }
                joinTarget = null
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                showTransient(R.string.cross_device_device_approved)
                synchronizeNow(quiet = true)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    showPanelFailure(PairingErrorMessage.from(error)) {
                        retryApproveJoin(coordinator, target, credentials)
                    }
                }
            }
        }
    }

    private fun joinPreparation(): JoinPreparation = JoinPreparation(
        policyFor = ::loadJoinPolicy,
        choose = ::askJoinPolicy,
    )

    /**
     * 配对批准成功后的本地收尾：需要清空时先删除旧身份、停止同步并原子清空任务，
     * 全部成功后才采纳新身份；任一步失败都会抛出且不会采纳新身份。
     */
    private fun joinIdentityAdoption(generation: Int): JoinIdentityAdoption =
        JoinIdentityAdoption(
            clearLocalData = {
                withContext(Dispatchers.Main) {
                    if (isCurrentPairing(generation) && !isFinishing && !isDestroyed) {
                        setPanelStatus(getString(R.string.cross_device_clearing_local_data))
                    }
                }
                withContext(Dispatchers.IO) { app.clearLocalTasksForJoin() }
            },
            adoptIdentity = { identity ->
                withContext(Dispatchers.Main) {
                    if (isCurrentPairing(generation) && !isFinishing && !isDestroyed) {
                        setPanelStatus(getString(R.string.pairing_saving))
                    }
                }
                withContext(Dispatchers.IO) { app.adoptWebDavIdentity(identity) }
            },
        )

    private suspend fun loadJoinPolicy(
        peerDeviceName: String?,
        peerPlatform: DevicePlatform?,
    ): JoinPolicy = withContext(Dispatchers.IO) {
        val identity = app.activeSyncCredentials()?.identity
        JoinPolicyDecider.decide(
            hasIdentity = identity != null,
            localVaultId = identity?.vaultId,
            lastSyncedAt = app.syncStatusPreferences.lastSuccessfulSyncAt(),
            peerDeviceName = peerDeviceName,
            peerPlatform = peerPlatform,
            localData = if (identity == null) {
                app.taskStore.localJoinDataSummary()
            } else {
                LocalJoinDataSummary()
            },
        )
    }

    private suspend fun askJoinPolicy(policy: JoinPolicy): JoinPolicyChoice =
        when (policy) {
            JoinPolicy.JoinDirectly -> JoinPolicyChoice.Continue
            is JoinPolicy.ClearLocalTasks -> showClearTasksDialog(policy.dataCount)
            is JoinPolicy.ChooseSpace -> showChooseSpaceDialog(policy)
        }

    private suspend fun showClearTasksDialog(dataCount: Int): JoinPolicyChoice {
        val gate = CompletableDeferred<JoinPolicyChoice>()
        val dialog = withContext(Dispatchers.Main) {
            AlertDialog.Builder(this@CrossDeviceSettingsActivity)
                .setTitle(R.string.cross_device_join_clear_title)
                .setMessage(
                    getString(R.string.cross_device_join_clear_message, dataCount),
                )
                .setPositiveButton(R.string.cross_device_join_clear_continue) { _, _ ->
                    gate.complete(JoinPolicyChoice.Continue)
                }
                .setNegativeButton(R.string.cancel) { _, _ ->
                    gate.complete(JoinPolicyChoice.Cancel)
                }
                .setOnCancelListener { gate.complete(JoinPolicyChoice.Cancel) }
                .create()
                .also {
                    joinPolicyDialog = it
                    pendingJoinDecision = gate
                    it.show()
                }
        }
        if (isFinishing || isDestroyed) {
            dialog.dismiss()
            throw CancellationException("页面已关闭")
        }
        return try {
            gate.await()
        } finally {
            if (joinPolicyDialog === dialog) joinPolicyDialog = null
            if (pendingJoinDecision === gate) pendingJoinDecision = null
            if (dialog.isShowing) dialog.dismiss()
        }
    }

    private suspend fun showChooseSpaceDialog(policy: JoinPolicy.ChooseSpace): JoinPolicyChoice {
        val gate = CompletableDeferred<JoinPolicyChoice>()
        val peer = if (policy.peerDeviceName != null && policy.peerPlatform != null) {
            "${policy.peerDeviceName} · ${platformLabel(policy.peerPlatform)}"
        } else {
            getString(R.string.cross_device_join_peer_unknown)
        }
        val lastSync = policy.lastSyncedAt?.let { lastSyncAt ->
            timeFormatter.format(
                Instant.ofEpochMilli(lastSyncAt).atZone(ZoneId.systemDefault()),
            )
        } ?: getString(R.string.cross_device_join_last_sync_never)
        val dialog = withContext(Dispatchers.Main) {
            AlertDialog.Builder(this@CrossDeviceSettingsActivity)
                .setTitle(R.string.cross_device_join_choose_title)
                .setMessage(
                    getString(
                        R.string.cross_device_join_choose_message,
                        shortVaultId(policy.localVaultId),
                        lastSync,
                        peer,
                    ),
                )
                .setPositiveButton(R.string.cross_device_join_choose_peer) { _, _ ->
                    gate.complete(JoinPolicyChoice.Continue)
                }
                .setNeutralButton(R.string.cross_device_join_choose_local) { _, _ ->
                    gate.complete(JoinPolicyChoice.UseLocalData)
                }
                .setNegativeButton(R.string.cancel) { _, _ ->
                    gate.complete(JoinPolicyChoice.Cancel)
                }
                .setOnCancelListener { gate.complete(JoinPolicyChoice.Cancel) }
                .create()
                .also {
                    joinPolicyDialog = it
                    pendingJoinDecision = gate
                    it.show()
                }
        }
        if (isFinishing || isDestroyed) {
            dialog.dismiss()
            throw CancellationException("页面已关闭")
        }
        return try {
            gate.await()
        } finally {
            if (joinPolicyDialog === dialog) joinPolicyDialog = null
            if (pendingJoinDecision === gate) pendingJoinDecision = null
            if (dialog.isShowing) dialog.dismiss()
        }
    }

    /** 结束本次加入并提示原因；hidePanel 会同时取消当前任务与清理配对文件。 */
    private fun cancelJoinWithMessage(@StringRes messageRes: Int) {
        hidePanel()
        showTransient(messageRes)
    }

    private fun synchronizeNow(quiet: Boolean = false) {
        if (app.syncRuntime.state.value is SyncRuntimeState.Running) return
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) { app.synchronizeManually() }
            if (isFinishing || isDestroyed) return@launch
            when (result) {
                is SyncExecutionResult.Succeeded ->
                    if (!quiet) showTransient(R.string.cross_device_sync_done)
                is SyncExecutionResult.Failed ->
                    showTransient(R.string.cross_device_sync_failed)
                SyncExecutionResult.NotConfigured ->
                    showTransient(R.string.cross_device_not_paired)
            }
        }
    }

    private fun confirmLeaveSpace() {
        val credentials = currentCredentials ?: return
        AlertDialog.Builder(this)
            .setTitle(R.string.cross_device_leave_confirm_title)
            .setMessage(R.string.cross_device_leave_confirm_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.cross_device_leave_confirm) { _, _ ->
                hidePanel()
                lifecycleScope.launch {
                    val result = withContext(Dispatchers.IO) {
                        runCatching { app.leaveSyncSpace() }
                    }
                    if (isFinishing || isDestroyed) return@launch
                    result.fold(
                        onSuccess = {
                            currentCredentials = null
                            lastSuccessfulSyncAt = null
                            spaceDeviceValue.text = ""
                            spaceSyncValue.text = ""
                            spaceLastSyncValue.isVisible = false
                            showTransient(R.string.cross_device_left_space)
                            render()
                        },
                        onFailure = {
                            showTransient(PairingErrorMessage.from(it))
                        },
                    )
                }
            }
            .show()
    }

    private fun coordinatorFor(account: WebDavAccount): WebDavPairingCoordinator =
        WebDavPairingCoordinator(WebDavPairingStoreClient(WebDavClient(account)))

    private fun beginPanel(@StringRes titleRes: Int, status: String) {
        pairingPanel.isVisible = true
        panelTitle.setText(titleRes)
        setPanelStatus(status)
        panelCode.isVisible = true
        panelCode.setCode("")
        panelCode.setEditable(false)
        panelVerificationGroup.isVisible = false
        panelVerification.setCode("")
        panelExpiry.isVisible = true
        panelExpiry.setText(R.string.cross_device_expiry_hint)
        panelPrimary.isVisible = false
        panelPrimary.isEnabled = true
        panelPrimary.setOnClickListener(null)
        panelCancel.isVisible = true
        panelCancel.isEnabled = true
        panelCancel.setText(R.string.cancel)
        panelCancel.setOnClickListener { cancelPairingFlow() }
        pairingPanel.post {
            findViewById<ScrollView>(R.id.cross_device_root)
                ?.smoothScrollTo(0, pairingPanel.top)
        }
    }

    private fun showVerification(code: String) {
        panelVerification.setCode(code)
        panelVerificationGroup.isVisible = true
    }

    private fun setPanelStatus(message: String, isError: Boolean = false) {
        panelStatus.text = message
        panelStatus.setTextColor(
            ContextCompat.getColor(this, if (isError) R.color.orange_text else R.color.muted),
        )
    }

    private fun showPanelFailure(message: String, retry: (() -> Unit)? = null) {
        setPanelStatus(message, isError = true)
        panelCancel.isEnabled = true
        if (retry != null) {
            panelPrimary.setText(R.string.retry)
            panelPrimary.isVisible = true
            panelPrimary.setOnClickListener {
                panelPrimary.isVisible = false
                panelPrimary.setOnClickListener(null)
                retry()
            }
        } else {
            panelPrimary.isVisible = false
        }
        panelCancel.isVisible = true
        panelCancel.setText(R.string.done)
        panelCancel.setOnClickListener { cancelPairingFlow() }
    }

    /**
     * 取消所有面板任务并清理本次写在 WebDAV 上的配对文件。先取消协程，
     * 避免与仍在进行的 approve/confirm 并发擦除会话密钥。
     */
    private fun hidePanel() {
        panelGeneration += 1
        val job = operationJob
        operationJob = null
        pendingApproval?.cancel()
        pendingApproval = null
        pendingJoinDecision?.cancel()
        pendingJoinDecision = null
        joinPolicyDialog?.dismiss()
        joinPolicyDialog = null
        val coordinator = panelCoordinator
        panelCoordinator = null
        val offer = offerSession
        offerSession = null
        val claim = claimInfo
        claimInfo = null
        val claimSessionToCancel = claimSession
        claimSession = null
        val join = joinSession
        joinSession = null
        val target = joinTarget
        joinTarget = null
        job?.cancel()
        val cleanup = {
            if (coordinator != null) {
                offer?.let { runCatching { coordinator.cancelOffer(it) } }
                claimSessionToCancel?.let { runCatching { coordinator.cancelClaim(it) } }
                claim?.destroy()
                join?.let { runCatching { coordinator.cancelJoin(it) } }
                target?.let { runCatching { coordinator.cancelJoinResolution(it) } }
            } else {
                offer?.destroy()
                claim?.destroy()
                claimSessionToCancel?.destroy()
                join?.destroy()
                target?.destroy()
            }
        }
        // 清理会访问 WebDAV，不能在主线程执行；即使 Activity 销毁也尽力删除配对文件。
        if (job == null || job.isCompleted) {
            Thread({ cleanup() }, "woo-todo-pairing-cleanup").start()
        } else {
            job.invokeOnCompletion {
                Thread({ cleanup() }, "woo-todo-pairing-cleanup").start()
            }
        }
        panelMode = PanelMode.NONE
        pairingPanel.isVisible = false
        panelVerificationGroup.isVisible = false
        panelCode.setCode("")
        panelVerification.setCode("")
        panelPrimary.setOnClickListener(null)
        panelCancel.setOnClickListener(null)
        panelCancel.isEnabled = true
    }

    private fun cancelPairingFlow() {
        val wasApprover = panelMode == PanelMode.JOIN_APPROVER
        hidePanel()
        showTransient(
            if (wasApprover) {
                R.string.cross_device_approver_canceled
            } else {
                R.string.cross_device_pairing_canceled
            },
        )
    }

    private fun isCurrentPairing(generation: Int): Boolean = generation == panelGeneration

    private fun shortVaultId(vaultId: String): String =
        if (vaultId.length <= 12) vaultId else "${vaultId.take(12)}…"

    private fun platformLabel(platform: DevicePlatform): String = getString(
        when (platform) {
            DevicePlatform.MACOS -> R.string.platform_macos
            DevicePlatform.ANDROID -> R.string.platform_android
            DevicePlatform.WINDOWS -> R.string.platform_windows
        },
    )

    private fun showTransient(@StringRes messageRes: Int) {
        Toast.makeText(this, messageRes, Toast.LENGTH_SHORT).show()
    }

    private fun showTransient(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private companion object {
        const val STALE_DEVICE_MILLIS = 30L * 24L * 60L * 60L * 1_000L
    }
}
