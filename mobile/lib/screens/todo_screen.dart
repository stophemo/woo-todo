import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/todo.dart';
import '../services/database.dart';
import '../services/sync_service.dart';

class TodoScreen extends StatefulWidget {
  const TodoScreen({super.key});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
  List<Todo> _todos = [];
  final _inputController = TextEditingController();
  final _focusNode = FocusNode();
  final _uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _loadTodos();
  }

  Future<void> _loadTodos() async {
    final db = context.read<TodoDatabase>();
    final todos = await db.getTodos();
    setState(() => _todos = todos);
  }

  Future<void> _addTodo() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final todo = Todo(
      id: _uuid.v4(),
      title: text,
      createdAt: now,
      updatedAt: now,
    );

    final db = context.read<TodoDatabase>();
    final sync = context.read<SyncService>();

    await db.insertTodo(todo);
    _inputController.clear();
    _focusNode.unfocus();
    await _loadTodos();

    // 异步推送到服务器
    sync.pushChanges([todo]);
  }

  Future<void> _toggleTodo(Todo todo) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = todo.copyWith(
      completed: !todo.completed,
      updatedAt: now,
    );

    final db = context.read<TodoDatabase>();
    final sync = context.read<SyncService>();

    await db.updateTodo(updated);
    await _loadTodos();
    sync.pushChanges([updated]);
  }

  Future<void> _deleteTodo(Todo todo) async {
    final db = context.read<TodoDatabase>();
    final sync = context.read<SyncService>();

    await db.deleteTodo(todo.id);
    await _loadTodos();
    sync.pushChanges([todo.copyWith(
      isDeleted: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    )]);
  }

  @override
  void dispose() {
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _todos.where((t) => !t.completed).toList();
    final done = _todos.where((t) => t.completed).toList();

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text(
          '无我待办',
          style: TextStyle(fontWeight: FontWeight.w500, fontSize: 18),
        ),
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          // 输入区域
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _focusNode,
                    style: const TextStyle(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: '添加新待办...',
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest
                          .withAlpha(128),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12,
                      ),
                    ),
                    onSubmitted: (_) => _addTodo(),
                    textInputAction: TextInputAction.done,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _addTodo,
                  child: const Text('添加'),
                ),
              ],
            ),
          ),

          // 待办列表
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                // 进行中
                if (active.isNotEmpty) ...[
                  _sectionHeader('待办 (${active.length})'),
                  ...active.map((t) => _TodoItem(
                        todo: t,
                        onToggle: () => _toggleTodo(t),
                        onDelete: () => _deleteTodo(t),
                      )),
                ],

                // 已完成
                if (done.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionHeader('已完成 (${done.length})'),
                  ...done.map((t) => _TodoItem(
                        todo: t,
                        onToggle: () => _toggleTodo(t),
                        onDelete: () => _deleteTodo(t),
                      )),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
        ),
      ),
    );
  }
}

class _TodoItem extends StatelessWidget {
  final Todo todo;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _TodoItem({
    required this.todo,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(64),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              // 勾选框
              Icon(
                todo.completed
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: todo.completed
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface.withAlpha(80),
                size: 22,
              ),
              const SizedBox(width: 12),

              // 待办文字
              Expanded(
                child: Text(
                  todo.title,
                  style: TextStyle(
                    fontSize: 16,
                    decoration:
                        todo.completed ? TextDecoration.lineThrough : null,
                    color: todo.completed
                        ? theme.colorScheme.onSurface.withAlpha(100)
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),

              // 删除按钮
              IconButton(
                onPressed: onDelete,
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: theme.colorScheme.onSurface.withAlpha(60),
                ),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
