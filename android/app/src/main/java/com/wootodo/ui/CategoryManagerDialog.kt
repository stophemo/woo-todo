package com.wootodo.ui

import android.app.AlertDialog
import android.text.InputType
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.wootodo.R
import com.wootodo.data.TaskRepository
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import kotlinx.coroutines.launch

object CategoryManagerDialog {
    fun show(
        activity: AppCompatActivity,
        repository: TaskRepository,
        onChanged: (List<TaskCategory>) -> Unit,
    ) {
        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            val padding = dp(activity, 20)
            setPadding(padding, padding / 2, padding, padding / 2)
        }
        val dialog = AlertDialog.Builder(activity)
            .setTitle(R.string.category_manage)
            .setView(ScrollView(activity).apply { addView(container) })
            .setNegativeButton(R.string.cancel, null)
            .create()
        var categories = emptyList<TaskCategory>()

        lateinit var render: () -> Unit
        lateinit var reload: () -> Unit
        lateinit var failureMessage: (String, String?) -> String
        lateinit var promptName: (TaskCategory?) -> Unit
        lateinit var confirmDelete: (TaskCategory) -> Unit

        render = {
            container.removeAllViews()
            categories.forEach { category ->
                val row = LinearLayout(activity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = android.view.Gravity.CENTER_VERTICAL
                    setPadding(0, dp(activity, 6), 0, dp(activity, 6))
                }
                row.addView(
                    TextView(activity).apply {
                        text = category.name
                        textSize = 16f
                        layoutParams = LinearLayout.LayoutParams(
                            0,
                            LinearLayout.LayoutParams.WRAP_CONTENT,
                            1f,
                        )
                    },
                )
                row.addView(
                    Button(activity).apply {
                        text = activity.getString(R.string.category_rename)
                        minWidth = 0
                        setOnClickListener { promptName(category) }
                    },
                )
                if (category.id != TaskCategories.INBOX_ID) {
                    row.addView(
                        Button(activity).apply {
                            text = activity.getString(R.string.delete)
                            minWidth = 0
                            setOnClickListener { confirmDelete(category) }
                        },
                    )
                }
                container.addView(row)
            }
            container.addView(
                Button(activity).apply {
                    text = activity.getString(R.string.category_add)
                    isEnabled = categories.size < TaskCategories.MAXIMUM_COUNT
                    setOnClickListener { promptName(null) }
                },
            )
        }

        reload = {
            activity.lifecycleScope.launch {
                categories = repository.allCategories()
                onChanged(categories)
                render()
            }
        }

        failureMessage = { name, currentId ->
            val normalized = TaskCategories.normalizeName(name)
            when {
                categories.size >= TaskCategories.MAXIMUM_COUNT ->
                    activity.getString(R.string.category_limit_reached)
                normalized == null -> activity.getString(R.string.category_name_invalid)
                categories.any { it.id != currentId && it.name == normalized } ->
                    activity.getString(R.string.category_duplicate_name)
                else -> activity.getString(R.string.save_failed)
            }
        }

        promptName = { existing ->
            val input = EditText(activity).apply {
                inputType = InputType.TYPE_CLASS_TEXT
                hint = activity.getString(R.string.category_name_hint)
                setText(existing?.name.orEmpty())
                setSelection(text.length)
            }
            AlertDialog.Builder(activity)
                .setTitle(
                    if (existing == null) R.string.category_add else R.string.category_rename,
                )
                .setView(input)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.confirm) { _, _ ->
                    val name = input.text.toString()
                    activity.lifecycleScope.launch {
                        val success = if (existing == null) {
                            repository.addCategory(name) != null
                        } else {
                            repository.renameCategory(existing.id, name)
                        }
                        if (success) {
                            reload()
                        } else {
                            Toast.makeText(
                                activity,
                                failureMessage(name, existing?.id),
                                Toast.LENGTH_SHORT,
                            ).show()
                        }
                    }
                }
                .show()
        }

        confirmDelete = { category ->
            AlertDialog.Builder(activity)
                .setTitle(R.string.category_delete_title)
                .setMessage(R.string.category_delete_message)
                .setNegativeButton(R.string.cancel, null)
                .setPositiveButton(R.string.delete) { _, _ ->
                    activity.lifecycleScope.launch {
                        if (repository.deleteCategory(category.id)) {
                            reload()
                        } else {
                            Toast.makeText(activity, R.string.save_failed, Toast.LENGTH_SHORT).show()
                        }
                    }
                }
                .show()
        }

        dialog.show()
        reload()
    }

    private fun dp(activity: AppCompatActivity, value: Int): Int =
        (value * activity.resources.displayMetrics.density).toInt()
}
