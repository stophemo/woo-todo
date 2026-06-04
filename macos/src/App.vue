<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { useTodoStore } from './composables/useTodoStore'
import TodoList from './components/TodoList.vue'
import TodoInput from './components/TodoInput.vue'

const { todos, addTodo, toggleTodo, deleteTodo } = useTodoStore()

const transparentMode = ref(true)
const alwaysOnTop = ref(true)
const showInput = ref(false)

onMounted(() => {
  if (window.electronAPI) {
    window.electronAPI.getSettings().then((settings) => {
      transparentMode.value = settings.transparentMode
      alwaysOnTop.value = settings.alwaysOnTop
    })
    window.electronAPI.onTransparentModeChanged((enabled) => {
      transparentMode.value = enabled
      if (enabled) showInput.value = false
    })
    window.electronAPI.onFocusAddInput(() => {
      showInput.value = true
    })
  }
})
</script>

<template>
  <div class="app-container" :class="{ 'transparent-mode': transparentMode }">
    <!-- 标题栏 -->
    <header v-if="!transparentMode" class="title-bar">
      <span class="app-title">woo-todo</span>
      <div class="title-actions">
        <button
          class="icon-btn"
          :title="alwaysOnTop ? '取消置顶' : '置于顶层'"
          @click="window.electronAPI?.toggleAlwaysOnTop()"
        >
          {{ alwaysOnTop ? '📌' : '📍' }}
        </button>
        <button
          class="icon-btn"
          title="透明化"
          @click="window.electronAPI?.toggleTransparentMode()"
        >
          👁
        </button>
      </div>
    </header>

    <!-- 待办列表 -->
    <main class="todo-list-area">
      <TodoList
        :todos="todos"
        :transparent-mode="transparentMode"
        @toggle="toggleTodo"
        @delete="deleteTodo"
      />
    </main>

    <!-- 新增区域（穿透模式下隐藏） -->
    <footer v-if="!transparentMode" class="input-area">
      <TodoInput
        v-if="showInput"
        @add="(title: string) => { addTodo(title); showInput = false }"
        @cancel="showInput = false"
      />
      <button v-else class="add-btn" @click="showInput = true">
        + 新增待办
      </button>
    </footer>
  </div>
</template>

<style>
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

html, body {
  background: transparent !important;
  overflow: hidden;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  -webkit-font-smoothing: antialiased;
  user-select: none;
}

.app-container {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: rgba(30, 30, 30, 0.85);
  backdrop-filter: blur(20px);
  -webkit-backdrop-filter: blur(20px);
  border-radius: 16px;
  transition: background 0.3s ease, backdrop-filter 0.3s ease;
}

.app-container.transparent-mode {
  background: transparent;
  backdrop-filter: none;
  -webkit-backdrop-filter: none;
  pointer-events: none;
}

.title-bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 14px;
  -webkit-app-region: drag;
  border-bottom: 0.5px solid rgba(255, 255, 255, 0.1);
}

.app-title {
  font-size: 13px;
  font-weight: 500;
  color: rgba(255, 255, 255, 0.7);
  letter-spacing: 0.5px;
}

.title-actions {
  display: flex;
  gap: 6px;
  -webkit-app-region: no-drag;
}

.icon-btn {
  background: rgba(255, 255, 255, 0.08);
  border: 0.5px solid rgba(255, 255, 255, 0.12);
  border-radius: 6px;
  font-size: 14px;
  padding: 4px 8px;
  cursor: pointer;
  transition: background 0.15s;
}

.icon-btn:hover {
  background: rgba(255, 255, 255, 0.15);
}

.todo-list-area {
  flex: 1;
  overflow-y: auto;
  padding: 8px 14px;
}

.input-area {
  padding: 10px 14px;
  border-top: 0.5px solid rgba(255, 255, 255, 0.1);
}

.add-btn {
  width: 100%;
  padding: 8px;
  background: rgba(255, 255, 255, 0.06);
  border: 0.5px solid rgba(255, 255, 255, 0.1);
  border-radius: 8px;
  color: rgba(255, 255, 255, 0.5);
  font-size: 13px;
  cursor: pointer;
  transition: all 0.15s;
}

.add-btn:hover {
  background: rgba(255, 255, 255, 0.1);
  color: rgba(255, 255, 255, 0.8);
}

/* 穿透模式下的文字 */
.transparent-mode .todo-list-area {
  pointer-events: none;
}
</style>
