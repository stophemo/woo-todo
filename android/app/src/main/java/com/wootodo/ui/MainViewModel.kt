package com.wootodo.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.wootodo.data.TaskRepository
import com.wootodo.domain.Task
import com.wootodo.domain.TaskCategory
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import java.time.LocalDate
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class MainViewModel(
    private val repository: TaskRepository,
    private val onTasksChanged: () -> Unit,
) : ViewModel() {
    private val todayFlow = MutableStateFlow(TaskDateRules.today())

    val categories: StateFlow<List<TaskCategory>> = repository.observeCategories()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val sections: StateFlow<List<TaskListSection>> = combine(
        repository.observeAllTasks(),
        categories,
        todayFlow,
    ) { tasks, categories, today ->
        TaskListPresenter.sections(tasks, categories, today)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun refresh() {
        todayFlow.value = TaskDateRules.today()
    }

    fun complete(id: String, onResult: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            val changed = repository.settle(id, TaskStatus.COMPLETED)
            if (changed) onTasksChanged()
            onResult(changed)
        }
    }

    fun reopen(id: String, onResult: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            val changed = repository.reopen(id)
            if (changed) onTasksChanged()
            onResult(changed)
        }
    }

    fun pass(id: String, onResult: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            val changed = repository.settle(id, TaskStatus.PASS)
            if (changed) onTasksChanged()
            onResult(changed)
        }
    }

    fun delete(task: Task, onResult: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            val deleted = repository.delete(task.id)
            if (deleted) onTasksChanged()
            onResult(deleted)
        }
    }

    /** 撤销删除：从本机恢复快照重新创建任务，并以普通 upsert 同步到其他设备。 */
    fun restoreTrash(id: String, onResult: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            val restored = runCatching {
                repository.restoreTrash(id)
            }.getOrDefault(false)
            if (restored) onTasksChanged()
            onResult(restored)
        }
    }

    class Factory(
        private val repository: TaskRepository,
        private val onTasksChanged: () -> Unit,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            MainViewModel(repository, onTasksChanged) as T
    }
}
