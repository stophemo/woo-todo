import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/todo.dart';
import 'database.dart';

class SyncService {
  static const _defaultHost = 'http://localhost:3001';
  static const _wsHost = 'ws://localhost:3001/ws';

  final String _host;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Function(List<Todo>)? onRemoteUpdate;

  SyncService({String? host}) : _host = host ?? _defaultHost;

  Future<void> connect() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsHost));
      _subscription = _channel!.stream.listen((data) {
        final msg = jsonDecode(data as String);
        if (msg['type'] == 'update') {
          final todos = (msg['todos'] as List)
              .map((j) => Todo.fromJson(j as Map<String, dynamic>))
              .toList();
          onRemoteUpdate?.call(todos);
        }
      });
    } catch (e) {
      // WebSocket 连接失败，降级为轮询
    }
  }

  /// 获取增量变更
  Future<List<Todo>> fetchUpdates(int since) async {
    try {
      final response = await http.get(
        Uri.parse('$_host/api/todos?since=$since'),
      );
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        return list
            .map((j) => Todo.fromJson(j as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      // 网络错误，返回空
    }
    return [];
  }

  /// 批量提交变更
  Future<void> pushChanges(List<Todo> todos) async {
    try {
      await http.post(
        Uri.parse('$_host/api/todos'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(todos.map((t) => t.toJson()).toList()),
      );
    } catch (e) {
      // 网络错误，本地队列稍后重试
    }
  }

  Future<void> fullSync() async {
    final db = await TodoDatabase.instance;
    final localTodos = await db.getTodos();

    // 获取服务器增量
    final lastSync = localTodos.isEmpty
        ? 0
        : localTodos.map((t) => t.updatedAt).reduce((a, b) => a > b ? a : b);
    final remoteTodos = await fetchUpdates(lastSync);

    // 合并：服务器数据以 updatedAt 较新的为准
    final merged = <String, Todo>{};
    for (final t in localTodos) {
      merged[t.id] = t;
    }
    for (final t in remoteTodos) {
      final existing = merged[t.id];
      if (existing == null || t.updatedAt > existing.updatedAt) {
        merged[t.id] = t;
      }
    }

    await db.upsertTodos(merged.values.toList());

    // 推送本地新增的
    final newLocal = localTodos
        .where((t) => !remoteTodos.any((r) => r.id == t.id))
        .toList();
    if (newLocal.isNotEmpty) {
      await pushChanges(newLocal);
    }
  }

  void dispose() {
    _subscription?.cancel();
    _channel?.sink.close();
  }
}
