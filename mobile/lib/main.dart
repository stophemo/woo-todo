import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/todo_screen.dart';
import 'services/database.dart';
import 'services/sync_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await TodoDatabase.instance;
  final syncService = SyncService();

  // 启动 WebSocket 连接 + 增量同步
  await syncService.connect();
  await syncService.fullSync();

  // 远程更新 → 写入本地数据库
  syncService.onRemoteUpdate = (todos) async {
    await db.upsertTodos(todos);
  };

  runApp(
    MultiProvider(
      providers: [
        Provider<TodoDatabase>.value(value: db),
        Provider<SyncService>.value(value: syncService),
      ],
      child: const WooTodoApp(),
    ),
  );
}

class WooTodoApp extends StatelessWidget {
  const WooTodoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '无我待办',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF534AB7),
        brightness: Brightness.dark,
        fontFamily: 'PingFang',
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF534AB7),
        brightness: Brightness.dark,
        fontFamily: 'PingFang',
      ),
      themeMode: ThemeMode.dark,
      home: const TodoScreen(),
    );
  }
}
