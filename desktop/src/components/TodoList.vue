<script setup lang="ts">
import type { Todo } from '../types/todo'
import TodoItem from './TodoItem.vue'

defineProps<{
  todos: Todo[]
  transparentMode: boolean
}>()

const emit = defineEmits<{
  toggle: [id: string]
  delete: [id: string]
}>()
</script>

<template>
  <div class="todo-list">
    <div v-if="todos.length === 0 && !transparentMode" class="empty-state">
      暂无待办，点击下方添加
    </div>
    <TransitionGroup name="todo" tag="div">
      <TodoItem
        v-for="todo in todos"
        :key="todo.id"
        :todo="todo"
        :transparent-mode="transparentMode"
        @toggle="emit('toggle', $event)"
        @delete="emit('delete', $event)"
      />
    </TransitionGroup>
  </div>
</template>

<style scoped>
.todo-list {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.empty-state {
  text-align: center;
  padding: 40px 0;
  color: rgba(255, 255, 255, 0.3);
  font-size: 13px;
}

.todo-enter-active,
.todo-leave-active {
  transition: all 0.25s ease;
}

.todo-enter-from {
  opacity: 0;
  transform: translateY(-8px);
}

.todo-leave-to {
  opacity: 0;
  transform: translateX(20px);
}
</style>
