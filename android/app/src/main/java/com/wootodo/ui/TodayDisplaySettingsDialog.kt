package com.wootodo.ui

import android.app.AlertDialog
import android.app.DatePickerDialog
import android.text.InputFilter
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.PopupMenu
import androidx.core.view.isVisible
import androidx.core.widget.doAfterTextChanged
import com.wootodo.R
import com.wootodo.display.DayCounterSettings
import com.wootodo.display.DayCounterText
import java.time.LocalDate

internal object TodayDisplaySettingsDialog {
    fun show(
        activity: AppCompatActivity,
        initial: DayCounterSettings,
        today: LocalDate,
        onSave: (DayCounterSettings) -> Unit,
    ) {
        val padding = (20 * activity.resources.displayMetrics.density).toInt()
        val spacing = padding / 2
        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, spacing, padding, spacing)
        }
        var startDate = initial.startDate
        var deadlineDate = initial.deadlineDate

        val headerInput = templateEditor(
            activity = activity,
            container = container,
            labelRes = R.string.display_header_template,
            hintRes = R.string.display_header_hint,
            value = initial.headerTemplate,
            limit = 80,
            spacing = spacing,
        )
        val subtitleInput = templateEditor(
            activity = activity,
            container = container,
            labelRes = R.string.display_subtitle_template,
            hintRes = R.string.display_subtitle_hint,
            value = initial.subtitleTemplate,
            limit = 160,
            spacing = spacing,
        )
        val startDateButton = Button(activity).apply { isAllCaps = false }
        val deadlineDateButton = Button(activity).apply { isAllCaps = false }
        container.addView(startDateButton)
        container.addView(deadlineDateButton)

        val previewLabel = TextView(activity).apply {
            setText(R.string.display_preview)
            setPadding(0, spacing, 0, spacing / 2)
        }
        val previewHeader = TextView(activity).apply {
            textSize = 20f
            maxLines = 1
        }
        val previewSubtitle = TextView(activity).apply {
            textSize = 13f
            maxLines = 2
        }
        val previewHidden = TextView(activity).apply {
            setText(R.string.display_preview_hidden)
        }
        container.addView(previewLabel)
        container.addView(previewHeader)
        container.addView(previewSubtitle)
        container.addView(previewHidden)

        fun currentSettings(): DayCounterSettings = DayCounterSettings(
            headerTemplate = headerInput.text.toString(),
            subtitleTemplate = subtitleInput.text.toString(),
            startDate = startDate,
            deadlineDate = deadlineDate,
        )

        fun renderPreview() {
            startDateButton.text = activity.getString(R.string.display_start_date, startDate)
            deadlineDateButton.text = activity.getString(R.string.display_deadline_date, deadlineDate)
            val rendered = DayCounterText.render(currentSettings(), today)
            previewHeader.text = rendered.header.orEmpty()
            previewHeader.isVisible = rendered.header != null
            previewSubtitle.text = rendered.subtitle.orEmpty()
            previewSubtitle.isVisible = rendered.subtitle != null
            previewHidden.isVisible = rendered.header == null && rendered.subtitle == null
        }

        headerInput.doAfterTextChanged { renderPreview() }
        subtitleInput.doAfterTextChanged { renderPreview() }
        startDateButton.setOnClickListener {
            pickDate(activity, startDate) { selected ->
                startDate = selected
                renderPreview()
            }
        }
        deadlineDateButton.setOnClickListener {
            pickDate(activity, deadlineDate) { selected ->
                deadlineDate = selected
                renderPreview()
            }
        }
        renderPreview()

        val scrollView = ScrollView(activity).apply {
            isFillViewport = true
            addView(container)
        }
        val dialog = AlertDialog.Builder(activity)
            .setTitle(R.string.day_counter_settings_title)
            .setView(scrollView)
            .setNegativeButton(R.string.cancel, null)
            .setNeutralButton(R.string.display_restore_default, null)
            .setPositiveButton(R.string.save) { _, _ -> onSave(currentSettings()) }
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
                val defaults = DayCounterSettings(startDate = today, deadlineDate = today)
                headerInput.setText(defaults.headerTemplate)
                subtitleInput.setText(defaults.subtitleTemplate)
                startDate = defaults.startDate
                deadlineDate = defaults.deadlineDate
                renderPreview()
            }
        }
        dialog.show()
    }

    private fun templateEditor(
        activity: AppCompatActivity,
        container: LinearLayout,
        labelRes: Int,
        hintRes: Int,
        value: String,
        limit: Int,
        spacing: Int,
    ): EditText {
        container.addView(TextView(activity).apply {
            setText(labelRes)
            setPadding(0, spacing / 2, 0, 0)
        })
        val row = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        val input = EditText(activity).apply {
            hint = activity.getString(hintRes)
            setText(value)
            isSingleLine = true
            filters = arrayOf(InputFilter.LengthFilter(limit))
            enableEditableTextActions()
        }
        row.addView(
            input,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        val insertButton = Button(activity).apply {
            setText(R.string.display_insert_variable)
            isAllCaps = false
            minWidth = 0
            setOnClickListener { anchor -> showVariableMenu(activity, anchor, input) }
        }
        row.addView(insertButton)
        container.addView(row)
        return input
    }

    private fun showVariableMenu(
        activity: AppCompatActivity,
        anchor: View,
        input: EditText,
    ) {
        PopupMenu(activity, anchor).apply {
            menu.add(activity.getString(R.string.display_variable_weekday))
                .setOnMenuItemClickListener {
                    insertToken(input, DayCounterText.WEEKDAY_TOKEN)
                    true
                }
            menu.add(activity.getString(R.string.display_variable_elapsed_days))
                .setOnMenuItemClickListener {
                    insertToken(input, DayCounterText.ELAPSED_DAYS_TOKEN)
                    true
                }
            menu.add(activity.getString(R.string.display_variable_deadline_days))
                .setOnMenuItemClickListener {
                    insertToken(input, DayCounterText.DEADLINE_DAYS_TOKEN)
                    true
                }
            show()
        }
    }

    private fun insertToken(input: EditText, token: String) {
        val position = input.selectionStart.coerceIn(0, input.text.length)
        input.text.insert(position, token)
        input.requestFocus()
        input.setSelection((position + token.length).coerceAtMost(input.text.length))
    }

    private fun pickDate(
        activity: AppCompatActivity,
        initial: LocalDate,
        onSelected: (LocalDate) -> Unit,
    ) {
        DatePickerDialog(
            activity,
            { _, year, month, day -> onSelected(LocalDate.of(year, month + 1, day)) },
            initial.year,
            initial.monthValue - 1,
            initial.dayOfMonth,
        ).show()
    }
}
