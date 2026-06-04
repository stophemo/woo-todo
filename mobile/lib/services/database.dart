import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/todo.dart';

class TodoDatabase {
  static TodoDatabase? _instance;
  static Database? _db;

  TodoDatabase._();

  static Future<TodoDatabase> get instance async {
    _instance ??= TodoDatabase._();
    _db ??= await _initDb();
    return _instance!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'woo_todo.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE todos (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            completed INTEGER DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            is_deleted INTEGER DEFAULT 0
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_todos_updated ON todos(updated_at)',
        );
      },
    );
  }

  Future<List<Todo>> getTodos() async {
    final db = _db!;
    final maps = await db.query(
      'todos',
      where: 'is_deleted = 0',
      orderBy: 'created_at DESC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<void> insertTodo(Todo todo) async {
    await _db!.insert('todos', todo.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateTodo(Todo todo) async {
    await _db!.update('todos', todo.toMap(),
        where: 'id = ?', whereArgs: [todo.id]);
  }

  Future<void> deleteTodo(String id) async {
    await _db!.update(
      'todos',
      {'is_deleted': 1, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> upsertTodos(List<Todo> todos) async {
    final batch = _db!.batch();
    for (final todo in todos) {
      batch.insert('todos', todo.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }
}
