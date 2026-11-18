package com.wootodo.ui

import android.app.AlertDialog
import android.view.LayoutInflater
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.wootodo.R
import com.wootodo.sync.Base64Url
import com.wootodo.sync.BearerCredential
import com.wootodo.sync.CreatePairingRequest
import com.wootodo.sync.PairingConfirmRequest
import com.wootodo.sync.PairingKeyPair
import com.wootodo.sync.PairingSessionCrypto
import com.wootodo.sync.PairingStatus
import com.wootodo.sync.SyncApiClient
import com.wootodo.sync.SyncApiException
import com.wootodo.sync.SyncCredentials
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Android 作为发起方显示六位码：保留现有 X25519 配对与六位核对码，
 * 让另一台设备输入短码后认领，由本机确认并传递同步密钥。
 */
object ShortCodePairingDialog {
    fun show(
        activity: AppCompatActivity,
        credentials: SyncCredentials,
        onFinished: () -> Unit = {},
    ) {
        val content = LayoutInflater.from(activity)
            .inflate(R.layout.dialog_short_code_pairing, null)
        val codeView = content.findViewById<SixDigitCodeView>(R.id.short_code_value)
        val statusView = content.findViewById<TextView>(R.id.short_code_status)
        val expiryView = content.findViewById<TextView>(R.id.short_code_expiry)
        val verificationGroup = content.findViewById<LinearLayout>(
            R.id.short_code_verification_group,
        )
        val verificationView = content.findViewById<SixDigitCodeView>(
            R.id.short_code_verification,
        )
        val confirmButton = content.findViewById<MaterialButton>(R.id.short_code_confirm)
        val cancelButton = content.findViewById<MaterialButton>(R.id.short_code_cancel)
        val dialog = AlertDialog.Builder(activity)
            .setView(content)
            .create()
        dialog.setCanceledOnTouchOutside(false)
        val confirmation = CompletableDeferred<Unit>()
        var job: Job? = null
        var finished = false
        codeView.setEditable(false)
        verificationView.setEditable(false)

        fun updateStatus(text: String, isError: Boolean = false) {
            if (activity.isFinishing || activity.isDestroyed) return
            statusView.text = text
            statusView.setTextColor(
                ContextCompat.getColor(
                    activity,
                    if (isError) R.color.orange else R.color.muted,
                ),
            )
        }

        fun finishDialog() {
            confirmButton.visibility = View.GONE
            expiryView.visibility = View.GONE
            cancelButton.text = activity.getString(R.string.done)
        }

        fun complete(message: String) {
            if (finished) return
            finished = true
            if (activity.isFinishing || activity.isDestroyed) return
            updateStatus(message)
            finishDialog()
            onFinished()
        }

        fun fail(message: String) {
            if (finished) return
            finished = true
            if (activity.isFinishing || activity.isDestroyed) return
            updateStatus(message, isError = true)
            finishDialog()
        }

        cancelButton.setOnClickListener {
            job?.cancel()
            dialog.dismiss()
        }
        confirmButton.setOnClickListener {
            confirmButton.visibility = View.GONE
            confirmation.complete(Unit)
        }
        dialog.setOnDismissListener {
            job?.cancel()
            job = null
        }

        job = activity.lifecycleScope.launch {
            try {
                val client = SyncApiClient(credentials.endpoint)
                val bearer = BearerCredential(credentials.deviceToken)
                val keyPair = PairingKeyPair.generate()
                val created = withContext(Dispatchers.IO) {
                    client.createPairing(
                        CreatePairingRequest(keyPair.publicKeyBase64Url),
                        bearer,
                    )
                }
                val shortCode = created.shortCode
                if (shortCode == null) {
                    fail(
                        activity.getString(
                            R.string.pairing_short_code_failed,
                            "当前同步服务不支持六位码",
                        ),
                    )
                    return@launch
                }
                codeView.setCode(shortCode)
                updateStatus(activity.getString(R.string.pairing_short_code_waiting))
                val deadline = System.currentTimeMillis() +
                    maxOf(0L, created.expiresAt - created.serverTime) + 30_000L
                var sessionKey: ByteArray? = null
                var claimedDeviceId: String? = null
                var verificationShown = false

                while (System.currentTimeMillis() < deadline) {
                    val status = withContext(Dispatchers.IO) {
                        client.pairingStatus(created.pairingId, bearer)
                    }
                    if (status.status == PairingStatus.CONFIRMED) {
                        complete(activity.getString(R.string.pairing_short_code_confirmed))
                        return@launch
                    }
                    if (status.status == PairingStatus.EXPIRED ||
                        status.status == PairingStatus.CANCELED
                    ) {
                        fail(activity.getString(R.string.pairing_short_code_expired))
                        return@launch
                    }
                    val claim = status.claim
                    if (status.status == PairingStatus.CLAIMED && claim != null) {
                        if (!verificationShown) {
                            val key = keyPair.sessionKey(
                                peerPublicKeyBase64Url = claim.publicKey,
                                pairingId = created.pairingId,
                                pairingSecretBase64Url = created.pairingSecret,
                            )
                            sessionKey = key
                            claimedDeviceId = claim.deviceId
                            verificationShown = true
                            if (!activity.isFinishing && !activity.isDestroyed) {
                                verificationView.setCode(
                                    PairingSessionCrypto.verificationCode(
                                        sessionKey = key,
                                        initiatorPublicKey = keyPair.publicKey,
                                        claimPublicKey = Base64Url.decode(claim.publicKey),
                                    ),
                                )
                                verificationGroup.visibility = View.VISIBLE
                                expiryView.visibility = View.GONE
                                confirmButton.visibility = View.VISIBLE
                                updateStatus(
                                    activity.getString(R.string.pairing_short_code_claimed),
                                )
                            }
                        }
                        if (confirmation.isCompleted &&
                            sessionKey != null &&
                            claimedDeviceId != null
                        ) {
                            val envelope = PairingSessionCrypto.sealVaultKey(
                                vaultKey = credentials.vaultKey,
                                sessionKey = sessionKey,
                                pairingId = created.pairingId,
                                claimedDeviceId = claimedDeviceId,
                            )
                            withContext(Dispatchers.IO) {
                                client.confirmPairing(
                                    created.pairingId,
                                    PairingConfirmRequest(envelope),
                                    bearer,
                                )
                            }
                            complete(activity.getString(R.string.pairing_short_code_confirmed))
                            return@launch
                        }
                    }
                    delay(2_000)
                }
                fail(activity.getString(R.string.pairing_short_code_expired))
            } catch (error: CancellationException) {
                throw error
            } catch (error: SyncApiException.Server) {
                if (error.statusCode == 401 || error.statusCode == 403) {
                    fail(activity.getString(R.string.pairing_short_code_display_requires_pairing))
                } else {
                    fail(
                        activity.getString(
                            R.string.pairing_short_code_failed,
                            error.message,
                        ),
                    )
                }
            } catch (error: Exception) {
                fail(
                    activity.getString(
                        R.string.pairing_short_code_failed,
                        error.message ?: error.javaClass.simpleName,
                    ),
                )
            }
        }
        dialog.show()
    }
}
