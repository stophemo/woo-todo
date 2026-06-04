/// 待办数据模型
/// 与桌面端 shared/types/todo.ts 保持结构一致
class Todo {
  final String id;
  final String title;
  final bool completed;
  final int createdAt;
  final int updatedAt;
  final bool isDeleted;

  const Todo({
    required this.id,
    required this.title,
    this.completed = false,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  Todo copyWith({
    String? id,
    String? title,
    bool? completed,
    int? createdAt,
    int? updatedAt,
    bool? isDeleted,
  }) {
    return Todo(
      id: id ?? this.id,
      title: title ?? this.title,
      completed: completed ?? this.completed,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'completed': completed ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'is_deleted': isDeleted ? 1 : 0,
      };

  factory Todo.fromMap(Map<String, dynamic> map) => Todo(
        id: map['id'] as String,
        title: map['title'] as String,
        completed: (map['completed'] as int) == 1,
        createdAt: map['created_at'] as int,
        updatedAt: map['updated_at'] as int,
        isDeleted: (map['is_deleted'] as int) == 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'completed': completed,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'isDeleted': isDeleted,
      };

  factory Todo.fromJson(Map<String, dynamic> json) => Todo(
        id: json['id'] as String,
        title: json['title'] as String,
        completed: json['completed'] as bool? ?? false,
        createdAt: json['createdAt'] as int,
        updatedAt: json['updatedAt'] as int,
        isDeleted: json['isDeleted'] as bool? ?? false,
      );
}
