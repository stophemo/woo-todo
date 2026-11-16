package com.wootodo.ui

import android.app.AlertDialog
import android.text.InputType
import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.ItemTouchHelper
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.wootodo.R
import com.wootodo.data.TaskRepository
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory
import kotlinx.coroutines.launch

object CategoryManagerDialog {
    private const val MAXIMUM_VISIBLE_ROWS = 6
    private const val ROW_HEIGHT_DP = 58

    fun show(
        activity: AppCompatActivity,
        repository: TaskRepository,
        onChanged: (List<TaskCategory>) -> Unit,
    ) {
        val content = LayoutInflater.from(activity)
            .inflate(R.layout.dialog_category_manager, null)
        val list = content.findViewById<RecyclerView>(R.id.category_list)
        val addButton = content.findViewById<Button>(R.id.category_add)
        val dialog = AlertDialog.Builder(activity)
            .setTitle(R.string.category_manage)
            .setView(content)
            .setNegativeButton(R.string.done, null)
            .create()
        var categories = emptyList<TaskCategory>()
        lateinit var adapter: CategoryOrderAdapter
        lateinit var dragHelper: ItemTouchHelper
        lateinit var render: () -> Unit
        lateinit var reload: () -> Unit
        lateinit var failureMessage: (String, String?) -> String
        lateinit var promptName: (TaskCategory?) -> Unit
        lateinit var confirmDelete: (TaskCategory) -> Unit

        adapter = CategoryOrderAdapter(
            rename = { promptName(it) },
            delete = { confirmDelete(it) },
            startDrag = { holder -> dragHelper.startDrag(holder) },
        )
        list.layoutManager = LinearLayoutManager(activity)
        list.adapter = adapter

        dragHelper = ItemTouchHelper(object : ItemTouchHelper.SimpleCallback(
            ItemTouchHelper.UP or ItemTouchHelper.DOWN,
            0,
        ) {
            private var orderChanged = false

            override fun onMove(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
                target: RecyclerView.ViewHolder,
            ): Boolean {
                val from = viewHolder.adapterPosition
                val to = target.adapterPosition
                if (from == RecyclerView.NO_POSITION || to == RecyclerView.NO_POSITION) {
                    return false
                }
                val moved = adapter.moveItem(from, to)
                if (moved) orderChanged = true
                return moved
            }

            override fun onSwiped(viewHolder: RecyclerView.ViewHolder, direction: Int) = Unit

            override fun isLongPressDragEnabled(): Boolean = true

            override fun onSelectedChanged(
                viewHolder: RecyclerView.ViewHolder?,
                actionState: Int,
            ) {
                super.onSelectedChanged(viewHolder, actionState)
                if (actionState == ItemTouchHelper.ACTION_STATE_DRAG) {
                    viewHolder?.itemView?.alpha = 0.85f
                }
            }

            override fun clearView(
                recyclerView: RecyclerView,
                viewHolder: RecyclerView.ViewHolder,
            ) {
                super.clearView(recyclerView, viewHolder)
                viewHolder.itemView.alpha = 1f
                if (!orderChanged) return
                orderChanged = false
                val ids = adapter.currentIds()
                activity.lifecycleScope.launch {
                    repository.reorderCategories(ids)
                    reload()
                }
            }
        })
        dragHelper.attachToRecyclerView(list)
        addButton.setOnClickListener { promptName(null) }

        render = {
            adapter.submit(categories)
            addButton.isEnabled = categories.size < TaskCategories.MAXIMUM_COUNT
            updateListHeight(activity, list, categories.size)
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
                normalized == null -> activity.getString(R.string.category_name_invalid)
                categories.any { it.id != currentId && it.name == normalized } ->
                    activity.getString(R.string.category_duplicate_name)
                currentId == null && categories.size >= TaskCategories.MAXIMUM_COUNT ->
                    activity.getString(R.string.category_limit_reached)
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

    private fun updateListHeight(
        activity: AppCompatActivity,
        list: RecyclerView,
        count: Int,
    ) {
        val height = if (count <= MAXIMUM_VISIBLE_ROWS) {
            ViewGroup.LayoutParams.WRAP_CONTENT
        } else {
            dp(activity, MAXIMUM_VISIBLE_ROWS * ROW_HEIGHT_DP)
        }
        if (list.layoutParams.height == height) return
        list.layoutParams = list.layoutParams.apply { this.height = height }
    }

    private fun dp(activity: AppCompatActivity, value: Int): Int =
        (value * activity.resources.displayMetrics.density).toInt()
}
