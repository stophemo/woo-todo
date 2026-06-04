package com.wootodo.ui.screens

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.wootodo.data.Todo
import com.wootodo.data.TodoDao
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class TodoViewModel @Inject constructor(
    private val todoDao: TodoDao
) : ViewModel() {

    val todos: StateFlow<List<Todo>> = todoDao.getAllTodos()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun addTodo(title: String) {
        viewModelScope.launch {
            val todo = Todo(
                title = title,
                createdAt = System.currentTimeMillis(),
                updatedAt = System.currentTimeMillis()
            )
            todoDao.upsert(todo)
        }
    }

    fun toggleTodo(todo: Todo) {
        viewModelScope.launch {
            val updated = todo.copy(
                completed = !todo.completed,
                updatedAt = System.currentTimeMillis(),
                syncedAt = 0
            )
            todoDao.upsert(updated)
        }
    }

    fun deleteTodo(todo: Todo) {
        viewModelScope.launch {
            todoDao.softDelete(todo.id)
        }
    }
}
