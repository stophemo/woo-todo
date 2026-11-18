package com.wootodo.ui

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.Editable
import android.text.InputFilter
import android.text.TextWatcher
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.wootodo.R

/**
 * 六位配对码输入/展示组件。输入由隐藏的 EditText 承接，六个格子只负责视觉，
 * 因此粘贴、输入法、删除和回车都能按系统习惯工作。
 */
class SixDigitCodeView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {
    private val cells: List<TextView>
    private val input: EditText
    private var editable = true
    private var isError = false

    var onCodeChanged: ((String) -> Unit)? = null
    var onSubmit: (() -> Unit)? = null

    val code: String
        get() = input.text.toString()

    init {
        LayoutInflater.from(context).inflate(R.layout.view_six_digit_code, this, true)
        cells = listOf(
            findViewById(R.id.pin_digit_0),
            findViewById(R.id.pin_digit_1),
            findViewById(R.id.pin_digit_2),
            findViewById(R.id.pin_digit_3),
            findViewById(R.id.pin_digit_4),
            findViewById(R.id.pin_digit_5),
        )
        cells.forEach { it.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        input = findViewById(R.id.pin_input)
        input.filters = arrayOf(InputFilter.LengthFilter(6))
        input.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit

            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit

            override fun afterTextChanged(s: Editable?) {
                val raw = s?.toString().orEmpty()
                val digits = raw.filter(Char::isDigit).take(6)
                if (digits != raw) {
                    input.setText(digits)
                    input.setSelection(digits.length)
                    return
                }
                isError = false
                render()
                onCodeChanged?.invoke(digits)
            }
        })
        input.setOnFocusChangeListener { _, _ -> render() }
        input.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_DONE) {
                onSubmit?.invoke()
                true
            } else {
                false
            }
        }
        setOnClickListener { requestInputFocus() }
        render()
    }

    fun setCode(value: String) {
        val digits = value.filter(Char::isDigit).take(6)
        input.setText(digits)
        input.setSelection(digits.length)
        render()
    }

    fun setEditable(value: Boolean) {
        editable = value
        input.visibility = if (value) View.VISIBLE else View.GONE
        input.isEnabled = value
        if (!value) input.clearFocus()
        render()
    }

    fun setError(value: Boolean) {
        isError = value
        render()
    }

    fun requestInputFocus() {
        if (!editable) return
        input.requestFocus()
        input.post {
            context.getSystemService(InputMethodManager::class.java)
                ?.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT)
        }
    }

    private fun render() {
        val characters = code
        val activeIndex = if (editable && input.hasFocus()) {
            minOf(characters.length, 5)
        } else {
            -1
        }
        contentDescription = if (editable) {
            null
        } else {
            context.getString(R.string.pairing_six_digit_code_description, characters)
        }
        val ink = ContextCompat.getColor(context, R.color.ink)
        val placeholder = ContextCompat.getColor(context, R.color.line)
        val line = ContextCompat.getColor(context, R.color.line)
        val primary = ContextCompat.getColor(context, R.color.primary)
        val error = ContextCompat.getColor(context, R.color.orange)
        val background = ContextCompat.getColor(context, R.color.app_background)
        val activeFill = Color.argb(
            26,
            Color.red(primary),
            Color.green(primary),
            Color.blue(primary),
        )
        cells.forEachIndexed { index, cell ->
            val filled = index < characters.length
            val active = index == activeIndex
            cell.text = if (filled) characters[index].toString() else "·"
            cell.setTextColor(if (filled) ink else placeholder)
            cell.background = GradientDrawable().apply {
                cornerRadius = dp(10f)
                setColor(if (active) activeFill else background)
                setStroke(
                    dp(if (active) 1.6f else 1f).toInt(),
                    when {
                        isError -> error
                        active -> primary
                        else -> line
                    },
                )
            }
            cell.scaleX = if (active) 1.03f else 1f
            cell.scaleY = if (active) 1.03f else 1f
        }
    }

    private fun dp(value: Float): Float = value * resources.displayMetrics.density
}
