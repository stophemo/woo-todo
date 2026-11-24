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
import androidx.annotation.StringRes
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.sync.DevicePlatform
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.sync.WebDavAccount
import com.wootodo.sync.WebDavClaimInfo
import com.wootodo.sync.WebDavClaimSession
import com.wootodo.sync.WebDavClient
import com.wootodo.sync.WebDavCredentials
import com.wootodo.sync.WebDavEndpointPolicy
import com.wootodo.sync.WebDavJoinSession
import com.wootodo.sync.WebDavJoinTarget
import com.wootodo.sync.WebDavOfferSession
import com.wootodo.sync.WebDavPairingConfirmation
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

    private lateinit var app: WooTodoApplication
    private lateinit var accountSummary: TextView
    private lateinit var editAccount: Button
    private lateinit var accountForm: View
    private lateinit var endpointInput: EditText
    private lateinit var usernameInput: EditText
    private lateinit var appPasswordInput: EditText
    private lateinit var saveAccount: Button
    private lateinit var noIdentitySection: View
    private lateinit var pairedSection: View
    private lateinit var spaceIdValue: TextView
    private lateinit var spaceDeviceValue: TextView
    private lateinit var spaceEndpointValue: TextView
    private lateinit var spaceSyncValue: TextView
    private lateinit var spaceLastSyncValue: TextView
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
    @Volatile
    private var panelGeneration = 0
    private var panelMode = PanelMode.NONE
    private var panelCoordinator: WebDavPairingCoordinator? = null
    private var offerSession: WebDavOfferSession? = null
    private var claimInfo: WebDavClaimInfo? = null
    private var claimSession: WebDavClaimSession? = null
    private var joinSession: WebDavJoinSession? = null
    private var joinTarget: WebDavJoinTarget? = null
    private var pendingConfirmation: CompletableDeferred<Unit>? = null
    private var currentAccount: WebDavAccount? = null
    private var currentCredentials: WebDavCredentials? = null
    private var lastSuccessfulSyncAt: Long? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = application as WooTodoApplication
        setContentView(R.layout.activity_cross_device_settings)
        applySystemBarInsets(findViewById(R.id.cross_device_root))
        bindViews()
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
        accountSummary = findViewById(R.id.webdav_account_summary)
        editAccount = findViewById(R.id.webdav_edit_account)
        accountForm = findViewById(R.id.webdav_account_form)
        endpointInput = findViewById(R.id.webdav_endpoint_input)
        usernameInput = findViewById(R.id.webdav_username_input)
        appPasswordInput = findViewById(R.id.webdav_app_password_input)
        saveAccount = findViewById(R.id.webdav_save_account)
        noIdentitySection = findViewById(R.id.no_identity_section)
        pairedSection = findViewById(R.id.paired_section)
        spaceIdValue = findViewById(R.id.space_id_value)
        spaceDeviceValue = findViewById(R.id.space_device_value)
        spaceEndpointValue = findViewById(R.id.space_endpoint_value)
        spaceSyncValue = findViewById(R.id.space_sync_value)
        spaceLastSyncValue = findViewById(R.id.space_last_sync_value)
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
        editAccount.setOnClickListener {
            val account = currentAccount ?: return@setOnClickListener
            endpointInput.setText(account.endpoint)
            usernameInput.setText(account.username)
            appPasswordInput.setText(account.appPassword)
            accountSummary.isVisible = false
            editAccount.isVisible = false
            accountForm.isVisible = true
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
        findViewById<View>(R.id.space_sync_now).setOnClickListener {
            synchronizeNow()
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
            }
            renderSyncState(app.syncRuntime.state.value)
        }
    }

    private fun renderAccount(account: WebDavAccount?) {
        if (account == null) {
            accountSummary.isVisible = false
            editAccount.isVisible = false
            accountForm.isVisible = true
            return
        }
        accountSummary.isVisible = true
        editAccount.isVisible = true
        accountForm.isVisible = false
        accountSummary.text = getString(
            R.string.cross_device_webdav_account_format,
            account.username,
            account.endpoint,
        )
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
        spaceEndpointValue.text = getString(
            R.string.cross_device_webdav_address_format,
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

    private fun saveWebDavAccount() {
        val endpoint = WebDavEndpointPolicy.normalize(endpointInput.text.toString())
        val username = usernameInput.text.toString()
        val password = appPasswordInput.text.toString()
        if (endpoint == null || username.isBlank() || password.isEmpty()) {
            showTransient(R.string.cross_device_webdav_account_invalid)
            return
        }
        val account = WebDavAccount(endpoint, username, password)
        saveAccount.isEnabled = false
        setPanelStatus(getString(R.string.cross_device_webdav_connecting))
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    WebDavClient(account).testConnection()
                    app.saveWebDavAccount(account)
                }
                if (isFinishing || isDestroyed) return@launch
                endpointInput.setText("")
                usernameInput.setText("")
                appPasswordInput.setText("")
                showTransient(R.string.cross_device_webdav_account_saved)
                render()
            } catch (error: Exception) {
                if (isFinishing || isDestroyed) return@launch
                showTransient(
                    getString(
                        R.string.cross_device_webdav_connection_failed,
                        PairingErrorMessage.from(error),
                    ),
                )
            } finally {
                saveAccount.isEnabled = true
            }
        }
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
        beginPanel(R.string.cross_device_enter_code, getString(R.string.cross_device_input_code_hint))
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
                session = withContext(Dispatchers.IO) {
                    coordinator.claimOffer(
                        offer,
                        DeviceName.current(this@CrossDeviceSettingsActivity),
                    )
                }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                claimSession = session
                panelCode.isVisible = false
                showVerification(session.verificationCode)
                setPanelStatus(getString(R.string.cross_device_waiting_approval))
                val identity = withContext(Dispatchers.IO) {
                    coordinator.awaitOfferApproval(session) { confirmation ->
                        confirmJoin(confirmation, generation, PanelMode.CLAIM_OFFER)
                    }
                }
                claimSession = null
                session = null
                withContext(Dispatchers.IO) { app.adoptWebDavIdentity(identity) }
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                session = null
                hidePanel()
                lastSuccessfulSyncAt = null
                showTransient(R.string.pairing_succeeded)
                render()
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
                    ),
                )
                val confirmation = CompletableDeferred<Unit>()
                pendingConfirmation = confirmation
                panelPrimary.setText(R.string.cross_device_confirm_binding)
                panelPrimary.isVisible = true
                panelPrimary.setOnClickListener { confirmation.complete(Unit) }
                confirmation.await()
                pendingConfirmation = null
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
            try {
                val session = withContext(Dispatchers.IO) {
                    coordinator.createJoin(DeviceName.current(this@CrossDeviceSettingsActivity))
                }
                joinSession = session
                if (!isCurrentPairing(generation) || isFinishing || isDestroyed) return@launch
                panelCode.setCode(session.code)
                setPanelStatus(getString(R.string.pairing_short_code_waiting))
                val identity = withContext(Dispatchers.IO) {
                    coordinator.awaitJoinCompletion(
                        session = session,
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
                                    setPanelStatus(getString(R.string.cross_device_waiting_approval))
                                }
                            }
                        },
                        confirm = { confirmation ->
                            confirmJoin(confirmation, generation, PanelMode.JOIN_CREATOR)
                        },
                    )
                }
                joinSession = null
                withContext(Dispatchers.IO) { app.adoptWebDavIdentity(identity) }
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
                    ),
                )
                val confirmation = CompletableDeferred<Unit>()
                pendingConfirmation = confirmation
                panelPrimary.setText(R.string.cross_device_approve_device)
                panelPrimary.isVisible = true
                panelPrimary.setOnClickListener { confirmation.complete(Unit) }
                confirmation.await()
                pendingConfirmation = null
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

    /**
     * 新设备解封 vaultKey 后必须由本机用户核对六位核对码、对端设备与空间指纹，
     * 点击“核对一致，完成加入”后才返回，让调用方继续保存身份。
     */
    private suspend fun confirmJoin(
        confirmation: WebDavPairingConfirmation,
        generation: Int,
        mode: PanelMode,
    ) {
        withContext(Dispatchers.Main) {
            if (panelMode != mode || !isCurrentPairing(generation) ||
                isFinishing || isDestroyed
            ) {
                throw CancellationException("配对面板已关闭")
            }
            showVerification(confirmation.verificationCode)
            val peer = confirmation.peerDeviceName
            val platform = confirmation.peerPlatform
            setPanelStatus(
                when {
                    peer != null && platform != null -> getString(
                        R.string.cross_device_verify_peer_with_platform,
                        peer,
                        platformLabel(platform),
                        shortVaultId(confirmation.vaultId),
                    )
                    peer != null -> getString(
                        R.string.cross_device_verify_peer,
                        peer,
                        shortVaultId(confirmation.vaultId),
                    )
                    else -> getString(
                        R.string.cross_device_verify_space,
                        shortVaultId(confirmation.vaultId),
                    )
                },
            )
            val gate = CompletableDeferred<Unit>()
            pendingConfirmation = gate
            panelPrimary.setText(R.string.cross_device_confirm_join)
            panelPrimary.isVisible = true
            panelPrimary.setOnClickListener { gate.complete(Unit) }
            try {
                gate.await()
            } finally {
                if (pendingConfirmation === gate) pendingConfirmation = null
                panelPrimary.isVisible = false
                panelPrimary.setOnClickListener(null)
            }
            setPanelStatus(getString(R.string.pairing_saving))
        }
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
     * 取消所有面板任务并清理本次写在 WebDAV 上的配对文件。先取消协程，
     * 避免与仍在进行的 approve/confirm 并发擦除会话密钥。
     */
    private fun hidePanel() {
        panelGeneration += 1
        val job = operationJob
        operationJob = null
        pendingConfirmation?.cancel()
        pendingConfirmation = null
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
}
