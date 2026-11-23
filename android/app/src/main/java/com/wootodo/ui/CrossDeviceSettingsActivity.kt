package com.wootodo.ui

import android.app.AlertDialog
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.viewModels
import androidx.annotation.StringRes
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.wootodo.BuildConfig
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.sync.CreateVaultRequest
import com.wootodo.sync.DevicePlatform
import com.wootodo.sync.DeviceRegistration
import com.wootodo.sync.JoinApprovalTarget
import com.wootodo.sync.JoinApproverCoordinator
import com.wootodo.sync.JoinCreationProgress
import com.wootodo.sync.JoinCreatorCoordinator
import com.wootodo.sync.PairingCodeClaim
import com.wootodo.sync.PairingCodeClaimResult
import com.wootodo.sync.PairingCodeCoordinator
import com.wootodo.sync.PairingCodeOffer
import com.wootodo.sync.PairingCompletion
import com.wootodo.sync.PairingException
import com.wootodo.sync.PairingPollPolicy
import com.wootodo.sync.SecureBytes
import com.wootodo.sync.SelfHostedEndpointPreferences
import com.wootodo.sync.SyncApiClient
import com.wootodo.sync.SyncCredentials
import com.wootodo.sync.SyncDeviceManager
import com.wootodo.sync.SyncEndpointPolicy
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.sync.SyncStatusPreferences
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
 * 唯一跨设备入口：未配对设备负责加入，已配对设备负责显示码、批准、设备管理和退出空间。
 */
class CrossDeviceSettingsActivity : AppCompatActivity() {
    private enum class PanelMode {
        NONE,
        CLAIM_CODE,
        SHOW_CODE,
        JOIN_CREATOR,
        JOIN_APPROVER,
        CREATE_SPACE,
    }

    private lateinit var app: WooTodoApplication
    private lateinit var unpairedSection: View
    private lateinit var pairedSection: View
    private lateinit var serverAddressValue: TextView
    private lateinit var serverAddressInput: EditText
    private lateinit var saveServerAddress: Button
    private lateinit var spaceIdValue: TextView
    private lateinit var spaceDeviceValue: TextView
    private lateinit var spaceEndpointValue: TextView
    private lateinit var spaceSyncValue: TextView
    private lateinit var spaceLastSyncValue: TextView
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

    private val selfHostedEndpoints by lazy { SelfHostedEndpointPreferences(this) }
    private val syncStatusPreferences by lazy { SyncStatusPreferences(this) }
    private val deviceManager by lazy { SyncDeviceManager() }
    private val pairingViewModel: PairingViewModel by viewModels {
        PairingViewModel.Factory(application as WooTodoApplication)
    }
    private val timeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    private var operationJob: Job? = null
    @Volatile
    private var panelGeneration = 0
    private var panelMode = PanelMode.NONE
    private var joinCreator: JoinCreatorCoordinator? = null
    @Volatile
    private var codeCoordinator: PairingCodeCoordinator? = null
    @Volatile
    private var approverCoordinator: JoinApproverCoordinator? = null
    @Volatile
    private var codeOffer: PairingCodeOffer? = null
    @Volatile
    private var codeClaim: PairingCodeClaim? = null
    @Volatile
    private var approvalTarget: JoinApprovalTarget? = null
    private var pendingConfirmation: CompletableDeferred<Unit>? = null
    private var currentCredentials: SyncCredentials? = null
    private var lastSuccessfulSyncAt: Long? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as WooTodoApplication
        setContentView(R.layout.activity_cross_device_settings)
        applySystemBarInsets(findViewById(R.id.cross_device_root))
        bindViews()
        lastSuccessfulSyncAt = syncStatusPreferences.lastSuccessfulSyncAt()
        findViewById<View>(R.id.cross_device_back_button).setOnClickListener { finish() }
        bindActions()
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    app.syncRuntime.state.collect(::renderSyncState)
                }
                launch {
                    pairingViewModel.state.collect(::renderClaimPairingState)
                }
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
        unpairedSection = findViewById(R.id.unpaired_section)
        pairedSection = findViewById(R.id.paired_section)
        serverAddressValue = findViewById(R.id.server_address_value)
        serverAddressInput = findViewById(R.id.server_address_input)
        saveServerAddress = findViewById(R.id.save_server_address)
        spaceIdValue = findViewById(R.id.space_id_value)
        spaceDeviceValue = findViewById(R.id.space_device_value)
        spaceEndpointValue = findViewById(R.id.space_endpoint_value)
        spaceSyncValue = findViewById(R.id.space_sync_value)
        spaceLastSyncValue = findViewById(R.id.space_last_sync_value)
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
        saveServerAddress.setOnClickListener {
            val normalized = SyncEndpointPolicy.normalize(serverAddressInput.text.toString())
            if (normalized == null) {
                showTransient(R.string.cross_device_server_address_invalid)
                return@setOnClickListener
            }
            runCatching { selfHostedEndpoints.save(normalized) }
                .onSuccess {
                    showTransient(R.string.cross_device_server_saved)
                    render()
                }
                .onFailure { showTransient(R.string.cross_device_server_address_invalid) }
        }
        findViewById<View>(R.id.action_enter_code).setOnClickListener {
            startClaimByCode()
        }
        findViewById<View>(R.id.action_show_my_code).setOnClickListener {
            startJoinCreator()
        }
        findViewById<View>(R.id.action_create_space).setOnClickListener {
            showCreateSpaceDialog()
        }
        findViewById<View>(R.id.action_show_pairing_code).setOnClickListener {
            startShowPairingCode()
        }
        findViewById<View>(R.id.action_enter_new_device_code).setOnClickListener {
            startApproveJoin()
        }
        findViewById<View>(R.id.space_sync_now).setOnClickListener {
            synchronizeNow()
        }
        findViewById<View>(R.id.action_leave_space).setOnClickListener {
            confirmLeaveSpace()
        }
    }

    private fun render() {
        lifecycleScope.launch {
            val credentials = withContext(Dispatchers.IO) { app.activeSyncCredentials() }
            if (isFinishing || isDestroyed) return@launch
            currentCredentials = credentials
            renderServerAddress(credentials)
            unpairedSection.isVisible = credentials == null
            pairedSection.isVisible = credentials != null
            if (credentials != null) {
                renderSpaceCard(credentials)
                refreshDevices(credentials)
            }
            renderSyncState(app.syncRuntime.state.value)
        }
    }

    private fun renderServerAddress(credentials: SyncCredentials?) {
        val builtIn = builtInEndpoint()
        val saved = selfHostedEndpoints.load()
        when {
            credentials != null -> {
                serverAddressValue.text = credentials.endpoint
                serverAddressInput.isVisible = false
                saveServerAddress.isVisible = false
            }
            builtIn != null -> {
                serverAddressValue.text = builtIn
                serverAddressInput.isVisible = false
                saveServerAddress.isVisible = false
            }
            else -> {
                serverAddressValue.text = if (saved == null) {
                    getString(R.string.cross_device_server_not_set)
                } else {
                    getString(R.string.cross_device_server_saved_short, saved)
                }
                serverAddressInput.isVisible = true
                saveServerAddress.isVisible = true
                if (serverAddressInput.text.isNullOrBlank()) {
                    serverAddressInput.setText(saved.orEmpty())
                }
            }
        }
    }

    private fun renderSpaceCard(credentials: SyncCredentials) {
        spaceIdValue.text = getString(
            R.string.cross_device_space_id,
            shortVaultId(credentials.vaultId),
        )
        spaceDeviceValue.text = getString(
            R.string.cross_device_current_device_detail,
            DeviceName.current(this),
            platformLabel(DevicePlatform.ANDROID),
        )
        spaceEndpointValue.text = getString(
            R.string.cross_device_server_address_format,
            credentials.endpoint,
        )
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

    private fun refreshDevices(credentials: SyncCredentials) {
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { deviceManager.listDevices(credentials) }
            }
            if (currentCredentials?.deviceId != credentials.deviceId) return@launch
            result.onSuccess { data ->
                val current = data.devices.firstOrNull { it.isCurrent }
                if (current != null) {
                    spaceDeviceValue.text = getString(
                        R.string.cross_device_current_device_detail,
                        current.name,
                        platformLabel(current.platform),
                    )
                }
                renderDeviceRows(credentials, data.devices)
            }
        }
    }

    private fun renderDeviceRows(
        credentials: SyncCredentials,
        devices: List<com.wootodo.sync.DeviceInfo>,
    ) {
        deviceList.removeAllViews()
        devices.filter { it.revokedAt == null }.forEach { device ->
            val row = layoutInflater.inflate(R.layout.item_cross_device, deviceList, false)
            row.findViewById<TextView>(R.id.device_name).text = device.name
            val details = buildList {
                add(platformLabel(device.platform))
                if (device.isCurrent) add(getString(R.string.cross_device_this_device))
                add(
                    getString(
                        R.string.cross_device_created_at,
                        timeFormatter.format(
                            Instant.ofEpochMilli(device.createdAt)
                                .atZone(ZoneId.systemDefault()),
                        ),
                    ),
                )
                add(
                    device.lastSeenAt?.let {
                        getString(
                            R.string.cross_device_last_seen,
                            timeFormatter.format(
                                Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault()),
                            ),
                        )
                    } ?: getString(R.string.cross_device_never_seen),
                )
            }
            row.findViewById<TextView>(R.id.device_detail).text = details.joinToString(" · ")
            val remove = row.findViewById<Button>(R.id.device_remove)
            remove.isVisible = !device.isCurrent
            remove.setOnClickListener {
                confirmRemoveDevice(credentials, device.id, device.name)
            }
            deviceList.addView(row)
        }
    }

    private fun startClaimByCode() {
        val endpoint = pairingEndpointOrNull() ?: return
        hidePanel()
        panelMode = PanelMode.CLAIM_CODE
        beginPanel(R.string.cross_device_enter_code, getString(R.string.cross_device_input_code_hint))
        panelCode.isVisible = true
        panelCode.setCode("")
        panelCode.setEditable(true)
        panelCode.requestInputFocus()
        panelPrimary.setText(R.string.pairing_short_code_pair)
        panelPrimary.isVisible = true
        panelPrimary.setOnClickListener {
            val code = panelCode.code
            if (code.length != 6) {
                panelCode.setError(true)
                setPanelStatus(getString(R.string.pairing_short_code_invalid), isError = true)
                return@setOnClickListener
            }
            panelCode.setEditable(false)
            panelPrimary.isVisible = false
            pairingViewModel.begin(
                endpoint = endpoint,
                shortCode = code,
                deviceName = DeviceName.current(this),
            )
        }
    }

    private fun renderClaimPairingState(state: PairingUiState) {
        if (panelMode != PanelMode.CLAIM_CODE) return
        when (state) {
            PairingUiState.Idle -> Unit
            PairingUiState.Claiming -> {
                panelCode.setEditable(false)
                setPanelStatus(getString(R.string.pairing_claiming))
            }
            is PairingUiState.AwaitingConfirmation -> {
                // state.expiresAt 已由 PairingCoordinator 换算成本机等待截止时间。
                val remainingMinutes = (
                    PairingPollPolicy.remainingSeconds(
                        System.currentTimeMillis(),
                        state.expiresAt,
                    ) + 59L
                    ) / 60L
                panelCode.isVisible = false
                showVerification(state.verificationCode)
                setPanelStatus(
                    getString(
                        R.string.pairing_verify_message,
                        remainingMinutes.coerceAtLeast(1L),
                    ),
                )
            }
            PairingUiState.SavingCredentials -> setPanelStatus(
                getString(R.string.pairing_saving),
            )
            is PairingUiState.Succeeded -> {
                hidePanel()
                pairingViewModel.acknowledgeTerminalState()
                lastSuccessfulSyncAt = null
                showTransient(R.string.pairing_succeeded)
                render()
            }
            is PairingUiState.Failed -> {
                showPanelFailure(state.message)
                pairingViewModel.acknowledgeTerminalState()
            }
            PairingUiState.Interrupted -> {
                hidePanel()
                pairingViewModel.acknowledgeTerminalState()
                showTransient(R.string.pairing_interrupted_message)
            }
        }
    }

    private fun startShowPairingCode() {
        val credentials = currentCredentials ?: run {
            showTransient(R.string.cross_device_not_paired)
            return
        }
        hidePanel()
        val generation = panelGeneration
        panelMode = PanelMode.SHOW_CODE
        beginPanel(R.string.cross_device_show_pairing_code, getString(R.string.pairing_short_code_creating))
        panelCode.isVisible = true
        panelCode.setEditable(false)
        val coordinator = PairingCodeCoordinator()
        codeCoordinator = coordinator
        operationJob = lifecycleScope.launch {
            val confirmation = CompletableDeferred<Unit>()
            pendingConfirmation = confirmation
            try {
                val offer = withContext(Dispatchers.IO) {
                    coordinator.create(credentials.endpoint, credentials)
                }
                codeOffer = offer
                if (panelMode != PanelMode.SHOW_CODE || !isCurrentPairing(generation)) return@launch
                panelCode.setCode(offer.shortCode)
                setPanelStatus(getString(R.string.pairing_short_code_waiting))

                val claim = withContext(Dispatchers.IO) {
                    when (val claimResult = coordinator.awaitClaim(offer, credentials)) {
                        is PairingCodeClaimResult.Claimed -> claimResult.claim
                        PairingCodeClaimResult.Confirmed -> null
                    }
                }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                if (claim != null) {
                    codeClaim = claim
                    showVerification(claim.verificationCode)
                    setPanelStatus(
                        getString(
                            R.string.cross_device_claimed_by_device,
                            claim.deviceName,
                            platformLabel(claim.platform),
                        ),
                    )
                    panelPrimary.setText(R.string.cross_device_confirm_binding)
                    panelPrimary.isVisible = true
                    panelPrimary.setOnClickListener { confirmation.complete(Unit) }
                    confirmation.await()
                    if (!isCurrentPairing(generation)) return@launch
                    // confirm 成功时由协调器擦除；失败时保留供重试。
                    confirmPairing(coordinator, offer, claim, credentials)
                }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                showTransient(R.string.pairing_short_code_confirmed)
                render()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    if (codeOffer != null && codeClaim != null) {
                        showPanelFailure(PairingErrorMessage.from(error)) {
                            retryPathAConfirm(credentials, generation)
                        }
                    } else {
                        showPanelFailure(PairingErrorMessage.from(error))
                    }
                }
            }
        }
    }

    /** 请求期间禁用取消，避免与仍在进行的 confirm 并发擦除密钥。 */
    private suspend fun confirmPairing(
        coordinator: PairingCodeCoordinator,
        offer: PairingCodeOffer,
        claim: PairingCodeClaim,
        credentials: SyncCredentials,
    ) {
        panelCancel.isEnabled = false
        try {
            withContext(Dispatchers.IO) {
                coordinator.confirm(offer, claim, credentials)
            }
        } finally {
            panelCancel.isEnabled = true
        }
    }

    private fun retryPathAConfirm(credentials: SyncCredentials, generation: Int) {
        val coordinator = codeCoordinator ?: return
        val offer = codeOffer ?: return
        val claim = codeClaim ?: return
        if (!isCurrentPairing(generation)) return
        panelPrimary.isVisible = false
        operationJob = lifecycleScope.launch {
            try {
                confirmPairing(coordinator, offer, claim, credentials)
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                showTransient(R.string.pairing_short_code_confirmed)
                render()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    showPanelFailure(PairingErrorMessage.from(error)) {
                        retryPathAConfirm(credentials, generation)
                    }
                }
            }
        }
    }

    private fun startJoinCreator() {
        val endpoint = pairingEndpointOrNull() ?: return
        hidePanel()
        val generation = panelGeneration
        panelMode = PanelMode.JOIN_CREATOR
        beginPanel(R.string.cross_device_show_my_code, getString(R.string.pairing_short_code_creating))
        panelCode.isVisible = true
        panelCode.setEditable(false)
        panelCancel.setOnClickListener { cancelPairingFlow() }
        val creator = JoinCreatorCoordinator(credentialsStore = app.syncCredentialsStore)
        joinCreator = creator
        operationJob = lifecycleScope.launch {
            try {
                val previousCredentials = withContext(Dispatchers.IO) {
                    app.syncCredentialsStore.load()
                }
                val completion = withContext(Dispatchers.IO) {
                    creator.awaitApproval(
                        endpoint = endpoint,
                        deviceName = DeviceName.current(this@CrossDeviceSettingsActivity),
                    ) { progress ->
                        runOnUiThread {
                            if (panelMode == PanelMode.JOIN_CREATOR &&
                                isCurrentPairing(generation)
                            ) {
                                renderJoinCreationProgress(progress)
                            }
                        }
                    }
                }
                withContext(Dispatchers.IO) {
                    finalizePairingChecked(completion, previousCredentials)
                }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                lastSuccessfulSyncAt = null
                showTransient(R.string.pairing_succeeded)
                render()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    showPanelFailure(PairingErrorMessage.from(error))
                }
            }
        }
    }

    private fun renderJoinCreationProgress(progress: JoinCreationProgress) {
        when (progress) {
            JoinCreationProgress.Creating -> setPanelStatus(
                getString(R.string.pairing_short_code_creating),
            )
            is JoinCreationProgress.AwaitingApproval -> {
                panelCode.setCode(progress.shortCode)
                setPanelStatus(getString(R.string.pairing_short_code_waiting))
            }
            is JoinCreationProgress.AwaitingConfirmation -> {
                showVerification(progress.verificationCode)
                if (progress.requiresConfirmation) {
                    // approved 先到：必须由本机用户核对后显式完成加入。
                    setPanelStatus(getString(R.string.cross_device_join_approved_verify))
                    panelPrimary.setText(R.string.cross_device_join_confirm)
                    panelPrimary.isVisible = true
                    panelPrimary.setOnClickListener {
                        panelPrimary.isVisible = false
                        panelPrimary.setOnClickListener(null)
                        panelCancel.isEnabled = false
                        joinCreator?.confirmApproved()
                    }
                } else {
                    setPanelStatus(getString(R.string.cross_device_join_verify_waiting))
                }
            }
            JoinCreationProgress.SavingCredentials -> {
                panelCancel.isEnabled = false
                setPanelStatus(getString(R.string.pairing_saving))
            }
        }
    }

    private fun startApproveJoin() {
        val credentials = currentCredentials ?: run {
            showTransient(R.string.cross_device_not_paired)
            return
        }
        hidePanel()
        val generation = panelGeneration
        panelMode = PanelMode.JOIN_APPROVER
        beginPanel(
            R.string.cross_device_enter_new_device_code,
            getString(R.string.cross_device_input_new_device_code_hint),
        )
        panelCode.isVisible = true
        panelCode.setCode("")
        panelCode.setEditable(true)
        panelCode.requestInputFocus()
        panelPrimary.setText(R.string.pairing_short_code_pair)
        panelPrimary.isVisible = true
        panelPrimary.setOnClickListener {
            val code = panelCode.code
            if (code.length != 6) {
                panelCode.setError(true)
                setPanelStatus(getString(R.string.pairing_short_code_invalid), isError = true)
                return@setOnClickListener
            }
            panelCode.setEditable(false)
            panelPrimary.isVisible = false
            resolveJoinForApproval(credentials, code, generation)
        }
    }

    private fun resolveJoinForApproval(
        credentials: SyncCredentials,
        shortCode: String,
        generation: Int,
    ) {
        val coordinator = JoinApproverCoordinator()
        approverCoordinator = coordinator
        operationJob = lifecycleScope.launch {
            try {
                val target = withContext(Dispatchers.IO) {
                    coordinator.resolve(credentials.endpoint, shortCode, credentials)
                }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) {
                    coordinator.discard(target)
                    return@launch
                }
                approvalTarget = target
                val confirmation = CompletableDeferred<Unit>()
                pendingConfirmation = confirmation
                showVerification(target.verificationCode)
                setPanelStatus(
                    getString(
                        R.string.cross_device_device_wants_to_join,
                        target.deviceName,
                        platformLabel(target.platform),
                    ),
                )
                panelPrimary.setText(R.string.cross_device_approve_device)
                panelPrimary.isVisible = true
                panelPrimary.setOnClickListener { confirmation.complete(Unit) }
                confirmation.await()
                if (!isCurrentPairing(generation)) return@launch
                approveJoinTarget(coordinator, target, credentials)
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                approvalTarget = null
                hidePanel()
                showTransient(R.string.cross_device_device_approved)
                refreshDevices(credentials)
                synchronizeNow(quiet = true)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    if (approvalTarget != null) {
                        showPanelFailure(PairingErrorMessage.from(error)) {
                            retryApproveJoin(credentials, generation)
                        }
                    } else {
                        showPanelFailure(PairingErrorMessage.from(error))
                    }
                }
            }
        }
    }

    /** 请求期间禁用取消，避免与仍在进行的 approve 并发擦除密钥。 */
    private suspend fun approveJoinTarget(
        coordinator: JoinApproverCoordinator,
        target: JoinApprovalTarget,
        credentials: SyncCredentials,
    ) {
        panelCancel.isEnabled = false
        try {
            withContext(Dispatchers.IO) {
                coordinator.approve(target, credentials)
            }
        } finally {
            panelCancel.isEnabled = true
        }
    }

    private fun retryApproveJoin(credentials: SyncCredentials, generation: Int) {
        val coordinator = approverCoordinator ?: return
        val target = approvalTarget ?: return
        if (!isCurrentPairing(generation)) return
        panelPrimary.isVisible = false
        operationJob = lifecycleScope.launch {
            try {
                approveJoinTarget(coordinator, target, credentials)
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                approvalTarget = null
                hidePanel()
                showTransient(R.string.cross_device_device_approved)
                refreshDevices(credentials)
                synchronizeNow(quiet = true)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    showPanelFailure(PairingErrorMessage.from(error)) {
                        retryApproveJoin(credentials, generation)
                    }
                }
            }
        }
    }

    private fun showCreateSpaceDialog() {
        val builtIn = builtInEndpoint()
        val saved = selfHostedEndpoints.load()
        val padding = (20 * resources.displayMetrics.density).toInt()
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding / 2, padding, 0)
        }
        val endpointInput = if (builtIn == null) {
            EditText(this).apply {
                hint = getString(R.string.cross_device_server_hint)
                setText(saved.orEmpty())
                isSingleLine = true
                inputType = android.text.InputType.TYPE_CLASS_TEXT or
                    android.text.InputType.TYPE_TEXT_VARIATION_URI
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            }.also(container::addView)
        } else {
            null
        }
        val inviteInput = EditText(this).apply {
            hint = getString(R.string.cross_device_invite_code_hint)
            isSingleLine = true
            inputType = android.text.InputType.TYPE_CLASS_TEXT
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
        }
        container.addView(inviteInput)
        val dialog = AlertDialog.Builder(this)
            .setTitle(R.string.cross_device_create_space)
            .setMessage(R.string.cross_device_create_space_message)
            .setView(container)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.cross_device_create_space, null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val endpoint = SyncEndpointPolicy.normalize(
                    builtIn ?: endpointInput?.text?.toString(),
                )
                val inviteCode = inviteInput.text.toString().trim()
                when {
                    endpoint == null -> showTransient(R.string.cross_device_server_address_invalid)
                    inviteCode.isEmpty() -> showTransient(R.string.cross_device_invite_code_required)
                    else -> {
                        if (builtIn == null) {
                            runCatching { selfHostedEndpoints.save(endpoint) }
                        }
                        dialog.dismiss()
                        createSpace(endpoint, inviteCode)
                    }
                }
            }
        }
        dialog.show()
    }

    private fun createSpace(endpoint: String, inviteCode: String) {
        hidePanel()
        val generation = panelGeneration
        panelMode = PanelMode.CREATE_SPACE
        beginPanel(R.string.cross_device_create_space, getString(R.string.cross_device_creating_space))
        panelCode.isVisible = false
        panelPrimary.isVisible = false
        panelCancel.setOnClickListener { hidePanel() }
        operationJob = lifecycleScope.launch {
            try {
                val previousCredentials = withContext(Dispatchers.IO) {
                    app.syncCredentialsStore.load()
                }
                if (previousCredentials != null &&
                    SyncEndpointPolicy.isValid(previousCredentials.endpoint)
                ) {
                    throw PairingException.AlreadyPaired
                }
                val vaultKey = SecureBytes.generate(32)
                val credentials = try {
                    val created = withContext(Dispatchers.IO) {
                        SyncApiClient(endpoint).createVault(
                            CreateVaultRequest(
                                device = DeviceRegistration(
                                    name = DeviceName.current(this@CrossDeviceSettingsActivity),
                                    platform = DevicePlatform.ANDROID,
                                ),
                            ),
                            inviteCode,
                        )
                    }
                    SyncCredentials(
                        endpoint = endpoint,
                        vaultId = created.vaultId,
                        deviceId = created.device.id,
                        deviceToken = created.device.token,
                        vaultKey = vaultKey,
                    ).also(SyncCredentials::validate)
                } finally {
                    vaultKey.fill(0)
                }
                if (!isCurrentPairing(generation)) return@launch
                withContext(Dispatchers.IO) {
                    if (!isCurrentPairing(generation)) return@withContext
                    if (previousCredentials == null) {
                        if (!app.syncCredentialsStore.saveIfAbsent(credentials)) {
                            throw PairingException.AlreadyPaired
                        }
                    } else {
                        app.syncCredentialsStore.save(credentials)
                    }
                    finalizePairingChecked(
                        PairingCompletion(
                            vaultId = credentials.vaultId,
                            deviceId = credentials.deviceId,
                            replacedExistingCredentials = previousCredentials != null,
                        ),
                        previousCredentials,
                    )
                }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                hidePanel()
                lastSuccessfulSyncAt = null
                showTransient(R.string.cross_device_space_created)
                render()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (!isFinishing && !isDestroyed && isCurrentPairing(generation)) {
                    showPanelFailure(PairingErrorMessage.from(error))
                }
            }
        }
    }

    /** finalizePairing 前确认凭据仍是本次配对写入的，避免回滚覆盖另一流程的成果。 */
    private suspend fun finalizePairingChecked(
        completion: PairingCompletion,
        previousCredentials: SyncCredentials?,
    ) {
        val stored = app.syncCredentialsStore.load()
        if (stored == null ||
            stored.deviceId != completion.deviceId ||
            stored.vaultId != completion.vaultId
        ) {
            throw PairingException.CredentialsOverwritten
        }
        app.finalizePairing(completion, previousCredentials)
    }

    private fun synchronizeNow(quiet: Boolean = false) {
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

    private fun confirmRemoveDevice(
        credentials: SyncCredentials,
        deviceId: String,
        deviceName: String,
    ) {
        AlertDialog.Builder(this)
            .setTitle(R.string.cross_device_remove_confirm_title)
            .setMessage(getString(R.string.cross_device_remove_confirm_message, deviceName))
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.cross_device_remove) { _, _ ->
                lifecycleScope.launch {
                    val result = withContext(Dispatchers.IO) {
                        runCatching { deviceManager.removeDevice(credentials, deviceId) }
                    }
                    if (isFinishing || isDestroyed) return@launch
                    if (result.isSuccess) {
                        showTransient(R.string.cross_device_device_removed)
                        refreshDevices(credentials)
                    } else {
                        showTransient(R.string.cross_device_device_remove_failed)
                    }
                }
            }
            .show()
    }

    private fun confirmLeaveSpace() {
        val credentials = currentCredentials ?: return
        AlertDialog.Builder(this)
            .setTitle(R.string.cross_device_leave_confirm_title)
            .setMessage(R.string.cross_device_leave_confirm_message)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.cross_device_leave_confirm) { _, _ ->
                lifecycleScope.launch {
                    val result = withContext(Dispatchers.IO) {
                        runCatching { app.leaveSyncSpace(credentials) }
                    }
                    if (isFinishing || isDestroyed) return@launch
                    result.fold(
                        onSuccess = {
                            currentCredentials = null
                            lastSuccessfulSyncAt = null
                            syncStatusPreferences.clear()
                            spaceDeviceValue.text = ""
                            deviceList.removeAllViews()
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
            ContextCompat.getColor(this, if (isError) R.color.orange else R.color.muted),
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
     * 取消所有面板任务并重置面板。operationJob 先取消、临时密钥等协程结束后再擦除，
     * 避免与仍在进行的 approve/confirm 并发销毁会话密钥。
     */
    private fun hidePanel() {
        panelGeneration += 1
        pairingViewModel.cancel()
        val job = operationJob
        operationJob = null
        pendingConfirmation?.cancel()
        pendingConfirmation = null
        val creator = joinCreator
        joinCreator = null
        val offer = codeOffer
        codeOffer = null
        val claim = codeClaim
        codeClaim = null
        val target = approvalTarget
        approvalTarget = null
        val code = codeCoordinator
        codeCoordinator = null
        val approver = approverCoordinator
        approverCoordinator = null
        job?.cancel()
        val cleanup = {
            if (offer != null && claim != null) {
                code?.discard(claim, offer) ?: run {
                    claim.destroy()
                    offer.destroy()
                }
            } else {
                offer?.destroy()
                claim?.destroy()
            }
            if (target != null) {
                approver?.discard(target) ?: target.destroy()
            }
        }
        if (job == null || job.isCompleted) {
            cleanup()
        } else {
            job.invokeOnCompletion { cleanup() }
        }
        if (creator != null) {
            lifecycleScope.launch { creator.cancelActive() }
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

    private fun pairingEndpointOrNull(): String? {
        val endpoint = SyncEndpointPolicy.resolvePreferredEndpoint(
            credentialsEndpoint = currentCredentials?.endpoint,
            buildEndpoint = BuildConfig.SYNC_WORKER_URL,
            savedEndpoint = selfHostedEndpoints.load(),
        )
        if (endpoint == null) {
            showTransient(R.string.cross_device_server_address_required)
        }
        return endpoint
    }

    private fun builtInEndpoint(): String? =
        SyncEndpointPolicy.normalize(BuildConfig.SYNC_WORKER_URL)

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
}
