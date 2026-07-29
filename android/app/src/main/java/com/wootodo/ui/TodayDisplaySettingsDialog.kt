package com.wootodo.ui

import android.app.AlertDialog
import android.app.DatePickerDialog
import android.text.InputFilter
import android.view.Menu
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
    private data class TemplateVariable(val labelRes: Int, val token: String)
    private data class CounterTemplateVariable(
        val labelRes: Int,
        val dateTitleRes: Int,
        val variable: DayCounterText.CounterVariable,
    )

    private val weekdayVariables = listOf(
        TemplateVariable(R.string.display_variable_weekday, DayCounterText.WEEKDAY_TOKEN),
        TemplateVariable(R.string.display_variable_weekday_short, DayCounterText.WEEKDAY_SHORT_TOKEN),
        TemplateVariable(R.string.display_variable_weekday_en, DayCounterText.WEEKDAY_EN_TOKEN),
        TemplateVariable(
            R.string.display_variable_weekday_en_short,
            DayCounterText.WEEKDAY_EN_SHORT_TOKEN,
        ),
    )
    private val dateVariables = listOf(
        TemplateVariable(R.string.display_variable_date, DayCounterText.DATE_TOKEN),
        TemplateVariable(R.string.display_variable_date_long, DayCounterText.DATE_LONG_TOKEN),
        TemplateVariable(R.string.display_variable_year, DayCounterText.YEAR_TOKEN),
        TemplateVariable(R.string.display_variable_month, DayCounterText.MONTH_TOKEN),
        TemplateVariable(R.string.display_variable_month_padded, DayCounterText.MONTH_PADDED_TOKEN),
        TemplateVariable(R.string.display_variable_day, DayCounterText.DAY_TOKEN),
        TemplateVariable(R.string.display_variable_day_padded, DayCounterText.DAY_PADDED_TOKEN),
    )
    private val counterVariables = listOf(
        CounterTemplateVariable(
            R.string.display_variable_elapsed_days,
            R.string.display_select_start_date,
            DayCounterText.CounterVariable.ELAPSED_DAYS,
        ),
        CounterTemplateVariable(
            R.string.display_variable_deadline_days,
            R.string.display_select_deadline_date,
            DayCounterText.CounterVariable.DEADLINE_DAYS,
        ),
        CounterTemplateVariable(
            R.string.display_variable_elapsed_months_days,
            R.string.display_select_start_date,
            DayCounterText.CounterVariable.ELAPSED_MONTHS_DAYS,
        ),
        CounterTemplateVariable(
            R.string.display_variable_deadline_months_days,
            R.string.display_select_deadline_date,
            DayCounterText.CounterVariable.DEADLINE_MONTHS_DAYS,
        ),
    )

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
            today = today,
        )
        val subtitleInput = templateEditor(
            activity = activity,
            container = container,
            labelRes = R.string.display_subtitle_template,
            hintRes = R.string.display_subtitle_hint,
            value = initial.subtitleTemplate,
            limit = 160,
            spacing = spacing,
            today = today,
        )

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
            val rendered = DayCounterText.render(currentSettings(), today)
            previewHeader.text = rendered.header.orEmpty()
            previewHeader.isVisible = rendered.header != null
            previewSubtitle.text = rendered.subtitle.orEmpty()
            previewSubtitle.isVisible = rendered.subtitle != null
            previewHidden.isVisible = rendered.header == null && rendered.subtitle == null
        }

        headerInput.doAfterTextChanged { renderPreview() }
        subtitleInput.doAfterTextChanged { renderPreview() }
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
        today: LocalDate,
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
            setOnClickListener { anchor ->
                showVariableMenu(activity, anchor, input, today, limit)
            }
        }
        row.addView(insertButton)
        container.addView(row)
        return input
    }

    private fun showVariableMenu(
        activity: AppCompatActivity,
        anchor: View,
        input: EditText,
        today: LocalDate,
        limit: Int,
    ) {
        PopupMenu(activity, anchor).apply {
            menu.addSubMenu(R.string.display_variable_group_weekday)
                .addVariables(activity, input, weekdayVariables, limit)
            menu.addSubMenu(R.string.display_variable_group_date)
                .addVariables(activity, input, dateVariables, limit)
            menu.addSubMenu(R.string.display_variable_group_counter)
                .addCounterVariables(activity, input, counterVariables, today, limit)
            show()
        }
    }

    private fun Menu.addCounterVariables(
        activity: AppCompatActivity,
        input: EditText,
        variables: List<CounterTemplateVariable>,
        today: LocalDate,
        limit: Int,
    ) {
        variables.forEach { variable ->
            add(activity.getString(variable.labelRes)).setOnMenuItemClickListener {
                pickDate(activity, today, variable.dateTitleRes) { selected ->
                    insertToken(
                        input,
                        DayCounterText.counterToken(variable.variable, selected),
                        limit,
                    )
                }
                true
            }
        }
    }

    private fun Menu.addVariables(
        activity: AppCompatActivity,
        input: EditText,
        variables: List<TemplateVariable>,
        limit: Int,
    ) {
        variables.forEach { variable ->
            add(activity.getString(variable.labelRes)).setOnMenuItemClickListener {
                insertToken(input, variable.token, limit)
                true
            }
        }
    }

    private fun insertToken(input: EditText, token: String, limit: Int) {
        val selectionStart = input.selectionStart.coerceIn(0, input.text.length)
        val selectionEnd = input.selectionEnd.coerceIn(0, input.text.length)
        val start = minOf(selectionStart, selectionEnd)
        val end = maxOf(selectionStart, selectionEnd)
        if (input.text.length - (end - start) + token.length > limit) return
        input.text.replace(start, end, token)
        input.requestFocus()
        input.setSelection((start + token.length).coerceAtMost(input.text.length))
    }

    private fun pickDate(
        activity: AppCompatActivity,
        initial: LocalDate,
        titleRes: Int,
        onSelected: (LocalDate) -> Unit,
    ) {
        DatePickerDialog(
            activity,
            { _, year, month, day -> onSelected(LocalDate.of(year, month + 1, day)) },
            initial.year,
            initial.monthValue - 1,
            initial.dayOfMonth,
        ).apply {
            setTitle(titleRes)
        }.show()
    }
}
