<script setup lang="ts">
import type { Todo } from '../types/todo'

const props = defineProps<{
  todo: Todo
  transparentMode: boolean
}>()

const emit = defineEmits<{
  toggle: [id: string]
  delete: [id: string]
}>()
</script>

<template>
  <div class="todo-item" :class="{ completed: todo.completed, 'transparent-item': transparentMode }">
    <!-- 勾选框（穿透模式下隐藏） -->
    <button
      v-if="!transparentMode"
      class="checkbox"
      :class="{ checked: todo.completed }"
      @click="emit('toggle', todo.id)"
    >
      <span v-if="todo.completed" class="check-mark">✓</span>
    </button>
    <span v-else class="transparent-dot" :class="{ done: todo.completed }">●</span>

    <!-- 待办文字 -->
    <span class="todo-title" :class="{ 'line-through': todo.completed }">
      {{ todo.title }}
    </span>

    <!-- 删除按钮（穿透模式下隐藏） -->
    <button
      v-if="!transparentMode"
      class="delete-btn"
      @click="emit('delete', todo.id)"
    >
      ×
    </button>
  </div>
</template>

<style scoped>
.todo-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 10px;
  border-radius: 8px;
  transition: background 0.15s;
}

.todo-item:not(.transparent-item):hover {
  background: rgba(255, 255, 255, 0.06);
}

.checkbox {
  width: 18px;
  height: 18px;
  border-radius: 50%;
  border: 1.5px solid rgba(255, 255, 255, 0.3);
  background: transparent;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  transition: all 0.2s;
}

.checkbox:hover {
  border-color: rgba(255, 255, 255, 0.5);
}

.checkbox.checked {
  background: rgba(100, 200, 130, 0.8);
  border-color: rgba(100, 200, 130, 0.8);
}

.check-mark {
  font-size: 11px;
  color: white;
  font-weight: 600;
  line-height: 1;
}

.transparent-dot {
  font-size: 10px;
  opacity: 0.6;
  flex-shrink: 0;
}

.transparent-dot.done {
  opacity: 0.2;
}

.todo-title {
  flex: 1;
  font-size: 14px;
  color: rgba(255, 255, 255, 0.9);
  line-height: 1.4;
  word-break: break-word;
}

/* 穿透模式下文字需高可见 */
.transparent-item .todo-title {
  text-shadow: 0 1px 4px rgba(0, 0, 0, 0.5);
  font-size: 13px;
}

.todo-title.line-through {
  text-decoration: line-through;
  color: rgba(255, 255, 255, 0.35);
}

.delete-btn {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  border: none;
  background: transparent;
  color: rgba(255, 255, 255, 0.2);
  font-size: 16px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  transition: all 0.15s;
  opacity: 0;
}

.todo-item:hover .delete-btn {
  opacity: 1;
}

.delete-btn:hover {
  background: rgba(255, 80, 80, 0.3);
  color: rgba(255, 255, 255, 0.8);
}
</style>
