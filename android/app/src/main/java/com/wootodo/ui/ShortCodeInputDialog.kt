package com.wootodo.ui

import android.app.AlertDialog
import android.content.ClipboardManager
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.button.MaterialButton
import com.wootodo.R

/** 六位配对码输入弹窗：六格输入、粘贴、错误态与回车提交。 */
object ShortCodeInputDialog {
    fun show(
        activity: AppCompatActivity,
        onSubmit: (String) -> Unit,
    ) {
        val content = LayoutInflater.from(activity)
            .inflate(R.layout.dialog_short_code_input, null)
        val codeView = content.findViewById<SixDigitCodeView>(R.id.short_code_input)
        val errorView = content.findViewById<TextView>(R.id.short_code_error)
        val submitButton = content.findViewById<MaterialButton>(R.id.short_code_submit)
        val pasteButton = content.findViewById<MaterialButton>(R.id.short_code_paste)
        val cancelButton = content.findViewById<MaterialButton>(R.id.short_code_cancel)
        val dialog = AlertDialog.Builder(activity)
            .setView(content)
            .create()

        fun showError(message: String) {
            codeView.setError(true)
            errorView.text = message
            errorView.visibility = View.VISIBLE
            codeView.requestInputFocus()
        }

        fun submit() {
            val code = codeView.code
            if (code.length != 6) {
                showError(activity.getString(R.string.pairing_short_code_invalid))
                return
            }
            dialog.dismiss()
            onSubmit(code)
        }

        codeView.onCodeChanged = { code ->
            submitButton.isEnabled = code.length == 6
            if (code.isNotEmpty()) {
                errorView.visibility = View.GONE
                codeView.setError(false)
            }
        }
        codeView.onSubmit = { submit() }
        submitButton.isEnabled = false
        submitButton.setOnClickListener { submit() }
        pasteButton.setOnClickListener {
            val clipboard = activity.getSystemService(ClipboardManager::class.java)
            val text = clipboard?.primaryClip
                ?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)
                ?.coerceToText(activity)
                ?.toString()
            val digits = text.orEmpty().filter(Char::isDigit).take(6)
            if (digits.length == 6) {
                codeView.setCode(digits)
                errorView.visibility = View.GONE
                codeView.setError(false)
            } else {
                showError(activity.getString(R.string.pairing_short_code_paste_invalid))
            }
        }
        cancelButton.setOnClickListener { dialog.dismiss() }
        dialog.window?.setSoftInputMode(
            WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or
                WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE,
        )
        dialog.setOnShowListener {
            codeView.requestInputFocus()
        }
        dialog.show()
    }
}
