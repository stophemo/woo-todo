import { ref, computed } from 'vue'
import type { Todo } from '../types/todo'

const todos = ref<Todo[]>([])

function generateId(): string {
  return Date.now().toString(36) + Math.random().toString(36).slice(2, 9)
}

export function useTodoStore() {
  const activeTodos = computed(() =>
    todos.value.filter((t) => !t.isDeleted).sort((a, b) => b.updatedAt - a.updatedAt)
  )

  const incompleteTodos = computed(() =>
    activeTodos.value.filter((t) => !t.completed)
  )

  const completedTodos = computed(() =>
    activeTodos.value.filter((t) => t.completed)
  )

  function addTodo(title: string) {
    const now = Date.now()
    const todo: Todo = {
      id: generateId(),
      title: title.trim(),
      completed: false,
      createdAt: now,
      updatedAt: now,
      isDeleted: false,
    }
    todos.value.unshift(todo)
    saveToLocal()
  }

  function toggleTodo(id: string) {
    const todo = todos.value.find((t) => t.id === id)
    if (todo) {
      todo.completed = !todo.completed
      todo.updatedAt = Date.now()
      saveToLocal()
    }
  }

  function deleteTodo(id: string) {
    const todo = todos.value.find((t) => t.id === id)
    if (todo) {
      todo.isDeleted = true
      todo.updatedAt = Date.now()
      saveToLocal()
    }
  }

  function saveToLocal() {
    localStorage.setItem('woo-todos', JSON.stringify(todos.value))
  }

  function loadFromLocal() {
    const stored = localStorage.getItem('woo-todos')
    if (stored) {
      try {
        todos.value = JSON.parse(stored)
      } catch {
        todos.value = []
      }
    }
  }

  // 初始化加载
  loadFromLocal()

  return {
    todos: activeTodos,
    incompleteTodos,
    completedTodos,
    addTodo,
    toggleTodo,
    deleteTodo,
  }
}
