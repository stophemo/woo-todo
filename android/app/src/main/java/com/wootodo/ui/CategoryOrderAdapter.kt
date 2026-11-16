package com.wootodo.ui

import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton
import android.widget.PopupMenu
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.wootodo.R
import com.wootodo.domain.TaskCategories
import com.wootodo.domain.TaskCategory

/** 标签管理列表：拖动左侧手柄调整优先级，更多菜单负责改名和删除。 */
internal class CategoryOrderAdapter(
    private val rename: (TaskCategory) -> Unit,
    private val delete: (TaskCategory) -> Unit,
    private val startDrag: (RecyclerView.ViewHolder) -> Unit,
) : RecyclerView.Adapter<CategoryOrderAdapter.Holder>() {
    private val items = mutableListOf<TaskCategory>()

    fun submit(values: List<TaskCategory>) {
        items.clear()
        items.addAll(values)
        notifyDataSetChanged()
    }

    fun moveItem(from: Int, to: Int): Boolean {
        if (from !in items.indices || to !in items.indices || from == to) return false
        items.add(to, items.removeAt(from))
        notifyItemMoved(from, to)
        return true
    }

    fun currentIds(): List<String> = items.map { it.id }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_category_manager, parent, false)
        return Holder(view)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        holder.bind(items[position])
    }

    override fun getItemCount(): Int = items.size

    inner class Holder(view: View) : RecyclerView.ViewHolder(view) {
        private val name: TextView = view.findViewById(R.id.category_name)
        private val fallback: TextView = view.findViewById(R.id.category_fallback)
        private val dragHandle: ImageButton = view.findViewById(R.id.category_drag_handle)
        private val more: ImageButton = view.findViewById(R.id.category_more)

        fun bind(category: TaskCategory) {
            name.text = category.name
            fallback.visibility =
                if (category.id == TaskCategories.INBOX_ID) View.VISIBLE else View.GONE
            more.contentDescription =
                itemView.context.getString(R.string.category_actions, category.name)
            dragHandle.setOnTouchListener { _, event ->
                if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                    startDrag(this)
                }
                false
            }
            more.setOnClickListener { showMenu(category) }
        }

        private fun showMenu(category: TaskCategory) {
            PopupMenu(itemView.context, more).apply {
                menu.add(0, MENU_RENAME, 0, R.string.category_rename)
                if (category.id != TaskCategories.INBOX_ID) {
                    menu.add(0, MENU_DELETE, 1, R.string.delete)
                }
                setOnMenuItemClickListener { item ->
                    when (item.itemId) {
                        MENU_RENAME -> rename(category)
                        MENU_DELETE -> delete(category)
                    }
                    true
                }
                show()
            }
        }
    }

    private companion object {
        const val MENU_RENAME = 1
        const val MENU_DELETE = 2
    }
}
