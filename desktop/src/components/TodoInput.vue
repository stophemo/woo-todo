<script setup lang="ts">
import { ref, onMounted } from 'vue'

const emit = defineEmits<{
  add: [title: string]
  cancel: []
}>()

const inputRef = ref<HTMLInputElement>()
const title = ref('')

onMounted(() => {
  inputRef.value?.focus()
})

function submit() {
  const trimmed = title.value.trim()
  if (trimmed) {
    emit('add', trimmed)
    title.value = ''
  }
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === 'Enter') submit()
  if (e.key === 'Escape') emit('cancel')
}
</script>

<template>
  <div class="todo-input-wrapper">
    <input
      ref="inputRef"
      v-model="title"
      class="todo-input"
      placeholder="输入待办内容..."
      @keydown="onKeydown"
      @blur="emit('cancel')"
    />
  </div>
</template>

<style scoped>
.todo-input-wrapper {
  width: 100%;
}

.todo-input {
  width: 100%;
  padding: 8px 12px;
  background: rgba(255, 255, 255, 0.08);
  border: 0.5px solid rgba(255, 255, 255, 0.15);
  border-radius: 8px;
  color: rgba(255, 255, 255, 0.9);
  font-size: 14px;
  outline: none;
  transition: border-color 0.15s;
}

.todo-input::placeholder {
  color: rgba(255, 255, 255, 0.3);
}

.todo-input:focus {
  border-color: rgba(255, 255, 255, 0.3);
}
</style>
