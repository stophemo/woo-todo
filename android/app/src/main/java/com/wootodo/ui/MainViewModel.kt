package com.wootodo.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.wootodo.data.TaskRepository
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskListDatePolicy
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskTimeType
import java.time.LocalDate
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

@OptIn(ExperimentalCoroutinesApi::class)
class MainViewModel(
    private val repository: TaskRepository,
    private val onTasksChanged: () -> Unit,
) : ViewModel() {
    private val selectedScopeFlow = MutableStateFlow(TaskTimeType.DAY)
    private val todayFlow = MutableStateFlow(TaskDateRules.today())
    private val showTomorrowFlow = MutableStateFlow(false)

    val selectedScope: StateFlow<TaskTimeType> = selectedScopeFlow
    val selectedReferenceDate: StateFlow<LocalDate> =
        combine(selectedScopeFlow, showTomorrowFlow, todayFlow) { scope, showTomorrow, today ->
            TaskListDatePolicy.referenceDate(scope, showTomorrow, today)
        }.stateIn(
            viewModelScope,
            SharingStarted.Eagerly,
            todayFlow.value,
        )

    val tasks: StateFlow<List<Task>> =
        combine(selectedScopeFlow, selectedReferenceDate) { scope, date -> scope to date }
            .flatMapLatest { (scope, date) -> repository.observeForScope(scope, date) }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun selectScope(scope: TaskTimeType) {
        selectedScopeFlow.value = scope
        if (scope != TaskTimeType.DAY) showTomorrowFlow.value = false
    }

    fun selectToday() {
        selectedScopeFlow.value = TaskTimeType.DAY
        showTomorrowFlow.value = false
    }

    fun selectTomorrow() {
        selectedScopeFlow.value = TaskTimeType.DAY
        showTomorrowFlow.value = true
    }

    fun refresh() {
        todayFlow.value = TaskDateRules.today()
        viewModelScope.launch {
            if (repository.autoPassExpired() > 0) {
                onTasksChanged()
            }
        }
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

    /** 撤销删除：用删除前的字段重建一条待办，避免同步删除墓碑冲突。 */
    fun restore(task: Task, onResult: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            val restored = runCatching {
                repository.create(task.toRestoreDraft())
            }.isSuccess
            if (restored) onTasksChanged()
            onResult(restored)
        }
    }

    fun reorder(idsInOrder: List<String>) {
        viewModelScope.launch {
            repository.reorder(idsInOrder)
            onTasksChanged()
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
